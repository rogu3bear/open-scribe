use super::*;
use std::os::unix::fs::FileExt;

fn caf(path: &Path, samples: u64) {
    let mut file = File::create(path).unwrap();
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
    file.write_all(&vec![0; samples as usize * 2]).unwrap();
    file.sync_all().unwrap();
}

fn imported(temp: &TempDir, compressed: bool) -> (SessionStore, ImportedMediaEvidence, PathBuf) {
    let source = temp.path().join(if compressed {
        "source.m4a"
    } else {
        "source.caf"
    });
    let mut store = open_store(temp);
    let request = ImportMediaRequest {
        title: "Synthetic device identity".into(),
        source_path: source.clone(),
    };
    let evidence = if compressed {
        let mut bytes = b"\x00\x00\x00\x1cftypM4A \x00\x00\x00\x00M4A isommp42".to_vec();
        bytes.extend_from_slice(&[42; 256]);
        fs::write(&source, &bytes).unwrap();
        store
            .import_compressed_m4a(
                request,
                CompressedImportMetadata {
                    original: OriginalImportMetadata {
                        display_name: "source.m4a".into(),
                        byte_length: bytes.len() as u64,
                        duration_nanoseconds: 1_000_000_000,
                        sample_rate_hz: 48_000,
                        channel_count: 1,
                        media_format: "m4a".into(),
                    },
                    sample_count: 48_000,
                    digest_sha256: format!("{:x}", Sha256::digest(&bytes)),
                },
            )
            .unwrap()
    } else {
        caf(&source, 960);
        store.import_recoverable_caf(request).unwrap()
    };
    let managed = store
        .session_directory(&evidence.session_id.0)
        .unwrap()
        .join(&evidence.relative_path);
    (store, evidence, managed)
}

// Synthetic replicas only: change accepted historical mount numbers, including
// the valid journal chain. Actual managed bytes and inode remain unchanged.
fn renumber_receipts(store: &SessionStore, session: &SessionId) -> u64 {
    let old: i64 = store
        .connection
        .query_row(
            "SELECT file_device FROM segments WHERE session_id = ?1 LIMIT 1",
            [&session.0],
            |row| row.get(0),
        )
        .unwrap();
    let prior_mount = old as u64 + 65_536;
    store
        .connection
        .execute(
            "UPDATE segments SET file_device = ?2 WHERE session_id = ?1",
            params![&session.0, prior_mount as i64],
        )
        .unwrap();
    let journal = store
        .session_directory(&session.0)
        .unwrap()
        .join(JOURNAL_NAME);
    let JournalValidation::Valid(mut records) = validate_journal(&journal, &session.0).unwrap()
    else {
        panic!("fixture journal must be valid")
    };
    let mut prior = None;
    for record in &mut records {
        if record.body.payload.get("file_device").is_some() {
            record.body.payload["file_device"] = json!(prior_mount);
        }
        record.body.prior_digest = prior;
        record.record_digest = digest_json(&record.body).unwrap();
        prior = Some(record.record_digest.clone());
    }
    let replacement = journal.with_extension("renumber-fixture");
    let mut file = OpenOptions::new()
        .create_new(true)
        .write(true)
        .open(&replacement)
        .unwrap();
    for record in &records {
        append_journal_record(&mut file, record).unwrap();
    }
    file.sync_all().unwrap();
    drop(file);
    fs::rename(replacement, &journal).unwrap();
    sync_directory(journal.parent().unwrap()).unwrap();
    assert!(matches!(
        validate_journal(&journal, &session.0).unwrap(),
        JournalValidation::Valid(rewritten) if rewritten.len() == records.len()
    ));
    prior_mount
}

fn captured(temp: &TempDir, seal: bool) -> (SessionStore, SessionId, MediaOpenAuthorization) {
    captured_with_clock(temp, seal, true)
}

