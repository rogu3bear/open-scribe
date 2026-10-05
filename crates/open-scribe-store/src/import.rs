use std::ffi::OsStr;
use std::fs::{self, File};
use std::io::{Read, Seek};
use std::os::fd::{AsRawFd, OwnedFd, RawFd};
use std::path::{Path, PathBuf};

use open_scribe_types::SessionId;
use rusqlite::params;
use rustix::fs as fd_fs;
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use uuid::Uuid;

use super::{
    CAF_HEADER, JOURNAL_VERSION, JournalRecord, MediaLengthRequirement, PrepareSessionRequest,
    RecoveryDisposition, SCHEMA_VERSION, SessionOrigin, SessionStore, StoreError,
    ValidatedMediaFile, event_digest, insert_event_with_id, inspect_pcm_caf, next_database_event,
    open_managed_directory, open_managed_directory_at, payload_string, payload_u64,
    sealed_media_identity, validate_request, wall_time_milliseconds,
};

const MAX_IMPORTED_PLAYBACK_SNAPSHOT_BYTES: u64 = 256 * 1024 * 1024;
/// Four hours of stereo 16-bit 48 kHz, plus CAF container slack. Files above
/// the snapshot cap stream in verified chunks and are not held in memory.
const MAX_IMPORT_BYTES: u64 = (4 * 60 * 60 * 48_000 * 2 * 2) + (1024 * 1024);
const MAX_COMPRESSED_IMPORT_BYTES: u64 = 4 * 1024 * 1024 * 1024;
const MAX_IMPORT_SAMPLES: u64 = 4 * 60 * 60 * 48_000;
const MAX_IMPORT_DURATION_NANOSECONDS: u64 = 4 * 60 * 60 * 1_000_000_000;
pub(super) const IMPORT_SOURCE_KIND: &str = "imported_audio";
const IMPORT_MEDIA_FORMAT: &str = "caf-pcm-s16le";
pub(super) const COMPRESSED_IMPORT_MEDIA_FORMAT: &str = "m4a-alac-or-aac";
const PLAYBACK_SNAPSHOT_PREFIX: &str = ".playback-";
const PLAYBACK_SNAPSHOT_SUFFIX: &str = ".caf";
const PLAYBACK_QUARANTINE_PREFIX: &str = ".playback-recovery-";

/// One already user-authorized local file to copy into the managed conversation library.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ImportMediaRequest {
    pub title: String,
    pub source_path: PathBuf,
}

/// Native-probed details of an original compressed file. Rust independently
/// validates managed bytes before any library entry becomes visible.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct OriginalImportMetadata {
    pub display_name: String,
    pub byte_length: u64,
    pub duration_nanoseconds: u64,
    pub sample_rate_hz: u32,
    pub channel_count: u32,
    pub media_format: String,
}

/// Platform decoder evidence, bound to the exact source bytes by SHA-256.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct CompressedImportMetadata {
    pub original: OriginalImportMetadata,
    pub sample_count: u64,
    pub digest_sha256: String,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct ImportPolicy {
    pub maximum_source_bytes: u64,
    pub maximum_managed_bytes: u64,
    pub maximum_duration_nanoseconds: u64,
    pub maximum_managed_samples: u64,
}

#[must_use]
pub const fn import_policy() -> ImportPolicy {
    ImportPolicy {
        maximum_source_bytes: MAX_COMPRESSED_IMPORT_BYTES,
        maximum_managed_bytes: MAX_IMPORT_BYTES,
        maximum_duration_nanoseconds: MAX_IMPORT_DURATION_NANOSECONDS,
        maximum_managed_samples: MAX_IMPORT_SAMPLES,
    }
}

/// Content-free admission evidence for one managed imported conversation.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ImportedMediaEvidence {
    pub session_id: SessionId,
    pub relative_path: String,
    pub byte_length: u64,
    pub sample_count: u64,
    pub digest_sha256: String,
    pub journal_version: u32,
    pub last_journal_sequence: u64,
    pub original_untouched: bool,
    pub ready_for_review: bool,
}

/// Open descriptor lease for one revalidated managed media object.
///
/// Native playback must match `digest_sha256` before exposing playback and retain this lease for
/// the full decoder lifetime. Imported PCM CAF uses a bounded anonymous snapshot; compressed
/// imports and recovered playback verify bounded chunks whenever AudioToolbox reads them. The
/// descriptor keeps the identity-bound managed object open and is never represented to the native
/// adapter by a pathname.
pub struct ImportedPlaybackLease {
    file: File,
    byte_length: u64,
    digest_sha256: String,
    media_format: String,
}

impl ImportedPlaybackLease {
    pub(super) fn verified_derived_m4a(
        file: File,
        byte_length: u64,
        digest_sha256: String,
    ) -> Self {
        Self {
            file,
            byte_length,
            digest_sha256,
            media_format: COMPRESSED_IMPORT_MEDIA_FORMAT.to_owned(),
        }
    }

    #[must_use]
    pub fn raw_file_descriptor(&self) -> RawFd {
        self.file.as_raw_fd()
    }

    #[must_use]
    pub const fn byte_length(&self) -> u64 {
        self.byte_length
    }

    #[must_use]
    pub fn digest_sha256(&self) -> &str {
        &self.digest_sha256
    }

    #[must_use]
    pub fn media_format(&self) -> &str {
        &self.media_format
    }

    #[must_use]
    pub const fn maximum_snapshot_byte_length() -> u64 {
        MAX_IMPORTED_PLAYBACK_SNAPSHOT_BYTES
    }

    /// The identity-bound descriptor, for in-crate readers of sealed bytes.
    pub(crate) fn file(&self) -> &File {
        &self.file
    }
}

struct ValidatedImportSource {
    file: File,
    byte_length: u64,
    sample_count: u64,
    digest_sha256: String,
    device: u64,
    inode: u64,
}

struct ImportPaths {
    track_id: String,
    relative_path: String,
    media_format: &'static str,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum ImportFailurePoint {
    PreparationDurable,
    ManagedCopyComplete,
    StagedJournalDurable,
}

impl SessionStore {
    /// Copies one bounded, independently validated CAF into the existing managed library.
    ///
    /// The caller remains responsible for obtaining user-selected file authority. This
    /// operation never mutates the original and never creates capture or recovery claims.
    pub fn import_recoverable_caf(
        &mut self,
        request: ImportMediaRequest,
    ) -> Result<ImportedMediaEvidence, StoreError> {
        self.import_recoverable_caf_inner(request, None, None)
    }

    pub fn import_normalized_caf(
        &mut self,
        request: ImportMediaRequest,
        original: OriginalImportMetadata,
    ) -> Result<ImportedMediaEvidence, StoreError> {
        if original.byte_length > MAX_IMPORT_BYTES {
            return Err(StoreError::ImportSizeLimit);
        }
        if original.duration_nanoseconds > MAX_IMPORT_DURATION_NANOSECONDS {
            return Err(StoreError::ImportDurationLimit);
        }
        if original.display_name.is_empty()
            || original.display_name.len() > 255
            || original
                .display_name
                .chars()
                .any(|character| matches!(character, '/' | '\\' | '\0'))
            || original.media_format != "m4a"
            || original.byte_length == 0
            || original.duration_nanoseconds == 0
            || original.sample_rate_hz == 0
            || original.channel_count != 1
        {
            return Err(StoreError::InvalidRequest(
                "original import metadata is invalid",
            ));
        }
        self.import_recoverable_caf_inner(request, Some(original), None)
    }

