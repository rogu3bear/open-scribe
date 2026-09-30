//! Restoring a verified portable package as a new local session (ADR 0010
//! round trip). The core verifies the package and parses its documents; this
//! module copies each sealed media file into the managed library, checks it
//! against the package's length, digest, sample count, and channels, and
//! journals its placement before projecting it. The session gets new local
//! identities; the portable source session ID and package digest remain as
//! provenance. A restored capture plays from its journaled placements, never
//! from a synthesized capture clock. A transcript is restored only when its
//! input digest, recomputed from the package's own identities, names exactly
//! these media bytes. A restore that does not finish is removed, at once or at
//! the next launch, and leaves a deletion tombstone.

use super::conversation_identity::{PrepareSessionRequest, SessionOrigin};
use super::import::IMPORT_SOURCE_KIND;
use super::library_recovery::isolated_disposition;
use super::transcript_input::{DigestedSegment, transcription_input_digest};
use super::transcript_review::{SOURCE_CLUSTER, reindex_session_search};
use super::transcripts::{TRANSCRIPT_SCHEMA_VERSION, TranscriptionRunIdentity, select_revision};
use super::{
    JOURNAL_NAME, JournalRecord, JournalValidation, MEDIA_FORMAT_CAF_PCM_S16LE,
    MEDIA_SAMPLE_RATE_HZ, MediaLengthRequirement, MediaSourceKind, SCHEMA_VERSION, SessionStore,
    StoreError, TimelineSegment, event_digest, insert_event_with_id, journal_record_for_segment,
    next_database_event, open_managed_directory_at, payload_i64, payload_string, payload_u64,
    sync_directory, validate_journal, wall_time_milliseconds,
};
use open_scribe_types::SessionId;
use rusqlite::{Transaction, params};
use rustix::fs as fd_fs;
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use std::collections::BTreeMap;
use std::ffi::OsStr;
use std::fs::{self, File, OpenOptions};
use std::io::{ErrorKind, Read, Write};
use std::os::unix::fs::OpenOptionsExt;
use std::path::PathBuf;
use uuid::Uuid;

pub(super) const RESTORE_MIGRATION_VERSION: i64 = 9;
/// Names a restored revision's reconciliation and run options.
const RESTORE_RECONCILIATION: &str = "open-scribe.package-restore/v1";
const MAX_RESTORED_TRACKS: usize = 64;
const MAX_RESTORED_SEGMENTS: usize = 100_000;
const MAX_RESTORED_TRANSCRIPT_SEGMENTS: usize = 200_000;
const MAX_RESTORED_MEDIA_BYTES: u64 = 8 << 30;
const MAX_IDENTIFIER_BYTES: usize = 128;
const MAX_PROVENANCE_BYTES: usize = 256;
const MAX_MARKER_LABEL_BYTES: usize = 512;
const MAX_SPEAKER_LABEL_BYTES: usize = 128;
const MAX_SEGMENT_TEXT_BYTES: usize = 64 * 1024;
const MAX_CORRECTION_BYTES: usize = 4096;
/// The one-sample overlap a first-version capture timeline may carry.
const MAX_OVERLAP_NANOSECONDS: i64 = 20_834;

pub(super) fn apply_restore_schema(transaction: &Transaction<'_>) -> Result<(), StoreError> {
    transaction.execute_batch(
        "CREATE TABLE IF NOT EXISTS session_restorations (
            session_id TEXT PRIMARY KEY REFERENCES sessions(id),
            schema_version INTEGER NOT NULL,
            source_session_id TEXT NOT NULL,
            source_created_at_ms INTEGER NOT NULL,
            package_sha256 TEXT NOT NULL,
            state TEXT NOT NULL CHECK (state IN ('restoring', 'restored')),
            created_at_ms INTEGER NOT NULL,
            updated_at_ms INTEGER NOT NULL
        );",
    )?;
    Ok(())
}

