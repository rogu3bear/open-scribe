//! P5: a reserved-but-unopened successor (a rotation that failed after
//! authorization) is abandoned durably so a later seal finalizes the session.
use super::*;

fn seg_lifecycle(store: &SessionStore, segment: &str) -> String {
    store
        .connection
        .query_row(
            "SELECT lifecycle FROM segments WHERE id = ?1",
            [segment],
            |r| r.get(0),
        )
        .unwrap()
}

fn session_i64(store: &SessionStore, session: &SessionId, column: &str) -> i64 {
    store
        .connection
        .query_row(
            &format!("SELECT {column} FROM sessions WHERE id = ?1"),
            [&session.0],
            |r| r.get(0),
        )
        .unwrap()
}

#[test]
fn abandoning_a_reserved_successor_lets_stop_finalize_cleanly() {
    let temp = TempDir::new().unwrap();
    let mut store = SessionStore::open(temp.path()).unwrap();
    let (session, sources) = recording_pair(&mut store);
    let successor = store
        .authorize_next_segment(session.clone(), sources[0].segment_id.clone())
        .unwrap();
    assert_eq!(session_i64(&store, &session, "media_files_open"), 1);

    store
        .abandon_reserved_segment(session.clone(), successor.segment_id.clone())
        .unwrap();
    assert_eq!(seg_lifecycle(&store, &successor.segment_id), "gap");
    // The predecessor stays the active segment and media is still open.
    assert_eq!(seg_lifecycle(&store, &sources[0].segment_id), "capturing");
    assert_eq!(session_i64(&store, &session, "media_files_open"), 1);

    seal(&mut store, &sources[0], 1_000_000_001, 48_000);
    seal(&mut store, &sources[1], 1_000_000_001, 48_000);
    assert_eq!(
        store.recorder_detail(&session).unwrap().lifecycle,
        "ready_for_review"
    );
    assert_eq!(session_i64(&store, &session, "media_files_open"), 0);
    assert_eq!(store.playback_timeline(&session).unwrap().len(), 2);
}

#[test]
fn abandon_is_idempotent_and_rejects_captured_segments() {
    let temp = TempDir::new().unwrap();
    let mut store = SessionStore::open(temp.path()).unwrap();
    let (session, sources) = recording_pair(&mut store);
    let successor = store
        .authorize_next_segment(session.clone(), sources[0].segment_id.clone())
        .unwrap();

    store
        .abandon_reserved_segment(session.clone(), successor.segment_id.clone())
        .unwrap();
    // A second abandon of the same segment is a durable no-op.
    store
        .abandon_reserved_segment(session.clone(), successor.segment_id.clone())
        .unwrap();
    assert_eq!(
        store
            .connection
            .query_row(
                "SELECT COUNT(*) FROM session_events WHERE session_id = ?1 AND event_kind = 'segment_capture_gap'",
                [&session.0],
                |r| r.get::<_, i64>(0),
            )
            .unwrap(),
        1,
        "the abandon is journaled exactly once"
    );
    // A captured segment (its first sample was accepted) is never abandonable.
    assert!(matches!(
        store.abandon_reserved_segment(session.clone(), sources[0].segment_id.clone()),
        Err(StoreError::InvalidState(
            "segment is not an abandonable reserved successor"
        ))
    ));
}

#[test]
fn crash_after_abandon_recovers_the_predecessor_and_keeps_the_gap() {
    let temp = TempDir::new().unwrap();
    let mut store = SessionStore::open(temp.path()).unwrap();
    let (session, sources) = recording_pair(&mut store);
    let successor = store
        .authorize_next_segment(session.clone(), sources[0].segment_id.clone())
        .unwrap();
    store
        .abandon_reserved_segment(session.clone(), successor.segment_id.clone())
        .unwrap();
    drop(store);

    let mut store = SessionStore::open(temp.path()).unwrap();
    let recovered = store.recover_playable_sessions().unwrap();
    assert_eq!(
        recovered.iter().filter(|r| r.session_id == session).count(),
        2,
        "both capturing predecessors recover"
    );
    assert_eq!(seg_lifecycle(&store, &successor.segment_id), "gap");
    assert_eq!(
        store.recorder_detail(&session).unwrap().lifecycle,
        "ready_for_review"
    );
    assert_eq!(session_i64(&store, &session, "media_files_open"), 0);
}