    pub fn import_compressed_m4a(
        &mut self,
        request: ImportMediaRequest,
        metadata: CompressedImportMetadata,
    ) -> Result<ImportedMediaEvidence, StoreError> {
        validate_compressed_import_bounds(metadata.original.byte_length, metadata.sample_count)?;
        if metadata.original.duration_nanoseconds > MAX_IMPORT_DURATION_NANOSECONDS {
            return Err(StoreError::ImportDurationLimit);
        }
        if metadata.original.media_format != "m4a"
            || metadata.original.sample_rate_hz != 48_000
            || !matches!(metadata.original.channel_count, 1 | 2)
            || metadata.original.byte_length == 0
            || metadata.original.byte_length > MAX_COMPRESSED_IMPORT_BYTES
            || metadata.sample_count == 0
            || metadata.sample_count > MAX_IMPORT_SAMPLES
            || metadata.original.duration_nanoseconds == 0
            || metadata.original.duration_nanoseconds > MAX_IMPORT_DURATION_NANOSECONDS
            || metadata.original.display_name.is_empty()
            || metadata.original.display_name.len() > 255
            || metadata
                .original
                .display_name
                .chars()
                .any(|c| matches!(c, '/' | '\\' | '\0'))
            || metadata.digest_sha256.len() != 64
            || !metadata
                .digest_sha256
                .bytes()
                .all(|b| b.is_ascii_hexdigit())
        {
            return Err(StoreError::InvalidRequest(
                "compressed import metadata is invalid",
            ));
        }
        let expected_duration = metadata.sample_count.saturating_mul(1_000_000_000) / 48_000;
        if expected_duration.abs_diff(metadata.original.duration_nanoseconds) > 1_000_000 {
            return Err(StoreError::InvalidRequest(
                "compressed import duration disagrees with frames",
            ));
        }
        self.import_inner(
            request,
            Some(metadata.original.clone()),
            Some(metadata),
            None,
        )
    }

    fn import_recoverable_caf_inner(
        &mut self,
        request: ImportMediaRequest,
        original: Option<OriginalImportMetadata>,
        failure: Option<ImportFailurePoint>,
    ) -> Result<ImportedMediaEvidence, StoreError> {
        self.import_inner(request, original, None, failure)
    }

    fn import_inner(
        &mut self,
        request: ImportMediaRequest,
        original: Option<OriginalImportMetadata>,
        compressed: Option<CompressedImportMetadata>,
        failure: Option<ImportFailurePoint>,
    ) -> Result<ImportedMediaEvidence, StoreError> {
        validate_request(&PrepareSessionRequest {
            title: request.title.clone(),
            origin: SessionOrigin::Import,
        })?;
        let mut source = match compressed.as_ref() {
            Some(metadata) => validate_compressed_import_source(&request.source_path, metadata)?,
            None => validate_import_source(&request.source_path)?,
        };
        let media_format = if compressed.is_some() {
            COMPRESSED_IMPORT_MEDIA_FORMAT
        } else {
            IMPORT_MEDIA_FORMAT
        };
        let suffix = if compressed.is_some() { "m4a" } else { "caf" };
        let prepared = self.prepare_session_inner(
            PrepareSessionRequest {
                title: request.title,
                origin: SessionOrigin::Import,
            },
            None,
        )?;

        let session_id = prepared.session_id.clone();
        let import_result = (|| {
            interrupt_import_if(failure, ImportFailurePoint::PreparationDurable)?;

            let source_id = Uuid::now_v7().to_string();
            let track_id = Uuid::now_v7().to_string();
            let segment_id = Uuid::now_v7().to_string();
            let staging_relative_path = format!("audio/{track_id}/.importing.{suffix}");
            let relative_path = format!("audio/{track_id}/000000-import.{suffix}");
            let audio_directory = self.open_managed_audio_directory(&prepared.session_id.0)?;
            fd_fs::mkdirat(
                &audio_directory,
                &track_id,
                fd_fs::Mode::from_raw_mode(0o700),
            )
            .map_err(|_| {
                StoreError::IntegrityMismatch("managed import track could not be created")
            })?;
            let track_directory =
                open_managed_directory_at(&audio_directory, OsStr::new(&track_id))?;
            source.file.rewind()?;
            let staging_fd = fd_fs::openat(
                &track_directory,
                OsStr::new(if compressed.is_some() {
                    ".importing.m4a"
                } else {
                    ".importing.caf"
                }),
                fd_fs::OFlags::WRONLY
                    | fd_fs::OFlags::CREATE
                    | fd_fs::OFlags::EXCL
                    | fd_fs::OFlags::CLOEXEC
                    | fd_fs::OFlags::NOFOLLOW,
                fd_fs::Mode::from_raw_mode(0o600),
            )
            .map_err(|_| {
                StoreError::IntegrityMismatch("managed import staging could not be created")
            })?;
            let mut staging = File::from(staging_fd);
            let staging_stat = fd_fs::fstat(&staging).map_err(|_| {
                StoreError::IntegrityMismatch("managed import staging identity is unavailable")
            })?;
            fd_fs::fsync(&track_directory).map_err(|_| {
                StoreError::IntegrityMismatch("managed import track was not synchronized")
            })?;
            fd_fs::fsync(&audio_directory).map_err(|_| {
                StoreError::IntegrityMismatch("managed import audio directory was not synchronized")
            })?;
            self.append_session_journal(
                &prepared.session_id.0,
                "media_import_copy_started",
                Some(&staging_relative_path),
                json!({
                    "track_id": track_id,
                    "staging_relative_path": staging_relative_path,
                    "file_device": staging_stat.st_dev as u64,
                    "file_inode": staging_stat.st_ino as u64,
                    "expected_byte_length": source.byte_length,
                    "expected_digest_sha256": source.digest_sha256,
                }),
            )?;
            let copied = std::io::copy(&mut source.file, &mut staging)?;
            if copied != source.byte_length {
                return Err(StoreError::IntegrityMismatch(
                    "managed import copy length changed",
                ));
            }
            staging.sync_all()?;
            drop(staging);
            fd_fs::fsync(&track_directory).map_err(|_| {
                StoreError::IntegrityMismatch("managed import track was not synchronized")
            })?;

            let staged = self.validate_import_media_file(
                &prepared.session_id.0,
                &staging_relative_path,
                source.byte_length,
                media_format,
                true,
            )?;
            if staged.digest_sha256.as_deref() != Some(source.digest_sha256.as_str())
                || (compressed.is_none()
                    && staged.recoverable_sample_count != Some(source.sample_count))
            {
                return Err(StoreError::IntegrityMismatch(
                    "managed import copy does not match the validated source",
                ));
            }
            revalidate_import_source(&source)?;
            interrupt_import_if(failure, ImportFailurePoint::ManagedCopyComplete)?;

            let payload = json!({
                "source_id": source_id,
                "source_kind": IMPORT_SOURCE_KIND,
                "source_display_name": original.as_ref().map_or_else(
                    || request.source_path.file_name().and_then(OsStr::to_str).unwrap_or("Imported audio"),
                    |metadata| metadata.display_name.as_str(),
                ),
                "original_media": original.as_ref().map(|metadata| json!({
                    "format": metadata.media_format,
                    "byte_length": metadata.byte_length,
                    "duration_nanoseconds": metadata.duration_nanoseconds,
                    "sample_rate_hz": metadata.sample_rate_hz,
                    "channel_count": metadata.channel_count,
                })),
                "track_id": track_id,
                "segment_id": segment_id,
                "staging_relative_path": staging_relative_path,
                "relative_path": relative_path,
                "media_format": media_format,
                "byte_length": source.byte_length,
                "sample_count": source.sample_count,
                "digest_sha256": source.digest_sha256,
            });
            let journal_record = self.append_session_journal(
                &prepared.session_id.0,
                "media_import_staged",
                Some(&relative_path),
                payload.clone(),
            )?;
            interrupt_import_if(failure, ImportFailurePoint::StagedJournalDurable)?;

            rename_import_entry(&track_directory, media_format)?;
            fd_fs::fsync(&track_directory).map_err(|_| {
                StoreError::IntegrityMismatch("managed import rename was not synchronized")
            })?;
            self.project_import(&prepared.session_id.0, &payload, &journal_record)?;

            Ok(ImportedMediaEvidence {
                session_id: prepared.session_id,
                relative_path,
                byte_length: source.byte_length,
                sample_count: source.sample_count,
                digest_sha256: source.digest_sha256,
                journal_version: JOURNAL_VERSION,
                last_journal_sequence: journal_record.body.sequence,
                original_untouched: true,
                ready_for_review: true,
            })
        })();

        match import_result {
            Ok(evidence) => Ok(evidence),
            Err(original_error) => match self.reconcile_import_attempt(&session_id.0)? {
                Some(evidence) => Ok(evidence),
                None => Err(original_error),
            },
        }
    }

