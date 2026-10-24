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

fn retire_sealed_microphone(
    store: &mut SessionStore,
) -> (SessionId, Vec<MediaOpenAuthorization>, Vec<u8>) {
    let (session, sources) = recording_pair(store);
    seal(store, &sources[0], 1_000_000_001, 48_000);
    let sealed = std::fs::read(&sources[0].absolute_path).unwrap();
    let failure = store
        .record_source_failure(SourceFailureRequest {
            session_id: session.clone(),
            source_kind: MediaSourceKind::Microphone,
            reason: SourceFailureReason::CaptureFailed,
        })
        .unwrap();
    assert!(failure.recording_continues);
    assert!(!failure.session_interrupted);
    (session, sources, sealed)
}

fn required_microphone_lifecycle(store: &SessionStore, session: &SessionId) -> String {
    store
        .connection
        .query_row(
            "SELECT lifecycle FROM required_sources WHERE session_id = ?1 AND kind = 'microphone'",
            [&session.0],
            |row| row.get(0),
        )
        .unwrap()
}

fn segment_lifecycle(store: &SessionStore, segment: &str) -> String {
    store
        .connection
        .query_row(
            "SELECT lifecycle FROM segments WHERE id = ?1",
            [segment],
            |row| row.get(0),
        )
        .unwrap()
}

/// AC-2 / AC-24: an explicit restore adds a new microphone source in the same
/// session. System audio keeps its current segment. The sealed microphone file
/// does not change, and the failure stays in the activity log.
#[test]
fn explicit_microphone_restore_adds_a_new_source_while_system_audio_continues() {
    let temp = TempDir::new().unwrap();
    let mut store = SessionStore::open(temp.path()).unwrap();
    let (session, sources, sealed_microphone) = retire_sealed_microphone(&mut store);
    let system_source = sources[1].source_id.clone();
    let refused = store.authorize_media_open(AuthorizeMediaOpenRequest {
        session_id: session.clone(),
        source_kind: MediaSourceKind::Microphone,
        source_display_name: "microphone".into(),
    });
    assert!(
        matches!(refused, Err(StoreError::InvalidState(_))),
        "resume-style authorization does not restore a retired microphone: {refused:?}"
    );

    store
        .recorder_action(session.clone(), RecorderAction::RestoreMicrophone)
        .unwrap();
    assert_eq!(required_microphone_lifecycle(&store, &session), "required");
    let restored = store
        .authorize_media_open(AuthorizeMediaOpenRequest {
            session_id: session.clone(),
            source_kind: MediaSourceKind::Microphone,
            source_display_name: "microphone".into(),
        })
        .unwrap();
    assert_ne!(restored.source_id, sources[0].source_id);
    assert_ne!(restored.track_id, sources[0].track_id);
    assert_eq!(
        store
            .connection
            .query_row(
                "SELECT id FROM sources WHERE session_id = ?1 AND kind = 'system_audio' AND lifecycle = 'capturing'",
                [&session.0],
                |row| row.get::<_, String>(0),
            )
            .unwrap(),
        system_source,
        "system audio is not interrupted by the microphone restore"
    );
    create_media(&mut store, &restored);
    capture(&mut store, &restored, 2_000_000_001, 48_000);
    assert_eq!(
        std::fs::read(&sources[0].absolute_path).unwrap(),
        sealed_microphone
    );
    seal(&mut store, &restored, 3_000_000_001, 48_000);
    seal(&mut store, &sources[1], 3_000_000_001, 48_000);
    assert_eq!(
        store.recorder_detail(&session).unwrap().lifecycle,
        "ready_for_review"
    );
    let detail = store.recorder_detail(&session).unwrap();
    assert_eq!(
        detail
            .events
            .iter()
            .filter(|event| event.kind == "source_failed")
            .count(),
        1,
        "the original microphone failure stays marked"
    );
    assert!(
        detail
            .events
            .iter()
            .any(|event| event.kind == "microphone_restore_requested")
    );
    let plan = store.playback_timeline(&session).unwrap();
    assert_eq!(
        plan.len(),
        3,
        "earlier microphone, later microphone, system audio"
    );
    let earlier = plan
        .iter()
        .find(|segment| segment.segment_id == sources[0].segment_id)
        .unwrap();
    let later = plan
        .iter()
        .find(|segment| segment.segment_id == restored.segment_id)
        .unwrap();
    assert_ne!(earlier.track_id, later.track_id);
    assert!(later.start_nanoseconds > earlier.start_nanoseconds);
    assert_eq!(
        plan.iter()
            .filter(|segment| segment.track_id == sources[1].track_id)
            .count(),
        1
    );
    assert_eq!(
        std::fs::read(&sources[0].absolute_path).unwrap(),
        sealed_microphone
    );
}