/// G8: a rotation completed (successor open, predecessor sealed) but the
/// successor's first sample never arrived. Abandoning it leaves the source on
/// its sealed media, so the failure retires only that source.
#[test]
fn an_unstarted_successor_after_rotation_is_abandoned_and_its_source_retired() {
    let temp = TempDir::new().unwrap();
    let mut store = SessionStore::open(temp.path()).unwrap();
    let (session, sources) = recording_pair(&mut store);
    let successor = store
        .authorize_next_segment(session.clone(), sources[1].segment_id.clone())
        .unwrap();
    create_media(&mut store, &successor);
    seal(&mut store, &sources[1], 1_000_000_001, 48_000);
    store
        .abandon_reserved_segment(session.clone(), successor.segment_id.clone())
        .unwrap();
    assert_eq!(seg_lifecycle(&store, &successor.segment_id), "gap");
    let failure = store
        .record_source_failure(SourceFailureRequest {
            session_id: session.clone(),
            source_kind: MediaSourceKind::SystemAudio,
            reason: SourceFailureReason::CaptureFailed,
        })
        .expect("the source rests on its sealed media and can be retired");
    assert!(failure.recording_continues);
    assert_eq!(
        store.recorder_detail(&session).unwrap().lifecycle,
        "recording"
    );
    assert_eq!(session_i64(&store, &session, "media_files_open"), 1);

    seal(&mut store, &sources[0], 1_000_000_001, 48_000);
    assert_eq!(
        store.recorder_detail(&session).unwrap().lifecycle,
        "ready_for_review"
    );
    assert_eq!(session_i64(&store, &session, "media_files_open"), 0);
    assert_eq!(store.playback_timeline(&session).unwrap().len(), 2);
}

/// G9: an abandoned successor stays on its track as a gap. A later resume must
/// still authorize the next segment after the sealed predecessor.
#[test]
fn a_track_with_an_abandoned_successor_resumes_after_a_pause() {
    let temp = TempDir::new().unwrap();
    let mut store = SessionStore::open(temp.path()).unwrap();
    let (session, sources) = recording_pair(&mut store);
    store
        .recorder_action(session.clone(), RecorderAction::BeginPause)
        .unwrap();
    // A rotation during the pause drain failed after reserving its successor.
    let abandoned = store
        .authorize_next_segment(session.clone(), sources[0].segment_id.clone())
        .unwrap();
    store
        .abandon_reserved_segment(session.clone(), abandoned.segment_id.clone())
        .unwrap();
    for source in &sources {
        seal(&mut store, source, 1_000_000_001, 48_000);
    }
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
    let mut resumed = Vec::new();
    for source in &sources {
        let next = store
            .authorize_next_segment(session.clone(), source.segment_id.clone())
            .expect("the sealed predecessor still takes one successor");
        create_media(&mut store, &next);
        resumed.push(next);
    }
    assert_ne!(
        resumed[0].relative_path, abandoned.relative_path,
        "the abandoned file keeps its own path"
    );
    store
        .recorder_action(
            session.clone(),
            RecorderAction::AnchorResume {
                host_time: 120_000_000_001,
            },
        )
        .unwrap();
    for next in &resumed {
        capture(&mut store, next, 120_000_000_001, 48_000);
    }
    store.confirm_recording(session.clone()).unwrap();
    for next in &resumed {
        seal(&mut store, next, 121_000_000_001, 48_000);
    }
    assert_eq!(
        store.recorder_detail(&session).unwrap().lifecycle,
        "ready_for_review"
    );
    assert_eq!(store.playback_timeline(&session).unwrap().len(), 4);
}