/// One package, parsed and path-checked by the core, to restore.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct PackageRestoreRequest {
    pub title: String,
    pub origin: SessionOrigin,
    pub source_session_id: String,
    pub source_created_at_ms: i64,
    /// SHA-256 of the package's `manifest.json`.
    pub package_sha256: String,
    pub tracks: Vec<RestoredTrack>,
    pub markers: Vec<RestoredMarker>,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct RestoredTrack {
    pub source_track_id: String,
    pub source_id: String,
    pub source_kind: String,
    /// The latest human speaker name, when the package records one.
    pub human_speaker_label: Option<String>,
    pub segments: Vec<RestoredSegment>,
    pub transcript: Option<RestoredTranscript>,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct RestoredSegment {
    pub source_segment_id: String,
    pub sequence: u64,
    pub start_nanoseconds: i64,
    pub sample_count: u64,
    pub channels: u16,
    pub byte_length: u64,
    pub digest_sha256: String,
    /// The media file inside the verified package.
    pub path: PathBuf,
}

/// A selected Final revision as the package's transcript records it.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct RestoredTranscript {
    pub source_revision_id: String,
    pub source_run_id: String,
    pub input_digest: String,
    pub engine: String,
    pub engine_version: String,
    pub model_id: String,
    pub model_sha256: String,
    pub language: Option<String>,
    /// In revision sequence order, starting at zero.
    pub segments: Vec<RestoredTranscriptSegment>,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct RestoredTranscriptSegment {
    pub start_nanoseconds: i64,
    pub end_nanoseconds: i64,
    pub verbatim_text: String,
    /// A human correction's effective text.
    pub correction: Option<String>,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct RestoredMarker {
    pub at_nanoseconds: i64,
    pub label: String,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct PackageRestoreReceipt {
    pub session_id: SessionId,
    pub media_files: u32,
    pub transcript_tracks: u32,
    pub markers: u32,
}

/// Provenance written in the same transaction that creates the session.
pub(super) struct RestorationIntent<'a> {
    pub source_session_id: &'a str,
    pub source_created_at_ms: i64,
    pub package_sha256: &'a str,
}

pub(super) fn insert_restoration_intent(
    transaction: &Transaction<'_>,
    session_id: &str,
    intent: &RestorationIntent<'_>,
    now: i64,
) -> Result<(), StoreError> {
    transaction.execute(
        "INSERT INTO session_restorations(
            session_id, schema_version, source_session_id, source_created_at_ms,
            package_sha256, state, created_at_ms, updated_at_ms)
         VALUES(?1, ?2, ?3, ?4, ?5, 'restoring', ?6, ?6)",
        params![
            session_id,
            SCHEMA_VERSION,
            intent.source_session_id,
            intent.source_created_at_ms,
            intent.package_sha256,
            now
        ],
    )?;
    Ok(())
}

/// A restored track's local identities and digest placements.
struct LocalTrack {
    track_id: String,
    placements: Vec<DigestedSegment>,
}

impl SessionStore {
    /// Restores one verified package as a new session. All or nothing: a
    /// failure removes the partial session before it returns.
    pub fn restore_portable_session(
        &mut self,
        request: &PackageRestoreRequest,
    ) -> Result<PackageRestoreReceipt, StoreError> {
        validate_restore(request)?;
        let prepared = self.prepare_session_recorded(
            PrepareSessionRequest {
                title: request.title.clone(),
                origin: request.origin,
            },
            None,
            Some(&RestorationIntent {
                source_session_id: &request.source_session_id,
                source_created_at_ms: request.source_created_at_ms,
                package_sha256: &request.package_sha256,
            }),
        )?;
        let session = prepared.session_id;
        match self.restore_into(&session, request) {
            Ok(receipt) => Ok(receipt),
            Err(error) => {
                // A failed discard is retried by the launch sweep.
                let _ = self.discard_restoration(&session.0);
                Err(error)
            }
        }
    }

    fn restore_into(
        &mut self,
        session: &SessionId,
        request: &PackageRestoreRequest,
    ) -> Result<PackageRestoreReceipt, StoreError> {
        let media_files: usize = request.tracks.iter().map(|t| t.segments.len()).sum();
        let started = self.append_session_journal(
            &session.0,
            "package_restore_started",
            None,
            json!({
                "source_session_id": request.source_session_id,
                "package_sha256": request.package_sha256,
                "tracks": request.tracks.len(),
                "media_files": media_files,
            }),
        )?;
        self.project_restore_event(&session.0, &started, None)?;
        let audio = self.open_managed_audio_directory(&session.0)?;
        let import = request.origin == SessionOrigin::Import;
        let mut local_tracks = Vec::with_capacity(request.tracks.len());
        for track in &request.tracks {
            let source_id = Uuid::now_v7().to_string();
            let track_id = Uuid::now_v7().to_string();
            fd_fs::mkdirat(&audio, &track_id, fd_fs::Mode::from_raw_mode(0o700)).map_err(|_| {
                StoreError::IntegrityMismatch("restored track could not be created")
            })?;
            let directory = open_managed_directory_at(&audio, OsStr::new(&track_id))?;
            fd_fs::fsync(&audio).map_err(|_| {
                StoreError::IntegrityMismatch("audio directory was not synchronized")
            })?;
            let mut placements = Vec::with_capacity(track.segments.len());
            for segment in &track.segments {
                let segment_id = Uuid::now_v7().to_string();
                let file_name = if import {
                    "000000-import.caf".to_owned()
                } else {
                    format!("{:06}-0.caf", segment.sequence)
                };
                let relative_path = format!("audio/{track_id}/{file_name}");
                copy_restored_media(segment, &directory, &file_name)?;
                let validated = self.validate_media_file(
                    &session.0,
                    &relative_path,
                    MediaLengthRequirement::Exact(segment.byte_length),
                    true,
                )?;
                if validated.digest_sha256.as_deref() != Some(segment.digest_sha256.as_str())
                    || validated.recoverable_sample_count != Some(segment.sample_count)
                    || validated.channels != Some(segment.channels)
                {
                    return Err(StoreError::IntegrityMismatch(
                        "restored media differs from its package entry",
                    ));
                }
                let payload = json!({
                    "source_id": source_id,
                    "source_kind": track.source_kind,
                    "track_id": track_id,
                    "segment_id": segment_id,
                    "sequence": segment.sequence,
                    "relative_path": relative_path,
                    "start_nanoseconds": segment.start_nanoseconds,
                    "sample_count": segment.sample_count,
                    "channels": segment.channels,
                    "byte_length": segment.byte_length,
                    "digest_sha256": segment.digest_sha256,
                    "file_device": validated.device,
                    "file_inode": validated.inode,
                    "source_segment_id": segment.source_segment_id,
                });
                let record = self.append_session_journal(
                    &session.0,
                    "segment_restored",
                    Some(&relative_path),
                    payload,
                )?;
                self.project_restore_event(&session.0, &record, Some(request.origin))?;
                placements.push(DigestedSegment {
                    segment_id,
                    digest_sha256: segment.digest_sha256.clone(),
                    start_nanoseconds: segment.start_nanoseconds,
                    gap_nanoseconds: 0,
                    frames: segment.sample_count,
                });
            }
            fill_gaps(&mut placements)?;
            local_tracks.push(LocalTrack {
                track_id,
                placements,
            });
        }
        for marker in &request.markers {
            let record = self.append_session_journal(
                &session.0,
                "marker_added",
                None,
                json!({
                    "marker_id": Uuid::now_v7().to_string(),
                    "label": marker.label,
                    "session_nanoseconds": marker.at_nanoseconds,
                }),
            )?;
            self.project_recorder_event(&session.0, &record, false)?;
        }
        let transcript_tracks = request
            .tracks
            .iter()
            .filter(|track| track.transcript.is_some())
            .count();
        let restored = self.append_session_journal(
            &session.0,
            "package_restored",
            None,
            json!({
                "media_files": media_files,
                "transcript_tracks": transcript_tracks,
                "markers": request.markers.len(),
            }),
        )?;
        self.complete_restoration(&session.0, request, &local_tracks, &restored)?;
        // The store's own reading of the restored timeline must name the
        // same input the restored transcript cites.
        for (track, local) in request.tracks.iter().zip(&local_tracks) {
            if track.transcript.is_some()
                && self
                    .transcription_input(session, &local.track_id)?
                    .input_digest
                    != transcription_input_digest(
                        &session.0,
                        &local.track_id,
                        false,
                        &local.placements,
                    )
            {
                return Err(StoreError::IntegrityMismatch(
                    "restored timeline differs from its transcript input",
                ));
            }
        }
        Ok(PackageRestoreReceipt {
            session_id: session.clone(),
            media_files: media_files as u32,
            transcript_tracks: transcript_tracks as u32,
            markers: request.markers.len() as u32,
        })
    }

    /// Projects one restore journal record. A segment record also creates its
    /// source, track, and segment rows, and an import's receipt.
    fn project_restore_event(
        &mut self,
        session: &str,
        record: &JournalRecord,
        segment_origin: Option<SessionOrigin>,
    ) -> Result<(), StoreError> {
        let kind = record.body.event_kind.as_str();
        let payload = &record.body.payload;
        let (sequence, prior) = next_database_event(&self.connection, session)?;
        let digest = event_digest(session, sequence, kind, payload, prior.as_deref())?;
        let transaction = self.connection.transaction()?;
        if let Some(origin) = segment_origin {
            project_restored_segment(&transaction, session, origin, payload)?;
        }
        insert_event_with_id(
            &transaction,
            &record.body.event_id,
            session,
            sequence,
            kind,
            record.body.wall_time_milliseconds,
            payload,
            prior.as_deref(),
            &digest,
        )?;
        transaction.commit()?;
        Ok(())
    }

    /// Transcripts, speaker names, search, and the lifecycle change commit
    /// together with the completion event.
    fn complete_restoration(
        &mut self,
        session: &str,
        request: &PackageRestoreRequest,
        local_tracks: &[LocalTrack],
        record: &JournalRecord,
    ) -> Result<(), StoreError> {
        let payload = &record.body.payload;
        let (sequence, prior) = next_database_event(&self.connection, session)?;
        let digest = event_digest(
            session,
            sequence,
            "package_restored",
            payload,
            prior.as_deref(),
        )?;
        let now = wall_time_milliseconds();
        let transaction = self.connection.transaction()?;
        for (track, local) in request.tracks.iter().zip(local_tracks) {
            if let Some(transcript) = &track.transcript {
                insert_restored_transcript(
                    &transaction,
                    session,
                    &request.source_session_id,
                    track,
                    local,
                    transcript,
                    now,
                )?;
            }
            if let Some(label) = &track.human_speaker_label {
                transaction.execute(
                    "INSERT INTO speaker_adjudications(
                        id, session_id, track_id, cluster, label, created_at_ms)
                     VALUES(?1, ?2, ?3, ?4, ?5, ?6)",
                    params![
                        Uuid::now_v7().to_string(),
                        session,
                        local.track_id,
                        SOURCE_CLUSTER,
                        label,
                        now
                    ],
                )?;
            }
        }
        reindex_session_search(&transaction, session)?;
        let ready = transaction.execute(
            "UPDATE sessions SET lifecycle = 'ready_for_review', updated_at_ms = ?2
             WHERE id = ?1 AND lifecycle = 'preparing'",
            params![session, now],
        )?;
        let restored = transaction.execute(
            "UPDATE session_restorations SET state = 'restored', updated_at_ms = ?2
             WHERE session_id = ?1 AND state = 'restoring'",
            params![session, now],
        )?;
        if ready != 1 || restored != 1 {
            return Err(StoreError::InvalidState(
                "restored session is not awaiting completion",
            ));
        }
        insert_event_with_id(
            &transaction,
            &record.body.event_id,
            session,
            sequence,
            "package_restored",
            record.body.wall_time_milliseconds,
            payload,
            prior.as_deref(),
            &digest,
        )?;
        transaction.commit()?;
        Ok(())
    }

    /// Removes a partial restore: its directory, then every row, leaving the
    /// ordinary deletion tombstone and receipt.
    fn discard_restoration(&mut self, session_id: &str) -> Result<(), StoreError> {
        match fs::remove_dir_all(self.sessions_root.join(session_id)) {
            Ok(()) => sync_directory(&self.sessions_root)?,
            Err(error) if error.kind() == ErrorKind::NotFound => {}
            Err(error) => return Err(error.into()),
        }
        self.connection.execute(
            "INSERT OR IGNORE INTO session_deletion_intents(session_id, created_at_ms)
             VALUES(?1, ?2)",
            params![session_id, wall_time_milliseconds()],
        )?;
        self.complete_session_deletion(&SessionId(session_id.to_owned()), None)?;
        Ok(())
    }

    /// Launch sweep: a restore a crash interrupted never became reviewable.
    pub(super) fn settle_package_restorations(&mut self) -> Result<(), StoreError> {
        let sessions: Vec<String> = self
            .connection
            .prepare(
                "SELECT session_id FROM session_restorations
                 WHERE state = 'restoring' ORDER BY session_id",
            )?
            .query_map([], |row| row.get(0))?
            .collect::<Result<_, _>>()?;
        for session_id in sessions {
            if let Err(error) = self.discard_restoration(&session_id) {
                isolated_disposition(error)?;
            }
        }
        Ok(())
    }

    pub(super) fn restored_capture(&self, session: &str) -> Result<bool, StoreError> {
        Ok(self.connection.query_row(
            "SELECT EXISTS(SELECT 1 FROM session_restorations
                           JOIN sessions ON sessions.id = session_restorations.session_id
                           WHERE session_restorations.session_id = ?1
                             AND session_restorations.state = 'restored'
                             AND sessions.origin = 'capture')",
            [session],
            |row| row.get(0),
        )?)
    }

    /// A restored capture's playback plan: each sealed segment at its
    /// journaled placement, with gaps preserved.
    pub(super) fn restored_playback_timeline(
        &self,
        session: &SessionId,
    ) -> Result<Vec<TimelineSegment>, StoreError> {
        let records = match validate_journal(
            &self.session_directory(&session.0)?.join(JOURNAL_NAME),
            &session.0,
        )? {
            JournalValidation::Valid(records) => records,
            _ => return Err(StoreError::IntegrityMismatch("playback journal is invalid")),
        };
        if !records
            .iter()
            .any(|record| record.body.event_kind == "package_restored")
        {
            return Err(StoreError::IntegrityMismatch(
                "restored timeline lacks journal evidence",
            ));
        }
        let mut statement = self.connection.prepare(
            "SELECT sources.id, tracks.id, segments.id, segments.sequence, segments.mapped_start_ns,
                    segments.sample_count, segments.channels, segments.digest, segments.relative_path
             FROM sessions JOIN segments ON segments.session_id = sessions.id
             JOIN tracks ON tracks.id = segments.track_id JOIN sources ON sources.id = tracks.source_id
             WHERE sessions.id = ?1 AND sessions.lifecycle = 'ready_for_review'
               AND segments.lifecycle = 'sealed'
             ORDER BY tracks.id, segments.sequence",
        )?;
        let rows = statement
            .query_map([&session.0], |row| {
                Ok((
                    row.get::<_, String>(0)?,
                    row.get::<_, String>(1)?,
                    row.get::<_, String>(2)?,
                    row.get::<_, i64>(3)?,
                    row.get::<_, i64>(4)?,
                    row.get::<_, i64>(5)?,
                    row.get::<_, i64>(6)?,
                    row.get::<_, String>(7)?,
                    row.get::<_, String>(8)?,
                ))
            })?
            .collect::<Result<Vec<_>, _>>()?;
        let mut ends = BTreeMap::new();
        let mut result = Vec::with_capacity(rows.len());
        for row in rows {
            let (source_id, track_id, segment_id, sequence, start, samples, channels) =
                (row.0, row.1, row.2, row.3, row.4, row.5, row.6);
            let evidence = journal_record_for_segment(&records, "segment_restored", &segment_id)?
                .ok_or(StoreError::IntegrityMismatch(
                "restored segment lacks journal evidence",
            ))?;
            let payload = &evidence.body.payload;
            if payload_string(payload, "track_id")? != track_id
                || payload_string(payload, "source_id")? != source_id
                || payload_string(payload, "digest_sha256")? != row.7
                || payload_string(payload, "relative_path")? != row.8
                || i64::try_from(payload_u64(payload, "sequence")?).ok() != Some(sequence)
                || payload_i64(payload, "start_nanoseconds")? != start
                || i64::try_from(payload_u64(payload, "sample_count")?).ok() != Some(samples)
                || i64::try_from(payload_u64(payload, "channels")?).ok() != Some(channels)
                || samples <= 0
                || !(1..=2).contains(&channels)
            {
                return Err(StoreError::IntegrityMismatch(
                    "restored timeline changed accepted evidence",
                ));
            }
            let end = start
                .checked_add(duration_nanoseconds(samples as u64)?)
                .ok_or(StoreError::IntegrityMismatch("timeline end overflow"))?;
            let gap = ends
                .insert(track_id.clone(), end)
                .map_or(0, |prior_end| start - prior_end);
            if gap < -MAX_OVERLAP_NANOSECONDS {
                return Err(StoreError::IntegrityMismatch(
                    "restored timeline overlaps itself",
                ));
            }
            result.push(TimelineSegment {
                session_id: session.clone(),
                source_id,
                track_id,
                segment_id,
                sequence: sequence as u64,
                start_nanoseconds: start,
                native_start_nanoseconds: start,
                clock_adjustment_nanoseconds: 0,
                sample_count: samples as u64,
                channels: channels as u16,
                gap_nanoseconds: gap,
            });
        }
        if result.is_empty() {
            return Err(StoreError::InvalidState("no sealed timeline media"));
        }
        Ok(result)
    }
}

