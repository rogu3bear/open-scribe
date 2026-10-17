use std::fs::File;
use std::io::Write;
use std::path::{Path, PathBuf};

use open_scribe_asr::{HypothesisSegment, Language, RECONCILIATION_VERSION, RecognizerIdentity};
use open_scribe_store::{ImportMediaRequest, TranscriptionRunHandle, TranscriptionRunIdentity};
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
fn retry_restart_and_recovery_preserve_a_corrected_final_companion_track() {
    for boundary in ["retry", "restart", "capture-safety-recovery"] {
        let temp = TempDir::new().unwrap();
        let (mut store, session, _) = crate::package_import_tests::captured(&temp);
        let tracks = store.transcription_tracks(&session).unwrap();
        let options = DecodeOptions::final_pass(Language::English);
        let model = "a".repeat(64);
        let first = transcribe_track(
            &mut store,
            &mut BurstRecognizer::new(&model),
            &options,
            &session,
            &tracks[0],
            &AtomicBool::new(false),
            &mut |_| {},
        )
        .unwrap();
        store
            .correct_transcript_segment(&session, &first.revision_id, 0, Some("Reviewed alpha"))
            .unwrap();
        let before = store.transcript_document(&session).unwrap();
        let runs_before = store
            .transcription_runs(&session)
            .unwrap()
            .into_iter()
            .filter(|run| run.track_id == tracks[0])
            .collect::<Vec<_>>();
        let revisions_before = store
            .transcript_revisions(&session)
            .unwrap()
            .into_iter()
            .filter(|revision| revision.track_id == tracks[0])
            .collect::<Vec<_>>();
        let database =
            rusqlite::Connection::open(temp.path().join("Open Scribe/Library.sqlite3")).unwrap();
        let correction_ids = || {
            database
                .prepare("SELECT id FROM transcript_corrections ORDER BY id")
                .unwrap()
                .query_map([], |r| r.get::<_, String>(0))
                .unwrap()
                .map(Result::unwrap)
                .collect::<Vec<_>>()
        };
        let ids_before = correction_ids();
        assert!(
            transcribe_track(
                &mut store,
                &mut BurstRecognizer::failing(&model, 1, RecognizerError::Engine("injected")),
                &options,
                &session,
                &tracks[1],
                &AtomicBool::new(false),
                &mut |_| {}
            )
            .is_err()
        );
        if boundary != "retry" {
            store = SessionStore::open(temp.path().join("Open Scribe")).unwrap();
        }
        if boundary == "capture-safety-recovery" {
            store.recover_library().unwrap();
        }
        let plan = crate::plan_session_transcription(
            &store,
            &session,
            crate::TranscriptionIntent::ResumeIncomplete,
        )
        .unwrap();
        assert_eq!(plan.tracks.len(), 1);
        assert_eq!(plan.tracks[0].track_id, tracks[1]);
        crate::execute_transcription_plan(
            &mut store,
            Some(&mut BurstRecognizer::new(&model)),
            &options,
            &plan,
            None,
            &AtomicBool::new(false),
            &mut |_, _, _| {},
        )
        .unwrap();
        assert_eq!(
            store
                .transcript_document(&session)
                .unwrap()
                .into_iter()
                .filter(|part| part.track_id == tracks[0])
                .collect::<Vec<_>>(),
            before
        );
        assert_eq!(
            store
                .transcription_runs(&session)
                .unwrap()
                .into_iter()
                .filter(|run| run.track_id == tracks[0])
                .collect::<Vec<_>>(),
            runs_before
        );
        assert_eq!(
            store
                .transcript_revisions(&session)
                .unwrap()
                .into_iter()
                .filter(|revision| revision.track_id == tracks[0])
                .collect::<Vec<_>>(),
            revisions_before
        );
        assert_eq!(correction_ids(), ids_before);
        assert_eq!(
            store
                .search_transcripts("Reviewed alpha", Some(&session), 10)
                .unwrap()[0]
                .revision_id,
            first.revision_id
        );
    }
}

#[test]
fn retained_reconciliation_needs_no_model_and_explicit_reprocess_has_a_selection_guard() {
    let mut imported = imported(6);
    let run = complete_fixture_chunks(&mut imported.store, &imported.session, &imported.track);
    let plan = crate::plan_session_transcription(
        &imported.store,
        &imported.session,
        crate::TranscriptionIntent::ReconcileRetained,
    )
    .unwrap();
    assert!(!plan.needs_recognizer());
    let outcomes = crate::execute_transcription_plan(
        &mut imported.store,
        None,
        &DecodeOptions::final_pass(Language::English),
        &plan,
        None,
        &AtomicBool::new(false),
        &mut |_, _, _| {},
    )
    .unwrap();
    assert_eq!(outcomes[0].run_id, run);
    assert_eq!(outcomes[0].transcribed_chunks, 0);
    let before = imported
        .store
        .transcript_revisions(&imported.session)
        .unwrap();
    let resume = crate::plan_session_transcription(
        &imported.store,
        &imported.session,
        crate::TranscriptionIntent::ResumeIncomplete,
    )
    .unwrap();
    assert!(resume.tracks.is_empty());
    let reprocess = crate::plan_session_transcription(
        &imported.store,
        &imported.session,
        crate::TranscriptionIntent::ReprocessAll,
    )
    .unwrap();
    assert_eq!(reprocess.tracks.len(), 1);
    assert!(!reprocess.needs_recognizer());
    let next = crate::execute_transcription_plan(
        &mut imported.store,
        None,
        &DecodeOptions::final_pass(Language::English),
        &reprocess,
        None,
        &AtomicBool::new(false),
        &mut |_, _, _| {},
    )
    .unwrap();
    let revisions = imported
        .store
        .transcript_revisions(&imported.session)
        .unwrap();
    assert_eq!(revisions.len(), before.len() + 1);
    assert!(
        revisions
            .iter()
            .any(|revision| revision.revision_id == next[0].revision_id && revision.selected)
    );
    assert!(
        revisions
            .iter()
            .any(|revision| revision.revision_id == before[0].revision_id && !revision.selected)
    );
}

