use std::fs;
use std::path::PathBuf;

use open_scribe_types::SessionId;
use serde_json::Value;

use super::{
    MediaLengthRequirement, MediaSourceKind, SessionInterruptionReason, SessionStore, StoreError,
    payload_string, valid_media_relative_path, wall_time_milliseconds,
};

/// One coarse, content-free source state for native presentation.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct RuntimeSourceSnapshot {
    pub kind: MediaSourceKind,
    pub display_name: String,
    pub lifecycle: String,
}

/// Current read-only playback posture for one managed audio file.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum RuntimePlayableMediaAvailability {
    Available,
    Unavailable,
    Corrupt,
}

/// Coarse, content-free media evidence used by the native conversation library.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct RuntimePlayableMediaSnapshot {
    pub source_display_name: String,
    pub availability: RuntimePlayableMediaAvailability,
    pub absolute_path: Option<PathBuf>,
    pub duration_nanoseconds: u64,
    pub sample_count: u64,
    pub byte_length: u64,
}

/// Rust-owned durable session projection for the native live and library surfaces.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct RuntimeSessionSnapshot {
    pub session_id: SessionId,
    pub title: String,
    pub lifecycle: String,
    pub health: String,
    pub elapsed_seconds: u64,
    pub journal_durable: bool,
    pub media_files_open: bool,
    pub interruption_reason: Option<SessionInterruptionReason>,
    pub recovered: bool,
    pub sources: Vec<RuntimeSourceSnapshot>,
    pub playable_media: Option<RuntimePlayableMediaSnapshot>,
}

/// One read-only authority snapshot shared by the native live and library surfaces.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct RuntimeLibrarySnapshot {
    pub current_session: Option<RuntimeSessionSnapshot>,
    pub saved_sessions: Vec<RuntimeSessionSnapshot>,
}

impl SessionStore {
    /// Reads one coarse snapshot from the durable library without mutating media or lifecycle.
    pub fn runtime_library_snapshot(&self) -> Result<RuntimeLibrarySnapshot, StoreError> {
        self.runtime_library_snapshot_at(wall_time_milliseconds())
    }

    pub(super) fn runtime_library_snapshot_at(
        &self,
        now_milliseconds: i64,
    ) -> Result<RuntimeLibrarySnapshot, StoreError> {
        self.runtime_library_snapshot_at_with_observer(now_milliseconds, || {})
    }

    #[cfg(test)]
    pub(super) fn runtime_library_snapshot_at_after_sessions<F>(
        &self,
        now_milliseconds: i64,
        after_sessions: F,
    ) -> Result<RuntimeLibrarySnapshot, StoreError>
    where
        F: FnOnce(),
    {
        self.runtime_library_snapshot_at_with_observer(now_milliseconds, after_sessions)
    }

