//! Journal replacements a live append in this process still owns. Opening a
//! store adopts or discards replacement files that a terminated process left
//! behind; a replacement an append here is still writing is not stale, even
//! when another store (a playback lease, the launch scan) opens meanwhile.
use std::collections::BTreeSet;
use std::fs::{File, OpenOptions};
use std::io;
use std::path::Path;
use std::sync::{Mutex, PoisonError};
use std::time::Duration;

static LIVE: Mutex<BTreeSet<String>> = Mutex::new(BTreeSet::new());

/// APFS can transiently reject allocation after an emergency reserve has
/// been unlinked, closed, and synced. Retry only create-new, for at most
/// 1 s of waiting. No journal bytes, rename, or projection are replayed.
/// Persistent ENOSPC still fails; callers may fall back to in-place append.
pub(super) fn create_temporary(path: &Path) -> io::Result<File> {
    retry_create(
        || OpenOptions::new().create_new(true).write(true).open(path),
        || std::thread::sleep(Duration::from_millis(20)),
    )
}

fn retry_create<T>(
    mut create: impl FnMut() -> io::Result<T>,
    mut wait: impl FnMut(),
) -> io::Result<T> {
    for _ in 0..50 {
        match create() {
            Err(error) if error.raw_os_error() == Some(rustix::io::Errno::NOSPC.raw_os_error()) => {
                wait();
            }
            result => return result,
        }
    }
    create()
}

/// Held by an append from before its replacement file exists until it has
/// been renamed over the journal or removed.
pub(super) struct LiveReplacement(String);

impl LiveReplacement {
    pub(super) fn begin(file_name: String) -> Self {
        LIVE.lock()
            .unwrap_or_else(PoisonError::into_inner)
            .insert(file_name.clone());
        Self(file_name)
    }
}

impl Drop for LiveReplacement {
    fn drop(&mut self) {
        LIVE.lock()
            .unwrap_or_else(PoisonError::into_inner)
            .remove(&self.0);
    }
}

/// True while an append in this process owns the named replacement file.
pub(super) fn is_live(file_name: &str) -> bool {
    LIVE.lock()
        .unwrap_or_else(PoisonError::into_inner)
        .contains(file_name)
}

/// A stale replacement that another sweep already adopted or removed needs
/// nothing more.
pub(super) fn ignore_missing(result: std::io::Result<()>) -> std::io::Result<()> {
    match result {
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(()),
        other => other,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn transient_enospc_retries_only_until_creation_succeeds() {
        let mut attempts = 0;
        let mut waits = 0;
        let result = retry_create(
            || {
                attempts += 1;
                if attempts < 3 {
                    Err(io::Error::from_raw_os_error(28))
                } else {
                    Ok(7)
                }
            },
            || waits += 1,
        );
        assert_eq!(result.unwrap(), 7);
        assert_eq!((attempts, waits), (3, 2));
    }

    #[test]
    fn persistent_exhaustion_is_bounded_and_stays_an_error() {
        let mut attempts = 0;
        let mut waits = 0;
        let result: io::Result<()> = retry_create(
            || {
                attempts += 1;
                Err(io::Error::from_raw_os_error(28))
            },
            || waits += 1,
        );
        assert_eq!(result.unwrap_err().raw_os_error(), Some(28));
        assert_eq!((attempts, waits), (51, 50));
    }

    #[test]
    fn unrelated_errors_and_existing_files_are_never_retried_or_overwritten() {
        for code in [13, 17, 5] {
            let result: io::Result<()> = retry_create(
                || Err(io::Error::from_raw_os_error(code)),
                || panic!("must not retry another error"),
            );
            assert_eq!(result.unwrap_err().raw_os_error(), Some(code));
        }
        let root = tempfile::tempdir().unwrap();
        let path = root.path().join("owned-by-someone-else");
        std::fs::write(&path, b"preserve").unwrap();
        assert_eq!(
            create_temporary(&path).unwrap_err().kind(),
            io::ErrorKind::AlreadyExists
        );
        assert_eq!(std::fs::read(path).unwrap(), b"preserve");
    }
}