    /// Revalidates an import and leases its identity-bound descriptor for native playback.
    pub fn lease_imported_playback(
        &self,
        session_id: &SessionId,
    ) -> Result<ImportedPlaybackLease, StoreError> {
        let rows = {
            let mut statement = self.connection.prepare(
                "SELECT segments.relative_path, segments.sample_count, segments.byte_length,
                        segments.digest,
                        CASE WHEN sessions.origin = 'import'
                             THEN imports.source_digest ELSE segments.digest END,
                        segments.file_device, segments.file_inode, segments.media_format
                 FROM sessions
                 JOIN segments ON segments.session_id = sessions.id
                 JOIN tracks ON tracks.id = segments.track_id
                            AND tracks.session_id = segments.session_id
                 JOIN sources ON sources.id = tracks.source_id
                             AND sources.session_id = tracks.session_id
                 LEFT JOIN imports ON imports.session_id = sessions.id
                 WHERE sessions.id = ?1
                   AND sessions.lifecycle = 'ready_for_review'
                   AND segments.lifecycle = 'sealed'
                   AND segments.seal_state = 'sealed'
                   AND (segments.media_format = 'caf-pcm-s16le'
                        OR (sessions.origin = 'import' AND segments.media_format = 'm4a-alac-or-aac'))
                   AND (
                     (sessions.origin = 'import'
                      AND segments.relative_path = imports.relative_path)
                     OR
                     (sessions.origin = 'capture'
                      AND sessions.health IN ('healthy', 'degraded')
                      AND segments.recovery_state = 'not_required'
                      AND NOT EXISTS (
                        SELECT 1 FROM recovery_runs
                        WHERE recovery_runs.session_id = sessions.id
                          AND recovery_runs.disposition = 'playable_media_recovered'
                      ))
                   )
                 ORDER BY CASE WHEN sources.lifecycle = 'failed' THEN 1 ELSE 0 END,
                          CASE sources.kind
                            WHEN 'microphone' THEN 0
                            WHEN 'application_audio' THEN 1
                            WHEN 'system_audio' THEN 2
                            ELSE 3
                          END,
                          segments.sequence, segments.id
                 LIMIT 1",
            )?;
            statement
                .query_map([&session_id.0], |row| {
                    Ok((
                        row.get::<_, String>(0)?,
                        row.get::<_, i64>(1)?,
                        row.get::<_, i64>(2)?,
                        row.get::<_, String>(3)?,
                        row.get::<_, String>(4)?,
                        row.get::<_, i64>(5)?,
                        row.get::<_, i64>(6)?,
                        row.get::<_, String>(7)?,
                    ))
                })?
                .collect::<Result<Vec<_>, _>>()?
        };
        if rows.len() != 1 {
            return Err(StoreError::InvalidState(
                "managed playback evidence is unavailable",
            ));
        }
        let (
            relative_path,
            stored_sample_count,
            stored_byte_length,
            segment_digest,
            import_digest,
            stored_device,
            stored_inode,
            media_format,
        ) = &rows[0];
        let sample_count = u64::try_from(*stored_sample_count)
            .map_err(|_| StoreError::IntegrityMismatch("managed sample count is invalid"))?;
        let byte_length = u64::try_from(*stored_byte_length)
            .map_err(|_| StoreError::IntegrityMismatch("managed byte length is invalid"))?;
        if media_format == COMPRESSED_IMPORT_MEDIA_FORMAT {
            validate_compressed_import_bounds(byte_length, sample_count)?;
        }
        if media_format == IMPORT_MEDIA_FORMAT && byte_length > MAX_IMPORT_BYTES {
            return Err(StoreError::ImportSizeLimit);
        }
        if segment_digest != import_digest {
            return Err(StoreError::IntegrityMismatch(
                "managed media receipt and segment digest disagree",
            ));
        }
        let mut validated = self.validate_import_media_file(
            &session_id.0,
            relative_path,
            byte_length,
            media_format,
            true,
        )?;
        if !validated.matches_sealed_identity(
            u64::try_from(*stored_device).unwrap_or(0),
            u64::try_from(*stored_inode).unwrap_or(0),
            byte_length,
            import_digest,
        ) || (media_format == IMPORT_MEDIA_FORMAT
            && validated.recoverable_sample_count != Some(sample_count))
            || validated.digest_sha256.as_deref() != Some(import_digest.as_str())
        {
            return Err(StoreError::IntegrityMismatch(
                "managed playback lease does not match durable evidence",
            ));
        }
        validated.file.rewind()?;
        Ok(ImportedPlaybackLease {
            file: validated.file,
            byte_length,
            digest_sha256: import_digest.clone(),
            media_format: media_format.clone(),
        })
    }

    /// Revalidates one exact recovered record and retains its descriptor for native playback.
    pub fn lease_recovered_playback(
        &self,
        session_id: &SessionId,
        source_id: &str,
        track_id: &str,
        segment_id: &str,
    ) -> Result<ImportedPlaybackLease, StoreError> {
        self.lease_capture_playback(session_id, source_id, track_id, segment_id, false)
    }

    pub fn lease_capture_playback(
        &self,
        session_id: &SessionId,
        source_id: &str,
        track_id: &str,
        segment_id: &str,
        allow_saved: bool,
    ) -> Result<ImportedPlaybackLease, StoreError> {
        let row = self
            .connection
            .query_row(
                &format!(
                    "SELECT segments.relative_path, segments.sample_count, segments.byte_length,
                    segments.digest, segments.file_device, segments.file_inode
             FROM sessions
             JOIN sources ON sources.session_id = sessions.id
             JOIN tracks ON tracks.session_id = sessions.id AND tracks.source_id = sources.id
             JOIN segments ON segments.session_id = sessions.id AND segments.track_id = tracks.id
             WHERE sessions.id = ?1
               AND sources.id = ?2
               AND tracks.id = ?3
               AND segments.id = ?4
               AND sessions.origin = 'capture'
               AND sessions.lifecycle = 'ready_for_review'
               AND segments.lifecycle = 'sealed'
               AND segments.seal_state = 'sealed'
               AND segments.recovery_state IN ('recovered', 'not_required')
               AND segments.media_format = 'caf-pcm-s16le'
               AND (?5 = 1 OR {})",
                    super::library_recovery::RECOVERED_SESSION_EVIDENCE_SQL
                ),
                params![&session_id.0, source_id, track_id, segment_id, allow_saved],
                |row| {
                    Ok((
                        row.get::<_, String>(0)?,
                        row.get::<_, i64>(1)?,
                        row.get::<_, i64>(2)?,
                        row.get::<_, String>(3)?,
                        row.get::<_, i64>(4)?,
                        row.get::<_, i64>(5)?,
                    ))
                },
            )
            .map_err(|error| match error {
                rusqlite::Error::QueryReturnedNoRows => {
                    StoreError::InvalidState("recovered playback evidence is unavailable")
                }
                other => StoreError::Sqlite(other),
            })?;
        let (relative_path, stored_samples, stored_bytes, digest, stored_device, stored_inode) =
            row;
        let sample_count = u64::try_from(stored_samples)
            .map_err(|_| StoreError::IntegrityMismatch("recovered sample count is invalid"))?;
        let byte_length = u64::try_from(stored_bytes)
            .map_err(|_| StoreError::IntegrityMismatch("recovered byte length is invalid"))?;
        let mut validated = self.validate_media_file(
            &session_id.0,
            &relative_path,
            MediaLengthRequirement::Exact(byte_length),
            true,
        )?;
        if !validated.matches_sealed_identity(
            u64::try_from(stored_device).unwrap_or(0),
            u64::try_from(stored_inode).unwrap_or(0),
            byte_length,
            &digest,
        ) || validated.recoverable_sample_count != Some(sample_count)
            || validated.digest_sha256.as_deref() != Some(digest.as_str())
        {
            return Err(StoreError::IntegrityMismatch(
                "recovered playback lease does not match durable evidence",
            ));
        }
        validated.file.rewind()?;
        Ok(ImportedPlaybackLease {
            file: validated.file,
            byte_length,
            digest_sha256: digest,
            media_format: IMPORT_MEDIA_FORMAT.to_owned(),
        })
    }

