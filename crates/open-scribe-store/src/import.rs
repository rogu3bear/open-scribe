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
    RecoveryDisposition, SCHEMA_VERSION, SessionOrigin, SessionStore, StoreError, event_digest,
    insert_event_with_id, inspect_recoverable_pcm_caf, next_database_event, open_managed_directory,
    open_managed_directory_at, payload_string, payload_u64, validate_request,
    wall_time_milliseconds,
};

const MAX_IMPORTED_PLAYBACK_SNAPSHOT_BYTES: u64 = 256 * 1024 * 1024;
const MAX_IMPORT_BYTES: u64 = MAX_IMPORTED_PLAYBACK_SNAPSHOT_BYTES;
const MAX_IMPORT_SAMPLES: u64 = 4 * 60 * 60 * 48_000;
const IMPORT_SOURCE_KIND: &str = "imported_audio";
const IMPORT_MEDIA_FORMAT: &str = "caf-pcm-s16le";
const PLAYBACK_SNAPSHOT_PREFIX: &str = ".playback-";
const PLAYBACK_SNAPSHOT_SUFFIX: &str = ".caf";
const PLAYBACK_QUARANTINE_PREFIX: &str = ".playback-recovery-";

/// One already user-authorized local file to copy into the managed conversation library.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ImportMediaRequest {
    pub title: String,
    pub source_path: PathBuf,
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
/// the full decoder lifetime. Imported playback copies the bounded object into anonymous memory;
/// recovered playback verifies bounded chunks again whenever AudioToolbox reads them. The
/// descriptor keeps the identity-bound managed object open and is never represented to the native
/// adapter by a pathname.
pub struct ImportedPlaybackLease {
    file: File,
    byte_length: u64,
    digest_sha256: String,
}

impl ImportedPlaybackLease {
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
    pub const fn maximum_snapshot_byte_length() -> u64 {
        MAX_IMPORTED_PLAYBACK_SNAPSHOT_BYTES
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
        self.import_recoverable_caf_inner(request, None)
    }

