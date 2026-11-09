//! Swift sends claim JSON and reads the navigation record. This test opens
//! `NativeTranscriptLibrary` on a real imported transcript.

use std::fs::File;
use std::io::Write;
use std::path::{Path, PathBuf};

use open_scribe_evidence::{
    AdjudicationAction, ClaimKind, ClaimProducer, ClaimStatus, DERIVED_CLAIM_SCHEMA,
    DeltaIngestReceipt, DerivedClaim, EvidenceRef, MEETING_MEMORY_DELTA_SCHEMA,
};
use open_scribe_store::{
    ImportMediaRequest, PlannedTranscriptChunk, RevisionSegmentInput, SessionStore,
    TranscriptChunk, TranscriptChunkState, TranscriptionRunIdentity,
};
use open_scribe_types::SessionId;
use sha2::{Digest, Sha256};
use tempfile::TempDir;

use super::{NativeEvidenceState, NativeStorageError, NativeTranscriptLibrary};

const SECOND: i64 = 1_000_000_000;

struct PreparedTranscript {
    _temp: TempDir,
    root: PathBuf,
    session: SessionId,
    revision: String,
    digest_sha256: String,
    media: PathBuf,
}

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

fn file_sha256(path: &Path) -> String {
    Sha256::digest(std::fs::read(path).unwrap())
        .iter()
        .map(|byte| format!("{byte:02x}"))
        .collect()
}

fn hypothesis(text: &str) -> String {
    serde_json::json!({
        "language": "en",
        "segments": [{ "start_ms": 100, "end_ms": 900, "text": text }]
    })
    .to_string()
}

fn segment(chunk: &TranscriptChunk, offset: i64, text: &str) -> RevisionSegmentInput {
    RevisionSegmentInput {
        start_nanoseconds: chunk.start_nanoseconds + offset,
        end_nanoseconds: chunk.start_nanoseconds + offset + SECOND / 2,
        text: text.into(),
        mean_probability: Some(0.8),
        no_speech_probability: None,
        chunk_identity: chunk.identity.clone(),
    }
}

fn prepared_transcript() -> PreparedTranscript {
    let temp = TempDir::new().unwrap();
    let source = temp.path().join("source.caf");
    write_caf(&source, 144_000);
    let root = temp.path().join("Open Scribe");
    let mut store = SessionStore::open(&root).unwrap();
    let evidence = store
        .import_recoverable_caf(ImportMediaRequest {
            title: "Native claim fixture".into(),
            source_path: source,
        })
        .unwrap();
    let track = store
        .transcription_tracks(&evidence.session_id)
        .unwrap()
        .remove(0);
    let input = store
        .transcription_input(&evidence.session_id, &track)
        .unwrap();
    let identity = TranscriptionRunIdentity {
        session_id: evidence.session_id.clone(),
        track_id: track,
        input_digest: input.input_digest,
        engine: "fixture-engine".into(),
        engine_version: "1".into(),
        model_id: "fixture-model".into(),
        model_sha256: "a".repeat(64),
        options_digest: "options-a".into(),
        reconciliation_version: "overlap-midpoint-v1".into(),
    };
    let plan = [
        PlannedTranscriptChunk {
            span_index: 0,
            start_nanoseconds: 0,
            end_nanoseconds: 2 * SECOND,
        },
        PlannedTranscriptChunk {
            span_index: 0,
            start_nanoseconds: SECOND,
            end_nanoseconds: 3 * SECOND,
        },
    ];
    let run = store.begin_transcription_run(&identity, &plan).unwrap();
    for (chunk, word) in run.chunks.iter().zip(["alpha", "bravo"]) {
        assert_ne!(chunk.state, TranscriptChunkState::Complete);
        store
            .complete_transcript_chunk(&run.run_id, chunk.sequence, "en", &hypothesis(word))
            .unwrap();
    }
    let segments = [
        segment(&run.chunks[0], SECOND / 10, "alpha"),
        segment(&run.chunks[1], SECOND, "bravo"),
    ];
    let revision = store
        .commit_transcript_revision(&run.run_id, &segments, "{}", "[]")
        .unwrap();
    let media = root
        .join("Sessions")
        .join(&evidence.session_id.0)
        .join(&evidence.relative_path);
    assert_eq!(file_sha256(&media), evidence.digest_sha256);
    let digest_sha256 = evidence.digest_sha256;
    let session = evidence.session_id;
    drop(store);
    PreparedTranscript {
        _temp: temp,
        root,
        session,
        revision,
        digest_sha256,
        media,
    }
}

