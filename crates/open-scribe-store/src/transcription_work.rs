//! Minimal durable user intent. Queue positions and eligibility are derived;
//! run/chunk history remains the authority for actual processing progress.
use super::*;
use open_scribe_types::{TranscriptionIntent, WorkHold, WorkObservations, WorkOutcome};
use rusqlite::OptionalExtension;
#[cfg(test)]
#[path = "transcription_work_tests.rs"]
mod tests;

type IntentRow = (
    Option<String>,
    i64,
    bool,
    Option<String>,
    Option<String>,
    Option<String>,
    Option<bool>,
);

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct TranscriptionWork {
    pub session_id: SessionId,
    pub manual: bool,
    pub intent: TranscriptionIntent,
    pub hold: Option<WorkHold>,
    pub admission: Option<String>,
    pub outcome: Option<WorkOutcome>,
}

pub(super) fn apply_schema(tx: &Transaction<'_>) -> Result<(), StoreError> {
    tx.execute_batch(
        "CREATE TABLE IF NOT EXISTS transcription_intent (
        session_id TEXT PRIMARY KEY REFERENCES sessions(id) ON DELETE CASCADE,
        requested_action TEXT, requested_at_ms INTEGER,
        declined_auto INTEGER NOT NULL DEFAULT 0,
        admission TEXT UNIQUE, admitted_action TEXT, admitted_manual INTEGER,
        runner_started INTEGER NOT NULL DEFAULT 0,
        request_generation INTEGER NOT NULL DEFAULT 0, admitted_generation INTEGER,
        last_outcome TEXT);",
    )?;
    tx.execute(
        "INSERT OR IGNORE INTO schema_migrations VALUES(11, ?1)",
        [wall_time_milliseconds()],
    )?;
    Ok(())
}

impl SessionStore {
    pub fn capture_active(&self) -> Result<bool, StoreError> {
        Ok(self
            .connection
            .query_row(&library_recovery::active_capture_sql(), [], |r| r.get(0))?)
    }
    pub fn work_admission_active(&self) -> Result<bool, StoreError> {
        Ok(self.connection.query_row(
            "SELECT EXISTS(SELECT 1 FROM transcription_intent WHERE admission IS NOT NULL)",
            [],
            |r| r.get(0),
        )?)
    }
    pub fn transcription_is_declined(&self, session: &SessionId) -> Result<bool, StoreError> {
        Ok(self.connection.query_row("SELECT EXISTS(SELECT 1 FROM transcription_intent WHERE session_id = ?1 AND declined_auto = 1)", [&session.0], |r| r.get(0))?)
    }
    /// Repeated requests do not duplicate an active or queued operation.
    pub fn request_transcription(
        &mut self,
        session: &SessionId,
        intent: TranscriptionIntent,
    ) -> Result<(), StoreError> {
        let _writer = self.write_guard()?;
        super::session_deletion::require_available(&self.connection, &session.0)?;
        if self.transcription_tracks(session)?.is_empty() {
            return Err(StoreError::InvalidState(
                "session has no transcribable saved tracks",
            ));
        }
        let selections = self.selection_json(session)?;
        self.connection.execute("INSERT INTO transcription_intent(session_id, requested_action, requested_at_ms, request_generation, selection_json)
            VALUES(?1, ?2, ?3, 1, ?4) ON CONFLICT(session_id) DO UPDATE SET
            selection_json = CASE WHEN requested_action IS NOT excluded.requested_action OR last_outcome = 'cancelled' THEN excluded.selection_json ELSE COALESCE(selection_json, excluded.selection_json) END,
            request_generation = request_generation + CASE WHEN requested_action IS NOT excluded.requested_action OR last_outcome = 'cancelled' THEN 1 ELSE 0 END,
            requested_action = excluded.requested_action,
            requested_at_ms = CASE WHEN requested_action IS NOT excluded.requested_action THEN excluded.requested_at_ms ELSE COALESCE(requested_at_ms, excluded.requested_at_ms) END,
            declined_auto = 0, last_outcome = NULL",
            params![session.0, intent.code(), wall_time_milliseconds(), selections])?;
        Ok(())
    }

