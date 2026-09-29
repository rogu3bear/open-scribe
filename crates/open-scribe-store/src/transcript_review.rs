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

use super::{SessionStore, StoreError, wall_time_milliseconds};
use open_scribe_types::SessionId;
use rusqlite::{OptionalExtension, Transaction, params};
use sha2::{Digest, Sha256};
use uuid::Uuid;

pub(super) const REVIEW_MIGRATION_VERSION: i64 = 6;
const MAX_CORRECTION_BYTES: usize = 4096;
const MAX_SPEAKER_LABEL_BYTES: usize = 128;
const MAX_QUERY_TERMS: usize = 16;
const MAX_SEARCH_RESULTS: u32 = 200;
/// The only speaker cluster before diarization: the whole source track.
const SOURCE_CLUSTER: &str = "source";

const EFFECTIVE_TEXT: &str = "COALESCE(
    (SELECT corrections.text FROM transcript_corrections AS corrections
     WHERE corrections.revision_id = segments.revision_id
       AND corrections.sequence = segments.sequence
     ORDER BY corrections.created_at_ms DESC, corrections.rowid DESC LIMIT 1),
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

/// Rebuilds one session's search rows from its selected revisions. Callers
/// run it in the transaction that changed a selection or a correction.
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

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct SessionSpeaker {
    pub track_id: String,
    pub source_kind: String,
    pub label: String,
    pub origin: SpeakerLabelOrigin,
}