fn project_restored_segment(
    transaction: &Transaction<'_>,
    session: &str,
    origin: SessionOrigin,
    payload: &Value,
) -> Result<(), StoreError> {
    let source_kind = payload_string(payload, "source_kind")?;
    let display_name = match source_kind {
        "microphone" => "Mac microphone",
        "application_audio" => "Selected application audio",
        "system_audio" => "Mac system audio",
        _ => "Imported audio",
    };
    let source_id = payload_string(payload, "source_id")?;
    let track_id = payload_string(payload, "track_id")?;
    let relative_path = payload_string(payload, "relative_path")?;
    let digest = payload_string(payload, "digest_sha256")?;
    transaction.execute(
        "INSERT OR IGNORE INTO sources (id, schema_version, session_id, kind, display_name, lifecycle)
         VALUES (?1, ?2, ?3, ?4, ?5, 'sealed')",
        params![source_id, SCHEMA_VERSION, session, source_kind, display_name],
    )?;
    transaction.execute(
        "INSERT OR IGNORE INTO tracks (id, schema_version, session_id, source_id, kind, lifecycle)
         VALUES (?1, ?2, ?3, ?4, 'audio', 'sealed')",
        params![track_id, SCHEMA_VERSION, session, source_id],
    )?;
    if origin == SessionOrigin::Capture {
        transaction.execute(
            "INSERT OR IGNORE INTO required_sources(session_id, schema_version, kind, lifecycle)
             VALUES(?1, ?2, ?3, 'sealed')",
            params![session, SCHEMA_VERSION, source_kind],
        )?;
    }
    transaction.execute(
        "INSERT INTO segments (
            id, schema_version, session_id, track_id, sequence, relative_path,
            lifecycle, original_start, mapped_start_ns, media_format, channels,
            sample_count, byte_length, digest, seal_state, recovery_state,
            open_token, writer_generation, file_device, file_inode
         ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, 'sealed', NULL, ?7, ?8, ?9,
                   ?10, ?11, ?12, 'sealed', 'not_required', NULL, 0, ?13, ?14)",
        params![
            payload_string(payload, "segment_id")?,
            SCHEMA_VERSION,
            session,
            track_id,
            payload_u64(payload, "sequence")? as i64,
            relative_path,
            payload_i64(payload, "start_nanoseconds")?,
            MEDIA_FORMAT_CAF_PCM_S16LE,
            payload_u64(payload, "channels")? as i64,
            payload_u64(payload, "sample_count")? as i64,
            payload_u64(payload, "byte_length")? as i64,
            digest,
            payload_u64(payload, "file_device")? as i64,
            payload_u64(payload, "file_inode")? as i64,
        ],
    )?;
    if origin == SessionOrigin::Import {
        transaction.execute(
            "INSERT INTO imports (
                id, schema_version, session_id, relative_path, source_digest, created_at_ms
             ) VALUES (?1, ?2, ?3, ?4, ?5, ?6)",
            params![
                Uuid::now_v7().to_string(),
                SCHEMA_VERSION,
                session,
                relative_path,
                digest,
                wall_time_milliseconds()
            ],
        )?;
    }
    Ok(())
}

