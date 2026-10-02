use super::*;
use crate::TranscriptionRunIdentity;
use crate::transcripts::tests::{complete_all, identity, imported_fixture, plan};

fn transcribed(words: [&str; 2]) -> (crate::transcripts::tests::Fixture, String) {
    let mut fixture = imported_fixture(144_000);
    let run = fixture
        .store
        .begin_transcription_run(&identity(&fixture, "options-a"), &plan())
        .unwrap();
    let revision = complete_all(&mut fixture, &run, words);
    (fixture, revision)
}

fn texts(hits: &[TranscriptSearchHit]) -> Vec<&str> {
    hits.iter().map(|hit| hit.effective_text.as_str()).collect()
}

#[test]
fn corrections_append_without_rewriting_verbatim_and_drive_search() {
    let (mut fixture, revision) = transcribed(["alpha", "bravo"]);
    let session = fixture.session.clone();
    let hits = fixture.store.search_transcripts("alpha", None, 10).unwrap();
    assert_eq!(texts(&hits), ["alpha"]);
    assert_eq!(hits[0].session_title, "Transcript fixture");
    assert_eq!(hits[0].revision_id, revision);
    assert_eq!(
        texts(&fixture.store.search_transcripts("alp", None, 10).unwrap()),
        ["alpha"]
    );

    fixture
        .store
        .correct_transcript_segment(&session, &revision, 0, Some("  Aleph  "))
        .unwrap();
    let document = fixture.store.transcript_document(&session).unwrap();
    assert_eq!(document.len(), 2);
    assert_eq!(document[0].verbatim_text, "alpha");
    assert_eq!(document[0].effective_text, "Aleph");
    assert!(document[0].corrected && !document[1].corrected);
    assert_eq!(
        fixture
            .store
            .transcript_revision_segments(&revision)
            .unwrap()[0]
            .text,
        "alpha"
    );
    assert!(
        fixture
            .store
            .search_transcripts("alpha", None, 10)
            .unwrap()
            .is_empty()
    );
    assert_eq!(
        texts(&fixture.store.search_transcripts("aleph", None, 10).unwrap()),
        ["Aleph"]
    );
    assert!(
        fixture
            .store
            .connection
            .execute("UPDATE transcript_corrections SET text = 'x'", [])
            .is_err()
    );

    fixture
        .store
        .correct_transcript_segment(&session, &revision, 0, None)
        .unwrap();
    let document = fixture.store.transcript_document(&session).unwrap();
    assert_eq!(document[0].effective_text, "alpha");
    assert!(!document[0].corrected);
    assert_eq!(
        texts(&fixture.store.search_transcripts("alpha", None, 10).unwrap()),
        ["alpha"]
    );
    let corrections: i64 = fixture
        .store
        .connection
        .query_row("SELECT COUNT(*) FROM transcript_corrections", [], |row| {
            row.get(0)
        })
        .unwrap();
    assert_eq!(corrections, 2);

    let other = SessionId("01a0ef0d-2600-76c4-8f7e-de8905518c51".into());
    let oversized = "x".repeat(MAX_CORRECTION_BYTES + 1);
    for (target, sequence, text) in [
        (&session, 0, Some("   ")),
        (&session, 0, Some(oversized.as_str())),
        (&session, 99, Some("valid")),
        (&other, 0, Some("valid")),
    ] {
        assert!(
            fixture
                .store
                .correct_transcript_segment(target, &revision, sequence, text)
                .is_err()
        );
    }
}

#[test]
fn search_quotes_user_syntax_and_follows_the_selected_revision() {
    let (mut fixture, first) = transcribed(["alpha", "bravo"]);
    for (query, expected) in [
        ("\"", 0),
        ("*", 0),
        ("", 0),
        ("alpha OR", 0),
        ("NEAR(alpha", 0),
        ("alpha\"", 1),
        ("-alpha", 1),
        ("ALPHA", 1),
    ] {
        assert_eq!(
            fixture
                .store
                .search_transcripts(query, None, 10)
                .unwrap()
                .len(),
            expected,
            "query {query:?}"
        );
    }
    assert_eq!(
        fixture
            .store
            .search_transcripts("a", None, 0)
            .unwrap()
            .len(),
        1
    );

    let replacement = TranscriptionRunIdentity {
        model_id: "replacement-model".into(),
        model_sha256: "b".repeat(64),
        ..identity(&fixture, "options-a")
    };
    let run = fixture
        .store
        .begin_transcription_run(&replacement, &plan())
        .unwrap();
    complete_all(&mut fixture, &run, ["charlie", "delta"]);
    assert!(
        fixture
            .store
            .search_transcripts("alpha", None, 10)
            .unwrap()
            .is_empty()
    );
    assert_eq!(
        texts(
            &fixture
                .store
                .search_transcripts("charlie", None, 10)
                .unwrap()
        ),
        ["charlie"]
    );

    let (session, track) = (fixture.session.clone(), fixture.track.clone());
    fixture
        .store
        .select_transcript_revision(&session, &track, &first)
        .unwrap();
    assert_eq!(
        texts(&fixture.store.search_transcripts("alpha", None, 10).unwrap()),
        ["alpha"]
    );
    assert!(
        fixture
            .store
            .search_transcripts("charlie", None, 10)
            .unwrap()
            .is_empty()
    );

    let elsewhere = SessionId("01a0ef0d-2600-76c4-8f7e-de8905518c51".into());
    assert!(
        fixture
            .store
            .search_transcripts("alpha", Some(&elsewhere), 10)
            .unwrap()
            .is_empty()
    );
    assert_eq!(
        fixture
            .store
            .search_transcripts("alpha", Some(&session), 10)
            .unwrap()
            .len(),
        1
    );
}

