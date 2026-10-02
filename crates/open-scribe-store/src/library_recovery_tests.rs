//! P3: one launch recovers every session on its own. Damage in one session is a
//! finding for that session; healthy sessions beside it still recover and play.
use super::*;
use std::io::SeekFrom;

#[test]
fn m1_launch_interrupts_abandoned_preparation_without_claiming_media() {
    let temp = TempDir::new().unwrap();
    let mut store = SessionStore::open(temp.path()).unwrap();
    let session = store
        .prepare_session(PrepareSessionRequest {
            title: "Killed before opening media".to_owned(),
            origin: SessionOrigin::Capture,
        })
        .unwrap()
        .session_id;
    drop(store);

    let mut store = SessionStore::open(temp.path()).unwrap();
    let first = store.recover_library().unwrap();
    assert_eq!(
        store.recorder_detail(&session).unwrap().lifecycle,
        "interrupted"
    );
    assert_eq!(
        finding_for(&first, &session),
        Some(RecoveryDisposition::InterruptedPrepared)
    );
    assert_eq!(playable_count(&first, &session), 0);
    let events = event_kinds(&store, &session);
    assert!(events.iter().any(|kind| kind == "session_interrupted"));
    assert!(!events.iter().any(|kind| kind == "recording_started"));
    let journal_path = store
        .session_directory(&session.0)
        .unwrap()
        .join(JOURNAL_NAME);
    let journal = fs::read(&journal_path).unwrap();
    assert!(
        journal_records(&store, &session)
            .iter()
            .any(|record| record.body.event_kind == "session_interrupted"
                && record.body.payload["reason"] == "capture_start_failed")
    );
    drop(store);

    let mut store = SessionStore::open(temp.path()).unwrap();
    store.recover_library().unwrap();
    assert_eq!(
        store.recorder_detail(&session).unwrap().lifecycle,
        "interrupted"
    );
    assert_eq!(event_kinds(&store, &session), events);
    assert_eq!(fs::read(journal_path).unwrap(), journal);
}

fn finding_for(recovery: &LibraryRecovery, session: &SessionId) -> Option<RecoveryDisposition> {
    recovery
        .findings
        .iter()
        .find(|finding| &finding.session_id == session)
        .map(|finding| finding.disposition)
}

fn playable_count(recovery: &LibraryRecovery, session: &SessionId) -> usize {
    recovery
        .playable
        .iter()
        .filter(|item| &item.session_id == session)
        .count()
}

fn media_bytes(sources: &[MediaOpenAuthorization]) -> Vec<Vec<u8>> {
    sources
        .iter()
        .map(|a| fs::read(&a.absolute_path).unwrap())
        .collect()
}

fn session_column(store: &SessionStore, session: &SessionId, column: &str) -> String {
    store
        .connection
        .query_row(
            &format!("SELECT {column} FROM sessions WHERE id = ?1"),
            [&session.0],
            |r| r.get(0),
        )
        .unwrap()
}

fn session_flag(store: &SessionStore, session: &SessionId, column: &str) -> i64 {
    store
        .connection
        .query_row(
            &format!("SELECT {column} FROM sessions WHERE id = ?1"),
            [&session.0],
            |r| r.get(0),
        )
        .unwrap()
}

fn event_kinds(store: &SessionStore, session: &SessionId) -> Vec<String> {
    let mut query = store
        .connection
        .prepare("SELECT event_kind FROM session_events WHERE session_id = ?1 ORDER BY sequence")
        .unwrap();
    query
        .query_map([&session.0], |r| r.get::<_, String>(0))
        .unwrap()
        .collect::<Result<_, _>>()
        .unwrap()
}

fn recovery_run_dispositions(store: &SessionStore, session: &SessionId) -> Vec<String> {
    let mut query = store
        .connection
        .prepare("SELECT disposition FROM recovery_runs WHERE session_id = ?1 ORDER BY created_at_ms, id")
        .unwrap();
    query
        .query_map([&session.0], |r| r.get::<_, String>(0))
        .unwrap()
        .collect::<Result<_, _>>()
        .unwrap()
}