fn captured_with_clock(
    temp: &TempDir,
    seal: bool,
    calibrated: bool,
) -> (SessionStore, SessionId, MediaOpenAuthorization) {
    let mut store = open_store(temp);
    let session = store
        .prepare_session_with_required_sources(request(), vec![MediaSourceKind::Microphone])
        .unwrap()
        .session_id;
    if calibrated {
        store
            .anchor_capture_clock(
                session.clone(),
                CaptureClock {
                    host_anchor: 42_000,
                    numerator: 1,
                    denominator: 1,
                },
            )
            .unwrap();
    }
    let a = store
        .authorize_media_open(AuthorizeMediaOpenRequest {
            session_id: session.clone(),
            source_kind: MediaSourceKind::Microphone,
            source_display_name: "Synthetic microphone".into(),
        })
        .unwrap();
    caf(&a.absolute_path, 0);
    store.accept_media_open(media_receipt(&a, 68)).unwrap();
    let mut file = OpenOptions::new()
        .append(true)
        .open(&a.absolute_path)
        .unwrap();
    file.write_all(&vec![0; 960 * 2]).unwrap();
    file.sync_all().unwrap();
    store
        .accept_first_sample(first_sample_receipt(&a, 68 + 960 * 2))
        .unwrap();
    store.confirm_recording(session.clone()).unwrap();
    drop(file);
    if seal {
        let mut receipt = seal_receipt(&a, 68 + 960 * 2);
        receipt.final_sample_host_time = 20_042_000;
        store.seal_segment(receipt).unwrap();
    }
    (store, session, a)
}

fn available(store: &SessionStore, session: &SessionId) -> RuntimePlayableMediaAvailability {
    store
        .runtime_library_snapshot()
        .unwrap()
        .saved_sessions
        .into_iter()
        .find(|s| &s.session_id == session)
        .unwrap()
        .playable_media
        .unwrap()
        .availability
}

#[test]
fn sealed_identity_import_device_renumber_preserves_receipts_and_supports_consumers() {
    for compressed in [false, true] {
        let temp = TempDir::new().unwrap();
        let (store, evidence, managed) = imported(&temp, compressed);
        let bytes = fs::read(&managed).unwrap();
        let prior_mount = renumber_receipts(&store, &evidence.session_id);
        assert_eq!(
            available(&store, &evidence.session_id),
            RuntimePlayableMediaAvailability::Available
        );
        let lease = store.lease_imported_playback(&evidence.session_id).unwrap();
        assert_eq!(lease.digest_sha256(), evidence.digest_sha256);
        let track = store
            .transcription_tracks(&evidence.session_id)
            .unwrap()
            .remove(0);
        let input = store
            .transcription_input(&evidence.session_id, &track)
            .unwrap();
        if !compressed {
            let reader = store.open_transcription_input(&input).unwrap();
            assert_eq!(reader.read_frames(0, 0, 960).unwrap().len(), 960);
        } else {
            let decoded = temp.path().join("decoded.caf");
            caf(&decoded, 48_000);
            let reader = store
                .open_decoded_transcription_input(&input, &decoded)
                .unwrap();
            assert_eq!(reader.read_frames(0, 0, 48_000).unwrap().len(), 48_000);
        }
        let inventory = store.session_inventory(&evidence.session_id).unwrap();
        assert_eq!(inventory.media.len(), 1);
        store
            .open_verified_media(&evidence.session_id, &inventory.media[0])
            .unwrap();
        let current: i64 = store
            .connection
            .query_row(
                "SELECT file_device FROM segments WHERE session_id = ?1",
                [&evidence.session_id.0],
                |r| r.get(0),
            )
            .unwrap();
        assert_eq!(current as u64, prior_mount);
        assert_eq!(fs::read(managed).unwrap(), bytes);
    }
}

