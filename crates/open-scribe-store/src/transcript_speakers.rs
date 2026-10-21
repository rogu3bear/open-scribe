//! Human-confirmed people and turn attribution over immutable transcript
//! revisions. Source topology still labels unassigned turns. Nothing here
//! infers a person's identity, clusters voices, or changes recorded audio.

use super::transcript_review::require_reviewable_session;
use super::{SessionStore, StoreError, wall_time_milliseconds};
use open_scribe_types::SessionId;
use rusqlite::{OptionalExtension, Transaction, params};
use std::collections::BTreeMap;
use uuid::Uuid;

pub(super) const SPEAKER_REVIEW_MIGRATION: i64 = 15;

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct NamedTranscriptSpeaker {
    pub id: String,
    pub label: String,
    /// Selected Final turns currently attributed to this person, not the
    /// count of historical assignments or source tracks.
    pub selected_turns: u32,
}

/// Latest human identity and display name for one immutable revision turn.
pub(super) struct TurnSpeaker {
    pub id: String,
    pub label: String,
}

type TurnSpeakers = BTreeMap<(String, u32), TurnSpeaker>;

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum TranscriptSpeakerAssignment {
    Existing(String),
    New(String),
    Source,
}

pub(super) fn apply_schema(tx: &Transaction<'_>) -> Result<(), StoreError> {
    tx.execute_batch(
        "CREATE TABLE IF NOT EXISTS transcript_named_speakers (
            id TEXT PRIMARY KEY,
            session_id TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
            created_at_ms INTEGER NOT NULL,
            UNIQUE(id, session_id)
        );
        CREATE TABLE IF NOT EXISTS transcript_speaker_names (
            id TEXT PRIMARY KEY,
            speaker_id TEXT NOT NULL REFERENCES transcript_named_speakers(id) ON DELETE CASCADE,
            label TEXT NOT NULL,
            search_label TEXT NOT NULL,
            created_at_ms INTEGER NOT NULL
        );
        CREATE INDEX IF NOT EXISTS transcript_speaker_names_by_person
            ON transcript_speaker_names(speaker_id);
        CREATE TABLE IF NOT EXISTS transcript_turn_speakers (
            id TEXT PRIMARY KEY,
            session_id TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
            revision_id TEXT NOT NULL,
            sequence INTEGER NOT NULL,
            speaker_id TEXT,
            created_at_ms INTEGER NOT NULL,
            FOREIGN KEY(revision_id, sequence)
                REFERENCES transcript_segments(revision_id, sequence) ON DELETE CASCADE,
            FOREIGN KEY(speaker_id, session_id)
                REFERENCES transcript_named_speakers(id, session_id) ON DELETE CASCADE
        );
        CREATE INDEX IF NOT EXISTS transcript_turn_speakers_by_segment
            ON transcript_turn_speakers(session_id, revision_id, sequence);
        CREATE TRIGGER IF NOT EXISTS transcript_named_speakers_append_only
            BEFORE UPDATE ON transcript_named_speakers
            BEGIN SELECT RAISE(ABORT, 'speaker identities are immutable'); END;
        CREATE TRIGGER IF NOT EXISTS transcript_speaker_names_append_only
            BEFORE UPDATE ON transcript_speaker_names
            BEGIN SELECT RAISE(ABORT, 'speaker names are append-only'); END;
        CREATE TRIGGER IF NOT EXISTS transcript_turn_speakers_append_only
            BEFORE UPDATE ON transcript_turn_speakers
            BEGIN SELECT RAISE(ABORT, 'turn assignments are append-only'); END;
        CREATE TRIGGER IF NOT EXISTS turn_speaker_selection_epoch
            AFTER INSERT ON transcript_turn_speakers BEGIN
            INSERT INTO transcript_selection_epochs(session_id, track_id, epoch)
            SELECT NEW.session_id, track_id, 1 FROM transcript_revisions
            WHERE id = NEW.revision_id
            ON CONFLICT(session_id, track_id) DO UPDATE SET epoch = epoch + 1;
        END;
        CREATE TRIGGER IF NOT EXISTS named_speaker_selection_epoch
            AFTER INSERT ON transcript_speaker_names BEGIN
            INSERT INTO transcript_selection_epochs(session_id, track_id, epoch)
            SELECT DISTINCT turns.session_id, revisions.track_id, 1
            FROM transcript_turn_speakers AS turns
            JOIN transcript_revisions AS revisions ON revisions.id = turns.revision_id
            WHERE turns.speaker_id = NEW.speaker_id
            ON CONFLICT(session_id, track_id) DO UPDATE SET epoch = epoch + 1;
        END;",
    )?;
    tx.execute(
        "INSERT OR IGNORE INTO schema_migrations(version, applied_at_ms) VALUES(?1, ?2)",
        params![SPEAKER_REVIEW_MIGRATION, wall_time_milliseconds()],
    )?;
    Ok(())
}