fn timeline_recovered_payloads(store: &SessionStore, session: &SessionId) -> Vec<Value> {
    journal_records(store, session)
        .into_iter()
        .filter(|r| r.body.event_kind == "timeline_recovered")
        .map(|r| r.body.payload)
        .collect()
}

/// Observable session state that a clean stop and a replayed stop must share.
#[derive(Debug, PartialEq)]
struct FinishedState {
    lifecycle: String,
    health: String,
    media_files_open: i64,
    events: Vec<String>,
    recovery_runs: Vec<String>,
    playable_segments: usize,
}

fn finished_state(store: &SessionStore, session: &SessionId) -> FinishedState {
    FinishedState {
        lifecycle: session_column(store, session, "lifecycle"),
        health: session_column(store, session, "health"),
        media_files_open: session_flag(store, session, "media_files_open"),
        events: event_kinds(store, session),
        recovery_runs: recovery_run_dispositions(store, session),
        playable_segments: store.playback_timeline(session).unwrap().len(),
    }
}

/// F2: a library holding one damaged paused session and one session that died
/// while Recording. Damage is applied after the process exit.
fn assert_damage_is_isolated(
    damage: impl Fn(&Path, &[MediaOpenAuthorization]),
    expected: RecoveryDisposition,
) {
    let temp = TempDir::new().unwrap();
    let mut store = SessionStore::open(temp.path()).unwrap();
    let (damaged, damaged_sources) = paused_pair(&mut store);
    let (healthy, healthy_sources) = recording_pair(&mut store);
    let damaged_journal = store
        .session_directory(&damaged.0)
        .unwrap()
        .join(JOURNAL_NAME);
    drop(store);
    damage(&damaged_journal, &damaged_sources);
    let healthy_bytes = media_bytes(&healthy_sources);

    let mut store = SessionStore::open(temp.path()).unwrap();
    let first = store.recover_library().unwrap();
    assert_eq!(
        finding_for(&first, &damaged),
        Some(expected),
        "damaged session gets its own finding"
    );
    assert_eq!(
        finding_for(&first, &healthy),
        Some(RecoveryDisposition::PlayableMediaRecovered)
    );
    assert_eq!(playable_count(&first, &healthy), 2);
    assert_eq!(playable_count(&first, &damaged), 0);
    assert_eq!(store.playback_timeline(&healthy).unwrap().len(), 2);
    assert_eq!(store.recorder_detail(&damaged).unwrap().lifecycle, "paused");
    assert_eq!(
        media_bytes(&healthy_sources),
        healthy_bytes,
        "recovery never rewrites media"
    );
    drop(store);

    let mut store = SessionStore::open(temp.path()).unwrap();
    let second = store.recover_library().unwrap();
    assert_eq!(finding_for(&second, &damaged), Some(expected));
    assert_eq!(
        finding_for(&second, &healthy),
        None,
        "a reviewed session needs no finding"
    );
    assert_eq!(second.playable, first.playable);
    assert_eq!(store.playback_timeline(&healthy).unwrap().len(), 2);
    assert_eq!(media_bytes(&healthy_sources), healthy_bytes);
}

#[test]
fn truncated_journal_in_one_session_does_not_block_the_library() {
    assert_damage_is_isolated(
        |journal, _| {
            let bytes = fs::read(journal).unwrap();
            fs::write(journal, &bytes[..bytes.len() - 3]).unwrap();
        },
        RecoveryDisposition::TruncatedJournal,
    );
}

/// The sealed-companion check names the deleted file as violated evidence.
#[test]
fn deleted_sealed_media_in_one_session_does_not_block_the_library() {
    assert_damage_is_isolated(
        |_, sources| fs::remove_file(&sources[1].absolute_path).unwrap(),
        RecoveryDisposition::IntegrityMismatch,
    );
}

