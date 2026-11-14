//! Human review over derived transcripts (ADR 0009): segment corrections,
//! source-aware speaker names, and Final-text search.
//!
//! Corrections and speaker names are append-only adjudication records; a
//! verbatim revision is never rewritten. A segment's effective text is its
//! latest correction, otherwise its verbatim text, and a correction without
//! text restores the verbatim reading. Known capture topology names a track's
//! speaker before any diarization (PRD 11.3). The FTS5 index holds only the
//! effective text of each track's selected Final revision. It is a
//! regenerable projection without foreign keys, so deletion must clear it
//! explicitly.

use super::conversation_titles::{TITLE_COLUMNS, TITLE_JOIN, TitleRow};
use super::{SessionStore, StoreError, TitleSource, TrackSourceKind, wall_time_milliseconds};
use open_scribe_types::SessionId;
use rusqlite::{Connection, OptionalExtension, Transaction, params};
use uuid::Uuid;

pub(super) const REVIEW_MIGRATION_VERSION: i64 = 6;
const MAX_CORRECTION_BYTES: usize = 4096;
const MAX_SPEAKER_LABEL_BYTES: usize = 128;
const MAX_QUERY_TERMS: usize = 16;
pub(super) const MAX_SEARCH_RESULTS: u32 = 200;
/// The only speaker cluster before diarization: the whole source track.
pub(super) const SOURCE_CLUSTER: &str = "source";

/// Review tables are append-only, so the latest row of any of them is the
/// last one appended: the highest rowid. Wall-clock time can step back and
/// never orders them.
pub(super) const EFFECTIVE_TEXT: &str = "COALESCE(
    (SELECT corrections.text FROM transcript_corrections AS corrections
     WHERE corrections.revision_id = segments.revision_id
       AND corrections.sequence = segments.sequence
     ORDER BY corrections.rowid DESC LIMIT 1),
    segments.text)";

pub(super) fn apply_review_schema(transaction: &Transaction<'_>) -> Result<(), StoreError> {
    let already_applied: bool = transaction.query_row(
        "SELECT EXISTS(SELECT 1 FROM schema_migrations WHERE version = ?1)",
        [REVIEW_MIGRATION_VERSION],
        |row| row.get(0),
    )?;
    transaction.execute_batch(
        "CREATE TABLE IF NOT EXISTS transcript_corrections (
            id TEXT PRIMARY KEY,
            session_id TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
            revision_id TEXT NOT NULL,
            sequence INTEGER NOT NULL,
            text TEXT,
            created_at_ms INTEGER NOT NULL,
            FOREIGN KEY (revision_id, sequence)
                REFERENCES transcript_segments(revision_id, sequence) ON DELETE CASCADE
        );
        CREATE INDEX IF NOT EXISTS transcript_corrections_by_segment
            ON transcript_corrections(revision_id, sequence, created_at_ms);
        CREATE TABLE IF NOT EXISTS speaker_adjudications (
            id TEXT PRIMARY KEY,
            session_id TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
            track_id TEXT NOT NULL REFERENCES tracks(id),
            cluster TEXT NOT NULL,
            label TEXT,
            created_at_ms INTEGER NOT NULL
        );
        CREATE INDEX IF NOT EXISTS speaker_adjudications_by_track
            ON speaker_adjudications(session_id, track_id, cluster, created_at_ms);
        CREATE TRIGGER IF NOT EXISTS transcript_corrections_append_only
            BEFORE UPDATE ON transcript_corrections
            BEGIN SELECT RAISE(ABORT, 'transcript corrections are append-only'); END;
        CREATE TRIGGER IF NOT EXISTS speaker_adjudications_append_only
            BEFORE UPDATE ON speaker_adjudications
            BEGIN SELECT RAISE(ABORT, 'speaker adjudications are append-only'); END;
        CREATE VIRTUAL TABLE IF NOT EXISTS transcript_search USING fts5(
            text,
            session_id UNINDEXED,
            revision_id UNINDEXED,
            track_id UNINDEXED,
            sequence UNINDEXED,
            start_ns UNINDEXED,
            end_ns UNINDEXED,
            tokenize = 'unicode61 remove_diacritics 2'
        );",
    )?;
    if !already_applied {
        // Selections committed under migration 5 predate the index.
        transaction.execute("DELETE FROM transcript_search", [])?;
        let sessions: Vec<String> = transaction
            .prepare("SELECT DISTINCT session_id FROM transcript_selections")?
            .query_map([], |row| row.get(0))?
            .collect::<Result<_, _>>()?;
        for session_id in sessions {
            reindex_session_search(transaction, &session_id)?;
        }
    }
    Ok(())
}

