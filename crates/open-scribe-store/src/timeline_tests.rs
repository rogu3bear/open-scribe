use super::*;
use tempfile::TempDir;

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
    for value in [2_u32, 2, 1, 1, 16] {
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
            channels: 1,
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
    let mut file = OpenOptions::new()
        .append(true)
        .open(&a.absolute_path)
        .unwrap();
    file.write_all(&vec![0_u8; samples as usize * 2]).unwrap();
    file.sync_all().unwrap();
    let receipt = FirstSampleReceipt {
        session_id: a.session_id.clone(),
        track_id: a.track_id.clone(),
        segment_id: a.segment_id.clone(),
        open_token: a.open_token.clone(),
        writer_generation: a.writer_generation,
        relative_path: a.relative_path.clone(),
        first_sample_host_time: host,
        first_sample_frame_count: samples,
        observed_byte_length: file.metadata().unwrap().len(),
    };
    store.accept_first_sample(receipt.clone()).unwrap();
    receipt
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
    for a in &sources {
        capture(store, a, 1, 48_000);
    }
    store.confirm_recording(session.clone()).unwrap();
    (session, sources)
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