    fn reconcile_import_attempt(
        &mut self,
        session_id: &str,
    ) -> Result<Option<ImportedMediaEvidence>, StoreError> {
        let journal_path = self
            .session_directory(session_id)?
            .join(super::JOURNAL_NAME);
        let records = match super::validate_journal(&journal_path, session_id)? {
            super::JournalValidation::Valid(records) => records,
            _ => {
                return Err(StoreError::IntegrityMismatch(
                    "import journal is not recoverable",
                ));
            }
        };
        let disposition =
            self.reconcile_import(session_id, &records, RecoveryDisposition::Prepared)?;
        match disposition {
            RecoveryDisposition::ImportedMediaReady
            | RecoveryDisposition::ImportProjectionRepaired => {
                self.imported_media_evidence(session_id).map(Some)
            }
            RecoveryDisposition::ImportFailed => Ok(None),
            _ => Err(StoreError::IntegrityMismatch(
                "failed import did not reach a terminal disposition",
            )),
        }
    }

    fn imported_media_evidence(
        &self,
        session_id: &str,
    ) -> Result<ImportedMediaEvidence, StoreError> {
        let (relative_path, byte_length, sample_count, digest_sha256) = self.connection.query_row(
            "SELECT imports.relative_path, segments.byte_length,
                        segments.sample_count, imports.source_digest
                 FROM imports
                 JOIN segments ON segments.session_id = imports.session_id
                              AND segments.relative_path = imports.relative_path
                 JOIN sessions ON sessions.id = imports.session_id
                 WHERE imports.session_id = ?1
                   AND sessions.lifecycle = 'ready_for_review'
                   AND segments.lifecycle = 'sealed'",
            [session_id],
            |row| {
                Ok((
                    row.get::<_, String>(0)?,
                    row.get::<_, i64>(1)?,
                    row.get::<_, i64>(2)?,
                    row.get::<_, String>(3)?,
                ))
            },
        )?;
        let journal_path = self
            .session_directory(session_id)?
            .join(super::JOURNAL_NAME);
        let records = match super::validate_journal(&journal_path, session_id)? {
            super::JournalValidation::Valid(records) => records,
            _ => {
                return Err(StoreError::IntegrityMismatch(
                    "import journal is not recoverable",
                ));
            }
        };
        let staged = records
            .iter()
            .find(|record| record.body.event_kind == "media_import_staged")
            .ok_or(StoreError::IntegrityMismatch("import evidence is missing"))?;
        Ok(ImportedMediaEvidence {
            session_id: SessionId(session_id.to_owned()),
            relative_path,
            byte_length: u64::try_from(byte_length)
                .map_err(|_| StoreError::IntegrityMismatch("import byte length is invalid"))?,
            sample_count: u64::try_from(sample_count)
                .map_err(|_| StoreError::IntegrityMismatch("import sample count is invalid"))?,
            digest_sha256,
            journal_version: JOURNAL_VERSION,
            last_journal_sequence: staged.body.sequence,
            original_untouched: true,
            ready_for_review: true,
        })
    }

    pub(super) fn reconcile_import(
        &mut self,
        session_id: &str,
        records: &[JournalRecord],
        base: RecoveryDisposition,
    ) -> Result<RecoveryDisposition, StoreError> {
        let (origin, lifecycle): (String, String) = self.connection.query_row(
            "SELECT origin, lifecycle FROM sessions WHERE id = ?1",
            [session_id],
            |row| Ok((row.get(0)?, row.get(1)?)),
        )?;
        if origin != "import" {
            return Ok(base);
        }

        let failures: Vec<_> = records
            .iter()
            .filter(|record| record.body.event_kind == "media_import_failed")
            .collect();
        if !failures.is_empty() {
            if failures.len() != 1 || failures[0].body.sequence != records.len() as u64 {
                return Ok(RecoveryDisposition::IntegrityMismatch);
            }
            if lifecycle == "preparing" {
                self.project_import_failure(session_id, &failures[0].body.payload, failures[0])?;
            } else if lifecycle != "deleted" {
                return Ok(RecoveryDisposition::IntegrityMismatch);
            }
            return Ok(RecoveryDisposition::ImportFailed);
        }

        let imports: Vec<_> = records
            .iter()
            .filter(|record| record.body.event_kind == "media_import_staged")
            .collect();
        if imports.is_empty() {
            self.cleanup_unstaged_import(session_id, records)?;
            return self.tombstone_import(session_id, "before_durable_stage");
        }
        if imports.len() != 1 || imports[0].body.sequence != records.len() as u64 {
            return Ok(RecoveryDisposition::IntegrityMismatch);
        }
        let record = imports[0];
        let payload = &record.body.payload;
        let paths = validate_import_paths(payload)?;
        let track_directory = self.managed_import_track_directory(session_id, &paths.track_id)?;
        let suffix = if paths.media_format == COMPRESSED_IMPORT_MEDIA_FORMAT {
            "m4a"
        } else {
            "caf"
        };
        if !managed_import_entry_exists(
            &track_directory,
            OsStr::new(&format!("000000-import.{suffix}")),
        )? {
            if !managed_import_entry_exists(
                &track_directory,
                OsStr::new(&format!(".importing.{suffix}")),
            )? {
                return self.tombstone_import(session_id, "staged_media_missing");
            }
            rename_import_entry(&track_directory, paths.media_format)?;
            fd_fs::fsync(&track_directory).map_err(|_| {
                StoreError::IntegrityMismatch("recovered import rename was not synchronized")
            })?;
        }
        let already_projected: bool = self.connection.query_row(
            "SELECT EXISTS(SELECT 1 FROM imports WHERE session_id = ?1)",
            [session_id],
            |row| row.get(0),
        )?;
        if already_projected {
            return Ok(RecoveryDisposition::ImportedMediaReady);
        }
        self.project_import(session_id, payload, record)?;
        Ok(RecoveryDisposition::ImportProjectionRepaired)
    }

    fn tombstone_import(
        &mut self,
        session_id: &str,
        reason: &str,
    ) -> Result<RecoveryDisposition, StoreError> {
        let payload = json!({ "reason": reason });
        let journal_record =
            self.append_session_journal(session_id, "media_import_failed", None, payload.clone())?;
        self.project_import_failure(session_id, &payload, &journal_record)?;
        Ok(RecoveryDisposition::ImportFailed)
    }