#[test]
fn sealed_identity_pcm_snapshot_memo_preserves_receipts_and_fresh_consumers() {
    for capture in [false, true] {
        for renumbered in [false, true] {
            let temp = TempDir::new().unwrap();
            let (store, session, managed) = if capture {
                let (store, session, a) = captured_with_clock(&temp, true, false);
                (store, session, a.absolute_path)
            } else {
                let (store, evidence, managed) = imported(&temp, false);
                (store, evidence.session_id, managed)
            };
            if renumbered {
                renumber_receipts(&store, &session);
            }
            let before = store.digest_computations();
            for _ in 0..4 {
                assert_eq!(
                    available(&store, &session),
                    RuntimePlayableMediaAvailability::Available
                );
            }
            assert_eq!(store.digest_computations(), before + 1);
            if capture {
                assert!(
                    !store.runtime_library_snapshot().unwrap().saved_sessions[0]
                        .has_capture_timeline
                );
                let (source, track, segment): (String, String, String) = store
                    .connection
                    .query_row(
                        "SELECT tracks.source_id, segments.track_id, segments.id FROM segments
                     JOIN tracks ON tracks.id = segments.track_id WHERE segments.session_id = ?1",
                        [&session.0],
                        |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?)),
                    )
                    .unwrap();
                store
                    .lease_capture_playback(&session, &source, &track, &segment, true)
                    .unwrap();
            } else {
                store.lease_imported_playback(&session).unwrap();
                let track = store.transcription_tracks(&session).unwrap().remove(0);
                let input = store.transcription_input(&session, &track).unwrap();
                store.open_transcription_input(&input).unwrap();
                let inventory = store.session_inventory(&session).unwrap();
                store
                    .open_verified_media(&session, &inventory.media[0])
                    .unwrap();
            }
            assert!(store.digest_computations() >= before + 2);
            let (digest, samples): (String, i64) = store
                .connection
                .query_row(
                    "SELECT digest, sample_count FROM segments WHERE session_id = ?1",
                    [&session.0],
                    |row| Ok((row.get(0)?, row.get(1)?)),
                )
                .unwrap();
            let hashes = store.digest_computations();
            store
                .connection
                .execute(
                    "UPDATE segments SET digest = ?2 WHERE session_id = ?1",
                    params![&session.0, "0".repeat(64)],
                )
                .unwrap();
            if !capture {
                store
                    .connection
                    .execute(
                        "UPDATE imports SET source_digest = ?2 WHERE session_id = ?1",
                        params![&session.0, "0".repeat(64)],
                    )
                    .unwrap();
            }
            assert_eq!(
                available(&store, &session),
                RuntimePlayableMediaAvailability::Corrupt
            );
            assert_eq!(store.digest_computations(), hashes);
            store
                .connection
                .execute(
                    "UPDATE segments SET digest = ?2, sample_count = ?3 WHERE session_id = ?1",
                    params![&session.0, digest, samples + 1],
                )
                .unwrap();
            if !capture {
                store
                    .connection
                    .execute(
                        "UPDATE imports SET source_digest = ?2 WHERE session_id = ?1",
                        params![&session.0, digest],
                    )
                    .unwrap();
            }
            assert_eq!(
                available(&store, &session),
                RuntimePlayableMediaAvailability::Corrupt
            );
            assert_eq!(store.digest_computations(), hashes);
            store
                .connection
                .execute(
                    "UPDATE segments SET sample_count = ?2 WHERE session_id = ?1",
                    params![&session.0, samples],
                )
                .unwrap();
            let file = OpenOptions::new().write(true).open(&managed).unwrap();
            let mtime = file.metadata().unwrap().modified().unwrap();
            let identity = sealed_media_identity::media_identity(&file).unwrap();
            file.write_all_at(&[99], 68).unwrap();
            file.set_times(fs::FileTimes::new().set_modified(mtime))
                .unwrap();
            file.sync_all().unwrap();
            let changed = sealed_media_identity::media_identity(&file).unwrap();
            assert_eq!((identity.3, identity.4), (changed.3, changed.4));
            assert_ne!((identity.5, identity.6), (changed.5, changed.6));
            assert_eq!(
                available(&store, &session),
                RuntimePlayableMediaAvailability::Corrupt
            );
            assert_eq!(store.digest_computations(), hashes + 1);
            assert_eq!(store.snapshot_digest_memo.borrow().len(), 1);
        }
    }
}