#[test]
fn changed_sealed_media_bytes_in_one_session_do_not_block_the_library() {
    assert_damage_is_isolated(
        |_, sources| {
            let mut file = OpenOptions::new()
                .write(true)
                .open(&sources[0].absolute_path)
                .unwrap();
            file.seek(SeekFrom::Start(100)).unwrap();
            file.write_all(&[0x7f; 8]).unwrap();
            file.sync_all().unwrap();
        },
        RecoveryDisposition::IntegrityMismatch,
    );
}

/// F10: an interruption journaled while the session was `finalizing` (pause
/// requested, sources still draining) but never projected is projected on relaunch.
#[test]
fn interruption_journaled_while_finalizing_is_projected_on_relaunch() {
    let temp = TempDir::new().unwrap();
    let mut store = SessionStore::open(temp.path()).unwrap();
    let (session, _) = recording_pair(&mut store);
    store
        .recorder_action(session.clone(), RecorderAction::BeginPause)
        .unwrap();
    assert_eq!(
        store.recorder_detail(&session).unwrap().lifecycle,
        "finalizing"
    );
    store
        .append_session_journal(
            &session.0,
            "session_interrupted",
            None,
            json!({"reason": SessionInterruptionReason::CaptureFailed.as_str()}),
        )
        .unwrap();
    drop(store);

    let mut store = SessionStore::open(temp.path()).unwrap();
    let findings = store.recover_preparations().unwrap();
    assert_eq!(
        findings
            .iter()
            .find(|f| f.session_id == session)
            .map(|f| f.disposition),
        Some(RecoveryDisposition::InterruptionProjectionRepaired)
    );
    assert_eq!(
        store.recorder_detail(&session).unwrap().lifecycle,
        "interrupted"
    );
    assert_eq!(
        event_kinds(&store, &session).last().map(String::as_str),
        Some("session_interrupted")
    );
    let recovery = store.recover_library().unwrap();
    assert_eq!(
        playable_count(&recovery, &session),
        2,
        "interrupted media is still recovered"
    );
    assert_eq!(
        session_column(&store, &session, "lifecycle"),
        "ready_for_review"
    );
    assert_eq!(session_column(&store, &session, "health"), "degraded");
}

/// F12: quitting while paused with every source sealed has no gap. The relaunch
/// finalizes the session without calling it degraded.
#[test]
fn quit_while_paused_without_gaps_finalizes_healthy() {
    let temp = TempDir::new().unwrap();
    let mut store = SessionStore::open(temp.path()).unwrap();
    let (session, sources) = paused_pair(&mut store);
    drop(store);
    let bytes = media_bytes(&sources);

    let mut store = SessionStore::open(temp.path()).unwrap();
    let recovery = store.recover_library().unwrap();
    assert_eq!(
        finding_for(&recovery, &session),
        Some(RecoveryDisposition::PlayableMediaRecovered)
    );
    assert_eq!(
        session_column(&store, &session, "lifecycle"),
        "ready_for_review"
    );
    assert_eq!(session_column(&store, &session, "health"), "healthy");
    assert_eq!(
        timeline_recovered_payloads(&store, &session),
        vec![json!({"media_preserved": true, "has_gaps": false})]
    );
    assert_eq!(store.playback_timeline(&session).unwrap().len(), 2);
    assert_eq!(media_bytes(&sources), bytes);
    store.recover_library().unwrap();
    assert_eq!(session_column(&store, &session, "health"), "healthy");
    assert_eq!(timeline_recovered_payloads(&store, &session).len(), 1);
}

