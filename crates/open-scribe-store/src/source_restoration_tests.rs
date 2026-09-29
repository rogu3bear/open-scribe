//! G1/G5: after a source fails the user may pause, choose the scope of the next
//! span, and resume. A reselected kind is a new source (ADR 0005 source-added,
//! ADR 0007 restoration), and the next span always holds a source that can capture.
use super::*;

/// System audio fails during Recording while the microphone continues; the
/// recording then pauses with every source sealed.
fn paused_after_system_failure(
    store: &mut SessionStore,
) -> (SessionId, Vec<MediaOpenAuthorization>) {
    let (session, sources) = recording_pair(store);
    seal(store, &sources[1], 1_000_000_001, 48_000);
    let failure = store
        .record_source_failure(system_failure(&session))
        .unwrap();
    assert!(failure.recording_continues);
    store
        .recorder_action(session.clone(), RecorderAction::BeginPause)
        .unwrap();
    seal(store, &sources[0], 1_000_000_001, 48_000);
    store
        .recorder_action(
            session.clone(),
            RecorderAction::CompletePause {
                host_time: 2_000_000_001,
            },
        )
        .unwrap();
    (session, sources)
}

fn system_failure(session: &SessionId) -> SourceFailureRequest {
    SourceFailureRequest {
        session_id: session.clone(),
        source_kind: MediaSourceKind::SystemAudio,
        reason: SourceFailureReason::CaptureFailed,
    }
}

fn select_system_scope(store: &mut SessionStore, session: &SessionId) {
    store
        .recorder_action(
            session.clone(),
            RecorderAction::SelectAudio {
                kind: Some(MediaSourceKind::SystemAudio),
                identity: "system".into(),
                display_name: "All computer audio".into(),
            },
        )
        .unwrap();
}

/// Resumes the microphone on its track and the reselected system audio as a
/// newly authorized source, the way the recorder's resume path does.
fn resume_with_restored_system(
    store: &mut SessionStore,
    session: &SessionId,
    microphone: &MediaOpenAuthorization,
    host: u64,
) -> (MediaOpenAuthorization, MediaOpenAuthorization) {
    store
        .recorder_action(session.clone(), RecorderAction::PrepareResume)
        .unwrap();
    let microphone_next = store
        .authorize_next_segment(session.clone(), microphone.segment_id.clone())
        .unwrap();
    create_media(store, &microphone_next);
    let restored = store
        .authorize_media_open(AuthorizeMediaOpenRequest {
            session_id: session.clone(),
            source_kind: MediaSourceKind::SystemAudio,
            source_display_name: "All computer audio".into(),
        })
        .expect("a kind reselected after its failure is authorized as a new source");
    create_media(store, &restored);
    store
        .recorder_action(
            session.clone(),
            RecorderAction::AnchorResume { host_time: host },
        )
        .unwrap();
    capture(store, &microphone_next, host, 48_000);
    capture(store, &restored, host, 48_000);
    (microphone_next, restored)
}

fn finding_for(recovery: &LibraryRecovery, session: &SessionId) -> Option<RecoveryDisposition> {
    recovery
        .findings
        .iter()
        .find(|finding| &finding.session_id == session)
        .map(|finding| finding.disposition)
}

/// G1: a failed source stays retired until its kind is selected again; resume
/// alone cannot authorize the retired kind back into the plan.
#[test]
fn a_failed_kind_is_not_reauthorized_without_a_new_scope() {
    let temp = TempDir::new().unwrap();
    let mut store = SessionStore::open(temp.path()).unwrap();
    let (session, _) = paused_after_system_failure(&mut store);
    store
        .recorder_action(session.clone(), RecorderAction::PrepareResume)
        .unwrap();
    let refused = store.authorize_media_open(AuthorizeMediaOpenRequest {
        session_id: session.clone(),
        source_kind: MediaSourceKind::SystemAudio,
        source_display_name: "All computer audio".into(),
    });
    assert!(
        matches!(refused, Err(StoreError::InvalidState(_))),
        "a retired kind needs a new scope: {refused:?}"
    );
}

/// G1: reselecting the kind of a failed source while paused must not make
/// Resume fail on the retired source.
#[test]
fn reselecting_a_failed_kind_while_paused_resumes_with_a_new_source() {
    let temp = TempDir::new().unwrap();
    let mut store = SessionStore::open(temp.path()).unwrap();
    let (session, sources) = paused_after_system_failure(&mut store);
    select_system_scope(&mut store, &session);
    let (microphone_next, restored) =
        resume_with_restored_system(&mut store, &session, &sources[0], 120_000_000_001);
    assert_ne!(restored.source_id, sources[1].source_id);
    assert_ne!(restored.track_id, sources[1].track_id);
    let recording = store.confirm_recording(session.clone()).unwrap();
    assert_eq!(
        recording.active_sources,
        vec![MediaSourceKind::Microphone, MediaSourceKind::SystemAudio]
    );
    seal(&mut store, &microphone_next, 121_000_000_001, 48_000);
    seal(&mut store, &restored, 121_000_000_001, 48_000);
    assert_eq!(
        store.recorder_detail(&session).unwrap().lifecycle,
        "ready_for_review"
    );
    assert_eq!(
        store.playback_timeline(&session).unwrap().len(),
        4,
        "both spans of both kinds play"
    );
    drop(store);

    let mut store = SessionStore::open(temp.path()).unwrap();
    let recovery = store.recover_library().unwrap();
    assert_eq!(finding_for(&recovery, &session), None);
    assert_eq!(store.playback_timeline(&session).unwrap().len(), 4);
}

