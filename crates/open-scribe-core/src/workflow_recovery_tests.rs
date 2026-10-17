//! A bounded comparison, not a benchmark or a second application. Kill an
//! owned process after durable Retry admission, before retained finalization.
use super::{plan_windows, tests::BurstRecognizer};
use crate::{SessionStore, TranscriptionFailure, execute_transcription_plan, transcribe_track};
use open_scribe_asr::{DecodeOptions, Language, RECONCILIATION_VERSION};
use open_scribe_store::TranscriptionRunIdentity;
use open_scribe_types::{
    ModelReadiness, SessionId, TranscriptionIntent, WorkObservations, WorkOutcome,
};
use rusqlite::{Connection, OpenFlags};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use std::fs::{self, File};
use std::io::Write;
use std::os::unix::process::ExitStatusExt;
use std::path::Path;
use std::process::{Child, Command, Stdio};
use std::sync::atomic::AtomicBool;
use std::time::{Duration, Instant};

#[path = "workflow_recovery_baseline.rs"]
mod baseline;

#[derive(Debug, Eq, PartialEq)]
struct Reviewed {
    selection: String,
    epoch: i64,
    corrections: Vec<String>,
    effective_text: Vec<String>,
    search_revisions: Vec<String>,
    runs: usize,
    revisions: usize,
}

fn observations() -> WorkObservations {
    WorkObservations {
        automatic: false,
        model: ModelReadiness::Absent,
        ..Default::default()
    }
}

fn identity(root: &Path) -> (SessionId, String, String, String) {
    let id: Value = serde_json::from_slice(&fs::read(root.join("identity.json")).unwrap()).unwrap();
    (
        SessionId(id["session"].as_str().unwrap().into()),
        id["reviewed"].as_str().unwrap().into(),
        id["incomplete"].as_str().unwrap().into(),
        id["failure"].as_str().unwrap().into(),
    )
}

