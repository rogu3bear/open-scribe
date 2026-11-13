use super::*;
use crate::SpeakerLabelOrigin;
use crate::transcripts::tests::{Fixture, complete_all, identity, imported_fixture, plan};

fn conversation() -> (Fixture, String) {
    let mut fixture = imported_fixture(144_000);
    let run = fixture
        .store
        .begin_transcription_run(&identity(&fixture, "speaker-review"), &plan())
        .unwrap();
    let revision = complete_all(&mut fixture, &run, ["First voice", "Second voice"]);
    (fixture, revision)
}

fn named(fixture: &mut Fixture, revision: &str, sequence: u32, name: &str) -> String {
    fixture
        .store
        .assign_transcript_speaker(
            &fixture.session,
            revision,
            sequence,
            &TranscriptSpeakerAssignment::New(name.into()),
        )
        .unwrap()
        .unwrap()
}

#[test]
fn one_imported_track_can_name_two_people_without_rewriting_text_or_audio() {
    let (mut fixture, revision) = conversation();
    let audio = std::fs::read(&fixture.media).unwrap();
    let before = fixture
        .store
        .transcript_revision_segments(&revision)
        .unwrap();
    let first = named(&mut fixture, &revision, 0, "  Dana  ");
    let partial = fixture.store.transcript_document(&fixture.session).unwrap();
    assert_eq!(partial[0].speaker_label, "Dana");
    assert_eq!(partial[0].named_speaker_id.as_deref(), Some(first.as_str()));
    assert_eq!(partial[1].speaker_label, "Speaker");
    assert!(partial[1].named_speaker_id.is_none());
    let second = named(&mut fixture, &revision, 1, "Morgan");
    let doc = fixture.store.transcript_document(&fixture.session).unwrap();
    assert_ne!(first, second);
    assert_eq!(doc[1].speaker_label, "Morgan");
    assert_eq!(
        fixture
            .store
            .transcript_revision_segments(&revision)
            .unwrap(),
        before
    );
    assert_eq!(
        fixture.store.session_speakers(&fixture.session).unwrap()[0].label,
        "Speaker"
    );
    let people = fixture
        .store
        .named_transcript_speakers(&fixture.session)
        .unwrap();
    assert_eq!(
        people
            .iter()
            .map(|p| (p.label.as_str(), p.selected_turns))
            .collect::<Vec<_>>(),
        [("Dana", 1), ("Morgan", 1)]
    );
    assert_eq!(std::fs::read(&fixture.media).unwrap(), audio);
}

#[test]
fn speaker_search_uses_confirmed_current_assignments_and_literal_names() {
    let (mut fixture, revision) = conversation();
    let id = named(&mut fixture, &revision, 0, "Élodie_100%");
    let hits = fixture
        .store
        .search_transcripts_by_speaker("ÉLO", None, 10)
        .unwrap();
    assert_eq!(hits.len(), 1);
    assert_eq!(hits[0].revision_id, revision);
    assert_eq!(hits[0].effective_text, "First voice");
    assert!(
        fixture
            .store
            .search_transcripts_by_speaker("%", None, 10)
            .unwrap()
            .is_empty()
    );
    assert!(
        fixture
            .store
            .search_transcripts_by_speaker("Élodie_100%", Some(&SessionId("other".into())), 10)
            .unwrap()
            .is_empty()
    );
    fixture
        .store
        .rename_transcript_speaker(&fixture.session, &id, "Dana")
        .unwrap();
    assert!(
        fixture
            .store
            .search_transcripts_by_speaker("Élo", None, 10)
            .unwrap()
            .is_empty()
    );
    assert_eq!(
        fixture
            .store
            .search_transcripts_by_speaker("Dana", None, 10)
            .unwrap()
            .len(),
        1
    );
    fixture
        .store
        .assign_transcript_speaker(
            &fixture.session,
            &revision,
            0,
            &TranscriptSpeakerAssignment::Source,
        )
        .unwrap();
    assert!(
        fixture
            .store
            .search_transcripts_by_speaker("Dana", None, 10)
            .unwrap()
            .is_empty()
    );
}