#[test]
fn queued_replacement_cannot_override_an_edit_made_before_model_loading() {
    use open_scribe_types::{TranscriptionIntent, WorkObservations};
    let mut fixture = imported(6);
    let first = run(&mut fixture, &mut BurstRecognizer::new(&"a".repeat(64))).unwrap();
    let before = fixture
        .store
        .runtime_library_snapshot()
        .unwrap()
        .saved_sessions[0]
        .transcript
        .clone();
    fixture
        .store
        .request_transcription(&fixture.session, TranscriptionIntent::ReprocessAll)
        .unwrap();
    fixture
        .store
        .correct_transcript_segment(
            &fixture.session,
            &first.revision_id,
            0,
            Some("Reviewed before loading"),
        )
        .unwrap();
    let reviewed = fixture.store.transcript_document(&fixture.session).unwrap();
    let after_edit = fixture
        .store
        .runtime_library_snapshot()
        .unwrap()
        .saved_sessions[0]
        .transcript
        .clone();
    assert_ne!(before.document_version, after_edit.document_version);
    let claim = fixture
        .store
        .admit_transcription(WorkObservations::default())
        .unwrap()
        .unwrap();
    let operation = fixture
        .store
        .transcription_operation(&fixture.session, claim.admission.as_deref().unwrap())
        .unwrap();
    let plan = crate::plan_transcription_operation(
        &fixture.store,
        &fixture.session,
        claim.intent,
        &operation,
    )
    .unwrap();
    assert!(
        !plan.needs_recognizer(),
        "compatible complete hypotheses need no installed model"
    );
    let completed = crate::execute_transcription_plan(
        &mut fixture.store,
        None,
        &DecodeOptions::final_pass(Language::English),
        &plan,
        None,
        &AtomicBool::new(false),
        &mut |_, _, _| {},
    )
    .unwrap();
    assert_eq!(
        fixture.store.transcript_document(&fixture.session).unwrap(),
        reviewed
    );
    let revisions = fixture
        .store
        .transcript_revisions(&fixture.session)
        .unwrap();
    assert!(
        revisions
            .iter()
            .any(|r| r.revision_id == first.revision_id && r.selected)
    );
    assert!(
        revisions
            .iter()
            .any(|r| r.revision_id == completed[0].revision_id && !r.selected)
    );
    assert_eq!(
        fixture
            .store
            .search_transcripts("Reviewed before loading", Some(&fixture.session), 10)
            .unwrap()[0]
            .revision_id,
        first.revision_id
    );
    assert_eq!(
        fixture
            .store
            .runtime_library_snapshot()
            .unwrap()
            .saved_sessions[0]
            .transcript
            .document_version,
        after_edit.document_version
    );
}

#[test]
fn deliberate_replacement_resumes_only_unfinished_tracks_with_its_original_guards() {
    use open_scribe_types::{TranscriptionIntent, WorkObservations, WorkOutcome};
    for boundary in ["capture-preempted", "restart", "failed"] {
        let temp = TempDir::new().unwrap();
        let (mut store, session, _) = crate::package_import_tests::captured(&temp);
        let tracks = store.transcription_tracks(&session).unwrap();
        let options = DecodeOptions::final_pass(Language::English);
        for track in &tracks {
            transcribe_track(
                &mut store,
                &mut BurstRecognizer::new(&"a".repeat(64)),
                &options,
                &session,
                track,
                &AtomicBool::new(false),
                &mut |_| {},
            )
            .unwrap();
        }
        store
            .request_transcription(&session, TranscriptionIntent::ReprocessAll)
            .unwrap();
        let first_claim = store
            .admit_transcription(WorkObservations::default())
            .unwrap()
            .unwrap();
        let token = first_claim.admission.as_deref().unwrap();
        let operation = store.transcription_operation(&session, token).unwrap();
        let mut first_plan =
            crate::plan_transcription_operation(&store, &session, first_claim.intent, &operation)
                .unwrap();
        assert_eq!(first_plan.tracks.len(), 2);
        first_plan.tracks.truncate(1);
        let completed = crate::execute_transcription_plan(
            &mut store,
            None,
            &options,
            &first_plan,
            None,
            &AtomicBool::new(false),
            &mut |_, _, _| {},
        )
        .unwrap();
        let track_a = first_plan.tracks[0].track_id.clone();
        store
            .correct_transcript_segment(
                &session,
                &completed[0].revision_id,
                0,
                Some("Reviewed replacement A"),
            )
            .unwrap();
        let reviewed = store.transcript_document(&session).unwrap();
        let run_count = store
            .transcription_runs(&session)
            .unwrap()
            .iter()
            .filter(|r| r.track_id == track_a)
            .count();
        let revision_count = store
            .transcript_revisions(&session)
            .unwrap()
            .iter()
            .filter(|r| r.track_id == track_a)
            .count();
        if boundary != "restart" {
            store
                .finish_transcription(
                    token,
                    if boundary == "failed" {
                        WorkOutcome::Failed
                    } else {
                        WorkOutcome::CapturePreempted
                    },
                )
                .unwrap();
        }
        store = SessionStore::open(temp.path().join("Open Scribe")).unwrap();
        if boundary == "restart" {
            store.recover_transcription_admissions().unwrap();
        }
        if boundary == "failed" {
            store.resume_replacement(&session).unwrap();
        }
        let next = store
            .admit_transcription(WorkObservations {
                automatic: false,
                paused: true,
                ..Default::default()
            })
            .unwrap()
            .unwrap();
        assert!(next.manual);
        let resumed = store
            .transcription_operation(&session, next.admission.as_deref().unwrap())
            .unwrap();
        assert_eq!(resumed.key, operation.key);
        assert_eq!(resumed.selections, operation.selections);
        let plan =
            crate::plan_transcription_operation(&store, &session, next.intent, &resumed).unwrap();
        assert_eq!(
            plan.tracks.len(),
            1,
            "already finished replacement A must be skipped at {boundary}"
        );
        assert_ne!(plan.tracks[0].track_id, track_a);
        crate::execute_transcription_plan(
            &mut store,
            None,
            &options,
            &plan,
            None,
            &AtomicBool::new(false),
            &mut |_, _, _| {},
        )
        .unwrap();
        assert_eq!(
            store
                .transcription_runs(&session)
                .unwrap()
                .iter()
                .filter(|r| r.track_id == track_a)
                .count(),
            run_count
        );
        assert_eq!(
            store
                .transcript_revisions(&session)
                .unwrap()
                .iter()
                .filter(|r| r.track_id == track_a)
                .count(),
            revision_count
        );
        assert_eq!(
            store
                .transcript_document(&session)
                .unwrap()
                .into_iter()
                .filter(|r| r.track_id == track_a)
                .collect::<Vec<_>>(),
            reviewed
                .into_iter()
                .filter(|r| r.track_id == track_a)
                .collect::<Vec<_>>()
        );
    }
}

