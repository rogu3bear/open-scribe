//! G3/G4/G6: launch recovery stays bounded and per-session. Long sessions do not
//! exhaust descriptors, a cut-short pass converges on the next launch, and one
//! damaged recovered session never hides the others.
use super::*;

const SEGMENT_SAMPLES: u64 = 480;

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

fn lifecycle(store: &SessionStore, session: &SessionId) -> String {
    store.recorder_detail(session).unwrap().lifecycle
}

/// Rotates both sources `rotations` times with 10 ms segments, sealing each
/// predecessor after its successor captured. Returns the capturing segments.
fn rotate_sealing(
    store: &mut SessionStore,
    session: &SessionId,
    mut current: Vec<MediaOpenAuthorization>,
    rotations: u64,
) -> Vec<MediaOpenAuthorization> {
    let mut written = vec![48_000_u64; current.len()];
    for index in 0..rotations {
        let host = 1_000_000_001 + index * 10_000_000;
        for slot in 0..current.len() {
            let next = store
                .authorize_next_segment(session.clone(), current[slot].segment_id.clone())
                .unwrap();
            create_media(store, &next);
            capture(store, &next, host, SEGMENT_SAMPLES);
            seal(store, &current[slot], host, written[slot]);
            current[slot] = next;
            written[slot] = SEGMENT_SAMPLES;
        }
    }
    current
}

/// G3: recovering a long session must not hold one descriptor per sealed
/// segment. The recovery runs in a child test process limited to 64 open files;
/// each session below holds 82 segments.
#[test]
fn long_sessions_recover_within_a_small_descriptor_limit() {
    const CHILD: &str = "OPEN_SCRIBE_DESCRIPTOR_LIMIT_CHILD";
    const NAME: &str = "long_sessions_recover_within_a_small_descriptor_limit";
    if std::env::var_os(CHILD).is_none() {
        let module = module_path!().split_once("::").unwrap().1;
        let status = std::process::Command::new("/bin/sh")
            .arg("-c")
            .arg("ulimit -n 64 && exec \"$0\" --exact \"$1\" --test-threads=1 --nocapture")
            .arg(std::env::current_exe().unwrap())
            .arg(format!("{module}::{NAME}"))
            .env(CHILD, "1")
            .status()
            .unwrap();
        assert!(
            status.success(),
            "recovery under a 64-descriptor limit failed: {status}"
        );
        return;
    }

    let temp = TempDir::new().unwrap();
    let mut store = SessionStore::open(temp.path()).unwrap();
    // Quit while paused: the finalize path.
    let (paused, sources) = recording_pair(&mut store);
    let current = rotate_sealing(&mut store, &paused, sources, 40);
    store
        .recorder_action(paused.clone(), RecorderAction::BeginPause)
        .unwrap();
    for segment in &current {
        seal(&mut store, segment, 1_400_000_001, SEGMENT_SAMPLES);
    }
    store
        .recorder_action(
            paused.clone(),
            RecorderAction::CompletePause {
                host_time: 1_500_000_001,
            },
        )
        .unwrap();
    // Killed while capturing: the promote path.
    let (crashed, sources) = recording_pair(&mut store);
    rotate_sealing(&mut store, &crashed, sources, 40);
    drop(store);

    let mut store = SessionStore::open(temp.path()).unwrap();
    let recovery = store.recover_library().unwrap();
    for session in [&paused, &crashed] {
        assert_eq!(
            finding_for(&recovery, session),
            Some(RecoveryDisposition::PlayableMediaRecovered)
        );
        assert_eq!(playable_count(&recovery, session), 82);
        assert_eq!(lifecycle(&store, session), "ready_for_review");
    }
}