    fn import_recoverable_caf_inner(
        &mut self,
        request: ImportMediaRequest,
        failure: Option<ImportFailurePoint>,
    ) -> Result<ImportedMediaEvidence, StoreError> {
        validate_request(&PrepareSessionRequest {
            title: request.title.clone(),
            origin: SessionOrigin::Import,
        })?;
        let mut source = validate_import_source(&request.source_path)?;
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
            let staging_relative_path = format!("audio/{track_id}/.importing.caf");
            let relative_path = format!("audio/{track_id}/000000-import.caf");
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
                OsStr::new(".importing.caf"),
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

            let staged = self.validate_media_file(
                &prepared.session_id.0,
                &staging_relative_path,
                MediaLengthRequirement::Exact(source.byte_length),
                true,
            )?;
            if staged.digest_sha256.as_deref() != Some(source.digest_sha256.as_str())
                || staged.recoverable_sample_count != Some(source.sample_count)
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
                "source_display_name": request.source_path.file_name().and_then(OsStr::to_str).unwrap_or("Imported audio"),
                "track_id": track_id,
                "segment_id": segment_id,
                "staging_relative_path": staging_relative_path,
                "relative_path": relative_path,
                "media_format": IMPORT_MEDIA_FORMAT,
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

            rename_import_entry(&track_directory)?;
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
                        segments.file_device, segments.file_inode
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
                   AND segments.media_format = 'caf-pcm-s16le'
                   AND (
                     (sessions.origin = 'import'
                      AND segments.relative_path = imports.relative_path)
                     OR
                     (sessions.origin = 'capture'
                      AND sessions.health = 'healthy'
                      AND segments.recovery_state = 'not_required'
                      AND NOT EXISTS (
                        SELECT 1 FROM recovery_runs
                        WHERE recovery_runs.session_id = sessions.id
                          AND recovery_runs.disposition = 'playable_media_recovered'
                      ))
                   )
                 ORDER BY CASE sources.kind
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
        ) = &rows[0];
        let sample_count = u64::try_from(*stored_sample_count)
            .map_err(|_| StoreError::IntegrityMismatch("managed sample count is invalid"))?;
        let byte_length = u64::try_from(*stored_byte_length)
            .map_err(|_| StoreError::IntegrityMismatch("managed byte length is invalid"))?;
        if byte_length > MAX_IMPORTED_PLAYBACK_SNAPSHOT_BYTES {
            return Err(StoreError::InvalidState(
                "managed media exceeds the safe playback snapshot limit",
            ));
        }
        if segment_digest != import_digest {
            return Err(StoreError::IntegrityMismatch(
                "managed media receipt and segment digest disagree",
            ));
        }
        let mut validated = self.validate_media_file(
            &session_id.0,
            relative_path,
            MediaLengthRequirement::Exact(byte_length),
            true,
        )?;
        if validated.device != u64::try_from(*stored_device).unwrap_or(0)
            || validated.inode != u64::try_from(*stored_inode).unwrap_or(0)
            || validated.recoverable_sample_count != Some(sample_count)
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
        let row = self
            .connection
            .query_row(
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
               AND EXISTS (
                   SELECT 1 FROM session_events recovery_events
                   WHERE recovery_events.session_id = sessions.id
                     AND recovery_events.event_kind = 'playable_media_recovered'
               )
               AND EXISTS (
                   SELECT 1 FROM recovery_runs
                   WHERE recovery_runs.session_id = sessions.id
                     AND recovery_runs.disposition = 'playable_media_recovered'
               )",
                params![&session_id.0, source_id, track_id, segment_id],
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
        if validated.device != u64::try_from(stored_device).unwrap_or(0)
            || validated.inode != u64::try_from(stored_inode).unwrap_or(0)
            || validated.recoverable_sample_count != Some(sample_count)
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
        if !managed_import_entry_exists(&track_directory, OsStr::new("000000-import.caf"))? {
            if !managed_import_entry_exists(&track_directory, OsStr::new(".importing.caf"))? {
                return self.tombstone_import(session_id, "staged_media_missing");
            }
            rename_import_entry(&track_directory)?;
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
        if track_entries.len() > 1
            || track_entries
                .first()
                .is_some_and(|entry| entry.file_name() != OsStr::new(".importing.caf"))
        {
            return Err(StoreError::IntegrityMismatch(
                "unstaged import track contains unexpected media",
            ));
        }

        if let Some(intent) = intents.first() {
            let payload = &intent.body.payload;
            if payload_string(payload, "track_id")? != track_id
                || payload_string(payload, "staging_relative_path")?
                    != format!("audio/{track_id}/.importing.caf")
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
                OsStr::new(".importing.caf"),
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
                OsStr::new(".importing.caf"),
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
        let validated = self.validate_media_file(
            session_id,
            relative_path,
            MediaLengthRequirement::Exact(byte_length),
            true,
        )?;
        if validated.digest_sha256.as_deref() != Some(digest_sha256)
            || validated.recoverable_sample_count != Some(sample_count)
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
                IMPORT_MEDIA_FORMAT,
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
    if payload_string(payload, "source_kind")? != IMPORT_SOURCE_KIND
        || payload_string(payload, "media_format")? != IMPORT_MEDIA_FORMAT
    {
        return Err(StoreError::IntegrityMismatch(
            "managed import kind or format is invalid",
        ));
    }
    let staging_relative_path = format!("audio/{track_id}/.importing.caf");
    let relative_path = format!("audio/{track_id}/000000-import.caf");
    if payload_string(payload, "staging_relative_path")? != staging_relative_path
        || payload_string(payload, "relative_path")? != relative_path
    {
        return Err(StoreError::IntegrityMismatch(
            "managed import path is not the generated destination",
        ));
    }
    validate_import_bounds(
        payload_u64(payload, "byte_length")?,
        payload_u64(payload, "sample_count")?,
    )?;
    let digest = payload_string(payload, "digest_sha256")?;
    if digest.len() != 64 || !digest.bytes().all(|byte| byte.is_ascii_hexdigit()) {
        return Err(StoreError::IntegrityMismatch(
            "managed import digest is invalid",
        ));
    }
    Ok(ImportPaths {
        track_id: track_id.to_owned(),
        relative_path,
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

fn rename_import_entry(track_directory: &OwnedFd) -> Result<(), StoreError> {
    fd_fs::renameat_with(
        track_directory,
        OsStr::new(".importing.caf"),
        track_directory,
        OsStr::new("000000-import.caf"),
        fd_fs::RenameFlags::NOREPLACE,
    )
    .map_err(|_| StoreError::IntegrityMismatch("managed import rename could not be completed"))
}

fn validate_import_bounds(byte_length: u64, sample_count: u64) -> Result<(), StoreError> {
    if byte_length < CAF_HEADER.len() as u64 || byte_length > MAX_IMPORT_BYTES {
        return Err(StoreError::InvalidRequest(
            "import source exceeds the CAF size bounds",
        ));
    }
    if sample_count == 0 || sample_count > MAX_IMPORT_SAMPLES {
        return Err(StoreError::InvalidRequest(
            "import source exceeds the CAF duration bounds",
        ));
    }
    Ok(())
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
    let sample_count = inspect_recoverable_pcm_caf(&mut file, byte_length)?.ok_or(
        StoreError::InvalidRequest("import source is not recoverable mono PCM CAF"),
    )?;
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
mod tests {
    use std::fs::OpenOptions;
    use std::io::{SeekFrom, Write};
    use std::os::unix::fs::{MetadataExt, symlink};

    use tempfile::TempDir;

    use super::*;
    use crate::RuntimePlayableMediaAvailability;

    fn write_recoverable_caf(path: &Path, sample_count: u64) {
        let mut file = File::create(path).unwrap();
        file.write_all(CAF_HEADER).unwrap();
        file.write_all(b"desc").unwrap();
        file.write_all(&32_i64.to_be_bytes()).unwrap();
        file.write_all(&48_000_f64.to_bits().to_be_bytes()).unwrap();
        file.write_all(b"lpcm").unwrap();
        file.write_all(&2_u32.to_be_bytes()).unwrap();
        file.write_all(&2_u32.to_be_bytes()).unwrap();
        file.write_all(&1_u32.to_be_bytes()).unwrap();
        file.write_all(&1_u32.to_be_bytes()).unwrap();
        file.write_all(&16_u32.to_be_bytes()).unwrap();
        file.write_all(b"data").unwrap();
        file.write_all(&(-1_i64).to_be_bytes()).unwrap();
        file.write_all(&0_u32.to_be_bytes()).unwrap();
        file.write_all(&vec![0_u8; sample_count as usize * 2])
            .unwrap();
        file.sync_all().unwrap();
    }

    fn write_sparse_recoverable_caf(path: &Path, sample_count: u64) {
        let mut file = File::create(path).unwrap();
        file.write_all(CAF_HEADER).unwrap();
        file.write_all(b"desc").unwrap();
        file.write_all(&32_i64.to_be_bytes()).unwrap();
        file.write_all(&48_000_f64.to_bits().to_be_bytes()).unwrap();
        file.write_all(b"lpcm").unwrap();
        file.write_all(&2_u32.to_be_bytes()).unwrap();
        file.write_all(&2_u32.to_be_bytes()).unwrap();
        file.write_all(&1_u32.to_be_bytes()).unwrap();
        file.write_all(&1_u32.to_be_bytes()).unwrap();
        file.write_all(&16_u32.to_be_bytes()).unwrap();
        file.write_all(b"data").unwrap();
        file.write_all(&(-1_i64).to_be_bytes()).unwrap();
        file.write_all(&0_u32.to_be_bytes()).unwrap();
        file.set_len(68 + sample_count * 2).unwrap();
        file.sync_all().unwrap();
    }

    #[test]
    fn managed_caf_import_preserves_original_and_enters_the_existing_library() {
        let temp = TempDir::new().unwrap();
        let source_path = temp.path().join("donella-review.caf");
        write_recoverable_caf(&source_path, 960);
        let original = fs::read(&source_path).unwrap();
        let mut store = SessionStore::open(temp.path().join("Open Scribe")).unwrap();

        let evidence = store
            .import_recoverable_caf(ImportMediaRequest {
                title: "Donella review".to_owned(),
                source_path: source_path.clone(),
            })
            .unwrap();

        assert!(evidence.ready_for_review);
        assert!(evidence.original_untouched);
        assert_eq!(evidence.sample_count, 960);
        assert_eq!(evidence.digest_sha256.len(), 64);
        assert_eq!(fs::read(&source_path).unwrap(), original);
        assert_eq!(
            fs::read(
                store
                    .session_directory(&evidence.session_id.0)
                    .unwrap()
                    .join(&evidence.relative_path)
            )
            .unwrap(),
            original
        );
        let snapshot = store.runtime_library_snapshot().unwrap();
        assert!(snapshot.current_session.is_none());
        assert_eq!(snapshot.saved_sessions.len(), 1);
        assert_eq!(snapshot.saved_sessions[0].session_id, evidence.session_id);
        assert_eq!(snapshot.saved_sessions[0].title, "Donella review");
        let playable = snapshot.saved_sessions[0].playable_media.as_ref().unwrap();
        assert_eq!(playable.source_display_name, "donella-review.caf");
        assert_eq!(
            playable.availability,
            RuntimePlayableMediaAvailability::Available
        );
        assert_eq!(playable.sample_count, 960);
        assert_eq!(playable.duration_nanoseconds, 20_000_000);
        assert!(playable.absolute_path.is_none());
        assert_eq!(
            store
                .connection
                .query_row(
                    "SELECT COUNT(*) FROM imports WHERE session_id = ?1",
                    [&evidence.session_id.0],
                    |row| row.get::<_, i64>(0)
                )
                .unwrap(),
            1
        );
        assert_eq!(
            store
                .connection
                .query_row(
                    "SELECT COUNT(*) FROM session_events
                     WHERE session_id = ?1 AND event_kind = 'recording_started'",
                    [&evidence.session_id.0],
                    |row| row.get::<_, i64>(0)
                )
                .unwrap(),
            0
        );
    }

    #[test]
    fn imported_library_playback_fails_closed_when_managed_media_is_missing_or_corrupt() {
        let temp = TempDir::new().unwrap();
        let managed_root = temp.path().join("Open Scribe");
        let mut store = SessionStore::open(&managed_root).unwrap();

        let missing_source = temp.path().join("missing-later.caf");
        write_recoverable_caf(&missing_source, 48_000);
        let missing = store
            .import_recoverable_caf(ImportMediaRequest {
                title: "Missing later".to_owned(),
                source_path: missing_source,
            })
            .unwrap();
        fs::remove_file(
            store
                .session_directory(&missing.session_id.0)
                .unwrap()
                .join(&missing.relative_path),
        )
        .unwrap();

        let corrupt_source = temp.path().join("corrupt-later.caf");
        write_recoverable_caf(&corrupt_source, 96_000);
        let corrupt = store
            .import_recoverable_caf(ImportMediaRequest {
                title: "Corrupt later".to_owned(),
                source_path: corrupt_source,
            })
            .unwrap();
        let corrupt_path = store
            .session_directory(&corrupt.session_id.0)
            .unwrap()
            .join(&corrupt.relative_path);
        let mut corrupt_file = fs::OpenOptions::new()
            .write(true)
            .open(&corrupt_path)
            .unwrap();
        corrupt_file.seek(std::io::SeekFrom::Start(68)).unwrap();
        corrupt_file.write_all(&[1]).unwrap();
        corrupt_file.sync_all().unwrap();
        drop(corrupt_file);
        let replacement_digest = format!("{:x}", Sha256::digest(fs::read(&corrupt_path).unwrap()));
        store
            .connection
            .execute(
                "UPDATE segments SET digest = ?2 WHERE session_id = ?1",
                params![&corrupt.session_id.0, replacement_digest],
            )
            .unwrap();

        let snapshot = store.runtime_library_snapshot().unwrap();
        let missing_playback = snapshot
            .saved_sessions
            .iter()
            .find(|session| session.session_id == missing.session_id)
            .unwrap()
            .playable_media
            .as_ref()
            .unwrap();
        assert_eq!(
            missing_playback.availability,
            RuntimePlayableMediaAvailability::Unavailable
        );
        assert!(missing_playback.absolute_path.is_none());
        assert_eq!(missing_playback.duration_nanoseconds, 1_000_000_000);

        let corrupt_playback = snapshot
            .saved_sessions
            .iter()
            .find(|session| session.session_id == corrupt.session_id)
            .unwrap()
            .playable_media
            .as_ref()
            .unwrap();
        assert_eq!(
            corrupt_playback.availability,
            RuntimePlayableMediaAvailability::Corrupt
        );
        assert!(corrupt_playback.absolute_path.is_none());
        assert_eq!(corrupt_playback.duration_nanoseconds, 2_000_000_000);
    }

    #[test]
    fn imported_playback_lease_retains_the_validated_object_across_path_replacement() {
        let temp = TempDir::new().unwrap();
        let source_path = temp.path().join("leased.caf");
        write_recoverable_caf(&source_path, 48_000);
        let original = fs::read(&source_path).unwrap();
        let mut store = SessionStore::open(temp.path().join("Open Scribe")).unwrap();
        let imported = store
            .import_recoverable_caf(ImportMediaRequest {
                title: "Leased import".to_owned(),
                source_path,
            })
            .unwrap();
        let lease = store.lease_imported_playback(&imported.session_id).unwrap();
        let managed_path = store
            .session_directory(&imported.session_id.0)
            .unwrap()
            .join(&imported.relative_path);

        fs::remove_file(&managed_path).unwrap();
        write_recoverable_caf(&managed_path, 96_000);

        let mut leased_file = lease.file.try_clone().unwrap();
        let mut leased_bytes = Vec::new();
        leased_file.read_to_end(&mut leased_bytes).unwrap();
        assert_eq!(leased_bytes, original);
        assert_eq!(lease.byte_length(), original.len() as u64);
        assert_eq!(lease.digest_sha256(), imported.digest_sha256);
        assert_eq!(
            ImportedPlaybackLease::maximum_snapshot_byte_length(),
            MAX_IMPORTED_PLAYBACK_SNAPSHOT_BYTES
        );
        assert_ne!(fs::read(managed_path).unwrap(), original);
        assert!(store.lease_imported_playback(&imported.session_id).is_err());
    }

    #[test]
    fn imported_playback_lease_preserves_admitted_digest_for_native_copy_validation() {
        let temp = TempDir::new().unwrap();
        let source_path = temp.path().join("same-inode.caf");
        write_recoverable_caf(&source_path, 48_000);
        let original = fs::read(&source_path).unwrap();
        let managed_root = temp.path().join("Open Scribe");
        let mut store = SessionStore::open(&managed_root).unwrap();
        let imported = store
            .import_recoverable_caf(ImportMediaRequest {
                title: "Same inode import".to_owned(),
                source_path,
            })
            .unwrap();
        let lease = store.lease_imported_playback(&imported.session_id).unwrap();
        let managed_path = store
            .session_directory(&imported.session_id.0)
            .unwrap()
            .join(&imported.relative_path);
        let before = fs::metadata(&managed_path).unwrap();

        let mut managed = OpenOptions::new().write(true).open(&managed_path).unwrap();
        managed.seek(SeekFrom::End(-1)).unwrap();
        managed.write_all(&[1]).unwrap();
        managed.sync_all().unwrap();
        let after = fs::metadata(&managed_path).unwrap();

        assert_eq!(after.dev(), before.dev());
        assert_eq!(after.ino(), before.ino());
        assert_eq!(after.len(), before.len());
        assert_ne!(fs::read(&managed_path).unwrap(), original);
        let mut leased_file = lease.file.try_clone().unwrap();
        let mut changed_bytes = Vec::new();
        leased_file.read_to_end(&mut changed_bytes).unwrap();
        assert_ne!(changed_bytes, original);
        assert_ne!(
            format!("{:x}", Sha256::digest(&changed_bytes)),
            lease.digest_sha256()
        );
        assert_eq!(lease.byte_length(), original.len() as u64);
        assert_eq!(lease.digest_sha256(), imported.digest_sha256);
        assert!(store.lease_imported_playback(&imported.session_id).is_err());
        assert!(fs::read_dir(&managed_root).unwrap().all(|entry| {
            !entry
                .unwrap()
                .file_name()
                .to_string_lossy()
                .starts_with(PLAYBACK_SNAPSHOT_PREFIX)
        }));
    }

    #[test]
    fn imported_playback_lease_rejects_over_cap_evidence_before_media_revalidation() {
        let temp = TempDir::new().unwrap();
        let source_path = temp.path().join("over-cap-lease.caf");
        write_recoverable_caf(&source_path, 48_000);
        let mut store = SessionStore::open(temp.path().join("Open Scribe")).unwrap();
        let imported = store
            .import_recoverable_caf(ImportMediaRequest {
                title: "Over-cap playback lease".to_owned(),
                source_path,
            })
            .unwrap();
        let managed_path = store
            .session_directory(&imported.session_id.0)
            .unwrap()
            .join(&imported.relative_path);
        store
            .connection
            .execute(
                "UPDATE segments SET byte_length = ?2 WHERE session_id = ?1",
                params![
                    &imported.session_id.0,
                    i64::try_from(MAX_IMPORTED_PLAYBACK_SNAPSHOT_BYTES + 1).unwrap()
                ],
            )
            .unwrap();
        fs::remove_file(managed_path).unwrap();

        assert!(matches!(
            store.lease_imported_playback(&imported.session_id),
            Err(StoreError::InvalidState(
                "managed media exceeds the safe playback snapshot limit"
            ))
        ));
    }

    #[test]
    fn p1_import_failure_before_durable_stage_is_tombstoned_and_not_visible() {
        let temp = TempDir::new().unwrap();
        let source_path = temp.path().join("early-failure.caf");
        write_recoverable_caf(&source_path, 48_000);
        let managed_root = temp.path().join("Open Scribe");
        let mut store = SessionStore::open(&managed_root).unwrap();

        assert!(
            store
                .import_recoverable_caf_inner(
                    ImportMediaRequest {
                        title: "Failed import".to_owned(),
                        source_path,
                    },
                    Some(ImportFailurePoint::PreparationDurable),
                )
                .is_err()
        );

        let snapshot = store.runtime_library_snapshot().unwrap();
        assert!(snapshot.current_session.is_none());
        assert!(snapshot.saved_sessions.is_empty());
        let (lifecycle, health, failures): (String, String, i64) = store
            .connection
            .query_row(
                "SELECT sessions.lifecycle, sessions.health,
                        COUNT(session_events.id)
                 FROM sessions
                 LEFT JOIN session_events ON session_events.session_id = sessions.id
                                               AND session_events.event_kind = 'media_import_failed'
                 WHERE sessions.origin = 'import'",
                [],
                |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?)),
            )
            .unwrap();
        assert_eq!(lifecycle, "deleted");
        assert_eq!(health, "degraded");
        assert_eq!(failures, 1);

        drop(store);
        let mut reopened = SessionStore::open(managed_root).unwrap();
        assert!(reopened.recover_playable_sessions().unwrap().is_empty());
        let snapshot = reopened.runtime_library_snapshot().unwrap();
        assert!(snapshot.current_session.is_none());
        assert!(snapshot.saved_sessions.is_empty());
    }

    #[test]
    fn prestage_copy_failure_cleans_managed_bytes_before_tombstone() {
        let temp = TempDir::new().unwrap();
        let source_path = temp.path().join("copied-before-failure.caf");
        write_recoverable_caf(&source_path, 48_000);
        let original = fs::read(&source_path).unwrap();
        let managed_root = temp.path().join("Open Scribe");
        let mut store = SessionStore::open(&managed_root).unwrap();

        assert!(
            store
                .import_recoverable_caf_inner(
                    ImportMediaRequest {
                        title: "Cleaned import".to_owned(),
                        source_path: source_path.clone(),
                    },
                    Some(ImportFailurePoint::ManagedCopyComplete),
                )
                .is_err()
        );

        assert_eq!(fs::read(&source_path).unwrap(), original);
        let (session_id, lifecycle, health): (String, String, String) = store
            .connection
            .query_row(
                "SELECT id, lifecycle, health FROM sessions WHERE origin = 'import'",
                [],
                |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?)),
            )
            .unwrap();
        assert_eq!(lifecycle, "deleted");
        assert_eq!(health, "degraded");
        assert_eq!(
            fs::read_dir(store.session_directory(&session_id).unwrap().join("audio"))
                .unwrap()
                .count(),
            0
        );
        assert!(
            store
                .runtime_library_snapshot()
                .unwrap()
                .saved_sessions
                .is_empty()
        );
    }

    #[test]
    fn p1_staged_import_failure_reconciles_to_ready_instead_of_reporting_no_add() {
        let temp = TempDir::new().unwrap();
        let source_path = temp.path().join("staged-failure.caf");
        write_recoverable_caf(&source_path, 48_000);
        let mut store = SessionStore::open(temp.path().join("Open Scribe")).unwrap();

        let evidence = store
            .import_recoverable_caf_inner(
                ImportMediaRequest {
                    title: "Recovered staged import".to_owned(),
                    source_path,
                },
                Some(ImportFailurePoint::StagedJournalDurable),
            )
            .unwrap();

        assert!(evidence.ready_for_review);
        let snapshot = store.runtime_library_snapshot().unwrap();
        assert!(snapshot.current_session.is_none());
        assert_eq!(snapshot.saved_sessions.len(), 1);
        assert_eq!(snapshot.saved_sessions[0].session_id, evidence.session_id);
    }

    #[test]
    fn p1_recovered_playback_lease_binds_exact_record_across_path_replacement_without_import_cap() {
        let temp = TempDir::new().unwrap();
        let mut store = SessionStore::open(temp.path().join("Open Scribe")).unwrap();
        let prepared = store
            .prepare_session_with_required_sources(
                PrepareSessionRequest {
                    title: "Recovered lease".to_owned(),
                    origin: SessionOrigin::Capture,
                },
                vec![crate::MediaSourceKind::Microphone],
            )
            .unwrap();
        let authorization = store
            .authorize_media_open(crate::AuthorizeMediaOpenRequest {
                session_id: prepared.session_id.clone(),
                source_kind: crate::MediaSourceKind::Microphone,
                source_display_name: "Synthetic microphone".to_owned(),
            })
            .unwrap();
        write_recoverable_caf(&authorization.absolute_path, 0);
        let initial_byte_length = authorization.absolute_path.metadata().unwrap().len();
        store
            .accept_media_open(crate::MediaOpenReceipt {
                session_id: authorization.session_id.clone(),
                track_id: authorization.track_id.clone(),
                segment_id: authorization.segment_id.clone(),
                open_token: authorization.open_token.clone(),
                writer_generation: authorization.writer_generation,
                relative_path: authorization.relative_path.clone(),
                media_format: authorization.media_format.clone(),
                sample_rate_hz: authorization.sample_rate_hz,
                channels: authorization.channels,
                initial_byte_length,
            })
            .unwrap();
        let observed_byte_length = {
            let mut writer = OpenOptions::new()
                .append(true)
                .open(&authorization.absolute_path)
                .unwrap();
            writer.write_all(&vec![0_u8; 960 * 2]).unwrap();
            writer.sync_all().unwrap();
            writer.metadata().unwrap().len()
        };
        store
            .accept_first_sample(crate::FirstSampleReceipt {
                session_id: authorization.session_id.clone(),
                track_id: authorization.track_id.clone(),
                segment_id: authorization.segment_id.clone(),
                open_token: authorization.open_token.clone(),
                writer_generation: authorization.writer_generation,
                relative_path: authorization.relative_path.clone(),
                first_sample_host_time: 42_000,
                first_sample_frame_count: 960,
                observed_byte_length,
            })
            .unwrap();
        store
            .confirm_recording(prepared.session_id.clone())
            .unwrap();
        store
            .interrupt_session(crate::InterruptSessionRequest {
                session_id: prepared.session_id,
                reason: crate::SessionInterruptionReason::CaptureFailed,
            })
            .unwrap();
        let recovered = store.recover_playable_sessions().unwrap().remove(0);
        let original = fs::read(&authorization.absolute_path).unwrap();

        let lease = store
            .lease_recovered_playback(
                &recovered.session_id,
                &recovered.source_id,
                &recovered.track_id,
                &recovered.segment_id,
            )
            .unwrap();
        assert!(matches!(
            store.lease_recovered_playback(
                &recovered.session_id,
                "wrong-source",
                &recovered.track_id,
                &recovered.segment_id,
            ),
            Err(StoreError::InvalidState(
                "recovered playback evidence is unavailable"
            ))
        ));
        let managed_path = authorization.absolute_path;
        fs::remove_file(&managed_path).unwrap();
        write_recoverable_caf(&managed_path, 96_000);

        let mut leased_file = lease.file.try_clone().unwrap();
        let mut leased_bytes = Vec::new();
        leased_file.read_to_end(&mut leased_bytes).unwrap();
        assert_eq!(leased_bytes, original);
        assert_eq!(lease.byte_length(), original.len() as u64);
        assert_eq!(lease.digest_sha256(), recovered.digest_sha256);
    }

    #[test]
    fn store_open_recovers_only_empty_private_playback_placeholders() {
        let temp = TempDir::new().unwrap();
        let managed_root = temp.path().join("Open Scribe");
        drop(SessionStore::open(&managed_root).unwrap());
        let stale = managed_root.join(format!(
            "{PLAYBACK_SNAPSHOT_PREFIX}{}{PLAYBACK_SNAPSHOT_SUFFIX}",
            Uuid::now_v7()
        ));
        File::create(&stale).unwrap();

        drop(SessionStore::open(&managed_root).unwrap());

        assert!(!stale.exists());
        let quarantine = fs::read_dir(&managed_root)
            .unwrap()
            .find_map(|entry| {
                let entry = entry.unwrap();
                entry
                    .file_name()
                    .to_string_lossy()
                    .starts_with(PLAYBACK_QUARANTINE_PREFIX)
                    .then_some(entry.path())
            })
            .unwrap();
        assert_eq!(fs::metadata(&quarantine).unwrap().len(), 0);
        let invalid = managed_root.join(format!(
            "{PLAYBACK_SNAPSHOT_PREFIX}{}{PLAYBACK_SNAPSHOT_SUFFIX}",
            Uuid::now_v7()
        ));
        fs::write(&invalid, b"not an empty placeholder").unwrap();
        assert!(SessionStore::open(&managed_root).is_err());
        assert_eq!(fs::read(&invalid).unwrap(), b"not an empty placeholder");

        fs::remove_file(&invalid).unwrap();
        fs::remove_file(&quarantine).unwrap();
        let raced = managed_root.join(format!(
            "{PLAYBACK_SNAPSHOT_PREFIX}{}{PLAYBACK_SNAPSHOT_SUFFIX}",
            Uuid::now_v7()
        ));
        File::create(&raced).unwrap();
        let replacement = b"replacement must be preserved";
        assert!(
            cleanup_stale_playback_snapshot_placeholders_with_hook(&managed_root, |path| {
                fs::remove_file(path).unwrap();
                fs::write(path, replacement).unwrap();
            })
            .is_err()
        );
        assert_eq!(fs::read(&raced).unwrap(), replacement);
        assert!(fs::read_dir(&managed_root).unwrap().all(|entry| {
            !entry
                .unwrap()
                .file_name()
                .to_string_lossy()
                .starts_with(PLAYBACK_QUARANTINE_PREFIX)
        }));

        fs::remove_file(&raced).unwrap();
        let symlink_target = managed_root.join("preserved-target");
        fs::write(&symlink_target, b"preserved").unwrap();
        let linked = managed_root.join(format!(
            "{PLAYBACK_SNAPSHOT_PREFIX}{}{PLAYBACK_SNAPSHOT_SUFFIX}",
            Uuid::now_v7()
        ));
        symlink(&symlink_target, &linked).unwrap();
        assert!(SessionStore::open(&managed_root).is_err());
        assert!(
            fs::symlink_metadata(&linked)
                .unwrap()
                .file_type()
                .is_symlink()
        );
        assert_eq!(fs::read(&symlink_target).unwrap(), b"preserved");
    }

    #[test]
    fn import_rejects_symlinks_and_malformed_media_without_library_rows() {
        let temp = TempDir::new().unwrap();
        let source_path = temp.path().join("audio.caf");
        fs::write(&source_path, b"not audio").unwrap();
        let symlink_path = temp.path().join("linked.caf");
        symlink(&source_path, &symlink_path).unwrap();
        let oversized_path = temp.path().join("oversized.caf");
        File::create(&oversized_path)
            .unwrap()
            .set_len(MAX_IMPORT_BYTES + 1)
            .unwrap();
        let overlong_path = temp.path().join("overlong.caf");
        write_sparse_recoverable_caf(&overlong_path, MAX_IMPORT_SAMPLES + 1);
        let mut store = SessionStore::open(temp.path().join("Open Scribe")).unwrap();

        for path in [source_path, symlink_path, oversized_path, overlong_path] {
            assert!(
                store
                    .import_recoverable_caf(ImportMediaRequest {
                        title: "Rejected".to_owned(),
                        source_path: path,
                    })
                    .is_err()
            );
        }
        assert_eq!(
            store
                .connection
                .query_row("SELECT COUNT(*) FROM sessions", [], |row| row
                    .get::<_, i64>(0))
                .unwrap(),
            0
        );
        assert_eq!(
            fs::read_dir(temp.path().join("Open Scribe").join("Sessions"))
                .unwrap()
                .count(),
            0
        );
    }

    #[test]
    fn durable_import_journal_replays_an_uncommitted_library_projection() {
        let temp = TempDir::new().unwrap();
        let source_path = temp.path().join("interrupted-import.caf");
        write_recoverable_caf(&source_path, 1_920);
        let managed_root = temp.path().join("Open Scribe");
        let mut store = SessionStore::open(&managed_root).unwrap();
        let evidence = store
            .import_recoverable_caf(ImportMediaRequest {
                title: "Interrupted import".to_owned(),
                source_path,
            })
            .unwrap();
        let session_id = evidence.session_id.0.clone();
        let track_id = Path::new(&evidence.relative_path)
            .components()
            .nth(1)
            .and_then(|component| match component {
                std::path::Component::Normal(value) => value.to_str(),
                _ => None,
            })
            .unwrap()
            .to_owned();
        let track_directory = store
            .managed_import_track_directory(&session_id, &track_id)
            .unwrap();
        fd_fs::renameat_with(
            &track_directory,
            OsStr::new("000000-import.caf"),
            &track_directory,
            OsStr::new(".importing.caf"),
            fd_fs::RenameFlags::NOREPLACE,
        )
        .unwrap();
        fd_fs::fsync(&track_directory).unwrap();
        drop(track_directory);

        let transaction = store.connection.transaction().unwrap();
        transaction
            .execute("DELETE FROM imports WHERE session_id = ?1", [&session_id])
            .unwrap();
        transaction
            .execute("DELETE FROM segments WHERE session_id = ?1", [&session_id])
            .unwrap();
        transaction
            .execute("DELETE FROM tracks WHERE session_id = ?1", [&session_id])
            .unwrap();
        transaction
            .execute("DELETE FROM sources WHERE session_id = ?1", [&session_id])
            .unwrap();
        transaction
            .execute(
                "DELETE FROM session_events
                 WHERE session_id = ?1 AND event_kind = 'media_imported'",
                [&session_id],
            )
            .unwrap();
        transaction
            .execute(
                "UPDATE sessions SET lifecycle = 'preparing' WHERE id = ?1",
                [&session_id],
            )
            .unwrap();
        transaction.commit().unwrap();
        drop(store);

        let mut reopened = SessionStore::open(&managed_root).unwrap();
        let findings = reopened.recover_preparations().unwrap();
        assert_eq!(findings.len(), 1);
        assert_eq!(
            findings[0].disposition,
            RecoveryDisposition::ImportProjectionRepaired
        );
        let snapshot = reopened.runtime_library_snapshot().unwrap();
        assert!(snapshot.current_session.is_none());
        assert_eq!(snapshot.saved_sessions.len(), 1);
        assert_eq!(snapshot.saved_sessions[0].session_id.0, session_id);
    }
}
