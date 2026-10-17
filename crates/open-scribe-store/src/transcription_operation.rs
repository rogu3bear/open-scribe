//! Binds run history to one deliberate replacement operation and its original
//! review selections. Capture preemption changes admission, never this intent.
use super::*;
use rusqlite::OptionalExtension;

#[derive(Clone, Debug, Default, Eq, PartialEq, Serialize, Deserialize)]
pub struct SelectionExpectation {
    pub revision_id: Option<String>,
    pub epoch: i64,
}
#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
pub struct TrackSelectionExpectation {
    pub track_id: String,
    pub selection: SelectionExpectation,
}
#[derive(Clone, Debug, Default)]
pub struct TranscriptionOperation {
    pub intent: open_scribe_types::TranscriptionIntent,
    pub key: Option<String>,
    pub selections: Vec<TrackSelectionExpectation>,
}
#[derive(Clone, Debug, Default)]
pub struct TranscriptionRunPolicy {
    pub operation_key: Option<String>,
    pub selection: Option<SelectionExpectation>,
}

pub(super) fn apply_schema(tx: &Transaction<'_>) -> Result<(), StoreError> {
    for (table, column, definition) in [
        ("transcription_runs", "operation_key", "TEXT"),
        ("transcription_intent", "selection_json", "TEXT"),
        ("transcription_intent", "admitted_selection_json", "TEXT"),
        ("transcription_intent", "last_action", "TEXT"),
        (
            "transcription_intent",
            "runner_started",
            "INTEGER NOT NULL DEFAULT 0",
        ),
        (
            "transcription_intent",
            "request_generation",
            "INTEGER NOT NULL DEFAULT 0",
        ),
        ("transcription_intent", "admitted_generation", "INTEGER"),
    ] {
        let columns = tx
            .prepare(&format!("PRAGMA table_info({table})"))?
            .query_map([], |r| r.get::<_, String>(1))?
            .collect::<Result<Vec<_>, _>>()?;
        if !columns.iter().any(|name| name == column) {
            tx.execute_batch(&format!(
                "ALTER TABLE {table} ADD COLUMN {column} {definition}"
            ))?;
        }
    }
    tx.execute_batch(
        "CREATE TRIGGER IF NOT EXISTS transcription_operation_immutable
        BEFORE UPDATE OF operation_key ON transcription_runs BEGIN
        SELECT RAISE(ABORT, 'transcription operation binding is immutable'); END;",
    )?;
    tx.execute(
        "INSERT OR IGNORE INTO schema_migrations VALUES(13, ?1)",
        [wall_time_milliseconds()],
    )?;
    Ok(())
}

