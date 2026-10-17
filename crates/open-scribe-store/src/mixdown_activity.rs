//! A session-scoped activity lease, separate from the short library writer.
//! Its stable, empty lock file is not evidence of a live worker. Descriptor
//! lifetime (including process death) releases admission without a DB repair.
use super::{SessionId, StoreError};
use std::fs::{File, OpenOptions};
use std::os::unix::fs::{MetadataExt, OpenOptionsExt};
use std::path::Path;

#[derive(Debug)]
pub struct MixdownWork {
    _file: File,
    session_id: SessionId,
}

impl MixdownWork {
    pub(super) fn try_acquire(root: &Path, session: &SessionId) -> Result<Self, StoreError> {
        if uuid::Uuid::parse_str(&session.0).is_err() {
            return Err(StoreError::InvalidRequest("session identity is invalid"));
        }
        // Keep the stable inode outside both the journal replacement and the
        // exports/Trash inventory. Never unlink or replace a live lease file.
        let path = root
            .canonicalize()?
            .join(format!(".mixdown-{}.lock-v1", session.0));
        let file = OpenOptions::new()
            .read(true)
            .write(true)
            .create(true)
            .truncate(false)
            .mode(0o600)
            .custom_flags(rustix::fs::OFlags::NOFOLLOW.bits() as i32)
            .open(path)?;
        let metadata = file.metadata()?;
        if !metadata.is_file() || metadata.nlink() != 1 || metadata.len() != 0 {
            return Err(StoreError::InvalidState("unsafe mixdown activity lock"));
        }
        match rustix::fs::flock(&file, rustix::fs::FlockOperation::NonBlockingLockExclusive) {
            Ok(()) => Ok(Self {
                _file: file,
                session_id: session.clone(),
            }),
            Err(rustix::io::Errno::WOULDBLOCK) => Err(StoreError::InvalidState(
                "stereo mix processing must finish before deletion or another mixdown",
            )),
            Err(error) => Err(std::io::Error::from(error).into()),
        }
    }

    pub fn session_id(&self) -> &SessionId {
        &self.session_id
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::process::{Child, Command, Stdio};
    use std::sync::Arc;
    use std::time::Duration;
    use tempfile::TempDir;

    #[test]
    fn activity_is_session_scoped_and_releases_with_the_last_owner() {
        let temp = TempDir::new().unwrap();
        let session = SessionId(uuid::Uuid::now_v7().to_string());
        let work = Arc::new(MixdownWork::try_acquire(temp.path(), &session).unwrap());
        let retained = Arc::clone(&work);
        assert!(MixdownWork::try_acquire(temp.path(), &session).is_err());
        let other = SessionId(uuid::Uuid::now_v7().to_string());
        let _independent = MixdownWork::try_acquire(temp.path(), &other).unwrap();
        // Native encoding must not own capture's library writer admission.
        let _writer = crate::writer::WriterGuard::acquire(temp.path()).unwrap();
        drop(work);
        assert!(MixdownWork::try_acquire(temp.path(), &session).is_err());
        drop(retained);
        assert!(MixdownWork::try_acquire(temp.path(), &session).is_ok());
    }

    #[test]
    fn activity_refuses_redirected_shared_or_nonempty_lock_files() {
        use std::os::unix::fs::symlink;
        let temp = TempDir::new().unwrap();
        for kind in ["symlink", "hardlink", "nonempty"] {
            let session = SessionId(uuid::Uuid::now_v7().to_string());
            let path = temp.path().join(format!(".mixdown-{}.lock-v1", session.0));
            let target = temp.path().join(kind);
            std::fs::write(&target, []).unwrap();
            match kind {
                "symlink" => symlink(&target, &path).unwrap(),
                "hardlink" => std::fs::hard_link(&target, &path).unwrap(),
                _ => std::fs::write(&path, b"foreign").unwrap(),
            }
            assert!(MixdownWork::try_acquire(temp.path(), &session).is_err());
            assert_eq!(std::fs::read(target).unwrap(), Vec::<u8>::new());
        }
    }

    struct ChildLease(Child);
    impl Drop for ChildLease {
        fn drop(&mut self) {
            let _ = self.0.kill();
            let _ = self.0.wait();
        }
    }

    #[test]
    fn process_death_releases_activity_without_a_database_repair() {
        let temp = TempDir::new().unwrap();
        let session = SessionId(uuid::Uuid::now_v7().to_string());
        let mut child = ChildLease(
            Command::new(std::env::current_exe().unwrap())
                .args([
                    "--exact",
                    "mixdown_activity::tests::activity_subprocess_holder",
                ])
                .env("OPEN_SCRIBE_MIXDOWN_LEASE_HELPER_ROOT", temp.path())
                .env("OPEN_SCRIBE_MIXDOWN_LEASE_HELPER_SESSION", &session.0)
                .stdout(Stdio::null())
                .stderr(Stdio::null())
                .spawn()
                .unwrap(),
        );
        for _ in 0..100 {
            if temp.path().join("ready").exists() {
                break;
            }
            assert!(child.0.try_wait().unwrap().is_none());
            std::thread::sleep(Duration::from_millis(50));
        }
        assert!(temp.path().join("ready").exists());
        assert!(matches!(
            MixdownWork::try_acquire(temp.path(), &session),
            Err(StoreError::InvalidState(_))
        ));
        child.0.kill().unwrap();
        assert!(!child.0.wait().unwrap().success());
        assert!(MixdownWork::try_acquire(temp.path(), &session).is_ok());
    }

    #[test]
    fn activity_subprocess_holder() {
        let Ok(root) = std::env::var("OPEN_SCRIBE_MIXDOWN_LEASE_HELPER_ROOT") else {
            return;
        };
        let session = SessionId(std::env::var("OPEN_SCRIBE_MIXDOWN_LEASE_HELPER_SESSION").unwrap());
        let _work = MixdownWork::try_acquire(Path::new(&root), &session).unwrap();
        std::fs::write(Path::new(&root).join("ready"), []).unwrap();
        // Bounded even if the parent fails before its RAII child cleanup.
        std::thread::sleep(Duration::from_secs(10));
    }
}