#[test]
fn native_library_adjudicates_a_claim_without_a_caller_chosen_revision() {
    let prepared = prepared_transcript();
    let library = NativeTranscriptLibrary::open(prepared.root.display().to_string()).unwrap();
    let session_id = prepared.session.0.clone();
    let cited_json = library
        .cite_transcript_segment(session_id.clone(), prepared.revision.clone(), 0)
        .unwrap();
    let cited = EvidenceRef::parse(&cited_json).unwrap();
    library
        .insert_derived_claim(claim_json(
            &prepared.session,
            cited,
            "revision-a",
            "The team agreed to ship the local recorder.",
        ))
        .unwrap();
    assert!(matches!(
        library.adjudicate_derived_claim(
            session_id.clone(),
            "claim-decision".into(),
            "unresolved".into(),
            None,
        ),
        Err(NativeStorageError::InvalidRequest)
    ));
    assert!(matches!(
        library.adjudicate_derived_claim(
            session_id.clone(),
            "claim-decision".into(),
            "accepted".into(),
            Some("The team deferred the remote recorder.".into()),
        ),
        Err(NativeStorageError::InvalidRequest)
    ));
    let revision = library
        .adjudicate_derived_claim(
            session_id.clone(),
            "claim-decision".into(),
            "corrected".into(),
            Some("The team deferred the remote recorder.".into()),
        )
        .unwrap();
    assert_ne!(revision, "revision-a");
    let navigation = library
        .navigate_derived_claim(session_id.clone(), "claim-decision".into())
        .unwrap();
    assert_eq!(navigation.revision_id, revision);
    assert_eq!(navigation.text, "The team deferred the remote recorder.");
    assert_eq!(navigation.adjudication.as_deref(), Some("corrected"));
    let rejected = library
        .adjudicate_derived_claim(
            session_id.clone(),
            "claim-decision".into(),
            "rejected".into(),
            None,
        )
        .unwrap();
    assert_ne!(rejected, revision);
    let navigation = library
        .navigate_derived_claim(session_id, "claim-decision".into())
        .unwrap();
    assert_eq!(navigation.revision_id, rejected);
    assert_eq!(navigation.adjudication.as_deref(), Some("rejected"));
    assert_eq!(navigation.text, "The team deferred the remote recorder.");
}

fn claim_json(session: &SessionId, cited: EvidenceRef, revision_id: &str, text: &str) -> String {
    let claim = DerivedClaim {
        schema: DERIVED_CLAIM_SCHEMA.to_owned(),
        claim_id: "claim-decision".into(),
        revision_id: revision_id.into(),
        session_id: session.0.clone(),
        kind: ClaimKind::Decision,
        text: text.into(),
        status: ClaimStatus::Agreed,
        supporting: vec![cited],
        contradicting: Vec::new(),
        producer: ClaimProducer::ModelRun,
        adjudication: None,
    };
    serde_json::to_string(&claim).unwrap()
}