#[test]
fn cancelled_complete_chunks_are_not_selected_by_restart_maintenance() {
    let mut fixture = imported(6);
    let run = complete_fixture_chunks(&mut fixture.store, &fixture.session, &fixture.track);
    fixture
        .store
        .cancel_transcription(&fixture.session)
        .unwrap();
    let mut recovery = crate::RecordingPreparationController::open(&fixture.root).unwrap();
    recovery.recover_capture_safety().unwrap();
    recovery
        .maintain_transcripts(&AtomicBool::new(false))
        .unwrap();
    let reopened = SessionStore::open(&fixture.root).unwrap();
    assert!(
        reopened
            .transcript_revisions(&fixture.session)
            .unwrap()
            .is_empty()
    );
    assert_eq!(
        reopened.transcription_run_record(&run).unwrap().state,
        "cancelled"
    );
    assert!(
        reopened
            .retained_transcript_candidates(RECONCILIATION_VERSION)
            .unwrap()
            .is_empty()
    );
}

#[test]
fn recognition_compute_releases_write_admission_and_durable_capture_preempts_completion() {
    use std::sync::mpsc;
    use std::time::Duration;
    struct BlockedRecognizer {
        inner: BurstRecognizer,
        entered: mpsc::Sender<()>,
        release: mpsc::Receiver<()>,
    }
    impl SpeechRecognizer for BlockedRecognizer {
        fn identity(&self) -> &RecognizerIdentity {
            self.inner.identity()
        }
        fn transcribe(
            &mut self,
            audio: &[f32],
            options: &DecodeOptions,
            cancel: &AtomicBool,
        ) -> Result<Hypothesis, RecognizerError> {
            self.entered.send(()).unwrap();
            self.release.recv_timeout(Duration::from_secs(15)).unwrap();
            self.inner.transcribe(audio, options, cancel)
        }
    }
    let fixture = imported(6);
    let root = fixture.root.clone();
    let session = fixture.session.clone();
    let track = fixture.track.clone();
    let (entered_tx, entered_rx) = mpsc::channel();
    let (release_tx, release_rx) = mpsc::channel();
    let worker = std::thread::spawn(move || {
        let mut store = SessionStore::open(root).unwrap();
        let mut recognizer = BlockedRecognizer {
            inner: BurstRecognizer::new(&"a".repeat(64)),
            entered: entered_tx,
            release: release_rx,
        };
        transcribe_track(
            &mut store,
            &mut recognizer,
            &DecodeOptions::final_pass(Language::English),
            &session,
            &track,
            &AtomicBool::new(false),
            &mut |_| {},
        )
    });
    entered_rx.recv_timeout(Duration::from_secs(10)).unwrap();
    let root = fixture.root.clone();
    let (committed_tx, committed_rx) = mpsc::channel();
    let capture = std::thread::spawn(move || {
        let mut store = SessionStore::open(root).unwrap();
        let result = store.prepare_session(open_scribe_store::PrepareSessionRequest {
            title: "Deliberate capture admission".into(),
            origin: open_scribe_store::SessionOrigin::Capture,
        });
        committed_tx.send(result.is_ok()).unwrap();
        result
    });
    let admitted_while_recognizer_blocked = committed_rx.recv_timeout(Duration::from_secs(5));
    release_tx.send(()).unwrap(); // always release before asserting, including failure
    capture.join().unwrap().unwrap();
    let result = worker.join().unwrap();
    assert!(admitted_while_recognizer_blocked.unwrap());
    assert!(matches!(
        result,
        Err(TranscriptionError::Preempted)
            | Err(TranscriptionError::RunEnded {
                failure: TranscriptionFailure::CapturePreempted,
                ..
            })
    ));
    assert!(
        fixture
            .store
            .transcript_revisions(&fixture.session)
            .unwrap()
            .is_empty()
    );
}