fn checked_name(label: &str) -> Result<&str, StoreError> {
    let label = label.trim();
    if label.is_empty() || label.len() > 128 || label.chars().any(char::is_control) {
        return Err(StoreError::InvalidRequest("speaker label is invalid"));
    }
    Ok(label)
}

impl SessionStore {
    /// Finds selected Final turns by a confirmed person's name. This is a
    /// literal Unicode-lowercased prefix, not FTS syntax or inferred identity.
    /// The text index remains an index of effective transcript text only.
    pub fn search_transcripts_by_speaker(
        &self,
        name: &str,
        session: Option<&SessionId>,
        limit: u32,
    ) -> Result<Vec<super::TranscriptSearchHit>, StoreError> {
        let name = name.trim();
        if name.is_empty() {
            return Ok(Vec::new());
        }
        let name = checked_name(name)?.to_lowercase();
        let pattern = format!(
            "{}%",
            name.replace('\\', "\\\\")
                .replace('%', "\\%")
                .replace('_', "\\_")
        );
        let effective = super::transcript_review::EFFECTIVE_TEXT;
        let mut statement = self.connection.prepare(&format!(
            "SELECT sessions.id, sessions.title, segments.revision_id, revisions.track_id,
                    segments.sequence, segments.start_ns, segments.end_ns, {effective}
             FROM transcript_selections AS selections
             JOIN sessions ON sessions.id = selections.session_id
             JOIN transcript_revisions AS revisions ON revisions.id = selections.revision_id
             JOIN transcript_segments AS segments ON segments.revision_id = revisions.id
             JOIN transcript_turn_speakers AS turns ON turns.rowid = (
                SELECT rowid FROM transcript_turn_speakers
                WHERE session_id = sessions.id AND revision_id = segments.revision_id
                  AND sequence = segments.sequence ORDER BY rowid DESC LIMIT 1)
             JOIN transcript_speaker_names AS names ON names.rowid = (
                SELECT rowid FROM transcript_speaker_names WHERE speaker_id = turns.speaker_id
                ORDER BY rowid DESC LIMIT 1)
             WHERE names.search_label LIKE ?1 ESCAPE '\\'
               AND sessions.lifecycle <> 'deleted'
               AND (?2 IS NULL OR sessions.id = ?2)
               AND NOT EXISTS(SELECT 1 FROM session_deletion_intents WHERE session_id = sessions.id)
             ORDER BY sessions.created_at_ms DESC, sessions.id, segments.start_ns, segments.sequence
             LIMIT ?3"
        ))?;
        statement
            .query_map(
                params![pattern, session.map(|id| &id.0), limit.clamp(1, 200)],
                |row| {
                    Ok(super::TranscriptSearchHit {
                        session_id: row.get(0)?,
                        session_title: row.get(1)?,
                        revision_id: row.get(2)?,
                        track_id: row.get(3)?,
                        sequence: row.get(4)?,
                        start_nanoseconds: row.get(5)?,
                        end_nanoseconds: row.get(6)?,
                        effective_text: row.get(7)?,
                    })
                },
            )?
            .collect::<Result<_, _>>()
            .map_err(StoreError::from)
    }

