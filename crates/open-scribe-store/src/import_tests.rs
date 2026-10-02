use std::fs::OpenOptions;
use std::io::{SeekFrom, Write};
use std::os::unix::fs::{FileExt, MetadataExt, symlink};

use tempfile::TempDir;

use super::*;
use crate::RuntimePlayableMediaAvailability;

// Store tests synthesize the platform probe. Native component tests exercise
// AudioToolbox with actual AAC/ALAC containers and independent channel samples.
fn compressed_source(path: &Path) -> CompressedImportMetadata {
    let mut bytes = b"\x00\x00\x00\x1cftypM4A \x00\x00\x00\x00M4A isommp42".to_vec();
    bytes.extend_from_slice(&[42; 256]);
    fs::write(path, &bytes).unwrap();
    CompressedImportMetadata {
        original: OriginalImportMetadata {
            display_name: "Stereo memo.m4a".to_owned(),
            byte_length: bytes.len() as u64,
            duration_nanoseconds: 1_000_000_000,
            sample_rate_hz: 48_000,
            channel_count: 2,
            media_format: "m4a".to_owned(),
        },
        sample_count: 48_000,
        digest_sha256: format!("{:x}", Sha256::digest(&bytes)),
    }
}

#[test]
fn compressed_import_is_byte_preserving_and_reopens_with_a_streaming_lease() {
    let temp = TempDir::new().unwrap();
    let source = temp.path().join("source.m4a");
    let metadata = compressed_source(&source);
    let original = fs::read(&source).unwrap();
    let root = temp.path().join("Library");
    let mut store = SessionStore::open(&root).unwrap();
    let evidence = store
        .import_compressed_m4a(
            ImportMediaRequest {
                title: "Stereo memo".to_owned(),
                source_path: source.clone(),
            },
            metadata,
        )
        .unwrap();
    assert!(evidence.relative_path.ends_with(".m4a"));
    assert_eq!(fs::read(&source).unwrap(), original);
    drop(store);
    let reopened = SessionStore::open(&root).unwrap();
    let snapshot = reopened.runtime_library_snapshot().unwrap();
    assert_eq!(snapshot.saved_sessions.len(), 1);
    assert_eq!(
        snapshot.saved_sessions[0]
            .playable_media
            .as_ref()
            .unwrap()
            .duration_nanoseconds,
        1_000_000_000
    );
    let lease = reopened
        .lease_imported_playback(&evidence.session_id)
        .unwrap();
    assert_eq!(lease.media_format(), COMPRESSED_IMPORT_MEDIA_FORMAT);
    assert_eq!(lease.byte_length(), original.len() as u64);
    assert!(evidence.original_untouched);
}

#[test]
fn compressed_import_rejects_source_drift_before_creating_library_rows() {
    let temp = TempDir::new().unwrap();
    let source = temp.path().join("source.m4a");
    let metadata = compressed_source(&source);
    let mut bytes = fs::read(&source).unwrap();
    bytes[40] ^= 1;
    fs::write(&source, bytes).unwrap();
    let mut store = SessionStore::open(temp.path().join("Library")).unwrap();
    assert!(
        store
            .import_compressed_m4a(
                ImportMediaRequest {
                    title: "Memo".to_owned(),
                    source_path: source
                },
                metadata
            )
            .is_err()
    );
    assert!(
        store
            .runtime_library_snapshot()
            .unwrap()
            .saved_sessions
            .is_empty()
    );
}

#[test]
fn compressed_import_policy_rejects_excess_and_unsupported_metadata_without_rows() {
    let temp = TempDir::new().unwrap();
    let source = temp.path().join("source.m4a");
    let metadata = compressed_source(&source);
    let mut store = SessionStore::open(temp.path().join("Library")).unwrap();
    for invalid in 0..5 {
        let mut candidate = metadata.clone();
        match invalid {
            0 => candidate.original.byte_length = MAX_COMPRESSED_IMPORT_BYTES + 1,
            1 => candidate.sample_count = MAX_IMPORT_SAMPLES + 1,
            2 => candidate.original.duration_nanoseconds = MAX_IMPORT_DURATION_NANOSECONDS + 1,
            3 => candidate.original.sample_rate_hz = 44_100,
            4 => candidate.original.channel_count = 3,
            _ => unreachable!(),
        }
        let error = store
            .import_compressed_m4a(
                ImportMediaRequest {
                    title: "Memo".to_owned(),
                    source_path: source.clone(),
                },
                candidate,
            )
            .unwrap_err();
        match invalid {
            0 => assert!(matches!(error, StoreError::ImportSizeLimit)),
            1 | 2 => assert!(matches!(error, StoreError::ImportDurationLimit)),
            _ => assert!(matches!(error, StoreError::InvalidRequest(_))),
        }
    }
    assert!(
        store
            .runtime_library_snapshot()
            .unwrap()
            .saved_sessions
            .is_empty()
    );
}

