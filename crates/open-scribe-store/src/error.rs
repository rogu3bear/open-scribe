//! The store's one error type.

use super::*;

#[derive(Debug)]
pub enum StoreError {
    InvalidManagedRoot(&'static str),
    InvalidRequest(&'static str),
    DecodedAudio(DecodedAudioError),
    ImportSizeLimit,
    ImportDurationLimit,
    InvalidState(&'static str),
    IntegrityMismatch(&'static str),
    Io(std::io::Error),
    Sqlite(rusqlite::Error),
    Json(serde_json::Error),
    JournalRecordTooLarge,
    InjectedInterruption,
}

impl fmt::Display for StoreError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::InvalidManagedRoot(reason) => write!(formatter, "invalid managed root: {reason}"),
            Self::InvalidRequest(reason) => write!(formatter, "invalid request: {reason}"),
            Self::DecodedAudio(reason) => write!(formatter, "decoded audio rejected: {reason}"),
            Self::ImportSizeLimit => write!(formatter, "import source exceeds the size limit"),
            Self::ImportDurationLimit => {
                write!(formatter, "import source exceeds the duration limit")
            }
            Self::InvalidState(reason) => write!(formatter, "invalid state: {reason}"),
            Self::IntegrityMismatch(reason) => write!(formatter, "integrity mismatch: {reason}"),
            Self::Io(error) => write!(formatter, "storage I/O failed: {error}"),
            Self::Sqlite(error) => write!(formatter, "SQLite operation failed: {error}"),
            Self::Json(error) => write!(formatter, "journal encoding failed: {error}"),
            Self::JournalRecordTooLarge => write!(formatter, "journal record exceeds size bound"),
            Self::InjectedInterruption => write!(formatter, "injected preparation interruption"),
        }
    }
}

impl std::error::Error for StoreError {}

impl From<std::io::Error> for StoreError {
    fn from(error: std::io::Error) -> Self {
        Self::Io(error)
    }
}

impl From<rusqlite::Error> for StoreError {
    fn from(error: rusqlite::Error) -> Self {
        Self::Sqlite(error)
    }
}

impl From<serde_json::Error> for StoreError {
    fn from(error: serde_json::Error) -> Self {
        Self::Json(error)
    }
}

/// Maps a query that found no row to `InvalidState(missing)` and keeps every
/// other SQLite error.
pub(crate) fn missing_row(missing: &'static str) -> impl FnOnce(rusqlite::Error) -> StoreError {
    move |error| match error {
        rusqlite::Error::QueryReturnedNoRows => StoreError::InvalidState(missing),
        other => StoreError::Sqlite(other),
    }
}
