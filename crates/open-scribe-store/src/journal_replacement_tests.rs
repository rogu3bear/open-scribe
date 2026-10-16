//! G10: opening a store (a playback lease, a timeline plan, the launch scan)
//! while a recording appends must never delete or adopt the replacement that
//! append is still writing. Replacements a terminated process left stay stale.
use super::*;
use std::sync::Arc;
use std::sync::Barrier;

#[test]
fn overlapping_handles_preserve_every_accepted_marker_and_declaration() {
    let temp = TempDir::new().unwrap();
    let mut store = SessionStore::open(temp.path()).unwrap();
    let (session, _) = recording_pair(&mut store);
    let start = Arc::new(Barrier::new(3));
    let mut workers = Vec::new();
    for writer in 0..2 {
        let root = temp.path().to_path_buf();
        let session = session.clone();
        let start = start.clone();
        workers.push(std::thread::spawn(move || {
            let mut handle = SessionStore::open(root).unwrap();
            start.wait();
            for index in 0..32 {
                handle
                    .recorder_action(
                        session.clone(),
                        RecorderAction::Marker {
                            host_time: 1 + index,
                            label: format!("writer-{writer}-{index}"),
                        },
                    )
                    .unwrap();
                handle
                    .declare_session(
                        session.clone(),
                        SessionDeclaration {
                            participants: vec![format!("writer {writer}")],
                            topic: Some(format!("event {index}")),
                        },
                    )
                    .unwrap();
            }
        }));
    }
    start.wait();
    for worker in workers {
        worker.join().unwrap();
    }
    let records = journal_records(&store, &session);
    assert_eq!(
        records
            .iter()
            .filter(|r| r.body.event_kind == "marker_added")
            .count(),
        64
    );
    assert_eq!(
        records
            .iter()
            .filter(|r| r.body.event_kind == "session_declared")
            .count(),
        64
    );
    for pair in records.windows(2) {
        assert_eq!(pair[1].body.sequence, pair[0].body.sequence + 1);
    }
    assert_eq!(
        store
            .recorder_detail(&session)
            .unwrap()
            .events
            .iter()
            .filter(|r| r.kind == "marker_added")
            .count(),
        64
    );
    store.recover_library().unwrap();
    let once = journal_records(&store, &session);
    store.recover_library().unwrap();
    assert_eq!(
        journal_records(&store, &session).len(),
        once.len(),
        "replay remains idempotent"
    );
}

#[test]
fn characterize_ordinary_v1_journal_growth_without_claiming_deadlines() {
    let temp = TempDir::new().unwrap();
    let mut store = SessionStore::open(temp.path()).unwrap();
    let (session, _) = recording_pair(&mut store);
    let before = store.journal_cost();
    for index in 1..=128 {
        store
            .recorder_action(
                session.clone(),
                RecorderAction::Marker {
                    host_time: 1 + index,
                    label: "fixed-sized-event".into(),
                },
            )
            .unwrap();
        if [16, 32, 64, 128].contains(&index) {
            let cost = store.journal_cost();
            println!(
                "JOURNAL_COST records={index} validated={} copied={} written={} write_calls={} sync_calls={} elapsed_ns={}",
                cost.bytes_validated - before.bytes_validated,
                cost.bytes_copied - before.bytes_copied,
                cost.bytes_written - before.bytes_written,
                cost.write_calls - before.write_calls,
                cost.sync_calls - before.sync_calls,
                cost.elapsed_nanoseconds - before.elapsed_nanoseconds
            );
        }
    }
    let cost = store.journal_cost();
    assert_eq!(cost.appends - before.appends, 128);
    assert_eq!(
        cost.bytes_validated - before.bytes_validated,
        cost.bytes_copied - before.bytes_copied
    );
    assert_eq!(cost.write_calls - before.write_calls, 128 * 3);
    assert_eq!(cost.sync_calls - before.sync_calls, 128 * 2);
}
use std::sync::atomic::{AtomicBool, Ordering};

#[test]
fn store_opens_during_live_appends_never_break_them() {
    const APPENDS: u64 = 150;
    let temp = TempDir::new().unwrap();
    let root = temp.path().to_path_buf();
    let mut store = SessionStore::open(&root).unwrap();
    let (session, _) = recording_pair(&mut store);
    let done = Arc::new(AtomicBool::new(false));
    let opener = {
        let done = Arc::clone(&done);
        let root = root.clone();
        std::thread::spawn(move || {
            let (mut opens, mut failed_opens, mut first_error) = (0_u32, 0_u32, None);
            while !done.load(Ordering::Acquire) {
                match SessionStore::open(&root) {
                    Ok(other) => drop(other),
                    Err(error) => {
                        failed_opens += 1;
                        first_error.get_or_insert_with(|| format!("{error:?}"));
                    }
                }
                opens += 1;
            }
            (opens, failed_opens, first_error)
        })
    };
    let mut failed_appends = 0_u64;
    for index in 0..APPENDS {
        let marker = RecorderAction::Marker {
            host_time: 1 + index,
            label: format!("marker {index}"),
        };
        if store.recorder_action(session.clone(), marker).is_err() {
            failed_appends += 1;
        }
    }
    done.store(true, Ordering::Release);
    let (opens, failed_opens, first_error) = opener.join().unwrap();
    assert!(opens > 0);
    assert_eq!(
        (failed_appends, failed_opens),
        (0, 0),
        "{failed_appends} of {APPENDS} appends and {failed_opens} of {opens} opens failed; first open error: {first_error:?}"
    );
    let journaled = journal_records(&store, &session)
        .iter()
        .filter(|record| record.body.event_kind == "marker_added")
        .count() as u64;
    assert_eq!(journaled, APPENDS);
    assert_eq!(
        store
            .recorder_detail(&session)
            .unwrap()
            .events
            .iter()
            .filter(|event| event.kind == "marker_added")
            .count() as u64,
        APPENDS,
        "every journaled marker is projected"
    );
}

#[test]
fn a_live_replacement_survives_another_open_and_a_stale_one_does_not() {
    let temp = TempDir::new().unwrap();
    let mut store = SessionStore::open(temp.path()).unwrap();
    let (session, _) = recording_pair(&mut store);
    let directory = store.session_directory(&session.0).unwrap();
    let journal = directory.join(JOURNAL_NAME);
    let before = fs::read(&journal).unwrap();
    let name = format!(".open-scribe-journal-{}.tmp", Uuid::now_v7());
    let mut partial = before.clone();
    partial.extend_from_slice(b"{\"version\":");

    let live = journal_replacement::LiveReplacement::begin(name.clone());
    fs::write(directory.join(&name), &partial).unwrap();
    drop(SessionStore::open(temp.path()).unwrap());
    assert!(
        directory.join(&name).exists(),
        "a replacement a live append owns is not stale"
    );
    assert_eq!(fs::read(&journal).unwrap(), before);

    drop(live);
    drop(SessionStore::open(temp.path()).unwrap());
    assert!(
        !directory.join(&name).exists(),
        "an unowned partial replacement is still discarded"
    );
    assert_eq!(fs::read(&journal).unwrap(), before);
}