    /// A permanent per-session opt-out, including explicit cancellation.
    /// Active admission is retained until its runner acknowledges the stop.
    pub fn cancel_transcription(&mut self, session: &SessionId) -> Result<(), StoreError> {
        let _writer = self.write_guard()?;
        if self.session_lifecycle(&session.0)? == "deleted" {
            return Ok(());
        }
        super::session_deletion::require_available(&self.connection, &session.0)?;
        self.connection.execute("INSERT INTO transcription_intent(session_id, declined_auto, last_outcome, request_generation)
            VALUES(?1, 1, 'cancelled', 1) ON CONFLICT(session_id) DO UPDATE SET
            requested_action = NULL, requested_at_ms = NULL, declined_auto = 1,
            request_generation = request_generation + 1, last_outcome = 'cancelled'", [&session.0])?;
        Ok(())
    }

    pub fn transcription_queue(
        &self,
        mut observations: WorkObservations,
    ) -> Result<Vec<TranscriptionWork>, StoreError> {
        // Native observations can add holds, never relax durable capture truth.
        observations.capture_active |= self.capture_active()?;
        let active: bool = self.connection.query_row(
            "SELECT EXISTS(SELECT 1 FROM transcription_intent WHERE admission IS NOT NULL)",
            [],
            |row| row.get(0),
        )?;
        // Admission reads metadata only; source hashing belongs to execution.
        let sessions: Vec<(String, bool)> = self.connection.prepare("SELECT sessions.id,
            (sessions.origin = 'import' OR EXISTS(SELECT 1 FROM session_events WHERE session_id = sessions.id AND event_kind = 'capture_clock_anchored')
             OR EXISTS(SELECT 1 FROM session_restorations WHERE session_id = sessions.id AND state = 'restored'))
            FROM sessions WHERE lifecycle = 'ready_for_review'
            AND NOT EXISTS(SELECT 1 FROM session_deletion_intents WHERE session_id = sessions.id)
            ORDER BY created_at_ms DESC, id DESC")?
            .query_map([], |r| Ok((r.get(0)?, r.get(1)?)))?.collect::<Result<_,_>>()?;
        let mut entries = Vec::new();
        for (session_id, calibrated) in sessions {
            let session_id = SessionId(session_id);
            let transcript = self.runtime_transcript_snapshot(&self.connection, &session_id.0)?;
            if transcript.total_tracks == 0 {
                continue;
            }
            let row: Option<IntentRow> = self.connection.query_row(
                "SELECT requested_action, COALESCE(requested_at_ms,0), declined_auto, admission, last_outcome, admitted_action, admitted_manual
                 FROM transcription_intent WHERE session_id = ?1", [&session_id.0],
                 |r| Ok((r.get(0)?,r.get(1)?,r.get(2)?,r.get(3)?,r.get(4)?,r.get(5)?,r.get(6)?))).optional()?;
            let (requested, order, declined, admission, outcome, admitted_action, admitted_manual) =
                row.unwrap_or_default();
            let unsupported_outcome = outcome
                .as_deref()
                .is_some_and(|code| WorkOutcome::from_code(code).is_none());
            let outcome = outcome.as_deref().and_then(WorkOutcome::from_code);
            let manual = if admission.is_some() {
                admitted_manual.unwrap_or(false)
            } else {
                requested.is_some()
            };
            let action = if admission.is_some() {
                admitted_action.as_deref()
            } else {
                requested.as_deref()
            };
            let intent = action
                .and_then(TranscriptionIntent::from_code)
                .unwrap_or_default();
            let unknown = unsupported_outcome
                || action.is_some_and(|value| TranscriptionIntent::from_code(value).is_none());
            let automatic_eligible = !declined
                && observations.automatic
                && !matches!(
                    outcome,
                    Some(WorkOutcome::UserCancelled | WorkOutcome::Failed | WorkOutcome::Completed)
                )
                && (calibrated)
                && (matches!(
                    transcript.state,
                    RuntimeTranscriptState::None | RuntimeTranscriptState::Partial
                ) || outcome == Some(WorkOutcome::CapturePreempted));
            if admission.is_none() && !manual && !automatic_eligible {
                continue;
            }
            if admission.is_none()
                && intent != TranscriptionIntent::ReprocessAll
                && transcript.state == RuntimeTranscriptState::Final
            {
                continue;
            }
            let hold = if unknown
                || transcript.state == RuntimeTranscriptState::Unknown
                || transcript.attempt == open_scribe_types::AttemptState::Unknown
            {
                Some(WorkHold::UnknownState)
            } else if admission.is_none() && active {
                Some(WorkHold::AlreadyRunning)
            } else {
                let admission_intent = if self.retained_plan_available(&session_id, intent)? {
                    TranscriptionIntent::ReconcileRetained
                } else {
                    intent
                };
                open_scribe_domain::transcription_hold(manual, admission_intent, observations)
            };
            entries.push((
                order,
                TranscriptionWork {
                    session_id,
                    manual,
                    intent,
                    hold,
                    admission,
                    outcome,
                },
            ));
        }
        // Snapshot is newest-first. Stable sorting preserves that order among
        // automatic arrivals; explicit requests use FIFO request time.
        entries
            .sort_by_key(|(order, entry)| (!entry.manual, if entry.manual { *order } else { 0 }));
        Ok(entries.into_iter().map(|(_, entry)| entry).collect())
    }

    /// The same production plan used to present the queue owns final admission.
    pub fn admit_transcription(
        &mut self,
        observations: WorkObservations,
    ) -> Result<Option<TranscriptionWork>, StoreError> {
        let _writer = self.write_guard()?;
        let Some(mut next) = self
            .transcription_queue(observations)?
            .into_iter()
            .find(|entry| entry.admission.is_none() && entry.hold.is_none())
        else {
            return Ok(None);
        };
        self.record_work_admission(&mut next)?;
        Ok(Some(next))
    }

    /// Maintenance competes for the same execution slot as ASR. This atomic
    /// decision closes the gap between native preflight and long reconciliation.
    pub fn admit_retained_reconciliation(
        &mut self,
        session: &SessionId,
        mut observations: WorkObservations,
    ) -> Result<Option<TranscriptionWork>, StoreError> {
        let _writer = self.write_guard()?;
        observations.capture_active |= self.capture_active()?;
        if self.deletion_pending(session)?
            || self.work_admission_active()?
            || self.transcription_is_declined(session)?
            || self.session_lifecycle(&session.0)? != "ready_for_review"
            || open_scribe_domain::transcription_hold(
                false,
                TranscriptionIntent::ReconcileRetained,
                observations,
            )
            .is_some()
        {
            return Ok(None);
        }
        if self
            .transcription_queue(observations)?
            .iter()
            .any(|entry| entry.manual || entry.hold.is_none())
        {
            return Ok(None);
        }
        let mut next = TranscriptionWork {
            session_id: session.clone(),
            manual: false,
            intent: TranscriptionIntent::ReconcileRetained,
            hold: None,
            admission: None,
            outcome: None,
        };
        self.record_work_admission(&mut next)?;
        Ok(Some(next))
    }

    fn record_work_admission(&mut self, next: &mut TranscriptionWork) -> Result<(), StoreError> {
        super::session_deletion::require_available(&self.connection, &next.session_id.0)?;
        let token = Uuid::now_v7().to_string();
        let automatic_selections = if next.manual {
            None
        } else {
            Some(self.selection_json(&next.session_id)?)
        };
        self.connection.execute("INSERT INTO transcription_intent(session_id, admission, admitted_action, admitted_manual, admitted_selection_json, admitted_generation)
            VALUES(?1, ?2, ?3, ?4, ?5, 0) ON CONFLICT(session_id) DO UPDATE SET
            admission = excluded.admission, runner_started = 0, admitted_generation = request_generation,
            admitted_selection_json = CASE WHEN excluded.admitted_manual THEN selection_json ELSE excluded.admitted_selection_json END,
            admitted_action = excluded.admitted_action,
            admitted_manual = excluded.admitted_manual, last_outcome = NULL",
            params![next.session_id.0, token, next.intent.code(), next.manual, automatic_selections])?;
        next.admission = Some(token);
        Ok(())
    }

    /// A stale completion cannot clear another admission or resurrect a cancelled
    /// request. Preemption preserves its original desired action and origin.
    pub fn finish_transcription(
        &mut self,
        token: &str,
        outcome: WorkOutcome,
    ) -> Result<(), StoreError> {
        let _writer = self.write_guard()?;
        self.connection.execute("UPDATE transcription_intent SET admission = NULL, runner_started = 0,
            last_action = admitted_action, admitted_action = NULL, admitted_selection_json = NULL,
            admitted_manual = NULL, admitted_generation = NULL,
            last_outcome = CASE WHEN last_outcome = 'cancelled' OR request_generation <> COALESCE(admitted_generation, 0) THEN last_outcome ELSE ?2 END,
            requested_action = CASE WHEN request_generation <> COALESCE(admitted_generation, 0) OR (?2 IN ('preempted','deferred') AND last_outcome IS NOT 'cancelled') THEN requested_action ELSE NULL END,
            requested_at_ms = CASE WHEN request_generation <> COALESCE(admitted_generation, 0) OR (?2 IN ('preempted','deferred') AND last_outcome IS NOT 'cancelled') THEN requested_at_ms ELSE NULL END
            WHERE admission = ?1", params![token, outcome.code()])?;
        Ok(())
    }

    /// Called once after launch media recovery, before starting any runner.
    /// Opening an additional read handle must never revoke live admissions.
    pub fn recover_transcription_admissions(&mut self) -> Result<(), StoreError> {
        let _writer = self.write_guard()?;
        self.connection.execute("UPDATE transcription_intent SET admission = NULL, runner_started = 0,
            last_action = admitted_action, admitted_action = NULL, admitted_manual = NULL,
            admitted_generation = NULL, admitted_selection_json = NULL,
            last_outcome = CASE WHEN last_outcome = 'cancelled' THEN last_outcome ELSE 'preempted' END
            WHERE admission IS NOT NULL", [])?;
        Ok(())
    }

    /// Consume the admission exactly once immediately before model/decoding
    /// work. A repeated runner, stale token, cancelled request, or durable
    /// capture cannot enter execution through another native handle.
    pub fn start_transcription_execution(
        &mut self,
        session: &SessionId,
        token: &str,
        intent: TranscriptionIntent,
    ) -> Result<bool, StoreError> {
        let _writer = self.write_guard()?;
        if self.capture_active()?
            || self.deletion_pending(session)?
            || self.session_lifecycle(&session.0)? != "ready_for_review"
        {
            return Ok(false);
        }
        Ok(self.connection.execute(
            "UPDATE transcription_intent SET runner_started = 1
            WHERE session_id = ?1 AND admission = ?2 AND admitted_action = ?3
              AND runner_started = 0 AND last_outcome IS NOT 'cancelled'",
            params![session.0, token, intent.code()],
        )? == 1)
    }

    pub fn transcription_outcomes(&self) -> Result<Vec<(String, WorkOutcome)>, StoreError> {
        let mut statement = self.connection.prepare("SELECT session_id, last_outcome FROM transcription_intent WHERE last_outcome IS NOT NULL")?;
        let rows =
            statement.query_map([], |r| Ok((r.get::<_, String>(0)?, r.get::<_, String>(1)?)))?;
        Ok(rows
            .collect::<Result<Vec<_>, _>>()?
            .into_iter()
            .filter_map(|(id, code)| Some((id, WorkOutcome::from_code(&code)?)))
            .collect())
    }

    fn deletion_pending(&self, session: &SessionId) -> Result<bool, StoreError> {
        Ok(self.connection.query_row(
            "SELECT EXISTS(SELECT 1 FROM session_deletion_intents WHERE session_id = ?1)",
            [&session.0],
            |row| row.get(0),
        )?)
    }
}