#[test]
fn speakers_default_from_source_topology_and_renames_are_append_only() {
    let (mut fixture, _) = transcribed(["alpha", "bravo"]);
    let (session, track) = (fixture.session.clone(), fixture.track.clone());
    let speakers = fixture.store.session_speakers(&session).unwrap();
    assert_eq!(
        speakers,
        [SessionSpeaker {
            track_id: track.clone(),
            source_kind: "imported_audio".into(),
            label: "Unknown speaker".into(),
            origin: SpeakerLabelOrigin::SourceDefault,
        }]
    );

    fixture
        .store
        .rename_speaker(&session, &track, Some(" Dana "))
        .unwrap();
    let document = fixture.store.transcript_document(&session).unwrap();
    assert!(
        document
            .iter()
            .all(|segment| segment.speaker_label == "Dana"
                && segment.speaker_origin == SpeakerLabelOrigin::Human)
    );

    fixture
        .store
        .rename_speaker(&session, &track, None)
        .unwrap();
    assert_eq!(
        fixture.store.session_speakers(&session).unwrap()[0].origin,
        SpeakerLabelOrigin::SourceDefault
    );
    let oversized = "x".repeat(MAX_SPEAKER_LABEL_BYTES + 1);
    for label in ["", "a\u{7}b", oversized.as_str()] {
        assert!(
            fixture
                .store
                .rename_speaker(&session, &track, Some(label))
                .is_err()
        );
    }
    assert!(
        fixture
            .store
            .rename_speaker(&session, "unknown-track", Some("Dana"))
            .is_err()
    );
    assert!(
        fixture
            .store
            .connection
            .execute("UPDATE speaker_adjudications SET label = 'x'", [])
            .is_err()
    );

    assert_eq!(default_speaker_label("microphone"), "Local user");
    assert_eq!(
        default_speaker_label("application_audio"),
        "Remote participants"
    );
    assert_eq!(default_speaker_label("system_audio"), "System audio");
    assert_eq!(default_speaker_label("imported_audio"), "Unknown speaker");
}

#[test]
fn migration_indexes_selections_committed_before_the_search_index() {
    let (fixture, _) = transcribed(["alpha", "bravo"]);
    fixture
        .store
        .connection
        .execute_batch(
            "DELETE FROM transcript_search;
             DELETE FROM schema_migrations WHERE version = 6;",
        )
        .unwrap();
    assert!(
        fixture
            .store
            .search_transcripts("alpha", None, 10)
            .unwrap()
            .is_empty()
    );

    let reopened = SessionStore::open(&fixture.root).unwrap();
    assert_eq!(
        texts(&reopened.search_transcripts("alpha", None, 10).unwrap()),
        ["alpha"]
    );
    assert_eq!(
        texts(&reopened.search_transcripts("bravo", None, 10).unwrap()),
        ["bravo"]
    );
    let rows: i64 = reopened
        .connection
        .query_row("SELECT COUNT(*) FROM transcript_search", [], |row| {
            row.get(0)
        })
        .unwrap();
    assert_eq!(rows, 2);
}

#[test]
fn fts_expressions_quote_every_term_and_prefix_only_the_last() {
    assert_eq!(fts_expression("alpha"), Some("\"alpha\"*".into()));
    assert_eq!(
        fts_expression("say \"hi\" now"),
        Some("\"say\" \"\"\"hi\"\"\" \"now\"*".into())
    );
    assert_eq!(fts_expression(" \" * - "), None);
    let many = "t ".repeat(MAX_QUERY_TERMS + 4);
    assert_eq!(
        fts_expression(&many).unwrap().matches('"').count(),
        MAX_QUERY_TERMS * 2
    );
}