/// One Final revision as a completed run with one chunk that records where
/// the text came from. Its input digest is the restored track's own.
fn insert_restored_transcript(
    transaction: &Transaction<'_>,
    session: &str,
    source_session_id: &str,
    track: &RestoredTrack,
    local: &LocalTrack,
    transcript: &RestoredTranscript,
    now: i64,
) -> Result<(), StoreError> {
    let identity = TranscriptionRunIdentity {
        session_id: SessionId(session.to_owned()),
        track_id: local.track_id.clone(),
        input_digest: transcription_input_digest(
            session,
            &local.track_id,
            false,
            &local.placements,
        ),
        engine: transcript.engine.clone(),
        engine_version: transcript.engine_version.clone(),
        model_id: transcript.model_id.clone(),
        model_sha256: transcript.model_sha256.clone(),
        options_digest: hex(&Sha256::digest(RESTORE_RECONCILIATION.as_bytes())),
        reconciliation_version: RESTORE_RECONCILIATION.to_owned(),
    };
    let start = transcript
        .segments
        .iter()
        .map(|segment| segment.start_nanoseconds)
        .min()
        .unwrap_or(0);
    let end = transcript
        .segments
        .iter()
        .map(|segment| segment.end_nanoseconds)
        .max()
        .unwrap_or(start)
        .max(start + 1);
    let chunk_identity = identity.chunk_identity(0, start, end);
    let provenance = json!({
        "restored_from": {
            "session_id": source_session_id,
            "track_id": track.source_track_id,
            "revision_id": transcript.source_revision_id,
            "run_id": transcript.source_run_id,
            "input_digest": transcript.input_digest,
        }
    });
    let run_id = Uuid::now_v7().to_string();
    transaction.execute(
        "INSERT INTO transcription_runs(
            id, schema_version, session_id, track_id, identity, input_digest, engine,
            engine_version, model_id, model_sha256, options_digest, reconciliation_version,
            state, created_at_ms, updated_at_ms)
         VALUES(?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, 'complete', ?13, ?13)",
        params![
            run_id,
            TRANSCRIPT_SCHEMA_VERSION,
            session,
            identity.track_id,
            identity.digest(),
            identity.input_digest,
            identity.engine,
            identity.engine_version,
            identity.model_id,
            identity.model_sha256,
            identity.options_digest,
            identity.reconciliation_version,
            now
        ],
    )?;
    transaction.execute(
        "INSERT INTO transcript_chunks(
            run_id, sequence, identity, span_index, start_ns, end_ns, state,
            language, hypothesis_json, reused_from_run, updated_at_ms)
         VALUES(?1, 0, ?2, 0, ?3, ?4, 'complete', ?5, ?6, NULL, ?7)",
        params![
            run_id,
            chunk_identity,
            start,
            end,
            transcript.language,
            provenance.to_string(),
            now
        ],
    )?;
    let revision_id = Uuid::now_v7().to_string();
    transaction.execute(
        "INSERT INTO transcript_revisions(
            id, schema_version, session_id, track_id, run_id, kind, finality,
            reconciliation_version, rejections_json, discontinuities_json, created_at_ms)
         VALUES(?1, ?2, ?3, ?4, ?5, 'verbatim', 'final', ?6, '[]', '[]', ?7)",
        params![
            revision_id,
            TRANSCRIPT_SCHEMA_VERSION,
            session,
            local.track_id,
            run_id,
            RESTORE_RECONCILIATION,
            now
        ],
    )?;
    for (sequence, segment) in transcript.segments.iter().enumerate() {
        transaction.execute(
            "INSERT INTO transcript_segments(
                revision_id, sequence, start_ns, end_ns, text, mean_probability,
                no_speech_probability, chunk_identity)
             VALUES(?1, ?2, ?3, ?4, ?5, NULL, NULL, ?6)",
            params![
                revision_id,
                sequence as i64,
                segment.start_nanoseconds,
                segment.end_nanoseconds,
                segment.verbatim_text,
                chunk_identity
            ],
        )?;
        if let Some(correction) = &segment.correction {
            transaction.execute(
                "INSERT INTO transcript_corrections(
                    id, session_id, revision_id, sequence, text, created_at_ms)
                 VALUES(?1, ?2, ?3, ?4, ?5, ?6)",
                params![
                    Uuid::now_v7().to_string(),
                    session,
                    revision_id,
                    sequence as i64,
                    correction,
                    now
                ],
            )?;
        }
    }
    select_revision(transaction, session, &local.track_id, &revision_id, now)
}