#[test]
fn compressed_import_lease_rejects_same_length_managed_corruption() {
    let temp = TempDir::new().unwrap();
    let source = temp.path().join("source.m4a");
    let metadata = compressed_source(&source);
    let mut store = SessionStore::open(temp.path().join("Library")).unwrap();
    let evidence = store
        .import_compressed_m4a(
            ImportMediaRequest {
                title: "Memo".to_owned(),
                source_path: source,
            },
            metadata,
        )
        .unwrap();
    let managed = store
        .session_directory(&evidence.session_id.0)
        .unwrap()
        .join(&evidence.relative_path);
    let mut bytes = fs::read(&managed).unwrap();
    bytes[40] ^= 1;
    fs::write(managed, bytes).unwrap();
    assert!(store.lease_imported_playback(&evidence.session_id).is_err());
}

#[test]
fn compressed_import_staged_failure_reconciles_with_its_m4a_destination() {
    let temp = TempDir::new().unwrap();
    let source = temp.path().join("source.m4a");
    let metadata = compressed_source(&source);
    let mut store = SessionStore::open(temp.path().join("Library")).unwrap();
    let evidence = store
        .import_inner(
            ImportMediaRequest {
                title: "Memo".to_owned(),
                source_path: source,
            },
            Some(metadata.original.clone()),
            Some(metadata),
            Some(ImportFailurePoint::StagedJournalDurable),
        )
        .unwrap();
    assert!(evidence.ready_for_review);
    assert!(store.lease_imported_playback(&evidence.session_id).is_ok());
}

fn write_recoverable_caf(path: &Path, sample_count: u64) {
    let mut file = File::create(path).unwrap();
    file.write_all(CAF_HEADER).unwrap();
    file.write_all(b"desc").unwrap();
    file.write_all(&32_i64.to_be_bytes()).unwrap();
    file.write_all(&48_000_f64.to_bits().to_be_bytes()).unwrap();
    file.write_all(b"lpcm").unwrap();
    file.write_all(&2_u32.to_be_bytes()).unwrap();
    file.write_all(&2_u32.to_be_bytes()).unwrap();
    file.write_all(&1_u32.to_be_bytes()).unwrap();
    file.write_all(&1_u32.to_be_bytes()).unwrap();
    file.write_all(&16_u32.to_be_bytes()).unwrap();
    file.write_all(b"data").unwrap();
    file.write_all(&(-1_i64).to_be_bytes()).unwrap();
    file.write_all(&0_u32.to_be_bytes()).unwrap();
    file.write_all(&vec![0_u8; sample_count as usize * 2])
        .unwrap();
    file.sync_all().unwrap();
}

fn write_sparse_recoverable_caf(path: &Path, sample_count: u64) {
    let mut file = File::create(path).unwrap();
    file.write_all(CAF_HEADER).unwrap();
    file.write_all(b"desc").unwrap();
    file.write_all(&32_i64.to_be_bytes()).unwrap();
    file.write_all(&48_000_f64.to_bits().to_be_bytes()).unwrap();
    file.write_all(b"lpcm").unwrap();
    file.write_all(&2_u32.to_be_bytes()).unwrap();
    file.write_all(&2_u32.to_be_bytes()).unwrap();
    file.write_all(&1_u32.to_be_bytes()).unwrap();
    file.write_all(&1_u32.to_be_bytes()).unwrap();
    file.write_all(&16_u32.to_be_bytes()).unwrap();
    file.write_all(b"data").unwrap();
    file.write_all(&(-1_i64).to_be_bytes()).unwrap();
    file.write_all(&0_u32.to_be_bytes()).unwrap();
    file.set_len(68 + sample_count * 2).unwrap();
    file.sync_all().unwrap();
}

#[test]
fn managed_caf_import_preserves_original_and_enters_the_existing_library() {
    let temp = TempDir::new().unwrap();
    let source_path = temp.path().join("donella-review.caf");
    write_recoverable_caf(&source_path, 960);
    let original = fs::read(&source_path).unwrap();
    let mut store = SessionStore::open(temp.path().join("Open Scribe")).unwrap();

    let evidence = store
        .import_recoverable_caf(ImportMediaRequest {
            title: "Donella review".to_owned(),
            source_path: source_path.clone(),
        })
        .unwrap();

    assert!(evidence.ready_for_review);
    assert!(evidence.original_untouched);
    assert_eq!(evidence.sample_count, 960);
    assert_eq!(evidence.digest_sha256.len(), 64);
    assert_eq!(fs::read(&source_path).unwrap(), original);
    assert_eq!(
        fs::read(
            store
                .session_directory(&evidence.session_id.0)
                .unwrap()
                .join(&evidence.relative_path)
        )
        .unwrap(),
        original
    );
    let snapshot = store.runtime_library_snapshot().unwrap();
    assert!(snapshot.current_session.is_none());
    assert_eq!(snapshot.saved_sessions.len(), 1);
    assert_eq!(snapshot.saved_sessions[0].session_id, evidence.session_id);
    assert_eq!(snapshot.saved_sessions[0].title, "Donella review");
    let playable = snapshot.saved_sessions[0].playable_media.as_ref().unwrap();
    assert_eq!(playable.source_display_name, "donella-review.caf");
    assert_eq!(
        playable.availability,
        RuntimePlayableMediaAvailability::Available
    );
    assert_eq!(playable.sample_count, 960);
    assert_eq!(playable.duration_nanoseconds, 20_000_000);
    assert!(playable.absolute_path.is_none());
    assert_eq!(
        store
            .connection
            .query_row(
                "SELECT COUNT(*) FROM imports WHERE session_id = ?1",
                [&evidence.session_id.0],
                |row| row.get::<_, i64>(0)
            )
            .unwrap(),
        1
    );
    assert_eq!(
        store
            .connection
            .query_row(
                "SELECT COUNT(*) FROM session_events
                 WHERE session_id = ?1 AND event_kind = 'recording_started'",
                [&evidence.session_id.0],
                |row| row.get::<_, i64>(0)
            )
            .unwrap(),
        0
    );
}

