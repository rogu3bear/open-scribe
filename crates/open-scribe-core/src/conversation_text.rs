//! Conversation text for pasting into another app (ADR 0010 transcript
//! formats). One paragraph per speaker turn, in timeline order, with human
//! corrections and speaker names applied. Provenance, model identity, and
//! evidence references stay in the file exports; this text is a reading copy.
//!
//! It reads the Readable document, so Draft text is included and flagged:
//! Copy works before a whisper model is installed (ADR 0019). A recording in
//! progress reads the same document, made of the Draft windows stored so far.

use crate::export::single_line;
use open_scribe_store::{
    DocumentScope, SessionStore, StoreError, TranscriptDocumentSegment, TranscriptFinality,
};
use open_scribe_types::SessionId;
use std::fmt::Write as _;

/// The body and the facts a caller needs to head it in the reader's locale.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ConversationText {
    /// The title a reader sees.
    pub title: String,
    pub created_at_ms: i64,
    /// Zero until the conversation is saved for review.
    pub duration_nanoseconds: i64,
    /// Speaker names in order of first appearance.
    pub participants: Vec<String>,
    /// True when any included passage is provisional Draft text.
    pub has_draft: bool,
    pub turn_count: u32,
    pub body: String,
    /// The turns the body renders, as data.
    pub turns: Vec<ConversationTurn>,
}

/// One speaker's consecutive passages.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ConversationTurn {
    pub speaker: String,
    pub start_nanoseconds: i64,
    pub text: String,
    /// True when any passage of the turn is Draft text.
    pub draft: bool,
}

/// Groups consecutive passages by the same speaker into turns. Passages
/// share a speaker when they show the same name for the same confirmed
/// person, as in the reader, so two people who share a name stay apart.
/// `segments` is in document order.
#[must_use]
pub fn conversation_turns(segments: &[TranscriptDocumentSegment]) -> Vec<ConversationTurn> {
    let mut turns: Vec<ConversationTurn> = Vec::new();
    let mut voice: Option<(&str, Option<&str>)> = None;
    for segment in segments
        .iter()
        .filter(|segment| !segment.effective_text.trim().is_empty())
    {
        let text = single_line(&segment.effective_text);
        let draft = segment.finality == TranscriptFinality::Draft;
        let this_voice = (
            segment.speaker_label.as_str(),
            segment.named_speaker_id.as_deref(),
        );
        match turns.last_mut() {
            Some(turn) if voice == Some(this_voice) => {
                turn.text.push(' ');
                turn.text.push_str(&text);
                turn.draft |= draft;
            }
            _ => turns.push(ConversationTurn {
                speaker: segment.speaker_label.clone(),
                start_nanoseconds: segment.start_nanoseconds,
                text,
                draft,
            }),
        }
        voice = Some(this_voice);
    }
    turns
}

/// Renders the reading copy of `segments`. Timestamps mark the start of
/// each turn.
#[must_use]
pub fn render_conversation_text(
    title: String,
    created_at_ms: i64,
    duration_nanoseconds: i64,
    segments: &[TranscriptDocumentSegment],
    timestamps: bool,
) -> ConversationText {
    let turns = conversation_turns(segments);
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
        title,
        created_at_ms,
        duration_nanoseconds,
        participants,
        has_draft: turns.iter().any(|turn| turn.draft),
        turn_count: u32::try_from(turns.len()).unwrap_or(u32::MAX),
        body,
        turns,
    }
}

/// Reads the readable document once and renders its reading copy.
pub fn conversation_text(
    store: &SessionStore,
    session: &SessionId,
    timestamps: bool,
) -> Result<ConversationText, StoreError> {
    let document = store.conversation_document(session, DocumentScope::Readable)?;
    Ok(render_conversation_text(
        document.title.display_title,
        document.created_at_ms,
        store.transcript_duration_nanoseconds(session)?,
        &document.segments,
        timestamps,
    ))
}

/// `m:ss` under an hour, `h:mm:ss` from an hour: the transcript's stamp,
/// shared with the native reader.
#[must_use]
pub fn compact_clock(nanoseconds: i64) -> String {
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
    use open_scribe_store::SpeakerLabelOrigin;

    fn segment(
        track: &str,
        sequence: u32,
        start_seconds: i64,
        speaker: &str,
        text: &str,
        finality: TranscriptFinality,
    ) -> TranscriptDocumentSegment {
        TranscriptDocumentSegment {
            revision_id: format!("rev-{track}"),
            track_id: track.into(),
            finality,
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

    fn render(segments: &[TranscriptDocumentSegment], timestamps: bool) -> ConversationText {
        render_conversation_text(
            "Mobile beta launch".into(),
            1_794_500_000_000,
            69_000_000_000,
            segments,
            timestamps,
        )
    }

    #[test]
    fn consecutive_passages_by_one_speaker_form_one_turn_across_tracks() {
        use TranscriptFinality::{Draft, Final};
        let text = render(
            &[
                segment(
                    "mic",
                    1,
                    0,
                    "You",
                    "Hey  Dana,\nthanks for jumping on.",
                    Final,
                ),
                segment("system", 1, 5, "Dana", "He's running late.", Final),
                segment("system", 2, 7, "Dana", "Start without him.", Final),
                segment("mic", 2, 13, "You", "Right.", Draft),
            ],
            true,
        );
        assert_eq!(
            text.body,
            "You [0:00]: Hey Dana, thanks for jumping on.\n\n\
             Dana [0:05]: He's running late. Start without him.\n\n\
             You [0:13]: Right."
        );
        assert_eq!(text.participants, vec!["You", "Dana"]);
        assert_eq!(text.turn_count, 3);
        assert!(text.has_draft);
        assert_eq!(
            text.turns.iter().map(|turn| turn.draft).collect::<Vec<_>>(),
            [false, false, true]
        );
        assert_eq!(text.title, "Mobile beta launch");
    }

    #[test]
    fn two_people_who_share_a_name_stay_separate_turns() {
        let mut first = segment("system", 1, 0, "Sam", "First.", TranscriptFinality::Final);
        first.named_speaker_id = Some("person-a".into());
        let mut second = segment("system", 2, 3, "Sam", "Second.", TranscriptFinality::Final);
        second.named_speaker_id = Some("person-b".into());
        let text = render(&[first, second], false);
        assert_eq!(text.body, "Sam: First.\n\nSam: Second.");
        assert_eq!(text.participants, vec!["Sam"]);
    }

    #[test]
    fn timestamps_can_be_omitted_and_blank_passages_are_skipped() {
        let segments = [
            segment(
                "mic",
                1,
                3_725,
                "You",
                "Late in the call.",
                TranscriptFinality::Final,
            ),
            segment("mic", 2, 3_727, "You", "   ", TranscriptFinality::Draft),
        ];
        assert_eq!(render(&segments, false).body, "You: Late in the call.");
        assert_eq!(
            render(&segments, true).body,
            "You [1:02:05]: Late in the call."
        );
        assert!(!render(&segments, false).has_draft);
    }

    #[test]
    fn an_empty_document_has_no_turns() {
        let text = render(&[], true);
        assert!(text.body.is_empty());
        assert_eq!(text.turn_count, 0);
        assert!(text.participants.is_empty());
        assert!(text.turns.is_empty());
    }

    #[test]
    fn the_stamp_is_minutes_under_an_hour_and_hours_from_one() {
        assert_eq!(compact_clock(0), "0:00");
        assert_eq!(compact_clock(65_400_000_000), "1:05");
        assert_eq!(compact_clock(3_725_000_000_000), "1:02:05");
        assert_eq!(compact_clock(-5), "0:00");
    }
}
