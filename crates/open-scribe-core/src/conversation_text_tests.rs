//! Copy against a real store: the reading copy follows the readable
//! document, so Draft text copies before any Final transcript exists, while
//! `transcript.v1` still cites Final text only.

use std::fs::File;
use std::io::Write;
use std::path::Path;

use open_scribe_store::{
    ImportMediaRequest, PlannedTranscriptChunk, RevisionSegmentInput, SessionStore,
    TranscriptionRunIdentity,
};
use open_scribe_types::SessionId;
use tempfile::TempDir;

use crate::{TranscriptAvailability, TranscriptExport, TranscriptLibrary};

const SECOND: i64 = 1_000_000_000;

fn write_caf(path: &Path, frames: u64) {
    let mut file = File::create(path).unwrap();
    file.write_all(b"caff\0\x01\0\0").unwrap();
    file.write_all(b"desc").unwrap();
    file.write_all(&32_i64.to_be_bytes()).unwrap();
    file.write_all(&48_000_f64.to_bits().to_be_bytes()).unwrap();
    file.write_all(b"lpcm").unwrap();
    for value in [2_u32, 2, 1, 1, 16] {
        file.write_all(&value.to_be_bytes()).unwrap();
    }
    file.write_all(b"data").unwrap();
    file.write_all(&(-1_i64).to_be_bytes()).unwrap();
    file.write_all(&0_u32.to_be_bytes()).unwrap();
    let bytes: Vec<u8> = (0..frames)
        .flat_map(|frame| (((frame % 997) as i16 - 498) * 31).to_le_bytes())
        .collect();
    file.write_all(&bytes).unwrap();
    file.sync_all().unwrap();
}

fn hypothesis(text: &str) -> String {
    serde_json::json!({
        "language": "en",
        "segments": [{ "start_ms": 100, "end_ms": 900, "text": text }]
    })
    .to_string()
}

/// Three seconds of imported audio, saved for review, with no transcript.
fn imported(temp: &TempDir) -> (SessionStore, SessionId, TranscriptionRunIdentity) {
    let source = temp.path().join("source.caf");
    write_caf(&source, 144_000);
    let mut store = SessionStore::open(temp.path().join("Open Scribe")).unwrap();
    let session = store
        .import_recoverable_caf(ImportMediaRequest {
            title: "Budget review".into(),
            source_path: source,
        })
        .unwrap()
        .session_id;
    let track = store.transcription_tracks(&session).unwrap().remove(0);
    let input = store.transcription_input(&session, &track).unwrap();
    let identity = TranscriptionRunIdentity {
        session_id: session.clone(),
        track_id: track,
        input_digest: input.input_digest,
        engine: "fixture-engine".into(),
        engine_version: "1".into(),
        model_id: "fixture-model".into(),
        model_sha256: "a".repeat(64),
        options_digest: "options-a".into(),
        reconciliation_version: "overlap-midpoint-v1".into(),
    };
    (store, session, identity)
}

/// Commits one revision whose single chunk covers `start..end` and holds
/// `words`, Draft or Final.
fn commit(
    store: &mut SessionStore,
    identity: &TranscriptionRunIdentity,
    start: i64,
    end: i64,
    words: &str,
    draft: bool,
) {
    let identity = TranscriptionRunIdentity {
        options_digest: format!("options-{start}-{draft}"),
        ..identity.clone()
    };
    let run = store
        .begin_transcription_run(
            &identity,
            &[PlannedTranscriptChunk {
                span_index: 0,
                start_nanoseconds: start,
                end_nanoseconds: end,
            }],
        )
        .unwrap();
    store
        .complete_transcript_chunk(&run.run_id, 0, "en", &hypothesis(words))
        .unwrap();
    let segments = [RevisionSegmentInput {
        start_nanoseconds: start,
        end_nanoseconds: end,
        text: words.into(),
        mean_probability: Some(0.8),
        no_speech_probability: None,
        chunk_identity: run.chunks[0].identity.clone(),
    }];
    if draft {
        store
            .commit_draft_transcript_revision(&run.run_id, &segments, "{}", "[]")
            .unwrap();
    } else {
        store
            .commit_transcript_revision(&run.run_id, &segments, "{}", "[]")
            .unwrap();
    }
}

#[test]
fn a_final_only_conversation_copies_its_final_text() {
    let temp = TempDir::new().unwrap();
    let (mut store, session, identity) = imported(&temp);
    commit(&mut store, &identity, 0, SECOND, "alpha opens", false);
    drop(store);

    let library = TranscriptLibrary::open(temp.path().join("Open Scribe")).unwrap();
    let text = library.conversation_text(&session, true).unwrap();
    assert_eq!(text.title, "Budget review");
    assert_eq!(text.body, "Speaker [0:00]: alpha opens");
    assert!(!text.has_draft);
    assert_eq!(text.turn_count, 1);
    assert_eq!(text.participants, ["Speaker"]);
    assert_eq!(text.duration_nanoseconds, 3 * SECOND);
    assert!(!text.turns[0].draft);
}

#[test]
fn a_draft_only_conversation_copies_its_draft_text_and_says_so() {
    let temp = TempDir::new().unwrap();
    let (mut store, session, identity) = imported(&temp);
    commit(&mut store, &identity, 0, SECOND, "provisional cedar", true);
    let exported = TranscriptExport::collect(&store, &session, 0).unwrap();
    assert!(
        exported.segments.is_empty(),
        "transcript.v1 never cites Draft text"
    );
    drop(store);

    let library = TranscriptLibrary::open(temp.path().join("Open Scribe")).unwrap();
    assert_eq!(
        library.availability(&session).unwrap(),
        TranscriptAvailability::Draft
    );
    let text = library.conversation_text(&session, false).unwrap();
    assert_eq!(text.body, "Speaker: provisional cedar");
    assert!(text.has_draft);
    assert_eq!(text.turn_count, 1);
    assert!(text.turns[0].draft);
    assert_eq!(text.turns[0].text, "provisional cedar");
    let readable = library.document(&session).unwrap();
    assert!(readable.has_draft());
    assert_eq!(readable.segments.len(), 1);
}

#[test]
fn a_mixed_conversation_copies_final_and_uncovered_draft_text_in_timeline_order() {
    let temp = TempDir::new().unwrap();
    let (mut store, session, identity) = imported(&temp);
    commit(&mut store, &identity, 0, SECOND, "alpha opens", false);
    commit(
        &mut store,
        &identity,
        2 * SECOND,
        3 * SECOND,
        "later cedar",
        true,
    );
    drop(store);

    let library = TranscriptLibrary::open(temp.path().join("Open Scribe")).unwrap();
    let text = library.conversation_text(&session, true).unwrap();
    assert_eq!(text.body, "Speaker [0:00]: alpha opens later cedar");
    assert!(text.has_draft);
    assert_eq!(text.turns.len(), 1);
    assert!(text.turns[0].draft);
    let document = library.document(&session).unwrap();
    assert_eq!(
        document
            .segments
            .iter()
            .map(|segment| (segment.finality.as_str(), segment.effective_text.as_str()))
            .collect::<Vec<_>>(),
        [("final", "alpha opens"), ("draft", "later cedar")]
    );
    let store = SessionStore::open(temp.path().join("Open Scribe")).unwrap();
    let exported = TranscriptExport::collect(&store, &session, 0).unwrap();
    assert_eq!(
        exported
            .segments
            .iter()
            .map(|segment| segment.effective_text.as_str())
            .collect::<Vec<_>>(),
        ["alpha opens"]
    );
}