    fn cleanup_unstaged_import(
        &self,
        session_id: &str,
        records: &[JournalRecord],
    ) -> Result<(), StoreError> {
        let intents = records
            .iter()
            .filter(|record| record.body.event_kind == "media_import_copy_started")
            .collect::<Vec<_>>();
        if intents.len() > 1 {
            return Err(StoreError::IntegrityMismatch(
                "managed import has multiple copy intents",
            ));
        }
        let audio_directory = self.open_managed_audio_directory(session_id)?;
        let audio_path = self.session_directory(session_id)?.join("audio");
        let entries = fs::read_dir(&audio_path)?.collect::<Result<Vec<_>, _>>()?;
        if entries.is_empty() {
            return Ok(());
        }
        if entries.len() != 1 {
            return Err(StoreError::IntegrityMismatch(
                "unstaged import audio directory is not uniquely owned",
            ));
        }
        let entry = &entries[0];
        let track_name = entry.file_name();
        let track_id = track_name.to_str().ok_or(StoreError::IntegrityMismatch(
            "unstaged import track ID is invalid",
        ))?;
        if Uuid::parse_str(track_id).is_err()
            || entry.file_type()?.is_symlink()
            || !entry.file_type()?.is_dir()
        {
            return Err(StoreError::IntegrityMismatch(
                "unstaged import track is not a managed UUID directory",
            ));
        }
        let track_directory = open_managed_directory_at(&audio_directory, &track_name)?;
        let track_path = audio_path.join(&track_name);
        let track_entries = fs::read_dir(&track_path)?.collect::<Result<Vec<_>, _>>()?;
        let staging_name = if let Some(intent) = intents.first() {
            let staged = payload_string(&intent.body.payload, "staging_relative_path")?;
            if staged == format!("audio/{track_id}/.importing.m4a") {
                ".importing.m4a"
            } else if staged == format!("audio/{track_id}/.importing.caf") {
                ".importing.caf"
            } else {
                return Err(StoreError::IntegrityMismatch(
                    "unstaged import path is invalid",
                ));
            }
        } else if track_entries
            .first()
            .is_some_and(|entry| entry.file_name() == OsStr::new(".importing.m4a"))
        {
            ".importing.m4a"
        } else {
            ".importing.caf"
        };
        if track_entries.len() > 1
            || track_entries
                .first()
                .is_some_and(|entry| entry.file_name() != OsStr::new(staging_name))
        {
            return Err(StoreError::IntegrityMismatch(
                "unstaged import track contains unexpected media",
            ));
        }

        if let Some(intent) = intents.first() {
            let payload = &intent.body.payload;
            if payload_string(payload, "track_id")? != track_id
                || payload_string(payload, "staging_relative_path")?
                    != format!("audio/{track_id}/{staging_name}")
            {
                return Err(StoreError::IntegrityMismatch(
                    "unstaged import cleanup intent does not match its target",
                ));
            }
            if track_entries.is_empty() {
                fd_fs::unlinkat(&audio_directory, &track_name, fd_fs::AtFlags::REMOVEDIR).map_err(
                    |_| {
                        StoreError::IntegrityMismatch(
                            "empty unstaged import track could not be removed",
                        )
                    },
                )?;
                fd_fs::fsync(&audio_directory).map_err(|_| {
                    StoreError::IntegrityMismatch(
                        "unstaged import audio cleanup was not synchronized",
                    )
                })?;
                return Ok(());
            }
            let staging_fd = fd_fs::openat(
                &track_directory,
                OsStr::new(staging_name),
                fd_fs::OFlags::RDONLY | fd_fs::OFlags::CLOEXEC | fd_fs::OFlags::NOFOLLOW,
                fd_fs::Mode::empty(),
            )
            .map_err(|_| {
                StoreError::IntegrityMismatch("unstaged import media could not be rebound")
            })?;
            let staging_stat = fd_fs::fstat(&staging_fd).map_err(|_| {
                StoreError::IntegrityMismatch("unstaged import media identity is unavailable")
            })?;
            if fd_fs::FileType::from_raw_mode(staging_stat.st_mode) != fd_fs::FileType::RegularFile
                || staging_stat.st_dev as u64 != payload_u64(payload, "file_device")?
                || staging_stat.st_ino as u64 != payload_u64(payload, "file_inode")?
            {
                return Err(StoreError::IntegrityMismatch(
                    "unstaged import media no longer matches cleanup authority",
                ));
            }
        } else if let Some(staging_entry) = track_entries.first() {
            let metadata = fs::symlink_metadata(staging_entry.path())?;
            if metadata.file_type().is_symlink() || !metadata.is_file() || metadata.len() != 0 {
                return Err(StoreError::IntegrityMismatch(
                    "unjournaled import media is not an empty staging file",
                ));
            }
        }

        if !track_entries.is_empty() {
            fd_fs::unlinkat(
                &track_directory,
                OsStr::new(staging_name),
                fd_fs::AtFlags::empty(),
            )
            .map_err(|_| {
                StoreError::IntegrityMismatch("unstaged import media could not be removed")
            })?;
            fd_fs::fsync(&track_directory).map_err(|_| {
                StoreError::IntegrityMismatch("unstaged import track cleanup was not synchronized")
            })?;
        }
        fd_fs::unlinkat(&audio_directory, &track_name, fd_fs::AtFlags::REMOVEDIR).map_err(
            |_| StoreError::IntegrityMismatch("unstaged import track could not be removed"),
        )?;
        fd_fs::fsync(&audio_directory).map_err(|_| {
            StoreError::IntegrityMismatch("unstaged import audio cleanup was not synchronized")
        })?;
        Ok(())
    }

    fn project_import_failure(
        &mut self,
        session_id: &str,
        payload: &Value,
        journal_record: &JournalRecord,
    ) -> Result<(), StoreError> {
        let reason = payload_string(payload, "reason")?;
        if !matches!(reason, "before_durable_stage" | "staged_media_missing") {
            return Err(StoreError::IntegrityMismatch(
                "import failure reason is unsupported",
            ));
        }
        let (event_sequence, prior_digest) = next_database_event(&self.connection, session_id)?;
        let digest = event_digest(
            session_id,
            event_sequence,
            "media_import_failed",
            payload,
            prior_digest.as_deref(),
        )?;
        let transaction = self.connection.transaction()?;
        let changed = transaction.execute(
            "UPDATE sessions
             SET lifecycle = 'deleted', health = 'degraded', media_files_open = 0,
                 updated_at_ms = ?2
             WHERE id = ?1 AND origin = 'import' AND lifecycle = 'preparing'",
            params![session_id, journal_record.body.wall_time_milliseconds],
        )?;
        if changed != 1 {
            return Err(StoreError::InvalidState(
                "import failure projection is not awaiting evidence",
            ));
        }
        insert_event_with_id(
            &transaction,
            &journal_record.body.event_id,
            session_id,
            event_sequence,
            "media_import_failed",
            journal_record.body.wall_time_milliseconds,
            payload,
            prior_digest.as_deref(),
            &digest,
        )?;
        transaction.commit()?;
        Ok(())
    }

