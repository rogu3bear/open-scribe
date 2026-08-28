use open_scribe_types::SessionId;
use serde_json::Value;

use super::{
    MediaSourceKind, SessionInterruptionReason, SessionStore, StoreError, payload_string,
    wall_time_milliseconds,
};

/// One coarse, content-free source state for native presentation.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct RuntimeSourceSnapshot {
    pub kind: MediaSourceKind,
    pub display_name: String,
    pub lifecycle: String,
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
        let sessions = {
            let mut statement = self.connection.prepare(
                "SELECT sessions.id, sessions.title, sessions.lifecycle, sessions.health,
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
                    row.get::<_, bool>(4)?,
                    row.get::<_, bool>(5)?,
                    row.get::<_, i64>(6)?,
                    row.get::<_, Option<i64>>(7)?,
                    row.get::<_, Option<String>>(8)?,
                    row.get::<_, bool>(9)?,
                ))
            })?;
            rows.collect::<Result<Vec<_>, _>>()?
        };

        let mut current_session = None;
        let mut saved_sessions = Vec::new();
        for (
            session_id,
            title,
            lifecycle,
            health,
            journal_durable,
            media_files_open,
            updated_at_ms,
            recording_started_at_ms,
            interruption_payload,
            recovered,
        ) in sessions
        {
            let sources = self.runtime_source_snapshots(&session_id, &lifecycle)?;
            let interruption_reason = interruption_payload
                .as_deref()
                .map(serde_json::from_str::<Value>)
                .transpose()?
                .as_ref()
                .map(|payload| payload_string(payload, "reason"))
                .transpose()?
                .map(SessionInterruptionReason::from_str)
                .transpose()?;
            let elapsed_seconds = recording_started_at_ms.map_or(0, |started_at_ms| {
                let end_milliseconds = if lifecycle == "recording" {
                    now_milliseconds.max(started_at_ms)
                } else {
                    updated_at_ms.max(started_at_ms)
                };
                u64::try_from(end_milliseconds.saturating_sub(started_at_ms)).unwrap_or(0) / 1_000
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

        Ok(RuntimeLibrarySnapshot {
            current_session,
            saved_sessions,
        })
    }

    fn runtime_source_snapshots(
        &self,
        session_id: &str,
        session_lifecycle: &str,
    ) -> Result<Vec<RuntimeSourceSnapshot>, StoreError> {
        let mut statement = self.connection.prepare(
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
}