/// G1: the restored source can fail again. Its failure is new evidence for the
/// new source, not a retry of the first one, and relaunch accepts both.
#[test]
fn a_restored_source_that_fails_again_is_its_own_failure() {
    let temp = TempDir::new().unwrap();
    let mut store = SessionStore::open(temp.path()).unwrap();
    let (session, sources) = paused_after_system_failure(&mut store);
    select_system_scope(&mut store, &session);
    let (_microphone_next, restored) =
        resume_with_restored_system(&mut store, &session, &sources[0], 120_000_000_001);
    store.confirm_recording(session.clone()).unwrap();
    seal(&mut store, &restored, 121_000_000_001, 48_000);
    let second = store
        .record_source_failure(system_failure(&session))
        .unwrap();
    assert!(second.recording_continues);
    let retry = store
        .record_source_failure(system_failure(&session))
        .unwrap();
    assert_eq!(
        retry.last_journal_sequence, second.last_journal_sequence,
        "a retry returns the accepted evidence"
    );
    let failures: Vec<_> = journal_records(&store, &session)
        .into_iter()
        .filter(|record| record.body.event_kind == "source_failed")
        .collect();
    assert_eq!(failures.len(), 2);
    assert_eq!(
        failures[1].body.payload["source_id"],
        json!(restored.source_id)
    );
    let detail = store.recorder_detail(&session).unwrap();
    assert_eq!(
        detail.lifecycle, "recording",
        "the microphone keeps recording"
    );
    let failure_events: Vec<_> = detail
        .events
        .iter()
        .filter(|event| event.kind == "source_failed")
        .collect();
    assert_eq!(failure_events.len(), 2, "each failure is a recorder event");
    assert_eq!(
        failure_events
            .iter()
            .map(|event| event.id.as_str())
            .collect::<Vec<_>>(),
        failures
            .iter()
            .map(|record| record.body.event_id.as_str())
            .collect::<Vec<_>>()
    );
    assert!(failure_events.iter().all(|event| !event.label.is_empty()));
    assert!(
        0 < failure_events[0].session_nanoseconds
            && failure_events[0].session_nanoseconds < failure_events[1].session_nanoseconds,
        "each failure sits where its source stopped: {failure_events:?}"
    );
    // The process dies while the microphone is still capturing.
    drop(store);

    let mut store = SessionStore::open(temp.path()).unwrap();
    let recovery = store.recover_library().unwrap();
    assert_eq!(
        finding_for(&recovery, &session),
        Some(RecoveryDisposition::PlayableMediaRecovered)
    );
    assert_eq!(store.playback_timeline(&session).unwrap().len(), 4);
    drop(store);

    let mut store = SessionStore::open(temp.path()).unwrap();
    let recovery = store.recover_library().unwrap();
    assert_eq!(finding_for(&recovery, &session), None);
}

/// G5: after the microphone fails, a scope without any other kind would leave
/// the next span with nothing that can capture. The store refuses it, keeps the
/// plan, and the paused session still finalizes on relaunch.
#[test]
fn a_scope_without_a_capturable_source_is_refused_after_a_microphone_failure() {
    let temp = TempDir::new().unwrap();
    let mut store = SessionStore::open(temp.path()).unwrap();
    let (session, sources) = recording_pair(&mut store);
    seal(&mut store, &sources[0], 1_000_000_001, 48_000);
    store
        .record_source_failure(SourceFailureRequest {
            session_id: session.clone(),
            source_kind: MediaSourceKind::Microphone,
            reason: SourceFailureReason::CaptureFailed,
        })
        .unwrap();
    store
        .recorder_action(session.clone(), RecorderAction::BeginPause)
        .unwrap();
    seal(&mut store, &sources[1], 1_000_000_001, 48_000);
    store
        .recorder_action(
            session.clone(),
            RecorderAction::CompletePause {
                host_time: 2_000_000_001,
            },
        )
        .unwrap();
    let refused = store.recorder_action(
        session.clone(),
        RecorderAction::SelectAudio {
            kind: None,
            identity: "microphone".into(),
            display_name: "Microphone only".into(),
        },
    );
    assert!(
        matches!(refused, Err(StoreError::InvalidState(_))),
        "a scope with no capturable source is refused"
    );
    assert!(
        journal_records(&store, &session)
            .iter()
            .all(|record| record.body.event_kind != "source_scope_selected"),
        "nothing is journaled for a refused scope"
    );
    drop(store);

    let mut store = SessionStore::open(temp.path()).unwrap();
    let recovery = store.recover_library().unwrap();
    assert_ne!(
        finding_for(&recovery, &session),
        Some(RecoveryDisposition::IntegrityMismatch)
    );
    assert_eq!(
        store.recorder_detail(&session).unwrap().lifecycle,
        "ready_for_review"
    );
    assert_eq!(store.playback_timeline(&session).unwrap().len(), 2);
}