#[test]
fn sealed_identity_snapshot_memo_reuses_only_unchanged_compressed_media_and_current_receipts() {
    let temp = TempDir::new().unwrap();
    let (store, evidence, managed) = imported(&temp, true);
    renumber_receipts(&store, &evidence.session_id);
    let imported_hashes = store.digest_computations();
    assert_eq!(
        available(&store, &evidence.session_id),
        RuntimePlayableMediaAvailability::Available
    );
    let first = store.digest_computations();
    assert_eq!(first, imported_hashes + 1);
    for _ in 0..3 {
        assert_eq!(
            available(&store, &evidence.session_id),
            RuntimePlayableMediaAvailability::Available
        );
    }
    assert_eq!(store.digest_computations(), first);
    store.lease_imported_playback(&evidence.session_id).unwrap();
    assert_eq!(store.digest_computations(), first + 1);
    let inventory = store.session_inventory(&evidence.session_id).unwrap();
    store
        .open_verified_media(&evidence.session_id, &inventory.media[0])
        .unwrap();
    assert!(store.digest_computations() >= first + 2);
    let track = store
        .transcription_tracks(&evidence.session_id)
        .unwrap()
        .remove(0);
    let input = store
        .transcription_input(&evidence.session_id, &track)
        .unwrap();
    let decoded = temp.path().join("decoded.caf");
    caf(&decoded, 48_000);
    store
        .open_decoded_transcription_input(&input, &decoded)
        .unwrap();
    assert!(store.digest_computations() >= first + 3);

    let wrong = "0".repeat(64);
    store
        .connection
        .execute(
            "UPDATE segments SET digest = ?2 WHERE session_id = ?1",
            params![&evidence.session_id.0, wrong],
        )
        .unwrap();
    store
        .connection
        .execute(
            "UPDATE imports SET source_digest = ?2 WHERE session_id = ?1",
            params![&evidence.session_id.0, wrong],
        )
        .unwrap();
    let before = store.digest_computations();
    assert_eq!(
        available(&store, &evidence.session_id),
        RuntimePlayableMediaAvailability::Corrupt
    );
    assert_eq!(store.digest_computations(), before);
    store
        .connection
        .execute(
            "UPDATE segments SET digest = ?2 WHERE session_id = ?1",
            params![&evidence.session_id.0, evidence.digest_sha256],
        )
        .unwrap();
    store
        .connection
        .execute(
            "UPDATE imports SET source_digest = ?2 WHERE session_id = ?1",
            params![&evidence.session_id.0, evidence.digest_sha256],
        )
        .unwrap();

    let original_time = fs::metadata(&managed).unwrap().modified().unwrap();
    let original_identity =
        sealed_media_identity::media_identity(&File::open(&managed).unwrap()).unwrap();
    let file = OpenOptions::new().write(true).open(&managed).unwrap();
    file.write_all_at(&[99], 64).unwrap();
    file.set_times(fs::FileTimes::new().set_modified(original_time))
        .unwrap();
    file.sync_all().unwrap();
    let changed_identity = sealed_media_identity::media_identity(&file).unwrap();
    assert_eq!(
        (original_identity.3, original_identity.4),
        (changed_identity.3, changed_identity.4)
    );
    assert_ne!(
        (original_identity.5, original_identity.6),
        (changed_identity.5, changed_identity.6)
    );
    assert_eq!(
        available(&store, &evidence.session_id),
        RuntimePlayableMediaAvailability::Corrupt
    );
    assert_eq!(store.digest_computations(), before + 1);
    assert_eq!(store.snapshot_digest_memo.borrow().len(), 1);
    assert!(store.lease_imported_playback(&evidence.session_id).is_err());
    assert!(
        store
            .open_verified_media(&evidence.session_id, &inventory.media[0])
            .is_err()
    );
    assert!(
        store
            .open_decoded_transcription_input(&input, &decoded)
            .is_err()
    );
}

