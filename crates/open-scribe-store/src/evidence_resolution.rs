//! Evidence citation and resolution (ADR 0013).
//!
//! Rust derives every reference from stored identity, so a caller never
//! chooses the IDs, ranges, or digests it cites. Resolution re-reads the
//! cited record and returns exactly one of the six permitted states; missing
//! or deleted evidence is never silently replaced by something nearby.
//!
//! Per kind, a reference binds:
//! - transcript segment: the immutable revision (`record_id` and
//!   `revision_id`, as the transcript export writes it), the segment sequence,
//!   and the SHA-256 of its verbatim text;
//! - human correction: the correction, its revision and sequence, and the
//!   SHA-256 of its replacement text (empty when it restored the verbatim);
//! - audio range: the track, the sealed segment holding its start, and that
//!   segment's sealed digest, rechecked against the file's full bytes;
//! - marker: the marker and the SHA-256 of its label;
//! - context event: the accepted event, optionally one text block
//!   (`block-N`), and the event digest or the block text's SHA-256.

use super::*;
use open_scribe_evidence::{
    EVIDENCE_REF_SCHEMA, EvidenceKind, EvidenceRef, EvidenceRefError, ResolutionState,
};
use rusqlite::OptionalExtension;

/// A resolved reference and what a surface may navigate to.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ResolvedEvidence {
    pub state: ResolutionState,
    /// The cited content when it is text and still available.
    pub text: Option<String>,
    /// For a superseded transcript revision, the currently selected one.
    pub current_revision_id: Option<String>,
}

impl ResolvedEvidence {
    fn state(state: ResolutionState) -> Self {
        Self {
            state,
            text: None,
            current_revision_id: None,
        }
    }

    fn available(text: Option<String>) -> Self {
        Self {
            state: ResolutionState::Available,
            text,
            current_revision_id: None,
        }
    }
}

fn text_digest(text: &str) -> String {
    format!("{:x}", Sha256::digest(text.as_bytes()))
}

fn reference(
    session: &SessionId,
    kind: EvidenceKind,
    record_id: &str,
    revision_id: Option<String>,
    range: (i64, i64),
    sub_item: Option<String>,
    content_digest: String,
) -> Result<EvidenceRef, StoreError> {
    let reference = EvidenceRef {
        schema: EVIDENCE_REF_SCHEMA.to_owned(),
        session_id: session.0.clone(),
        kind,
        record_id: record_id.to_owned(),
        revision_id,
        start_ns: range.0,
        end_ns: range.1.max(range.0 + 1),
        sub_item,
        content_digest,
        resolver_hint: Some(ResolutionState::Available),
    };
    reference
        .validate()
        .map_err(|_| StoreError::IntegrityMismatch("stored evidence cannot form a reference"))?;
    Ok(reference)
}

