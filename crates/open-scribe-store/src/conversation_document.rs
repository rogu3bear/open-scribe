//! One read of a conversation's transcript document (ADR 0009, ADR 0010).
//!
//! The reader, Copy, the file exports and provenance read here, in one of
//! two scopes. `Readable` is what a person sees: each track's selected Final
//! revision plus Draft text that no selected Final range on the same track
//! overlaps. `FinalOnly` is what a file export may cite: `transcript.v1`
//! segments are always Final, so an export cannot cite provisional text.

use super::conversation_titles::{ConversationTitle, conversation_title};
use super::transcript_review::{
    EFFECTIVE_TEXT, SessionSpeaker, SpeakerLabelOrigin, speaker_labels,
};
use super::{SessionStore, StoreError, TranscriptFinality, sha256_hex};
use open_scribe_types::SessionId;
use rusqlite::{Connection, params};

/// Which text a document read includes.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum DocumentScope {
    /// Selected Final text plus Draft text no selected Final range covers.
    Readable,
    /// Selected Final text only.
    FinalOnly,
}

/// One transcript segment of a document. `finality` is `Final` for a
/// selected revision and `Draft` for provisional text no selected Final range
/// covers; superseded rows are never part of a document.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct TranscriptDocumentSegment {
    pub revision_id: String,
    pub track_id: String,
    pub finality: TranscriptFinality,
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
    /// A human-confirmed identity for this exact turn, independent of its
    /// source track. None preserves the existing source label.
    pub named_speaker_id: Option<String>,
}

/// A conversation's title, speakers and transcript text, read together.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ConversationDocument {
    pub session_id: SessionId,
    pub title: ConversationTitle,
    pub created_at_ms: i64,
    pub speakers: Vec<SessionSpeaker>,
    /// Session timeline order: start, then track, then sequence.
    pub segments: Vec<TranscriptDocumentSegment>,
}

impl ConversationDocument {
    /// True when the document shows Draft text.
    #[must_use]
    pub fn has_draft(&self) -> bool {
        self.segments
            .iter()
            .any(|segment| segment.finality == TranscriptFinality::Draft)
    }
}

/// Draft revisions a reader shows, over `transcript_revisions AS revisions`:
/// not superseded, with text, and no segment overlapping the selected Final
/// revision of the same track.
const READABLE_DRAFT: &str = "revisions.finality = 'draft'
    AND EXISTS (SELECT 1 FROM transcript_segments AS shown
                WHERE shown.revision_id = revisions.id)
    AND NOT EXISTS (
      SELECT 1 FROM transcript_segments AS draft_segments
      JOIN transcript_selections AS selections
        ON selections.session_id = revisions.session_id
       AND selections.track_id = revisions.track_id
      JOIN transcript_segments AS final_segments
        ON final_segments.revision_id = selections.revision_id
      WHERE draft_segments.revision_id = revisions.id
        AND draft_segments.start_ns < final_segments.end_ns
        AND final_segments.start_ns < draft_segments.end_ns
    )";

/// One stored segment row in a document's scope, before speakers apply.
pub(super) struct DocumentRow {
    pub revision_id: String,
    pub track_id: String,
    pub sequence: u32,
    pub start_nanoseconds: i64,
    pub end_nanoseconds: i64,
    pub verbatim_text: String,
    pub effective_text: String,
    pub finality: TranscriptFinality,
}