#[test]
fn sealed_identity_snapshot_memo_rejects_cached_path_changes_and_never_caches_failed_validation() {
    for compressed in [false, true] {
        for change in 0..5 {
            let temp = TempDir::new().unwrap();
            let (store, evidence, managed) = imported(&temp, compressed);
            renumber_receipts(&store, &evidence.session_id);
            assert_eq!(
                available(&store, &evidence.session_id),
                RuntimePlayableMediaAvailability::Available
            );
            let original = managed.clone();
            let alter = move || match change {
                0 => {
                    let bytes = fs::read(&original).unwrap();
                    fs::rename(&original, original.with_extension("original")).unwrap();
                    fs::write(original, bytes).unwrap();
                }
                1 => {
                    fs::rename(&original, original.with_extension("original")).unwrap();
                    std::os::unix::fs::symlink(original.with_extension("original"), original)
                        .unwrap();
                }
                2 | 3 | 4 => {
                    let ancestor = original.ancestors().nth(change - 1).unwrap();
                    fs::rename(ancestor, ancestor.with_extension("original")).unwrap();
                    std::os::unix::fs::symlink(ancestor.with_extension("original"), ancestor)
                        .unwrap();
                }
                _ => unreachable!(),
            };
            if change >= 2 {
                *store.media_validation_hook.borrow_mut() = Some(Box::new(alter));
            } else {
                alter();
            }
            assert_eq!(
                available(&store, &evidence.session_id),
                RuntimePlayableMediaAvailability::Corrupt
            );
            assert!(store.lease_imported_playback(&evidence.session_id).is_err());
        }
    }
    let temp = TempDir::new().unwrap();
    let (store, evidence, managed) = imported(&temp, true);
    renumber_receipts(&store, &evidence.session_id);
    let file = OpenOptions::new().write(true).open(&managed).unwrap();
    file.write_all_at(&[99], 64).unwrap();
    file.sync_all().unwrap();
    assert_eq!(
        available(&store, &evidence.session_id),
        RuntimePlayableMediaAvailability::Corrupt
    );
    assert!(store.snapshot_digest_memo.borrow().is_empty());
}

#[test]
fn sealed_identity_snapshot_memo_is_bounded_and_not_persistent() {
    let temp = TempDir::new().unwrap();
    let (store, evidence, _) = imported(&temp, true);
    renumber_receipts(&store, &evidence.session_id);
    for _ in 0..65 {
        let (_, evidence, _) = imported(&temp, true);
        renumber_receipts(&store, &evidence.session_id);
    }
    let snapshot = store.runtime_library_snapshot().unwrap();
    assert_eq!(snapshot.saved_sessions.len(), 66);
    assert!(
        snapshot.saved_sessions.iter().all(|saved| saved
            .playable_media
            .as_ref()
            .unwrap()
            .availability
            == RuntimePlayableMediaAvailability::Available)
    );
    assert_eq!(store.snapshot_digest_memo.borrow().len(), 64);
    drop(store);
    let reopened = open_store(&temp);
    assert!(reopened.snapshot_digest_memo.borrow().is_empty());
}