    fn runtime_library_snapshot_at_with_observer<F>(
        &self,
        now_milliseconds: i64,
        after_sessions: F,
    ) -> Result<RuntimeLibrarySnapshot, StoreError>
    where
        F: FnOnce(),
    {
        let transaction = self.connection.unchecked_transaction()?;
        let sessions = {
            let mut statement = transaction.prepare(
                "SELECT sessions.id, sessions.title, sessions.origin, sessions.lifecycle, sessions.health,
                        sessions.journal_durable, sessions.media_files_open,
                        sessions.updated_at_ms,
                        (SELECT MIN(started.wall_time_ms)
                         FROM session_events started
                         WHERE started.session_id = sessions.id
                           AND started.event_kind = 'recording_started'),
                        (SELECT interrupted.payload_json
                         FROM session_events interrupted
                         WHERE interrupted.session_id = sessions.id
                           AND interrupted.event_kind = 'session_interrupted'
                         ORDER BY interrupted.sequence DESC LIMIT 1),
                        (SELECT interrupted.wall_time_ms
                         FROM session_events interrupted
                         WHERE interrupted.session_id = sessions.id
                           AND interrupted.event_kind = 'session_interrupted'
                         ORDER BY interrupted.sequence DESC LIMIT 1),
                        (SELECT MAX(segments.sample_count)
                         FROM segments
                         WHERE segments.session_id = sessions.id
                           AND segments.lifecycle = 'sealed'
                           AND segments.media_format = 'caf-pcm-s16le'
                           AND segments.sample_count > 0
                           AND segments.byte_length > 0
                           AND segments.digest IS NOT NULL),
                        EXISTS(
                          SELECT 1 FROM recovery_runs
                          WHERE recovery_runs.session_id = sessions.id
                            AND recovery_runs.disposition = 'playable_media_recovered'
                        )
                 FROM sessions
                 WHERE sessions.lifecycle != 'deleted'
                 ORDER BY sessions.updated_at_ms DESC, sessions.id DESC",
            )?;
            let rows = statement.query_map([], |row| {
                Ok((
                    row.get::<_, String>(0)?,
                    row.get::<_, String>(1)?,
                    row.get::<_, String>(2)?,
                    row.get::<_, String>(3)?,
                    row.get::<_, String>(4)?,
                    row.get::<_, bool>(5)?,
                    row.get::<_, bool>(6)?,
                    row.get::<_, i64>(7)?,
                    row.get::<_, Option<i64>>(8)?,
                    row.get::<_, Option<String>>(9)?,
                    row.get::<_, Option<i64>>(10)?,
                    row.get::<_, Option<i64>>(11)?,
                    row.get::<_, bool>(12)?,
                ))
            })?;
            rows.collect::<Result<Vec<_>, _>>()?
        };
        after_sessions();

        let mut current_session = None;
        let mut saved_sessions = Vec::new();
        for (
            session_id,
            title,
            origin,
            lifecycle,
            health,
            journal_durable,
            media_files_open,
            updated_at_ms,
            recording_started_at_ms,
            interruption_payload,
            interruption_at_ms,
            recovered_sample_count,
            recovered,
        ) in sessions
        {
            let sources = Self::runtime_source_snapshots(&transaction, &session_id, &lifecycle)?;
            // Recovered tracks have their own validated playback authority. The
            // ordinary saved-audio query deliberately excludes them.
            let playable_media = if recovered {
                None
            } else {
                self.runtime_playable_media_snapshot(
                    &transaction,
                    &session_id,
                    &origin,
                    &lifecycle,
                )?
            };
            let interruption_reason = interruption_payload
                .as_deref()
                .map(serde_json::from_str::<Value>)
                .transpose()?
                .as_ref()
                .map(|payload| payload_string(payload, "reason"))
                .transpose()?
                .map(SessionInterruptionReason::from_str)
                .transpose()?;
            let health = if recovered && interruption_reason.is_some() {
                "degraded".to_owned()
            } else {
                health
            };
            let elapsed_seconds = playable_media
                .as_ref()
                .map(|media| media.duration_nanoseconds / 1_000_000_000)
                .or_else(|| {
                    recovered
                        .then_some(recovered_sample_count)
                        .flatten()
                        .map(|sample_count| {
                            u64::try_from(sample_count).unwrap_or(0)
                                / u64::from(super::MEDIA_SAMPLE_RATE_HZ)
                        })
                })
                .unwrap_or_else(|| {
                    recording_started_at_ms.map_or(0, |started_at_ms| {
                        let end_milliseconds = if lifecycle == "recording" {
                            now_milliseconds.max(started_at_ms)
                        } else {
                            interruption_at_ms
                                .unwrap_or(updated_at_ms)
                                .max(started_at_ms)
                        };
                        u64::try_from(end_milliseconds.saturating_sub(started_at_ms)).unwrap_or(0)
                            / 1_000
                    })
                });
            let snapshot = RuntimeSessionSnapshot {
                session_id: SessionId(session_id),
                title,
                lifecycle: lifecycle.clone(),
                health,
                elapsed_seconds,
                journal_durable,
                media_files_open,
                interruption_reason,
                recovered,
                sources,
                playable_media,
            };
            if lifecycle == "ready_for_review" {
                saved_sessions.push(snapshot);
            } else if current_session.is_none()
                && matches!(
                    lifecycle.as_str(),
                    "preparing" | "recording" | "paused" | "finalizing" | "interrupted"
                )
            {
                current_session = Some(snapshot);
            }
        }

        transaction.commit()?;
        Ok(RuntimeLibrarySnapshot {
            current_session,
            saved_sessions,
        })
    }

    fn runtime_source_snapshots(
        connection: &rusqlite::Connection,
        session_id: &str,
        session_lifecycle: &str,
    ) -> Result<Vec<RuntimeSourceSnapshot>, StoreError> {
        let mut statement = connection.prepare(
            "SELECT required.kind,
                    COALESCE(
                      (SELECT sources.display_name FROM sources
                       WHERE sources.session_id = required.session_id
                         AND sources.kind = required.kind
                       ORDER BY sources.id LIMIT 1),
                      CASE required.kind
                        WHEN 'microphone' THEN 'Mac microphone'
                        WHEN 'application_audio' THEN 'Selected application audio'
                        WHEN 'system_audio' THEN 'Mac system audio'
                      END
                    ),
                    required.lifecycle
             FROM required_sources required
             WHERE required.session_id = ?1
             ORDER BY required.kind",
        )?;
        statement
            .query_map([session_id], |row| {
                Ok((
                    row.get::<_, String>(0)?,
                    row.get::<_, String>(1)?,
                    row.get::<_, String>(2)?,
                ))
            })?
            .map(|row| {
                let (kind, display_name, mut lifecycle) = row?;
                if session_lifecycle == "interrupted" && lifecycle != "sealed" {
                    lifecycle = "failed".to_owned();
                }
                Ok(RuntimeSourceSnapshot {
                    kind: MediaSourceKind::from_str(&kind)?,
                    display_name,
                    lifecycle,
                })
            })
            .collect()
    }

