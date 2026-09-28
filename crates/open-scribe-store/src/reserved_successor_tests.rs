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
