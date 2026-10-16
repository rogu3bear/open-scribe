use std::fs;
use std::path::PathBuf;

use open_scribe_types::SessionId;
use rusqlite::OptionalExtension;
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

/// Coarse derived-transcript posture of one saved conversation. It is read
/// from runs, chunks, and selections; it never claims more than the store
/// has committed.
#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub enum RuntimeTranscriptState {
    /// No transcribable track, or no run has been attempted on one.
    #[default]
    None,
    /// At least one track has a run still in progress.
    Running,
    /// Every transcribable track has a selected Final revision.
    Final,
    /// Some tracks are Final; the rest have no attempt or were cancelled.
    Partial,
    /// A track without a selected revision has a latest run that failed.
    Failed,
    /// A track without a selected revision has a latest run the user
    /// cancelled; nothing restarts it until they ask.
    Cancelled,
    Unknown,
}

impl RuntimeTranscriptState {
    #[must_use]
    pub const fn code(self) -> &'static str {
        match self {
            Self::None => "none",
            Self::Running => "running",
            Self::Final => "final",
            Self::Partial => "partial",
            Self::Failed => "failed",
            Self::Cancelled => "cancelled",
            Self::Unknown => "unknown",
        }
    }
}

/// Content-free transcript progress for the native library surfaces.
#[derive(Clone, Debug, Default, Eq, PartialEq)]
pub struct RuntimeTranscriptSnapshot {
    pub document: open_scribe_types::DocumentAvailability,
    pub replacement_resumable: bool,
    pub state: RuntimeTranscriptState,
    pub selected_revision_ids: Vec<String>,
    /// Content-free identity of selection plus human edits, for native reloads.
    pub document_version: String,
    pub attempt: open_scribe_types::AttemptState,
    pub attempt_failure: Option<String>,
    /// Sealed tracks a transcript can cover.
    pub total_tracks: u32,
    /// Tracks with a selected Final revision.
    pub final_tracks: u32,
    /// Complete chunks across the running runs, when `state` is `Running`.
    pub completed_chunks: u32,
    /// Planned chunks across the running runs, when `state` is `Running`.
    pub total_chunks: u32,
    /// The failure class of the latest failed run, when `state` is `Failed`.
    pub failure_class: Option<String>,
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
    pub has_capture_timeline: bool,
    pub sources: Vec<RuntimeSourceSnapshot>,
    pub playable_media: Option<RuntimePlayableMediaSnapshot>,
    pub transcript: RuntimeTranscriptSnapshot,
}

