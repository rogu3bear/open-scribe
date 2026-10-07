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
fn an_older_interrupted_session_stays_listed_beside_a_newer_one() {
    let temp = TempDir::new().unwrap();
    let mut store = open_store(&temp);
    let older = store
        .prepare_session(PrepareSessionRequest {
            title: "Start failed".to_owned(),
            origin: SessionOrigin::Capture,
        })
        .unwrap()
        .session_id;
    store
        .interrupt_session(InterruptSessionRequest {
            session_id: older.clone(),
            reason: SessionInterruptionReason::CaptureStartFailed,
        })
        .unwrap();
    let newer = store
        .prepare_session(PrepareSessionRequest {
            title: "Still starting".to_owned(),
            origin: SessionOrigin::Capture,
        })
        .unwrap()
        .session_id;
    store
        .interrupt_session(InterruptSessionRequest {
            session_id: newer.clone(),
            reason: SessionInterruptionReason::CaptureStartFailed,
        })
        .unwrap();

    let snapshot = store.runtime_library_snapshot().unwrap();
    let current = snapshot.current_session.unwrap();
    assert_eq!(current.session_id, newer);
    assert_eq!(current.lifecycle, "interrupted");
    assert_eq!(snapshot.saved_sessions.len(), 1);
    let listed = &snapshot.saved_sessions[0];
    assert_eq!(listed.session_id, older);
    assert_eq!(listed.lifecycle, "interrupted");
    assert!(listed.playable_media.is_none());
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
fn degraded_saved_capture_plays_surviving_source_and_rejects_changed_media() {
    for failed_kind in [MediaSourceKind::Microphone, MediaSourceKind::SystemAudio] {
        let temp = TempDir::new().unwrap();
        let mut store = open_store(&temp);
        let (prepared, microphone, system) = prepared_dual_first_samples(&mut store);
        store
            .confirm_recording(prepared.session_id.clone())
            .unwrap();
        let (failed, surviving, surviving_name) = if failed_kind == MediaSourceKind::Microphone {
            (&microphone, &system, "Mac system audio")
        } else {
            (&system, &microphone, "Mac microphone")
        };
        replace_with_recoverable_pcm_caf(failed, 48_000);
        let mut receipt = seal_receipt(failed, fs::metadata(&failed.absolute_path).unwrap().len());
        receipt.sample_count = 48_000;
        store.seal_segment(receipt).unwrap();
        store
            .record_source_failure(SourceFailureRequest {
                session_id: prepared.session_id.clone(),
                source_kind: failed_kind,
                reason: SourceFailureReason::CaptureFailed,
            })
            .unwrap();
        replace_with_recoverable_pcm_caf(surviving, 96_000);
        let mut receipt = seal_receipt(
            surviving,
            fs::metadata(&surviving.absolute_path).unwrap().len(),
        );
        receipt.sample_count = 96_000;
        store.seal_segment(receipt).unwrap();

        let snapshot = store.runtime_library_snapshot().unwrap();
        assert!(snapshot.current_session.is_none());
        let saved = &snapshot.saved_sessions[0];
        assert_eq!(saved.health, "degraded");
        assert!(!saved.recovered);
        let playable = saved.playable_media.as_ref().unwrap();
        assert_eq!(
            playable.availability,
            RuntimePlayableMediaAvailability::Available
        );
        assert_eq!(playable.source_display_name, surviving_name);
        assert_eq!(saved.elapsed_seconds, 2);
        assert_eq!(
            store
                .lease_imported_playback(&prepared.session_id)
                .unwrap()
                .byte_length(),
            playable.byte_length
        );

        let mut bytes = fs::read(&surviving.absolute_path).unwrap();
        *bytes.last_mut().unwrap() ^= 1;
        fs::write(&surviving.absolute_path, bytes).unwrap();
        assert!(store.lease_imported_playback(&prepared.session_id).is_err());
        let changed = store.runtime_library_snapshot().unwrap();
        assert_eq!(
            changed.saved_sessions[0]
                .playable_media
                .as_ref()
                .unwrap()
                .availability,
            RuntimePlayableMediaAvailability::Corrupt
        );
    }
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