/// AC-3: reconnect from pause authorizes a new microphone during prepare-resume.
/// The sealed microphone cannot take a successor.
#[test]
fn microphone_restore_from_pause_authorizes_a_new_source() {
    let temp = TempDir::new().unwrap();
    let mut store = SessionStore::open(temp.path()).unwrap();
    let (session, sources, sealed_microphone) = retire_sealed_microphone(&mut store);
    store
        .recorder_action(session.clone(), RecorderAction::BeginPause)
        .unwrap();
    seal(&mut store, &sources[1], 1_500_000_001, 48_000);
    store
        .recorder_action(
            session.clone(),
            RecorderAction::CompletePause {
                host_time: 2_000_000_001,
            },
        )
        .unwrap();
    store
        .recorder_action(session.clone(), RecorderAction::RestoreMicrophone)
        .unwrap();
    assert_eq!(required_microphone_lifecycle(&store, &session), "required");
    store
        .recorder_action(session.clone(), RecorderAction::PrepareResume)
        .unwrap();
    let restored = store
        .authorize_media_open(AuthorizeMediaOpenRequest {
            session_id: session.clone(),
            source_kind: MediaSourceKind::Microphone,
            source_display_name: "microphone".into(),
        })
        .expect("paused restore authorizes a new microphone during prepare");
    let system = store
        .authorize_next_segment(session.clone(), sources[1].segment_id.clone())
        .unwrap();
    let successor = store.authorize_next_segment(session.clone(), sources[0].segment_id.clone());
    assert!(
        matches!(successor, Err(StoreError::InvalidState(_))),
        "the sealed microphone does not gain a successor: {successor:?}"
    );
    assert_ne!(restored.source_id, sources[0].source_id);
    create_media(&mut store, &restored);
    create_media(&mut store, &system);
    store
        .recorder_action(
            session.clone(),
            RecorderAction::AnchorResume {
                host_time: 3_000_000_001,
            },
        )
        .unwrap();
    capture(&mut store, &restored, 3_000_000_001, 48_000);
    capture(&mut store, &system, 3_000_000_001, 48_000);
    store.confirm_recording(session.clone()).unwrap();
    assert_eq!(
        std::fs::read(&sources[0].absolute_path).unwrap(),
        sealed_microphone
    );
    seal(&mut store, &restored, 4_000_000_001, 48_000);
    seal(&mut store, &system, 4_000_000_001, 48_000);
    assert_eq!(
        store.recorder_detail(&session).unwrap().lifecycle,
        "ready_for_review"
    );
    assert_eq!(store.playback_timeline(&session).unwrap().len(), 4);
}

/// AC-4: resume without the restore action still cannot authorize the microphone.
#[test]
fn resume_without_microphone_restore_leaves_the_microphone_retired() {
    let temp = TempDir::new().unwrap();
    let mut store = SessionStore::open(temp.path()).unwrap();
    let (session, sources, _) = retire_sealed_microphone(&mut store);
    store
        .recorder_action(session.clone(), RecorderAction::BeginPause)
        .unwrap();
    seal(&mut store, &sources[1], 1_500_000_001, 48_000);
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
    let refused = store.authorize_media_open(AuthorizeMediaOpenRequest {
        session_id: session.clone(),
        source_kind: MediaSourceKind::Microphone,
        source_display_name: "microphone".into(),
    });
    assert!(matches!(refused, Err(StoreError::InvalidState(_))));
    assert_eq!(required_microphone_lifecycle(&store, &session), "failed");
    assert!(
        store
            .recorder_detail(&session)
            .unwrap()
            .events
            .iter()
            .all(|event| event.kind != "microphone_restore_requested")
    );
}

/// AC-12: a microphone-only interruption is not an open recording, so restore
/// cannot start another conversation.
#[test]
fn microphone_restore_refuses_a_microphone_only_interruption() {
    let temp = TempDir::new().unwrap();
    let mut store = SessionStore::open(temp.path()).unwrap();
    let session = store
        .prepare_session_with_required_sources(
            PrepareSessionRequest {
                title: "Microphone only".into(),
                origin: SessionOrigin::Capture,
            },
            vec![MediaSourceKind::Microphone],
        )
        .unwrap()
        .session_id;
    store
        .interrupt_session(InterruptSessionRequest {
            session_id: session.clone(),
            reason: SessionInterruptionReason::CaptureFailed,
        })
        .unwrap();
    let refused = store.recorder_action(session, RecorderAction::RestoreMicrophone);
    assert!(matches!(refused, Err(StoreError::InvalidState(_))));
}

