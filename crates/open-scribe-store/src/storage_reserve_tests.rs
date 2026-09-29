use super::*;
use std::os::unix::fs::MetadataExt;
use tempfile::TempDir;

#[test]
#[ignore = "requires OPEN_SCRIBE_RESERVE_TEST_VOLUME on a dedicated disposable volume"]
fn m1_real_full_volume_can_release_reserve_and_journal_critical_storage() {
    let volume =
        std::env::var_os("OPEN_SCRIBE_RESERVE_TEST_VOLUME").expect("dedicated volume required");
    let volume = PathBuf::from(volume).canonicalize().unwrap();
    assert_ne!(
        fs::metadata(&volume).unwrap().dev(),
        fs::metadata(std::env::current_dir().unwrap())
            .unwrap()
            .dev(),
        "refuse filling the host filesystem"
    );
    let root = tempfile::tempdir_in(volume).unwrap();
    let mut store = SessionStore::open(root.path()).unwrap();
    let (session, sources) = recording_pair(&mut store);
    let filler_path = root.path().join("owned-filler");
    let mut filler = OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(&filler_path)
        .unwrap();
    let block = [0x5a; 1024 * 1024];
    let mut exhausted = false;
    for _ in 0..2048 {
        if let Err(error) = filler.write_all(&block) {
            assert_eq!(error.raw_os_error(), Some(28));
            exhausted = true;
            break;
        }
    }
    drop(filler);
    assert!(exhausted, "dedicated volume must reach ENOSPC within 2 GiB");
    let mut media = OpenOptions::new()
        .append(true)
        .open(&sources[0].absolute_path)
        .unwrap();
    let mut media_exhausted = false;
    for _ in 0..16 {
        if let Err(error) = media.write_all(&block).and_then(|()| media.sync_all()) {
            assert_eq!(error.raw_os_error(), Some(28));
            media_exhausted = true;
            break;
        }
    }
    assert!(media_exhausted, "real source write must fail");
    drop(media);
    let result = store.recorder_action(
        session,
        RecorderAction::ObserveStorage { available_bytes: 0 },
    );
    if let Err(error) = &result {
        eprintln!("critical observation: {error:?}");
        eprintln!(
            "direct reserve release: {:?}",
            store.release_storage_reserve()
        );
    }
    // Cleanup only the test's filler after capturing the original result.
    fs::remove_file(filler_path).unwrap();
    let detail = result.expect("must journal before any filler space is returned");
    assert_eq!(detail.storage_level, "critical");
    assert!(
        detail
            .events
            .iter()
            .any(|event| event.kind == "storage_observed")
    );
}

#[test]
fn m1_reserve_refuses_foreign_files_symlinks_and_hardlinks_without_changing_them() {
    for link in ["foreign", "symlink", "hardlink"] {
        let temp = TempDir::new().unwrap();
        let mut store = SessionStore::open(temp.path()).unwrap();
        let foreign = temp.path().join("unowned");
        let reserve = temp.path().join(".capture-journal-reserve-v1");
        fs::write(&foreign, b"user owned bytes").unwrap();
        match link {
            "symlink" => std::os::unix::fs::symlink(&foreign, &reserve).unwrap(),
            "hardlink" => fs::hard_link(&foreign, &reserve).unwrap(),
            _ => {
                fs::copy(&foreign, &reserve).unwrap();
            }
        }
        assert!(
            store
                .prepare_session(PrepareSessionRequest {
                    title: "Unsafe reserve".to_owned(),
                    origin: SessionOrigin::Capture,
                })
                .is_err()
        );
        assert!(store.release_storage_reserve().is_err());
        assert_eq!(fs::read(&foreign).unwrap(), b"user owned bytes");
        assert_eq!(fs::read(&reserve).unwrap(), b"user owned bytes");
    }
}

#[test]
fn m1_capture_reserves_real_blocks_and_releases_them_before_critical_journaling() {
    let temp = TempDir::new().unwrap();
    let mut store = SessionStore::open(temp.path()).unwrap();
    let reserve = temp.path().join(".capture-journal-reserve-v1");
    assert!(
        !reserve.exists(),
        "library reads must not allocate capture space"
    );
    let session = store
        .prepare_session(PrepareSessionRequest {
            title: "Emergency journal space".to_owned(),
            origin: SessionOrigin::Capture,
        })
        .unwrap()
        .session_id;
    let allocated = fs::metadata(&reserve).expect("capture must provision emergency space");
    assert!(
        allocated.blocks() * 512 >= 16 * 1024 * 1024,
        "a sparse file is not a reserve"
    );
    let detail = store
        .recorder_action(
            session.clone(),
            RecorderAction::ObserveStorage { available_bytes: 0 },
        )
        .unwrap();
    assert_eq!(detail.storage_level, "critical");
    assert!(
        detail
            .events
            .iter()
            .any(|event| event.kind == "storage_observed")
    );
    assert!(
        !reserve.exists(),
        "release must unlink the owned allocation"
    );
    store.release_storage_reserve().unwrap();
    drop(store);
    let mut store = SessionStore::open(temp.path()).unwrap();
    assert!(
        !reserve.exists(),
        "launch recovery must not spend the released emergency space"
    );
    assert_eq!(
        store.recorder_detail(&session).unwrap().storage_level,
        "critical"
    );
    store
        .prepare_session(PrepareSessionRequest {
            title: "Next explicit capture".to_owned(),
            origin: SessionOrigin::Capture,
        })
        .unwrap();
    assert!(fs::metadata(&reserve).unwrap().blocks() * 512 >= 16 * 1024 * 1024);
}