#[test]
fn normalized_import_retains_original_metadata_and_reopens_as_playable_media() {
    let temp = TempDir::new().unwrap();
    let caf_path = temp.path().join("normalized.caf");
    write_recoverable_caf(&caf_path, 960);
    let original_caf = fs::read(&caf_path).unwrap();
    let managed_root = temp.path().join("Open Scribe");
    let mut store = SessionStore::open(&managed_root).unwrap();
    let evidence = store
        .import_normalized_caf(
            ImportMediaRequest {
                title: "Voice memo".to_owned(),
                source_path: caf_path.clone(),
            },
            OriginalImportMetadata {
                display_name: "Voice memo.m4a".to_owned(),
                byte_length: 8_192,
                duration_nanoseconds: 20_000_000,
                sample_rate_hz: 44_100,
                channel_count: 1,
                media_format: "m4a".to_owned(),
            },
        )
        .unwrap();
    assert_eq!(fs::read(&caf_path).unwrap(), original_caf);
    let snapshot = store.runtime_library_snapshot().unwrap();
    assert_eq!(snapshot.saved_sessions.len(), 1);
    assert_eq!(
        snapshot.saved_sessions[0]
            .playable_media
            .as_ref()
            .unwrap()
            .source_display_name,
        "Voice memo.m4a"
    );
    let journal = fs::read_to_string(
        store
            .session_directory(&evidence.session_id.0)
            .unwrap()
            .join("recovery.jsonl"),
    )
    .unwrap();
    assert!(journal.contains("\"original_media\""));
    assert!(journal.contains("\"sample_rate_hz\":44100"));
    drop(store);
    let reopened = SessionStore::open(managed_root).unwrap();
    assert!(
        reopened
            .lease_imported_playback(&evidence.session_id)
            .is_ok()
    );
}

#[test]
fn import_bounds_have_distinct_size_and_duration_failures() {
    let policy = import_policy();
    assert_eq!(
        policy.maximum_managed_bytes,
        ImportedPlaybackLease::maximum_snapshot_byte_length()
    );
    assert!(matches!(
        validate_import_bounds(policy.maximum_managed_bytes + 1, 1),
        Err(StoreError::ImportSizeLimit)
    ));
    assert!(matches!(
        validate_import_bounds(96_068, policy.maximum_managed_samples + 1),
        Err(StoreError::ImportDurationLimit)
    ));
}

#[test]
fn imported_library_playback_fails_closed_when_managed_media_is_missing_or_corrupt() {
    let temp = TempDir::new().unwrap();
    let managed_root = temp.path().join("Open Scribe");
    let mut store = SessionStore::open(&managed_root).unwrap();

    let missing_source = temp.path().join("missing-later.caf");
    write_recoverable_caf(&missing_source, 48_000);
    let missing = store
        .import_recoverable_caf(ImportMediaRequest {
            title: "Missing later".to_owned(),
            source_path: missing_source,
        })
        .unwrap();
    fs::remove_file(
        store
            .session_directory(&missing.session_id.0)
            .unwrap()
            .join(&missing.relative_path),
    )
    .unwrap();

    let corrupt_source = temp.path().join("corrupt-later.caf");
    write_recoverable_caf(&corrupt_source, 96_000);
    let corrupt = store
        .import_recoverable_caf(ImportMediaRequest {
            title: "Corrupt later".to_owned(),
            source_path: corrupt_source,
        })
        .unwrap();
    let corrupt_path = store
        .session_directory(&corrupt.session_id.0)
        .unwrap()
        .join(&corrupt.relative_path);
    let mut corrupt_file = fs::OpenOptions::new()
        .write(true)
        .open(&corrupt_path)
        .unwrap();
    corrupt_file.seek(std::io::SeekFrom::Start(68)).unwrap();
    corrupt_file.write_all(&[1]).unwrap();
    corrupt_file.sync_all().unwrap();
    drop(corrupt_file);
    let replacement_digest = format!("{:x}", Sha256::digest(fs::read(&corrupt_path).unwrap()));
    store
        .connection
        .execute(
            "UPDATE segments SET digest = ?2 WHERE session_id = ?1",
            params![&corrupt.session_id.0, replacement_digest],
        )
        .unwrap();

    let snapshot = store.runtime_library_snapshot().unwrap();
    let missing_playback = snapshot
        .saved_sessions
        .iter()
        .find(|session| session.session_id == missing.session_id)
        .unwrap()
        .playable_media
        .as_ref()
        .unwrap();
    assert_eq!(
        missing_playback.availability,
        RuntimePlayableMediaAvailability::Unavailable
    );
    assert!(missing_playback.absolute_path.is_none());
    assert_eq!(missing_playback.duration_nanoseconds, 1_000_000_000);

    let corrupt_playback = snapshot
        .saved_sessions
        .iter()
        .find(|session| session.session_id == corrupt.session_id)
        .unwrap()
        .playable_media
        .as_ref()
        .unwrap();
    assert_eq!(
        corrupt_playback.availability,
        RuntimePlayableMediaAvailability::Corrupt
    );
    assert!(corrupt_playback.absolute_path.is_none());
    assert_eq!(corrupt_playback.duration_nanoseconds, 2_000_000_000);
}

