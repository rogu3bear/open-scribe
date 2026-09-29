use super::*;
use tempfile::TempDir;

#[path = "reserved_successor_tests.rs"]
mod reserved_successor_tests;

#[path = "playable_recovery_tests.rs"]
mod playable_recovery_tests;

#[path = "library_recovery_tests.rs"]
mod library_recovery_tests;

#[path = "source_restoration_tests.rs"]
mod source_restoration_tests;

#[path = "recovery_resilience_tests.rs"]
mod recovery_resilience_tests;

#[path = "journal_replacement_tests.rs"]
mod journal_replacement_tests;

#[path = "storage_reserve_tests.rs"]
mod storage_reserve_tests;

fn create_media(store: &mut SessionStore, a: &MediaOpenAuthorization) {
    let mut file = OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(&a.absolute_path)
        .unwrap();
    file.write_all(CAF_HEADER).unwrap();
    file.write_all(b"desc").unwrap();
    file.write_all(&32_i64.to_be_bytes()).unwrap();
    file.write_all(&48_000_f64.to_bits().to_be_bytes()).unwrap();
    file.write_all(b"lpcm").unwrap();
    let channels = u32::from(a.channels);
    for value in [2_u32, 2 * channels, 1, channels, 16] {
        file.write_all(&value.to_be_bytes()).unwrap();
    }
    file.write_all(b"data").unwrap();
    file.write_all(&(-1_i64).to_be_bytes()).unwrap();
    file.write_all(&0_u32.to_be_bytes()).unwrap();
    file.sync_all().unwrap();
    store
        .accept_media_open(MediaOpenReceipt {
            session_id: a.session_id.clone(),
            track_id: a.track_id.clone(),
            segment_id: a.segment_id.clone(),
            open_token: a.open_token.clone(),
            writer_generation: a.writer_generation,
            relative_path: a.relative_path.clone(),
            media_format: a.media_format.clone(),
            sample_rate_hz: 48_000,
            channels: a.channels,
            initial_byte_length: file.metadata().unwrap().len(),
        })
        .unwrap();
}

fn capture(
    store: &mut SessionStore,
    a: &MediaOpenAuthorization,
    host: u64,
    samples: u64,
) -> FirstSampleReceipt {
    let receipt = write_sample_receipt(a, host, samples);
    store.accept_first_sample(receipt.clone()).unwrap();
    receipt
}

fn write_sample_receipt(a: &MediaOpenAuthorization, host: u64, samples: u64) -> FirstSampleReceipt {
    let mut file = OpenOptions::new()
        .append(true)
        .open(&a.absolute_path)
        .unwrap();
    file.write_all(&vec![0_u8; samples as usize * 2 * usize::from(a.channels)])
        .unwrap();
    file.sync_all().unwrap();
    FirstSampleReceipt {
        session_id: a.session_id.clone(),
        track_id: a.track_id.clone(),
        segment_id: a.segment_id.clone(),
        open_token: a.open_token.clone(),
        writer_generation: a.writer_generation,
        relative_path: a.relative_path.clone(),
        first_sample_host_time: host,
        first_sample_frame_count: samples,
        observed_byte_length: file.metadata().unwrap().len(),
    }
}

fn seal(store: &mut SessionStore, a: &MediaOpenAuthorization, end: u64, samples: u64) {
    store
        .seal_segment(SealSegmentReceipt {
            session_id: a.session_id.clone(),
            track_id: a.track_id.clone(),
            segment_id: a.segment_id.clone(),
            open_token: a.open_token.clone(),
            writer_generation: a.writer_generation,
            relative_path: a.relative_path.clone(),
            final_sample_host_time: end,
            sample_count: samples,
            final_byte_length: fs::metadata(&a.absolute_path).unwrap().len(),
        })
        .unwrap();
}

#[test]
fn calibrated_clock_uses_signed_rational_ticks_and_checks_overflow() {
    let clock = CaptureClock {
        host_anchor: 100,
        numerator: 125,
        denominator: 3,
    };
    assert_eq!(clock.map(103).unwrap(), 125);
    assert_eq!(clock.map(97).unwrap(), -125);
    assert!(
        CaptureClock {
            denominator: 0,
            ..clock
        }
        .map(100)
        .is_err()
    );
    assert!(clock.map(u64::MAX).is_err());
}

#[test]
fn playback_alignment_bounds_cumulative_correction_and_preserves_gaps() {
    assert_eq!(
        align_playback_start(94_000_000, Some(100_000_000), 1).unwrap(),
        (100_000_000, -6_000_000)
    );
    assert_eq!(
        align_playback_start(50_000_000, Some(100_000_000), 1).unwrap(),
        (100_000_000, -50_000_000)
    );
    assert!(align_playback_start(49_999_999, Some(100_000_000), 1).is_err());
    assert!(align_playback_start(94_000_000, Some(100_000_000), 0).is_err());
    assert_eq!(
        align_playback_start(110_000_000, Some(100_000_000), 1).unwrap(),
        (110_000_000, 10_000_000)
    );
    assert!(align_playback_start(i64::MIN, Some(i64::MAX), 1).is_err());
}

