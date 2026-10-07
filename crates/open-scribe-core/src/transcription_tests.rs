use std::fs::File;
use std::io::Write;
use std::path::{Path, PathBuf};

use open_scribe_asr::{HypothesisSegment, Language, RECONCILIATION_VERSION, RecognizerIdentity};
use open_scribe_store::{ImportMediaRequest, TranscriptionRunIdentity};
use sha2::{Digest, Sha256};
use tempfile::TempDir;

use super::*;

pub(crate) const SECOND: i64 = 1_000_000_000;
pub(crate) const BURSTS_SECONDS: [f64; 3] = [5.0, 25.0, 60.0];
const BURST_LENGTH_SECONDS: f64 = 1.5;

/// Test-only recognizer: reports each sustained tone burst as one segment.
/// It is deterministic evidence plumbing, never a product capability.
pub(crate) struct BurstRecognizer {
    identity: RecognizerIdentity,
    calls: usize,
    fail_on_call: Option<(usize, RecognizerError)>,
}

impl BurstRecognizer {
    pub(crate) fn new(model_sha256: &str) -> Self {
        Self {
            identity: RecognizerIdentity {
                engine: "burst-fixture".into(),
                engine_version: "1".into(),
                model_id: "burst-model".into(),
                model_sha256: model_sha256.into(),
            },
            calls: 0,
            fail_on_call: None,
        }
    }

    pub(crate) fn failing(model_sha256: &str, call: usize, error: RecognizerError) -> Self {
        Self {
            fail_on_call: Some((call, error)),
            ..Self::new(model_sha256)
        }
    }
}

impl SpeechRecognizer for BurstRecognizer {
    fn identity(&self) -> &RecognizerIdentity {
        &self.identity
    }

    fn transcribe(
        &mut self,
        audio: &[f32],
        _options: &DecodeOptions,
        cancel: &AtomicBool,
    ) -> Result<Hypothesis, RecognizerError> {
        self.calls += 1;
        if let Some((call, error)) = self.fail_on_call
            && call == self.calls
        {
            if error == RecognizerError::Cancelled {
                cancel.store(true, Ordering::Release);
            }
            return Err(error);
        }
        assert!(audio.len() <= 30 * MODEL_SAMPLE_RATE_HZ as usize);
        let frame = MODEL_SAMPLE_RATE_HZ as usize / 10;
        let mut segments = Vec::new();
        let mut open: Option<usize> = None;
        for (index, window) in audio.chunks(frame).enumerate() {
            let rms = (window.iter().map(|value| value * value).sum::<f32>() / window.len() as f32)
                .sqrt();
            match (rms > 0.05, open) {
                (true, None) => open = Some(index),
                (false, Some(start)) => {
                    segments.push(segment(start, index));
                    open = None;
                }
                _ => {}
            }
        }
        if let Some(start) = open {
            segments.push(segment(start, audio.len().div_ceil(frame)));
        }
        Ok(Hypothesis {
            language: "en".into(),
            segments,
        })
    }
}

fn segment(start_frame: usize, end_frame: usize) -> HypothesisSegment {
    HypothesisSegment {
        start_ms: (start_frame * 100) as u32,
        end_ms: (end_frame * 100) as u32,
        text: "burst".into(),
        mean_probability: Some(0.9),
        no_speech_probability: Some(0.0),
    }
}

pub(crate) struct Imported {
    _temp: TempDir,
    pub(crate) root: PathBuf,
    pub(crate) store: SessionStore,
    pub(crate) session: SessionId,
    pub(crate) track: String,
    pub(crate) media: PathBuf,
}

pub(crate) fn imported(seconds: u64) -> Imported {
    let temp = TempDir::new().unwrap();
    let source = temp.path().join("bursts.caf");
    write_burst_caf(&source, seconds * u64::from(SOURCE_SAMPLE_RATE_HZ));
    let root = temp.path().join("Open Scribe");
    let mut store = SessionStore::open(&root).unwrap();
    let evidence = store
        .import_recoverable_caf(ImportMediaRequest {
            title: "Bursts".into(),
            source_path: source,
        })
        .unwrap();
    let track = store
        .transcription_tracks(&evidence.session_id)
        .unwrap()
        .remove(0);
    let media = root
        .join("Sessions")
        .join(&evidence.session_id.0)
        .join(&evidence.relative_path);
    Imported {
        _temp: temp,
        root,
        store,
        session: evidence.session_id,
        track,
        media,
    }
}