impl SessionStore {
    /// Coarse readiness only. Execution revalidates input and hypotheses.
    pub(super) fn retained_plan_available(
        &self,
        session: &SessionId,
        intent: open_scribe_types::TranscriptionIntent,
    ) -> Result<bool, StoreError> {
        use open_scribe_types::TranscriptionIntent;
        for track in self.transcription_tracks(session)? {
            if intent != TranscriptionIntent::ReprocessAll {
                let selected: bool = self.connection.query_row("SELECT EXISTS(SELECT 1 FROM transcript_selections WHERE session_id = ?1 AND track_id = ?2)", params![session.0, track], |r| r.get(0))?;
                if selected {
                    continue;
                }
            }
            let retained: bool = self.connection.query_row("SELECT EXISTS(SELECT 1 FROM transcription_runs runs WHERE session_id = ?1 AND track_id = ?2
                AND (state IN ('running','cancelled') OR (?3 AND state = 'complete')
                  OR (state = 'failed' AND failure_class IN ('invalid_result','stale_reconciliation','orphaned','storage_error')))
                AND EXISTS(SELECT 1 FROM transcript_chunks WHERE run_id = runs.id)
                AND NOT EXISTS(SELECT 1 FROM transcript_chunks WHERE run_id = runs.id AND state <> 'complete'))",
                params![session.0, track, intent == TranscriptionIntent::ReprocessAll], |r| r.get(0))?;
            if !retained {
                return Ok(false);
            }
        }
        Ok(true)
    }
    pub fn fresh_transcription_operation() -> String {
        Uuid::now_v7().to_string()
    }
    pub fn selection_expectation(
        &self,
        session: &SessionId,
        track: &str,
    ) -> Result<SelectionExpectation, StoreError> {
        Ok(SelectionExpectation {
            revision_id: self.connection.query_row("SELECT revision_id FROM transcript_selections WHERE session_id = ?1 AND track_id = ?2",
                params![session.0, track], |r| r.get(0)).optional()?,
            epoch: self.connection.query_row("SELECT COALESCE((SELECT epoch FROM transcript_selection_epochs WHERE session_id = ?1 AND track_id = ?2),0)",
                params![session.0, track], |r| r.get(0))?,
        })
    }
    pub fn selection_expectations(
        &self,
        session: &SessionId,
    ) -> Result<Vec<TrackSelectionExpectation>, StoreError> {
        Ok(self.connection.prepare("SELECT tracks.id, selection.revision_id, COALESCE(epoch.epoch,0)
            FROM tracks LEFT JOIN transcript_selections selection ON selection.session_id = tracks.session_id AND selection.track_id = tracks.id
            LEFT JOIN transcript_selection_epochs epoch ON epoch.session_id = tracks.session_id AND epoch.track_id = tracks.id
            WHERE tracks.session_id = ?1 ORDER BY tracks.id")?
            .query_map([&session.0], |r| Ok(TrackSelectionExpectation { track_id: r.get(0)?,
                selection: SelectionExpectation { revision_id: r.get(1)?, epoch: r.get(2)? } }))?.collect::<Result<_,_>>()?)
    }
    pub(super) fn selection_json(&self, session: &SessionId) -> Result<String, StoreError> {
        Ok(serde_json::to_string(
            &self.selection_expectations(session)?,
        )?)
    }
    pub fn transcription_operation(
        &self,
        session: &SessionId,
        admission: &str,
    ) -> Result<TranscriptionOperation, StoreError> {
        let (action, generation, selections): (String, i64, Option<String>) =
            self.connection.query_row(
                "SELECT admitted_action, COALESCE(admitted_generation,0), admitted_selection_json
             FROM transcription_intent WHERE session_id = ?1 AND admission = ?2",
                params![session.0, admission],
                |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)),
            )?;
        Ok(TranscriptionOperation {
            intent: open_scribe_types::TranscriptionIntent::from_code(&action).ok_or(
                StoreError::InvalidState("unsupported transcription operation"),
            )?,
            key: (action == "reprocess").then(|| format!("{}:{generation}", session.0)),
            selections: selections
                .as_deref()
                .map(serde_json::from_str)
                .transpose()?
                .unwrap_or_default(),
        })
    }
    pub fn completed_operation_track(
        &self,
        key: &str,
        session: &SessionId,
        track: &str,
        input_digest: &str,
    ) -> Result<bool, StoreError> {
        Ok(self.connection.query_row(
            "SELECT EXISTS(SELECT 1 FROM transcription_runs WHERE operation_key = ?1
            AND session_id = ?2 AND track_id = ?3 AND input_digest = ?4 AND state = 'complete')",
            params![key, session.0, track, input_digest],
            |r| r.get(0),
        )?)
    }
    /// Explicit continuation of a failed replacement, with its original review
    /// guards and operation key. A generic Retry never creates ReprocessAll.
    pub fn resume_replacement(&mut self, session: &SessionId) -> Result<(), StoreError> {
        let _writer = self.write_guard()?;
        super::session_deletion::require_available(&self.connection, &session.0)?;
        if self.connection.execute(
            "UPDATE transcription_intent SET requested_action = 'reprocess',
            requested_at_ms = ?2, declined_auto = 0, last_outcome = NULL
            WHERE session_id = ?1 AND admission IS NULL AND last_action = 'reprocess'
              AND last_outcome IN ('failed','preempted')",
            params![session.0, wall_time_milliseconds()],
        )? != 1
        {
            return Err(StoreError::InvalidState(
                "no resumable replacement operation",
            ));
        }
        Ok(())
    }
}

pub(super) fn apply_selection_guard(
    tx: &Transaction<'_>,
    run: &str,
    expected: &SelectionExpectation,
) -> Result<(), StoreError> {
    // Never widen an older guard when resuming a run. Legacy runs with no guard
    // remain conservative and cannot displace an existing selected document.
    tx.execute(
        "UPDATE transcription_selection_guards SET expected_revision = ?2, expected_epoch = ?3
        WHERE run_id = ?1 AND expected_epoch >= ?3",
        params![run, expected.revision_id, expected.epoch],
    )?;
    Ok(())
}