#[test]
fn imported_playback_lease_retains_the_validated_object_across_path_replacement() {
    let temp = TempDir::new().unwrap();
    let source_path = temp.path().join("leased.caf");
    write_recoverable_caf(&source_path, 48_000);
    let original = fs::read(&source_path).unwrap();
    let mut store = SessionStore::open(temp.path().join("Open Scribe")).unwrap();
    let imported = store
        .import_recoverable_caf(ImportMediaRequest {
            title: "Leased import".to_owned(),
            source_path,
        })
        .unwrap();
    let lease = store.lease_imported_playback(&imported.session_id).unwrap();
    let managed_path = store
        .session_directory(&imported.session_id.0)
        .unwrap()
        .join(&imported.relative_path);

    fs::remove_file(&managed_path).unwrap();
    write_recoverable_caf(&managed_path, 96_000);

    let mut leased_file = lease.file.try_clone().unwrap();
    let mut leased_bytes = Vec::new();
    leased_file.read_to_end(&mut leased_bytes).unwrap();
    assert_eq!(leased_bytes, original);
    assert_eq!(lease.byte_length(), original.len() as u64);
    assert_eq!(lease.digest_sha256(), imported.digest_sha256);
    assert_eq!(
        ImportedPlaybackLease::maximum_snapshot_byte_length(),
        MAX_IMPORTED_PLAYBACK_SNAPSHOT_BYTES
    );
    assert_ne!(fs::read(managed_path).unwrap(), original);
    assert!(store.lease_imported_playback(&imported.session_id).is_err());
}

#[test]
fn imported_playback_lease_preserves_admitted_digest_for_native_copy_validation() {
    let temp = TempDir::new().unwrap();
    let source_path = temp.path().join("same-inode.caf");
    write_recoverable_caf(&source_path, 48_000);
    let original = fs::read(&source_path).unwrap();
    let managed_root = temp.path().join("Open Scribe");
    let mut store = SessionStore::open(&managed_root).unwrap();
    let imported = store
        .import_recoverable_caf(ImportMediaRequest {
            title: "Same inode import".to_owned(),
            source_path,
        })
        .unwrap();
    let lease = store.lease_imported_playback(&imported.session_id).unwrap();
    let managed_path = store
        .session_directory(&imported.session_id.0)
        .unwrap()
        .join(&imported.relative_path);
    let before = fs::metadata(&managed_path).unwrap();

    let mut managed = OpenOptions::new().write(true).open(&managed_path).unwrap();
    managed.seek(SeekFrom::End(-1)).unwrap();
    managed.write_all(&[1]).unwrap();
    managed.sync_all().unwrap();
    let after = fs::metadata(&managed_path).unwrap();

    assert_eq!(after.dev(), before.dev());
    assert_eq!(after.ino(), before.ino());
    assert_eq!(after.len(), before.len());
    assert_ne!(fs::read(&managed_path).unwrap(), original);
    let mut leased_file = lease.file.try_clone().unwrap();
    let mut changed_bytes = Vec::new();
    leased_file.read_to_end(&mut changed_bytes).unwrap();
    assert_ne!(changed_bytes, original);
    assert_ne!(
        format!("{:x}", Sha256::digest(&changed_bytes)),
        lease.digest_sha256()
    );
    assert_eq!(lease.byte_length(), original.len() as u64);
    assert_eq!(lease.digest_sha256(), imported.digest_sha256);
    assert!(store.lease_imported_playback(&imported.session_id).is_err());
    assert!(fs::read_dir(&managed_root).unwrap().all(|entry| {
        !entry
            .unwrap()
            .file_name()
            .to_string_lossy()
            .starts_with(PLAYBACK_SNAPSHOT_PREFIX)
    }));
}