pub(crate) fn write_burst_caf(path: &Path, frames: u64) {
    let mut file = File::create(path).unwrap();
    file.write_all(b"caff\0\x01\0\0desc").unwrap();
    file.write_all(&32_i64.to_be_bytes()).unwrap();
    file.write_all(&48_000_f64.to_bits().to_be_bytes()).unwrap();
    file.write_all(b"lpcm").unwrap();
    for value in [2_u32, 2, 1, 1, 16] {
        file.write_all(&value.to_be_bytes()).unwrap();
    }
    file.write_all(b"data").unwrap();
    file.write_all(&(-1_i64).to_be_bytes()).unwrap();
    file.write_all(&0_u32.to_be_bytes()).unwrap();
    let rate = f64::from(SOURCE_SAMPLE_RATE_HZ);
    let bytes: Vec<u8> = (0..frames)
        .flat_map(|frame| {
            let time = frame as f64 / rate;
            let active = BURSTS_SECONDS
                .iter()
                .any(|start| time >= *start && time < start + BURST_LENGTH_SECONDS);
            let value = if active {
                ((2.0 * std::f64::consts::PI * 1_000.0 * time).sin() * 12_000.0) as i16
            } else {
                0
            };
            value.to_le_bytes()
        })
        .collect();
    file.write_all(&bytes).unwrap();
    file.sync_all().unwrap();
}

fn digest(path: &Path) -> Vec<u8> {
    Sha256::digest(std::fs::read(path).unwrap()).to_vec()
}

pub(crate) fn run(
    imported: &mut Imported,
    recognizer: &mut BurstRecognizer,
) -> Result<TranscriptionOutcome, TranscriptionError> {
    transcribe_track(
        &mut imported.store,
        recognizer,
        &DecodeOptions::final_pass(Language::English),
        &imported.session,
        &imported.track,
        &AtomicBool::new(false),
        &mut |_| {},
    )
}

#[test]
fn final_transcript_aligns_to_media_time_and_leaves_sealed_audio_unchanged() {
    let mut imported = imported(90);
    let before = digest(&imported.media);
    let mut stages = Vec::new();
    let outcome = transcribe_track(
        &mut imported.store,
        &mut BurstRecognizer::new(&"a".repeat(64)),
        &DecodeOptions::final_pass(Language::English),
        &imported.session,
        &imported.track,
        &AtomicBool::new(false),
        &mut |progress| stages.push(progress),
    )
    .unwrap();
    assert_eq!(
        (
            outcome.transcribed_chunks,
            outcome.reused_chunks,
            outcome.resumed
        ),
        (4, 0, false)
    );
    assert_eq!(outcome.segment_count, 3);
    assert_eq!(outcome.rejections.overlap_duplicates, 0);

    let transcript = imported
        .store
        .selected_transcript(&imported.session)
        .unwrap();
    assert_eq!(transcript.len(), 3);
    for (segment, expected) in transcript.iter().zip(BURSTS_SECONDS) {
        let expected_start = (expected * SECOND as f64) as i64;
        let expected_end = ((expected + BURST_LENGTH_SECONDS) * SECOND as f64) as i64;
        assert!(
            (segment.start_nanoseconds - expected_start).abs() <= SECOND / 5,
            "{segment:?}"
        );
        assert!(
            (segment.end_nanoseconds - expected_end).abs() <= SECOND / 5,
            "{segment:?}"
        );
        assert_eq!(segment.revision_id, outcome.revision_id);
    }
    let last = stages.last().unwrap();
    assert_eq!(last.stage, TranscriptionStage::Reconciling);
    assert_eq!(last.completed_nanoseconds, last.required_nanoseconds);
    assert_eq!(digest(&imported.media), before);
}