    fn project_import(
        &mut self,
        session_id: &str,
        payload: &Value,
        journal_record: &JournalRecord,
    ) -> Result<(), StoreError> {
        let paths = validate_import_paths(payload)?;
        let source_id = payload_string(payload, "source_id")?;
        let track_id = paths.track_id.as_str();
        let segment_id = payload_string(payload, "segment_id")?;
        let relative_path = paths.relative_path.as_str();
        let byte_length = payload_u64(payload, "byte_length")?;
        let sample_count = payload_u64(payload, "sample_count")?;
        let digest_sha256 = payload_string(payload, "digest_sha256")?;
        let media_format = payload_string(payload, "media_format")?;
        let validated = self.validate_import_media_file(
            session_id,
            relative_path,
            byte_length,
            media_format,
            true,
        )?;
        if validated.digest_sha256.as_deref() != Some(digest_sha256)
            || (media_format == IMPORT_MEDIA_FORMAT
                && validated.recoverable_sample_count != Some(sample_count))
        {
            return Err(StoreError::IntegrityMismatch(
                "managed import evidence does not match its file",
            ));
        }

        let (event_sequence, prior_digest) = next_database_event(&self.connection, session_id)?;
        let digest = event_digest(
            session_id,
            event_sequence,
            "media_imported",
            payload,
            prior_digest.as_deref(),
        )?;
        let now = wall_time_milliseconds();
        let transaction = self.connection.transaction()?;
        let lifecycle: String = transaction.query_row(
            "SELECT lifecycle FROM sessions WHERE id = ?1 AND origin = 'import'",
            [session_id],
            |row| row.get(0),
        )?;
        if lifecycle != "preparing" {
            return Err(StoreError::InvalidState(
                "import session is not awaiting managed media",
            ));
        }
        transaction.execute(
            "INSERT INTO sources (id, schema_version, session_id, kind, display_name, lifecycle)
             VALUES (?1, ?2, ?3, ?4, ?5, 'sealed')",
            params![
                source_id,
                SCHEMA_VERSION,
                session_id,
                IMPORT_SOURCE_KIND,
                payload_string(payload, "source_display_name")?
            ],
        )?;
        transaction.execute(
            "INSERT INTO tracks (id, schema_version, session_id, source_id, kind, lifecycle)
             VALUES (?1, ?2, ?3, ?4, 'audio', 'sealed')",
            params![track_id, SCHEMA_VERSION, session_id, source_id],
        )?;
        transaction.execute(
            "INSERT INTO segments (
                id, schema_version, session_id, track_id, sequence, relative_path,
                lifecycle, original_start, mapped_start_ns, media_format,
                sample_count, byte_length, digest, seal_state, recovery_state,
                open_token, writer_generation, file_device, file_inode
             ) VALUES (?1, ?2, ?3, ?4, 0, ?5, 'sealed', 0, 0, ?6,
                       ?7, ?8, ?9, 'sealed', 'not_required', NULL, 0, ?10, ?11)",
            params![
                segment_id,
                SCHEMA_VERSION,
                session_id,
                track_id,
                relative_path,
                media_format,
                sample_count as i64,
                byte_length as i64,
                digest_sha256,
                validated.device as i64,
                validated.inode as i64,
            ],
        )?;
        transaction.execute(
            "INSERT INTO imports (
                id, schema_version, session_id, relative_path, source_digest, created_at_ms
             ) VALUES (?1, ?2, ?3, ?4, ?5, ?6)",
            params![
                Uuid::now_v7().to_string(),
                SCHEMA_VERSION,
                session_id,
                relative_path,
                digest_sha256,
                now
            ],
        )?;
        insert_event_with_id(
            &transaction,
            &journal_record.body.event_id,
            session_id,
            event_sequence,
            "media_imported",
            journal_record.body.wall_time_milliseconds,
            payload,
            prior_digest.as_deref(),
            &digest,
        )?;
        transaction.execute(
            "UPDATE sessions
             SET lifecycle = 'ready_for_review', media_files_open = 0, updated_at_ms = ?2
             WHERE id = ?1 AND origin = 'import' AND lifecycle = 'preparing'",
            params![session_id, now],
        )?;
        transaction.commit()?;
        Ok(())
    }

    fn managed_import_track_directory(
        &self,
        session_id: &str,
        track_id: &str,
    ) -> Result<OwnedFd, StoreError> {
        let audio_directory = self.open_managed_audio_directory(session_id)?;
        open_managed_directory_at(&audio_directory, OsStr::new(track_id))
    }
}

fn interrupt_import_if(
    selected: Option<ImportFailurePoint>,
    current: ImportFailurePoint,
) -> Result<(), StoreError> {
    if selected == Some(current) {
        return Err(StoreError::IntegrityMismatch(
            "simulated managed import interruption",
        ));
    }
    Ok(())
}

pub(super) fn cleanup_stale_playback_snapshot_placeholders(
    managed_root: &Path,
) -> Result<(), StoreError> {
    cleanup_stale_playback_snapshot_placeholders_with_hook(managed_root, |_| {})
}

fn cleanup_stale_playback_snapshot_placeholders_with_hook(
    managed_root: &Path,
    mut after_inspection: impl FnMut(&Path),
) -> Result<(), StoreError> {
    // A crash can occur only after the empty file is created and before it is unlinked.
    // Atomically quarantine that zero-byte evidence instead of deleting by pathname: a
    // same-user replacement is restored and preserved, while a matched tombstone remains
    // recoverable evidence and is ignored by every library/media lookup.
    let managed_directory = open_managed_directory(managed_root)?;
    let mut quarantined = false;
    for entry in fs::read_dir(managed_root)? {
        let entry = entry?;
        let file_name = entry.file_name();
        let Some(name) = file_name.to_str() else {
            continue;
        };
        let Some(identifier) = name
            .strip_prefix(PLAYBACK_SNAPSHOT_PREFIX)
            .and_then(|value| value.strip_suffix(PLAYBACK_SNAPSHOT_SUFFIX))
        else {
            continue;
        };
        if Uuid::parse_str(identifier).is_err() {
            continue;
        }
        let inspected_fd = fd_fs::openat(
            &managed_directory,
            &file_name,
            fd_fs::OFlags::RDONLY | fd_fs::OFlags::CLOEXEC | fd_fs::OFlags::NOFOLLOW,
            fd_fs::Mode::empty(),
        )
        .map_err(|_| {
            StoreError::IntegrityMismatch("stale playback placeholder changed before recovery")
        })?;
        let inspected_stat = fd_fs::fstat(&inspected_fd).map_err(|_| {
            StoreError::IntegrityMismatch("stale playback placeholder identity is unavailable")
        })?;
        if fd_fs::FileType::from_raw_mode(inspected_stat.st_mode) != fd_fs::FileType::RegularFile
            || inspected_stat.st_size != 0
        {
            return Err(StoreError::IntegrityMismatch(
                "stale playback snapshot placeholder is not an empty regular file",
            ));
        }
        after_inspection(&entry.path());
        let quarantine_name = format!("{PLAYBACK_QUARANTINE_PREFIX}{}", Uuid::now_v7());
        fd_fs::renameat_with(
            &managed_directory,
            &file_name,
            &managed_directory,
            OsStr::new(&quarantine_name),
            fd_fs::RenameFlags::NOREPLACE,
        )
        .map_err(|_| {
            StoreError::IntegrityMismatch("stale playback placeholder could not be quarantined")
        })?;
        let quarantined_fd = fd_fs::openat(
            &managed_directory,
            OsStr::new(&quarantine_name),
            fd_fs::OFlags::RDONLY | fd_fs::OFlags::CLOEXEC | fd_fs::OFlags::NOFOLLOW,
            fd_fs::Mode::empty(),
        );
        let disposition = quarantined_fd.and_then(|fd| fd_fs::fstat(&fd));
        let identity_matches = disposition.is_ok_and(|stat| {
            stat.st_dev == inspected_stat.st_dev
                && stat.st_ino == inspected_stat.st_ino
                && stat.st_size == inspected_stat.st_size
                && fd_fs::FileType::from_raw_mode(stat.st_mode) == fd_fs::FileType::RegularFile
        });
        if !identity_matches {
            let _ = fd_fs::renameat_with(
                &managed_directory,
                OsStr::new(&quarantine_name),
                &managed_directory,
                &file_name,
                fd_fs::RenameFlags::NOREPLACE,
            );
            return Err(StoreError::IntegrityMismatch(
                "quarantined playback placeholder does not match the inspected object",
            ));
        }
        quarantined = true;
    }
    if quarantined {
        fd_fs::fsync(&managed_directory).map_err(|_| {
            StoreError::IntegrityMismatch("stale playback snapshot quarantine was not synchronized")
        })?;
    }
    Ok(())
}