#[test]
fn metadata_and_wall_clock_changes_do_not_change_a_timed_capture_or_seek_plan() {
    let temp = TempDir::new().unwrap();
    let (mut store, session, _) = crate::package_import_tests::captured(&temp);
    let before = store
        .runtime_library_snapshot()
        .unwrap()
        .saved_sessions
        .remove(0);
    let timeline = store.playback_timeline(&session).unwrap();
    let modified = store.metadata_modified_at(&session).unwrap();
    store
        .rename_session(&session, "Reviewed conversation")
        .unwrap();
    store
        .declare_session(
            session.clone(),
            open_scribe_store::SessionDeclaration {
                participants: vec!["Alex".into()],
                topic: Some("Plan".into()),
            },
        )
        .unwrap();
    assert!(store.metadata_modified_at(&session).unwrap() > modified);
    let database =
        rusqlite::Connection::open(temp.path().join("Open Scribe/Library.sqlite3")).unwrap();
    database
        .execute(
            "UPDATE sessions SET updated_at_ms = updated_at_ms + 86400000 WHERE id = ?1",
            [&session.0],
        )
        .unwrap();
    let after = store
        .runtime_library_snapshot()
        .unwrap()
        .saved_sessions
        .remove(0);
    assert_eq!(after.elapsed_seconds, before.elapsed_seconds);
    assert_eq!(store.playback_timeline(&session).unwrap(), timeline);
}