#[test]
fn native_library_keeps_human_adjudication_ahead_of_a_later_model_revision() {
    let prepared = prepared_transcript();
    let library = NativeTranscriptLibrary::open(prepared.root.display().to_string()).unwrap();
    let session_id = prepared.session.0.clone();
    assert!(matches!(
        library.insert_derived_claim("{}".into()),
        Err(NativeStorageError::InvalidRequest)
    ));
    library
        .correct_segment(
            session_id.clone(),
            prepared.revision.clone(),
            1,
            Some("Bravo two".into()),
        )
        .unwrap();
    let cited_json = library
        .cite_transcript_segment(session_id.clone(), prepared.revision.clone(), 0)
        .unwrap();
    let cited = EvidenceRef::parse(&cited_json).unwrap();
    let original = claim_json(
        &prepared.session,
        cited.clone(),
        "revision-a",
        "The team agreed to ship the local recorder.",
    );
    library.insert_derived_claim(original).unwrap();

    let mut corrected = DerivedClaim::parse(&claim_json(
        &prepared.session,
        cited.clone(),
        "revision-a",
        "The team agreed to ship the local recorder.",
    ))
    .unwrap()
    .with_adjudication(
        AdjudicationAction::Corrected,
        "revision-b",
        "adjudication-1",
    )
    .unwrap();
    corrected.text = "The team deferred the remote recorder.".into();
    library
        .insert_derived_claim(serde_json::to_string(&corrected).unwrap())
        .unwrap();
    library
        .insert_derived_claim(claim_json(
            &prepared.session,
            cited,
            "revision-c",
            "The team agreed to upload every recording.",
        ))
        .unwrap();

    let navigation = library
        .navigate_derived_claim(session_id.clone(), "claim-decision".into())
        .unwrap();
    assert_eq!(navigation.revision_id, "revision-b");
    assert_eq!(navigation.text, "The team deferred the remote recorder.");
    assert_eq!(navigation.adjudication.as_deref(), Some("corrected"));
    assert_eq!(navigation.targets.len(), 1);
    let target = &navigation.targets[0];
    assert_eq!(target.side, "supporting");
    assert_eq!(target.state, NativeEvidenceState::Available);
    assert_eq!(target.text.as_deref(), Some("alpha"));
    assert_eq!(target.record_id, corrected.supporting[0].record_id);

    let inventory = library.begin_deletion(session_id.clone()).unwrap();
    assert!(inventory.media_files > 0);
    assert!(inventory.human_corrections > 0);
    library.abandon_deletion(session_id.clone()).unwrap();

    let document = library.document(session_id.clone()).unwrap();
    let bravo = document
        .iter()
        .find(|segment| segment.sequence == 1)
        .unwrap();
    assert_eq!(bravo.verbatim_text, "bravo");
    assert_eq!(bravo.effective_text, "Bravo two");
    assert!(bravo.corrected);
    let after_cancel = library
        .navigate_derived_claim(session_id, "claim-decision".into())
        .unwrap();
    assert_eq!(after_cancel.adjudication.as_deref(), Some("corrected"));
    assert_eq!(after_cancel.text, navigation.text);
    assert_eq!(after_cancel.targets[0].text.as_deref(), Some("alpha"));
    assert_eq!(file_sha256(&prepared.media), prepared.digest_sha256);
}