#[test]
fn a_speaker_review_during_background_work_preserves_the_selected_document() {
    let (mut fixture, reviewed) = conversation();
    let run = fixture
        .store
        .begin_transcription_run(&identity(&fixture, "background"), &plan())
        .unwrap();
    let id = named(&mut fixture, &reviewed, 0, "Dana");
    let replacement = complete_all(
        &mut fixture,
        &run,
        ["Unreviewed replacement", "Second replacement"],
    );
    assert_ne!(reviewed, replacement);
    let doc = fixture.store.transcript_document(&fixture.session).unwrap();
    assert_eq!(doc[0].revision_id, reviewed);
    assert_eq!(doc[0].named_speaker_id.as_deref(), Some(id.as_str()));
    assert_eq!(doc[0].effective_text, "First voice");
}

#[test]
fn reuse_rename_and_reset_are_append_only_and_idempotent() {
    let (mut fixture, revision) = conversation();
    let id = named(&mut fixture, &revision, 0, "Dana");
    let assignment = TranscriptSpeakerAssignment::Existing(id.clone());
    for _ in 0..2 {
        fixture
            .store
            .assign_transcript_speaker(&fixture.session, &revision, 1, &assignment)
            .unwrap();
    }
    let count: i64 = fixture
        .store
        .connection
        .query_row("SELECT COUNT(*) FROM transcript_turn_speakers", [], |r| {
            r.get(0)
        })
        .unwrap();
    assert_eq!(count, 2);
    fixture
        .store
        .rename_transcript_speaker(&fixture.session, &id, "D. Morgan")
        .unwrap();
    fixture
        .store
        .rename_transcript_speaker(&fixture.session, &id, "D. Morgan")
        .unwrap();
    assert!(
        fixture
            .store
            .transcript_document(&fixture.session)
            .unwrap()
            .iter()
            .all(|s| s.speaker_label == "D. Morgan")
    );
    fixture
        .store
        .assign_transcript_speaker(
            &fixture.session,
            &revision,
            0,
            &TranscriptSpeakerAssignment::Source,
        )
        .unwrap();
    let doc = fixture.store.transcript_document(&fixture.session).unwrap();
    assert_eq!(doc[0].speaker_label, "Speaker");
    assert_eq!(doc[1].speaker_label, "D. Morgan");
    for table in [
        "transcript_named_speakers",
        "transcript_speaker_names",
        "transcript_turn_speakers",
    ] {
        assert!(
            fixture
                .store
                .connection
                .execute(&format!("UPDATE {table} SET id = 'rewritten'"), [])
                .is_err()
        );
    }
    let names: i64 = fixture
        .store
        .connection
        .query_row("SELECT COUNT(*) FROM transcript_speaker_names", [], |r| {
            r.get(0)
        })
        .unwrap();
    assert_eq!(names, 2);
}

#[test]
fn invalid_or_foreign_turns_never_create_a_person() {
    let (mut fixture, revision) = conversation();
    for (session, rev, sequence, name) in [
        (fixture.session.clone(), revision.clone(), 9, "Dana"),
        (SessionId("foreign".into()), revision.clone(), 0, "Dana"),
        (fixture.session.clone(), "foreign".into(), 0, "Dana"),
        (fixture.session.clone(), revision.clone(), 0, " \n "),
        (fixture.session.clone(), revision.clone(), 0, "D\0ana"),
    ] {
        assert!(
            fixture
                .store
                .assign_transcript_speaker(
                    &session,
                    &rev,
                    sequence,
                    &TranscriptSpeakerAssignment::New(name.into())
                )
                .is_err()
        );
    }
    assert!(
        fixture
            .store
            .assign_transcript_speaker(
                &fixture.session,
                &revision,
                0,
                &TranscriptSpeakerAssignment::Existing("foreign".into())
            )
            .is_err()
    );
    assert!(
        fixture
            .store
            .named_transcript_speakers(&fixture.session)
            .unwrap()
            .is_empty()
    );
}