/// AC-16: cancelling a restore that never captured gaps the new segment, returns
/// the microphone to failed, and leaves the other source recording.
#[test]
fn cancelling_an_unstarted_microphone_restore_keeps_the_other_source() {
    let temp = TempDir::new().unwrap();
    let mut store = SessionStore::open(temp.path()).unwrap();
    let (session, sources, sealed_microphone) = retire_sealed_microphone(&mut store);
    store
        .recorder_action(session.clone(), RecorderAction::RestoreMicrophone)
        .unwrap();
    let restored = store
        .authorize_media_open(AuthorizeMediaOpenRequest {
            session_id: session.clone(),
            source_kind: MediaSourceKind::Microphone,
            source_display_name: "microphone".into(),
        })
        .unwrap();
    create_media(&mut store, &restored);
    store
        .recorder_action(session.clone(), RecorderAction::CancelMicrophoneRestore)
        .unwrap();
    assert_eq!(segment_lifecycle(&store, &restored.segment_id), "gap");
    assert_eq!(required_microphone_lifecycle(&store, &session), "failed");
    assert_eq!(
        store.recorder_detail(&session).unwrap().lifecycle,
        "recording"
    );
    assert_eq!(
        std::fs::read(&sources[0].absolute_path).unwrap(),
        sealed_microphone
    );
    store
        .recorder_action(session.clone(), RecorderAction::RestoreMicrophone)
        .expect("reconnect stays available after a failed attempt");
    store
        .recorder_action(session.clone(), RecorderAction::CancelMicrophoneRestore)
        .unwrap();
    assert_eq!(required_microphone_lifecycle(&store, &session), "failed");
    seal(&mut store, &sources[1], 2_000_000_001, 48_000);
    assert_eq!(
        store.recorder_detail(&session).unwrap().lifecycle,
        "ready_for_review"
    );
    assert_eq!(store.playback_timeline(&session).unwrap().len(), 2);
    assert_eq!(
        std::fs::read(&sources[0].absolute_path).unwrap(),
        sealed_microphone
    );
}

/// A crash after authorization still gaps the unstarted microphone on recovery.
#[test]
fn recovery_gaps_an_unstarted_microphone_restore() {
    let temp = TempDir::new().unwrap();
    let session = {
        let mut store = SessionStore::open(temp.path()).unwrap();
        let (session, _, _) = retire_sealed_microphone(&mut store);
        store
            .recorder_action(session.clone(), RecorderAction::RestoreMicrophone)
            .unwrap();
        let restored = store
            .authorize_media_open(AuthorizeMediaOpenRequest {
                session_id: session.clone(),
                source_kind: MediaSourceKind::Microphone,
                source_display_name: "microphone".into(),
            })
            .unwrap();
        assert_eq!(segment_lifecycle(&store, &restored.segment_id), "opening");
        session
    };
    let mut store = SessionStore::open(temp.path()).unwrap();
    store.recover_library().unwrap();
    assert_eq!(required_microphone_lifecycle(&store, &session), "failed");
    assert_eq!(
        store.recorder_detail(&session).unwrap().lifecycle,
        "ready_for_review",
        "a crashed recording closes once the unstarted microphone is a gap and captured audio is sealed"
    );
    let gaps: i64 = store
        .connection
        .query_row(
            "SELECT COUNT(*) FROM segments WHERE session_id = ?1 AND lifecycle = 'gap'",
            [&session.0],
            |row| row.get(0),
        )
        .unwrap();
    assert_eq!(gaps, 1);
    assert_eq!(store.playback_timeline(&session).unwrap().len(), 2);
    assert_eq!(
        store
            .recorder_detail(&session)
            .unwrap()
            .events
            .iter()
            .filter(|event| event.kind == "source_failed")
            .count(),
        1
    );
}