fn validate_import_paths(payload: &Value) -> Result<ImportPaths, StoreError> {
    let source_id = payload_string(payload, "source_id")?;
    let track_id = payload_string(payload, "track_id")?;
    let segment_id = payload_string(payload, "segment_id")?;
    if [source_id, track_id, segment_id]
        .iter()
        .any(|value| Uuid::parse_str(value).is_err())
    {
        return Err(StoreError::IntegrityMismatch(
            "managed import identity is invalid",
        ));
    }
    let media_format = payload_string(payload, "media_format")?;
    if payload_string(payload, "source_kind")? != IMPORT_SOURCE_KIND
        || !matches!(
            media_format,
            IMPORT_MEDIA_FORMAT | COMPRESSED_IMPORT_MEDIA_FORMAT
        )
    {
        return Err(StoreError::IntegrityMismatch(
            "managed import kind or format is invalid",
        ));
    }
    let suffix = if media_format == COMPRESSED_IMPORT_MEDIA_FORMAT {
        "m4a"
    } else {
        "caf"
    };
    let staging_relative_path = format!("audio/{track_id}/.importing.{suffix}");
    let relative_path = format!("audio/{track_id}/000000-import.{suffix}");
    if payload_string(payload, "staging_relative_path")? != staging_relative_path
        || payload_string(payload, "relative_path")? != relative_path
    {
        return Err(StoreError::IntegrityMismatch(
            "managed import path is not the generated destination",
        ));
    }
    if media_format == IMPORT_MEDIA_FORMAT {
        validate_import_bounds(
            payload_u64(payload, "byte_length")?,
            payload_u64(payload, "sample_count")?,
        )?;
    } else {
        validate_compressed_import_bounds(
            payload_u64(payload, "byte_length")?,
            payload_u64(payload, "sample_count")?,
        )?;
    }
    let digest = payload_string(payload, "digest_sha256")?;
    if digest.len() != 64 || !digest.bytes().all(|byte| byte.is_ascii_hexdigit()) {
        return Err(StoreError::IntegrityMismatch(
            "managed import digest is invalid",
        ));
    }
    Ok(ImportPaths {
        track_id: track_id.to_owned(),
        relative_path,
        media_format: if media_format == COMPRESSED_IMPORT_MEDIA_FORMAT {
            COMPRESSED_IMPORT_MEDIA_FORMAT
        } else {
            IMPORT_MEDIA_FORMAT
        },
    })
}

fn managed_import_entry_exists(
    track_directory: &OwnedFd,
    name: &OsStr,
) -> Result<bool, StoreError> {
    let entry = match fd_fs::openat(
        track_directory,
        name,
        fd_fs::OFlags::RDONLY | fd_fs::OFlags::CLOEXEC | fd_fs::OFlags::NOFOLLOW,
        fd_fs::Mode::empty(),
    ) {
        Ok(entry) => entry,
        Err(error) if error == rustix::io::Errno::NOENT => return Ok(false),
        Err(_) => {
            return Err(StoreError::IntegrityMismatch(
                "managed import entry is missing, replaced, or symlinked",
            ));
        }
    };
    let stat = fd_fs::fstat(&entry)
        .map_err(|_| StoreError::IntegrityMismatch("managed import entry could not be read"))?;
    if fd_fs::FileType::from_raw_mode(stat.st_mode) != fd_fs::FileType::RegularFile {
        return Err(StoreError::IntegrityMismatch(
            "managed import entry is not a regular file",
        ));
    }
    Ok(true)
}

fn rename_import_entry(track_directory: &OwnedFd, media_format: &str) -> Result<(), StoreError> {
    let suffix = if media_format == COMPRESSED_IMPORT_MEDIA_FORMAT {
        "m4a"
    } else {
        "caf"
    };
    fd_fs::renameat_with(
        track_directory,
        OsStr::new(&format!(".importing.{suffix}")),
        track_directory,
        OsStr::new(&format!("000000-import.{suffix}")),
        fd_fs::RenameFlags::NOREPLACE,
    )
    .map_err(|_| StoreError::IntegrityMismatch("managed import rename could not be completed"))
}

fn validate_import_bounds(byte_length: u64, sample_count: u64) -> Result<(), StoreError> {
    if byte_length > MAX_IMPORT_BYTES {
        return Err(StoreError::ImportSizeLimit);
    }
    if byte_length < CAF_HEADER.len() as u64 {
        return Err(StoreError::InvalidRequest(
            "import source is too short to be a CAF",
        ));
    }
    if sample_count > MAX_IMPORT_SAMPLES {
        return Err(StoreError::ImportDurationLimit);
    }
    if sample_count == 0 {
        return Err(StoreError::InvalidRequest(
            "import source contains no audio samples",
        ));
    }
    Ok(())
}

fn validate_compressed_import_bounds(
    byte_length: u64,
    sample_count: u64,
) -> Result<(), StoreError> {
    if byte_length > MAX_COMPRESSED_IMPORT_BYTES {
        return Err(StoreError::ImportSizeLimit);
    }
    if byte_length < 12 || sample_count == 0 {
        return Err(StoreError::InvalidRequest(
            "compressed import has no supported audio",
        ));
    }
    if sample_count > MAX_IMPORT_SAMPLES {
        return Err(StoreError::ImportDurationLimit);
    }
    Ok(())
}

fn has_m4a_file_type(file: &mut File) -> Result<bool, StoreError> {
    file.rewind()?;
    let mut header = [0_u8; 12];
    file.read_exact(&mut header)?;
    Ok(&header[4..8] == b"ftyp" && matches!(&header[8..12], b"M4A " | b"mp42" | b"isom"))
}

fn validate_compressed_import_source(
    path: &Path,
    metadata: &CompressedImportMetadata,
) -> Result<ValidatedImportSource, StoreError> {
    if path.as_os_str().is_empty() || fs::symlink_metadata(path)?.file_type().is_symlink() {
        return Err(StoreError::InvalidRequest(
            "compressed import must be a regular file",
        ));
    }
    let fd = fd_fs::open(
        path,
        fd_fs::OFlags::RDONLY | fd_fs::OFlags::CLOEXEC | fd_fs::OFlags::NOFOLLOW,
        fd_fs::Mode::empty(),
    )
    .map_err(|_| StoreError::InvalidRequest("compressed import could not be opened safely"))?;
    let mut file = File::from(fd);
    let stat = fd_fs::fstat(&file)
        .map_err(|_| StoreError::IntegrityMismatch("compressed source identity is unavailable"))?;
    if fd_fs::FileType::from_raw_mode(stat.st_mode) != fd_fs::FileType::RegularFile {
        return Err(StoreError::InvalidRequest(
            "compressed import must be a regular file",
        ));
    }
    let byte_length = u64::try_from(stat.st_size)
        .map_err(|_| StoreError::InvalidRequest("compressed source length is invalid"))?;
    validate_compressed_import_bounds(byte_length, metadata.sample_count)?;
    if byte_length != metadata.original.byte_length || !has_m4a_file_type(&mut file)? {
        return Err(StoreError::InvalidRequest(
            "compressed source does not match its M4A probe",
        ));
    }
    file.rewind()?;
    let mut hasher = Sha256::new();
    let mut buffer = [0_u8; 64 * 1024];
    loop {
        let read = file.read(&mut buffer)?;
        if read == 0 {
            break;
        }
        hasher.update(&buffer[..read]);
    }
    revalidate_stat(&file, stat.st_dev as u64, stat.st_ino as u64, byte_length)?;
    let digest_sha256 = format!("{:x}", hasher.finalize());
    if digest_sha256 != metadata.digest_sha256 {
        return Err(StoreError::IntegrityMismatch(
            "compressed source changed since its native decode probe",
        ));
    }
    Ok(ValidatedImportSource {
        file,
        byte_length,
        sample_count: metadata.sample_count,
        digest_sha256,
        device: stat.st_dev as u64,
        inode: stat.st_ino as u64,
    })
}