#[test]
fn imported_playback_lease_rejects_over_cap_evidence_before_media_revalidation() {
    let temp = TempDir::new().unwrap();
    let source_path = temp.path().join("over-cap-lease.caf");
    write_recoverable_caf(&source_path, 48_000);
    let mut store = SessionStore::open(temp.path().join("Open Scribe")).unwrap();
    let imported = store
        .import_recoverable_caf(ImportMediaRequest {
            title: "Over-cap playback lease".to_owned(),
            source_path,
        })
        .unwrap();
    let managed_path = store
        .session_directory(&imported.session_id.0)
        .unwrap()
        .join(&imported.relative_path);
    store
        .connection
        .execute(
            "UPDATE segments SET byte_length = ?2 WHERE session_id = ?1",
            params![
                &imported.session_id.0,
                i64::try_from(MAX_IMPORTED_PLAYBACK_SNAPSHOT_BYTES + 1).unwrap()
            ],
        )
        .unwrap();
    fs::remove_file(managed_path).unwrap();

    assert!(matches!(
        store.lease_imported_playback(&imported.session_id),
        Err(StoreError::InvalidState(
            "managed media exceeds the safe playback snapshot limit"
        ))
    ));
}

#[test]
fn p1_import_failure_before_durable_stage_is_tombstoned_and_not_visible() {
    let temp = TempDir::new().unwrap();
    let source_path = temp.path().join("early-failure.caf");
    write_recoverable_caf(&source_path, 48_000);
    let managed_root = temp.path().join("Open Scribe");
    let mut store = SessionStore::open(&managed_root).unwrap();

    assert!(
        store
            .import_recoverable_caf_inner(
                ImportMediaRequest {
                    title: "Failed import".to_owned(),
                    source_path,
                },
                None,
                Some(ImportFailurePoint::PreparationDurable),
            )
            .is_err()
    );

    let snapshot = store.runtime_library_snapshot().unwrap();
    assert!(snapshot.current_session.is_none());
    assert!(snapshot.saved_sessions.is_empty());
    let (lifecycle, health, failures): (String, String, i64) = store
        .connection
        .query_row(
            "SELECT sessions.lifecycle, sessions.health,
                    COUNT(session_events.id)
             FROM sessions
             LEFT JOIN session_events ON session_events.session_id = sessions.id
                                           AND session_events.event_kind = 'media_import_failed'
             WHERE sessions.origin = 'import'",
            [],
            |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?)),
        )
        .unwrap();
    assert_eq!(lifecycle, "deleted");
    assert_eq!(health, "degraded");
    assert_eq!(failures, 1);

    drop(store);
    let mut reopened = SessionStore::open(managed_root).unwrap();
    assert!(reopened.recover_playable_sessions().unwrap().is_empty());
    let snapshot = reopened.runtime_library_snapshot().unwrap();
    assert!(snapshot.current_session.is_none());
    assert!(snapshot.saved_sessions.is_empty());
}

#[test]
fn prestage_copy_failure_cleans_managed_bytes_before_tombstone() {
    let temp = TempDir::new().unwrap();
    let source_path = temp.path().join("copied-before-failure.caf");
    write_recoverable_caf(&source_path, 48_000);
    let original = fs::read(&source_path).unwrap();
    let managed_root = temp.path().join("Open Scribe");
    let mut store = SessionStore::open(&managed_root).unwrap();

    assert!(
        store
            .import_recoverable_caf_inner(
                ImportMediaRequest {
                    title: "Cleaned import".to_owned(),
                    source_path: source_path.clone(),
                },
                None,
                Some(ImportFailurePoint::ManagedCopyComplete),
            )
            .is_err()
    );

    assert_eq!(fs::read(&source_path).unwrap(), original);
    let (session_id, lifecycle, health): (String, String, String) = store
        .connection
        .query_row(
            "SELECT id, lifecycle, health FROM sessions WHERE origin = 'import'",
            [],
            |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?)),
        )
        .unwrap();
    assert_eq!(lifecycle, "deleted");
    assert_eq!(health, "degraded");
    assert_eq!(
        fs::read_dir(store.session_directory(&session_id).unwrap().join("audio"))
            .unwrap()
            .count(),
        0
    );
    assert!(
        store
            .runtime_library_snapshot()
            .unwrap()
            .saved_sessions
            .is_empty()
    );
}

