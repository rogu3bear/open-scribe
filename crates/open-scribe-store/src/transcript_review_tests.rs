use std::io::Read;

use super::*;
use crate::transcripts::tests::{
    complete_all, identity, imported_fixture, plan, sample, write_caf,
};
use crate::{ImportMediaRequest, TranscriptionRunIdentity};

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

fn ranges(hits: &[TranscriptSearchHit]) -> Vec<(String, String, String, u32, i64, i64, String)> {
    let mut found = hits
        .iter()
        .map(|hit| {
            (
                hit.session_id.clone(),
                hit.session_title.clone(),
                hit.revision_id.clone(),
                hit.sequence,
                hit.start_nanoseconds,
                hit.end_nanoseconds,
                hit.effective_text.clone(),
            )
        })
        .collect::<Vec<_>>();
    found.sort();
    found
}

fn range_of(
    session: &SessionId,
    title: &str,
    segment: &TranscriptDocumentSegment,
) -> (String, String, String, u32, i64, i64, String) {
    (
        session.0.clone(),
        title.to_owned(),
        segment.revision_id.clone(),
        segment.sequence,
        segment.start_nanoseconds,
        segment.end_nanoseconds,
        segment.effective_text.clone(),
    )
}

/// Opens the leased local file for one saved conversation and reports its
/// bytes, digest, and audio end. The lease is the playback descriptor.
fn opened_audio(store: &SessionStore, session: &SessionId) -> (Vec<u8>, String, i64) {
    let lease = store.lease_imported_playback(session).unwrap();
    let mut bytes = Vec::new();
    lease.file().read_to_end(&mut bytes).unwrap();
    assert_eq!(bytes.len() as u64, lease.byte_length());
    let tracks = store.transcription_tracks(session).unwrap();
    let input = store.transcription_input(session, &tracks[0]).unwrap();
    assert_eq!(input.spans.len(), 1);
    let span = &input.spans[0];
    let end = span.start_nanoseconds
        + i64::try_from(span.frames).unwrap() * 1_000_000_000
            / i64::from(crate::MEDIA_SAMPLE_RATE_HZ);
    (bytes, lease.digest_sha256().to_owned(), end)
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
            label: "Speaker".into(),
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

    assert_eq!(default_speaker_label("microphone"), "You");
    assert_eq!(default_speaker_label("application_audio"), "Others");
    assert_eq!(default_speaker_label("system_audio"), "Others");
    assert_eq!(default_speaker_label("imported_audio"), "Speaker");
}