impl SessionStore {
    pub(super) fn validate_import_media_file(
        &self,
        session_id: &str,
        relative_path: &str,
        byte_length: u64,
        media_format: &str,
        calculate_digest: bool,
    ) -> Result<ValidatedMediaFile, StoreError> {
        if media_format == IMPORT_MEDIA_FORMAT {
            return self.validate_media_file(
                session_id,
                relative_path,
                MediaLengthRequirement::Exact(byte_length),
                true,
            );
        }
        if media_format != COMPRESSED_IMPORT_MEDIA_FORMAT
            || !relative_path.starts_with("audio/")
            || !relative_path.ends_with(".m4a")
            || Path::new(relative_path).components().count() != 3
        {
            return Err(StoreError::IntegrityMismatch(
                "compressed import path or format is invalid",
            ));
        }
        validate_compressed_import_bounds(byte_length, 1)?;
        let parts: Vec<_> = Path::new(relative_path).components().collect();
        let [
            std::path::Component::Normal(audio),
            std::path::Component::Normal(track),
            std::path::Component::Normal(name),
        ] = parts.as_slice()
        else {
            return Err(StoreError::IntegrityMismatch(
                "compressed import path is invalid",
            ));
        };
        if audio != &OsStr::new("audio")
            || (name != &OsStr::new(".importing.m4a") && name != &OsStr::new("000000-import.m4a"))
        {
            return Err(StoreError::IntegrityMismatch(
                "compressed import destination is invalid",
            ));
        }
        let audio_directory = self.open_managed_audio_directory(session_id)?;
        let track_directory = open_managed_directory_at(&audio_directory, track)?;
        let fd = fd_fs::openat(
            &track_directory,
            *name,
            fd_fs::OFlags::RDONLY | fd_fs::OFlags::CLOEXEC | fd_fs::OFlags::NOFOLLOW,
            fd_fs::Mode::empty(),
        )
        .map_err(|_| {
            StoreError::IntegrityMismatch("compressed managed media is missing or replaced")
        })?;
        let mut file = File::from(fd);
        let stat = fd_fs::fstat(&file).map_err(|_| {
            StoreError::IntegrityMismatch("compressed managed media identity is unavailable")
        })?;
        let identity = sealed_media_identity::media_identity(&file)?;
        if identity.0 != stat.st_dev as u64
            || identity.1 != stat.st_ino as u64
            || identity.2 != byte_length
        {
            return Err(StoreError::IntegrityMismatch(
                "compressed media changed before hashing",
            ));
        }
        if fd_fs::FileType::from_raw_mode(stat.st_mode) != fd_fs::FileType::RegularFile
            || stat.st_size != byte_length as i64
            || !has_m4a_file_type(&mut file)?
        {
            return Err(StoreError::IntegrityMismatch(
                "compressed managed media format or length changed",
            ));
        }
        file.rewind()?;
        let mut hasher = Sha256::new();
        let mut buffer = vec![0_u8; 1024 * 1024];
        let mut remaining = if calculate_digest { byte_length } else { 0 };
        while remaining > 0 {
            let read_limit = usize::try_from(remaining.min(buffer.len() as u64)).unwrap();
            let read = file.read(&mut buffer[..read_limit])?;
            if read == 0 {
                return Err(StoreError::IntegrityMismatch(
                    "compressed managed media ended early",
                ));
            }
            hasher.update(&buffer[..read]);
            remaining -= read as u64;
        }
        if calculate_digest && file.read(&mut buffer[..1])? != 0 {
            return Err(StoreError::IntegrityMismatch(
                "compressed managed media grew",
            ));
        }
        if calculate_digest {
            self.digest_memo.borrow_mut().computed();
        }
        #[cfg(test)]
        self.run_media_validation_hook();
        if sealed_media_identity::media_identity(&file)? != identity {
            return Err(StoreError::IntegrityMismatch(
                "compressed media changed during hashing",
            ));
        }
        let current_audio = self.open_managed_audio_directory(session_id)?;
        let current_track = open_managed_directory_at(&current_audio, track)?;
        let rebound = fd_fs::openat(
            &current_track,
            *name,
            fd_fs::OFlags::RDONLY | fd_fs::OFlags::CLOEXEC | fd_fs::OFlags::NOFOLLOW,
            fd_fs::Mode::empty(),
        )
        .map_err(|_| {
            StoreError::IntegrityMismatch("compressed managed media changed during validation")
        })?;
        let after = fd_fs::fstat(&rebound).map_err(|_| {
            StoreError::IntegrityMismatch("compressed managed media identity changed")
        })?;
        if after.st_dev != stat.st_dev
            || after.st_ino != stat.st_ino
            || after.st_size != stat.st_size
            || sealed_media_identity::media_identity(&File::from(rebound))? != identity
        {
            return Err(StoreError::IntegrityMismatch(
                "compressed managed media was replaced",
            ));
        }
        file.rewind()?;
        Ok(ValidatedMediaFile {
            file,
            identity,
            byte_length,
            device: stat.st_dev as u64,
            inode: stat.st_ino as u64,
            digest_sha256: calculate_digest.then(|| format!("{:x}", hasher.finalize())),
            recoverable_sample_count: None,
            channels: None,
        })
    }
}

fn validate_import_source(path: &Path) -> Result<ValidatedImportSource, StoreError> {
    if path.as_os_str().is_empty() {
        return Err(StoreError::InvalidRequest("import path is empty"));
    }
    let metadata = fs::symlink_metadata(path)?;
    if metadata.file_type().is_symlink() || !metadata.is_file() {
        return Err(StoreError::InvalidRequest(
            "import source must be a regular file, not a symlink",
        ));
    }
    let source_fd = fd_fs::open(
        path,
        fd_fs::OFlags::RDONLY | fd_fs::OFlags::CLOEXEC | fd_fs::OFlags::NOFOLLOW,
        fd_fs::Mode::empty(),
    )
    .map_err(|_| StoreError::InvalidRequest("import source could not be opened safely"))?;
    let mut file = File::from(source_fd);
    let stat = fd_fs::fstat(&file)
        .map_err(|_| StoreError::IntegrityMismatch("import source identity could not be read"))?;
    if fd_fs::FileType::from_raw_mode(stat.st_mode) != fd_fs::FileType::RegularFile {
        return Err(StoreError::InvalidRequest(
            "import source is not a regular file",
        ));
    }
    let byte_length = u64::try_from(stat.st_size)
        .map_err(|_| StoreError::InvalidRequest("import source length is invalid"))?;
    validate_import_bounds(byte_length, 1)?;
    let mut header = [0_u8; 8];
    file.read_exact(&mut header)?;
    if &header != CAF_HEADER {
        return Err(StoreError::InvalidRequest(
            "import source is not a supported CAF file",
        ));
    }
    file.rewind()?;
    let inspection = inspect_pcm_caf(&mut file, byte_length)?.ok_or(StoreError::InvalidRequest(
        "import source is not recoverable mono PCM CAF",
    ))?;
    let sample_count = inspection
        .sample_count
        .filter(|_| inspection.channels == 1)
        .ok_or(StoreError::InvalidRequest(
            "import source is not recoverable mono PCM CAF",
        ))?;
    validate_import_bounds(byte_length, sample_count)?;
    file.rewind()?;
    let mut hasher = Sha256::new();
    let mut buffer = [0_u8; 64 * 1024];
    loop {
        let read = file.read(&mut buffer)?;
        if read == 0 {
            break;
        }
        hasher.update(&buffer[..read]);
    }
    revalidate_stat(&file, stat.st_dev as u64, stat.st_ino as u64, byte_length)?;
    Ok(ValidatedImportSource {
        file,
        byte_length,
        sample_count,
        digest_sha256: format!("{:x}", hasher.finalize()),
        device: stat.st_dev as u64,
        inode: stat.st_ino as u64,
    })
}

fn revalidate_import_source(source: &ValidatedImportSource) -> Result<(), StoreError> {
    revalidate_stat(
        &source.file,
        source.device,
        source.inode,
        source.byte_length,
    )
}

fn revalidate_stat(
    file: &File,
    expected_device: u64,
    expected_inode: u64,
    expected_length: u64,
) -> Result<(), StoreError> {
    let stat = fd_fs::fstat(file)
        .map_err(|_| StoreError::IntegrityMismatch("import source could not be revalidated"))?;
    if stat.st_dev as u64 != expected_device
        || stat.st_ino as u64 != expected_inode
        || stat.st_size as u64 != expected_length
    {
        return Err(StoreError::IntegrityMismatch(
            "import source changed during admission",
        ));
    }
    Ok(())
}

#[cfg(test)]
#[path = "import_tests.rs"]
mod tests;