/// F12: a crash after `paused_session_finalized` reached the journal replays to
/// exactly the state a clean stop produces, with no recovery finalization on top.
#[test]
fn crash_after_journaled_paused_finalization_replays_to_the_clean_stop_state() {
    let control_temp = TempDir::new().unwrap();
    let mut control = SessionStore::open(control_temp.path()).unwrap();
    let (control_session, _) = paused_pair(&mut control);
    control
        .recorder_action(control_session.clone(), RecorderAction::FinishPaused)
        .unwrap();
    let expected = finished_state(&control, &control_session);
    assert_eq!(expected.lifecycle, "ready_for_review");

    let temp = TempDir::new().unwrap();
    let mut store = SessionStore::open(temp.path()).unwrap();
    let (session, _) = paused_pair(&mut store);
    let captured = store
        .recorder_detail(&session)
        .unwrap()
        .captured_nanoseconds;
    store
        .append_session_journal(
            &session.0,
            "paused_session_finalized",
            None,
            json!({"session_nanoseconds": captured}),
        )
        .unwrap();
    drop(store);

    let mut store = SessionStore::open(temp.path()).unwrap();
    store.recover_library().unwrap();
    assert_eq!(finished_state(&store, &session), expected);
    store.recover_library().unwrap();
    assert_eq!(finished_state(&store, &session), expected);
}

/// F12: a session with a real gap still reports it and stays degraded.
#[test]
fn real_gaps_still_report_has_gaps_and_degraded_health() {
    let temp = TempDir::new().unwrap();
    let mut store = SessionStore::open(temp.path()).unwrap();
    let (session, sources) = paused_pair(&mut store);
    store
        .recorder_action(session.clone(), RecorderAction::PrepareResume)
        .unwrap();
    let successor = store
        .authorize_next_segment(session.clone(), sources[0].segment_id.clone())
        .unwrap();
    create_media(&mut store, &successor);
    drop(store);
    let bytes = media_bytes(&sources);

    let mut store = SessionStore::open(temp.path()).unwrap();
    let recovery = store.recover_library().unwrap();
    assert_eq!(
        finding_for(&recovery, &session),
        Some(RecoveryDisposition::PlayableMediaRecovered)
    );
    assert_eq!(
        session_column(&store, &session, "lifecycle"),
        "ready_for_review"
    );
    assert_eq!(session_column(&store, &session, "health"), "degraded");
    assert_eq!(
        timeline_recovered_payloads(&store, &session),
        vec![json!({"media_preserved": true, "has_gaps": true})]
    );
    assert_eq!(
        store
            .connection
            .query_row(
                "SELECT lifecycle FROM segments WHERE id = ?1",
                [&successor.segment_id],
                |r| r.get::<_, String>(0),
            )
            .unwrap(),
        "gap"
    );
    assert_eq!(media_bytes(&sources), bytes);
}

/// N2: Recording that continues after a source failure (pause, resume on the
/// remaining source, rotation) is consistent evidence, not an integrity mismatch.
#[test]
fn relaunch_after_source_failure_and_resume_recovers_the_continuing_source() {
    let temp = TempDir::new().unwrap();
    let mut store = SessionStore::open(temp.path()).unwrap();
    let (session, sources) = recording_pair(&mut store);
    let (microphone, system) = (&sources[0], &sources[1]);
    seal(&mut store, system, 1_000_000_001, 48_000);
    store
        .record_source_failure(SourceFailureRequest {
            session_id: session.clone(),
            source_kind: MediaSourceKind::SystemAudio,
            reason: SourceFailureReason::CaptureFailed,
        })
        .unwrap();
    store
        .recorder_action(session.clone(), RecorderAction::BeginPause)
        .unwrap();
    seal(&mut store, microphone, 1_000_000_001, 48_000);
    store
        .recorder_action(
            session.clone(),
            RecorderAction::CompletePause {
                host_time: 2_000_000_001,
            },
        )
        .unwrap();
    store
        .recorder_action(session.clone(), RecorderAction::PrepareResume)
        .unwrap();
    let next = store
        .authorize_next_segment(session.clone(), microphone.segment_id.clone())
        .unwrap();
    create_media(&mut store, &next);
    store
        .recorder_action(
            session.clone(),
            RecorderAction::AnchorResume {
                host_time: 120_000_000_001,
            },
        )
        .unwrap();
    capture(&mut store, &next, 120_000_000_001, 48_000);
    store.confirm_recording(session.clone()).unwrap();
    drop(store);

    let mut store = SessionStore::open(temp.path()).unwrap();
    let recovery = store.recover_library().unwrap();
    assert_eq!(
        finding_for(&recovery, &session),
        Some(RecoveryDisposition::PlayableMediaRecovered)
    );
    assert_eq!(
        session_column(&store, &session, "lifecycle"),
        "ready_for_review"
    );
    assert_eq!(session_column(&store, &session, "health"), "degraded");
    assert_eq!(store.playback_timeline(&session).unwrap().len(), 3);
}