/// One selected Final segment as the transcript document presents it.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct TranscriptDocumentSegment {
    pub revision_id: String,
    pub track_id: String,
    pub sequence: u32,
    pub start_nanoseconds: i64,
    pub end_nanoseconds: i64,
    pub verbatim_text: String,
    /// Lowercase SHA-256 of the immutable verbatim text; evidence
    /// references bind to it.
    pub verbatim_sha256: String,
    pub effective_text: String,
    /// True when a human correction supplies the effective text.
    pub corrected: bool,
    pub speaker_label: String,
    pub speaker_origin: SpeakerLabelOrigin,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct TranscriptSearchHit {
    pub session_id: String,
    pub session_title: String,
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
                             AND revisions.session_id = ?3)",
            params![revision_id, sequence, session.0],
            |row| row.get(0),
        )?;
        if !owned {
            return Err(StoreError::InvalidRequest(
                "segment does not belong to this session",
            ));
        }
        let correction_id = Uuid::now_v7().to_string();
        transaction.execute(
            "INSERT INTO transcript_corrections(
                id, session_id, revision_id, sequence, text, created_at_ms)
             VALUES(?1, ?2, ?3, ?4, ?5, ?6)",
            params![
                correction_id,
                session.0,
                revision_id,
                sequence,
                text,
                wall_time_milliseconds()
            ],
        )?;
        reindex_session_search(&transaction, &session.0)?;
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
        let label = match label {
            Some(label) => {
                let trimmed = label.trim();
                if trimmed.is_empty()
                    || trimmed.len() > MAX_SPEAKER_LABEL_BYTES
                    || trimmed.chars().any(char::is_control)
                {
                    return Err(StoreError::InvalidRequest("speaker label is invalid"));
                }
                Some(trimmed.to_owned())
            }
            None => None,
        };
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
        let mut statement = self.connection.prepare(
            "SELECT tracks.id, sources.kind,
                    (SELECT adjudications.label FROM speaker_adjudications AS adjudications
                     WHERE adjudications.session_id = tracks.session_id
                       AND adjudications.track_id = tracks.id
                       AND adjudications.cluster = ?2
                     ORDER BY adjudications.created_at_ms DESC, adjudications.rowid DESC
                     LIMIT 1)
             FROM tracks JOIN sources ON sources.id = tracks.source_id
             WHERE tracks.session_id = ?1
             ORDER BY tracks.id",
        )?;
        let speakers = statement
            .query_map(params![session.0, SOURCE_CLUSTER], |row| {
                Ok((
                    row.get::<_, String>(0)?,
                    row.get::<_, String>(1)?,
                    row.get::<_, Option<String>>(2)?,
                ))
            })?
            .collect::<Result<Vec<_>, _>>()?;
        Ok(speakers
            .into_iter()
            .map(|(track_id, source_kind, human)| {
                let (label, origin) = match human {
                    Some(label) => (label, SpeakerLabelOrigin::Human),
                    None => (
                        default_speaker_label(&source_kind).to_owned(),
                        SpeakerLabelOrigin::SourceDefault,
                    ),
                };
                SessionSpeaker {
                    track_id,
                    source_kind,
                    label,
                    origin,
                }
            })
            .collect())
    }

    /// Selected Final text across tracks on the session timeline, with
    /// effective text, correction provenance, and speaker identity.
    pub fn transcript_document(
        &self,
        session: &SessionId,
    ) -> Result<Vec<TranscriptDocumentSegment>, StoreError> {
        let speakers = self.session_speakers(session)?;
        let mut statement = self.connection.prepare(&format!(
            "SELECT segments.revision_id, revisions.track_id, segments.sequence,
                    segments.start_ns, segments.end_ns, segments.text, {EFFECTIVE_TEXT}
             FROM transcript_selections AS selections
             JOIN transcript_revisions AS revisions ON revisions.id = selections.revision_id
             JOIN transcript_segments AS segments ON segments.revision_id = revisions.id
             WHERE selections.session_id = ?1
             ORDER BY segments.start_ns, revisions.track_id, segments.sequence"
        ))?;
        let rows = statement
            .query_map([&session.0], |row| {
                Ok((
                    row.get::<_, String>(0)?,
                    row.get::<_, String>(1)?,
                    row.get::<_, u32>(2)?,
                    row.get::<_, i64>(3)?,
                    row.get::<_, i64>(4)?,
                    row.get::<_, String>(5)?,
                    row.get::<_, String>(6)?,
                ))
            })?
            .collect::<Result<Vec<_>, _>>()?;
        rows.into_iter()
            .map(
                |(revision_id, track_id, sequence, start, end, verbatim, effective)| {
                    let speaker = speakers
                        .iter()
                        .find(|speaker| speaker.track_id == track_id)
                        .ok_or(StoreError::IntegrityMismatch(
                            "transcript track has no source identity",
                        ))?;
                    Ok(TranscriptDocumentSegment {
                        corrected: effective != verbatim,
                        speaker_label: speaker.label.clone(),
                        speaker_origin: speaker.origin,
                        revision_id,
                        track_id,
                        sequence,
                        start_nanoseconds: start,
                        end_nanoseconds: end,
                        verbatim_sha256: Sha256::digest(verbatim.as_bytes())
                            .iter()
                            .map(|byte| format!("{byte:02x}"))
                            .collect(),
                        verbatim_text: verbatim,
                        effective_text: effective,
                    })
                },
            )
            .collect()
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
        let mut statement = self.connection.prepare(
            "SELECT transcript_search.session_id, sessions.title, transcript_search.revision_id,
                    transcript_search.track_id, transcript_search.sequence,
                    transcript_search.start_ns, transcript_search.end_ns, transcript_search.text
             FROM transcript_search
             JOIN sessions ON sessions.id = transcript_search.session_id
             WHERE transcript_search MATCH ?1
               AND sessions.lifecycle <> 'deleted'
               AND (?2 IS NULL OR transcript_search.session_id = ?2)
             ORDER BY transcript_search.rank, transcript_search.session_id,
                      transcript_search.start_ns
             LIMIT ?3",
        )?;
        let hits = statement
            .query_map(
                params![expression, session.map(|session| &session.0), limit],
                |row| {
                    Ok(TranscriptSearchHit {
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
            .collect::<Result<_, _>>()?;
        Ok(hits)
    }
}

fn require_reviewable_session(
    transaction: &Transaction<'_>,
    session_id: &str,
) -> Result<(), StoreError> {
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

fn default_speaker_label(source_kind: &str) -> &'static str {
    match source_kind {
        "microphone" => "Local user",
        "application_audio" => "Remote participants",
        "system_audio" => "System audio",
        _ => "Unknown speaker",
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