#[test]
fn transcript_only_failure_leaves_capture_safety_results_and_playback_available() {
    let temp = TempDir::new().unwrap();
    let (mut store, session, track) = crate::package_import_tests::captured(&temp);
    complete_fixture_chunks(&mut store, &session, &track);
    let mut controller =
        crate::RecordingPreparationController::open(temp.path().join("Open Scribe")).unwrap();
    let media = controller.recover_capture_safety().unwrap();
    let snapshot = controller.runtime_library_snapshot().unwrap();
    let database =
        rusqlite::Connection::open(temp.path().join("Open Scribe/Library.sqlite3")).unwrap();
    database.execute_batch("CREATE TRIGGER transcript_only_failure BEFORE INSERT ON transcript_revisions BEGIN SELECT RAISE(ABORT, 'derived-only failure'); END;").unwrap();
    assert!(
        controller
            .maintain_transcripts(&AtomicBool::new(false))
            .is_err()
    );
    assert_eq!(
        controller
            .runtime_library_snapshot()
            .unwrap()
            .saved_sessions
            .len(),
        snapshot.saved_sessions.len()
    );
    assert!(!store.playback_timeline(&session).unwrap().is_empty());
    assert!(
        media.pending_transcript_finalizations.is_empty(),
        "media result has no derived-work return dependency"
    );
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
fn corrected_reconciliation_reuses_failed_run_chunks_and_commits_in_order() {
    let mut imported = imported(60);
    let input = imported
        .store
        .transcription_input(&imported.session, &imported.track)
        .unwrap();
    let mut identity = TranscriptionRunIdentity {
        session_id: imported.session.clone(),
        track_id: imported.track.clone(),
        input_digest: input.input_digest.clone(),
        engine: "burst-fixture".into(),
        engine_version: "1".into(),
        model_id: "burst-model".into(),
        model_sha256: "a".repeat(64),
        options_digest: DecodeOptions::final_pass(Language::English).digest(),
        reconciliation_version: "overlap-midpoint-v2".into(),
    };
    let windows = plan_windows(&input);
    let plan: Vec<_> = windows.iter().map(|w| w.chunk).collect();
    assert_eq!(plan[1].start_nanoseconds, 23 * SECOND);
    let old = imported
        .store
        .begin_transcription_run(&identity, &plan)
        .unwrap();
    for chunk in &old.chunks {
        let segments = match chunk.sequence {
            0 => vec![HypothesisSegment {
                start_ms: 25_400,
                end_ms: 25_500,
                text: "short left".into(),
                mean_probability: Some(0.9),
                no_speech_probability: Some(0.0),
            }],
            1 => vec![HypothesisSegment {
                start_ms: 1_280,
                end_ms: 4_480,
                text: "long right".into(),
                mean_probability: Some(0.9),
                no_speech_probability: Some(0.0),
            }],
            _ => vec![],
        };
        let hypothesis = Hypothesis {
            language: "en".into(),
            segments,
        };
        imported
            .store
            .complete_transcript_chunk(
                &old.run_id,
                chunk.sequence,
                "en",
                &serde_json::to_string(&hypothesis).unwrap(),
            )
            .unwrap();
    }
    let preserved = imported
        .store
        .transcript_chunks_for_run(&old.run_id)
        .unwrap();
    imported
        .store
        .fail_transcription_run(&old.run_id, None, TranscriptionFailure::InvalidResult)
        .unwrap();
    identity.reconciliation_version = RECONCILIATION_VERSION.into();
    let successor = imported
        .store
        .begin_transcription_run(&identity, &plan)
        .unwrap();
    assert_ne!(successor.run_id, old.run_id);
    assert!(
        successor
            .chunks
            .iter()
            .all(|c| c.state == TranscriptChunkState::Complete
                && c.reused_from_run.as_deref() == Some(old.run_id.as_str()))
    );
    let (revision, count, rejections) =
        finalize_transcription_run(&mut imported.store, &successor.run_id).unwrap();
    assert_eq!(count, 2);
    assert_eq!(rejections, open_scribe_asr::Rejections::default());
    let selected = imported
        .store
        .selected_transcript(&imported.session)
        .unwrap();
    assert_eq!(
        selected.iter().map(|s| s.text.as_str()).collect::<Vec<_>>(),
        ["long right", "short left"]
    );
    assert_eq!(
        selected
            .iter()
            .map(|s| s.start_nanoseconds)
            .collect::<Vec<_>>(),
        [24_280_000_000, 25_400_000_000]
    );
    assert!(selected.iter().all(|s| s.revision_id == revision));
    assert_eq!(
        imported
            .store
            .transcript_chunks_for_run(&old.run_id)
            .unwrap(),
        preserved
    );
    let runs = imported
        .store
        .transcription_runs(&imported.session)
        .unwrap();
    assert_eq!(
        runs.iter().find(|r| r.run_id == old.run_id).unwrap().state,
        "failed"
    );
    assert_eq!(
        runs.iter()
            .find(|r| r.run_id == successor.run_id)
            .unwrap()
            .state,
        "complete"
    );
}

#[test]
fn finalize_refuses_unavailable_input_instead_of_committing_gap_free_success() {
    let mut imported = imported(1);
    let run = complete_fixture_chunks(&mut imported.store, &imported.session, &imported.track);
    let database = rusqlite::Connection::open(imported.root.join("Library.sqlite3")).unwrap();
    // Complete hypotheses outlive a lost sealed-media binding; finalization
    // must not turn that unknown timeline into an empty list of gaps.
    database
        .execute(
            "UPDATE segments SET digest = NULL WHERE track_id = ?1",
            [&imported.track],
        )
        .unwrap();
    assert!(matches!(
        finalize_transcription_run(&mut imported.store, &run),
        Err(TranscriptionError::RunEnded {
            failure: TranscriptionFailure::InvalidResult,
            ..
        })
    ));
    assert!(
        imported
            .store
            .transcript_revisions(&imported.session)
            .unwrap()
            .is_empty()
    );
    let runs = imported
        .store
        .transcription_runs(&imported.session)
        .unwrap();
    assert_eq!(runs[0].state, "failed");
    assert_eq!(runs[0].failure_class.as_deref(), Some("invalid_result"));
}

#[test]
fn finalize_accepts_verified_gapped_input_with_explicit_discontinuities() {
    let temp = TempDir::new().unwrap();
    let (mut store, session, track) = crate::package_import_tests::captured(&temp);
    let input = store.transcription_input(&session, &track).unwrap();
    let gaps = discontinuities(&input);
    assert_ne!(gaps, serde_json::json!([]));
    let run = complete_fixture_chunks(&mut store, &session, &track);
    let (revision, _, _) = finalize_transcription_run(&mut store, &run).unwrap();
    let database =
        rusqlite::Connection::open(temp.path().join("Open Scribe/Library.sqlite3")).unwrap();
    let stored: String = database
        .query_row(
            "SELECT discontinuities_json FROM transcript_revisions WHERE id = ?1",
            [&revision],
            |row| row.get(0),
        )
        .unwrap();
    assert_eq!(
        serde_json::from_str::<serde_json::Value>(&stored).unwrap(),
        gaps
    );
    assert_eq!(
        store.transcription_runs(&session).unwrap()[0].state,
        "complete"
    );
    assert_eq!(
        discontinuities(&store.transcription_input(&session, &track).unwrap()),
        gaps
    );
}

pub(crate) fn complete_fixture_chunks(
    store: &mut SessionStore,
    session: &SessionId,
    track: &str,
) -> String {
    let input = store.transcription_input(session, track).unwrap();
    let identity = TranscriptionRunIdentity {
        session_id: session.clone(),
        track_id: track.to_owned(),
        input_digest: input.input_digest.clone(),
        engine: "burst-fixture".into(),
        engine_version: "1".into(),
        model_id: "burst-model".into(),
        model_sha256: "a".repeat(64),
        options_digest: DecodeOptions::final_pass(Language::English).digest(),
        reconciliation_version: RECONCILIATION_VERSION.to_owned(),
    };
    let plan: Vec<_> = plan_windows(&input)
        .iter()
        .map(|window| window.chunk)
        .collect();
    let handle = store.begin_transcription_run(&identity, &plan).unwrap();
    for chunk in &handle.chunks {
        store
            .complete_transcript_chunk(
                &handle.run_id,
                chunk.sequence,
                "en",
                r#"{"language":"en","segments":[]}"#,
            )
            .unwrap();
    }
    handle.run_id
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
    let Imported { _temp, store, .. } = imported;
    drop(store);

    let mut controller = crate::RecordingPreparationController::open(&root).unwrap();
    let _playable = controller.recover_playable_sessions().unwrap();
    controller
        .maintain_transcripts(&AtomicBool::new(false))
        .unwrap();
    let store = SessionStore::open(&root).unwrap();
    let runs = store.transcription_runs(&session).unwrap();
    assert_eq!(runs.len(), 1);
    assert_eq!(runs[0].state, "complete");
    assert!(runs[0].failure_class.is_none());
    assert_eq!(store.transcript_revisions(&session).unwrap().len(), 1);
    drop(_temp);
}

#[test]
fn held_retained_maintenance_does_not_report_completed() {
    let mut imported = imported(60);
    complete_fixture_chunks(&mut imported.store, &imported.session, &imported.track);
    imported
        .store
        .request_transcription(
            &imported.session,
            crate::TranscriptionIntent::ResumeIncomplete,
        )
        .unwrap();
    let mut controller = crate::RecordingPreparationController::open(&imported.root).unwrap();
    let outcome = controller
        .maintain_transcripts(&AtomicBool::new(false))
        .unwrap();
    assert_eq!(outcome, open_scribe_types::WorkOutcome::Deferred);
    assert!(
        imported
            .store
            .transcript_revisions(&imported.session)
            .unwrap()
            .is_empty()
    );
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

/// The identity a real run stores: the burst fixture's engine and model
/// under a chosen reconciliation version.
fn retained_identity(
    store: &SessionStore,
    session: &SessionId,
    track: &str,
    reconciliation_version: &str,
) -> (TranscriptionRunIdentity, Vec<PlannedTranscriptChunk>) {
    let input = store.transcription_input(session, track).unwrap();
    let identity = TranscriptionRunIdentity {
        session_id: session.clone(),
        track_id: track.to_owned(),
        input_digest: input.input_digest.clone(),
        engine: "burst-fixture".into(),
        engine_version: "1".into(),
        model_id: "burst-model".into(),
        model_sha256: "a".repeat(64),
        options_digest: DecodeOptions::final_pass(Language::English).digest(),
        reconciliation_version: reconciliation_version.into(),
    };
    let plan = plan_windows(&input)
        .iter()
        .map(|window| window.chunk)
        .collect();
    (identity, plan)
}

/// Hypotheses whose midpoint-owned segments only commit once reconciliation
/// orders them: the second window's long segment starts before the first
/// window's short one.
fn complete_out_of_order(store: &mut SessionStore, handle: &TranscriptionRunHandle) {
    for chunk in &handle.chunks {
        let segments = match chunk.sequence {
            0 => vec![HypothesisSegment {
                start_ms: 25_400,
                end_ms: 25_500,
                text: "short left".into(),
                mean_probability: Some(0.9),
                no_speech_probability: Some(0.0),
            }],
            1 => vec![HypothesisSegment {
                start_ms: 1_280,
                end_ms: 4_480,
                text: "long right".into(),
                mean_probability: Some(0.9),
                no_speech_probability: Some(0.0),
            }],
            _ => vec![],
        };
        let hypothesis = Hypothesis {
            language: "en".into(),
            segments,
        };
        store
            .complete_transcript_chunk(
                &handle.run_id,
                chunk.sequence,
                "en",
                &serde_json::to_string(&hypothesis).unwrap(),
            )
            .unwrap();
    }
}

fn assert_recovered_in_order(store: &SessionStore, session: &SessionId, source_run: &str) {
    let selected = store.selected_transcript(session).unwrap();
    assert_eq!(
        selected.iter().map(|s| s.text.as_str()).collect::<Vec<_>>(),
        ["long right", "short left"]
    );
    assert_eq!(
        selected
            .iter()
            .map(|s| s.start_nanoseconds)
            .collect::<Vec<_>>(),
        [24_280_000_000, 25_400_000_000]
    );
    let revisions = store.transcript_revisions(session).unwrap();
    assert_eq!(revisions.len(), 1);
    assert!(revisions[0].selected);
    assert_eq!(revisions[0].reconciliation_version, RECONCILIATION_VERSION);
    assert_ne!(
        revisions[0].run_id, source_run,
        "the stale label never owns the revision"
    );
    let successor = store
        .transcription_run_record(&revisions[0].run_id)
        .unwrap();
    assert_eq!(
        successor.identity.reconciliation_version,
        RECONCILIATION_VERSION
    );
    assert_eq!(successor.state, "complete");
    assert!(
        store
            .transcript_chunks_for_run(&revisions[0].run_id)
            .unwrap()
            .iter()
            .all(|chunk| chunk.reused_from_run.as_deref() == Some(source_run)),
        "every chunk is reused; nothing is transcribed again"
    );
}

#[test]
fn launch_recovery_rebuilds_a_stale_class_a_orphan_under_the_current_version() {
    let mut imported = imported(60);
    let (stale, plan) = retained_identity(
        &imported.store,
        &imported.session,
        &imported.track,
        "overlap-midpoint-v2",
    );
    let old = imported
        .store
        .begin_transcription_run(&stale, &plan)
        .unwrap();
    complete_out_of_order(&mut imported.store, &old);
    let preserved = imported
        .store
        .transcript_chunks_for_run(&old.run_id)
        .unwrap();
    let root = imported.root.clone();
    let session = imported.session.clone();
    let Imported { _temp, store, .. } = imported;
    drop(store);

    let mut controller = crate::RecordingPreparationController::open(&root).unwrap();
    controller.recover_playable_sessions().unwrap();
    controller
        .maintain_transcripts(&AtomicBool::new(false))
        .unwrap();
    let store = SessionStore::open(&root).unwrap();
    let runs = store.transcription_runs(&session).unwrap();
    assert_eq!(runs.len(), 2);
    assert_eq!(runs[0].run_id, old.run_id);
    assert_eq!(runs[0].state, "cancelled");
    assert_eq!(runs[0].failure_class.as_deref(), Some("superseded"));
    assert_eq!(
        store.transcript_chunks_for_run(&old.run_id).unwrap(),
        preserved
    );
    assert_recovered_in_order(&store, &session, &old.run_id);

    // A second launch finds nothing left to rebuild.
    drop(store);
    let mut controller = crate::RecordingPreparationController::open(&root).unwrap();
    controller.recover_playable_sessions().unwrap();
    controller
        .maintain_transcripts(&AtomicBool::new(false))
        .unwrap();
    let store = SessionStore::open(&root).unwrap();
    assert_eq!(store.transcription_runs(&session).unwrap().len(), 2);
    assert_eq!(store.transcript_revisions(&session).unwrap().len(), 1);
    drop(_temp);
}

#[test]
fn launch_recovery_rebuilds_a_failed_stale_run_once_and_leaves_current_failures_alone() {
    let mut imported = imported(60);
    // A second conversation in the same library, failed under the current
    // version: its failure is real and must not be retried on every launch.
    let other_source = imported.root.join("other.caf");
    write_burst_caf(&other_source, 60 * u64::from(SOURCE_SAMPLE_RATE_HZ));
    let other = imported
        .store
        .import_recoverable_caf(ImportMediaRequest {
            title: "Other".into(),
            source_path: other_source,
        })
        .unwrap()
        .session_id;
    let other_track = imported
        .store
        .transcription_tracks(&other)
        .unwrap()
        .remove(0);
    let (current, other_plan) = retained_identity(
        &imported.store,
        &other,
        &other_track,
        RECONCILIATION_VERSION,
    );
    let current_run = imported
        .store
        .begin_transcription_run(&current, &other_plan)
        .unwrap();
    complete_out_of_order(&mut imported.store, &current_run);
    imported
        .store
        .fail_transcription_run(
            &current_run.run_id,
            None,
            TranscriptionFailure::InvalidResult,
        )
        .unwrap();

    // The stale run an earlier build failed after every chunk was durable.
    let (stale, plan) = retained_identity(
        &imported.store,
        &imported.session,
        &imported.track,
        "overlap-midpoint-v2",
    );
    let old = imported
        .store
        .begin_transcription_run(&stale, &plan)
        .unwrap();
    complete_out_of_order(&mut imported.store, &old);
    imported
        .store
        .fail_transcription_run(&old.run_id, None, TranscriptionFailure::InvalidResult)
        .unwrap();
    let preserved = imported
        .store
        .transcript_chunks_for_run(&old.run_id)
        .unwrap();
    let root = imported.root.clone();
    let session = imported.session.clone();
    let Imported { _temp, store, .. } = imported;
    drop(store);

    for launch in 0..2 {
        let mut controller = crate::RecordingPreparationController::open(&root).unwrap();
        controller.recover_playable_sessions().unwrap();
        controller
            .maintain_transcripts(&AtomicBool::new(false))
            .unwrap();
        let store = SessionStore::open(&root).unwrap();
        let runs = store.transcription_runs(&session).unwrap();
        assert_eq!(runs.len(), 2, "launch {launch} adds no further runs");
        assert_eq!(runs[0].run_id, old.run_id);
        assert_eq!(runs[0].state, "failed");
        assert_eq!(runs[0].failure_class.as_deref(), Some("invalid_result"));
        assert_eq!(
            store.transcript_chunks_for_run(&old.run_id).unwrap(),
            preserved
        );
        assert_recovered_in_order(&store, &session, &old.run_id);
        let other_runs = store.transcription_runs(&other).unwrap();
        assert_eq!(other_runs.len(), 1);
        assert_eq!(other_runs[0].state, "failed");
        assert!(store.transcript_revisions(&other).unwrap().is_empty());
    }
    drop(_temp);
}

#[test]
fn finalize_refuses_to_label_a_stale_run_with_the_current_version() {
    let mut imported = imported(60);
    let (stale, plan) = retained_identity(
        &imported.store,
        &imported.session,
        &imported.track,
        "overlap-midpoint-v2",
    );
    let old = imported
        .store
        .begin_transcription_run(&stale, &plan)
        .unwrap();
    complete_out_of_order(&mut imported.store, &old);
    let preserved = imported
        .store
        .transcript_chunks_for_run(&old.run_id)
        .unwrap();

    assert!(matches!(
        finalize_transcription_run(&mut imported.store, &old.run_id),
        Err(TranscriptionError::RunEnded { .. })
    ));
    let runs = imported
        .store
        .transcription_runs(&imported.session)
        .unwrap();
    assert_eq!(runs.len(), 1);
    assert_eq!(runs[0].state, "failed");
    assert_eq!(
        runs[0].failure_class.as_deref(),
        Some("stale_reconciliation")
    );
    assert!(
        imported
            .store
            .transcript_revisions(&imported.session)
            .unwrap()
            .is_empty()
    );
    assert_eq!(
        imported
            .store
            .transcript_chunks_for_run(&old.run_id)
            .unwrap(),
        preserved
    );

    // The same chunks commit under a successor labeled with the version
    // that ordered them.
    let recovered = reconcile_retained_chunks(&mut imported.store, &old.run_id).unwrap();
    assert_eq!(recovered.source_run_id, old.run_id);
    assert_ne!(recovered.run_id, old.run_id);
    assert_eq!(recovered.reused_chunks, plan.len() as u32);
    assert_eq!(recovered.segment_count, 2);
    assert_eq!(recovered.rejections, Rejections::default());
    assert_recovered_in_order(&imported.store, &imported.session, &old.run_id);
}

#[test]
fn reconcile_retained_chunks_refuses_incomplete_runs_without_a_successor() {
    let mut imported = imported(60);
    let (stale, plan) = retained_identity(
        &imported.store,
        &imported.session,
        &imported.track,
        "overlap-midpoint-v2",
    );
    let old = imported
        .store
        .begin_transcription_run(&stale, &plan)
        .unwrap();
    imported
        .store
        .complete_transcript_chunk(
            &old.run_id,
            0,
            "en",
            &serde_json::to_string(&Hypothesis {
                language: "en".into(),
                segments: vec![],
            })
            .unwrap(),
        )
        .unwrap();
    assert!(matches!(
        reconcile_retained_chunks(&mut imported.store, &old.run_id),
        Err(TranscriptionError::Store(StoreError::InvalidState(_)))
    ));
    let runs = imported
        .store
        .transcription_runs(&imported.session)
        .unwrap();
    assert_eq!(runs.len(), 1);
    assert_eq!(runs[0].state, "running");
    assert!(
        recover_retained_transcripts(&mut imported.store, None)
            .unwrap()
            .is_empty()
    );
    assert_eq!(
        imported
            .store
            .transcription_runs(&imported.session)
            .unwrap()
            .len(),
        1
    );
}

#[test]
fn retained_transcript_recovery_can_be_scoped_to_one_session() {
    let mut imported = imported(60);
    let other_source = imported.root.join("other.caf");
    write_burst_caf(&other_source, 60 * u64::from(SOURCE_SAMPLE_RATE_HZ));
    let other = imported
        .store
        .import_recoverable_caf(ImportMediaRequest {
            title: "Other".into(),
            source_path: other_source,
        })
        .unwrap()
        .session_id;
    let other_track = imported
        .store
        .transcription_tracks(&other)
        .unwrap()
        .remove(0);
    for (session, track) in [
        (imported.session.clone(), imported.track.clone()),
        (other.clone(), other_track),
    ] {
        let (stale, plan) =
            retained_identity(&imported.store, &session, &track, "overlap-midpoint-v2");
        let run = imported
            .store
            .begin_transcription_run(&stale, &plan)
            .unwrap();
        complete_out_of_order(&mut imported.store, &run);
        imported
            .store
            .fail_transcription_run(&run.run_id, None, TranscriptionFailure::InvalidResult)
            .unwrap();
    }
    let scoped = recover_retained_transcripts(&mut imported.store, Some(&other)).unwrap();
    assert_eq!(scoped.len(), 1);
    assert_eq!(scoped[0].session_id, other);
    assert_eq!(scoped[0].segment_count, 2);
    assert!(
        imported
            .store
            .transcript_revisions(&imported.session)
            .unwrap()
            .is_empty()
    );
    let rest = recover_retained_transcripts(&mut imported.store, None).unwrap();
    assert_eq!(rest.len(), 1);
    assert_eq!(rest[0].session_id, imported.session);
    assert!(
        recover_retained_transcripts(&mut imported.store, None)
            .unwrap()
            .is_empty()
    );
}

/// Operator dry run: rebuilds retained transcripts inside a copy of a real
/// library and prints content-free outcomes. Set
/// `OPEN_SCRIBE_RETAINED_DRY_RUN_ROOT` to the copy's managed root, a
/// directory holding `Library.sqlite3` and `Sessions/`. Transcript text is
/// never printed.
#[test]
#[ignore = "operator dry run against a copied library"]
fn dry_run_retained_recovery_on_a_library_copy() {
    let Some(root) = std::env::var_os("OPEN_SCRIBE_RETAINED_DRY_RUN_ROOT") else {
        return;
    };
    let mut store = SessionStore::open(PathBuf::from(root)).unwrap();
    let candidates = store
        .retained_transcript_candidates(RECONCILIATION_VERSION)
        .unwrap();
    println!("candidates={}", candidates.len());
    for run_id in &candidates {
        let record = store.transcription_run_record(run_id).unwrap();
        println!(
            "candidate run={} session={} track={} version={} state={} failure={:?} chunks={}/{}",
            run_id,
            record.identity.session_id.0,
            record.identity.track_id,
            record.identity.reconciliation_version,
            record.state,
            record.failure_class,
            record.complete_chunks,
            record.total_chunks
        );
    }
    let mut recovered = Vec::new();
    for run_id in &candidates {
        match reconcile_retained_chunks(&mut store, run_id) {
            Ok(outcome) => recovered.push(outcome),
            Err(error) => println!("skipped run={run_id} error={error}"),
        }
    }
    for outcome in &recovered {
        let segments = store
            .transcript_revision_segments(&outcome.revision_id)
            .unwrap();
        let ordered = segments
            .windows(2)
            .all(|pair| pair[1].start_nanoseconds >= pair[0].start_nanoseconds);
        let bounded = segments
            .iter()
            .all(|segment| segment.end_nanoseconds >= segment.start_nanoseconds);
        println!(
            "recovered session={} track={} source_run={} run={} revision={} reused={} segments={} rejections={:?} first_start_ns={:?} last_end_ns={:?} ordered={} bounded={}",
            outcome.session_id.0,
            outcome.track_id,
            outcome.source_run_id,
            outcome.run_id,
            outcome.revision_id,
            outcome.reused_chunks,
            outcome.segment_count,
            outcome.rejections,
            segments.first().map(|segment| segment.start_nanoseconds),
            segments.last().map(|segment| segment.end_nanoseconds),
            ordered,
            bounded
        );
        assert!(ordered && bounded);
    }
    println!(
        "remaining_candidates={}",
        store
            .retained_transcript_candidates(RECONCILIATION_VERSION)
            .unwrap()
            .len()
    );
    assert!(
        recover_retained_transcripts(&mut store, None)
            .unwrap()
            .is_empty(),
        "a second pass must find nothing new to commit"
    );
}