/// N2: a scope change while paused after a failure drops the failed kind from
/// the plan. The failed source keeps its failure and the relaunch finalizes.
#[test]
fn relaunch_after_source_failure_and_scope_change_finalizes() {
    let temp = TempDir::new().unwrap();
    let mut store = SessionStore::open(temp.path()).unwrap();
    let (session, sources) = recording_pair(&mut store);
    let (microphone, system) = (&sources[0], &sources[1]);
    seal(&mut store, system, 1_000_000_001, 48_000);
    store
        .record_source_failure(SourceFailureRequest {
            session_id: session.clone(),
            source_kind: MediaSourceKind::SystemAudio,
            reason: SourceFailureReason::CaptureFailed,
        })
        .unwrap();
    store
        .recorder_action(session.clone(), RecorderAction::BeginPause)
        .unwrap();
    seal(&mut store, microphone, 1_000_000_001, 48_000);
    store
        .recorder_action(
            session.clone(),
            RecorderAction::CompletePause {
                host_time: 2_000_000_001,
            },
        )
        .unwrap();
    select_application_scope(&mut store, &session);
    let system_lifecycle = |store: &SessionStore| -> String {
        store
            .connection
            .query_row(
                "SELECT lifecycle FROM sources WHERE id = ?1",
                [&system.source_id],
                |r| r.get(0),
            )
            .unwrap()
    };
    assert_eq!(
        system_lifecycle(&store),
        "failed",
        "a scope change keeps the failure"
    );
    drop(store);

    let mut store = SessionStore::open(temp.path()).unwrap();
    let recovery = store.recover_library().unwrap();
    assert_eq!(
        finding_for(&recovery, &session),
        Some(RecoveryDisposition::PlayableMediaRecovered)
    );
    assert_eq!(
        session_column(&store, &session, "lifecycle"),
        "ready_for_review"
    );
    assert_eq!(session_column(&store, &session, "health"), "degraded");
    assert_eq!(
        timeline_recovered_payloads(&store, &session),
        vec![json!({"media_preserved": true, "has_gaps": false})]
    );
    assert_eq!(store.playback_timeline(&session).unwrap().len(), 2);
    assert_eq!(system_lifecycle(&store), "failed");
}

/// F10 companion: a process that died while draining a pause (`finalizing`,
/// sources still capturing) recovers its media like one that died Recording.
#[test]
fn crash_while_draining_a_pause_recovers_the_captured_media() {
    let temp = TempDir::new().unwrap();
    let mut store = SessionStore::open(temp.path()).unwrap();
    let (session, sources) = recording_pair(&mut store);
    store
        .recorder_action(session.clone(), RecorderAction::BeginPause)
        .unwrap();
    drop(store);
    let bytes = media_bytes(&sources);

    let mut store = SessionStore::open(temp.path()).unwrap();
    let recovery = store.recover_library().unwrap();
    assert_eq!(
        finding_for(&recovery, &session),
        Some(RecoveryDisposition::PlayableMediaRecovered)
    );
    assert_eq!(playable_count(&recovery, &session), 2);
    assert_eq!(
        session_column(&store, &session, "lifecycle"),
        "ready_for_review"
    );
    assert_eq!(session_column(&store, &session, "health"), "healthy");
    assert_eq!(store.playback_timeline(&session).unwrap().len(), 2);
    assert_eq!(media_bytes(&sources), bytes);
}