#[test]
fn engine_failure_ends_only_the_run_and_retry_reuses_committed_chunks() {
    let mut imported = imported(90);
    let before = digest(&imported.media);
    let model = "a".repeat(64);
    let failed = run(
        &mut imported,
        &mut BurstRecognizer::failing(&model, 3, RecognizerError::Engine("injected")),
    );
    let Err(TranscriptionError::RunEnded { run_id, failure }) = failed else {
        panic!("engine failure must end the run");
    };
    assert_eq!(failure, TranscriptionFailure::EngineError);
    assert!(
        imported
            .store
            .selected_transcript(&imported.session)
            .unwrap()
            .is_empty()
    );
    let runs = imported
        .store
        .transcription_runs(&imported.session)
        .unwrap();
    assert_eq!(
        (runs[0].run_id.as_str(), runs[0].state.as_str()),
        (run_id.as_str(), "failed")
    );
    assert_eq!(runs[0].completed_chunks, 2);
    assert_eq!(digest(&imported.media), before);

    let retry = run(&mut imported, &mut BurstRecognizer::new(&model)).unwrap();
    assert_eq!((retry.reused_chunks, retry.transcribed_chunks), (2, 2));
    assert_eq!(
        imported
            .store
            .selected_transcript(&imported.session)
            .unwrap()
            .len(),
        3
    );
    let runs = imported
        .store
        .transcription_runs(&imported.session)
        .unwrap();
    assert_eq!(runs[0].state, "failed");
    assert_eq!(runs[1].state, "complete");
}

#[test]
fn cancelled_replacement_keeps_the_selected_revision_until_a_replacement_completes() {
    let mut imported = imported(60);
    let first = run(&mut imported, &mut BurstRecognizer::new(&"a".repeat(64))).unwrap();
    let replacement_model = "b".repeat(64);
    let cancelled = run(
        &mut imported,
        &mut BurstRecognizer::failing(&replacement_model, 2, RecognizerError::Cancelled),
    );
    assert!(matches!(
        cancelled,
        Err(TranscriptionError::RunEnded {
            failure: TranscriptionFailure::Cancelled,
            ..
        })
    ));
    let selected = imported
        .store
        .selected_transcript(&imported.session)
        .unwrap();
    assert!(!selected.is_empty());
    assert!(
        selected
            .iter()
            .all(|segment| segment.revision_id == first.revision_id)
    );

    let second = run(&mut imported, &mut BurstRecognizer::new(&replacement_model)).unwrap();
    assert_eq!(second.reused_chunks, 1);
    assert_ne!(second.revision_id, first.revision_id);
    let selected = imported
        .store
        .selected_transcript(&imported.session)
        .unwrap();
    assert!(
        selected
            .iter()
            .all(|segment| segment.revision_id == second.revision_id)
    );
    assert_eq!(
        imported
            .store
            .transcript_revision_segments(&first.revision_id)
            .unwrap()
            .len(),
        selected.len()
    );
}

#[test]
fn a_run_interrupted_by_process_exit_resumes_without_redoing_committed_chunks() {
    let mut imported = imported(60);
    let recognizer = BurstRecognizer::new(&"a".repeat(64));
    let options = DecodeOptions::final_pass(Language::English);
    let input = imported
        .store
        .transcription_input(&imported.session, &imported.track)
        .unwrap();
    let windows = plan_windows(&input);
    let identity = TranscriptionRunIdentity {
        session_id: imported.session.clone(),
        track_id: imported.track.clone(),
        input_digest: input.input_digest.clone(),
        engine: recognizer.identity.engine.clone(),
        engine_version: recognizer.identity.engine_version.clone(),
        model_id: recognizer.identity.model_id.clone(),
        model_sha256: recognizer.identity.model_sha256.clone(),
        options_digest: options.digest(),
        reconciliation_version: RECONCILIATION_VERSION.to_owned(),
    };
    let plan: Vec<_> = windows.iter().map(|window| window.chunk).collect();
    let handle = imported
        .store
        .begin_transcription_run(&identity, &plan)
        .unwrap();
    let empty = serde_json::to_string(&Hypothesis {
        language: "en".into(),
        segments: Vec::new(),
    })
    .unwrap();
    imported
        .store
        .complete_transcript_chunk(&handle.run_id, 0, "en", &empty)
        .unwrap();
    imported
        .store
        .mark_transcript_chunk_running(&handle.run_id, 1)
        .unwrap();
    imported.store = SessionStore::open(&imported.root).unwrap();

    let mut recognizer = recognizer;
    let outcome = run(&mut imported, &mut recognizer).unwrap();
    assert!(outcome.resumed);
    assert_eq!(outcome.run_id, handle.run_id);
    assert_eq!(outcome.transcribed_chunks as usize, windows.len() - 1);
    assert_eq!(recognizer.calls, windows.len() - 1);
}

