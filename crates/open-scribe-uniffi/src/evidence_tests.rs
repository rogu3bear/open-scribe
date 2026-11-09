//! Swift sends claim JSON and reads the navigation record. This test opens
//! `NativeTranscriptLibrary` on a real imported transcript.

use std::fs::File;
use std::io::Write;
use std::path::{Path, PathBuf};

use open_scribe_evidence::{
    AdjudicationAction, ClaimKind, ClaimProducer, ClaimStatus, DERIVED_CLAIM_SCHEMA, DerivedClaim,
    EvidenceRef,
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
