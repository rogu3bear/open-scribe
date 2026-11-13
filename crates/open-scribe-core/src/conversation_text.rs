//! Conversation text for pasting into another app (ADR 0010 transcript
//! formats). One paragraph per speaker turn, in timeline order, with human
//! corrections and speaker names applied. Provenance, model identity, and
//! evidence references stay in the file exports; this text is a reading copy.

use crate::export::{TranscriptExport, TranscriptExportError};
use open_scribe_store::{SessionStore, TranscriptDocumentSegment};
use open_scribe_types::SessionId;
use std::fmt::Write as _;

/// The body and the facts a caller needs to head it in the reader's locale.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ConversationText {
    pub title: String,
    pub created_at_ms: i64,
    pub duration_nanoseconds: i64,
    /// Speaker names in order of first appearance.
    pub participants: Vec<String>,
    /// True when any included passage is provisional Draft text.
    pub has_draft: bool,
    pub turn_count: u32,
    pub body: String,
}

/// One speaker's consecutive passages.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ConversationTurn {
    pub speaker: String,
    pub start_nanoseconds: i64,
    pub text: String,
}

impl TranscriptExport {
    /// Groups consecutive passages by the same speaker into turns.
    #[must_use]
    pub fn conversation_turns(&self) -> Vec<ConversationTurn> {
        let mut segments: Vec<&TranscriptDocumentSegment> = self
            .segments
            .iter()
            .filter(|segment| !segment.effective_text.trim().is_empty())
            .collect();
        segments.sort_by(|left, right| {
            left.start_nanoseconds
                .cmp(&right.start_nanoseconds)
                .then_with(|| left.track_id.cmp(&right.track_id))
                .then_with(|| left.sequence.cmp(&right.sequence))
        });
        let mut turns: Vec<ConversationTurn> = Vec::new();
        for segment in segments {
            let text = collapse_whitespace(&segment.effective_text);
            match turns.last_mut() {
                Some(turn) if turn.speaker == segment.speaker_label => {
                    turn.text.push(' ');
                    turn.text.push_str(&text);
                }
                _ => turns.push(ConversationTurn {
                    speaker: segment.speaker_label.clone(),
                    start_nanoseconds: segment.start_nanoseconds,
                    text,
                }),
            }
        }
        turns
    }

    /// Renders the reading copy. Timestamps mark the start of each turn.
    #[must_use]
    pub fn conversation_text(&self, timestamps: bool) -> ConversationText {
        let turns = self.conversation_turns();
        let mut participants: Vec<String> = Vec::new();
        for turn in &turns {
            if !participants.contains(&turn.speaker) {
                participants.push(turn.speaker.clone());
            }
        }
        let mut body = String::new();
        for (index, turn) in turns.iter().enumerate() {
            if index > 0 {
                body.push_str("\n\n");
            }
            if timestamps {
                let _ = write!(
                    body,
                    "{} [{}]: {}",
                    turn.speaker,
                    compact_clock(turn.start_nanoseconds),
                    turn.text
                );
            } else {
                let _ = write!(body, "{}: {}", turn.speaker, turn.text);
            }
        }
        ConversationText {
            title: self.context.title.clone(),
            created_at_ms: self.context.created_at_ms,
            duration_nanoseconds: self.context.duration_nanoseconds,
            participants,
            has_draft: self
                .segments
                .iter()
                .any(|segment| segment.finality == "draft"),
            turn_count: u32::try_from(turns.len()).unwrap_or(u32::MAX),
            body,
        }
    }
}

/// Reads the selected document once and renders its reading copy.
pub fn conversation_text(
    store: &SessionStore,
    session: &SessionId,
    timestamps: bool,
) -> Result<ConversationText, TranscriptExportError> {
    let export = TranscriptExport::collect(store, session, 0)?;
    Ok(export.conversation_text(timestamps))
}

fn collapse_whitespace(text: &str) -> String {
    text.split_whitespace().collect::<Vec<_>>().join(" ")
}

/// `m:ss` under an hour, `h:mm:ss` from an hour.
fn compact_clock(nanoseconds: i64) -> String {
    let seconds = nanoseconds.max(0) / 1_000_000_000;
    let (hours, minutes, remainder) = (seconds / 3600, seconds / 60 % 60, seconds % 60);
    if hours > 0 {
        format!("{hours}:{minutes:02}:{remainder:02}")
    } else {
        format!("{minutes}:{remainder:02}")
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use open_scribe_store::{SpeakerLabelOrigin, TranscriptExportContext};

    fn segment(
        track: &str,
        sequence: u32,
        start_seconds: i64,
        speaker: &str,
        text: &str,
        finality: &str,
    ) -> TranscriptDocumentSegment {
        TranscriptDocumentSegment {
            revision_id: format!("rev-{track}"),
            track_id: track.into(),
            finality: finality.into(),
            sequence,
            start_nanoseconds: start_seconds * 1_000_000_000,
            end_nanoseconds: (start_seconds + 2) * 1_000_000_000,
            verbatim_text: text.into(),
            verbatim_sha256: String::new(),
            effective_text: text.into(),
            corrected: false,
            speaker_label: speaker.into(),
            speaker_origin: SpeakerLabelOrigin::SourceDefault,
            named_speaker_id: None,
        }
    }

    fn export(segments: Vec<TranscriptDocumentSegment>) -> TranscriptExport {
        TranscriptExport {
            context: TranscriptExportContext {
                session_id: SessionId("session".into()),
                title: "Mobile beta launch".into(),
                created_at_ms: 1_794_500_000_000,
                transcribable_tracks: vec!["mic".into(), "system".into()],
                track_input_digests: Vec::new(),
                selected: Vec::new(),
                failed_tracks: Vec::new(),
                duration_nanoseconds: 69_000_000_000,
            },
            speakers: Vec::new(),
            segments,
            exported_at_ms: 0,
        }
    }

    #[test]
    fn consecutive_passages_by_one_speaker_form_one_turn_across_tracks() {
        let text = export(vec![
            segment("system", 1, 5, "Dana", "He's running late.", "final"),
            segment(
                "mic",
                1,
                0,
                "You",
                "Hey  Dana,\nthanks for jumping on.",
                "final",
            ),
            segment("system", 2, 7, "Dana", "Start without him.", "final"),
            segment("mic", 2, 13, "You", "Right.", "draft"),
        ])
        .conversation_text(true);
        assert_eq!(
            text.body,
            "You [0:00]: Hey Dana, thanks for jumping on.\n\n\
             Dana [0:05]: He's running late. Start without him.\n\n\
             You [0:13]: Right."
        );
        assert_eq!(text.participants, vec!["You", "Dana"]);
        assert_eq!(text.turn_count, 3);
        assert!(text.has_draft);
        assert_eq!(text.title, "Mobile beta launch");
    }

    #[test]
    fn timestamps_can_be_omitted_and_blank_passages_are_skipped() {
        let text = export(vec![
            segment("mic", 1, 3_725, "You", "Late in the call.", "final"),
            segment("mic", 2, 3_727, "You", "   ", "final"),
        ]);
        assert_eq!(text.conversation_text(false).body, "You: Late in the call.");
        assert_eq!(
            text.conversation_text(true).body,
            "You [1:02:05]: Late in the call."
        );
        assert!(!text.conversation_text(false).has_draft);
    }

    #[test]
    fn an_empty_document_has_no_turns() {
        let text = export(Vec::new()).conversation_text(true);
        assert!(text.body.is_empty());
        assert_eq!(text.turn_count, 0);
        assert!(text.participants.is_empty());
    }
}
