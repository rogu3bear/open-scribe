//! P4: every recovered segment the launch lists must lease for playback, and
//! one launch hashes each sealed segment at most once.
use super::*;
use std::time::Instant;

/// Recording died right after both sources reserved and opened a successor and
/// sealed their first segment; the successors never received a sample.
fn killed_after_successor_reserved(
    store: &mut SessionStore,
) -> (SessionId, Vec<MediaOpenAuthorization>) {
    let (session, sources) = recording_pair(store);
    for a in &sources {
        let next = store
            .authorize_next_segment(session.clone(), a.segment_id.clone())
            .unwrap();
        create_media(store, &next);
        seal(store, a, 1_000_000_001, 48_000);
    }
    (session, sources)
}

/// Leases every listed row of `session` the way the app's segment rows and the
/// menu bar's "Play Recovered Audio" do, and returns how many rows there were.
fn lease_every_row(store: &SessionStore, recovery: &LibraryRecovery, session: &SessionId) -> usize {
    let rows: Vec<_> = recovery
        .playable
        .iter()
        .filter(|row| &row.session_id == session)
        .collect();
    for row in &rows {
        let lease = store
            .lease_recovered_playback(
                &row.session_id,
                &row.source_id,
                &row.track_id,
                &row.segment_id,
            )
            .unwrap_or_else(|error| {
                panic!("listed segment {} must lease: {error}", row.segment_id)
            });
        assert_eq!(lease.byte_length(), row.byte_length);
        assert_eq!(lease.digest_sha256(), row.digest_sha256);
    }
    rows.len()
}

/// F4: a session finalized through `timeline_recovered` lists its sealed
/// segments; the lease must accept the same evidence the listing accepted.
#[test]
fn kill_after_successor_reserved_lists_and_leases_every_recovered_segment() {
    let temp = TempDir::new().unwrap();
    let mut store = SessionStore::open(temp.path()).unwrap();
    let (session, _) = killed_after_successor_reserved(&mut store);
    drop(store);

    let mut store = SessionStore::open(temp.path()).unwrap();
    let recovery = store.recover_library().unwrap();
    assert_eq!(lease_every_row(&store, &recovery, &session), 2);
    assert_eq!(
        store.playback_timeline(&session).unwrap().len(),
        2,
        "synchronized playback sees the same two segments"
    );
    drop(store);

    let mut store = SessionStore::open(temp.path()).unwrap();
    let recovery = store.recover_library().unwrap();
    assert_eq!(lease_every_row(&store, &recovery, &session), 2);
}

/// F4: the P3 quit-while-paused finalization is listed and must lease too.
#[test]
fn quit_while_paused_session_leases_recovered_playback() {
    let temp = TempDir::new().unwrap();
    let mut store = SessionStore::open(temp.path()).unwrap();
    let (session, _) = paused_pair(&mut store);
    drop(store);

    let mut store = SessionStore::open(temp.path()).unwrap();
    let recovery = store.recover_library().unwrap();
    assert_eq!(lease_every_row(&store, &recovery, &session), 2);
}

/// F15 seam: a launch that replays, finalizes, and lists a session hashes each
/// sealed segment at most once.
#[test]
fn launch_hashes_each_recovered_segment_at_most_once() {
    let temp = TempDir::new().unwrap();
    let mut store = SessionStore::open(temp.path()).unwrap();
    let (session, _) = killed_after_successor_reserved(&mut store);
    drop(store);

    let mut store = SessionStore::open(temp.path()).unwrap();
    let recovery = store.recover_library().unwrap();
    let listed = recovery
        .playable
        .iter()
        .filter(|row| row.session_id == session)
        .count() as u64;
    assert_eq!(listed, 2);
    assert!(
        store.digest_computations() <= listed,
        "launch hashed {} times for {listed} listed segments",
        store.digest_computations()
    );
}

/// Fixture of 200 sealed five-second segments (two sources, 100 each) killed
/// right after the next successors were reserved. Prints launch timing.
#[test]
fn two_hundred_segment_library_relaunch_hashes_each_segment_once() {
    const SEGMENTS_PER_SOURCE: u64 = 100;
    const SAMPLES: u64 = 240_000;
    let temp = TempDir::new().unwrap();
    let mut store = SessionStore::open(temp.path()).unwrap();
    let (session, sources) = recording_pair(&mut store);
    let mut current = sources;
    let mut written = vec![48_000_u64; current.len()];
    for index in 1..SEGMENTS_PER_SOURCE {
        let host = 1 + index * 5_000_000_000;
        for slot in 0..current.len() {
            let next = store
                .authorize_next_segment(session.clone(), current[slot].segment_id.clone())
                .unwrap();
            create_media(&mut store, &next);
            capture(&mut store, &next, host, SAMPLES);
            seal(&mut store, &current[slot], host, written[slot]);
            current[slot] = next;
            written[slot] = SAMPLES;
        }
    }
    for a in &current {
        store
            .authorize_next_segment(session.clone(), a.segment_id.clone())
            .unwrap();
    }
    drop(store);
    let expected = 2 * SEGMENTS_PER_SOURCE;

    let mut store = SessionStore::open(temp.path()).unwrap();
    let started = Instant::now();
    let recovery = store.recover_library().unwrap();
    let fresh = started.elapsed();
    let listed = recovery
        .playable
        .iter()
        .filter(|row| row.session_id == session)
        .count() as u64;
    assert_eq!(listed, expected);
    let fresh_digests = store.digest_computations();
    eprintln!(
        "P4 fixture: fresh recovery of {listed} segments took {fresh:?}; {fresh_digests} digest computations"
    );
    assert!(
        fresh_digests <= expected,
        "fresh launch hashed {fresh_digests} times for {expected} segments"
    );
    drop(store);

    let mut store = SessionStore::open(temp.path()).unwrap();
    let started = Instant::now();
    let recovery = store.recover_library().unwrap();
    let steady = started.elapsed();
    let listed = recovery
        .playable
        .iter()
        .filter(|row| row.session_id == session)
        .count() as u64;
    assert_eq!(listed, expected);
    let steady_digests = store.digest_computations();
    eprintln!(
        "P4 fixture: steady-state relaunch of {listed} segments took {steady:?}; {steady_digests} digest computations"
    );
    assert!(steady_digests <= expected);
    assert_eq!(
        lease_every_row(&store, &recovery, &session),
        expected as usize
    );
}