#[test]
fn p1_staged_import_failure_reconciles_to_ready_instead_of_reporting_no_add() {
    let temp = TempDir::new().unwrap();
    let source_path = temp.path().join("staged-failure.caf");
    write_recoverable_caf(&source_path, 48_000);
    let mut store = SessionStore::open(temp.path().join("Open Scribe")).unwrap();

    let evidence = store
        .import_recoverable_caf_inner(
            ImportMediaRequest {
                title: "Recovered staged import".to_owned(),
                source_path,
            },
            None,
            Some(ImportFailurePoint::StagedJournalDurable),
        )
        .unwrap();

    assert!(evidence.ready_for_review);
    let snapshot = store.runtime_library_snapshot().unwrap();
    assert!(snapshot.current_session.is_none());
    assert_eq!(snapshot.saved_sessions.len(), 1);
    assert_eq!(snapshot.saved_sessions[0].session_id, evidence.session_id);
}

#[test]
fn p1_recovered_playback_lease_binds_exact_record_across_path_replacement_without_import_cap() {
    let temp = TempDir::new().unwrap();
    let mut store = SessionStore::open(temp.path().join("Open Scribe")).unwrap();
    let prepared = store
        .prepare_session_with_required_sources(
            PrepareSessionRequest {
                title: "Recovered lease".to_owned(),
                origin: SessionOrigin::Capture,
            },
            vec![crate::MediaSourceKind::Microphone],
        )
        .unwrap();
    let authorization = store
        .authorize_media_open(crate::AuthorizeMediaOpenRequest {
            session_id: prepared.session_id.clone(),
            source_kind: crate::MediaSourceKind::Microphone,
            source_display_name: "Synthetic microphone".to_owned(),
        })
        .unwrap();
    write_recoverable_caf(&authorization.absolute_path, 0);
    let initial_byte_length = authorization.absolute_path.metadata().unwrap().len();
    store
        .accept_media_open(crate::MediaOpenReceipt {
            session_id: authorization.session_id.clone(),
            track_id: authorization.track_id.clone(),
            segment_id: authorization.segment_id.clone(),
            open_token: authorization.open_token.clone(),
            writer_generation: authorization.writer_generation,
            relative_path: authorization.relative_path.clone(),
            media_format: authorization.media_format.clone(),
            sample_rate_hz: authorization.sample_rate_hz,
            channels: authorization.channels,
            initial_byte_length,
        })
        .unwrap();
    let observed_byte_length = {
        let mut writer = OpenOptions::new()
            .append(true)
            .open(&authorization.absolute_path)
            .unwrap();
        writer.write_all(&vec![0_u8; 960 * 2]).unwrap();
        writer.sync_all().unwrap();
        writer.metadata().unwrap().len()
    };
    store
        .accept_first_sample(crate::FirstSampleReceipt {
            session_id: authorization.session_id.clone(),
            track_id: authorization.track_id.clone(),
            segment_id: authorization.segment_id.clone(),
            open_token: authorization.open_token.clone(),
            writer_generation: authorization.writer_generation,
            relative_path: authorization.relative_path.clone(),
            first_sample_host_time: 42_000,
            first_sample_frame_count: 960,
            observed_byte_length,
        })
        .unwrap();
    store
        .confirm_recording(prepared.session_id.clone())
        .unwrap();
    store
        .interrupt_session(crate::InterruptSessionRequest {
            session_id: prepared.session_id,
            reason: crate::SessionInterruptionReason::CaptureFailed,
        })
        .unwrap();
    let recovered = store.recover_playable_sessions().unwrap().remove(0);
    let original = fs::read(&authorization.absolute_path).unwrap();

    let lease = store
        .lease_recovered_playback(
            &recovered.session_id,
            &recovered.source_id,
            &recovered.track_id,
            &recovered.segment_id,
        )
        .unwrap();
    assert!(matches!(
        store.lease_recovered_playback(
            &recovered.session_id,
            "wrong-source",
            &recovered.track_id,
            &recovered.segment_id,
        ),
        Err(StoreError::InvalidState(
            "recovered playback evidence is unavailable"
        ))
    ));
    let managed_path = authorization.absolute_path;
    fs::remove_file(&managed_path).unwrap();
    write_recoverable_caf(&managed_path, 96_000);

    let mut leased_file = lease.file.try_clone().unwrap();
    let mut leased_bytes = Vec::new();
    leased_file.read_to_end(&mut leased_bytes).unwrap();
    assert_eq!(leased_bytes, original);
    assert_eq!(lease.byte_length(), original.len() as u64);
    assert_eq!(lease.digest_sha256(), recovered.digest_sha256);
}