/// Rebuilds one session's search rows from its selected revisions. Only the
/// writes that change a selection (`select_revision`) or a correction
/// (`append_correction`) call it, in their own transaction.
pub(super) fn reindex_session_search(
    transaction: &Transaction<'_>,
    session_id: &str,
) -> Result<(), StoreError> {
    transaction.execute(
        "DELETE FROM transcript_search WHERE session_id = ?1",
        [session_id],
    )?;
    transaction.execute(
        &format!(
            "INSERT INTO transcript_search(
                text, session_id, revision_id, track_id, sequence, start_ns, end_ns)
             SELECT {EFFECTIVE_TEXT}, selections.session_id, segments.revision_id,
                    revisions.track_id, segments.sequence, segments.start_ns, segments.end_ns
             FROM transcript_selections AS selections
             JOIN transcript_revisions AS revisions ON revisions.id = selections.revision_id
             JOIN transcript_segments AS segments ON segments.revision_id = revisions.id
             WHERE selections.session_id = ?1"
        ),
        [session_id],
    )?;
    Ok(())
}

/// Who a speaker label came from.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum SpeakerLabelOrigin {
    /// Derived from the capture source kind; no human has named it.
    SourceDefault,
    /// The latest human rename.
    Human,
}

impl SpeakerLabelOrigin {
    /// The token `transcript.v1` and the diarization record store.
    #[must_use]
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::SourceDefault => "source_default",
            Self::Human => "human",
        }
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct SessionSpeaker {
    pub track_id: String,
    pub source_kind: TrackSourceKind,
    pub label: String,
    pub origin: SpeakerLabelOrigin,
}

/// One stored speaker-name change. A null stored label is presented as the
/// source default; it is not dropped.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct SpeakerLabelRevision {
    pub label: String,
    pub origin: SpeakerLabelOrigin,
    pub created_at_ms: i64,
}

/// The source-derived name plus every stored rename for one track, oldest first.
/// A track with no stored rename has an empty `revisions` list. The source
/// default stays available either way.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct SpeakerLabelHistory {
    pub track_id: String,
    pub source_kind: TrackSourceKind,
    pub source_default_label: String,
    pub revisions: Vec<SpeakerLabelRevision>,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct TranscriptSearchHit {
    pub session_id: String,
    /// The title the library shows for the conversation.
    pub session_title: String,
    pub title_source: TitleSource,
    pub placeholder_at_ms: Option<i64>,
    pub revision_id: String,
    pub track_id: String,
    pub sequence: u32,
    pub start_nanoseconds: i64,
    pub end_nanoseconds: i64,
    pub effective_text: String,
}