/// AC-10: a second restore after the new microphone stops is another source.
#[test]
fn a_second_microphone_restore_appends_another_source() {
    let temp = TempDir::new().unwrap();
    let mut store = SessionStore::open(temp.path()).unwrap();
    let (session, sources, _) = retire_sealed_microphone(&mut store);
    store
        .recorder_action(session.clone(), RecorderAction::RestoreMicrophone)
        .unwrap();
    let first = store
        .authorize_media_open(AuthorizeMediaOpenRequest {
            session_id: session.clone(),
            source_kind: MediaSourceKind::Microphone,
            source_display_name: "microphone".into(),
        })
        .unwrap();
    create_media(&mut store, &first);
    capture(&mut store, &first, 2_000_000_001, 48_000);
    seal(&mut store, &first, 3_000_000_001, 48_000);
    store
        .record_source_failure(SourceFailureRequest {
            session_id: session.clone(),
            source_kind: MediaSourceKind::Microphone,
            reason: SourceFailureReason::CaptureFailed,
        })
        .unwrap();
    store
        .recorder_action(session.clone(), RecorderAction::RestoreMicrophone)
        .unwrap();
    let second = store
        .authorize_media_open(AuthorizeMediaOpenRequest {
            session_id: session.clone(),
            source_kind: MediaSourceKind::Microphone,
            source_display_name: "microphone".into(),
        })
        .unwrap();
    assert_ne!(second.source_id, first.source_id);
    assert_ne!(second.source_id, sources[0].source_id);
    create_media(&mut store, &second);
    capture(&mut store, &second, 4_000_000_001, 48_000);
    seal(&mut store, &second, 5_000_000_001, 48_000);
    seal(&mut store, &sources[1], 5_000_000_001, 48_000);
    let failures = store
        .recorder_detail(&session)
        .unwrap()
        .events
        .into_iter()
        .filter(|event| event.kind == "source_failed")
        .count();
    assert_eq!(failures, 2);
    assert_eq!(store.playback_timeline(&session).unwrap().len(), 4);
}

/// AC-11: the microphone can be retired before any sample when the other source
/// has already captured, then an explicit restore records the first sample.
#[test]
fn an_unstarted_microphone_can_be_retired_and_restored() {
    let temp = TempDir::new().unwrap();
    let mut store = SessionStore::open(temp.path()).unwrap();
    let session = store
        .prepare_session_with_required_sources(
            PrepareSessionRequest {
                title: "Microphone missed its first sample".into(),
                origin: SessionOrigin::Capture,
            },
            vec![MediaSourceKind::Microphone, MediaSourceKind::SystemAudio],
        )
        .unwrap()
        .session_id;
    store
        .anchor_capture_clock(
            session.clone(),
            CaptureClock {
                host_anchor: 1,
                numerator: 1,
                denominator: 1,
            },
        )
        .unwrap();
    let microphone = store
        .authorize_media_open(AuthorizeMediaOpenRequest {
            session_id: session.clone(),
            source_kind: MediaSourceKind::Microphone,
            source_display_name: "microphone".into(),
        })
        .unwrap();
    let system = store
        .authorize_media_open(AuthorizeMediaOpenRequest {
            session_id: session.clone(),
            source_kind: MediaSourceKind::SystemAudio,
            source_display_name: "system_audio".into(),
        })
        .unwrap();
    create_media(&mut store, &microphone);
    create_media(&mut store, &system);
    capture(&mut store, &system, 1, 48_000);
    store
        .recorder_action(session.clone(), RecorderAction::RetireUnstartedMicrophone)
        .unwrap();
    assert_eq!(segment_lifecycle(&store, &microphone.segment_id), "gap");
    assert_eq!(required_microphone_lifecycle(&store, &session), "failed");
    let recording = store.confirm_recording(session.clone()).unwrap();
    assert_eq!(recording.active_sources, vec![MediaSourceKind::SystemAudio]);
    assert_eq!(
        store.recorder_detail(&session).unwrap().lifecycle,
        "recording"
    );
    store
        .recorder_action(session.clone(), RecorderAction::RestoreMicrophone)
        .unwrap();
    let restored = store
        .authorize_media_open(AuthorizeMediaOpenRequest {
            session_id: session.clone(),
            source_kind: MediaSourceKind::Microphone,
            source_display_name: "microphone".into(),
        })
        .unwrap();
    create_media(&mut store, &restored);
    capture(&mut store, &restored, 2_000_000_001, 48_000);
    seal(&mut store, &restored, 3_000_000_001, 48_000);
    seal(&mut store, &system, 3_000_000_001, 48_000);
    assert_eq!(
        store.recorder_detail(&session).unwrap().lifecycle,
        "ready_for_review"
    );
    let plan = store.playback_timeline(&session).unwrap();
    assert_eq!(
        plan.len(),
        2,
        "system audio and the first saved microphone span"
    );
    assert!(
        plan.iter()
            .any(|segment| segment.segment_id == restored.segment_id)
    );
    assert!(
        plan.iter()
            .all(|segment| segment.segment_id != microphone.segment_id)
    );
}