#[test]
fn store_open_recovers_only_empty_private_playback_placeholders() {
    let temp = TempDir::new().unwrap();
    let managed_root = temp.path().join("Open Scribe");
    drop(SessionStore::open(&managed_root).unwrap());
    let stale = managed_root.join(format!(
        "{PLAYBACK_SNAPSHOT_PREFIX}{}{PLAYBACK_SNAPSHOT_SUFFIX}",
        Uuid::now_v7()
    ));
    File::create(&stale).unwrap();

    drop(SessionStore::open(&managed_root).unwrap());

    assert!(!stale.exists());
    let quarantine = fs::read_dir(&managed_root)
        .unwrap()
        .find_map(|entry| {
            let entry = entry.unwrap();
            entry
                .file_name()
                .to_string_lossy()
                .starts_with(PLAYBACK_QUARANTINE_PREFIX)
                .then_some(entry.path())
        })
        .unwrap();
    assert_eq!(fs::metadata(&quarantine).unwrap().len(), 0);
    let invalid = managed_root.join(format!(
        "{PLAYBACK_SNAPSHOT_PREFIX}{}{PLAYBACK_SNAPSHOT_SUFFIX}",
        Uuid::now_v7()
    ));
    fs::write(&invalid, b"not an empty placeholder").unwrap();
    assert!(SessionStore::open(&managed_root).is_err());
    assert_eq!(fs::read(&invalid).unwrap(), b"not an empty placeholder");

    fs::remove_file(&invalid).unwrap();
    fs::remove_file(&quarantine).unwrap();
    let raced = managed_root.join(format!(
        "{PLAYBACK_SNAPSHOT_PREFIX}{}{PLAYBACK_SNAPSHOT_SUFFIX}",
        Uuid::now_v7()
    ));
    File::create(&raced).unwrap();
    let replacement = b"replacement must be preserved";
    assert!(
        cleanup_stale_playback_snapshot_placeholders_with_hook(&managed_root, |path| {
            fs::remove_file(path).unwrap();
            fs::write(path, replacement).unwrap();
        })
        .is_err()
    );
    assert_eq!(fs::read(&raced).unwrap(), replacement);
    assert!(fs::read_dir(&managed_root).unwrap().all(|entry| {
        !entry
            .unwrap()
            .file_name()
            .to_string_lossy()
            .starts_with(PLAYBACK_QUARANTINE_PREFIX)
    }));

    fs::remove_file(&raced).unwrap();
    let symlink_target = managed_root.join("preserved-target");
    fs::write(&symlink_target, b"preserved").unwrap();
    let linked = managed_root.join(format!(
        "{PLAYBACK_SNAPSHOT_PREFIX}{}{PLAYBACK_SNAPSHOT_SUFFIX}",
        Uuid::now_v7()
    ));
    symlink(&symlink_target, &linked).unwrap();
    assert!(SessionStore::open(&managed_root).is_err());
    assert!(
        fs::symlink_metadata(&linked)
            .unwrap()
            .file_type()
            .is_symlink()
    );
    assert_eq!(fs::read(&symlink_target).unwrap(), b"preserved");
}

#[test]
fn import_rejects_symlinks_and_malformed_media_without_library_rows() {
    let temp = TempDir::new().unwrap();
    let source_path = temp.path().join("audio.caf");
    fs::write(&source_path, b"not audio").unwrap();
    let symlink_path = temp.path().join("linked.caf");
    symlink(&source_path, &symlink_path).unwrap();
    let oversized_path = temp.path().join("oversized.caf");
    File::create(&oversized_path)
        .unwrap()
        .set_len(MAX_IMPORT_BYTES + 1)
        .unwrap();
    let overlong_path = temp.path().join("overlong.caf");
    write_sparse_recoverable_caf(&overlong_path, MAX_IMPORT_SAMPLES + 1);
    let mut store = SessionStore::open(temp.path().join("Open Scribe")).unwrap();

    for path in [source_path, symlink_path, oversized_path, overlong_path] {
        assert!(
            store
                .import_recoverable_caf(ImportMediaRequest {
                    title: "Rejected".to_owned(),
                    source_path: path,
                })
                .is_err()
        );
    }
    assert_eq!(
        store
            .connection
            .query_row("SELECT COUNT(*) FROM sessions", [], |row| row
                .get::<_, i64>(0))
            .unwrap(),
        0
    );
    assert_eq!(
        fs::read_dir(temp.path().join("Open Scribe").join("Sessions"))
            .unwrap()
            .count(),
        0
    );
}

