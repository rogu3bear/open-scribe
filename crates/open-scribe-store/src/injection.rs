//! Failure points tests use to interrupt durable work between steps.

use super::*;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) enum FailurePoint {
    DatabaseIntent,
    SessionDirectory,
    JournalSync,
    DatabaseProjection,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) enum MediaFailurePoint {
    AuthorizationJournalSync,
    AuthorizationDatabaseProjection,
    ReceiptJournalSync,
    ReceiptDatabaseProjection,
    FirstSampleJournalSync,
    FirstSampleDatabaseProjection,
    SegmentSealJournalSync,
    SegmentSealDatabaseProjection,
}

#[derive(Clone, Copy, Eq, PartialEq)]
pub(crate) enum JournalReplacementFailurePoint {
    TemporaryWrite,
    TemporarySync,
    Rename,
    DirectorySync,
    #[cfg(test)]
    PartialWriteNoSpace,
    #[cfg(test)]
    AfterRenameNoSpace,
}

pub(crate) fn interrupt_journal_replace_if(
    actual: Option<JournalReplacementFailurePoint>,
    expected: JournalReplacementFailurePoint,
) -> Result<(), StoreError> {
    if actual == Some(expected) {
        Err(StoreError::InjectedInterruption)
    } else {
        Ok(())
    }
}

pub(crate) fn interrupt_if(
    selected: Option<FailurePoint>,
    current: FailurePoint,
) -> Result<(), StoreError> {
    if selected == Some(current) {
        Err(StoreError::InjectedInterruption)
    } else {
        Ok(())
    }
}

pub(crate) fn interrupt_media_if(
    selected: Option<MediaFailurePoint>,
    current: MediaFailurePoint,
) -> Result<(), StoreError> {
    if selected == Some(current) {
        Err(StoreError::InjectedInterruption)
    } else {
        Ok(())
    }
}