/// One read-only authority snapshot shared by the native live and library surfaces.
/// `current_session` is the newest nonterminal session. `saved_sessions` holds
/// reviewable conversations and any older interrupted sessions, which are not
/// themselves saved recordings.
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

    pub fn runtime_library_snapshot_at_host(
        &self,
        host_time: u64,
    ) -> Result<RuntimeLibrarySnapshot, StoreError> {
        self.runtime_snapshot_observed(wall_time_milliseconds(), || {}, Some(host_time))
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
        self.runtime_snapshot_observed(now_milliseconds, after_sessions, None)
    }

    fn runtime_snapshot_observed<F: FnOnce()>(
        &self,
        now_milliseconds: i64,
        after_sessions: F,
        host_time: Option<u64>,
    ) -> Result<RuntimeLibrarySnapshot, StoreError> {
        // One read snapshot; deferred so it never holds the write lock that
        // store connections otherwise take at BEGIN.
        let transaction = rusqlite::Transaction::new_unchecked(
            &self.connection,
            rusqlite::TransactionBehavior::Deferred,
        )?;
        let sessions = {
            let mut statement = transaction.prepare_cached(
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
                        (SELECT CAST(MAX(segments.mapped_start_ns / 1000000000.0 * 48000 + segments.sample_count) AS INTEGER)
                         FROM segments
                         WHERE segments.session_id = sessions.id
                           AND segments.lifecycle = 'sealed'
                           AND segments.media_format IN ('caf-pcm-s16le', 'm4a-alac-or-aac')
                           AND segments.sample_count > 0
                           AND segments.byte_length > 0
                           AND segments.digest IS NOT NULL),
                        EXISTS(
                          SELECT 1 FROM recovery_runs
                          WHERE recovery_runs.session_id = sessions.id
                            AND recovery_runs.disposition IN ('playable_media_recovered', 'timeline_recovered')
                        )
                 FROM sessions
                 WHERE sessions.lifecycle != 'deleted'
                 ORDER BY sessions.created_at_ms DESC, sessions.id DESC",
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
            let has_capture_timeline: bool = transaction.query_row(
                "SELECT EXISTS(SELECT 1 FROM session_events WHERE session_id = ?1 AND event_kind = 'capture_clock_anchored')
                    OR EXISTS(SELECT 1 FROM session_restorations JOIN sessions ON sessions.id = session_restorations.session_id
                              WHERE session_restorations.session_id = ?1 AND session_restorations.state = 'restored'
                                AND sessions.origin = 'capture')",
                [&session_id], |row| row.get(0),
            )?;
            let playable_media = if recovered || has_capture_timeline {
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
            let mut elapsed_seconds = playable_media
                .as_ref()
                .map(|media| media.duration_nanoseconds / 1_000_000_000)
                .or_else(|| {
                    (lifecycle == "ready_for_review")
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
            if has_capture_timeline {
                // Authoritative accepted frames and calibrated capture intervals.
                // Wall-clock adjustments and metadata edits never advance these.
                let durable: i64 = transaction.query_row("SELECT MAX(
                    COALESCE((SELECT MAX(mapped_start_ns + sample_count * 1000000000 / 48000) FROM segments WHERE session_id = ?1 AND lifecycle = 'sealed'),0),
                    COALESCE((SELECT MAX(session_nanoseconds) FROM session_events WHERE session_id = ?1 AND event_kind IN ('capture_paused','paused_session_finalized','segment_sealed')),0))",
                    [&session_id], |row| row.get(0))?;
                let observed = if lifecycle == "recording" {
                    host_time
                        .map(|host| self.map_capture_time(&session_id, host))
                        .transpose()?
                        .unwrap_or(durable)
                } else {
                    durable
                };
                elapsed_seconds = observed.max(durable).max(0) as u64 / 1_000_000_000;
            } else if matches!(lifecycle.as_str(), "paused" | "recording" | "preparing") {
                // Limited compatibility for legacy untimed captures only.
                let mut boundary = transaction.prepare_cached("SELECT event_kind, session_nanoseconds, wall_time_ms FROM session_events WHERE session_id = ?1 AND event_kind IN ('capture_paused', 'capture_resumed') ORDER BY sequence DESC LIMIT 1")?;
                let mut rows = boundary.query([&session_id])?;
                if let Some(row) = rows.next()? {
                    let kind: String = row.get(0)?;
                    let position: i64 = row.get(1)?;
                    let wall: i64 = row.get(2)?;
                    let advancing = if lifecycle == "recording" && kind == "capture_resumed" {
                        now_milliseconds.saturating_sub(wall).max(0) / 1000
                    } else {
                        0
                    };
                    elapsed_seconds = (position.max(0) / 1_000_000_000 + advancing) as u64;
                }
            }
            let transcript = if lifecycle == "ready_for_review" {
                self.runtime_transcript_snapshot(&transaction, &session_id)?
            } else {
                RuntimeTranscriptSnapshot::default()
            };
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
                has_capture_timeline,
                sources,
                playable_media,
                transcript,
            };
            if lifecycle == "ready_for_review" {
                saved_sessions.push(snapshot);
            } else if lifecycle == "interrupted" {
                // The newest nonterminal session stays in Now. Older
                // interrupted sessions remain listable so they can be reviewed
                // and deleted; they are not saved recordings.
                if current_session.is_none() {
                    current_session = Some(snapshot);
                } else {
                    saved_sessions.push(snapshot);
                }
            } else if current_session.is_none()
                && matches!(
                    lifecycle.as_str(),
                    "preparing" | "recording" | "paused" | "finalizing"
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

    /// Derived-transcript posture over the session's transcribable tracks.
    pub(super) fn runtime_transcript_snapshot(
        &self,
        connection: &rusqlite::Connection,
        session_id: &str,
    ) -> Result<RuntimeTranscriptSnapshot, StoreError> {
        let tracks = self.transcription_tracks(&SessionId(session_id.to_owned()))?;
        let mut snapshot = RuntimeTranscriptSnapshot {
            total_tracks: tracks.len() as u32,
            ..RuntimeTranscriptSnapshot::default()
        };
        if tracks.is_empty() {
            return Ok(snapshot);
        }
        let versions: Vec<(String, String, i64)> = connection.prepare_cached("SELECT selection.track_id, selection.revision_id,
            COALESCE(epoch.epoch, 0) FROM transcript_selections selection LEFT JOIN transcript_selection_epochs epoch
            ON epoch.session_id = selection.session_id AND epoch.track_id = selection.track_id
            WHERE selection.session_id = ?1 ORDER BY selection.track_id")?
            .query_map([session_id], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)))?.collect::<Result<_,_>>()?;
        snapshot.selected_revision_ids = versions
            .iter()
            .map(|(_, revision, _)| revision.clone())
            .collect();
        snapshot.document_version = super::digest_json(&versions)?;
        let mut selected = connection.prepare_cached(
            "SELECT EXISTS(SELECT 1 FROM transcript_selections
                           WHERE session_id = ?1 AND track_id = ?2)",
        )?;
        let mut latest = connection.prepare_cached(
            "SELECT runs.state, runs.failure_class,
                    (SELECT COUNT(*) FROM transcript_chunks
                     WHERE run_id = runs.id AND state = 'complete'),
                    (SELECT COUNT(*) FROM transcript_chunks WHERE run_id = runs.id)
             FROM transcription_runs AS runs
             WHERE runs.session_id = ?1 AND runs.track_id = ?2
             ORDER BY runs.created_at_ms DESC, runs.id DESC LIMIT 1",
        )?;
        let mut running = 0_u32;
        let mut failed = 0_u32;
        let mut cancelled = 0_u32;
        let mut unsupported = false;
        for track in &tracks {
            let is_selected: bool =
                selected.query_row([session_id, track.as_str()], |row| row.get(0))?;
            if is_selected {
                snapshot.final_tracks += 1;
            }
            let run: Option<(String, Option<String>, i64, i64)> = latest
                .query_row([session_id, track.as_str()], |row| {
                    Ok((row.get(0)?, row.get(1)?, row.get(2)?, row.get(3)?))
                })
                .optional()?;
            match run {
                Some((state, _, complete, total)) if state == "running" => {
                    if !is_selected {
                        running += 1;
                    }
                    snapshot.attempt = open_scribe_domain::merge_transcription_attempt(
                        snapshot.attempt,
                        open_scribe_types::AttemptState::Running,
                    );
                    snapshot.completed_chunks += u32::try_from(complete).unwrap_or(u32::MAX);
                    snapshot.total_chunks += u32::try_from(total).unwrap_or(u32::MAX);
                }
                Some((state, failure_class, _, _)) if state == "failed" => {
                    if !is_selected {
                        failed += 1;
                    }
                    snapshot.attempt = open_scribe_domain::merge_transcription_attempt(
                        snapshot.attempt,
                        open_scribe_types::AttemptState::Failed,
                    );
                    if snapshot.attempt == open_scribe_types::AttemptState::Failed {
                        snapshot.attempt_failure = failure_class.clone();
                    }
                    if snapshot.failure_class.is_none() {
                        snapshot.failure_class = failure_class;
                    }
                }
                // A superseded cancellation always has a newer run, so the
                // latest cancelled run is one the user stopped.
                Some((state, failure_class, _, _))
                    if state == "cancelled"
                        && matches!(
                            failure_class.as_deref(),
                            Some("cancelled" | "capture_preempted")
                        ) =>
                {
                    if !is_selected {
                        cancelled += 1;
                    }
                    snapshot.attempt = open_scribe_domain::merge_transcription_attempt(
                        snapshot.attempt,
                        if failure_class.as_deref() == Some("capture_preempted") {
                            open_scribe_types::AttemptState::Preempted
                        } else {
                            open_scribe_types::AttemptState::Cancelled
                        },
                    );
                }
                Some((state, _, _, _)) if state == "complete" => {
                    snapshot.attempt = open_scribe_domain::merge_transcription_attempt(
                        snapshot.attempt,
                        open_scribe_types::AttemptState::Complete,
                    );
                }
                Some(_) => {
                    unsupported = true;
                }
                None => {}
            }
        }
        if unsupported {
            snapshot.attempt = open_scribe_types::AttemptState::Unknown;
        }
        if snapshot.attempt != open_scribe_types::AttemptState::Failed {
            snapshot.attempt_failure = None;
        }
        // Recognizers use a cancellation flag for capture preemption too. The
        // accepted operation outcome supplies that missing stop reason without
        // rewriting any engine run/failure history or masking a live attempt.
        let accepted_outcome: Option<String> = connection
            .query_row(
                "SELECT last_outcome FROM transcription_intent WHERE session_id = ?1",
                [session_id],
                |row| row.get::<_, Option<String>>(0),
            )
            .optional()?
            .flatten();
        let accepted_preemption = !unsupported
            && snapshot.attempt != open_scribe_types::AttemptState::Running
            && accepted_outcome
                .as_deref()
                .and_then(open_scribe_types::WorkOutcome::from_code)
                == Some(open_scribe_types::WorkOutcome::CapturePreempted);
        if accepted_preemption {
            snapshot.attempt = open_scribe_types::AttemptState::Preempted;
            snapshot.attempt_failure = None;
        }
        snapshot.replacement_resumable = connection.query_row("SELECT EXISTS(SELECT 1 FROM transcription_intent WHERE session_id = ?1
            AND admission IS NULL AND last_action = 'reprocess' AND last_outcome IN ('failed','preempted'))", [session_id], |r| r.get(0))?;
        snapshot.document = if snapshot.final_tracks == snapshot.total_tracks {
            open_scribe_types::DocumentAvailability::Final
        } else if snapshot.final_tracks > 0 {
            open_scribe_types::DocumentAvailability::Partial
        } else if unsupported {
            open_scribe_types::DocumentAvailability::Unavailable
        } else {
            open_scribe_types::DocumentAvailability::None
        };
        snapshot.state = if snapshot.final_tracks == snapshot.total_tracks {
            RuntimeTranscriptState::Final
        } else if unsupported {
            RuntimeTranscriptState::Unknown
        } else if accepted_preemption {
            RuntimeTranscriptState::Cancelled
        } else if running > 0 {
            RuntimeTranscriptState::Running
        } else if failed > 0 {
            RuntimeTranscriptState::Failed
        } else if cancelled > 0 {
            RuntimeTranscriptState::Cancelled
        } else if snapshot.final_tracks > 0 {
            RuntimeTranscriptState::Partial
        } else {
            RuntimeTranscriptState::None
        };
        if snapshot.state != RuntimeTranscriptState::Failed {
            snapshot.failure_class = None;
        }
        Ok(snapshot)
    }

    fn runtime_source_snapshots(
        connection: &rusqlite::Connection,
        session_id: &str,
        session_lifecycle: &str,
    ) -> Result<Vec<RuntimeSourceSnapshot>, StoreError> {
        let mut statement = connection.prepare_cached(
            "SELECT required.kind,
                    COALESCE(
                      (SELECT sources.display_name FROM sources
                       WHERE sources.session_id = required.session_id
                         AND sources.kind = required.kind
                       ORDER BY sources.id DESC LIMIT 1),
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
            let mut statement = connection.prepare_cached(
                "SELECT sources.display_name, segments.relative_path,
                        segments.sample_count, segments.byte_length, segments.digest,
                        imports.source_digest, segments.file_device, segments.file_inode,
                        segments.media_format
                 FROM imports
                 JOIN segments ON segments.session_id = imports.session_id
                              AND segments.relative_path = imports.relative_path
                 JOIN tracks ON tracks.id = segments.track_id
                             AND tracks.session_id = segments.session_id
                 JOIN sources ON sources.id = tracks.source_id
                              AND sources.session_id = tracks.session_id
                 WHERE imports.session_id = ?1
                   AND segments.lifecycle = 'sealed'
                   AND segments.media_format IN ('caf-pcm-s16le', 'm4a-alac-or-aac')
                 ORDER BY segments.sequence",
            )?;
            statement
                .query_map([session_id], playable_media_row)?
                .collect::<Result<Vec<_>, _>>()?
        } else if origin == "capture" {
            let mut statement = connection.prepare_cached(
                "SELECT sources.display_name, segments.relative_path,
                        segments.sample_count, segments.byte_length, segments.digest,
                        segments.digest, segments.file_device, segments.file_inode,
                        segments.media_format
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
            media_format,
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
        if !(valid_media_relative_path(relative_path)
            || (origin == "import"
                && media_format == "m4a-alac-or-aac"
                && relative_path.starts_with("audio/")
                && relative_path.ends_with("/000000-import.m4a")))
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
        // Probe the complete managed path and CAF layout before recalling a
        // digest. The import validator always hashes CAF, so dispatch locally
        // rather than changing validation for playback or other consumers.
        let validate = |calculate_digest| {
            if media_format == "caf-pcm-s16le" {
                self.observe_sealed_media_file(
                    session_id,
                    relative_path,
                    MediaLengthRequirement::Exact(byte_length),
                    calculate_digest,
                )
            } else {
                self.validate_import_media_file(
                    session_id,
                    relative_path,
                    byte_length,
                    media_format,
                    calculate_digest,
                )
            }
        };
        let validated = if media_format == "caf-pcm-s16le" {
            // One open. The sealed-read path reuses a digest already checked
            // for this file identity and hashes the audio at most once.
            validate(true)
        } else {
            match validate(false) {
                Ok(mut media)
                    if media.device != u64::try_from(*stored_device).unwrap_or(0)
                        && media.digest_sha256.is_none() =>
                {
                    let cached = self
                        .snapshot_digest_memo
                        .borrow()
                        .get(&media.identity)
                        .cloned();
                    if let Some(digest) = cached {
                        media.digest_sha256 = Some(digest);
                        Ok(media)
                    } else {
                        validate(true)
                    }
                }
                other => other,
            }
        };
        let Ok(validated) = validated else {
            return Ok(Some(base(RuntimePlayableMediaAvailability::Corrupt)));
        };
        if !validated.matches_sealed_identity(
            u64::try_from(*stored_device).unwrap_or(0),
            u64::try_from(*stored_inode).unwrap_or(0),
            byte_length,
            import_digest_sha256,
        ) || (media_format == "caf-pcm-s16le"
            && validated.recoverable_sample_count != Some(sample_count))
            || (media_format == "caf-pcm-s16le"
                && validated.digest_sha256.as_deref() != Some(import_digest_sha256.as_str()))
        {
            return Ok(Some(base(RuntimePlayableMediaAvailability::Corrupt)));
        }
        if let Some(digest) = validated.digest_sha256 {
            // This cache belongs only to read-only UI polling. A fresh nofollow
            // path rebind and full change-timestamp fingerprint precede lookup;
            // insertion follows all sealed receipt comparisons above.
            self.remember_snapshot_digest(validated.identity, digest);
        }
        Ok(Some(base(RuntimePlayableMediaAvailability::Available)))
    }
}

type PlayableMediaRow = (String, String, i64, i64, String, String, i64, i64, String);

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
        row.get(8)?,
    ))
}