fn recording_pair(store: &mut SessionStore) -> (SessionId, Vec<MediaOpenAuthorization>) {
    let session = store
        .prepare_session_with_required_sources(
            PrepareSessionRequest {
                title: "Recorder controls".into(),
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
    let sources: Vec<_> = [MediaSourceKind::Microphone, MediaSourceKind::SystemAudio]
        .into_iter()
        .map(|kind| {
            let a = store
                .authorize_media_open(AuthorizeMediaOpenRequest {
                    session_id: session.clone(),
                    source_kind: kind,
                    source_display_name: kind.as_str().into(),
                })
                .unwrap();
            create_media(store, &a);
            a
        })
        .collect();
    assert_eq!(
        sources
            .iter()
            .map(|source| source.channels)
            .collect::<Vec<_>>(),
        vec![1, 2]
    );
    for a in &sources {
        capture(store, a, 1, 48_000);
    }
    store.confirm_recording(session.clone()).unwrap();
    (session, sources)
}

fn paused_pair(store: &mut SessionStore) -> (SessionId, Vec<MediaOpenAuthorization>) {
    let (session, sources) = recording_pair(store);
    store
        .recorder_action(session.clone(), RecorderAction::BeginPause)
        .unwrap();
    for source in &sources {
        seal(store, source, 1_000_000_001, 48_000);
    }
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

#[test]
fn derived_mixdown_uses_fresh_capacity_without_changing_saved_recorder_state() {
    let temp = TempDir::new().unwrap();
    let mut store = SessionStore::open(temp.path()).unwrap();
    let (session, sources) = recording_pair(&mut store);
    for source in &sources {
        seal(&mut store, source, 1_000_000_001, 48_000);
    }
    let before = store.recorder_detail(&session).unwrap();
    assert_eq!(before.lifecycle, "ready_for_review");
    assert!(store.authorize_mixdown(session.clone(), 0).is_err());
    let authorization = store.authorize_mixdown(session.clone(), u64::MAX).unwrap();
    assert_eq!(authorization.expected_frame_count, 48_000);
    assert!(authorization.write_floor_bytes > recorder::RESERVE_BYTES);
    let after = store.recorder_detail(&session).unwrap();
    assert_eq!(after.lifecycle, before.lifecycle);
    assert_eq!(after.storage_level, before.storage_level);
    assert_eq!(after.events, before.events);
}

#[test]
fn lost_derived_mixdown_does_not_take_source_playback_with_it() {
    let temp = TempDir::new().unwrap();
    let mut store = SessionStore::open(temp.path()).unwrap();
    let (session, sources) = recording_pair(&mut store);
    for source in &sources {
        seal(&mut store, source, 1_000_000_001, 48_000);
    }
    let authorization = store.authorize_mixdown(session.clone(), u64::MAX).unwrap();
    let mut file = OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(&authorization.absolute_path)
        .unwrap();
    // The native boundary owns AAC decoding. This fixture exercises the Rust
    // receipt, file identity, and source fallback after that boundary.
    file.write_all(&[0, 0, 0, 32]).unwrap();
    file.write_all(b"ftyp").unwrap();
    file.write_all(&[0; 24]).unwrap();
    file.sync_all().unwrap();
    drop(file);
    store
        .accept_mixdown(MixdownReceipt {
            session_id: session.clone(),
            relative_path: authorization.relative_path,
            byte_length: 32,
            decoded_frame_count: 48_000,
            sample_rate_hz: 48_000,
            channels: 2,
            codec: "aac".into(),
            boundary_frames_readable: true,
        })
        .unwrap();
    assert!(store.validated_mixdown(&session).unwrap().is_some());
    fs::remove_file(&authorization.absolute_path).unwrap();
    assert!(store.validated_mixdown(&session).unwrap().is_none());
    assert_eq!(store.playback_timeline(&session).unwrap().len(), 2);
}

#[test]
fn resume_requires_one_boundary_before_new_samples() {
    let temp = TempDir::new().unwrap();
    let mut store = SessionStore::open(temp.path()).unwrap();
    let (session, sources) = paused_pair(&mut store);
    store
        .recorder_action(session.clone(), RecorderAction::PrepareResume)
        .unwrap();
    let successors: Vec<_> = sources
        .iter()
        .map(|source| {
            let next = store
                .authorize_next_segment(session.clone(), source.segment_id.clone())
                .unwrap();
            create_media(&mut store, &next);
            next
        })
        .collect();
    let mut receipt = write_sample_receipt(&successors[0], 120_000_000_001, 480);
    assert!(
        store.accept_first_sample(receipt.clone()).is_err(),
        "resume must be anchored before capture"
    );
    store
        .recorder_action(
            session.clone(),
            RecorderAction::AnchorResume {
                host_time: 120_000_000_001,
            },
        )
        .unwrap();
    assert!(
        store
            .recorder_action(
                session.clone(),
                RecorderAction::AnchorResume {
                    host_time: 121_000_000_001
                }
            )
            .is_err(),
        "resume boundary is immutable"
    );
    receipt.first_sample_host_time = 119_000_000_001;
    assert!(
        store.accept_first_sample(receipt.clone()).is_err(),
        "old callbacks cannot enter a resumed segment"
    );
    receipt.first_sample_host_time = 120_000_000_001;
    store.accept_first_sample(receipt).unwrap();
    assert!(
        store.confirm_recording(session.clone()).is_err(),
        "each resumed source needs fresh durable samples"
    );
    capture(&mut store, &successors[1], 120_000_000_001, 480);
    store.confirm_recording(session).unwrap();
}

#[test]
fn pause_boundary_cannot_precede_drained_media() {
    let temp = TempDir::new().unwrap();
    let mut store = SessionStore::open(temp.path()).unwrap();
    let (session, sources) = recording_pair(&mut store);
    store
        .recorder_action(session.clone(), RecorderAction::BeginPause)
        .unwrap();
    for source in &sources {
        seal(&mut store, source, 1_000_000_001, 48_000);
    }
    assert!(
        store
            .recorder_action(
                session.clone(),
                RecorderAction::CompletePause {
                    host_time: 999_999_999
                }
            )
            .is_err()
    );
    assert_eq!(
        store.recorder_detail(&session).unwrap().lifecycle,
        "finalizing"
    );
    store
        .recorder_action(
            session,
            RecorderAction::CompletePause {
                host_time: 1_000_000_001,
            },
        )
        .unwrap();
}

#[test]
fn pause_failure_can_durably_interrupt_before_all_sources_seal() {
    let temp = TempDir::new().unwrap();
    let mut store = SessionStore::open(temp.path()).unwrap();
    let (session, sources) = recording_pair(&mut store);
    store
        .recorder_action(session.clone(), RecorderAction::BeginPause)
        .unwrap();
    seal(&mut store, &sources[0], 1_000_000_001, 48_000);
    let evidence = store
        .interrupt_session(InterruptSessionRequest {
            session_id: session.clone(),
            reason: SessionInterruptionReason::SegmentSealFailed,
        })
        .unwrap();
    assert!(evidence.journal_durable && evidence.session_interrupted);
    assert_eq!(
        store.recorder_detail(&session).unwrap().lifecycle,
        "interrupted"
    );
    assert!(
        store
            .recorder_action(session.clone(), RecorderAction::PrepareResume)
            .is_err()
    );
    drop(store);
    let mut reopened = SessionStore::open(temp.path()).unwrap();
    reopened.recover_playable_sessions().unwrap();
    assert_eq!(reopened.playback_timeline(&session).unwrap().len(), 2);
}

#[test]
fn pause_draining_can_rotate_before_completing_the_boundary() {
    let temp = TempDir::new().unwrap();
    let mut store = SessionStore::open(temp.path()).unwrap();
    let (session, sources) = recording_pair(&mut store);
    store
        .recorder_action(session.clone(), RecorderAction::BeginPause)
        .unwrap();
    for source in sources {
        let next = store
            .authorize_next_segment(session.clone(), source.segment_id.clone())
            .unwrap();
        create_media(&mut store, &next);
        seal(&mut store, &source, 1_000_000_001, 48_000);
        capture(&mut store, &next, 1_000_000_001, 48_000);
        seal(&mut store, &next, 2_000_000_001, 48_000);
    }
    let paused = store
        .recorder_action(
            session.clone(),
            RecorderAction::CompletePause {
                host_time: 2_000_000_001,
            },
        )
        .unwrap();
    assert_eq!(paused.lifecycle, "paused");
    assert_eq!(paused.captured_nanoseconds, 2_000_000_000);
    assert!(
        store
            .authorize_next_segment(session, String::new())
            .is_err()
    );
}

#[test]
fn repeated_pause_resume_then_stop_preserves_total_captured_duration() {
    let temp = TempDir::new().unwrap();
    let mut store = SessionStore::open(temp.path()).unwrap();
    let (session, mut sources) = paused_pair(&mut store);
    for cycle in 1..=2_u64 {
        store
            .recorder_action(session.clone(), RecorderAction::PrepareResume)
            .unwrap();
        sources = sources
            .iter()
            .map(|source| {
                let next = store
                    .authorize_next_segment(session.clone(), source.segment_id.clone())
                    .unwrap();
                create_media(&mut store, &next);
                next
            })
            .collect();
        let host = cycle * 120_000_000_000 + 1;
        store
            .recorder_action(
                session.clone(),
                RecorderAction::AnchorResume { host_time: host },
            )
            .unwrap();
        for source in &sources {
            capture(&mut store, source, host, 48_000);
        }
        store.confirm_recording(session.clone()).unwrap();
        store
            .recorder_action(session.clone(), RecorderAction::BeginPause)
            .unwrap();
        for source in &sources {
            seal(&mut store, source, host + 1_000_000_000, 48_000);
        }
        store
            .recorder_action(
                session.clone(),
                RecorderAction::CompletePause {
                    host_time: host + 2_000_000_000,
                },
            )
            .unwrap();
        let paused = store.recorder_detail(&session).unwrap();
        assert_eq!(
            paused.captured_nanoseconds,
            (cycle as i64 + 1) * 1_000_000_000
        );
        assert_eq!(
            store
                .runtime_library_snapshot_at(wall_time_milliseconds() + 600_000)
                .unwrap()
                .current_session
                .unwrap()
                .elapsed_seconds,
            cycle + 1
        );
    }
    store
        .recorder_action(session.clone(), RecorderAction::FinishPaused)
        .unwrap();
    let snapshot = store.runtime_library_snapshot().unwrap();
    assert!(snapshot.current_session.is_none());
    assert_eq!(snapshot.saved_sessions[0].elapsed_seconds, 3);
    drop(store);
    let mut store = SessionStore::open(temp.path()).unwrap();
    store.recover_playable_sessions().unwrap();
    let plan = store.playback_timeline(&session).unwrap();
    assert_eq!(plan.len(), 6);
    for segment in plan {
        assert_eq!(
            segment.start_nanoseconds,
            segment.sequence as i64 * 1_000_000_000
        );
        assert_eq!(segment.sample_count, 48_000);
        assert_eq!(segment.gap_nanoseconds, 0);
    }
}

#[test]
fn pause_resume_excludes_idle_time_and_keeps_markers_durable() {
    let temp = TempDir::new().unwrap();
    let mut store = SessionStore::open(temp.path()).unwrap();
    let (session, sources) = recording_pair(&mut store);
    store
        .recorder_action(session.clone(), RecorderAction::BeginPause)
        .unwrap();
    assert!(
        store
            .recorder_action(
                session.clone(),
                RecorderAction::CompletePause {
                    host_time: 2_000_000_001
                }
            )
            .is_err()
    );
    for a in &sources {
        seal(&mut store, a, 1_000_000_001, 48_000);
    }
    let paused = store
        .recorder_action(
            session.clone(),
            RecorderAction::CompletePause {
                host_time: 2_000_000_001,
            },
        )
        .unwrap();
    assert_eq!(paused.lifecycle, "paused");
    assert_eq!(paused.captured_nanoseconds, 1_000_000_000);
    store
        .recorder_action(
            session.clone(),
            RecorderAction::Marker {
                host_time: 100_000_000_001,
                label: "Paused marker".into(),
            },
        )
        .unwrap();
    assert_eq!(
        store
            .runtime_library_snapshot()
            .unwrap()
            .current_session
            .unwrap()
            .elapsed_seconds,
        1
    );
    store
        .recorder_action(session.clone(), RecorderAction::PrepareResume)
        .unwrap();
    let successors: Vec<_> = sources
        .iter()
        .map(|a| {
            let next = store
                .authorize_next_segment(session.clone(), a.segment_id.clone())
                .unwrap();
            create_media(&mut store, &next);
            next
        })
        .collect();
    store
        .recorder_action(
            session.clone(),
            RecorderAction::AnchorResume {
                host_time: 120_000_000_001,
            },
        )
        .unwrap();
    for a in &successors {
        capture(&mut store, a, 120_000_000_001, 48_000);
    }
    store.confirm_recording(session.clone()).unwrap();
    for a in &successors {
        seal(&mut store, a, 121_000_000_001, 48_000);
    }
    drop(store);
    let mut store = SessionStore::open(temp.path()).unwrap();
    store.recover_playable_sessions().unwrap();
    let plan = store.playback_timeline(&session).unwrap();
    assert!(
        plan.iter()
            .filter(|s| s.sequence == 1)
            .all(|s| s.start_nanoseconds == 1_000_000_000)
    );
    let detail = store.recorder_detail(&session).unwrap();
    assert_eq!(detail.captured_nanoseconds, 2_000_000_000);
    assert_eq!(
        detail
            .events
            .iter()
            .find(|e| e.kind == "marker_added")
            .unwrap()
            .session_nanoseconds,
        1_000_000_000
    );
}

#[test]
fn paused_crash_repairs_a_synced_marker_without_losing_source_media() {
    let temp = TempDir::new().unwrap();
    let mut store = SessionStore::open(temp.path()).unwrap();
    let (session, sources) = recording_pair(&mut store);
    store
        .recorder_action(session.clone(), RecorderAction::BeginPause)
        .unwrap();
    for a in &sources {
        seal(&mut store, a, 1_000_000_001, 48_000);
    }
    store
        .recorder_action(
            session.clone(),
            RecorderAction::CompletePause {
                host_time: 2_000_000_001,
            },
        )
        .unwrap();
    store.append_session_journal(&session.0, "marker_added", None, json!({"marker_id": Uuid::now_v7().to_string(), "label": "Durable", "host_time": 3_000_000_001_u64, "session_nanoseconds": 1_000_000_000})).unwrap();
    drop(store);
    let mut store = SessionStore::open(temp.path()).unwrap();
    store.recover_playable_sessions().unwrap();
    assert_eq!(store.playback_timeline(&session).unwrap().len(), 2);
    assert_eq!(
        store
            .recorder_detail(&session)
            .unwrap()
            .events
            .iter()
            .filter(|e| e.kind == "marker_added")
            .count(),
        1
    );
    store.recover_playable_sessions().unwrap();
    assert_eq!(
        store
            .recorder_detail(&session)
            .unwrap()
            .events
            .iter()
            .filter(|e| e.kind == "marker_added")
            .count(),
        1
    );
}

#[test]
fn critical_storage_blocks_successors_but_allows_sealing_existing_media() {
    let temp = TempDir::new().unwrap();
    let mut store = SessionStore::open(temp.path()).unwrap();
    let (session, sources) = recording_pair(&mut store);
    let observation = store
        .recorder_action(
            session.clone(),
            RecorderAction::ObserveStorage {
                available_bytes: 256 * 1024 * 1024,
            },
        )
        .unwrap();
    assert_eq!(observation.storage_level, "critical");
    assert!(
        store
            .authorize_next_segment(session.clone(), sources[0].segment_id.clone())
            .is_err()
    );
    for a in &sources {
        seal(&mut store, a, 1_000_000_001, 48_000);
    }
    assert_eq!(store.playback_timeline(&session).unwrap().len(), 2);
    assert!(sources.iter().all(|a| a.absolute_path.exists()));
}

#[test]
fn termination_at_each_rotation_boundary_preserves_both_sources() {
    for boundary in 0..3 {
        let temp = TempDir::new().unwrap();
        let mut store = SessionStore::open(temp.path()).unwrap();
        let session = store
            .prepare_session_with_required_sources(
                PrepareSessionRequest {
                    title: "Boundary".to_owned(),
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
        let mut sources = Vec::new();
        for kind in [MediaSourceKind::Microphone, MediaSourceKind::SystemAudio] {
            let a = store
                .authorize_media_open(AuthorizeMediaOpenRequest {
                    session_id: session.clone(),
                    source_kind: kind,
                    source_display_name: kind.as_str().to_owned(),
                })
                .unwrap();
            create_media(&mut store, &a);
            sources.push(a);
        }
        for a in &sources {
            capture(&mut store, a, 1, 48_000);
        }
        store.confirm_recording(session.clone()).unwrap();
        for a in &sources {
            let next = store
                .authorize_next_segment(session.clone(), a.segment_id.clone())
                .unwrap();
            if boundary >= 1 {
                create_media(&mut store, &next);
            }
            if boundary >= 2 {
                seal(&mut store, a, 1_000_000_001, 48_000);
            }
        }
        drop(store);
        let mut store = SessionStore::open(temp.path()).unwrap();
        assert_eq!(
            store.recover_playable_sessions().unwrap().len(),
            2,
            "boundary {boundary}"
        );
        assert_eq!(store.playback_timeline(&session).unwrap().len(), 2);
        assert_eq!(store.recover_playable_sessions().unwrap().len(), 2);
        let gaps: i64 = store
            .connection
            .query_row(
                "SELECT COUNT(*) FROM segments WHERE lifecycle = 'gap'",
                [],
                |r| r.get(0),
            )
            .unwrap();
        assert_eq!(gaps, 2);
    }
}

#[test]
fn dual_segment_crash_recovery_retains_offsets_samples_and_media_bytes() {
    let temp = TempDir::new().unwrap();
    let mut store = SessionStore::open(temp.path()).unwrap();
    let session = store
        .prepare_session_with_required_sources(
            PrepareSessionRequest {
                title: "Timeline".to_owned(),
                origin: SessionOrigin::Capture,
            },
            vec![MediaSourceKind::Microphone, MediaSourceKind::SystemAudio],
        )
        .unwrap()
        .session_id;
    let clock = CaptureClock {
        host_anchor: 1_000_000_000,
        numerator: 1,
        denominator: 1,
    };
    store.anchor_capture_clock(session.clone(), clock).unwrap();
    assert!(
        store
            .anchor_capture_clock(
                session.clone(),
                CaptureClock {
                    host_anchor: 2,
                    ..clock
                }
            )
            .is_err()
    );
    let mut sources = Vec::new();
    for kind in [MediaSourceKind::Microphone, MediaSourceKind::SystemAudio] {
        let a = store
            .authorize_media_open(AuthorizeMediaOpenRequest {
                session_id: session.clone(),
                source_kind: kind,
                source_display_name: kind.as_str().to_owned(),
            })
            .unwrap();
        create_media(&mut store, &a);
        sources.push(a);
    }
    let starts = [2_000_000_000, 2_250_000_000];
    let mut receipts = Vec::new();
    for (a, start) in sources.iter().zip(starts) {
        receipts.push(capture(&mut store, a, start, 1_440_000));
    }
    // A repeat is scoped to its segment, even after another source's receipt.
    assert_eq!(
        store
            .accept_first_sample(receipts[0].clone())
            .unwrap()
            .first_sample_session_nanoseconds,
        1_000_000_000
    );
    store.confirm_recording(session.clone()).unwrap();
    let mut all = sources.clone();
    for (a, start) in sources.iter().zip(starts) {
        let next = store
            .authorize_next_segment(session.clone(), a.segment_id.clone())
            .unwrap();
        assert_eq!(next.track_id, a.track_id);
        assert_eq!(next.writer_generation, 2);
        assert!(
            store
                .authorize_next_segment(session.clone(), a.segment_id.clone())
                .is_err()
        );
        create_media(&mut store, &next);
        seal(&mut store, a, start + 30_000_000_000, 1_440_000);
        // Native microphone clock runs slightly ahead of its PCM duration.
        let overlap = if a.source_id == sources[0].source_id {
            6_197_500
        } else {
            0
        };
        capture(&mut store, &next, start + 30_000_000_000 - overlap, 48_000);
        all.push(next);
    }
    let original: Vec<_> = all
        .iter()
        .map(|a| fs::read(&a.absolute_path).unwrap())
        .collect();
    drop(store); // No stop/seal for either tail.
    let mut store = SessionStore::open(temp.path()).unwrap();
    assert_eq!(store.recover_playable_sessions().unwrap().len(), 4);
    let plan = store.playback_timeline(&session).unwrap();
    assert_eq!(plan.len(), 4);
    for source in &sources {
        let track: Vec<_> = plan
            .iter()
            .filter(|s| s.track_id == source.track_id)
            .collect();
        assert_eq!(track.iter().map(|s| s.sample_count).sum::<u64>(), 1_488_000);
        assert_eq!(
            track[1].start_nanoseconds - track[0].start_nanoseconds,
            30_000_000_000
        );
        let overlap = if source.source_id == sources[0].source_id {
            6_197_500
        } else {
            0
        };
        assert_eq!(track[1].gap_nanoseconds, -overlap);
        assert_eq!(track[1].clock_adjustment_nanoseconds, overlap);
        assert_eq!(
            track[1].native_start_nanoseconds + overlap,
            track[1].start_nanoseconds
        );
    }
    for (a, bytes) in all.iter().zip(original) {
        assert_eq!(fs::read(&a.absolute_path).unwrap(), bytes);
    }
    assert_eq!(store.recover_playable_sessions().unwrap().len(), 4);
    assert_eq!(store.playback_timeline(&session).unwrap(), plan);
    store
        .connection
        .execute(
            "UPDATE segments SET mapped_start_ns = mapped_start_ns + 1 WHERE id = ?1",
            [&sources[0].segment_id],
        )
        .unwrap();
    assert!(store.playback_timeline(&session).is_err());
}

fn journal_records(store: &SessionStore, session: &SessionId) -> Vec<JournalRecord> {
    match validate_journal(
        &store
            .session_directory(&session.0)
            .unwrap()
            .join(JOURNAL_NAME),
        &session.0,
    )
    .unwrap()
    {
        JournalValidation::Valid(records) => records,
        _ => panic!("journal is not valid"),
    }
}

fn select_application_scope(store: &mut SessionStore, session: &SessionId) {
    store
        .recorder_action(
            session.clone(),
            RecorderAction::SelectAudio {
                kind: Some(MediaSourceKind::ApplicationAudio),
                identity: "com.example.app:42".into(),
                display_name: "Example".into(),
            },
        )
        .unwrap();
}

/// F3: a scope selected while paused is a plan for the next span, not a
/// requirement over media that was already captured.
#[test]
fn source_scope_change_while_paused_keeps_the_captured_span_playable() {
    let temp = TempDir::new().unwrap();
    let mut store = SessionStore::open(temp.path()).unwrap();
    let (session, _) = paused_pair(&mut store);
    select_application_scope(&mut store, &session);
    store
        .recorder_action(session.clone(), RecorderAction::FinishPaused)
        .unwrap();
    assert_eq!(
        store.recorder_detail(&session).unwrap().lifecycle,
        "ready_for_review"
    );
    let plan = store.playback_timeline(&session).unwrap();
    assert_eq!(plan.len(), 2, "the pre-pause span plays");
    assert!(plan.iter().all(|s| s.sample_count == 48_000));
    let selected = journal_records(&store, &session)
        .into_iter()
        .find(|r| r.body.event_kind == "source_scope_selected")
        .expect("scope change is journaled");
    assert_eq!(
        selected.body.payload["ended"],
        json!(["system_audio"]),
        "the retired source is journaled as ended"
    );
    assert_eq!(
        selected.body.payload["added"],
        json!(["application_audio"]),
        "the new source is journaled as added"
    );
}

/// F3: quitting while paused with a pending scope change must still finalize
/// on relaunch instead of being skipped on every launch.
#[test]
fn paused_session_with_pending_scope_change_finalizes_on_relaunch() {
    let temp = TempDir::new().unwrap();
    let mut store = SessionStore::open(temp.path()).unwrap();
    let (session, _) = paused_pair(&mut store);
    select_application_scope(&mut store, &session);
    drop(store);
    let mut store = SessionStore::open(temp.path()).unwrap();
    store.recover_playable_sessions().unwrap();
    assert_eq!(
        store.recorder_detail(&session).unwrap().lifecycle,
        "ready_for_review"
    );
    assert_eq!(store.playback_timeline(&session).unwrap().len(), 2);
    store.recover_playable_sessions().unwrap();
    assert_eq!(store.playback_timeline(&session).unwrap().len(), 2);
}

/// F5: a source that failed during Recording leaves the required set for later
/// spans. Resume authorizes only the continuing source and Recording resumes.
#[test]
fn resume_after_source_failure_continues_on_the_remaining_source() {
    let temp = TempDir::new().unwrap();
    let mut store = SessionStore::open(temp.path()).unwrap();
    let (session, sources) = recording_pair(&mut store);
    let (microphone, system) = (&sources[0], &sources[1]);
    seal(&mut store, system, 1_000_000_001, 48_000);
    let failure = store
        .record_source_failure(SourceFailureRequest {
            session_id: session.clone(),
            source_kind: MediaSourceKind::SystemAudio,
            reason: SourceFailureReason::CaptureFailed,
        })
        .unwrap();
    assert!(failure.recording_continues);
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
    assert!(
        store
            .authorize_next_segment(session.clone(), system.segment_id.clone())
            .is_err(),
        "a failed source gets no successor"
    );
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
    let recording = store.confirm_recording(session.clone()).unwrap();
    assert_eq!(
        recording.required_sources,
        vec![MediaSourceKind::Microphone]
    );
    assert_eq!(recording.active_sources, vec![MediaSourceKind::Microphone]);
    seal(&mut store, &next, 121_000_000_001, 48_000);
    assert_eq!(
        store.recorder_detail(&session).unwrap().lifecycle,
        "ready_for_review"
    );
    let plan = store.playback_timeline(&session).unwrap();
    assert_eq!(plan.len(), 3);
    assert_eq!(
        plan.iter().filter(|s| s.track_id == next.track_id).count(),
        2
    );
}

/// F9: a source first authorized on resume starts at sequence 0. Dying before
/// its first sample must leave a gap, not an open segment that blocks finalize.
#[test]
fn unstarted_resumed_source_at_sequence_zero_becomes_a_gap_and_finalizes() {
    let temp = TempDir::new().unwrap();
    let mut store = SessionStore::open(temp.path()).unwrap();
    let (session, sources) = paused_pair(&mut store);
    select_application_scope(&mut store, &session);
    store
        .recorder_action(session.clone(), RecorderAction::PrepareResume)
        .unwrap();
    let microphone_next = store
        .authorize_next_segment(session.clone(), sources[0].segment_id.clone())
        .unwrap();
    create_media(&mut store, &microphone_next);
    let application = store
        .authorize_media_open(AuthorizeMediaOpenRequest {
            session_id: session.clone(),
            source_kind: MediaSourceKind::ApplicationAudio,
            source_display_name: "Example".into(),
        })
        .unwrap();
    assert_eq!(
        application.relative_path,
        format!("audio/{}/000000-0.caf", application.track_id)
    );
    drop(store);
    let mut store = SessionStore::open(temp.path()).unwrap();
    store.recover_playable_sessions().unwrap();
    let lifecycle = |store: &SessionStore, id: &str| -> String {
        store
            .connection
            .query_row("SELECT lifecycle FROM segments WHERE id = ?1", [id], |r| {
                r.get(0)
            })
            .unwrap()
    };
    assert_eq!(lifecycle(&store, &application.segment_id), "gap");
    assert_eq!(lifecycle(&store, &microphone_next.segment_id), "gap");
    assert_eq!(
        store.recorder_detail(&session).unwrap().lifecycle,
        "ready_for_review"
    );
    assert_eq!(store.playback_timeline(&session).unwrap().len(), 2);
    store.recover_playable_sessions().unwrap();
    assert_eq!(lifecycle(&store, &application.segment_id), "gap");
}

/// N1 (from the F11 check): a timestamp discontinuity before Recording is
/// confirmed must rotate like any other, not fail the start. The successor
/// belongs to a capturing source of a preparing session.
#[test]
fn early_rotation_before_recording_confirmation_is_admitted() {
    let temp = TempDir::new().unwrap();
    let mut store = SessionStore::open(temp.path()).unwrap();
    let session = store
        .prepare_session_with_required_sources(
            PrepareSessionRequest {
                title: "Early rotation".into(),
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
    let sources: Vec<_> = [MediaSourceKind::Microphone, MediaSourceKind::SystemAudio]
        .into_iter()
        .map(|kind| {
            let a = store
                .authorize_media_open(AuthorizeMediaOpenRequest {
                    session_id: session.clone(),
                    source_kind: kind,
                    source_display_name: kind.as_str().into(),
                })
                .unwrap();
            create_media(&mut store, &a);
            a
        })
        .collect();
    capture(&mut store, &sources[0], 1, 480);
    let next = store
        .authorize_next_segment(session.clone(), sources[0].segment_id.clone())
        .expect("a capturing source may rotate before Recording is confirmed");
    create_media(&mut store, &next);
    seal(&mut store, &sources[0], 10_000_001, 480);
    capture(&mut store, &next, 2_000_000_001, 480);
    capture(&mut store, &sources[1], 2_000_000_001, 480);
    let recording = store.confirm_recording(session.clone()).unwrap();
    assert_eq!(recording.active_sources, recording.required_sources);
    seal(&mut store, &next, 2_010_000_001, 480);
    seal(&mut store, &sources[1], 2_010_000_001, 480);
    assert_eq!(
        store.recorder_detail(&session).unwrap().lifecycle,
        "ready_for_review"
    );
    let plan = store.playback_timeline(&session).unwrap();
    assert_eq!(plan.len(), 3);
    assert_eq!(
        plan.iter()
            .filter(|s| s.track_id == next.track_id)
            .map(|s| s.sequence)
            .collect::<Vec<_>>(),
        vec![0, 1]
    );
}

/// N1: dying after an early rotation but before Recording is confirmed
/// still recovers every captured segment on relaunch.
#[test]
fn crash_after_early_rotation_before_recording_recovers_all_media() {
    let temp = TempDir::new().unwrap();
    let mut store = SessionStore::open(temp.path()).unwrap();
    let session = store
        .prepare_session_with_required_sources(
            PrepareSessionRequest {
                title: "Early rotation crash".into(),
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
    let sources: Vec<_> = [MediaSourceKind::Microphone, MediaSourceKind::SystemAudio]
        .into_iter()
        .map(|kind| {
            let a = store
                .authorize_media_open(AuthorizeMediaOpenRequest {
                    session_id: session.clone(),
                    source_kind: kind,
                    source_display_name: kind.as_str().into(),
                })
                .unwrap();
            create_media(&mut store, &a);
            a
        })
        .collect();
    capture(&mut store, &sources[0], 1, 480);
    let next = store
        .authorize_next_segment(session.clone(), sources[0].segment_id.clone())
        .unwrap();
    create_media(&mut store, &next);
    seal(&mut store, &sources[0], 10_000_001, 480);
    capture(&mut store, &next, 2_000_000_001, 480);
    capture(&mut store, &sources[1], 2_000_000_001, 480);
    drop(store);
    let mut store = SessionStore::open(temp.path()).unwrap();
    let recovered = store.recover_playable_sessions().unwrap();
    assert_eq!(
        recovered.iter().filter(|r| r.session_id == session).count(),
        3
    );
    assert_eq!(
        store.recorder_detail(&session).unwrap().lifecycle,
        "ready_for_review"
    );
    assert_eq!(store.playback_timeline(&session).unwrap().len(), 3);
}

/// PRD 11.6: sleep and wake are journaled recorder events at the captured
/// position. Neither moves the lifecycle; the native recorder pauses capture.
#[test]
fn system_sleep_and_wake_are_logged_without_moving_the_lifecycle() {
    let temp = TempDir::new().unwrap();
    let mut store = SessionStore::open(temp.path()).unwrap();
    let (session, sources) = recording_pair(&mut store);
    let slept = store
        .recorder_action(
            session.clone(),
            RecorderAction::ObserveSystemPower {
                host_time: 500_000_001,
                asleep: true,
            },
        )
        .unwrap();
    assert_eq!(slept.lifecycle, "recording");
    store
        .recorder_action(session.clone(), RecorderAction::BeginPause)
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
    let woke = store
        .recorder_action(
            session.clone(),
            RecorderAction::ObserveSystemPower {
                host_time: 90_000_000_001,
                asleep: false,
            },
        )
        .unwrap();
    assert_eq!(woke.lifecycle, "paused", "wake never resumes capture");
    drop(store);

    let store = SessionStore::open(temp.path()).unwrap();
    let power: Vec<_> = store
        .recorder_detail(&session)
        .unwrap()
        .events
        .into_iter()
        .filter(|event| event.kind.starts_with("system_"))
        .map(|event| (event.kind, event.session_nanoseconds))
        .collect();
    assert_eq!(
        power,
        vec![
            ("system_sleep_observed".to_owned(), 500_000_000),
            ("system_wake_observed".to_owned(), 1_000_000_000),
        ]
    );
    assert_eq!(
        journal_records(&store, &session)
            .iter()
            .filter(|record| record.body.event_kind.starts_with("system_"))
            .count(),
        2
    );
}

#[test]
fn system_power_is_not_journaled_for_a_finished_session() {
    let temp = TempDir::new().unwrap();
    let mut store = SessionStore::open(temp.path()).unwrap();
    let (session, _) = paused_pair(&mut store);
    store
        .recorder_action(session.clone(), RecorderAction::FinishPaused)
        .unwrap();
    assert!(matches!(
        store.recorder_action(
            session,
            RecorderAction::ObserveSystemPower {
                host_time: 3_000_000_001,
                asleep: true,
            },
        ),
        Err(StoreError::InvalidState(_))
    ));
}

/// The CAF header AVAudioFile writes for 16-bit stereo: interleaved, four
/// bytes per packet, with a `free` chunk before `data`.
fn avaudiofile_stereo_caf(path: &Path, bytes_per_packet: u32, frames: u64) -> u64 {
    let mut bytes = Vec::new();
    bytes.extend_from_slice(CAF_HEADER);
    bytes.extend_from_slice(b"desc");
    bytes.extend_from_slice(&32_i64.to_be_bytes());
    bytes.extend_from_slice(&48_000_f64.to_bits().to_be_bytes());
    bytes.extend_from_slice(b"lpcm");
    for value in [2_u32, bytes_per_packet, 1, 2, 16] {
        bytes.extend_from_slice(&value.to_be_bytes());
    }
    bytes.extend_from_slice(b"free");
    bytes.extend_from_slice(&16_i64.to_be_bytes());
    bytes.extend_from_slice(&[0_u8; 16]);
    bytes.extend_from_slice(b"data");
    bytes.extend_from_slice(&(4 + frames as i64 * 4).to_be_bytes());
    bytes.extend_from_slice(&0_u32.to_be_bytes());
    bytes.extend_from_slice(&vec![0_u8; frames as usize * 4]);
    fs::write(path, &bytes).unwrap();
    bytes.len() as u64
}

#[test]
fn stereo_caf_inspection_uses_the_interleaved_packet_width() {
    let temp = TempDir::new().unwrap();
    let path = temp.path().join("stereo.caf");
    let length = avaudiofile_stereo_caf(&path, 4, 480);
    let inspection = inspect_pcm_caf(&mut File::open(&path).unwrap(), length)
        .unwrap()
        .unwrap();
    assert_eq!(
        (inspection.channels, inspection.sample_count),
        (2, Some(480))
    );
    let length = avaudiofile_stereo_caf(&path, 2, 480);
    assert!(
        inspect_pcm_caf(&mut File::open(&path).unwrap(), length)
            .unwrap()
            .is_none()
    );
}