#[test]
fn sealed_identity_saved_capture_device_renumber_survives_journal_replay_and_leases() {
    let temp = TempDir::new().unwrap();
    let (mut store, session, a) = captured(&temp, true);
    let bytes = fs::read(&a.absolute_path).unwrap();
    renumber_receipts(&store, &session);
    let recovery = store.recover_library().unwrap();
    assert!(
        !recovery
            .findings
            .iter()
            .any(|f| f.disposition.blocks_recovery())
    );
    assert!(
        store
            .runtime_library_snapshot()
            .unwrap()
            .saved_sessions
            .iter()
            .any(|saved| saved.session_id == session && saved.has_capture_timeline)
    );
    let timeline = store.playback_timeline(&session).unwrap();
    assert_eq!(timeline.len(), 1);
    store
        .lease_capture_playback(
            &session,
            &timeline[0].source_id,
            &a.track_id,
            &a.segment_id,
            true,
        )
        .unwrap();
    let input = store.transcription_input(&session, &a.track_id).unwrap();
    store.open_transcription_input(&input).unwrap();
    let inventory = store.session_inventory(&session).unwrap();
    store
        .open_verified_media(&session, &inventory.media[0])
        .unwrap();
    assert_eq!(fs::read(a.absolute_path).unwrap(), bytes);
}

#[test]
fn sealed_identity_recovered_capture_device_renumber_is_playable_and_idempotent() {
    let temp = TempDir::new().unwrap();
    let (mut store, session, a) = captured(&temp, false);
    assert_eq!(store.recover_playable_sessions().unwrap().len(), 1);
    renumber_receipts(&store, &session);
    for _ in 0..2 {
        let playable = store.recover_playable_sessions().unwrap();
        assert_eq!(playable.len(), 1);
        let row = &playable[0];
        store
            .lease_recovered_playback(&session, &row.source_id, &a.track_id, &a.segment_id)
            .unwrap();
    }
}

#[test]
fn sealed_identity_seal_journal_crash_replays_after_device_renumber() {
    let temp = TempDir::new().unwrap();
    let (mut store, session, a) = captured(&temp, false);
    let mut receipt = seal_receipt(&a, 68 + 960 * 2);
    receipt.final_sample_host_time = 20_042_000;
    assert!(matches!(
        store.seal_segment_inner(receipt, Some(MediaFailurePoint::SegmentSealJournalSync)),
        Err(StoreError::InjectedInterruption)
    ));
    renumber_receipts(&store, &session);
    assert_eq!(
        store.recover_preparations().unwrap()[0].disposition,
        RecoveryDisposition::SegmentSealProjectionRepaired
    );
    assert!(
        store
            .runtime_library_snapshot()
            .unwrap()
            .saved_sessions
            .iter()
            .any(|saved| saved.session_id == session && saved.has_capture_timeline)
    );
    let timeline = store.playback_timeline(&session).unwrap();
    assert_eq!(timeline.len(), 1);
    store
        .lease_capture_playback(
            &session,
            &timeline[0].source_id,
            &a.track_id,
            &a.segment_id,
            true,
        )
        .unwrap();
}

#[test]
fn sealed_identity_replays_verified_recovery_receipt_after_projection_crash_and_device_renumber() {
    let temp = TempDir::new().unwrap();
    let (mut store, session, a) = captured(&temp, false);
    let validated = store
        .validate_media_file(
            &session.0,
            &a.relative_path,
            MediaLengthRequirement::Exact(68 + 960 * 2),
            true,
        )
        .unwrap();
    let source: String = store
        .connection
        .query_row(
            "SELECT source_id FROM tracks WHERE id = ?1",
            [&a.track_id],
            |r| r.get(0),
        )
        .unwrap();
    store.append_session_journal(&session.0, "playable_media_recovered", Some(&a.relative_path), json!({
        "source_id": source, "track_id": a.track_id, "segment_id": a.segment_id,
        "relative_path": a.relative_path, "sample_count": 960,
        "final_byte_length": validated.byte_length, "digest_sha256": validated.digest_sha256.unwrap(),
        "file_device": validated.device, "file_inode": validated.inode, "truncated_bytes": 0,
    })).unwrap();
    renumber_receipts(&store, &session);
    assert_eq!(store.recover_playable_sessions().unwrap().len(), 1);
    assert_eq!(store.recover_playable_sessions().unwrap().len(), 1);
    let path = store
        .session_directory(&session.0)
        .unwrap()
        .join(JOURNAL_NAME);
    let JournalValidation::Valid(records) = validate_journal(&path, &session.0).unwrap() else {
        panic!()
    };
    assert_eq!(
        records
            .iter()
            .filter(|r| r.body.event_kind == "playable_media_recovered")
            .count(),
        1
    );
}