impl SessionStore {
    /// Appends a human correction to one segment of a revision. `None`
    /// restores the verbatim reading; the verbatim row never changes.
    pub fn correct_transcript_segment(
        &mut self,
        session: &SessionId,
        revision_id: &str,
        sequence: u32,
        text: Option<&str>,
    ) -> Result<String, StoreError> {
        let _writer = self.write_guard()?;
        let text = match text {
            Some(text) => {
                let trimmed = text.trim();
                if trimmed.is_empty() || trimmed.len() > MAX_CORRECTION_BYTES {
                    return Err(StoreError::InvalidRequest(
                        "correction text is empty or too long",
                    ));
                }
                Some(trimmed.to_owned())
            }
            None => None,
        };
        let transaction = self.connection.transaction()?;
        require_reviewable_session(&transaction, &session.0)?;
        let owned: bool = transaction.query_row(
            "SELECT EXISTS(SELECT 1 FROM transcript_segments AS segments
                           JOIN transcript_revisions AS revisions
                             ON revisions.id = segments.revision_id
                           WHERE segments.revision_id = ?1 AND segments.sequence = ?2
                             AND revisions.session_id = ?3
                             AND revisions.finality = 'final')",
            params![revision_id, sequence, session.0],
            |row| row.get(0),
        )?;
        if !owned {
            return Err(StoreError::InvalidRequest(
                "segment does not belong to this session",
            ));
        }
        let correction_id = append_correction(
            &transaction,
            &session.0,
            revision_id,
            sequence,
            text.as_deref(),
            wall_time_milliseconds(),
        )?;
        transaction.commit()?;
        Ok(correction_id)
    }

    /// Appends a human name for a track's speaker. `None` restores the
    /// source-derived default.
    pub fn rename_speaker(
        &mut self,
        session: &SessionId,
        track_id: &str,
        label: Option<&str>,
    ) -> Result<(), StoreError> {
        let _writer = self.write_guard()?;
        let label = label.map(checked_speaker_label).transpose()?;
        let transaction = self.connection.transaction()?;
        require_reviewable_session(&transaction, &session.0)?;
        let owned: bool = transaction.query_row(
            "SELECT EXISTS(SELECT 1 FROM tracks WHERE id = ?1 AND session_id = ?2)",
            params![track_id, session.0],
            |row| row.get(0),
        )?;
        if !owned {
            return Err(StoreError::InvalidRequest(
                "track does not belong to this session",
            ));
        }
        transaction.execute(
            "INSERT INTO speaker_adjudications(
                id, session_id, track_id, cluster, label, created_at_ms)
             VALUES(?1, ?2, ?3, ?4, ?5, ?6)",
            params![
                Uuid::now_v7().to_string(),
                session.0,
                track_id,
                SOURCE_CLUSTER,
                label,
                wall_time_milliseconds()
            ],
        )?;
        transaction.commit()?;
        Ok(())
    }

    pub fn session_speakers(&self, session: &SessionId) -> Result<Vec<SessionSpeaker>, StoreError> {
        speaker_labels(&self.connection, &session.0)
    }

    /// Oldest-first speaker names for every source track.
    /// `source_default_label` comes from the source kind even when no row
    /// stores it. A stored null label is one revision of that source default.
    /// A join row with no `created_at_ms` is a track that has no revision.
    pub fn speaker_label_history(
        &self,
        session: &SessionId,
    ) -> Result<Vec<SpeakerLabelHistory>, StoreError> {
        let mut statement = self.connection.prepare(
            "SELECT tracks.id, sources.kind, adjudications.label, adjudications.created_at_ms
             FROM tracks
             JOIN sources ON sources.id = tracks.source_id
             LEFT JOIN speaker_adjudications AS adjudications
               ON adjudications.session_id = tracks.session_id
              AND adjudications.track_id = tracks.id
              AND adjudications.cluster = ?2
             WHERE tracks.session_id = ?1
             ORDER BY tracks.id, adjudications.rowid",
        )?;
        let rows = statement
            .query_map(params![session.0, SOURCE_CLUSTER], |row| {
                Ok((
                    row.get::<_, String>(0)?,
                    row.get::<_, TrackSourceKind>(1)?,
                    row.get::<_, Option<String>>(2)?,
                    row.get::<_, Option<i64>>(3)?,
                ))
            })?
            .collect::<Result<Vec<_>, _>>()?;
        let mut histories: Vec<SpeakerLabelHistory> = Vec::new();
        for (track_id, source_kind, stored_label, created_at_ms) in rows {
            let same_track = histories
                .last()
                .is_some_and(|history| history.track_id == track_id);
            if !same_track {
                histories.push(SpeakerLabelHistory {
                    track_id,
                    source_kind,
                    source_default_label: source_kind.default_speaker_label().to_owned(),
                    revisions: Vec::new(),
                });
            }
            let Some(created_at_ms) = created_at_ms else {
                continue;
            };
            let Some(history) = histories.last_mut() else {
                continue;
            };
            let (label, origin) = match stored_label {
                Some(label) => (label, SpeakerLabelOrigin::Human),
                None => (
                    history.source_default_label.clone(),
                    SpeakerLabelOrigin::SourceDefault,
                ),
            };
            history.revisions.push(SpeakerLabelRevision {
                label,
                origin,
                created_at_ms,
            });
        }
        Ok(histories)
    }

    /// Searches effective Final text of selected revisions. Every
    /// whitespace-separated term must match; the last term also matches as a
    /// prefix. User text is always quoted, never parsed as FTS5 syntax.
    pub fn search_transcripts(
        &self,
        query: &str,
        session: Option<&SessionId>,
        limit: u32,
    ) -> Result<Vec<TranscriptSearchHit>, StoreError> {
        let Some(expression) = fts_expression(query) else {
            return Ok(Vec::new());
        };
        let limit = limit.clamp(1, MAX_SEARCH_RESULTS);
        let mut statement = self.connection.prepare(&format!(
            "SELECT transcript_search.session_id, transcript_search.revision_id,
                    transcript_search.track_id, transcript_search.sequence,
                    transcript_search.start_ns, transcript_search.end_ns, transcript_search.text,
                    {TITLE_COLUMNS}
             FROM transcript_search
             JOIN sessions ON sessions.id = transcript_search.session_id
             {TITLE_JOIN}
             WHERE transcript_search MATCH ?1
               AND sessions.lifecycle <> 'deleted'
               AND (?2 IS NULL OR transcript_search.session_id = ?2)
             ORDER BY transcript_search.rank, transcript_search.session_id,
                      transcript_search.start_ns
             LIMIT ?3"
        ))?;
        let rows = statement
            .query_map(
                params![expression, session.map(|session| &session.0), limit],
                SearchRow::read,
            )?
            .collect::<Result<Vec<_>, _>>()?;
        rows.into_iter().map(SearchRow::resolve).collect()
    }
}