fn seed_production(temp: &tempfile::TempDir) {
    let (mut store, session, _) = crate::package_import_tests::captured(temp);
    let tracks = store.transcription_tracks(&session).unwrap();
    let options = DecodeOptions::final_pass(Language::English);
    let first = transcribe_track(
        &mut store,
        &mut BurstRecognizer::new(&"a".repeat(64)),
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

    let input = store.transcription_input(&session, &tracks[1]).unwrap();
    let run_identity = TranscriptionRunIdentity {
        session_id: session.clone(),
        track_id: tracks[1].clone(),
        input_digest: input.input_digest.clone(),
        engine: "burst-fixture".into(),
        engine_version: "1".into(),
        model_id: "burst-model".into(),
        model_sha256: "a".repeat(64),
        options_digest: options.digest(),
        reconciliation_version: RECONCILIATION_VERSION.into(),
    };
    let chunks: Vec<_> = plan_windows(&input).into_iter().map(|w| w.chunk).collect();
    let run = store
        .begin_transcription_run(&run_identity, &chunks)
        .unwrap();
    for chunk in &run.chunks {
        let hypothesis = json!({"language":"en", "segments":[{
            "start_ms":200, "end_ms":1200, "text":"Retained beta",
            "mean_probability":0.99, "no_speech_probability":0.0
        }]});
        store
            .complete_transcript_chunk(&run.run_id, chunk.sequence, "en", &hypothesis.to_string())
            .unwrap();
    }
    store
        .fail_transcription_run(&run.run_id, None, TranscriptionFailure::StorageError)
        .unwrap();
    fs::write(
        temp.path().join("identity.json"),
        json!({"session":session.0, "reviewed":tracks[0], "incomplete":tracks[1],
            "failure":run.run_id})
        .to_string(),
    )
    .unwrap();
}

fn production_review(root: &Path) -> Reviewed {
    let (session, track, _, _) = identity(root);
    let store = SessionStore::open(root.join("Open Scribe")).unwrap();
    let selected = store.selection_expectation(&session, &track).unwrap();
    let database = Connection::open_with_flags(
        root.join("Open Scribe/Library.sqlite3"),
        OpenFlags::SQLITE_OPEN_READ_ONLY,
    )
    .unwrap();
    let corrections = database
        .prepare("SELECT id FROM transcript_corrections ORDER BY id")
        .unwrap()
        .query_map([], |r| r.get(0))
        .unwrap()
        .collect::<Result<Vec<String>, _>>()
        .unwrap();
    Reviewed {
        selection: selected.revision_id.unwrap(),
        epoch: selected.epoch,
        corrections,
        effective_text: store
            .transcript_document(&session)
            .unwrap()
            .into_iter()
            .filter(|s| s.track_id == track)
            .map(|s| s.effective_text)
            .collect(),
        search_revisions: store
            .search_transcripts("Reviewed alpha", Some(&session), 10)
            .unwrap()
            .into_iter()
            .map(|hit| hit.revision_id)
            .collect(),
        runs: store
            .transcription_runs(&session)
            .unwrap()
            .iter()
            .filter(|r| r.track_id == track)
            .count(),
        revisions: store
            .transcript_revisions(&session)
            .unwrap()
            .iter()
            .filter(|r| r.track_id == track)
            .count(),
    }
}

fn production_admit(root: &Path) {
    let (session, _, _, _) = identity(root);
    let mut store = SessionStore::open(root.join("Open Scribe")).unwrap();
    store
        .request_transcription(&session, TranscriptionIntent::ResumeIncomplete)
        .unwrap();
    let admitted = store.admit_transcription(observations()).unwrap().unwrap();
    assert!(admitted.manual);
    assert_eq!(admitted.intent, TranscriptionIntent::ResumeIncomplete);
    assert!(
        store
            .start_transcription_execution(
                &session,
                admitted.admission.as_deref().unwrap(),
                admitted.intent
            )
            .unwrap()
    );
    // Keep the real handle alive until the parent kills this process. No
    // finalizer, recognizer, orderly connection close, or destructors run.
    checkpoint_and_wait(root);
    drop(store);
}

fn resume_production(root: &Path) -> Value {
    let (session, _, second, failure) = identity(root);
    let mut store = SessionStore::open(root.join("Open Scribe")).unwrap();
    let recovery = store.recover_library().unwrap();
    assert!(recovery.pending_transcript_finalizations.is_empty());
    store.recover_transcription_admissions().unwrap();
    let queue = store.transcription_queue(observations()).unwrap();
    assert_eq!(queue.len(), 1);
    assert_eq!(queue[0].session_id, session);
    assert!(queue[0].manual);
    assert_eq!(queue[0].intent, TranscriptionIntent::ResumeIncomplete);
    assert_eq!(queue[0].hold, None);
    let admitted = store.admit_transcription(observations()).unwrap().unwrap();
    let token = admitted.admission.as_deref().unwrap();
    assert!(
        store
            .start_transcription_execution(&session, token, admitted.intent)
            .unwrap()
    );
    let operation = store.transcription_operation(&session, token).unwrap();
    let plan =
        crate::plan_transcription_operation(&store, &session, admitted.intent, &operation).unwrap();
    assert_eq!(plan.tracks.len(), 1);
    assert_eq!(plan.tracks[0].track_id, second);
    assert!(!plan.needs_recognizer());
    let result = execute_transcription_plan(
        &mut store,
        None,
        &DecodeOptions::final_pass(Language::English),
        &plan,
        None,
        &AtomicBool::new(false),
        &mut |_, _, _| {},
    )
    .unwrap();
    assert_eq!(result.len(), 1);
    assert_eq!(result[0].transcribed_chunks, 0);
    store
        .finish_transcription(token, WorkOutcome::Completed)
        .unwrap();
    assert!(
        store
            .has_compatible_selected_final(&session, &second)
            .unwrap()
    );
    assert!(
        store
            .transcript_document(&session)
            .unwrap()
            .iter()
            .any(|s| s.track_id == second && s.effective_text == "Retained beta")
    );
    let old = store
        .transcription_runs(&session)
        .unwrap()
        .into_iter()
        .find(|r| r.run_id == failure)
        .unwrap();
    assert_eq!(old.failure_class.as_deref(), Some("storage_error"));
    assert!(
        store
            .transcription_queue(observations())
            .unwrap()
            .is_empty()
    );
    json!({"manual_origin_preserved":true, "recognized_chunks":result[0].transcribed_chunks,
        "resumed_tracks":result.len(), "repeated_user_actions":0})
}

fn checkpoint_and_wait(root: &Path) {
    let mut checkpoint = File::create(root.join("admitted")).unwrap();
    checkpoint.write_all(b"manual-resume-admitted\n").unwrap();
    checkpoint.sync_all().unwrap();
    loop {
        std::thread::park_timeout(Duration::from_secs(1));
    }
}

#[test]
#[ignore = "owned child only; invoked by the paired process-kill test"]
fn comparison_child() {
    let root = std::env::var_os("OPEN_SCRIBE_COMPARISON_ROOT").unwrap();
    let root = Path::new(&root);
    assert!(root.is_absolute());
    assert_eq!(root.canonicalize().unwrap(), root);
    assert_eq!(
        fs::read_to_string(root.join("owner")).unwrap(),
        std::env::var("OPEN_SCRIBE_COMPARISON_OWNER").unwrap()
    );
    match std::env::var("OPEN_SCRIBE_COMPARISON_SUBJECT")
        .unwrap()
        .as_str()
    {
        "production" => production_admit(root),
        "baseline" => baseline::admit_and_wait(root),
        _ => panic!("unsupported comparison subject"),
    }
}

struct OwnedChild(Child);
impl Drop for OwnedChild {
    fn drop(&mut self) {
        if matches!(self.0.try_wait(), Ok(None)) {
            let _ = self.0.kill();
        }
        let _ = self.0.wait();
    }
}

fn kill_after_admission(root: &Path, subject: &str) {
    let owner = format!("{}:{subject}", std::process::id());
    fs::write(root.join("owner"), &owner).unwrap();
    let log = File::create(root.join("child.log")).unwrap();
    let mut child = OwnedChild(
        Command::new(std::env::current_exe().unwrap())
            .args([
                "--exact",
                "transcription::workflow_recovery_tests::comparison_child",
                "--ignored",
                "--nocapture",
                "--test-threads=1",
            ])
            .env("OPEN_SCRIBE_COMPARISON_ROOT", root)
            .env("OPEN_SCRIBE_COMPARISON_OWNER", owner)
            .env("OPEN_SCRIBE_COMPARISON_SUBJECT", subject)
            .stdout(Stdio::from(log.try_clone().unwrap()))
            .stderr(Stdio::from(log))
            .spawn()
            .unwrap(),
    );
    let deadline = Instant::now() + Duration::from_secs(30);
    loop {
        if fs::read(root.join("admitted")).ok().as_deref() == Some(b"manual-resume-admitted\n") {
            break;
        }
        assert!(
            child.0.try_wait().unwrap().is_none(),
            "child exited: {}",
            fs::read_to_string(root.join("child.log")).unwrap()
        );
        assert!(
            Instant::now() < deadline,
            "child did not reach durable admission"
        );
        std::thread::sleep(Duration::from_millis(10));
    }
    child.0.kill().unwrap();
    assert_eq!(
        child.0.wait().unwrap().signal(),
        Some(9),
        "must be an external SIGKILL"
    );
}

fn audio_hashes(root: &Path) -> Vec<(std::path::PathBuf, String)> {
    fn visit(root: &Path, directory: &Path, hashes: &mut Vec<(std::path::PathBuf, String)>) {
        for entry in fs::read_dir(directory).unwrap() {
            let entry = entry.unwrap();
            if entry.file_type().unwrap().is_dir() {
                visit(root, &entry.path(), hashes);
            } else if entry.path().extension().is_some_and(|ext| ext == "caf") {
                hashes.push((
                    entry.path().strip_prefix(root).unwrap().into(),
                    format!("{:x}", Sha256::digest(fs::read(entry.path()).unwrap())),
                ));
            }
        }
    }
    let mut hashes = Vec::new();
    visit(root, root, &mut hashes);
    hashes.sort();
    assert!(!hashes.is_empty());
    hashes
}

#[test]
fn paired_sigkill_preserves_review_and_manual_retry_without_recognition() {
    let production = tempfile::tempdir().unwrap();
    let baseline = tempfile::tempdir().unwrap();
    seed_production(&production);
    baseline::seed(baseline.path());
    let mut results = serde_json::Map::new();
    for (subject, temp) in [("production", &production), ("baseline", &baseline)] {
        let root = temp.path().canonicalize().unwrap();
        let before = if subject == "production" {
            production_review(&root)
        } else {
            baseline::review(&root)
        };
        assert!(!before.corrections.is_empty());
        assert_eq!(before.search_revisions, vec![before.selection.clone()]);
        assert!(before.effective_text.iter().any(|t| t == "Reviewed alpha"));
        let audio = audio_hashes(&root);
        kill_after_admission(&root, subject);
        let result = if subject == "production" {
            resume_production(&root)
        } else {
            baseline::resume(&root)
        };
        let after = if subject == "production" {
            production_review(&root)
        } else {
            baseline::review(&root)
        };
        assert_eq!(
            before, after,
            "{subject}: corrected selected A must remain byte-for-byte effective"
        );
        assert_eq!(
            audio,
            audio_hashes(&root),
            "{subject}: source evidence changed"
        );
        results.insert(subject.into(), result);
    }
    assert_eq!(results["production"], results["baseline"]);
    eprintln!(
        "RECOVERY_COMPARISON_GREEN {}",
        json!({"case":"manual-retry-sigkill-retained",
        "outcome":"tie", "subjects":results,
        "scope":"one logical fixture; no timing, ASR accuracy, UI, or market advantage inferred"})
    );
}