/// Copies one package file into the managed track directory, rehashing as it
/// copies: the package could change after the core verified it.
fn copy_restored_media(
    segment: &RestoredSegment,
    directory: &impl std::os::fd::AsFd,
    file_name: &str,
) -> Result<(), StoreError> {
    let mismatch = || StoreError::IntegrityMismatch("package media changed after verification");
    let source = OpenOptions::new()
        .read(true)
        .custom_flags(rustix::fs::OFlags::NOFOLLOW.bits() as i32)
        .open(&segment.path)
        .map_err(|_| mismatch())?;
    let metadata = source.metadata()?;
    if !metadata.is_file() || metadata.len() != segment.byte_length {
        return Err(mismatch());
    }
    let target = fd_fs::openat(
        directory,
        OsStr::new(file_name),
        fd_fs::OFlags::WRONLY
            | fd_fs::OFlags::CREATE
            | fd_fs::OFlags::EXCL
            | fd_fs::OFlags::CLOEXEC
            | fd_fs::OFlags::NOFOLLOW,
        fd_fs::Mode::from_raw_mode(0o600),
    )
    .map_err(|_| StoreError::IntegrityMismatch("restored media could not be created"))?;
    let mut target = File::from(target);
    let mut hasher = Sha256::new();
    let mut buffer = vec![0_u8; 1 << 20];
    let mut reader = source.take(segment.byte_length);
    let mut copied = 0_u64;
    loop {
        let read = reader.read(&mut buffer)?;
        if read == 0 {
            break;
        }
        hasher.update(&buffer[..read]);
        target.write_all(&buffer[..read])?;
        copied += read as u64;
    }
    if copied != segment.byte_length || hex(&hasher.finalize()) != segment.digest_sha256 {
        return Err(mismatch());
    }
    target.sync_all()?;
    fd_fs::fsync(directory)
        .map_err(|_| StoreError::IntegrityMismatch("restored track was not synchronized"))?;
    Ok(())
}