/// One search match as read, before its session title resolves. Both text
/// and speaker search select these columns, then [`TITLE_COLUMNS`].
pub(super) struct SearchRow {
    session_id: String,
    revision_id: String,
    track_id: String,
    sequence: u32,
    start_nanoseconds: i64,
    end_nanoseconds: i64,
    effective_text: String,
    title: TitleRow,
}

impl SearchRow {
    pub(super) fn read(row: &rusqlite::Row<'_>) -> rusqlite::Result<Self> {
        Ok(Self {
            session_id: row.get(0)?,
            revision_id: row.get(1)?,
            track_id: row.get(2)?,
            sequence: row.get(3)?,
            start_nanoseconds: row.get(4)?,
            end_nanoseconds: row.get(5)?,
            effective_text: row.get(6)?,
            title: TitleRow::read(row, 7)?,
        })
    }

    pub(super) fn resolve(self) -> Result<TranscriptSearchHit, StoreError> {
        let title = self.title.resolve()?;
        Ok(TranscriptSearchHit {
            session_id: self.session_id,
            session_title: title.display_title,
            title_source: title.source,
            placeholder_at_ms: title.placeholder_at_ms,
            revision_id: self.revision_id,
            track_id: self.track_id,
            sequence: self.sequence,
            start_nanoseconds: self.start_nanoseconds,
            end_nanoseconds: self.end_nanoseconds,
            effective_text: self.effective_text,
        })
    }
}

