//! User-initiated session deletion (ADR 0006; PRD 9.10 and 18.4).
//!
//! Deletion is two-phase and fails closed. `begin_session_deletion` records a
//! durable intent and states exactly what will be removed. The macOS adapter
//! then moves the whole session directory (media, journal, and in-session
//! exports) to Trash. Only when that directory is gone does
//! `complete_session_deletion` remove every structured and derived row,
//! compact the search index, and leave a content-free tombstone plus a
//! deletion receipt. If Trash fails, `abandon_session_deletion` leaves the
//! session untouched. Launch recovery settles an intent a crash interrupted.
//! Emptying Trash is the separate, user-owned permanent deletion.

use super::library_recovery::isolated_disposition;
use super::{
    EXPORTS_DIRECTORY, MixdownWork, SCHEMA_VERSION, SESSION_OWNED_TABLES, SessionLifecycle,
    SessionStore, StoreError, wall_time_milliseconds,
};
use open_scribe_types::SessionId;
use rusqlite::{Connection, OptionalExtension, Transaction, params};
use std::fs;
use std::io::ErrorKind;
use std::path::PathBuf;
use std::time::Duration;
use uuid::Uuid;

const MAX_TRASH_REFERENCE_BYTES: usize = 4096;

pub(super) fn apply_deletion_schema(transaction: &Transaction<'_>) -> Result<(), StoreError> {
    transaction.execute_batch(
        "CREATE TABLE IF NOT EXISTS session_deletion_intents (
            session_id TEXT PRIMARY KEY REFERENCES sessions(id),
            created_at_ms INTEGER NOT NULL
        );",
    )?;
    Ok(())
}

/// Called under the library writer guard before changing session-owned work.
/// The confirmation inventory remains stable until completion or abandonment.
pub(super) fn require_available(connection: &Connection, session: &str) -> Result<(), StoreError> {
    let state: Option<(SessionLifecycle, bool)> = connection
        .query_row(
            "SELECT lifecycle,
                    EXISTS(SELECT 1 FROM session_deletion_intents WHERE session_id = sessions.id)
             FROM sessions WHERE id = ?1",
            [session],
            |row| Ok((row.get(0)?, row.get(1)?)),
        )
        .optional()?;
    match state {
        Some((lifecycle, false)) if lifecycle != SessionLifecycle::Deleted => Ok(()),
        Some(_) => Err(StoreError::InvalidState(
            "session is being deleted or was deleted",
        )),
        None => Err(StoreError::InvalidRequest("session does not exist")),
    }
}

/// Whether the session holds audio anyone could hear or recover: a segment
/// that accepted samples, or media launch recovery promoted. Expects
/// `sessions` in scope.
pub(super) const HOLDS_AUDIO_SQL: &str = "(EXISTS(SELECT 1 FROM segments held
        WHERE held.session_id = sessions.id
          AND (held.lifecycle = 'capturing' OR COALESCE(held.sample_count, 0) > 0))
    OR EXISTS(SELECT 1 FROM recovery_runs promoted
        WHERE promoted.session_id = sessions.id
          AND promoted.disposition IN ('playable_media_recovered', 'timeline_recovered')))";

/// The one Trash rule, shared by the library snapshot and deletion itself. A
/// capture launch recovery isolated may go only when it never held audio, so
/// nothing recoverable is ever discarded as an empty attempt.
pub(super) fn trash_eligible(
    lifecycle: SessionLifecycle,
    isolated: bool,
    holds_audio: bool,
) -> bool {
    lifecycle.is_trashable() || (isolated && lifecycle.is_open_capture() && !holds_audio)
}

/// Exactly what a confirmed deletion removes, for the confirmation surface.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct SessionDeletionInventory {
    pub session_id: SessionId,
    pub title: String,
    /// The directory the adapter must move to Trash.
    pub directory: PathBuf,
    pub media_files: u32,
    pub media_bytes: u64,
    pub transcript_revisions: u32,
    pub human_corrections: u32,
    pub speaker_names: u32,
    pub markers: u32,
    pub context_events: u32,
    pub export_files: u32,
    pub export_bytes: u64,
    /// Distinct derived claims. Revisions of one claim are one item.
    pub derived_items: u32,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct SessionDeletionReceipt {
    pub receipt_id: String,
    pub session_id: SessionId,
    pub trash_reference: Option<String>,
    /// Whether the WAL was checkpointed and truncated after the deletion.
    pub wal_checkpointed: bool,
}