/// The segment rows of `scope`, in session timeline order.
pub(super) fn document_rows(
    connection: &Connection,
    session_id: &str,
    scope: DocumentScope,
) -> Result<Vec<DocumentRow>, StoreError> {
    let mut statement = connection.prepare_cached(&format!(
        "SELECT segments.revision_id, revisions.track_id, segments.sequence,
                segments.start_ns, segments.end_ns, segments.text, {EFFECTIVE_TEXT},
                revisions.finality
         FROM transcript_revisions AS revisions
         JOIN transcript_segments AS segments ON segments.revision_id = revisions.id
         WHERE revisions.session_id = ?1
           AND ((revisions.finality = 'final'
                 AND EXISTS (SELECT 1 FROM transcript_selections AS selected
                             WHERE selected.session_id = revisions.session_id
                               AND selected.track_id = revisions.track_id
                               AND selected.revision_id = revisions.id))
                OR (?2 AND {READABLE_DRAFT}))
         ORDER BY segments.start_ns, revisions.track_id, segments.sequence, revisions.id"
    ))?;
    let rows = statement
        .query_map(
            params![session_id, scope == DocumentScope::Readable],
            |row| {
                Ok(DocumentRow {
                    revision_id: row.get(0)?,
                    track_id: row.get(1)?,
                    sequence: row.get(2)?,
                    start_nanoseconds: row.get(3)?,
                    end_nanoseconds: row.get(4)?,
                    verbatim_text: row.get(5)?,
                    effective_text: row.get(6)?,
                    finality: row.get(7)?,
                })
            },
        )?
        .collect::<Result<_, _>>()?;
    Ok(rows)
}

/// Readable Draft revisions of one session; the runtime snapshot reports them.
pub(super) fn readable_draft_count(
    connection: &Connection,
    session_id: &str,
) -> Result<u32, StoreError> {
    Ok(connection
        .prepare_cached(&format!(
            "SELECT COUNT(*) FROM transcript_revisions AS revisions
             WHERE revisions.session_id = ?1 AND {READABLE_DRAFT}"
        ))?
        .query_row([session_id], |row| row.get(0))?)
}

impl SessionStore {
    /// Reads the title, speakers and text of one conversation that is not
    /// deleted, in one read transaction.
    pub fn conversation_document(
        &self,
        session: &SessionId,
        scope: DocumentScope,
    ) -> Result<ConversationDocument, StoreError> {
        // Deferred, so the read never holds the write lock.
        let transaction = rusqlite::Transaction::new_unchecked(
            &self.connection,
            rusqlite::TransactionBehavior::Deferred,
        )?;
        let title = conversation_title(&transaction, &session.0)?;
        let created_at_ms: i64 = transaction.query_row(
            "SELECT created_at_ms FROM sessions WHERE id = ?1",
            [&session.0],
            |row| row.get(0),
        )?;
        let speakers = speaker_labels(&transaction, &session.0)?;
        let turn_speakers = super::transcript_speakers::turn_speakers(&transaction, &session.0)?;
        let segments = document_rows(&transaction, &session.0, scope)?
            .into_iter()
            .map(|row| {
                let speaker = speakers
                    .iter()
                    .find(|speaker| speaker.track_id == row.track_id)
                    .ok_or(StoreError::IntegrityMismatch(
                        "transcript track has no source identity",
                    ))?;
                let named = turn_speakers.get(&(row.revision_id.clone(), row.sequence));
                Ok(TranscriptDocumentSegment {
                    corrected: row.effective_text != row.verbatim_text,
                    speaker_label: named
                        .map_or_else(|| speaker.label.clone(), |person| person.label.clone()),
                    speaker_origin: if named.is_some() {
                        SpeakerLabelOrigin::Human
                    } else {
                        speaker.origin
                    },
                    named_speaker_id: named.map(|person| person.id.clone()),
                    verbatim_sha256: sha256_hex(row.verbatim_text.as_bytes()),
                    revision_id: row.revision_id,
                    track_id: row.track_id,
                    finality: row.finality,
                    sequence: row.sequence,
                    start_nanoseconds: row.start_nanoseconds,
                    end_nanoseconds: row.end_nanoseconds,
                    verbatim_text: row.verbatim_text,
                    effective_text: row.effective_text,
                })
            })
            .collect::<Result<_, StoreError>>()?;
        Ok(ConversationDocument {
            session_id: session.clone(),
            title,
            created_at_ms,
            speakers,
            segments,
        })
    }

    /// True when the readable document of `session` shows Draft text.
    pub fn has_readable_draft(&self, session: &SessionId) -> Result<bool, StoreError> {
        Ok(readable_draft_count(&self.connection, &session.0)? > 0)
    }
}
