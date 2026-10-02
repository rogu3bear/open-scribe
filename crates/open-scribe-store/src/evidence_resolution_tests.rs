use super::*;
use crate::TranscriptionRunIdentity;
use crate::transcripts::tests::{Fixture, complete_all, identity, imported_fixture, plan};

fn transcribed() -> (Fixture, String) {
    let mut fixture = imported_fixture(144_000);
    let run = fixture
        .store
        .begin_transcription_run(&identity(&fixture, "options-a"), &plan())
        .unwrap();
    let revision = complete_all(&mut fixture, &run, ["alpha", "bravo"]);
    (fixture, revision)
}

fn state(fixture: &Fixture, reference: &EvidenceRef) -> ResolutionState {
    fixture.store.resolve_evidence(reference).unwrap().state
}

#[test]
fn transcript_references_resolve_supersede_and_detect_tampering() {
    let (mut fixture, first) = transcribed();
    let session = fixture.session.clone();
    let cited = fixture
        .store
        .cite_transcript_segment(&session, &first, 0)
        .unwrap();
    assert_eq!(cited.record_id, first);
    assert_eq!(cited.sub_item.as_deref(), Some("0"));
    let resolved = fixture.store.resolve_evidence(&cited).unwrap();
    assert_eq!(resolved.state, ResolutionState::Available);
    assert_eq!(resolved.text.as_deref(), Some("alpha"));
    // The reference survives a JSON round trip unchanged.
    let parsed = EvidenceRef::parse(&serde_json::to_string(&cited).unwrap()).unwrap();
    assert_eq!(parsed, cited);

    // A newer selected revision supersedes, but never replaces, the citation.
    let replacement = TranscriptionRunIdentity {
        model_id: "replacement-model".into(),
        model_sha256: "b".repeat(64),
        ..identity(&fixture, "options-a")
    };
    let run = fixture
        .store
        .begin_transcription_run(&replacement, &plan())
        .unwrap();
    let second = complete_all(&mut fixture, &run, ["charlie", "delta"]);
    let superseded = fixture.store.resolve_evidence(&cited).unwrap();
    assert_eq!(superseded.state, ResolutionState::Superseded);
    assert_eq!(superseded.text.as_deref(), Some("alpha"));
    assert_eq!(
        superseded.current_revision_id.as_deref(),
        Some(second.as_str())
    );

    let mut wrong_digest = cited.clone();
    wrong_digest.content_digest = "0".repeat(64);
    let mut moved = cited.clone();
    moved.start_ns += 1;
    let mut other_record = cited.clone();
    other_record.record_id = "another-revision".into();
    for reference in [wrong_digest, moved, other_record] {
        assert_eq!(
            state(&fixture, &reference),
            ResolutionState::IntegrityMismatch
        );
    }
    let mut absent = cited.clone();
    absent.sub_item = Some("99".into());
    assert_eq!(state(&fixture, &absent), ResolutionState::Missing);
    let mut future = cited.clone();
    future.schema = "open-scribe.evidence-ref/v2".into();
    assert_eq!(
        state(&fixture, &future),
        ResolutionState::UnsupportedVersion
    );
    let mut malformed = cited.clone();
    malformed.session_id = "../escape".into();
    assert!(fixture.store.resolve_evidence(&malformed).is_err());
    let mut unknown_session = cited;
    unknown_session.session_id = "00000000-0000-7000-8000-000000000000".into();
    assert_eq!(state(&fixture, &unknown_session), ResolutionState::Missing);
}

#[test]
fn corrections_cite_their_own_text_and_are_superseded_by_later_ones() {
    let (mut fixture, revision) = transcribed();
    let session = fixture.session.clone();
    let correction = fixture
        .store
        .correct_transcript_segment(&session, &revision, 0, Some("Aleph"))
        .unwrap();
    let cited = fixture
        .store
        .cite_human_correction(&session, &correction)
        .unwrap();
    let resolved = fixture.store.resolve_evidence(&cited).unwrap();
    assert_eq!(resolved.state, ResolutionState::Available);
    assert_eq!(resolved.text.as_deref(), Some("Aleph"));
    fixture
        .store
        .correct_transcript_segment(&session, &revision, 0, None)
        .unwrap();
    assert_eq!(state(&fixture, &cited), ResolutionState::Superseded);
}

#[test]
fn audio_ranges_recheck_the_sealed_bytes_and_deletion_is_reported() {
    let (mut fixture, _) = transcribed();
    let session = fixture.session.clone();
    let track = fixture.track.clone();
    let cited = fixture
        .store
        .cite_audio_range(&session, &track, 500_000_000, 1_500_000_000)
        .unwrap();
    assert_eq!(state(&fixture, &cited), ResolutionState::Available);
    assert!(
        fixture
            .store
            .cite_audio_range(&session, &track, 0, 4_000_000_000)
            .is_err()
    );
    let mut beyond = cited.clone();
    beyond.end_ns = 4_000_000_000;
    assert_eq!(state(&fixture, &beyond), ResolutionState::IntegrityMismatch);

    let original = fs::read(&fixture.media).unwrap();
    let mut changed = original.clone();
    *changed.last_mut().unwrap() ^= 1;
    fs::write(&fixture.media, &changed).unwrap();
    assert_eq!(state(&fixture, &cited), ResolutionState::IntegrityMismatch);
    fs::write(&fixture.media, &original).unwrap();
    assert_eq!(state(&fixture, &cited), ResolutionState::Available);

    let transcript = fixture
        .store
        .cite_transcript_segment(
            &session,
            &fixture.store.transcript_document(&session).unwrap()[0].revision_id,
            0,
        )
        .unwrap();
    fixture.store.begin_session_deletion(&session).unwrap();
    let directory = fixture.root.join(SESSIONS_DIRECTORY).join(&session.0);
    fs::rename(&directory, fixture.root.parent().unwrap().join("Trashed")).unwrap();
    fixture
        .store
        .complete_session_deletion(&session, None)
        .unwrap();
    for reference in [cited, transcript] {
        assert_eq!(state(&fixture, &reference), ResolutionState::Deleted);
    }
}
