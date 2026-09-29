//! Journal replacements a live append in this process still owns. Opening a
//! store adopts or discards replacement files that a terminated process left
//! behind; a replacement an append here is still writing is not stale, even
//! when another store (a playback lease, the launch scan) opens meanwhile.
use std::collections::BTreeSet;
use std::sync::{Mutex, PoisonError};

static LIVE: Mutex<BTreeSet<String>> = Mutex::new(BTreeSet::new());

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
