//! The macOS review surface calls `TranscriptLibrary`, not the store.
//! These tests drive that path: an imported recording, a committed
//! transcript, a human adjudication, and a cancelled deletion.

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

use crate::{
    ClaimEvidenceSide, ResolutionState, SpeakerDiarizationTrackInput, SpeakerLabelOrigin,
    StoreError, TranscriptLibrary, TranscriptSpeakerAssignment,
};

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

/// Three seconds of managed audio and two committed transcript segments.
/// The store is dropped before the library opens the same root.
fn prepared_transcript() -> PreparedTranscript {
    let temp = TempDir::new().unwrap();
    let source = temp.path().join("source.caf");
    write_caf(&source, 144_000);
    let root = temp.path().join("Open Scribe");
    let mut store = SessionStore::open(&root).unwrap();
    let evidence = store
        .import_recoverable_caf(ImportMediaRequest {
            title: "Library claim fixture".into(),
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

#[test]
fn human_adjudication_stays_effective_through_the_library_and_cancelled_deletion() {
    let prepared = prepared_transcript();
    let mut library = TranscriptLibrary::open(&prepared.root).unwrap();
    let session = &prepared.session;
    library
        .correct_segment(session, &prepared.revision, 1, Some("Bravo two"))
        .unwrap();
    let cited = library
        .cite_transcript_segment(session, &prepared.revision, 0)
        .unwrap();
    let claim = agreed(session, cited.clone());
    library.insert_derived_claim(&claim).unwrap();

    let mut corrected = claim
        .with_adjudication(
            AdjudicationAction::Corrected,
            "revision-b",
            "adjudication-1",
        )
        .unwrap();
    corrected.text = "The team deferred the remote recorder.".into();
    library.insert_derived_claim(&corrected).unwrap();

    let mut rerun = claim;
    rerun.revision_id = "revision-c".into();
    rerun.text = "The team agreed to upload every recording.".into();
    library.insert_derived_claim(&rerun).unwrap();

    let navigation = library
        .navigate_derived_claim(session, "claim-decision")
        .unwrap();
    assert_eq!(navigation.revision_id, "revision-b");
    assert_eq!(navigation.text, "The team deferred the remote recorder.");
    assert_eq!(navigation.adjudication, Some(AdjudicationAction::Corrected));
    assert_eq!(navigation.targets.len(), 1);
    let target = &navigation.targets[0];
    assert_eq!(target.side, ClaimEvidenceSide::Supporting);
    assert_eq!(target.state, ResolutionState::Available);
    assert_eq!(target.text.as_deref(), Some("alpha"));
    assert_eq!(target.record_id, cited.record_id);
    assert_eq!(target.start_ns, cited.start_ns);
    assert_eq!(target.end_ns, cited.end_ns);

    let inventory = library.begin_deletion(session).unwrap();
    assert!(inventory.media_files > 0);
    assert!(inventory.transcript_revisions > 0);
    assert!(inventory.human_corrections > 0);
    library.abandon_deletion(session).unwrap();

    let document = library.document(session).unwrap();
    let alpha = document
        .iter()
        .find(|segment| segment.sequence == 0)
        .unwrap();
    let bravo = document
        .iter()
        .find(|segment| segment.sequence == 1)
        .unwrap();
    assert_eq!(alpha.verbatim_text, "alpha");
    assert_eq!(alpha.effective_text, "alpha");
    assert!(!alpha.corrected);
    assert_eq!(bravo.verbatim_text, "bravo");
    assert_eq!(bravo.effective_text, "Bravo two");
    assert!(bravo.corrected);
    let after_cancel = library
        .navigate_derived_claim(session, "claim-decision")
        .unwrap();
    assert_eq!(after_cancel.revision_id, "revision-b");
    assert_eq!(after_cancel.text, navigation.text);
    assert_eq!(after_cancel.targets[0].text.as_deref(), Some("alpha"));
    assert_eq!(file_sha256(&prepared.media), prepared.digest_sha256);

    let reopened = SessionStore::open(&prepared.root).unwrap();
    let saved = reopened.session_inventory(session).unwrap();
    assert_eq!(saved.lifecycle, "ready_for_review");
    assert_eq!(saved.media[0].digest_sha256, prepared.digest_sha256);
}

#[test]
fn imported_review_keeps_unknown_speakers_when_diarization_is_uncalibrated() {
    let prepared = prepared_transcript();
    let mut library = TranscriptLibrary::open(&prepared.root).unwrap();
    let session = &prepared.session;
    let first = library.prepare_speaker_diarization(session).unwrap();
    assert!(first.inserted);
    assert_eq!(first.algorithm_id, open_scribe_diarize::ALGORITHM_ID);
    assert_eq!(
        first.clustering_state,
        open_scribe_diarize::CLUSTERING_UNAVAILABLE
    );
    assert_eq!(first.reason, open_scribe_diarize::UNAVAILABLE_REASON);
    assert_eq!(first.tracks.len(), 1);
    let track = &first.tracks[0];
    assert_eq!(track.source_kind, "imported_audio");
    assert_eq!(track.disposition, "unresolved");
    assert_eq!(track.label, "Unknown speaker");
    assert_eq!(track.label_origin, "source_default");
    assert!(!track.label.contains("Speaker "));

    let named = library
        .assign_speaker(
            session,
            &prepared.revision,
            0,
            &TranscriptSpeakerAssignment::New("Dana".into()),
        )
        .unwrap();
    assert!(named.is_some());
    let second = library.prepare_speaker_diarization(session).unwrap();
    assert!(!second.inserted);
    assert_eq!(second.run_id, first.run_id);
    assert_eq!(second.tracks, first.tracks);

    let document = library.document(session).unwrap();
    let alpha = document
        .iter()
        .find(|segment| segment.sequence == 0)
        .unwrap();
    let bravo = document
        .iter()
        .find(|segment| segment.sequence == 1)
        .unwrap();
    assert_eq!(alpha.revision_id, prepared.revision);
    assert_eq!(alpha.verbatim_text, "alpha");
    assert_eq!(alpha.effective_text, "alpha");
    assert_eq!(alpha.speaker_label, "Dana");
    assert_eq!(alpha.speaker_origin, SpeakerLabelOrigin::Human);
    assert_eq!(bravo.verbatim_text, "bravo");
    assert_eq!(bravo.effective_text, "bravo");
    assert_eq!(bravo.speaker_label, "Unknown speaker");
    assert_eq!(bravo.speaker_origin, SpeakerLabelOrigin::SourceDefault);
    assert_eq!(file_sha256(&prepared.media), prepared.digest_sha256);

    let mut store = SessionStore::open(&prepared.root).unwrap();
    let uncalibrated = store.record_speaker_diarization(
        session,
        open_scribe_diarize::ALGORITHM_ID,
        "clustered",
        open_scribe_diarize::UNAVAILABLE_REASON,
        &[SpeakerDiarizationTrackInput {
            track_id: track.track_id.clone(),
            disposition: "unresolved".into(),
        }],
    );
    assert!(matches!(uncalibrated, Err(StoreError::InvalidRequest(_))));
    let mismatched = store.record_speaker_diarization(
        session,
        open_scribe_diarize::ALGORITHM_ID,
        open_scribe_diarize::CLUSTERING_UNAVAILABLE,
        open_scribe_diarize::UNAVAILABLE_REASON,
        &[SpeakerDiarizationTrackInput {
            track_id: track.track_id.clone(),
            disposition: "topology".into(),
        }],
    );
    assert!(matches!(mismatched, Err(StoreError::InvalidRequest(_))));
    drop(store);
    let third = library.prepare_speaker_diarization(session).unwrap();
    assert!(!third.inserted);
    assert_eq!(third.run_id, first.run_id);
    assert_eq!(file_sha256(&prepared.media), prepared.digest_sha256);
}