/// Checks everything the package claims before any file is written.
fn validate_restore(request: &PackageRestoreRequest) -> Result<(), StoreError> {
    let invalid = StoreError::InvalidRequest;
    let bounded = |value: &str, limit: usize| {
        !value.trim().is_empty() && value.len() <= limit && !value.chars().any(char::is_control)
    };
    if !bounded(&request.source_session_id, MAX_IDENTIFIER_BYTES)
        || !is_sha256(&request.package_sha256)
    {
        return Err(invalid("package provenance is invalid"));
    }
    let import = request.origin == SessionOrigin::Import;
    let media_files: usize = request.tracks.iter().map(|t| t.segments.len()).sum();
    if request.tracks.is_empty()
        || request.tracks.len() > MAX_RESTORED_TRACKS
        || media_files > MAX_RESTORED_SEGMENTS
        || (import && (media_files != 1 || !request.markers.is_empty()))
    {
        return Err(invalid("package media layout is not restorable"));
    }
    for track in &request.tracks {
        let kind_valid = if import {
            track.source_kind == IMPORT_SOURCE_KIND
        } else {
            MediaSourceKind::from_str(&track.source_kind).is_ok()
        };
        if !kind_valid
            || !bounded(&track.source_track_id, MAX_IDENTIFIER_BYTES)
            || !bounded(&track.source_id, MAX_IDENTIFIER_BYTES)
            || track.segments.is_empty()
            || track.human_speaker_label.as_deref().is_some_and(|label| {
                !bounded(label, MAX_SPEAKER_LABEL_BYTES) || label.trim() != label
            })
        {
            return Err(invalid("a package track is not restorable"));
        }
        let channels = track.segments[0].channels;
        let mut placements = Vec::with_capacity(track.segments.len());
        for (index, segment) in track.segments.iter().enumerate() {
            if !bounded(&segment.source_segment_id, MAX_IDENTIFIER_BYTES)
                || (index > 0 && segment.sequence <= track.segments[index - 1].sequence)
                || segment.start_nanoseconds < 0
                || (import && segment.start_nanoseconds != 0)
                || segment.sample_count == 0
                || segment.channels != channels
                || !(1..=2).contains(&segment.channels)
                || segment.byte_length == 0
                || segment.byte_length > MAX_RESTORED_MEDIA_BYTES
                || !is_sha256(&segment.digest_sha256)
            {
                return Err(invalid("a package media file is not restorable"));
            }
            placements.push(DigestedSegment {
                segment_id: segment.source_segment_id.clone(),
                digest_sha256: segment.digest_sha256.clone(),
                start_nanoseconds: segment.start_nanoseconds,
                gap_nanoseconds: 0,
                frames: segment.sample_count,
            });
        }
        fill_gaps(&mut placements)?;
        if let Some(transcript) = &track.transcript {
            validate_transcript(transcript)?;
            // The package's transcript must cite exactly these media bytes.
            let source_input = transcription_input_digest(
                &request.source_session_id,
                &track.source_track_id,
                false,
                &placements,
            );
            if source_input != transcript.input_digest {
                return Err(invalid("a transcript does not match its media"));
            }
        }
    }
    for marker in &request.markers {
        if marker.at_nanoseconds < 0
            || marker.label.len() > MAX_MARKER_LABEL_BYTES
            || marker.label.contains('\0')
        {
            return Err(invalid("a package marker is invalid"));
        }
    }
    Ok(())
}

