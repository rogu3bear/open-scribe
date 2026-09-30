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
use super::{SCHEMA_VERSION, SessionStore, StoreError, wall_time_milliseconds};
use open_scribe_types::SessionId;
use rusqlite::{OptionalExtension, Transaction, params};
use std::fs;
use std::io::ErrorKind;
use std::path::PathBuf;
use uuid::Uuid;

pub(super) const DELETION_MIGRATION_VERSION: i64 = 7;
const MAX_TRASH_REFERENCE_BYTES: usize = 4096;
const EXPORTS_DIRECTORY: &str = "exports";

pub(super) fn apply_deletion_schema(transaction: &Transaction<'_>) -> Result<(), StoreError> {
    transaction.execute_batch(
        "CREATE TABLE IF NOT EXISTS session_deletion_intents (
            session_id TEXT PRIMARY KEY REFERENCES sessions(id),
            created_at_ms INTEGER NOT NULL
        );",
    )?;
    Ok(())
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
        let transaction = self.connection.transaction()?;
        let title: Option<(String, String)> = transaction
            .query_row(
                "SELECT title, lifecycle FROM sessions WHERE id = ?1",
                [&session.0],
                |row| Ok((row.get(0)?, row.get(1)?)),
            )
            .optional()?;
        let title = match title {
            Some((title, lifecycle))
                if matches!(lifecycle.as_str(), "ready_for_review" | "interrupted") =>
            {
                title
            }
            Some(_) => {
                return Err(StoreError::InvalidState(
                    "only saved or interrupted sessions can be deleted",
                ));
            }
            None => return Err(StoreError::InvalidRequest("session does not exist")),
        };
        transaction.execute(
            "INSERT OR IGNORE INTO session_deletion_intents(session_id, created_at_ms)
             VALUES(?1, ?2)",
            params![session.0, wall_time_milliseconds()],
        )?;
        transaction.commit()?;

        let count = |sql: &str| -> Result<u32, StoreError> {
            Ok(self
                .connection
                .query_row(sql, [&session.0], |row| row.get(0))?)
        };
        let (media_files, media_bytes): (u32, i64) = self.connection.query_row(
            "SELECT COUNT(*), COALESCE(SUM(byte_length), 0) FROM segments WHERE session_id = ?1",
            [&session.0],
            |row| Ok((row.get(0)?, row.get(1)?)),
        )?;
        let directory = self.sessions_root.join(&session.0);
        let (export_files, export_bytes) = export_inventory(&directory)?;
        Ok(SessionDeletionInventory {
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
                "SELECT COUNT(DISTINCT track_id) FROM speaker_adjudications
                 WHERE session_id = ?1 AND label IS NOT NULL",
            )?,
            markers: count("SELECT COUNT(*) FROM markers WHERE session_id = ?1")?,
            context_events: count("SELECT COUNT(*) FROM context_events WHERE session_id = ?1")?,
            export_files,
            export_bytes,
            directory,
        })
    }

    /// Clears an intent after Trash failed or the user cancelled. Nothing
    /// else changes.
    pub fn abandon_session_deletion(&mut self, session: &SessionId) -> Result<(), StoreError> {
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
        // Derived and human-review rows first, then evidence rows in foreign
        // key order. The session row survives only as a tombstone.
        for statement in [
            "DELETE FROM transcript_search WHERE session_id = ?1",
            "DELETE FROM speaker_adjudications WHERE session_id = ?1",
            "DELETE FROM transcript_corrections WHERE session_id = ?1",
            "DELETE FROM transcript_selections WHERE session_id = ?1",
            "DELETE FROM transcription_runs WHERE session_id = ?1",
            "DELETE FROM segments WHERE session_id = ?1",
            "DELETE FROM tracks WHERE session_id = ?1",
            "DELETE FROM sources WHERE session_id = ?1",
            "DELETE FROM required_sources WHERE session_id = ?1",
            "DELETE FROM context_events WHERE session_id = ?1",
            "DELETE FROM context_scopes WHERE session_id = ?1",
            "DELETE FROM session_declarations WHERE session_id = ?1",
            "DELETE FROM markers WHERE session_id = ?1",
            "DELETE FROM imports WHERE session_id = ?1",
            "DELETE FROM session_events WHERE session_id = ?1",
            "DELETE FROM recovery_runs WHERE session_id = ?1",
            "DELETE FROM session_restorations WHERE session_id = ?1",
            "DELETE FROM session_deletion_intents WHERE session_id = ?1",
        ] {
            transaction.execute(statement, [&session.0])?;
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
        // Pages were zeroed by secure_delete; truncating the WAL removes the
        // pre-deletion copies it still held.
        let busy: i64 =
            self.connection
                .query_row("PRAGMA wal_checkpoint(TRUNCATE)", [], |row| row.get(0))?;
        Ok(SessionDeletionReceipt {
            receipt_id,
            session_id: session.clone(),
            trash_reference: trash_reference.map(str::to_owned),
            wal_checkpointed: busy == 0,
        })
    }

    /// Launch recovery for deletions a crash interrupted: an intent whose
    /// directory reached Trash completes; one whose directory remains is
    /// abandoned so the session stays intact.
    pub(super) fn settle_deletion_intents(&mut self) -> Result<(), StoreError> {
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