    fn runtime_playable_media_snapshot(
        &self,
        connection: &rusqlite::Connection,
        session_id: &str,
        origin: &str,
        lifecycle: &str,
    ) -> Result<Option<RuntimePlayableMediaSnapshot>, StoreError> {
        if lifecycle != "ready_for_review" {
            return Ok(None);
        }
        let rows = if origin == "import" {
            let mut statement = connection.prepare(
                "SELECT sources.display_name, segments.relative_path,
                        segments.sample_count, segments.byte_length, segments.digest,
                        imports.source_digest, segments.file_device, segments.file_inode
                 FROM imports
                 JOIN segments ON segments.session_id = imports.session_id
                              AND segments.relative_path = imports.relative_path
                 JOIN tracks ON tracks.id = segments.track_id
                             AND tracks.session_id = segments.session_id
                 JOIN sources ON sources.id = tracks.source_id
                              AND sources.session_id = tracks.session_id
                 WHERE imports.session_id = ?1
                   AND segments.lifecycle = 'sealed'
                   AND segments.media_format = 'caf-pcm-s16le'
                 ORDER BY segments.sequence",
            )?;
            statement
                .query_map([session_id], playable_media_row)?
                .collect::<Result<Vec<_>, _>>()?
        } else if origin == "capture" {
            let mut statement = connection.prepare(
                "SELECT sources.display_name, segments.relative_path,
                        segments.sample_count, segments.byte_length, segments.digest,
                        segments.digest, segments.file_device, segments.file_inode
                 FROM sessions
                 JOIN segments ON segments.session_id = sessions.id
                 JOIN tracks ON tracks.id = segments.track_id
                             AND tracks.session_id = segments.session_id
                 JOIN sources ON sources.id = tracks.source_id
                              AND sources.session_id = tracks.session_id
                 WHERE sessions.id = ?1
                   AND sessions.origin = 'capture'
                   AND sessions.lifecycle = 'ready_for_review'
                   AND sessions.health IN ('healthy', 'degraded')
                   AND segments.lifecycle = 'sealed'
                   AND segments.seal_state = 'sealed'
                   AND segments.recovery_state = 'not_required'
                   AND segments.media_format = 'caf-pcm-s16le'
                   AND NOT EXISTS (
                     SELECT 1 FROM recovery_runs
                     WHERE recovery_runs.session_id = sessions.id
                       AND recovery_runs.disposition = 'playable_media_recovered'
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
                .query_map([session_id], playable_media_row)?
                .collect::<Result<Vec<_>, _>>()?
        } else {
            return Ok(None);
        };
        if rows.len() != 1 {
            return Ok(Some(RuntimePlayableMediaSnapshot {
                source_display_name: "Saved audio".to_owned(),
                availability: RuntimePlayableMediaAvailability::Corrupt,
                absolute_path: None,
                duration_nanoseconds: 0,
                sample_count: 0,
                byte_length: 0,
            }));
        }
        let (
            source_display_name,
            relative_path,
            stored_sample_count,
            stored_byte_length,
            digest_sha256,
            import_digest_sha256,
            stored_device,
            stored_inode,
        ) = &rows[0];
        let sample_count = u64::try_from(*stored_sample_count).unwrap_or(0);
        let byte_length = u64::try_from(*stored_byte_length).unwrap_or(0);
        let duration_nanoseconds = sample_count.saturating_mul(1_000_000_000) / 48_000;
        let base = |availability| RuntimePlayableMediaSnapshot {
            source_display_name: source_display_name.clone(),
            availability,
            absolute_path: None,
            duration_nanoseconds,
            sample_count,
            byte_length,
        };
        if !valid_media_relative_path(relative_path)
            || sample_count == 0
            || byte_length == 0
            || digest_sha256.len() != 64
            || digest_sha256 != import_digest_sha256
        {
            return Ok(Some(base(RuntimePlayableMediaAvailability::Corrupt)));
        }
        let absolute_path = self.session_directory(session_id)?.join(relative_path);
        match fs::symlink_metadata(&absolute_path) {
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
                return Ok(Some(base(RuntimePlayableMediaAvailability::Unavailable)));
            }
            Err(_) => {
                return Ok(Some(base(RuntimePlayableMediaAvailability::Corrupt)));
            }
            Ok(_) => {}
        }
        let Ok(validated) = self.validate_media_file(
            session_id,
            relative_path,
            MediaLengthRequirement::Exact(byte_length),
            true,
        ) else {
            return Ok(Some(base(RuntimePlayableMediaAvailability::Corrupt)));
        };
        if validated.device != u64::try_from(*stored_device).unwrap_or(0)
            || validated.inode != u64::try_from(*stored_inode).unwrap_or(0)
            || validated.recoverable_sample_count != Some(sample_count)
            || validated.digest_sha256.as_deref() != Some(import_digest_sha256.as_str())
        {
            return Ok(Some(base(RuntimePlayableMediaAvailability::Corrupt)));
        }
        Ok(Some(base(RuntimePlayableMediaAvailability::Available)))
    }
}

type PlayableMediaRow = (String, String, i64, i64, String, String, i64, i64);

fn playable_media_row(row: &rusqlite::Row<'_>) -> rusqlite::Result<PlayableMediaRow> {
    Ok((
        row.get(0)?,
        row.get(1)?,
        row.get(2)?,
        row.get(3)?,
        row.get(4)?,
        row.get(5)?,
        row.get(6)?,
        row.get(7)?,
    ))
}