#[test]
fn native_library_keeps_a_human_adjudication_ahead_of_a_meeting_memory_delta() {
    let prepared = prepared_transcript();
    let library = NativeTranscriptLibrary::open(prepared.root.display().to_string()).unwrap();
    let session_id = prepared.session.0.clone();
    assert_eq!(
        library.meeting_memory_revision(session_id.clone()).unwrap(),
        "0"
    );
    assert!(matches!(
        library.ingest_meeting_memory_delta(r#"{"adjudication":"accepted"}"#.into()),
        Err(NativeStorageError::InvalidRequest)
    ));
    let cited = EvidenceRef::parse(
        &library
            .cite_transcript_segment(session_id.clone(), prepared.revision.clone(), 0)
            .unwrap(),
    )
    .unwrap();
    let mut proposal = serde_json::json!({
        "schema": MEETING_MEMORY_DELTA_SCHEMA,
        "model_run_id": "run-1",
        "input_manifest_digest": "b".repeat(64),
        "session_id": session_id,
        "base_revision": "stale",
        "operations": [{
            "op": "propose_claim",
            "operation_id": "op-propose",
            "kind": "decision",
            "text": "The team agreed to ship the local recorder.",
            "status": "agreed",
            "supporting": [cited.clone()],
            "contradicting": []
        }]
    });
    assert!(matches!(
        library.ingest_meeting_memory_delta(proposal.to_string()),
        Err(NativeStorageError::InvalidRequest)
    ));
    assert_eq!(
        library.meeting_memory_revision(session_id.clone()).unwrap(),
        "0"
    );
    proposal["base_revision"] = serde_json::json!("0");
    let receipt: DeltaIngestReceipt = serde_json::from_str(
        &library
            .ingest_meeting_memory_delta(proposal.to_string())
            .unwrap(),
    )
    .unwrap();
    assert_eq!(receipt.operations[0].outcome, "accepted");
    let claim_id = receipt.operations[0].claim_id.clone().unwrap();
    let model_revision = receipt.operations[0].revision_id.clone().unwrap();
    assert_eq!(
        library.meeting_memory_revision(session_id.clone()).unwrap(),
        receipt.next_revision
    );

    let proposed = DerivedClaim {
        schema: DERIVED_CLAIM_SCHEMA.to_owned(),
        claim_id: claim_id.clone(),
        revision_id: model_revision.clone(),
        session_id: session_id.clone(),
        kind: ClaimKind::Decision,
        text: "The team agreed to ship the local recorder.".into(),
        status: ClaimStatus::Agreed,
        supporting: vec![cited.clone()],
        contradicting: Vec::new(),
        producer: ClaimProducer::ModelRun,
        adjudication: None,
    };
    let mut corrected = proposed
        .with_adjudication(
            AdjudicationAction::Corrected,
            "revision-human",
            "adjudication-1",
        )
        .unwrap();
    corrected.text = "The team deferred the remote recorder.".into();
    library
        .insert_derived_claim(serde_json::to_string(&corrected).unwrap())
        .unwrap();

    let mut later = serde_json::json!({
        "schema": MEETING_MEMORY_DELTA_SCHEMA,
        "model_run_id": "run-2",
        "input_manifest_digest": "c".repeat(64),
        "session_id": session_id,
        "base_revision": receipt.next_revision,
        "operations": [
            {
                "op": "revise_claim",
                "operation_id": "op-revise",
                "claim_id": claim_id,
                "kind": "decision",
                "text": "The team agreed to upload every recording.",
                "status": "agreed",
                "supporting": [cited.clone()],
                "contradicting": []
            },
            {
                "op": "propose_claim",
                "operation_id": "op-other",
                "kind": "question",
                "text": "Who owns the recorder?",
                "status": "open",
                "supporting": [cited.clone()],
                "contradicting": []
            }
        ]
    });
    let second: DeltaIngestReceipt = serde_json::from_str(
        &library
            .ingest_meeting_memory_delta(later.to_string())
            .unwrap(),
    )
    .unwrap();
    let revise = second
        .operations
        .iter()
        .find(|item| item.operation_id == "op-revise")
        .unwrap();
    assert_eq!(revise.outcome, "rejected");
    assert_eq!(
        revise.reason.as_deref(),
        Some("human adjudication stays in effect")
    );
    assert_eq!(revise.revision_id.as_deref(), Some("revision-human"));
    let other = second
        .operations
        .iter()
        .find(|item| item.operation_id == "op-other")
        .unwrap();
    assert_eq!(other.outcome, "accepted");
    assert_ne!(other.claim_id.as_deref(), Some(claim_id.as_str()));

    let navigation = library
        .navigate_derived_claim(session_id.clone(), claim_id.clone())
        .unwrap();
    assert_eq!(navigation.revision_id, "revision-human");
    assert_eq!(navigation.text, "The team deferred the remote recorder.");
    assert_eq!(navigation.adjudication.as_deref(), Some("corrected"));
    assert_eq!(navigation.targets[0].text.as_deref(), Some("alpha"));
    assert_ne!(navigation.revision_id, model_revision);
    let listed = library
        .effective_derived_claims(session_id.clone())
        .unwrap();
    assert!(listed.contains("The team deferred the remote recorder."));
    assert!(listed.contains("Who owns the recorder?"));
    assert!(!listed.contains("upload every recording"));

    later["base_revision"] = serde_json::json!(second.next_revision);
    assert!(matches!(
        library.ingest_meeting_memory_delta(later.to_string()),
        Err(NativeStorageError::InvalidRequest)
    ));
    assert!(matches!(
        library.ingest_meeting_memory_delta(
            r#"{"schema":"open-scribe.meeting-memory-delta/v1","operations":[{"op":"delete_evidence"}]}"#
                .into()
        ),
        Err(NativeStorageError::InvalidRequest)
    ));
    let after = library
        .navigate_derived_claim(session_id, claim_id)
        .unwrap();
    assert_eq!(after.revision_id, "revision-human");
    assert_eq!(after.text, navigation.text);
    assert_eq!(after.targets[0].text.as_deref(), Some("alpha"));
    assert_eq!(file_sha256(&prepared.media), prepared.digest_sha256);
}