#[test]
fn sealed_identity_unsealed_device_renumber_remains_rejected() {
    let temp = TempDir::new().unwrap();
    let (mut store, session, a) = captured(&temp, false);
    let bytes = fs::read(&a.absolute_path).unwrap();
    renumber_receipts(&store, &session);
    let recovery = store.recover_library().unwrap();
    assert!(recovery.playable.is_empty());
    assert!(
        recovery
            .findings
            .iter()
            .any(|f| f.disposition == RecoveryDisposition::InvalidMediaFile)
    );
    assert_eq!(fs::read(a.absolute_path).unwrap(), bytes);
}

#[test]
fn sealed_identity_renumbered_capture_with_changed_content_is_refused() {
    // Inode and length stay the same, so only the recorded digest can catch it.
    fn change_first_sample(path: &Path) {
        File::options()
            .write(true)
            .open(path)
            .unwrap()
            .write_at(&[1], 68)
            .unwrap();
    }

    let temp = TempDir::new().unwrap();
    let (store, session, a) = captured(&temp, true);
    renumber_receipts(&store, &session);
    change_first_sample(&a.absolute_path);
    let source: String = store
        .connection
        .query_row(
            "SELECT source_id FROM tracks WHERE id = ?1",
            [&a.track_id],
            |r| r.get(0),
        )
        .unwrap();
    assert!(
        store
            .lease_capture_playback(&session, &source, &a.track_id, &a.segment_id, true)
            .is_err()
    );
    assert!(
        store
            .transcription_input(&session, &a.track_id)
            .and_then(|input| store.open_transcription_input(&input).map(drop))
            .is_err()
    );
    assert_ne!(
        available(&store, &session),
        RuntimePlayableMediaAvailability::Available
    );

    // Replaying a seal receipt whose projection crashed takes the same rule.
    let temp = TempDir::new().unwrap();
    let (mut store, session, a) = captured(&temp, false);
    let mut receipt = seal_receipt(&a, 68 + 960 * 2);
    receipt.final_sample_host_time = 20_042_000;
    assert!(matches!(
        store.seal_segment_inner(receipt, Some(MediaFailurePoint::SegmentSealJournalSync)),
        Err(StoreError::InjectedInterruption)
    ));
    renumber_receipts(&store, &session);
    change_first_sample(&a.absolute_path);
    assert_eq!(
        store.recover_preparations().unwrap()[0].disposition,
        RecoveryDisposition::IntegrityMismatch
    );
}

#[test]
fn sealed_identity_rejects_replacement_digest_length_and_symlink_changes() {
    for compressed in [false, true] {
        for change in 0..6 {
            let temp = TempDir::new().unwrap();
            let (store, evidence, managed) = imported(&temp, compressed);
            renumber_receipts(&store, &evidence.session_id);
            let bytes = fs::read(&managed).unwrap();
            match change {
                0 => {
                    fs::rename(&managed, managed.with_extension("original")).unwrap();
                    fs::write(&managed, &bytes).unwrap();
                }
                1 => {
                    File::options()
                        .write(true)
                        .open(&managed)
                        .unwrap()
                        .write_at(&[1], 68)
                        .unwrap();
                }
                2 => {
                    File::options()
                        .write(true)
                        .open(&managed)
                        .unwrap()
                        .set_len(bytes.len() as u64 - 1)
                        .unwrap();
                }
                3 => {
                    File::options()
                        .write(true)
                        .open(&managed)
                        .unwrap()
                        .set_len(bytes.len() as u64 + 1)
                        .unwrap();
                }
                4 => {
                    let original = managed.with_extension("original");
                    fs::rename(&managed, &original).unwrap();
                    symlink(original, &managed).unwrap();
                }
                5 => {
                    let track = managed.parent().unwrap();
                    let original = track.with_extension("original");
                    fs::rename(track, &original).unwrap();
                    symlink(original, track).unwrap();
                }
                _ => unreachable!(),
            }
            assert!(
                store.lease_imported_playback(&evidence.session_id).is_err(),
                "format={compressed}, change={change}"
            );
            assert_ne!(
                available(&store, &evidence.session_id),
                RuntimePlayableMediaAvailability::Available
            );
        }
    }
}