#[test]
fn windows_cover_each_span_on_the_session_timeline() {
    let imported = imported(60);
    let input = imported
        .store
        .transcription_input(&imported.session, &imported.track)
        .unwrap();
    let windows = plan_windows(&input);
    assert_eq!(windows.first().unwrap().chunk.start_nanoseconds, 0);
    assert_eq!(windows.last().unwrap().chunk.end_nanoseconds, 60 * SECOND);
    assert!(
        windows
            .windows(2)
            .all(|pair| pair[1].chunk.start_nanoseconds < pair[0].chunk.end_nanoseconds)
    );
    assert_eq!(discontinuities(&input), serde_json::json!([]));
}

#[test]
fn finalize_completes_a_run_whose_chunks_are_already_durable() {
    let mut imported = imported(60);
    let model = "a".repeat(64);
    let options = DecodeOptions::final_pass(Language::English);
    let input = imported
        .store
        .transcription_input(&imported.session, &imported.track)
        .unwrap();
    let identity = TranscriptionRunIdentity {
        session_id: imported.session.clone(),
        track_id: imported.track.clone(),
        input_digest: input.input_digest.clone(),
        engine: "burst-fixture".into(),
        engine_version: "1".into(),
        model_id: "burst-model".into(),
        model_sha256: model.clone(),
        options_digest: options.digest(),
        reconciliation_version: RECONCILIATION_VERSION.to_owned(),
    };
    let windows = plan_windows(&input);
    let plan: Vec<_> = windows.iter().map(|w| w.chunk).collect();
    let handle = imported
        .store
        .begin_transcription_run(&identity, &plan)
        .unwrap();
    // Simulate death after every chunk committed, before revision.
    for chunk in &handle.chunks {
        let hypothesis = Hypothesis {
            language: "en".into(),
            segments: vec![HypothesisSegment {
                start_ms: 100,
                end_ms: 500,
                text: "burst".into(),
                mean_probability: Some(0.9),
                no_speech_probability: Some(0.0),
            }],
        };
        let json = serde_json::to_string(&hypothesis).unwrap();
        imported
            .store
            .complete_transcript_chunk(&handle.run_id, chunk.sequence, "en", &json)
            .unwrap();
    }
    assert!(
        imported
            .store
            .transcript_revisions(&imported.session)
            .unwrap()
            .is_empty()
    );

    let (revision_id, segment_count, _) =
        finalize_transcription_run(&mut imported.store, &handle.run_id).unwrap();
    assert!(!revision_id.is_empty());
    assert!(segment_count >= 1);
    let runs = imported
        .store
        .transcription_runs(&imported.session)
        .unwrap();
    assert_eq!(runs[0].state, "complete");
    assert_eq!(runs[0].failure_class, None);
    assert_eq!(
        imported
            .store
            .transcript_revisions(&imported.session)
            .unwrap()
            .len(),
        1
    );

    // Second finalize is a no-op failure path: run is no longer running.
    assert!(matches!(
        finalize_transcription_run(&mut imported.store, &handle.run_id),
        Err(TranscriptionError::Store(_)) | Err(TranscriptionError::RunEnded { .. })
    ));
}