#[test]
fn assignments_survive_reopen_and_never_follow_a_replacement_by_ordinal() {
    let (mut fixture, revision) = conversation();
    let id = named(&mut fixture, &revision, 0, "Dana");
    let run = fixture
        .store
        .begin_transcription_run(&identity(&fixture, "replacement"), &plan())
        .unwrap();
    let replacement = complete_all(&mut fixture, &run, ["Changed order", "Changed content"]);
    assert_ne!(revision, replacement);
    assert!(
        fixture
            .store
            .transcript_document(&fixture.session)
            .unwrap()
            .iter()
            .all(|s| s.named_speaker_id.is_none())
    );
    assert!(
        fixture
            .store
            .assign_transcript_speaker(
                &fixture.session,
                &revision,
                1,
                &TranscriptSpeakerAssignment::Existing(id.clone())
            )
            .is_err()
    );
    fixture
        .store
        .select_transcript_revision(&fixture.session, &fixture.track, &revision)
        .unwrap();
    let root = fixture.store.managed_root().to_path_buf();
    let reopened = SessionStore::open(root).unwrap();
    let doc = reopened.transcript_document(&fixture.session).unwrap();
    assert_eq!(doc[0].named_speaker_id.as_deref(), Some(id.as_str()));
    assert_eq!(doc[0].speaker_label, "Dana");
    assert!(doc[1].named_speaker_id.is_none());
}

#[test]
fn identical_names_do_not_merge_people_and_deletion_inventory_includes_them() {
    let (mut fixture, revision) = conversation();
    let first = named(&mut fixture, &revision, 0, "Alex");
    let second = named(&mut fixture, &revision, 1, "Alex");
    assert_ne!(first, second);
    assert_eq!(
        fixture
            .store
            .named_transcript_speakers(&fixture.session)
            .unwrap()
            .len(),
        2
    );
    let inventory = fixture
        .store
        .begin_session_deletion(&fixture.session)
        .unwrap();
    assert_eq!(inventory.speaker_names, 2);
    fixture
        .store
        .abandon_session_deletion(&fixture.session)
        .unwrap();
    assert_eq!(
        fixture
            .store
            .transcript_document(&fixture.session)
            .unwrap()
            .len(),
        2
    );
}

#[test]
fn reader_metadata_uses_stored_library_facts_and_survives_speaker_edits() {
    let (mut fixture, revision) = conversation();
    let before = fixture
        .store
        .conversation_review_metadata(&fixture.session)
        .unwrap();
    assert_eq!(before.origin, "import");
    assert!(before.added_at_ms > 0);
    assert_eq!(
        before.stored_media_bytes,
        std::fs::metadata(&fixture.media).unwrap().len()
    );
    assert!(!before.source_names.is_empty());
    named(&mut fixture, &revision, 0, "Dana");
    assert_eq!(
        fixture
            .store
            .conversation_review_metadata(&fixture.session)
            .unwrap(),
        before
    );
}

#[test]
fn confirmed_deletion_removes_named_people_and_their_name_history() {
    let (mut fixture, revision) = conversation();
    let person = named(&mut fixture, &revision, 0, "Dana");
    fixture
        .store
        .rename_transcript_speaker(&fixture.session, &person, "D. Morgan")
        .unwrap();
    let inventory = fixture
        .store
        .begin_session_deletion(&fixture.session)
        .unwrap();
    let trashed = inventory.directory.with_file_name("owned-test-trash");
    std::fs::rename(&inventory.directory, &trashed).unwrap();
    fixture
        .store
        .complete_session_deletion(&fixture.session, None)
        .unwrap();
    for table in [
        "transcript_named_speakers",
        "transcript_speaker_names",
        "transcript_turn_speakers",
    ] {
        let count: i64 = fixture
            .store
            .connection
            .query_row(&format!("SELECT COUNT(*) FROM {table}"), [], |row| {
                row.get(0)
            })
            .unwrap();
        assert_eq!(count, 0, "confirmed deletion retained {table}");
    }
    let tombstone: String = fixture
        .store
        .connection
        .query_row(
            "SELECT lifecycle FROM sessions WHERE id = ?1",
            [&fixture.session.0],
            |row| row.get(0),
        )
        .unwrap();
    assert_eq!(tombstone, "deleted");
}

