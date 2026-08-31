use super::*;

#[test]
fn runtime_library_snapshot_projects_recording_timer_and_required_sources() {
    let temp = TempDir::new().unwrap();
    let mut store = open_store(&temp);
    let (prepared, _, _) = prepared_dual_first_samples(&mut store);
    store
        .confirm_recording(prepared.session_id.clone())
        .unwrap();
    let started_at_ms = store
        .connection
        .query_row(
            "SELECT wall_time_ms FROM session_events
             WHERE session_id = ?1 AND event_kind = 'recording_started'",
            [&prepared.session_id.0],
            |row| row.get::<_, i64>(0),
        )
        .unwrap();

    let snapshot = store
        .runtime_library_snapshot_at(started_at_ms + 5_000)
        .unwrap();
    let current = snapshot.current_session.unwrap();

    assert_eq!(current.session_id, prepared.session_id);
    assert_eq!(current.lifecycle, "recording");
    assert_eq!(current.elapsed_seconds, 5);
    assert!(current.journal_durable);
    assert!(current.media_files_open);
    assert_eq!(current.sources.len(), 2);
    assert!(
        current
            .sources
            .iter()
            .all(|source| source.lifecycle == "capturing")
    );
    assert!(snapshot.saved_sessions.is_empty());

    store
        .interrupt_session(InterruptSessionRequest {
            session_id: prepared.session_id.clone(),
            reason: SessionInterruptionReason::CaptureFailed,
        })
        .unwrap();
    let interrupted = store
        .runtime_library_snapshot_at(started_at_ms + 7_000)
        .unwrap()
        .current_session
        .unwrap();
    assert_eq!(interrupted.lifecycle, "interrupted");
    assert_eq!(
        interrupted.interruption_reason,
        Some(SessionInterruptionReason::CaptureFailed)
    );
    assert!(
        interrupted
            .sources
            .iter()
            .all(|source| source.lifecycle == "failed")
    );
}

#[test]
fn runtime_library_snapshot_exposes_saved_session_without_fixture_state() {
    let temp = TempDir::new().unwrap();
    let mut store = open_store(&temp);
    let (prepared, microphone, system) = prepared_dual_first_samples(&mut store);
    store
        .confirm_recording(prepared.session_id.clone())
        .unwrap();
    for authorization in [&microphone, &system] {
        replace_with_recoverable_pcm_caf(authorization, 960);
        let byte_length = fs::metadata(&authorization.absolute_path).unwrap().len();
        store
            .seal_segment(seal_receipt(authorization, byte_length))
            .unwrap();
    }

    let snapshot = store.runtime_library_snapshot().unwrap();

    assert!(snapshot.current_session.is_none());
    assert_eq!(snapshot.saved_sessions.len(), 1);
    let saved = &snapshot.saved_sessions[0];
    assert_eq!(saved.session_id, prepared.session_id);
    assert_eq!(saved.lifecycle, "ready_for_review");
    assert_eq!(saved.sources.len(), 2);
    assert!(
        saved
            .sources
            .iter()
            .all(|source| source.lifecycle == "sealed")
    );
    assert!(!saved.recovered);
    let playable = saved.playable_media.as_ref().unwrap();
    assert_eq!(playable.source_display_name, "Mac microphone");
    assert_eq!(playable.sample_count, 960);
    assert_eq!(
        playable.availability,
        RuntimePlayableMediaAvailability::Available
    );
    assert!(playable.absolute_path.is_none());
    let lease = store.lease_imported_playback(&prepared.session_id).unwrap();
    assert_eq!(lease.byte_length(), playable.byte_length);
    assert_eq!(lease.digest_sha256().len(), 64);
}

#[test]
fn runtime_library_snapshot_reads_session_and_sources_from_one_database_moment() {
    let temp = TempDir::new().unwrap();
    let mut writer = open_store(&temp);
    let (prepared, microphone, system) = prepared_dual_first_samples(&mut writer);
    writer
        .confirm_recording(prepared.session_id.clone())
        .unwrap();
    for authorization in [&microphone, &system] {
        replace_with_recoverable_pcm_caf(authorization, 960);
    }
    let reader = open_store(&temp);

    let snapshot = reader
        .runtime_library_snapshot_at_after_sessions(wall_time_milliseconds(), || {
            for authorization in [&microphone, &system] {
                let byte_length = fs::metadata(&authorization.absolute_path).unwrap().len();
                writer
                    .seal_segment(seal_receipt(authorization, byte_length))
                    .unwrap();
            }
        })
        .unwrap();

    if let Some(current) = snapshot.current_session {
        assert!(
            current.lifecycle != "recording"
                || current
                    .sources
                    .iter()
                    .all(|source| source.lifecycle == "capturing"),
            "one snapshot combined a pre-seal Recording session with post-seal source state"
        );
    }
}