impl SessionStore {
    pub fn begin_session_deletion(
        &mut self,
        session: &SessionId,
    ) -> Result<SessionDeletionInventory, StoreError> {
        let _writer = self.write_guard()?;
        let transaction = self.connection.transaction()?;
        let state: Option<(String, SessionLifecycle, bool)> = transaction
            .query_row(
                &format!("SELECT title, lifecycle, {HOLDS_AUDIO_SQL} FROM sessions WHERE id = ?1"),
                [&session.0],
                |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?)),
            )
            .optional()?;
        let Some((title, lifecycle, holds_audio)) = state else {
            return Err(StoreError::InvalidRequest("session does not exist"));
        };
        let isolated = lifecycle.is_open_capture()
            && super::library_recovery::capture_isolated(&transaction, &session.0)?;
        if !trash_eligible(lifecycle, isolated, holds_audio) {
            return Err(StoreError::InvalidState(
                "only saved, interrupted, or empty isolated sessions can be deleted",
            ));
        }
        let admitted: bool = transaction.query_row(
            "SELECT EXISTS(SELECT 1 FROM transcription_intent
                           WHERE session_id = ?1 AND admission IS NOT NULL)",
            [&session.0],
            |row| row.get(0),
        )?;
        if admitted {
            return Err(StoreError::InvalidState(
                "processing must finish or acknowledge cancellation before deletion",
            ));
        }
        // Rendering owns only this session's lease, never the library writer.
        // Fail without waiting or committing intent; Cancel must not discard
        // an otherwise valid in-flight mix. Hold until intent commits below.
        let _mixdown = MixdownWork::try_acquire(&self.managed_root, session)?;

        let count = |sql: &str| -> Result<u32, StoreError> {
            Ok(transaction.query_row(sql, [&session.0], |row| row.get(0))?)
        };
        let (media_files, media_bytes): (u32, i64) = transaction.query_row(
            "SELECT COUNT(*), COALESCE(SUM(byte_length), 0) FROM segments WHERE session_id = ?1",
            [&session.0],
            |row| Ok((row.get(0)?, row.get(1)?)),
        )?;
        let directory = self.sessions_root.join(&session.0);
        let (export_files, export_bytes) = export_inventory(&directory)?;
        let inventory = SessionDeletionInventory {
            session_id: session.clone(),
            title,
            media_files,
            media_bytes: u64::try_from(media_bytes).unwrap_or(0),
            transcript_revisions: count(
                "SELECT COUNT(*) FROM transcript_revisions WHERE session_id = ?1",
            )?,
            human_corrections: count(
                "SELECT COUNT(*) FROM transcript_corrections WHERE session_id = ?1",
            )?,
            speaker_names: count(
                "SELECT (SELECT COUNT(DISTINCT track_id) FROM speaker_adjudications
                         WHERE session_id = ?1 AND label IS NOT NULL)
                      + (SELECT COUNT(*) FROM transcript_named_speakers WHERE session_id = ?1)",
            )?,
            markers: count("SELECT COUNT(*) FROM markers WHERE session_id = ?1")?,
            context_events: count("SELECT COUNT(*) FROM context_events WHERE session_id = ?1")?,
            export_files,
            export_bytes,
            derived_items: count(
                "SELECT COUNT(DISTINCT claim_id) FROM derived_claim_revisions WHERE session_id = ?1",
            )?,
            directory,
        };
        // Inventory failure must not leave an invisible pending deletion.
        transaction.execute(
            "INSERT OR IGNORE INTO session_deletion_intents(session_id, created_at_ms)
             VALUES(?1, ?2)",
            params![session.0, wall_time_milliseconds()],
        )?;
        transaction.commit()?;
        Ok(inventory)
    }

    /// Clears an intent after Trash failed or the user cancelled. Nothing
    /// else changes.
    pub fn abandon_session_deletion(&mut self, session: &SessionId) -> Result<(), StoreError> {
        let _writer = self.write_guard()?;
        self.connection.execute(
            "DELETE FROM session_deletion_intents WHERE session_id = ?1",
            [&session.0],
        )?;
        Ok(())
    }

    /// Removes every row the session owns once its directory is in Trash.
    pub fn complete_session_deletion(
        &mut self,
        session: &SessionId,
        trash_reference: Option<&str>,
    ) -> Result<SessionDeletionReceipt, StoreError> {
        let _writer = self.write_guard()?;
        if trash_reference.is_some_and(|reference| {
            reference.is_empty()
                || reference.len() > MAX_TRASH_REFERENCE_BYTES
                || reference.chars().any(char::is_control)
        }) {
            return Err(StoreError::InvalidRequest("trash reference is invalid"));
        }
        let directory = self.sessions_root.join(&session.0);
        match fs::symlink_metadata(&directory) {
            Err(error) if error.kind() == ErrorKind::NotFound => {}
            Err(error) => return Err(error.into()),
            Ok(_) => {
                return Err(StoreError::InvalidState(
                    "session directory must be in Trash before deletion completes",
                ));
            }
        }
        let receipt_id = Uuid::now_v7().to_string();
        let now = wall_time_milliseconds();
        let transaction = self.connection.transaction()?;
        let begun: bool = transaction.query_row(
            "SELECT EXISTS(SELECT 1 FROM session_deletion_intents WHERE session_id = ?1)",
            [&session.0],
            |row| row.get(0),
        )?;
        if !begun {
            return Err(StoreError::InvalidState("session deletion was not begun"));
        }
        for table in SESSION_OWNED_TABLES {
            transaction.execute(
                &format!("DELETE FROM {table} WHERE session_id = ?1"),
                [&session.0],
            )?;
        }
        transaction.execute(
            "UPDATE sessions SET lifecycle = 'deleted', title = '', media_files_open = 0,
                                 updated_at_ms = ?2
             WHERE id = ?1",
            params![session.0, now],
        )?;
        transaction.execute(
            "INSERT INTO deletion_receipts(
                id, schema_version, session_id, trash_reference, created_at_ms)
             VALUES(?1, ?2, ?3, ?4, ?5)",
            params![receipt_id, SCHEMA_VERSION, session.0, trash_reference, now],
        )?;
        // Merging every index segment drops the deleted rows' tokens.
        transaction.execute(
            "INSERT INTO transcript_search(transcript_search) VALUES('optimize')",
            [],
        )?;
        transaction.commit()?;
        drop(_writer);
        // Pages were zeroed by secure_delete; truncating the WAL removes the
        // pre-deletion copies it still held. This optional cleanup never waits
        // on another reader/writer or keeps capture's durable-write admission.
        let wal_checkpointed = self.checkpoint_deletion_wal()?;
        Ok(SessionDeletionReceipt {
            receipt_id,
            session_id: session.clone(),
            trash_reference: trash_reference.map(str::to_owned),
            wal_checkpointed,
        })
    }

    fn checkpoint_deletion_wal(&self) -> Result<bool, StoreError> {
        let previous_timeout_ms: i64 =
            self.connection
                .pragma_query_value(None, "busy_timeout", |row| row.get(0))?;
        let previous_timeout_ms = u64::try_from(previous_timeout_ms)
            .map_err(|_| StoreError::InvalidState("SQLite busy timeout is invalid"))?;
        self.connection.busy_timeout(Duration::ZERO)?;
        let checkpoint =
            self.connection
                .query_row::<i64, _, _>("PRAGMA wal_checkpoint(TRUNCATE)", [], |row| row.get(0));
        // This connection is exclusively borrowed. Restore its actual policy
        // before returning either the checkpoint result or an error.
        self.connection
            .busy_timeout(Duration::from_millis(previous_timeout_ms))?;
        match checkpoint {
            Ok(busy) => Ok(busy == 0),
            Err(error)
                if matches!(
                    error.sqlite_error_code(),
                    Some(rusqlite::ErrorCode::DatabaseBusy | rusqlite::ErrorCode::DatabaseLocked)
                ) =>
            {
                Ok(false)
            }
            Err(error) => Err(error.into()),
        }
    }

    /// Launch recovery for deletions a crash interrupted: an intent whose
    /// directory reached Trash completes; one whose directory remains is
    /// abandoned so the session stays intact.
    pub(super) fn settle_deletion_intents(&mut self) -> Result<(), StoreError> {
        let _writer = self.write_guard()?;
        let intents: Vec<String> = self
            .connection
            .prepare("SELECT session_id FROM session_deletion_intents ORDER BY session_id")?
            .query_map([], |row| row.get(0))?
            .collect::<Result<_, _>>()?;
        for id in intents {
            let session = SessionId(id);
            let settled = match fs::symlink_metadata(self.sessions_root.join(&session.0)) {
                Err(error) if error.kind() == ErrorKind::NotFound => {
                    self.complete_session_deletion(&session, None).map(|_| ())
                }
                Err(error) => Err(error.into()),
                Ok(_) => self.abandon_session_deletion(&session),
            };
            if let Err(error) = settled {
                isolated_disposition(error)?;
            }
        }
        Ok(())
    }
}

/// Files directly inside the session's `exports/` directory.
fn export_inventory(directory: &std::path::Path) -> Result<(u32, u64), StoreError> {
    let entries = match fs::read_dir(directory.join(EXPORTS_DIRECTORY)) {
        Ok(entries) => entries,
        Err(error) if error.kind() == ErrorKind::NotFound => return Ok((0, 0)),
        Err(error) => return Err(error.into()),
    };
    let (mut files, mut bytes) = (0_u32, 0_u64);
    for entry in entries {
        let metadata = entry?.metadata()?;
        if metadata.is_file() {
            files = files.saturating_add(1);
            bytes = bytes.saturating_add(metadata.len());
        }
    }
    Ok((files, bytes))
}

#[cfg(test)]
#[path = "session_deletion_tests.rs"]
mod tests;