/// The one read of a session's source-track speakers: each track's latest
/// human name, or its source default.
pub(super) fn speaker_labels(
    connection: &Connection,
    session_id: &str,
) -> Result<Vec<SessionSpeaker>, StoreError> {
    let mut statement = connection.prepare_cached(
        "SELECT tracks.id, sources.kind,
                (SELECT adjudications.label FROM speaker_adjudications AS adjudications
                 WHERE adjudications.session_id = tracks.session_id
                   AND adjudications.track_id = tracks.id
                   AND adjudications.cluster = ?2
                 ORDER BY adjudications.rowid DESC LIMIT 1)
         FROM tracks JOIN sources ON sources.id = tracks.source_id
         WHERE tracks.session_id = ?1
         ORDER BY tracks.id",
    )?;
    let speakers = statement
        .query_map(params![session_id, SOURCE_CLUSTER], |row| {
            let source_kind: TrackSourceKind = row.get(1)?;
            let (label, origin) = match row.get::<_, Option<String>>(2)? {
                Some(label) => (label, SpeakerLabelOrigin::Human),
                None => (
                    source_kind.default_speaker_label().to_owned(),
                    SpeakerLabelOrigin::SourceDefault,
                ),
            };
            Ok(SessionSpeaker {
                track_id: row.get(0)?,
                source_kind,
                label,
                origin,
            })
        })?
        .collect::<Result<_, _>>()?;
    Ok(speakers)
}

/// Appends one correction and reindexes the session in the same
/// transaction, so search never shows the replaced text.
pub(super) fn append_correction(
    transaction: &Transaction<'_>,
    session_id: &str,
    revision_id: &str,
    sequence: u32,
    text: Option<&str>,
    now: i64,
) -> Result<String, StoreError> {
    let correction_id =
        insert_correction(transaction, session_id, revision_id, sequence, text, now)?;
    reindex_session_search(transaction, session_id)?;
    Ok(correction_id)
}

/// The correction row alone. Only a revision that is not yet selected, and
/// so not yet indexed, may take one without reindexing.
pub(super) fn insert_correction(
    transaction: &Transaction<'_>,
    session_id: &str,
    revision_id: &str,
    sequence: u32,
    text: Option<&str>,
    now: i64,
) -> Result<String, StoreError> {
    let correction_id = Uuid::now_v7().to_string();
    transaction.execute(
        "INSERT INTO transcript_corrections(
            id, session_id, revision_id, sequence, text, created_at_ms)
         VALUES(?1, ?2, ?3, ?4, ?5, ?6)",
        params![correction_id, session_id, revision_id, sequence, text, now],
    )?;
    Ok(correction_id)
}

/// The one speaker-name rule, for track names and named people alike.
pub(super) fn checked_speaker_label(label: &str) -> Result<&str, StoreError> {
    let label = label.trim();
    if label.is_empty()
        || label.len() > MAX_SPEAKER_LABEL_BYTES
        || label.chars().any(char::is_control)
    {
        return Err(StoreError::InvalidRequest("speaker label is invalid"));
    }
    Ok(label)
}

pub(super) fn require_reviewable_session(
    transaction: &Transaction<'_>,
    session_id: &str,
) -> Result<(), StoreError> {
    super::session_deletion::require_available(transaction, session_id)?;
    let lifecycle: Option<String> = transaction
        .query_row(
            "SELECT lifecycle FROM sessions WHERE id = ?1",
            [session_id],
            |row| row.get(0),
        )
        .optional()?;
    match lifecycle.as_deref() {
        Some("ready_for_review") => Ok(()),
        Some(_) => Err(StoreError::InvalidState("session is not ready for review")),
        None => Err(StoreError::InvalidRequest("session does not exist")),
    }
}

/// Quotes each term so punctuation and FTS5 operators in user text stay
/// literal. Terms without a letter or digit cannot match and are dropped.
fn fts_expression(query: &str) -> Option<String> {
    let terms: Vec<String> = query
        .split_whitespace()
        .filter(|term| term.chars().any(char::is_alphanumeric))
        .take(MAX_QUERY_TERMS)
        .map(|term| format!("\"{}\"", term.replace('"', "\"\"")))
        .collect();
    let (last, rest) = terms.split_last()?;
    let mut expression = rest.join(" ");
    if !expression.is_empty() {
        expression.push(' ');
    }
    expression.push_str(last);
    expression.push('*');
    Some(expression)
}

#[cfg(test)]
#[path = "transcript_review_tests.rs"]
mod tests;
