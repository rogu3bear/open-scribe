//! Selection is a mutable human/document choice, separate from immutable output.
//! A run captures the selection epoch when it begins. Completion may publish
//! only while that expectation is still current, including intervening edits.
use super::*;
use rusqlite::OptionalExtension;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum TranscriptSelectionPolicy {
    IfUnchanged,
    KeepCurrent,
}

pub(super) fn apply_schema(transaction: &Transaction<'_>) -> Result<(), StoreError> {
    transaction.execute_batch(
        "CREATE TABLE IF NOT EXISTS transcript_selection_epochs (
            session_id TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
            track_id TEXT NOT NULL, epoch INTEGER NOT NULL,
            PRIMARY KEY(session_id, track_id));
         CREATE TABLE IF NOT EXISTS transcription_selection_guards (
            run_id TEXT PRIMARY KEY REFERENCES transcription_runs(id) ON DELETE CASCADE,
            expected_revision TEXT, expected_epoch INTEGER NOT NULL);
         CREATE TRIGGER IF NOT EXISTS capture_transcription_selection_guard
         AFTER INSERT ON transcription_runs BEGIN
            INSERT INTO transcription_selection_guards(run_id, expected_revision, expected_epoch)
            VALUES(NEW.id,
              (SELECT revision_id FROM transcript_selections
               WHERE session_id = NEW.session_id AND track_id = NEW.track_id),
              COALESCE((SELECT epoch FROM transcript_selection_epochs
               WHERE session_id = NEW.session_id AND track_id = NEW.track_id), 0));
         END;
         CREATE TRIGGER IF NOT EXISTS selection_epoch_insert
         AFTER INSERT ON transcript_selections BEGIN
            INSERT INTO transcript_selection_epochs VALUES(NEW.session_id, NEW.track_id, 1)
            ON CONFLICT(session_id, track_id) DO UPDATE SET epoch = epoch + 1;
         END;
         CREATE TRIGGER IF NOT EXISTS selection_epoch_update
         AFTER UPDATE ON transcript_selections BEGIN
            INSERT INTO transcript_selection_epochs VALUES(NEW.session_id, NEW.track_id, 1)
            ON CONFLICT(session_id, track_id) DO UPDATE SET epoch = epoch + 1;
         END;
         CREATE TRIGGER IF NOT EXISTS correction_selection_epoch
         AFTER INSERT ON transcript_corrections BEGIN
            INSERT INTO transcript_selection_epochs(session_id, track_id, epoch)
            SELECT NEW.session_id, track_id, 1 FROM transcript_revisions
            WHERE id = NEW.revision_id
            ON CONFLICT(session_id, track_id) DO UPDATE SET epoch = epoch + 1;
         END;
         CREATE TRIGGER IF NOT EXISTS speaker_selection_epoch
         AFTER INSERT ON speaker_adjudications BEGIN
            INSERT INTO transcript_selection_epochs VALUES(NEW.session_id, NEW.track_id, 1)
            ON CONFLICT(session_id, track_id) DO UPDATE SET epoch = epoch + 1;
         END;",
    )?;
    transaction.execute(
        "INSERT OR IGNORE INTO schema_migrations VALUES(10, ?1)",
        [wall_time_milliseconds()],
    )?;
    Ok(())
}

pub(super) fn expectation_matches(
    transaction: &Transaction<'_>,
    run: &str,
    session: &str,
    track: &str,
) -> Result<bool, StoreError> {
    let current: Option<String> = transaction
        .query_row(
            "SELECT revision_id FROM transcript_selections WHERE session_id = ?1 AND track_id = ?2",
            params![session, track],
            |row| row.get(0),
        )
        .optional()?;
    let guard: Option<(Option<String>, i64)> = transaction.query_row(
        "SELECT expected_revision, expected_epoch FROM transcription_selection_guards WHERE run_id = ?1",
        [run], |row| Ok((row.get(0)?, row.get(1)?)),
    ).optional()?;
    let epoch: i64 = transaction.query_row(
        "SELECT COALESCE((SELECT epoch FROM transcript_selection_epochs
         WHERE session_id = ?1 AND track_id = ?2), 0)",
        params![session, track],
        |row| row.get(0),
    )?;
    // A legacy interrupted run has no trustworthy pre-work selection stamp.
    // It may fill an empty track, never displace an existing document.
    Ok(guard.map_or(current.is_none(), |expected| expected == (current, epoch)))
}

impl SessionStore {
    /// Compatibility follows the immutable media input, not the current model
    /// choice or algorithm label. Reviewed older Final text stays useful.
    pub fn has_compatible_selected_final(
        &self,
        session: &SessionId,
        track: &str,
    ) -> Result<bool, StoreError> {
        let input = self.transcription_input(session, track)?;
        self.selected_final_matches_input(session, track, &input.input_digest)
    }

    pub fn selected_final_matches_input(
        &self,
        session: &SessionId,
        track: &str,
        input_digest: &str,
    ) -> Result<bool, StoreError> {
        Ok(self.connection.query_row(
            "SELECT EXISTS(SELECT 1 FROM transcript_selections selection
             JOIN transcript_revisions revision ON revision.id = selection.revision_id
             JOIN transcription_runs run ON run.id = revision.run_id
             WHERE selection.session_id = ?1 AND selection.track_id = ?2
               AND revision.finality = 'final' AND run.input_digest = ?3)",
            params![session.0, track, input_digest],
            |row| row.get(0),
        )?)
    }
}
