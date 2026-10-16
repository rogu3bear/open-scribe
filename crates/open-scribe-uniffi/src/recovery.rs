//! Capture-safety results are published before optional derived maintenance.
use super::*;
#[derive(Clone, Debug, uniffi::Record)]
pub struct NativeMediaRecovery {
    pub capture_safety_complete: bool,
    pub playable: Vec<NativeRecoveredPlayableSession>,
    pub findings: Vec<NativeRecoveryFinding>,
}
#[derive(Clone, Debug, uniffi::Record)]
pub struct NativeRecoveryFinding {
    pub session_id: String,
    pub disposition: NativeRecoveryDisposition,
}
#[derive(Clone, Copy, Debug, Eq, PartialEq, uniffi::Enum)]
pub enum NativeRecoveryDisposition {
    Prepared,
    ProjectionRepaired,
    MediaOpenPrepared,
    MediaOpenProjectionRepaired,
    MediaOpenAwaitingReceipt,
    FirstSamplePrepared,
    FirstSampleProjectionRepaired,
    SegmentSealedPrepared,
    SegmentSealProjectionRepaired,
    ImportedMediaReady,
    ImportProjectionRepaired,
    ImportFailed,
    SourceFailedRecording,
    SourceFailureProjectionRepaired,
    InterruptedPrepared,
    InterruptedMediaOpen,
    InterruptedFirstSample,
    InterruptedSegmentSealed,
    InterruptionProjectionRepaired,
    PlayableMediaRecovered,
    TranscriptRunOrphaned,
    MissingMediaFile,
    InvalidMediaFile,
    MissingDirectory,
    MissingJournal,
    TruncatedJournal,
    MalformedJournal,
    IntegrityMismatch,
    UnsupportedJournalVersion,
    OrphanDirectory,
}
impl From<open_scribe_core::RecoveryDisposition> for NativeRecoveryDisposition {
    fn from(value: open_scribe_core::RecoveryDisposition) -> Self {
        use open_scribe_core::RecoveryDisposition as R;
        match value {
            R::Prepared => Self::Prepared,
            R::ProjectionRepaired => Self::ProjectionRepaired,
            R::MediaOpenPrepared => Self::MediaOpenPrepared,
            R::MediaOpenProjectionRepaired => Self::MediaOpenProjectionRepaired,
            R::MediaOpenAwaitingReceipt => Self::MediaOpenAwaitingReceipt,
            R::FirstSamplePrepared => Self::FirstSamplePrepared,
            R::FirstSampleProjectionRepaired => Self::FirstSampleProjectionRepaired,
            R::SegmentSealedPrepared => Self::SegmentSealedPrepared,
            R::SegmentSealProjectionRepaired => Self::SegmentSealProjectionRepaired,
            R::ImportedMediaReady => Self::ImportedMediaReady,
            R::ImportProjectionRepaired => Self::ImportProjectionRepaired,
            R::ImportFailed => Self::ImportFailed,
            R::SourceFailedRecording => Self::SourceFailedRecording,
            R::SourceFailureProjectionRepaired => Self::SourceFailureProjectionRepaired,
            R::InterruptedPrepared => Self::InterruptedPrepared,
            R::InterruptedMediaOpen => Self::InterruptedMediaOpen,
            R::InterruptedFirstSample => Self::InterruptedFirstSample,
            R::InterruptedSegmentSealed => Self::InterruptedSegmentSealed,
            R::InterruptionProjectionRepaired => Self::InterruptionProjectionRepaired,
            R::PlayableMediaRecovered => Self::PlayableMediaRecovered,
            R::TranscriptRunOrphaned => Self::TranscriptRunOrphaned,
            R::MissingMediaFile => Self::MissingMediaFile,
            R::InvalidMediaFile => Self::InvalidMediaFile,
            R::MissingDirectory => Self::MissingDirectory,
            R::MissingJournal => Self::MissingJournal,
            R::TruncatedJournal => Self::TruncatedJournal,
            R::MalformedJournal => Self::MalformedJournal,
            R::IntegrityMismatch => Self::IntegrityMismatch,
            R::UnsupportedJournalVersion => Self::UnsupportedJournalVersion,
            R::OrphanDirectory => Self::OrphanDirectory,
        }
    }
}
#[uniffi::export]
impl NativeRecordingPreparation {
    pub fn recover_capture_safety(&self) -> Result<NativeMediaRecovery, NativeStorageError> {
        let result = self
            .controller()?
            .recover_capture_safety()
            .map_err(map_storage_error)?;
        Ok(NativeMediaRecovery {
            capture_safety_complete: true,
            playable: result.playable.into_iter().map(map_recovered).collect(),
            findings: result
                .findings
                .into_iter()
                .map(|finding| NativeRecoveryFinding {
                    session_id: finding.session_id.0,
                    disposition: finding.disposition.into(),
                })
                .collect(),
        })
    }
}
pub(super) fn map_recovered(
    recovered: open_scribe_core::RecoveredPlayableSession,
) -> NativeRecoveredPlayableSession {
    NativeRecoveredPlayableSession {
        session_id: recovered.session_id.0,
        source_id: recovered.source_id,
        track_id: recovered.track_id,
        source_kind: map_native_media_source_kind(recovered.source_kind),
        source_display_name: recovered.source_display_name,
        segment_id: recovered.segment_id,
        relative_path: recovered.relative_path,
        sample_count: recovered.sample_count,
        duration_nanoseconds: recovered.duration_nanoseconds,
        byte_length: recovered.byte_length,
        digest_sha256: recovered.digest_sha256,
        media_preserved: recovered.media_preserved,
        ready_for_review: recovered.ready_for_review,
        recording_started: recovered.recording_started,
        last_journal_sequence: recovered.last_journal_sequence,
    }
}