fn validate_transcript(transcript: &RestoredTranscript) -> Result<(), StoreError> {
    let bounded = |value: &str| {
        !value.trim().is_empty()
            && value.len() <= MAX_PROVENANCE_BYTES
            && !value.chars().any(char::is_control)
    };
    let valid = bounded(&transcript.source_revision_id)
        && bounded(&transcript.source_run_id)
        && bounded(&transcript.engine)
        && bounded(&transcript.engine_version)
        && bounded(&transcript.model_id)
        && bounded(&transcript.model_sha256)
        && is_sha256(&transcript.input_digest)
        && transcript.language.as_deref().is_none_or(bounded)
        && !transcript.segments.is_empty()
        && transcript.segments.len() <= MAX_RESTORED_TRANSCRIPT_SEGMENTS
        && transcript
            .segments
            .windows(2)
            .all(|pair| pair[1].start_nanoseconds >= pair[0].start_nanoseconds)
        && transcript.segments.iter().all(|segment| {
            segment.start_nanoseconds >= 0
                && segment.end_nanoseconds >= segment.start_nanoseconds
                && !segment.verbatim_text.trim().is_empty()
                && segment.verbatim_text.len() <= MAX_SEGMENT_TEXT_BYTES
                && segment.correction.as_deref().is_none_or(|text| {
                    !text.trim().is_empty()
                        && text.trim() == text
                        && text.len() <= MAX_CORRECTION_BYTES
                })
        });
    if valid {
        Ok(())
    } else {
        Err(StoreError::InvalidRequest(
            "a package transcript is invalid",
        ))
    }
}