fn advance_clock() {
    let start = crate::wall_time_milliseconds();
    while crate::wall_time_milliseconds() == start {
        std::thread::sleep(std::time::Duration::from_millis(1));
    }
}

fn turn_labels(history: &[NamedSpeakerTurnHistory], sequence: u32) -> (String, Vec<String>) {
    let turn = history
        .iter()
        .find(|turn| turn.sequence == sequence)
        .unwrap();
    (
        turn.source_default_label.clone(),
        turn.revisions
            .iter()
            .map(|revision| revision.label.clone())
            .collect(),
    )
}

#[test]
fn merge_and_split_keep_each_named_assignment_and_the_source_default() {
    let (mut fixture, revision) = conversation();
    let audio = std::fs::read(&fixture.media).unwrap();
    let verbatim = fixture
        .store
        .transcript_revision_segments(&revision)
        .unwrap();
    let unnamed = fixture
        .store
        .named_speaker_turn_history(&fixture.session)
        .unwrap();
    assert_eq!(unnamed.len(), 2);
    assert!(
        unnamed
            .iter()
            .all(|turn| { turn.revisions.is_empty() && turn.source_default_label == "Speaker" })
    );
    let dana = named(&mut fixture, &revision, 0, "Dana");
    let morgan = named(&mut fixture, &revision, 1, "Morgan");
    assert_eq!(
        fixture
            .store
            .merge_named_speakers(&fixture.session, &dana, &dana)
            .unwrap_err()
            .to_string(),
        "invalid request: a speaker cannot merge into themself"
    );
    assert_eq!(
        fixture
            .store
            .merge_named_speakers(&fixture.session, &dana, &morgan)
            .unwrap(),
        1
    );
    assert_eq!(
        fixture
            .store
            .merge_named_speakers(&fixture.session, &dana, &morgan)
            .unwrap(),
        0
    );
    let merged = fixture.store.transcript_document(&fixture.session).unwrap();
    assert!(merged.iter().all(|segment| segment.speaker_label == "Dana"));
    assert_eq!(merged[1].named_speaker_id.as_deref(), Some(dana.as_str()));
    let people = fixture
        .store
        .named_transcript_speakers(&fixture.session)
        .unwrap();
    assert_eq!(
        people
            .iter()
            .map(|person| (person.label.as_str(), person.selected_turns))
            .collect::<Vec<_>>(),
        [("Dana", 2), ("Morgan", 0)]
    );
    let history = fixture
        .store
        .named_speaker_turn_history(&fixture.session)
        .unwrap();
    assert_eq!(
        turn_labels(&history, 1),
        ("Speaker".into(), vec!["Morgan".into(), "Dana".into()])
    );
    assert_eq!(
        history
            .iter()
            .find(|turn| turn.sequence == 1)
            .unwrap()
            .revisions
            .iter()
            .map(|revision| revision.origin)
            .collect::<Vec<_>>(),
        [SpeakerLabelOrigin::Human, SpeakerLabelOrigin::Human]
    );
    advance_clock();
    fixture
        .store
        .rename_transcript_speaker(&fixture.session, &dana, "D. Morgan")
        .unwrap();
    let renamed = fixture
        .store
        .named_speaker_turn_history(&fixture.session)
        .unwrap();
    assert_eq!(
        turn_labels(&renamed, 1),
        ("Speaker".into(), vec!["Morgan".into(), "Dana".into()])
    );
    assert_eq!(
        fixture.store.transcript_document(&fixture.session).unwrap()[1].speaker_label,
        "D. Morgan"
    );
    assert_eq!(
        fixture
            .store
            .split_named_speaker(&fixture.session, &dana, &[], "Mina")
            .unwrap_err()
            .to_string(),
        "invalid request: a split needs at least one passage"
    );
    let both = [
        NamedSpeakerTurn {
            revision_id: revision.clone(),
            sequence: 0,
        },
        NamedSpeakerTurn {
            revision_id: revision.clone(),
            sequence: 1,
        },
    ];
    assert_eq!(
        fixture
            .store
            .split_named_speaker(&fixture.session, &dana, &both, "Mina")
            .unwrap_err()
            .to_string(),
        "invalid request: a split must leave one passage with this person"
    );
    let mina = fixture
        .store
        .split_named_speaker(
            &fixture.session,
            &dana,
            &[NamedSpeakerTurn {
                revision_id: revision.clone(),
                sequence: 1,
            }],
            "Mina",
        )
        .unwrap();
    assert_ne!(mina, dana);
    let split = fixture.store.transcript_document(&fixture.session).unwrap();
    assert_eq!(split[0].speaker_label, "D. Morgan");
    assert_eq!(split[0].named_speaker_id.as_deref(), Some(dana.as_str()));
    assert_eq!(split[1].speaker_label, "Mina");
    assert_eq!(split[1].named_speaker_id.as_deref(), Some(mina.as_str()));
    assert_eq!(split[0].verbatim_text, "First voice");
    assert_eq!(split[1].verbatim_text, "Second voice");
    let after = fixture
        .store
        .named_speaker_turn_history(&fixture.session)
        .unwrap();
    assert_eq!(
        turn_labels(&after, 1),
        (
            "Speaker".into(),
            vec!["Morgan".into(), "Dana".into(), "Mina".into()]
        )
    );
    let counts = fixture
        .store
        .named_transcript_speakers(&fixture.session)
        .unwrap();
    assert_eq!(
        counts
            .iter()
            .map(|person| (person.id.as_str(), person.selected_turns))
            .collect::<Vec<_>>(),
        [(dana.as_str(), 1), (mina.as_str(), 1), (morgan.as_str(), 0)]
    );
    assert_eq!(
        fixture
            .store
            .split_named_speaker(
                &fixture.session,
                &dana,
                &[NamedSpeakerTurn {
                    revision_id: revision.clone(),
                    sequence: 0,
                }],
                "Noah",
            )
            .unwrap_err()
            .to_string(),
        "invalid request: a split must leave one passage with this person"
    );
    fixture
        .store
        .assign_transcript_speaker(
            &fixture.session,
            &revision,
            0,
            &TranscriptSpeakerAssignment::Source,
        )
        .unwrap();
    let restored = fixture
        .store
        .named_speaker_turn_history(&fixture.session)
        .unwrap();
    let first = restored.iter().find(|turn| turn.sequence == 0).unwrap();
    assert_eq!(first.revisions.last().unwrap().label, "Speaker");
    assert_eq!(
        first.revisions.last().unwrap().origin,
        SpeakerLabelOrigin::SourceDefault
    );
    assert!(
        first
            .revisions
            .iter()
            .any(|revision| revision.label == "Dana")
    );
    assert_eq!(
        fixture.store.session_speakers(&fixture.session).unwrap()[0].label,
        "Speaker"
    );
    assert_eq!(
        fixture
            .store
            .transcript_revision_segments(&revision)
            .unwrap(),
        verbatim
    );
    assert_eq!(std::fs::read(&fixture.media).unwrap(), audio);
    assert!(
        fixture
            .store
            .connection
            .execute("UPDATE transcript_turn_speakers SET id = 'rewritten'", [])
            .is_err()
    );
}