#[test]
fn durable_import_journal_replays_an_uncommitted_library_projection() {
    let temp = TempDir::new().unwrap();
    let source_path = temp.path().join("interrupted-import.caf");
    write_recoverable_caf(&source_path, 1_920);
    let managed_root = temp.path().join("Open Scribe");
    let mut store = SessionStore::open(&managed_root).unwrap();
    let evidence = store
        .import_recoverable_caf(ImportMediaRequest {
            title: "Interrupted import".to_owned(),
            source_path,
        })
        .unwrap();
    let session_id = evidence.session_id.0.clone();
    let track_id = Path::new(&evidence.relative_path)
        .components()
        .nth(1)
        .and_then(|component| match component {
            std::path::Component::Normal(value) => value.to_str(),
            _ => None,
        })
        .unwrap()
        .to_owned();
    let track_directory = store
        .managed_import_track_directory(&session_id, &track_id)
        .unwrap();
    fd_fs::renameat_with(
        &track_directory,
        OsStr::new("000000-import.caf"),
        &track_directory,
        OsStr::new(".importing.caf"),
        fd_fs::RenameFlags::NOREPLACE,
    )
    .unwrap();
    fd_fs::fsync(&track_directory).unwrap();
    drop(track_directory);

    let transaction = store.connection.transaction().unwrap();
    transaction
        .execute("DELETE FROM imports WHERE session_id = ?1", [&session_id])
        .unwrap();
    transaction
        .execute("DELETE FROM segments WHERE session_id = ?1", [&session_id])
        .unwrap();
    transaction
        .execute("DELETE FROM tracks WHERE session_id = ?1", [&session_id])
        .unwrap();
    transaction
        .execute("DELETE FROM sources WHERE session_id = ?1", [&session_id])
        .unwrap();
    transaction
        .execute(
            "DELETE FROM session_events
             WHERE session_id = ?1 AND event_kind = 'media_imported'",
            [&session_id],
        )
        .unwrap();
    transaction
        .execute(
            "UPDATE sessions SET lifecycle = 'preparing' WHERE id = ?1",
            [&session_id],
        )
        .unwrap();
    transaction.commit().unwrap();
    drop(store);

    let mut reopened = SessionStore::open(&managed_root).unwrap();
    let findings = reopened.recover_preparations().unwrap();
    assert_eq!(findings.len(), 1);
    assert_eq!(
        findings[0].disposition,
        RecoveryDisposition::ImportProjectionRepaired
    );
    let snapshot = reopened.runtime_library_snapshot().unwrap();
    assert!(snapshot.current_session.is_none());
    assert_eq!(snapshot.saved_sessions.len(), 1);
    assert_eq!(snapshot.saved_sessions[0].session_id.0, session_id);
}

/// A 48 kHz 16-bit stereo PCM CAF, as AVAudioFile writes one, whose left and
/// right samples are `left` and `-left`.
fn stereo_pcm_caf(path: &Path, frames: u64, left: i16) {
    let mut bytes = Vec::new();
    bytes.extend_from_slice(CAF_HEADER);
    bytes.extend_from_slice(b"desc");
    bytes.extend_from_slice(&32_i64.to_be_bytes());
    bytes.extend_from_slice(&48_000_f64.to_bits().to_be_bytes());
    bytes.extend_from_slice(b"lpcm");
    for value in [2_u32, 4, 1, 2, 16] {
        bytes.extend_from_slice(&value.to_be_bytes());
    }
    bytes.extend_from_slice(b"data");
    bytes.extend_from_slice(&(4 + frames as i64 * 4).to_be_bytes());
    bytes.extend_from_slice(&0_u32.to_be_bytes());
    for _ in 0..frames {
        bytes.extend_from_slice(&left.to_le_bytes());
        bytes.extend_from_slice(&(-left).to_le_bytes());
    }
    fs::write(path, &bytes).unwrap();
}

#[test]
fn compressed_import_transcribes_only_through_a_matching_decoded_companion() {
    let temp = TempDir::new().unwrap();
    let source = temp.path().join("source.m4a");
    let metadata = compressed_source(&source);
    let root = temp.path().join("Library");
    let mut store = SessionStore::open(&root).unwrap();
    let evidence = store
        .import_compressed_m4a(
            ImportMediaRequest {
                title: "Stereo memo".to_owned(),
                source_path: source,
            },
            metadata,
        )
        .unwrap();
    let session = evidence.session_id.clone();
    let tracks = store.transcription_tracks(&session).unwrap();
    assert_eq!(tracks.len(), 1);
    let input = store.transcription_input(&session, &tracks[0]).unwrap();
    assert!(input.compressed);
    assert_eq!((input.channels, input.spans[0].frames), (2, 48_000));
    assert!(matches!(
        store.open_transcription_input(&input),
        Err(StoreError::InvalidState(_))
    ));

    let decoded = temp.path().join("decoded.caf");
    stereo_pcm_caf(&decoded, 48_000, 1_234);
    let reader = store
        .open_decoded_transcription_input(&input, &decoded)
        .unwrap();
    assert_eq!(
        reader.read_frames(0, 47_999, 48_000).unwrap(),
        [1_234, -1_234]
    );

    let short = temp.path().join("short.caf");
    stereo_pcm_caf(&short, 47_999, 1);
    assert!(matches!(
        store.open_decoded_transcription_input(&input, &short),
        Err(StoreError::InvalidRequest(_))
    ));
    let link = temp.path().join("link.caf");
    symlink(&decoded, &link).unwrap();
    assert!(
        store
            .open_decoded_transcription_input(&input, &link)
            .is_err()
    );

    // The original is rehashed: altered managed bytes refuse the companion.
    let managed = root
        .join("Sessions")
        .join(&session.0)
        .join(&evidence.relative_path);
    let file = OpenOptions::new().write(true).open(&managed).unwrap();
    file.write_all_at(&[0], fs::metadata(&managed).unwrap().len() - 1)
        .unwrap();
    drop(file);
    assert!(
        store
            .open_decoded_transcription_input(&input, &decoded)
            .is_err()
    );
}