/// Derives each segment's gap from the preceding segment's end on its track.
fn fill_gaps(placements: &mut [DigestedSegment]) -> Result<(), StoreError> {
    let mut prior_end: Option<i64> = None;
    for placement in placements.iter_mut() {
        let end = placement
            .start_nanoseconds
            .checked_add(duration_nanoseconds(placement.frames)?)
            .ok_or(StoreError::InvalidRequest("package timeline overflows"))?;
        placement.gap_nanoseconds =
            prior_end.map_or(0, |prior| placement.start_nanoseconds - prior);
        if placement.gap_nanoseconds < -MAX_OVERLAP_NANOSECONDS {
            return Err(StoreError::InvalidRequest(
                "package timeline overlaps itself",
            ));
        }
        prior_end = Some(end);
    }
    Ok(())
}

fn duration_nanoseconds(frames: u64) -> Result<i64, StoreError> {
    i64::try_from(u128::from(frames) * 1_000_000_000 / u128::from(MEDIA_SAMPLE_RATE_HZ))
        .map_err(|_| StoreError::InvalidRequest("package timeline overflows"))
}

fn is_sha256(value: &str) -> bool {
    value.len() == 64
        && value
            .bytes()
            .all(|byte| matches!(byte, b'0'..=b'9' | b'a'..=b'f'))
}

fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|byte| format!("{byte:02x}")).collect()
}

#[cfg(test)]
#[path = "package_restore_tests.rs"]
mod tests;
