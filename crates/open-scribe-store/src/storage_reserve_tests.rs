use super::*;
use std::os::unix::fs::MetadataExt;
use tempfile::TempDir;

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
    assert!(fs::metadata(&reserve).unwrap().blocks() * 512 < 4096 * 2);
    let released_length = fs::metadata(&reserve).unwrap().len();
    drop(store);
    let mut store = SessionStore::open(temp.path()).unwrap();
    assert_eq!(
        fs::metadata(&reserve).unwrap().len(),
        released_length,
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
