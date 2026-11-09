use super::*;
use crate::transcripts::tests::{complete_all, identity, imported_fixture, plan};
use open_scribe_evidence::{
    AdjudicationAction, ClaimKind, ClaimProducer, ClaimStatus, DERIVED_CLAIM_SCHEMA, DerivedClaim,
};

fn agreed(session: &SessionId, cited: EvidenceRef) -> DerivedClaim {
    DerivedClaim {
        schema: DERIVED_CLAIM_SCHEMA.to_owned(),
        claim_id: "claim-decision".into(),
        revision_id: "revision-a".into(),
        session_id: session.0.clone(),
        kind: ClaimKind::Decision,
        text: "The team agreed to ship the local recorder.".into(),
        status: ClaimStatus::Agreed,
        supporting: vec![cited],
        contradicting: Vec::new(),
        producer: ClaimProducer::ModelRun,
        adjudication: None,
    }
}

fn body(store: &SessionStore, revision_id: &str) -> String {
    store
        .connection
        .query_row(
            "SELECT body FROM derived_claim_revisions WHERE revision_id = ?1",
            [revision_id],
            |row| row.get(0),
        )
        .unwrap()
}

#[test]
fn human_adjudication_stays_effective_and_navigates_to_the_transcript() {
    let mut fixture = imported_fixture(144_000);
    let run = fixture
        .store
        .begin_transcription_run(&identity(&fixture, "options-a"), &plan())
        .unwrap();
    let revision = complete_all(&mut fixture, &run, ["alpha", "bravo"]);
    let session = fixture.session.clone();
    let cited = fixture
        .store
        .cite_transcript_segment(&session, &revision, 0)
        .unwrap();
    let claim = agreed(&session, cited.clone());
    fixture.store.insert_derived_claim(&claim).unwrap();
    let original = body(&fixture.store, "revision-a");

    let mut corrected = claim
        .with_adjudication(
            AdjudicationAction::Corrected,
            "revision-b",
            "adjudication-1",
        )
        .unwrap();
    corrected.text = "The team deferred the remote recorder.".into();
    fixture.store.insert_derived_claim(&corrected).unwrap();

    let mut rerun = claim;
    rerun.revision_id = "revision-c".into();
    rerun.text = "The team agreed to upload every recording.".into();
    fixture.store.insert_derived_claim(&rerun).unwrap();

    let effective = fixture
        .store
        .effective_derived_claim(&session, "claim-decision")
        .unwrap()
        .unwrap();
    assert_eq!(effective.revision_id, "revision-b");
    assert_eq!(effective.text, "The team deferred the remote recorder.");
    assert_eq!(body(&fixture.store, "revision-a"), original);
    assert!(
        fixture
            .store
            .connection
            .execute(
                "UPDATE derived_claim_revisions SET body = 'changed' WHERE revision_id = ?1",
                ["revision-a"],
            )
            .is_err()
    );

    let navigation = fixture
        .store
        .navigate_derived_claim(&session, "claim-decision")
        .unwrap();
    assert_eq!(navigation.revision_id, "revision-b");
    assert_eq!(navigation.adjudication, Some(AdjudicationAction::Corrected));
    assert_eq!(navigation.targets.len(), 1);
    let target = &navigation.targets[0];
    assert_eq!(target.side, ClaimEvidenceSide::Supporting);
    assert_eq!(target.state, ResolutionState::Available);
    assert_eq!(target.text.as_deref(), Some("alpha"));
    assert_eq!(target.record_id, cited.record_id);
    assert_eq!(target.start_ns, cited.start_ns);
    assert_eq!(target.end_ns, cited.end_ns);
}

#[test]
fn an_unsupported_claim_is_not_canonical_navigation() {
    let mut fixture = imported_fixture(144_000);
    let session = fixture.session.clone();
    let mut draft = agreed(
        &session,
        EvidenceRef {
            schema: open_scribe_evidence::EVIDENCE_REF_SCHEMA.to_owned(),
            session_id: session.0.clone(),
            kind: open_scribe_evidence::EvidenceKind::TranscriptSegment,
            record_id: "missing".into(),
            revision_id: Some("missing".into()),
            start_ns: 0,
            end_ns: 1,
            sub_item: Some("0".into()),
            content_digest: "ab".repeat(32),
            resolver_hint: None,
        },
    );
    draft.producer = ClaimProducer::ModelRun;
    draft.supporting.clear();
    assert!(matches!(
        fixture.store.insert_derived_claim(&draft),
        Err(StoreError::InvalidRequest(_))
    ));

    draft.producer = ClaimProducer::Human;
    draft.status = ClaimStatus::Unsupported;
    draft.revision_id = "revision-draft".into();
    fixture.store.insert_derived_claim(&draft).unwrap();
    assert!(
        fixture
            .store
            .effective_derived_claim(&session, "claim-decision")
            .unwrap()
            .is_none()
    );
    assert!(matches!(
        fixture
            .store
            .navigate_derived_claim(&session, "claim-decision"),
        Err(StoreError::InvalidRequest(_))
    ));
}