#[test]
fn launch_recovery_finalizes_class_a_orphans_without_recognizer() {
    let mut imported = imported(60);
    let model = "a".repeat(64);
    let options = DecodeOptions::final_pass(Language::English);
    let input = imported
        .store
        .transcription_input(&imported.session, &imported.track)
        .unwrap();
    let identity = TranscriptionRunIdentity {
        session_id: imported.session.clone(),
        track_id: imported.track.clone(),
        input_digest: input.input_digest.clone(),
        engine: "burst-fixture".into(),
        engine_version: "1".into(),
        model_id: "burst-model".into(),
        model_sha256: model,
        options_digest: options.digest(),
        reconciliation_version: RECONCILIATION_VERSION.to_owned(),
    };
    let windows = plan_windows(&input);
    let plan: Vec<_> = windows.iter().map(|w| w.chunk).collect();
    let handle = imported
        .store
        .begin_transcription_run(&identity, &plan)
        .unwrap();
    for chunk in &handle.chunks {
        let hypothesis = Hypothesis {
            language: "en".into(),
            segments: vec![HypothesisSegment {
                start_ms: 100,
                end_ms: 500,
                text: "burst".into(),
                mean_probability: Some(0.9),
                no_speech_probability: Some(0.0),
            }],
        };
        let json = serde_json::to_string(&hypothesis).unwrap();
        imported
            .store
            .complete_transcript_chunk(&handle.run_id, chunk.sequence, "en", &json)
            .unwrap();
    }
    let root = imported.root.clone();
    let session = imported.session.clone();
    let Imported {
        _temp,
        store,
        ..
    } = imported;
    drop(store);

    let mut controller = crate::RecordingPreparationController::open(&root).unwrap();
    let _playable = controller.recover_playable_sessions().unwrap();
    let store = SessionStore::open(&root).unwrap();
    let runs = store.transcription_runs(&session).unwrap();
    assert_eq!(runs.len(), 1);
    assert_eq!(runs[0].state, "complete");
    assert!(runs[0].failure_class.is_none());
    assert_eq!(store.transcript_revisions(&session).unwrap().len(), 1);
    drop(_temp);
}

#[test]
fn commit_failure_after_complete_chunks_fails_the_run_closed() {
    let mut imported = imported(60);
    let model = "a".repeat(64);
    let options = DecodeOptions::final_pass(Language::English);
    let input = imported
        .store
        .transcription_input(&imported.session, &imported.track)
        .unwrap();
    let identity = TranscriptionRunIdentity {
        session_id: imported.session.clone(),
        track_id: imported.track.clone(),
        input_digest: input.input_digest.clone(),
        engine: "burst-fixture".into(),
        engine_version: "1".into(),
        model_id: "burst-model".into(),
        model_sha256: model,
        options_digest: options.digest(),
        reconciliation_version: RECONCILIATION_VERSION.to_owned(),
    };
    let windows = plan_windows(&input);
    let plan: Vec<_> = windows.iter().map(|w| w.chunk).collect();
    let handle = imported
        .store
        .begin_transcription_run(&identity, &plan)
        .unwrap();
    // Persist complete chunks whose JSON is not a Hypothesis — finalize must
    // fail closed rather than leave the run forever-running.
    for chunk in &handle.chunks {
        imported
            .store
            .complete_transcript_chunk(
                &handle.run_id,
                chunk.sequence,
                "en",
                r#"{"not":"a-hypothesis"}"#,
            )
            .unwrap();
    }
    let err = finalize_transcription_run(&mut imported.store, &handle.run_id).unwrap_err();
    assert!(matches!(
        err,
        TranscriptionError::RunEnded {
            failure: TranscriptionFailure::InvalidResult,
            ..
        }
    ));
    let runs = imported
        .store
        .transcription_runs(&imported.session)
        .unwrap();
    assert_eq!(runs[0].state, "failed");
    assert_eq!(runs[0].failure_class.as_deref(), Some("invalid_result"));
}