#[test]
fn speaker_label_history_keeps_each_rename_and_the_source_default() {
    let (mut fixture, _) = transcribed(["alpha", "bravo"]);
    let (session, track) = (fixture.session.clone(), fixture.track.clone());
    let before = fixture.store.speaker_label_history(&session).unwrap();
    assert_eq!(before.len(), 1);
    assert_eq!(before[0].track_id, track);
    assert_eq!(before[0].source_kind, "imported_audio");
    assert_eq!(before[0].source_default_label, "Speaker");
    assert!(before[0].revisions.is_empty());

    fixture
        .store
        .rename_speaker(&session, &track, Some(" Dana "))
        .unwrap();
    let named = fixture.store.speaker_label_history(&session).unwrap();
    assert_eq!(named[0].source_default_label, "Speaker");
    assert_eq!(named[0].revisions.len(), 1);
    assert_eq!(named[0].revisions[0].label, "Dana");
    assert_eq!(named[0].revisions[0].origin, SpeakerLabelOrigin::Human);
    assert!(named[0].revisions[0].created_at_ms > 0);

    fixture
        .store
        .rename_speaker(&session, &track, None)
        .unwrap();
    fixture
        .store
        .rename_speaker(&session, &track, Some("Mina"))
        .unwrap();
    fixture
        .store
        .rename_speaker(&session, &track, None)
        .unwrap();

    let history = fixture.store.speaker_label_history(&session).unwrap();
    assert_eq!(
        history[0]
            .revisions
            .iter()
            .map(|revision| (revision.label.as_str(), revision.origin))
            .collect::<Vec<_>>(),
        [
            ("Dana", SpeakerLabelOrigin::Human),
            ("Speaker", SpeakerLabelOrigin::SourceDefault),
            ("Mina", SpeakerLabelOrigin::Human),
            ("Speaker", SpeakerLabelOrigin::SourceDefault),
        ]
    );
    assert!(
        history[0]
            .revisions
            .windows(2)
            .all(|pair| pair[0].created_at_ms <= pair[1].created_at_ms)
    );
    assert_eq!(
        fixture.store.session_speakers(&session).unwrap()[0].label,
        "Speaker"
    );
    assert_eq!(
        fixture.store.session_speakers(&session).unwrap()[0].origin,
        SpeakerLabelOrigin::SourceDefault
    );
    let document = fixture.store.transcript_document(&session).unwrap();
    assert_eq!(
        document
            .iter()
            .map(|segment| segment.verbatim_text.as_str())
            .collect::<Vec<_>>(),
        ["alpha", "bravo"]
    );
    let stored: i64 = fixture
        .store
        .connection
        .query_row("SELECT COUNT(*) FROM speaker_adjudications", [], |row| {
            row.get(0)
        })
        .unwrap();
    assert_eq!(stored, 4);

    let reopened = SessionStore::open(&fixture.root).unwrap();
    assert_eq!(reopened.speaker_label_history(&session).unwrap(), history);
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

#[test]
fn search_returns_matching_conversations_and_timestamped_ranges() {
    let mut library = imported_fixture(144_000);
    let interview_session = library.session.clone();
    let interview_title = "Transcript fixture";
    let interview_source = library.root.parent().unwrap().join("source.caf");
    let interview_source_bytes = std::fs::read(&interview_source).unwrap();
    let interview_media_bytes = std::fs::read(&library.media).unwrap();

    let budget_source = library.root.parent().unwrap().join("budget.caf");
    write_caf(&budget_source, 144_000, |frame| {
        sample(frame.wrapping_add(11))
    });
    let budget_source_bytes = std::fs::read(&budget_source).unwrap();
    let budget = library
        .store
        .import_recoverable_caf(ImportMediaRequest {
            title: "Budget".into(),
            source_path: budget_source.clone(),
        })
        .unwrap();
    let budget_session = budget.session_id.clone();
    let budget_title = "Budget";
    assert_ne!(budget_session, interview_session);
    assert!(budget.ready_for_review);
    assert!(!budget.repeated_source);
    let budget_media = library
        .root
        .join(crate::SESSIONS_DIRECTORY)
        .join(&budget_session.0)
        .join(&budget.relative_path);
    let budget_media_bytes = std::fs::read(&budget_media).unwrap();

    let interview_run = library
        .store
        .begin_transcription_run(&identity(&library, "options-interview"), &plan())
        .unwrap();
    let interview_revision = complete_all(
        &mut library,
        &interview_run,
        ["meadow draft", "closing note"],
    );
    library
        .store
        .correct_transcript_segment(
            &interview_session,
            &interview_revision,
            0,
            Some("approved meadow"),
        )
        .unwrap();

    let budget_tracks = library.store.transcription_tracks(&budget_session).unwrap();
    let budget_input = library
        .store
        .transcription_input(&budget_session, &budget_tracks[0])
        .unwrap();
    let budget_identity = TranscriptionRunIdentity {
        session_id: budget_session.clone(),
        track_id: budget_tracks[0].clone(),
        input_digest: budget_input.input_digest,
        ..identity(&library, "options-budget")
    };
    let budget_run = library
        .store
        .begin_transcription_run(&budget_identity, &plan())
        .unwrap();
    complete_all(&mut library, &budget_run, ["opening note", "meadow budget"]);

    let interview_document = library
        .store
        .transcript_document(&interview_session)
        .unwrap();
    let budget_document = library.store.transcript_document(&budget_session).unwrap();
    assert_eq!(interview_document[0].verbatim_text, "meadow draft");
    assert_eq!(interview_document[0].effective_text, "approved meadow");
    assert!(interview_document[0].corrected);
    assert!(!interview_document[1].corrected);
    assert!(budget_document.iter().all(|segment| !segment.corrected));
    assert_ne!(
        interview_document[0].start_nanoseconds,
        budget_document[1].start_nanoseconds
    );

    let mut meadow = vec![
        range_of(&interview_session, interview_title, &interview_document[0]),
        range_of(&budget_session, budget_title, &budget_document[1]),
    ];
    meadow.sort();
    assert_eq!(
        ranges(
            &library
                .store
                .search_transcripts("meadow", None, 10)
                .unwrap()
        ),
        meadow
    );
    assert!(
        library
            .store
            .search_transcripts("draft", None, 10)
            .unwrap()
            .is_empty()
    );
    assert_eq!(
        ranges(
            &library
                .store
                .search_transcripts("approved meadow", None, 10)
                .unwrap()
        ),
        vec![range_of(
            &interview_session,
            interview_title,
            &interview_document[0]
        )]
    );
    assert_eq!(
        ranges(
            &library
                .store
                .search_transcripts("opening note", None, 10)
                .unwrap()
        ),
        vec![range_of(&budget_session, budget_title, &budget_document[0])]
    );

    let (interview_audio, interview_digest, interview_end) =
        opened_audio(&library.store, &interview_session);
    let (budget_audio, budget_digest, budget_end) = opened_audio(&library.store, &budget_session);
    assert_eq!(interview_audio, interview_media_bytes);
    assert_eq!(budget_audio, budget_media_bytes);
    for hit in library
        .store
        .search_transcripts("meadow", None, 10)
        .unwrap()
    {
        let end = if hit.session_id == interview_session.0 {
            interview_end
        } else {
            budget_end
        };
        assert!(hit.start_nanoseconds >= 0);
        assert!(hit.end_nanoseconds > hit.start_nanoseconds);
        assert!(hit.end_nanoseconds <= end);
    }

    let reopened = SessionStore::open(&library.root).unwrap();
    assert_eq!(
        ranges(&reopened.search_transcripts("meadow", None, 10).unwrap()),
        meadow
    );
    let (again, digest, _) = opened_audio(&reopened, &interview_session);
    assert_eq!(again, interview_audio);
    assert_eq!(digest, interview_digest);
    let (again, digest, _) = opened_audio(&reopened, &budget_session);
    assert_eq!(again, budget_audio);
    assert_eq!(digest, budget_digest);
    assert_eq!(
        std::fs::read(&interview_source).unwrap(),
        interview_source_bytes
    );
    assert_eq!(std::fs::read(&budget_source).unwrap(), budget_source_bytes);

    let snapshot = library.store.runtime_library_snapshot().unwrap();
    assert!(snapshot.current_session.is_none());
    let mut saved = snapshot
        .saved_sessions
        .iter()
        .map(|session| (session.session_id.0.clone(), session.title.clone()))
        .collect::<Vec<_>>();
    saved.sort();
    let mut expected_saved = vec![
        (interview_session.0, interview_title.to_owned()),
        (budget_session.0, budget_title.to_owned()),
    ];
    expected_saved.sort();
    assert_eq!(saved, expected_saved);
    assert!(snapshot.saved_sessions.iter().all(|session| {
        session.lifecycle == "ready_for_review" && session.playable_media.is_some()
    }));
}