#[test]
fn sealed_identity_validation_rejects_deterministic_file_and_ancestor_races() {
    for compressed in [false, true] {
        for change in 0..5 {
            let temp = TempDir::new().unwrap();
            let (store, evidence, managed) = imported(&temp, compressed);
            renumber_receipts(&store, &evidence.session_id);
            let race_path = managed.clone();
            let bytes = fs::read(&managed).unwrap();
            *store.media_validation_hook.borrow_mut() = Some(Box::new(move || match change {
                0 => {
                    File::options()
                        .write(true)
                        .open(&race_path)
                        .unwrap()
                        .write_at(&[1], 68)
                        .unwrap();
                }
                1 => {
                    fs::rename(&race_path, race_path.with_extension("original")).unwrap();
                    fs::write(&race_path, bytes).unwrap();
                }
                2..=4 => {
                    let ancestor = match change {
                        2 => race_path.parent().unwrap(),
                        3 => race_path.parent().unwrap().parent().unwrap(),
                        4 => race_path
                            .parent()
                            .unwrap()
                            .parent()
                            .unwrap()
                            .parent()
                            .unwrap(),
                        _ => unreachable!(),
                    };
                    fs::rename(ancestor, ancestor.with_extension("original")).unwrap();
                    fs::create_dir(ancestor).unwrap();
                }
                _ => unreachable!(),
            }));
            assert!(
                store.lease_imported_playback(&evidence.session_id).is_err(),
                "format={compressed}, race={change}"
            );
        }
    }
}

#[test]
fn sealed_identity_launch_memo_rehashes_in_place_changes_and_never_caches_failed_validation() {
    let temp = TempDir::new().unwrap();
    let (store, evidence, managed) = imported(&temp, false);
    renumber_receipts(&store, &evidence.session_id);
    store.digest_memo.borrow_mut().begin_launch();
    store.lease_imported_playback(&evidence.session_id).unwrap();
    let count = store.digest_computations();
    File::options()
        .write(true)
        .open(&managed)
        .unwrap()
        .write_at(&[1], 68)
        .unwrap();
    assert!(store.lease_imported_playback(&evidence.session_id).is_err());
    assert_eq!(store.digest_computations(), count + 1);
    store.digest_memo.borrow_mut().end_launch();

    let temp = TempDir::new().unwrap();
    let (store, evidence, managed) = imported(&temp, false);
    let file = File::open(&managed).unwrap();
    let before = sealed_media_identity::media_identity(&file).unwrap();
    store.digest_memo.borrow_mut().begin_launch();
    let race_path = managed.clone();
    *store.media_validation_hook.borrow_mut() = Some(Box::new(move || {
        let parent = race_path.parent().unwrap();
        fs::rename(parent, parent.with_extension("original")).unwrap();
    }));
    assert!(store.lease_imported_playback(&evidence.session_id).is_err());
    assert!(store.digest_memo.borrow().recall(before).is_none());
    assert!(store.digest_computations() > 0);
    store.digest_memo.borrow_mut().end_launch();
}