impl SessionStore {
    pub fn cite_transcript_segment(
        &self,
        session: &SessionId,
        revision_id: &str,
        sequence: u32,
    ) -> Result<EvidenceRef, StoreError> {
        let (start, end, text): (i64, i64, String) = self
            .connection
            .query_row(
                "SELECT segments.start_ns, segments.end_ns, segments.text
                 FROM transcript_segments AS segments
                 JOIN transcript_revisions AS revisions ON revisions.id = segments.revision_id
                 WHERE revisions.session_id = ?1 AND segments.revision_id = ?2
                   AND segments.sequence = ?3",
                params![session.0, revision_id, sequence],
                |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?)),
            )
            .optional()?
            .ok_or(StoreError::InvalidRequest("no such transcript segment"))?;
        reference(
            session,
            EvidenceKind::TranscriptSegment,
            revision_id,
            Some(revision_id.to_owned()),
            (start, end),
            Some(sequence.to_string()),
            text_digest(&text),
        )
    }

    pub fn cite_marker(
        &self,
        session: &SessionId,
        marker_id: &str,
    ) -> Result<EvidenceRef, StoreError> {
        let (at, label): (i64, Option<String>) = self
            .connection
            .query_row(
                "SELECT session_nanoseconds, label FROM markers WHERE session_id = ?1 AND id = ?2",
                params![session.0, marker_id],
                |row| Ok((row.get(0)?, row.get(1)?)),
            )
            .optional()?
            .ok_or(StoreError::InvalidRequest("no such marker"))?;
        reference(
            session,
            EvidenceKind::Marker,
            marker_id,
            None,
            (at.max(0), at.max(0) + 1),
            None,
            text_digest(label.as_deref().unwrap_or("")),
        )
    }

    pub fn cite_human_correction(
        &self,
        session: &SessionId,
        correction_id: &str,
    ) -> Result<EvidenceRef, StoreError> {
        let (revision, sequence, text, start, end): (String, u32, Option<String>, i64, i64) = self
            .connection
            .query_row(
                "SELECT corrections.revision_id, corrections.sequence, corrections.text,
                        segments.start_ns, segments.end_ns
                 FROM transcript_corrections AS corrections
                 JOIN transcript_segments AS segments
                   ON segments.revision_id = corrections.revision_id
                  AND segments.sequence = corrections.sequence
                 WHERE corrections.session_id = ?1 AND corrections.id = ?2",
                params![session.0, correction_id],
                |row| {
                    Ok((
                        row.get(0)?,
                        row.get(1)?,
                        row.get(2)?,
                        row.get(3)?,
                        row.get(4)?,
                    ))
                },
            )
            .optional()?
            .ok_or(StoreError::InvalidRequest("no such correction"))?;
        reference(
            session,
            EvidenceKind::HumanCorrection,
            correction_id,
            Some(revision),
            (start, end),
            Some(sequence.to_string()),
            text_digest(text.as_deref().unwrap_or("")),
        )
    }

    /// Cites an accepted context event, or one of its text blocks.
    pub fn cite_context_event(
        &self,
        session: &SessionId,
        event_id: &str,
        block: Option<usize>,
    ) -> Result<EvidenceRef, StoreError> {
        let (start, end, digest, event): (i64, i64, String, String) = self
            .connection
            .query_row(
                "SELECT start_ns, end_ns, event_digest, event_json FROM context_events
                 WHERE session_id = ?1 AND id = ?2",
                params![session.0, event_id],
                |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?, row.get(3)?)),
            )
            .optional()?
            .ok_or(StoreError::InvalidRequest("no such context event"))?;
        let (sub_item, content_digest) = match block {
            None => (None, digest),
            Some(index) => {
                let event: Value = serde_json::from_str(&event)?;
                let text = event["blocks"][index]["text"]
                    .as_str()
                    .ok_or(StoreError::InvalidRequest("no such context block"))?;
                (Some(format!("block-{index}")), text_digest(text))
            }
        };
        reference(
            session,
            EvidenceKind::ContextEvent,
            event_id,
            None,
            (start, end),
            sub_item,
            content_digest,
        )
    }

    /// Cites a range of one sealed track; it must lie inside one segment.
    pub fn cite_audio_range(
        &self,
        session: &SessionId,
        track_id: &str,
        start_ns: i64,
        end_ns: i64,
    ) -> Result<EvidenceRef, StoreError> {
        let entry = self
            .session_inventory(session)?
            .media
            .into_iter()
            .find(|entry| {
                entry.track_id == track_id
                    && entry.start_nanoseconds <= start_ns
                    && end_ns <= entry_end(entry)
            })
            .ok_or(StoreError::InvalidRequest(
                "the range is not inside one sealed segment",
            ))?;
        reference(
            session,
            EvidenceKind::AudioRange,
            track_id,
            None,
            (start_ns, end_ns),
            Some(entry.segment_id.clone()),
            entry.digest_sha256,
        )
    }

    /// Re-reads the cited evidence. `Err` only for storage failures or a
    /// reference that is not a valid v1 shape.
    pub fn resolve_evidence(
        &self,
        reference: &EvidenceRef,
    ) -> Result<ResolvedEvidence, StoreError> {
        match reference.validate() {
            Ok(()) => {}
            Err(EvidenceRefError::UnsupportedVersion) => {
                return Ok(ResolvedEvidence::state(ResolutionState::UnsupportedVersion));
            }
            Err(_) => return Err(StoreError::InvalidRequest("malformed evidence reference")),
        }
        let lifecycle: Option<String> = self
            .connection
            .query_row(
                "SELECT lifecycle FROM sessions WHERE id = ?1",
                [&reference.session_id],
                |row| row.get(0),
            )
            .optional()?;
        match lifecycle.as_deref() {
            None => return Ok(ResolvedEvidence::state(ResolutionState::Missing)),
            Some("deleted") => return Ok(ResolvedEvidence::state(ResolutionState::Deleted)),
            Some(_) => {}
        }
        let session = SessionId(reference.session_id.clone());
        match reference.kind {
            EvidenceKind::TranscriptSegment => self.resolve_transcript(&session, reference),
            EvidenceKind::HumanCorrection => self.resolve_correction(&session, reference),
            EvidenceKind::Marker => {
                let found: Option<(i64, Option<String>)> = self
                    .connection
                    .query_row(
                        "SELECT session_nanoseconds, label FROM markers
                         WHERE session_id = ?1 AND id = ?2",
                        params![session.0, reference.record_id],
                        |row| Ok((row.get(0)?, row.get(1)?)),
                    )
                    .optional()?;
                Ok(match found {
                    None => ResolvedEvidence::state(ResolutionState::Missing),
                    Some((at, label)) => {
                        let label = label.unwrap_or_default();
                        if at.max(0) != reference.start_ns
                            || text_digest(&label) != reference.content_digest
                        {
                            ResolvedEvidence::state(ResolutionState::IntegrityMismatch)
                        } else {
                            ResolvedEvidence::available(Some(label))
                        }
                    }
                })
            }
            EvidenceKind::ContextEvent => self.resolve_context(&session, reference),
            EvidenceKind::AudioRange => self.resolve_audio(&session, reference),
        }
    }

    fn resolve_transcript(
        &self,
        session: &SessionId,
        reference: &EvidenceRef,
    ) -> Result<ResolvedEvidence, StoreError> {
        let revision = reference.revision_id.as_deref().unwrap_or_default();
        let sequence: u32 = reference
            .sub_item
            .as_deref()
            .and_then(|value| value.parse().ok())
            .ok_or(StoreError::InvalidRequest(
                "a transcript sub-item is a sequence",
            ))?;
        let found: Option<(String, i64, i64, String)> = self
            .connection
            .query_row(
                "SELECT revisions.track_id, segments.start_ns, segments.end_ns, segments.text
                 FROM transcript_segments AS segments
                 JOIN transcript_revisions AS revisions ON revisions.id = segments.revision_id
                 WHERE revisions.session_id = ?1 AND segments.revision_id = ?2
                   AND segments.sequence = ?3",
                params![session.0, revision, sequence],
                |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?, row.get(3)?)),
            )
            .optional()?;
        let Some((track, start, end, text)) = found else {
            return Ok(ResolvedEvidence::state(ResolutionState::Missing));
        };
        if revision != reference.record_id
            || start != reference.start_ns
            || end.max(start + 1) != reference.end_ns
            || text_digest(&text) != reference.content_digest
        {
            return Ok(ResolvedEvidence::state(ResolutionState::IntegrityMismatch));
        }
        let selected: Option<String> = self
            .connection
            .query_row(
                "SELECT revision_id FROM transcript_selections WHERE session_id = ?1 AND track_id = ?2",
                params![session.0, track],
                |row| row.get(0),
            )
            .optional()?;
        Ok(if selected.as_deref() == Some(revision) {
            ResolvedEvidence::available(Some(text))
        } else {
            // The cited revision is preserved; a newer one is selected.
            ResolvedEvidence {
                state: ResolutionState::Superseded,
                text: Some(text),
                current_revision_id: selected,
            }
        })
    }

    fn resolve_correction(
        &self,
        session: &SessionId,
        reference: &EvidenceRef,
    ) -> Result<ResolvedEvidence, StoreError> {
        let found: Option<(String, u32, Option<String>, i64)> = self
            .connection
            .query_row(
                "SELECT revision_id, sequence, text, rowid FROM transcript_corrections
                 WHERE session_id = ?1 AND id = ?2",
                params![session.0, reference.record_id],
                |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?, row.get(3)?)),
            )
            .optional()?;
        let Some((revision, sequence, text, rowid)) = found else {
            return Ok(ResolvedEvidence::state(ResolutionState::Missing));
        };
        let text = text.unwrap_or_default();
        if reference.revision_id.as_deref() != Some(revision.as_str())
            || reference.sub_item.as_deref() != Some(sequence.to_string().as_str())
            || text_digest(&text) != reference.content_digest
        {
            return Ok(ResolvedEvidence::state(ResolutionState::IntegrityMismatch));
        }
        let newer: bool = self.connection.query_row(
            "SELECT EXISTS(SELECT 1 FROM transcript_corrections
             WHERE revision_id = ?1 AND sequence = ?2 AND rowid > ?3)",
            params![revision, sequence, rowid],
            |row| row.get(0),
        )?;
        Ok(ResolvedEvidence {
            state: if newer {
                ResolutionState::Superseded
            } else {
                ResolutionState::Available
            },
            text: Some(text),
            current_revision_id: None,
        })
    }

    fn resolve_context(
        &self,
        session: &SessionId,
        reference: &EvidenceRef,
    ) -> Result<ResolvedEvidence, StoreError> {
        let found: Option<(i64, i64, String, String)> = self
            .connection
            .query_row(
                "SELECT start_ns, end_ns, event_digest, event_json FROM context_events
                 WHERE session_id = ?1 AND id = ?2",
                params![session.0, reference.record_id],
                |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?, row.get(3)?)),
            )
            .optional()?;
        let Some((start, end, digest, event)) = found else {
            return Ok(ResolvedEvidence::state(ResolutionState::Missing));
        };
        let event: Value = serde_json::from_str(&event)?;
        let mut body = event.clone();
        if let Some(object) = body.as_object_mut() {
            object.remove("event_digest");
        }
        let intact = digest_json(&body)? == digest
            && start == reference.start_ns
            && end.max(start + 1) == reference.end_ns;
        if !intact {
            return Ok(ResolvedEvidence::state(ResolutionState::IntegrityMismatch));
        }
        let blocks = event["blocks"].as_array().cloned().unwrap_or_default();
        let texts: Vec<&str> = blocks
            .iter()
            .filter_map(|block| block["text"].as_str())
            .collect();
        match reference.sub_item.as_deref() {
            None if digest == reference.content_digest => {
                Ok(ResolvedEvidence::available(Some(texts.join("\n"))))
            }
            Some(item) => {
                let text = item
                    .strip_prefix("block-")
                    .and_then(|index| index.parse::<usize>().ok())
                    .and_then(|index| texts.get(index).copied());
                Ok(match text {
                    None => ResolvedEvidence::state(ResolutionState::Missing),
                    Some(text) if text_digest(text) == reference.content_digest => {
                        ResolvedEvidence::available(Some(text.to_owned()))
                    }
                    Some(_) => ResolvedEvidence::state(ResolutionState::IntegrityMismatch),
                })
            }
            None => Ok(ResolvedEvidence::state(ResolutionState::IntegrityMismatch)),
        }
    }

    fn resolve_audio(
        &self,
        session: &SessionId,
        reference: &EvidenceRef,
    ) -> Result<ResolvedEvidence, StoreError> {
        let Some(segment) = reference.sub_item.as_deref() else {
            return Ok(ResolvedEvidence::state(ResolutionState::Missing));
        };
        let Some(entry) = self
            .session_inventory(session)?
            .media
            .into_iter()
            .find(|entry| entry.segment_id == segment && entry.track_id == reference.record_id)
        else {
            return Ok(ResolvedEvidence::state(ResolutionState::Missing));
        };
        if entry.digest_sha256 != reference.content_digest
            || reference.start_ns < entry.start_nanoseconds
            || reference.end_ns > entry_end(&entry)
        {
            return Ok(ResolvedEvidence::state(ResolutionState::IntegrityMismatch));
        }
        Ok(match self.open_verified_media(session, &entry) {
            Ok(_) => ResolvedEvidence::available(None),
            Err(StoreError::IntegrityMismatch(_)) => {
                ResolvedEvidence::state(ResolutionState::IntegrityMismatch)
            }
            Err(StoreError::Io(error)) if error.kind() == std::io::ErrorKind::NotFound => {
                ResolvedEvidence::state(ResolutionState::Missing)
            }
            Err(error) => return Err(error),
        })
    }
}

fn entry_end(entry: &SessionMediaEntry) -> i64 {
    entry.start_nanoseconds
        + i64::try_from(u128::from(entry.sample_count) * 1_000_000_000 / 48_000).unwrap_or(i64::MAX)
}

#[cfg(test)]
#[path = "evidence_resolution_tests.rs"]
mod tests;