    /// Assigns one *currently selected* turn. The exact revision/sequence
    /// guards a stale sheet and prevents copying identity by ordinal after
    /// reprocessing. A new person and their first assignment commit together.
    pub fn assign_transcript_speaker(
        &mut self,
        session: &SessionId,
        revision_id: &str,
        sequence: u32,
        assignment: &TranscriptSpeakerAssignment,
    ) -> Result<Option<String>, StoreError> {
        let _writer = self.write_guard()?;
        let tx = self.connection.transaction()?;
        require_reviewable_session(&tx, &session.0)?;
        let selected: bool = tx.query_row(
            "SELECT EXISTS(SELECT 1 FROM transcript_selections AS selections
             JOIN transcript_segments AS segments ON segments.revision_id = selections.revision_id
             WHERE selections.session_id = ?1 AND segments.revision_id = ?2
               AND segments.sequence = ?3)",
            params![session.0, revision_id, sequence],
            |row| row.get(0),
        )?;
        if !selected {
            return Err(StoreError::InvalidRequest(
                "the selected transcript turn changed",
            ));
        }
        let speaker_id = match assignment {
            TranscriptSpeakerAssignment::Source => None,
            TranscriptSpeakerAssignment::Existing(id) => {
                let owned: bool = tx.query_row(
                    "SELECT EXISTS(SELECT 1 FROM transcript_named_speakers
                     WHERE id = ?1 AND session_id = ?2)",
                    params![id, session.0],
                    |row| row.get(0),
                )?;
                if !owned {
                    return Err(StoreError::InvalidRequest(
                        "the speaker belongs to another conversation",
                    ));
                }
                Some(id.clone())
            }
            TranscriptSpeakerAssignment::New(label) => {
                let label = checked_name(label)?;
                let id = Uuid::now_v7().to_string();
                tx.execute(
                    "INSERT INTO transcript_named_speakers(id, session_id, created_at_ms)
                     VALUES(?1, ?2, ?3)",
                    params![id, session.0, wall_time_milliseconds()],
                )?;
                tx.execute(
                    "INSERT INTO transcript_speaker_names(id, speaker_id, label, search_label, created_at_ms)
                     VALUES(?1, ?2, ?3, ?4, ?5)",
                    params![
                        Uuid::now_v7().to_string(),
                        id,
                        label,
                        label.to_lowercase(),
                        wall_time_milliseconds()
                    ],
                )?;
                Some(id)
            }
        };
        let current: Option<String> = tx
            .query_row(
                "SELECT speaker_id FROM transcript_turn_speakers
                 WHERE session_id = ?1 AND revision_id = ?2 AND sequence = ?3
                 ORDER BY rowid DESC LIMIT 1",
                params![session.0, revision_id, sequence],
                |row| row.get(0),
            )
            .optional()?
            .flatten();
        if current != speaker_id {
            tx.execute(
                "INSERT INTO transcript_turn_speakers(
                    id, session_id, revision_id, sequence, speaker_id, created_at_ms)
                 VALUES(?1, ?2, ?3, ?4, ?5, ?6)",
                params![
                    Uuid::now_v7().to_string(),
                    session.0,
                    revision_id,
                    sequence,
                    speaker_id,
                    wall_time_milliseconds()
                ],
            )?;
        }
        tx.commit()?;
        Ok(speaker_id)
    }

    /// Rename the confirmed identity; every assigned turn follows the
    /// latest append, including after restart. Equal labels are allowed:
    /// two people with the same name remain distinct identities.
    pub fn rename_transcript_speaker(
        &mut self,
        session: &SessionId,
        speaker_id: &str,
        label: &str,
    ) -> Result<(), StoreError> {
        let _writer = self.write_guard()?;
        let label = checked_name(label)?;
        let tx = self.connection.transaction()?;
        require_reviewable_session(&tx, &session.0)?;
        let current: Option<String> = tx
            .query_row(
                "SELECT names.label FROM transcript_named_speakers AS speakers
             JOIN transcript_speaker_names AS names ON names.speaker_id = speakers.id
             WHERE speakers.id = ?1 AND speakers.session_id = ?2
             ORDER BY names.rowid DESC LIMIT 1",
                params![speaker_id, session.0],
                |row| row.get(0),
            )
            .optional()?;
        let current = current.ok_or(StoreError::InvalidRequest(
            "speaker not found in this conversation",
        ))?;
        if current != label {
            tx.execute(
                "INSERT INTO transcript_speaker_names(id, speaker_id, label, search_label, created_at_ms)
                 VALUES(?1, ?2, ?3, ?4, ?5)",
                params![
                    Uuid::now_v7().to_string(),
                    speaker_id,
                    label,
                    label.to_lowercase(),
                    wall_time_milliseconds()
                ],
            )?;
        }
        tx.commit()?;
        Ok(())
    }

    pub fn named_transcript_speakers(
        &self,
        session: &SessionId,
    ) -> Result<Vec<NamedTranscriptSpeaker>, StoreError> {
        let assignments = self.transcript_turn_speakers(session)?;
        let mut statement = self.connection.prepare(
            "SELECT speakers.id, names.label FROM transcript_named_speakers AS speakers
             JOIN transcript_speaker_names AS names ON names.rowid = (
                SELECT rowid FROM transcript_speaker_names WHERE speaker_id = speakers.id
                ORDER BY rowid DESC LIMIT 1)
             WHERE speakers.session_id = ?1 ORDER BY names.label COLLATE NOCASE, speakers.id",
        )?;
        let people = statement
            .query_map([&session.0], |row| {
                Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?))
            })?
            .collect::<Result<Vec<_>, _>>()?;
        let selected: std::collections::BTreeSet<String> = self
            .connection
            .prepare("SELECT revision_id FROM transcript_selections WHERE session_id = ?1")?
            .query_map([&session.0], |row| row.get(0))?
            .collect::<Result<_, _>>()?;
        Ok(people
            .into_iter()
            .map(|(id, label)| {
                let selected_turns = assignments
                    .iter()
                    .filter(|((revision, _), speaker)| {
                        selected.contains(revision) && speaker.id == id
                    })
                    .count() as u32;
                NamedTranscriptSpeaker {
                    id,
                    label,
                    selected_turns,
                }
            })
            .collect())
    }

    pub(super) fn transcript_turn_speakers(
        &self,
        session: &SessionId,
    ) -> Result<TurnSpeakers, StoreError> {
        let mut statement = self.connection.prepare(
            "SELECT turns.revision_id, turns.sequence, turns.speaker_id, names.label
             FROM transcript_turn_speakers AS turns
             JOIN transcript_speaker_names AS names ON names.rowid = (
                SELECT rowid FROM transcript_speaker_names
                WHERE speaker_id = turns.speaker_id ORDER BY rowid DESC LIMIT 1)
             WHERE turns.session_id = ?1 AND turns.speaker_id IS NOT NULL
               AND turns.rowid = (
                SELECT latest.rowid FROM transcript_turn_speakers AS latest
                WHERE latest.session_id = turns.session_id
                  AND latest.revision_id = turns.revision_id AND latest.sequence = turns.sequence
                ORDER BY latest.rowid DESC LIMIT 1)",
        )?;
        statement
            .query_map([&session.0], |row| {
                Ok((
                    (row.get(0)?, row.get(1)?),
                    TurnSpeaker {
                        id: row.get(2)?,
                        label: row.get(3)?,
                    },
                ))
            })?
            .collect::<Result<_, _>>()
            .map_err(StoreError::from)
    }
}

#[cfg(test)]
#[path = "transcript_speakers_tests.rs"]
mod tests;