/// G4: a recovery pass journaled a gap for an interrupted session but was cut
/// short before projecting it. The next launch must not treat the interruption
/// as untrustworthy; it reuses the journaled gap and finalizes.
#[test]
fn an_interrupted_session_converges_after_a_cut_short_recovery_pass() {
    let temp = TempDir::new().unwrap();
    let mut store = SessionStore::open(temp.path()).unwrap();
    let (session, sources) = recording_pair(&mut store);
    let mut reserved = Vec::new();
    for source in &sources {
        let next = store
            .authorize_next_segment(session.clone(), source.segment_id.clone())
            .unwrap();
        create_media(&mut store, &next);
        seal(&mut store, source, 1_000_000_001, 48_000);
        reserved.push(next);
    }
    store
        .interrupt_session(InterruptSessionRequest {
            session_id: session.clone(),
            reason: SessionInterruptionReason::CaptureFailed,
        })
        .unwrap();
    // The first relaunch appended this gap, then the pass stopped.
    store
        .append_session_journal(
            &session.0,
            "segment_capture_gap",
            Some(&reserved[0].relative_path),
            json!({
                "segment_id": reserved[0].segment_id, "track_id": reserved[0].track_id,
                "relative_path": reserved[0].relative_path,
                "reason": "terminated_before_first_sample", "media_preserved": true,
            }),
        )
        .unwrap();
    drop(store);

    let mut store = SessionStore::open(temp.path()).unwrap();
    let recovery = store.recover_library().unwrap();
    assert_eq!(
        finding_for(&recovery, &session),
        Some(RecoveryDisposition::PlayableMediaRecovered)
    );
    assert_eq!(lifecycle(&store, &session), "ready_for_review");
    assert_eq!(playable_count(&recovery, &session), 2);
    let gaps = journal_records(&store, &session)
        .into_iter()
        .filter(|record| record.body.event_kind == "segment_capture_gap")
        .count();
    assert_eq!(gaps, 2, "the journaled gap is reused, not written again");
    drop(store);

    let mut store = SessionStore::open(temp.path()).unwrap();
    let recovery = store.recover_library().unwrap();
    assert_eq!(finding_for(&recovery, &session), None);
    assert_eq!(playable_count(&recovery, &session), 2);
}

/// G6: one recovered session damaged after acceptance must not hide the others.
fn assert_damaged_recovered_session_is_isolated(
    damage: impl Fn(&MediaOpenAuthorization),
    expected: RecoveryDisposition,
) {
    let temp = TempDir::new().unwrap();
    let mut store = SessionStore::open(temp.path()).unwrap();
    let (damaged, damaged_sources) = paused_pair(&mut store);
    let (healthy, _) = paused_pair(&mut store);
    drop(store);
    let mut store = SessionStore::open(temp.path()).unwrap();
    let first = store.recover_library().unwrap();
    assert_eq!(playable_count(&first, &damaged), 2);
    assert_eq!(playable_count(&first, &healthy), 2);
    drop(store);

    damage(&damaged_sources[1]);
    for _ in 0..2 {
        let mut store = SessionStore::open(temp.path()).unwrap();
        let recovery = store
            .recover_library()
            .expect("one damaged session never fails the launch");
        assert_eq!(playable_count(&recovery, &healthy), 2);
        assert_eq!(playable_count(&recovery, &damaged), 0);
        assert_eq!(finding_for(&recovery, &damaged), Some(expected));
        assert_eq!(finding_for(&recovery, &healthy), None);
    }
}

#[test]
fn a_deleted_segment_hides_only_its_recovered_session() {
    assert_damaged_recovered_session_is_isolated(
        |segment| fs::remove_file(&segment.absolute_path).unwrap(),
        RecoveryDisposition::IntegrityMismatch,
    );
}

#[test]
fn changed_bytes_hide_only_their_recovered_session() {
    assert_damaged_recovered_session_is_isolated(
        |segment| {
            let mut file = OpenOptions::new()
                .write(true)
                .open(&segment.absolute_path)
                .unwrap();
            file.seek(std::io::SeekFrom::Start(100)).unwrap();
            file.write_all(&[0x7f; 8]).unwrap();
            file.sync_all().unwrap();
        },
        RecoveryDisposition::IntegrityMismatch,
    );
}
