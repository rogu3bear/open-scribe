//! Coarse Swift/Rust control boundary for native state and preparation.
//!
//! Media bytes, sample buffers, frame-rate telemetry, and capture callbacks do
//! not cross this boundary. Preparation evidence never starts Recording.

use std::sync::{Arc, Mutex};

/// Non-media state used to prove the native Rust-to-Swift boundary.
#[derive(Clone, Debug, Eq, PartialEq, uniffi::Record)]
pub struct NativeStatus {
    pub product_name: String,
    pub core_version: String,
    pub persistence: String,
    pub capture: String,
    pub intelligence: String,
}

/// Returns the current M0 capability posture as one coarse query.
#[uniffi::export]
pub fn native_status() -> NativeStatus {
    let status = open_scribe_core::status_snapshot();

    NativeStatus {
        product_name: status.product_name.to_owned(),
        core_version: status.core_version.to_owned(),
        persistence: status.persistence.to_owned(),
        capture: status.capture.to_owned(),
        intelligence: status.intelligence.to_owned(),
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq, uniffi::Enum)]
pub enum NativeMediaSourceKind {
    Microphone,
    ApplicationAudio,
    SystemAudio,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq, uniffi::Enum)]
pub enum NativeSessionInterruptionReason {
    CaptureStartFailed,
    CaptureFailed,
    FirstSampleRejected,
    StopWithoutDurableSample,
    SegmentSealFailed,
    PermissionRevoked,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq, uniffi::Enum)]
pub enum NativeSourceFailureReason {
    CaptureFailed,
    PermissionRevoked,
}

#[derive(Clone, Debug, Eq, PartialEq, uniffi::Record)]
pub struct NativePreparedSession {
    pub session_id: String,
    pub schema_version: u32,
    pub journal_version: u32,
    pub last_journal_sequence: u64,
    pub journal_durable: bool,
    pub media_files_open: bool,
    pub recording_started: bool,
}

#[derive(Clone, Debug, Eq, PartialEq, uniffi::Record)]
pub struct NativeRecordingStartedEvidence {
    pub session_id: String,
    pub required_sources: Vec<NativeMediaSourceKind>,
    pub active_sources: Vec<NativeMediaSourceKind>,
    pub journal_durable: bool,
    pub media_files_open: bool,
    pub recording_started: bool,
    pub last_journal_sequence: u64,
}

#[derive(Clone, Debug, Eq, PartialEq, uniffi::Record)]
pub struct NativeMediaOpenAuthorization {
    pub session_id: String,
    pub source_id: String,
    pub track_id: String,
    pub segment_id: String,
    pub open_token: String,
    pub writer_generation: u64,
    pub relative_path: String,
    pub absolute_path: String,
    pub channels: u16,
    pub mapped_start_nanoseconds: i64,
}

#[derive(Clone, Debug, Eq, PartialEq, uniffi::Record)]
pub struct NativeMediaOpenReceipt {
    pub session_id: String,
    pub track_id: String,
    pub segment_id: String,
    pub open_token: String,
    pub writer_generation: u64,
    pub relative_path: String,
    pub channels: u16,
    pub initial_byte_length: u64,
}

#[derive(Clone, Debug, Eq, PartialEq, uniffi::Record)]
pub struct NativeMediaOpenEvidence {
    pub session_id: String,
    pub segment_id: String,
    pub journal_durable: bool,
    pub media_files_open: bool,
    pub recording_started: bool,
    pub last_journal_sequence: u64,
}

#[derive(Clone, Debug, Eq, PartialEq, uniffi::Record)]
pub struct NativeFirstSampleReceipt {
    pub session_id: String,
    pub track_id: String,
    pub segment_id: String,
    pub open_token: String,
    pub writer_generation: u64,
    pub relative_path: String,
    pub first_sample_host_time: u64,
    pub first_sample_frame_count: u64,
    pub observed_byte_length: u64,
}

#[derive(Clone, Debug, Eq, PartialEq, uniffi::Record)]
pub struct NativeFirstSampleEvidence {
    pub session_id: String,
    pub segment_id: String,
    pub first_sample_session_nanoseconds: i64,
    pub journal_durable: bool,
    pub media_files_open: bool,
    pub first_sample_durable: bool,
    pub recording_started: bool,
    pub last_journal_sequence: u64,
}

#[derive(Clone, Debug, Eq, PartialEq, uniffi::Record)]
pub struct NativeSealSegmentReceipt {
    pub session_id: String,
    pub track_id: String,
    pub segment_id: String,
    pub open_token: String,
    pub writer_generation: u64,
    pub relative_path: String,
    pub final_sample_host_time: u64,
    pub final_sample_count: u64,
    pub final_byte_length: u64,
}

#[derive(Clone, Debug, Eq, PartialEq, uniffi::Record)]
pub struct NativeSealedSegmentEvidence {
    pub session_id: String,
    pub segment_id: String,
    pub final_sample_count: u64,
    pub final_byte_length: u64,
    pub digest_sha256: String,
    pub segment_sealed: bool,
    pub recording_started: bool,
    pub last_journal_sequence: u64,
}

#[derive(Clone, Debug, Eq, PartialEq, uniffi::Record)]
pub struct NativeSessionInterruptionEvidence {
    pub session_id: String,
    pub reason: NativeSessionInterruptionReason,
    pub journal_durable: bool,
    pub session_interrupted: bool,
    pub recording_started: bool,
    pub last_journal_sequence: u64,
}

#[derive(Clone, Debug, Eq, PartialEq, uniffi::Record)]
pub struct NativeSourceFailureEvidence {
    pub session_id: String,
    pub source_kind: NativeMediaSourceKind,
    pub reason: NativeSourceFailureReason,
    pub journal_durable: bool,
    pub source_failed: bool,
    pub session_degraded: bool,
    pub session_interrupted: bool,
    pub recording_continues: bool,
    pub last_journal_sequence: u64,
}

#[derive(Clone, Debug, Eq, PartialEq, uniffi::Record)]
pub struct NativeRecoveredPlayableSession {
    pub session_id: String,
    pub source_id: String,
    pub track_id: String,
    pub source_kind: NativeMediaSourceKind,
    pub source_display_name: String,
    pub segment_id: String,
    pub relative_path: String,
    pub sample_count: u64,
    pub duration_nanoseconds: u64,
    pub byte_length: u64,
    pub digest_sha256: String,
    pub media_preserved: bool,
    pub ready_for_review: bool,
    pub recording_started: bool,
    pub last_journal_sequence: u64,
}

#[derive(Clone, Debug, Eq, PartialEq, uniffi::Record)]
pub struct NativeRuntimeSourceSnapshot {
    pub kind: NativeMediaSourceKind,
    pub display_name: String,
    pub lifecycle: String,
}

#[derive(Clone, Debug, Eq, PartialEq, uniffi::Record)]
pub struct NativeRuntimePlayableMediaSnapshot {
    pub source_display_name: String,
    pub availability: String,
    pub absolute_path: Option<String>,
    pub duration_nanoseconds: u64,
    pub sample_count: u64,
    pub byte_length: u64,
}

#[derive(Clone, Debug, Eq, PartialEq, uniffi::Record)]
pub struct NativeRuntimeSessionSnapshot {
    pub session_id: String,
    pub title: String,
    pub lifecycle: String,
    pub health: String,
    pub elapsed_seconds: u64,
    pub journal_durable: bool,
    pub media_files_open: bool,
    pub interruption_reason: Option<String>,
    pub recovered: bool,
    pub has_capture_timeline: bool,
    pub sources: Vec<NativeRuntimeSourceSnapshot>,
    pub playable_media: Option<NativeRuntimePlayableMediaSnapshot>,
}

#[derive(Clone, Debug, Eq, PartialEq, uniffi::Record)]
pub struct NativeRuntimeLibrarySnapshot {
    pub current_session: Option<NativeRuntimeSessionSnapshot>,
    pub saved_sessions: Vec<NativeRuntimeSessionSnapshot>,
}

#[derive(Clone, Debug, Eq, PartialEq, uniffi::Record)]
pub struct NativeImportedMediaEvidence {
    pub session_id: String,
    pub relative_path: String,
    pub byte_length: u64,
    pub sample_count: u64,
    pub digest_sha256: String,
    pub journal_version: u32,
    pub last_journal_sequence: u64,
    pub original_untouched: bool,
    pub ready_for_review: bool,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq, uniffi::Record)]
pub struct NativeImportPolicy {
    pub maximum_source_bytes: u64,
    pub maximum_managed_bytes: u64,
    pub maximum_duration_nanoseconds: u64,
    pub maximum_managed_samples: u64,
}

#[derive(Clone, Debug, Eq, PartialEq, uniffi::Record)]
pub struct NativeCompressedImportMetadata {
    pub original: NativeOriginalImportMetadata,
    pub sample_count: u64,
    pub digest_sha256: String,
}

#[uniffi::export]
pub fn native_import_policy() -> NativeImportPolicy {
    let policy = open_scribe_core::import_policy();
    NativeImportPolicy {
        maximum_source_bytes: policy.maximum_source_bytes,
        maximum_managed_bytes: policy.maximum_managed_bytes,
        maximum_duration_nanoseconds: policy.maximum_duration_nanoseconds,
        maximum_managed_samples: policy.maximum_managed_samples,
    }
}

#[derive(Clone, Debug, Eq, PartialEq, uniffi::Record)]
pub struct NativeOriginalImportMetadata {
    pub display_name: String,
    pub byte_length: u64,
    pub duration_nanoseconds: u64,
    pub sample_rate_hz: u32,
    pub channel_count: u32,
    pub media_format: String,
}

impl From<open_scribe_core::ImportedMediaEvidence> for NativeImportedMediaEvidence {
    fn from(evidence: open_scribe_core::ImportedMediaEvidence) -> Self {
        Self {
            session_id: evidence.session_id.0,
            relative_path: evidence.relative_path,
            byte_length: evidence.byte_length,
            sample_count: evidence.sample_count,
            digest_sha256: evidence.digest_sha256,
            journal_version: evidence.journal_version,
            last_journal_sequence: evidence.last_journal_sequence,
            original_untouched: evidence.original_untouched,
            ready_for_review: evidence.ready_for_review,
        }
    }
}

#[derive(Debug, thiserror::Error, uniffi::Error)]
pub enum NativeStorageError {
    #[error("The storage root is invalid.")]
    InvalidManagedRoot,
    #[error("The preparation request is invalid.")]
    InvalidRequest,
    #[error("The import exceeds the size limit.")]
    ImportSizeLimit,
    #[error("The import exceeds the duration limit.")]
    ImportDurationLimit,
    #[error("The durable session is not in the required preparation state.")]
    InvalidState,
    #[error("Media or journal evidence does not match Rust authority.")]
    IntegrityMismatch,
    #[error("The durable storage operation failed.")]
    StorageFailure,
}

#[derive(uniffi::Object)]
pub struct NativeRecordingPreparation {
    controller: Arc<Mutex<open_scribe_core::RecordingPreparationController>>,
}

#[derive(uniffi::Object)]
pub struct NativeImportedPlaybackLease {
    lease: open_scribe_core::ImportedPlaybackLease,
    strategy: NativePlaybackLeaseStrategy,
}

enum NativePlaybackLeaseStrategy {
    ImportedSnapshot,
    ImportedCompressed,
    RecoveredVerifiedChunks,
}

#[derive(uniffi::Record)]
pub struct NativeTimelineSegment {
    pub track_id: String,
    pub segment_id: String,
    pub sequence: u64,
    pub start_nanoseconds: i64,
    pub native_start_nanoseconds: i64,
    pub clock_adjustment_nanoseconds: i64,
    pub sample_count: u64,
    pub channels: u16,
    pub gap_nanoseconds: i64,
    pub media: Arc<NativeTimelineMedia>,
}

#[derive(Clone, Debug, Eq, PartialEq, uniffi::Record)]
pub struct NativeMixdownAuthorization {
    pub session_id: String,
    pub relative_path: String,
    pub absolute_path: String,
    pub expected_frame_count: u64,
    pub source_digest_sha256: String,
    pub write_floor_bytes: u64,
}

#[derive(Clone, Debug, Eq, PartialEq, uniffi::Record)]
pub struct NativeMixdownReceipt {
    pub session_id: String,
    pub relative_path: String,
    pub byte_length: u64,
    pub decoded_frame_count: u64,
    pub sample_rate_hz: u32,
    pub channels: u16,
    pub codec: String,
    pub boundary_frames_readable: bool,
}

#[derive(Clone, Debug, Eq, PartialEq, uniffi::Record)]
pub struct NativeValidatedMixdown {
    pub session_id: String,
    pub relative_path: String,
    pub byte_length: u64,
    pub decoded_frame_count: u64,
    pub expected_frame_count: u64,
    pub digest_sha256: String,
    pub source_digest_sha256: String,
}

/// A bounded lease factory. Planning a long recording does not open every CAF
/// at once; the native decoder holds only the segments it currently reads.
#[derive(uniffi::Object)]
pub struct NativeTimelineMedia {
    controller: Arc<Mutex<open_scribe_core::RecordingPreparationController>>,
    segment: open_scribe_core::TimelineSegment,
}

#[uniffi::export]
impl NativeTimelineMedia {
    pub fn lease(&self) -> Result<Arc<NativeImportedPlaybackLease>, NativeStorageError> {
        let lease = self
            .controller
            .lock()
            .map_err(|_| NativeStorageError::StorageFailure)?
            .lease_timeline_segment(&self.segment)
            .map_err(map_storage_error)?;
        Ok(Arc::new(NativeImportedPlaybackLease {
            lease,
            strategy: NativePlaybackLeaseStrategy::RecoveredVerifiedChunks,
        }))
    }
}

#[uniffi::export]
impl NativeImportedPlaybackLease {
    pub fn playback_path(&self) -> String {
        match self.strategy {
            NativePlaybackLeaseStrategy::ImportedSnapshot => format!(
                "v1;fd={};byte_length={};sha256={};max_byte_length={}",
                self.lease.raw_file_descriptor(),
                self.lease.byte_length(),
                self.lease.digest_sha256(),
                open_scribe_core::ImportedPlaybackLease::maximum_snapshot_byte_length(),
            ),
            NativePlaybackLeaseStrategy::RecoveredVerifiedChunks => format!(
                "v2;fd={};byte_length={};sha256={};chunk_byte_length=65536",
                self.lease.raw_file_descriptor(),
                self.lease.byte_length(),
                self.lease.digest_sha256(),
            ),
            NativePlaybackLeaseStrategy::ImportedCompressed => format!(
                "v3;fd={};byte_length={};sha256={};chunk_byte_length=65536;format=m4a",
                self.lease.raw_file_descriptor(),
                self.lease.byte_length(),
                self.lease.digest_sha256(),
            ),
        }
    }
}

#[uniffi::export]
impl NativeRecordingPreparation {
    pub fn anchor_capture_clock(
        &self,
        session_id: String,
        host_anchor: u64,
        numerator: u32,
        denominator: u32,
    ) -> Result<(), NativeStorageError> {
        self.controller()?
            .anchor_capture_clock(
                open_scribe_types::SessionId(session_id),
                open_scribe_core::CaptureClock {
                    host_anchor,
                    numerator,
                    denominator,
                },
            )
            .map_err(map_storage_error)
    }

    pub fn authorize_next_segment(
        &self,
        session_id: String,
        previous_segment_id: String,
    ) -> Result<NativeMediaOpenAuthorization, NativeStorageError> {
        let a = self
            .controller()?
            .authorize_next_segment(
                open_scribe_types::SessionId(session_id),
                previous_segment_id,
            )
            .map_err(map_storage_error)?;
        Ok(NativeMediaOpenAuthorization {
            session_id: a.session_id.0,
            source_id: a.source_id,
            track_id: a.track_id,
            segment_id: a.segment_id,
            open_token: a.open_token,
            writer_generation: a.writer_generation,
            relative_path: a.relative_path,
            absolute_path: a.absolute_path.to_string_lossy().into_owned(),
            channels: a.channels,
            mapped_start_nanoseconds: a.mapped_start_nanoseconds,
        })
    }

    pub fn abandon_reserved_segment(
        &self,
        session_id: String,
        segment_id: String,
    ) -> Result<(), NativeStorageError> {
        self.controller()?
            .abandon_reserved_segment(open_scribe_types::SessionId(session_id), segment_id)
            .map_err(map_storage_error)
    }

    pub fn playback_timeline(
        &self,
        session_id: String,
    ) -> Result<Vec<NativeTimelineSegment>, NativeStorageError> {
        self.controller()?
            .playback_timeline(open_scribe_types::SessionId(session_id))
            .map_err(map_storage_error)
            .map(|segments| {
                segments
                    .into_iter()
                    .map(|segment| NativeTimelineSegment {
                        track_id: segment.track_id.clone(),
                        segment_id: segment.segment_id.clone(),
                        sequence: segment.sequence,
                        start_nanoseconds: segment.start_nanoseconds,
                        native_start_nanoseconds: segment.native_start_nanoseconds,
                        clock_adjustment_nanoseconds: segment.clock_adjustment_nanoseconds,
                        sample_count: segment.sample_count,
                        channels: segment.channels,
                        gap_nanoseconds: segment.gap_nanoseconds,
                        media: Arc::new(NativeTimelineMedia {
                            controller: Arc::clone(&self.controller),
                            segment,
                        }),
                    })
                    .collect()
            })
    }

    pub fn authorize_mixdown(
        &self,
        session_id: String,
        available_bytes: u64,
    ) -> Result<NativeMixdownAuthorization, NativeStorageError> {
        self.controller()?
            .authorize_mixdown(open_scribe_types::SessionId(session_id), available_bytes)
            .map_err(map_storage_error)
            .map(|value| NativeMixdownAuthorization {
                session_id: value.session_id.0,
                relative_path: value.relative_path,
                absolute_path: value.absolute_path.to_string_lossy().into_owned(),
                expected_frame_count: value.expected_frame_count,
                source_digest_sha256: value.source_digest_sha256,
                write_floor_bytes: value.write_floor_bytes,
            })
    }

    pub fn accept_mixdown(
        &self,
        receipt: NativeMixdownReceipt,
    ) -> Result<NativeValidatedMixdown, NativeStorageError> {
        self.controller()?
            .accept_mixdown(open_scribe_core::MixdownReceipt {
                session_id: open_scribe_types::SessionId(receipt.session_id),
                relative_path: receipt.relative_path,
                byte_length: receipt.byte_length,
                decoded_frame_count: receipt.decoded_frame_count,
                sample_rate_hz: receipt.sample_rate_hz,
                channels: receipt.channels,
                codec: receipt.codec,
                boundary_frames_readable: receipt.boundary_frames_readable,
            })
            .map_err(map_storage_error)
            .map(map_validated_mixdown)
    }

    pub fn validated_mixdown(
        &self,
        session_id: String,
    ) -> Result<Option<NativeValidatedMixdown>, NativeStorageError> {
        self.controller()?
            .validated_mixdown(&open_scribe_types::SessionId(session_id))
            .map_err(map_storage_error)
            .map(|value| value.map(map_validated_mixdown))
    }

    pub fn lease_validated_mixdown(
        &self,
        session_id: String,
    ) -> Result<Option<Arc<NativeImportedPlaybackLease>>, NativeStorageError> {
        self.controller()?
            .lease_validated_mixdown(&open_scribe_types::SessionId(session_id))
            .map_err(map_storage_error)
            .map(|value| {
                value.map(|lease| {
                    Arc::new(NativeImportedPlaybackLease {
                        lease,
                        strategy: NativePlaybackLeaseStrategy::ImportedCompressed,
                    })
                })
            })
    }

    #[uniffi::constructor]
    pub fn open(managed_root: String) -> Result<Arc<Self>, NativeStorageError> {
        let controller = open_scribe_core::RecordingPreparationController::open(managed_root)
            .map_err(map_storage_error)?;
        Ok(Arc::new(Self {
            controller: Arc::new(Mutex::new(controller)),
        }))
    }

    pub fn prepare_session(
        &self,
        title: String,
    ) -> Result<NativePreparedSession, NativeStorageError> {
        let receipt = self
            .controller()?
            .prepare_session(title)
            .map_err(map_storage_error)?;
        Ok(NativePreparedSession {
            session_id: receipt.session_id.0,
            schema_version: receipt.schema_version,
            journal_version: receipt.journal_version,
            last_journal_sequence: receipt.last_journal_sequence,
            journal_durable: receipt.journal_durable,
            media_files_open: receipt.media_files_open,
            recording_started: false,
        })
    }

    pub fn prepare_session_with_required_sources(
        &self,
        title: String,
        required_sources: Vec<NativeMediaSourceKind>,
    ) -> Result<NativePreparedSession, NativeStorageError> {
        let receipt = self
            .controller()?
            .prepare_session_with_required_sources(
                title,
                required_sources
                    .into_iter()
                    .map(map_media_source_kind)
                    .collect(),
            )
            .map_err(map_storage_error)?;
        Ok(NativePreparedSession {
            session_id: receipt.session_id.0,
            schema_version: receipt.schema_version,
            journal_version: receipt.journal_version,
            last_journal_sequence: receipt.last_journal_sequence,
            journal_durable: receipt.journal_durable,
            media_files_open: receipt.media_files_open,
            recording_started: false,
        })
    }

    pub fn confirm_recording(
        &self,
        session_id: String,
    ) -> Result<NativeRecordingStartedEvidence, NativeStorageError> {
        let evidence = self
            .controller()?
            .confirm_recording(open_scribe_types::SessionId(session_id))
            .map_err(map_storage_error)?;
        Ok(NativeRecordingStartedEvidence {
            session_id: evidence.session_id.0,
            required_sources: evidence
                .required_sources
                .into_iter()
                .map(map_native_media_source_kind)
                .collect(),
            active_sources: evidence
                .active_sources
                .into_iter()
                .map(map_native_media_source_kind)
                .collect(),
            journal_durable: evidence.journal_durable,
            media_files_open: evidence.media_files_open,
            recording_started: evidence.recording_started,
            last_journal_sequence: evidence.last_journal_sequence,
        })
    }

    pub fn authorize_initial_media(
        &self,
        session_id: String,
        source_kind: NativeMediaSourceKind,
        source_display_name: String,
    ) -> Result<NativeMediaOpenAuthorization, NativeStorageError> {
        let authorization = self
            .controller()?
            .authorize_initial_media(open_scribe_core::AuthorizeMediaOpenRequest {
                session_id: open_scribe_types::SessionId(session_id),
                source_kind: map_media_source_kind(source_kind),
                source_display_name,
            })
            .map_err(map_storage_error)?;
        Ok(NativeMediaOpenAuthorization {
            session_id: authorization.session_id.0,
            source_id: authorization.source_id,
            track_id: authorization.track_id,
            segment_id: authorization.segment_id,
            open_token: authorization.open_token,
            writer_generation: authorization.writer_generation,
            relative_path: authorization.relative_path,
            absolute_path: authorization.absolute_path.to_string_lossy().into_owned(),
            channels: authorization.channels,
            mapped_start_nanoseconds: authorization.mapped_start_nanoseconds,
        })
    }

    pub fn accept_media_open(
        &self,
        receipt: NativeMediaOpenReceipt,
    ) -> Result<NativeMediaOpenEvidence, NativeStorageError> {
        let evidence = self
            .controller()?
            .accept_coarse_media_open(open_scribe_core::CoarseMediaOpenReceipt {
                session_id: open_scribe_types::SessionId(receipt.session_id),
                track_id: receipt.track_id,
                segment_id: receipt.segment_id,
                open_token: receipt.open_token,
                writer_generation: receipt.writer_generation,
                relative_path: receipt.relative_path,
                channels: receipt.channels,
                initial_byte_length: receipt.initial_byte_length,
            })
            .map_err(map_storage_error)?;
        Ok(NativeMediaOpenEvidence {
            session_id: evidence.session_id.0,
            segment_id: evidence.segment_id,
            journal_durable: evidence.journal_durable,
            media_files_open: evidence.media_files_open,
            recording_started: evidence.recording_started,
            last_journal_sequence: evidence.last_journal_sequence,
        })
    }

    pub fn accept_first_sample(
        &self,
        receipt: NativeFirstSampleReceipt,
    ) -> Result<NativeFirstSampleEvidence, NativeStorageError> {
        let evidence = self
            .controller()?
            .accept_coarse_first_sample(open_scribe_core::CoarseFirstSampleReceipt {
                session_id: open_scribe_types::SessionId(receipt.session_id),
                track_id: receipt.track_id,
                segment_id: receipt.segment_id,
                open_token: receipt.open_token,
                writer_generation: receipt.writer_generation,
                relative_path: receipt.relative_path,
                first_sample_host_time: receipt.first_sample_host_time,
                first_sample_frame_count: receipt.first_sample_frame_count,
                observed_byte_length: receipt.observed_byte_length,
            })
            .map_err(map_storage_error)?;
        Ok(NativeFirstSampleEvidence {
            session_id: evidence.session_id.0,
            segment_id: evidence.segment_id,
            first_sample_session_nanoseconds: evidence.first_sample_session_nanoseconds,
            journal_durable: evidence.journal_durable,
            media_files_open: evidence.media_files_open,
            first_sample_durable: evidence.first_sample_durable,
            recording_started: evidence.recording_started,
            last_journal_sequence: evidence.last_journal_sequence,
        })
    }

    pub fn seal_segment(
        &self,
        receipt: NativeSealSegmentReceipt,
    ) -> Result<NativeSealedSegmentEvidence, NativeStorageError> {
        let evidence = self
            .controller()?
            .seal_coarse_segment(open_scribe_core::CoarseSealSegmentReceipt {
                session_id: open_scribe_types::SessionId(receipt.session_id),
                track_id: receipt.track_id,
                segment_id: receipt.segment_id,
                open_token: receipt.open_token,
                writer_generation: receipt.writer_generation,
                relative_path: receipt.relative_path,
                final_sample_host_time: receipt.final_sample_host_time,
                final_sample_count: receipt.final_sample_count,
                final_byte_length: receipt.final_byte_length,
            })
            .map_err(map_storage_error)?;
        Ok(NativeSealedSegmentEvidence {
            session_id: evidence.session_id.0,
            segment_id: evidence.segment_id,
            final_sample_count: evidence.sample_count,
            final_byte_length: evidence.final_byte_length,
            digest_sha256: evidence.digest_sha256,
            segment_sealed: evidence.segment_sealed,
            recording_started: evidence.recording_started,
            last_journal_sequence: evidence.last_journal_sequence,
        })
    }

    pub fn interrupt_session(
        &self,
        session_id: String,
        reason: NativeSessionInterruptionReason,
    ) -> Result<NativeSessionInterruptionEvidence, NativeStorageError> {
        let evidence = self
            .controller()?
            .interrupt_session(
                open_scribe_types::SessionId(session_id),
                map_session_interruption_reason(reason),
            )
            .map_err(map_storage_error)?;
        Ok(NativeSessionInterruptionEvidence {
            session_id: evidence.session_id.0,
            reason,
            journal_durable: evidence.journal_durable,
            session_interrupted: evidence.session_interrupted,
            recording_started: evidence.recording_started,
            last_journal_sequence: evidence.last_journal_sequence,
        })
    }

    pub fn record_source_failure(
        &self,
        session_id: String,
        source_kind: NativeMediaSourceKind,
        reason: NativeSourceFailureReason,
    ) -> Result<NativeSourceFailureEvidence, NativeStorageError> {
        let evidence = self
            .controller()?
            .record_source_failure(
                open_scribe_types::SessionId(session_id),
                map_media_source_kind(source_kind),
                map_source_failure_reason(reason),
            )
            .map_err(map_storage_error)?;
        Ok(NativeSourceFailureEvidence {
            session_id: evidence.session_id.0,
            source_kind,
            reason,
            journal_durable: evidence.journal_durable,
            source_failed: evidence.source_failed,
            session_degraded: evidence.session_degraded,
            session_interrupted: evidence.session_interrupted,
            recording_continues: evidence.recording_continues,
            last_journal_sequence: evidence.last_journal_sequence,
        })
    }

    pub fn recover_playable_sessions(
        &self,
    ) -> Result<Vec<NativeRecoveredPlayableSession>, NativeStorageError> {
        let recovered = self
            .controller()?
            .recover_playable_sessions()
            .map_err(map_storage_error)?;
        Ok(recovered
            .into_iter()
            .map(|recovered| NativeRecoveredPlayableSession {
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
            })
            .collect())
    }

    pub fn import_recoverable_caf(
        &self,
        title: String,
        source_path: String,
    ) -> Result<NativeImportedMediaEvidence, NativeStorageError> {
        let evidence = self
            .controller()?
            .import_recoverable_caf(title, source_path.into())
            .map_err(map_storage_error)?;
        Ok(evidence.into())
    }

    pub fn import_normalized_caf(
        &self,
        title: String,
        normalized_path: String,
        original: NativeOriginalImportMetadata,
    ) -> Result<NativeImportedMediaEvidence, NativeStorageError> {
        let evidence = self
            .controller()?
            .import_normalized_caf(
                title,
                normalized_path.into(),
                open_scribe_core::OriginalImportMetadata {
                    display_name: original.display_name,
                    byte_length: original.byte_length,
                    duration_nanoseconds: original.duration_nanoseconds,
                    sample_rate_hz: original.sample_rate_hz,
                    channel_count: original.channel_count,
                    media_format: original.media_format,
                },
            )
            .map_err(map_storage_error)?;
        Ok(evidence.into())
    }

    pub fn import_compressed_m4a(
        &self,
        title: String,
        source_path: String,
        metadata: NativeCompressedImportMetadata,
    ) -> Result<NativeImportedMediaEvidence, NativeStorageError> {
        let original = metadata.original;
        let evidence = self
            .controller()?
            .import_compressed_m4a(
                title,
                source_path.into(),
                open_scribe_core::CompressedImportMetadata {
                    original: open_scribe_core::OriginalImportMetadata {
                        display_name: original.display_name,
                        byte_length: original.byte_length,
                        duration_nanoseconds: original.duration_nanoseconds,
                        sample_rate_hz: original.sample_rate_hz,
                        channel_count: original.channel_count,
                        media_format: original.media_format,
                    },
                    sample_count: metadata.sample_count,
                    digest_sha256: metadata.digest_sha256,
                },
            )
            .map_err(map_storage_error)?;
        Ok(evidence.into())
    }

    pub fn lease_imported_playback(
        &self,
        session_id: String,
    ) -> Result<Arc<NativeImportedPlaybackLease>, NativeStorageError> {
        let lease = self
            .controller()?
            .lease_imported_playback(open_scribe_types::SessionId(session_id))
            .map_err(map_storage_error)?;
        let strategy = if lease.media_format() == "m4a-alac-or-aac" {
            NativePlaybackLeaseStrategy::ImportedCompressed
        } else if lease.byte_length()
            > open_scribe_core::ImportedPlaybackLease::maximum_snapshot_byte_length()
        {
            // Larger PCM stays on the verified chunk reader. The 256 MiB
            // snapshot path is only for audio that fits in that buffer.
            NativePlaybackLeaseStrategy::RecoveredVerifiedChunks
        } else {
            NativePlaybackLeaseStrategy::ImportedSnapshot
        };
        Ok(Arc::new(NativeImportedPlaybackLease { strategy, lease }))
    }

    pub fn lease_recovered_playback(
        &self,
        session_id: String,
        source_id: String,
        track_id: String,
        segment_id: String,
    ) -> Result<Arc<NativeImportedPlaybackLease>, NativeStorageError> {
        let lease = self
            .controller()?
            .lease_recovered_playback(
                open_scribe_types::SessionId(session_id),
                source_id,
                track_id,
                segment_id,
            )
            .map_err(map_storage_error)?;
        Ok(Arc::new(NativeImportedPlaybackLease {
            lease,
            strategy: NativePlaybackLeaseStrategy::RecoveredVerifiedChunks,
        }))
    }

    pub fn runtime_library_snapshot(
        &self,
    ) -> Result<NativeRuntimeLibrarySnapshot, NativeStorageError> {
        let snapshot = self
            .controller()?
            .runtime_library_snapshot()
            .map_err(map_storage_error)?;
        Ok(NativeRuntimeLibrarySnapshot {
            current_session: snapshot.current_session.map(map_runtime_session_snapshot),
            saved_sessions: snapshot
                .saved_sessions
                .into_iter()
                .map(map_runtime_session_snapshot)
                .collect(),
        })
    }
}

impl NativeRecordingPreparation {
    fn controller(
        &self,
    ) -> Result<
        std::sync::MutexGuard<'_, open_scribe_core::RecordingPreparationController>,
        NativeStorageError,
    > {
        self.controller
            .lock()
            .map_err(|_| NativeStorageError::InvalidState)
    }
}

const fn map_media_source_kind(kind: NativeMediaSourceKind) -> open_scribe_core::MediaSourceKind {
    match kind {
        NativeMediaSourceKind::Microphone => open_scribe_core::MediaSourceKind::Microphone,
        NativeMediaSourceKind::ApplicationAudio => {
            open_scribe_core::MediaSourceKind::ApplicationAudio
        }
        NativeMediaSourceKind::SystemAudio => open_scribe_core::MediaSourceKind::SystemAudio,
    }
}

const fn map_native_media_source_kind(
    kind: open_scribe_core::MediaSourceKind,
) -> NativeMediaSourceKind {
    match kind {
        open_scribe_core::MediaSourceKind::Microphone => NativeMediaSourceKind::Microphone,
        open_scribe_core::MediaSourceKind::ApplicationAudio => {
            NativeMediaSourceKind::ApplicationAudio
        }
        open_scribe_core::MediaSourceKind::SystemAudio => NativeMediaSourceKind::SystemAudio,
    }
}

const fn map_session_interruption_reason(
    reason: NativeSessionInterruptionReason,
) -> open_scribe_core::SessionInterruptionReason {
    match reason {
        NativeSessionInterruptionReason::CaptureStartFailed => {
            open_scribe_core::SessionInterruptionReason::CaptureStartFailed
        }
        NativeSessionInterruptionReason::CaptureFailed => {
            open_scribe_core::SessionInterruptionReason::CaptureFailed
        }
        NativeSessionInterruptionReason::FirstSampleRejected => {
            open_scribe_core::SessionInterruptionReason::FirstSampleRejected
        }
        NativeSessionInterruptionReason::StopWithoutDurableSample => {
            open_scribe_core::SessionInterruptionReason::StopWithoutDurableSample
        }
        NativeSessionInterruptionReason::SegmentSealFailed => {
            open_scribe_core::SessionInterruptionReason::SegmentSealFailed
        }
        NativeSessionInterruptionReason::PermissionRevoked => {
            open_scribe_core::SessionInterruptionReason::PermissionRevoked
        }
    }
}

const fn map_source_failure_reason(
    reason: NativeSourceFailureReason,
) -> open_scribe_core::SourceFailureReason {
    match reason {
        NativeSourceFailureReason::CaptureFailed => {
            open_scribe_core::SourceFailureReason::CaptureFailed
        }
        NativeSourceFailureReason::PermissionRevoked => {
            open_scribe_core::SourceFailureReason::PermissionRevoked
        }
    }
}

fn map_validated_mixdown(value: open_scribe_core::ValidatedMixdown) -> NativeValidatedMixdown {
    NativeValidatedMixdown {
        session_id: value.session_id.0,
        relative_path: value.relative_path,
        byte_length: value.byte_length,
        decoded_frame_count: value.decoded_frame_count,
        expected_frame_count: value.expected_frame_count,
        digest_sha256: value.digest_sha256,
        source_digest_sha256: value.source_digest_sha256,
    }
}

fn map_runtime_session_snapshot(
    snapshot: open_scribe_core::RuntimeSessionSnapshot,
) -> NativeRuntimeSessionSnapshot {
    NativeRuntimeSessionSnapshot {
        session_id: snapshot.session_id.0,
        title: snapshot.title,
        lifecycle: snapshot.lifecycle,
        health: snapshot.health,
        elapsed_seconds: snapshot.elapsed_seconds,
        journal_durable: snapshot.journal_durable,
        media_files_open: snapshot.media_files_open,
        interruption_reason: snapshot.interruption_reason.map(|reason| {
            match reason {
                open_scribe_core::SessionInterruptionReason::CaptureStartFailed => {
                    "capture_start_failed"
                }
                open_scribe_core::SessionInterruptionReason::CaptureFailed => "capture_failed",
                open_scribe_core::SessionInterruptionReason::FirstSampleRejected => {
                    "first_sample_rejected"
                }
                open_scribe_core::SessionInterruptionReason::StopWithoutDurableSample => {
                    "stop_without_durable_sample"
                }
                open_scribe_core::SessionInterruptionReason::SegmentSealFailed => {
                    "segment_seal_failed"
                }
                open_scribe_core::SessionInterruptionReason::PermissionRevoked => {
                    "permission_revoked"
                }
            }
            .to_owned()
        }),
        recovered: snapshot.recovered,
        has_capture_timeline: snapshot.has_capture_timeline,
        sources: snapshot
            .sources
            .into_iter()
            .map(|source| NativeRuntimeSourceSnapshot {
                kind: map_native_media_source_kind(source.kind),
                display_name: source.display_name,
                lifecycle: source.lifecycle,
            })
            .collect(),
        playable_media: snapshot
            .playable_media
            .map(|media| NativeRuntimePlayableMediaSnapshot {
                source_display_name: media.source_display_name,
                availability: match media.availability {
                    open_scribe_core::RuntimePlayableMediaAvailability::Available => "available",
                    open_scribe_core::RuntimePlayableMediaAvailability::Unavailable => {
                        "unavailable"
                    }
                    open_scribe_core::RuntimePlayableMediaAvailability::Corrupt => "corrupt",
                }
                .to_owned(),
                absolute_path: media
                    .absolute_path
                    .map(|path| path.to_string_lossy().into_owned()),
                duration_nanoseconds: media.duration_nanoseconds,
                sample_count: media.sample_count,
                byte_length: media.byte_length,
            }),
    }
}

fn map_storage_error(error: open_scribe_core::StoreError) -> NativeStorageError {
    #[cfg(debug_assertions)]
    if std::env::var_os("OPEN_SCRIBE_M1_PROOF_DIAGNOSTICS").as_deref()
        == Some(std::ffi::OsStr::new("1"))
    {
        // Explicit development proofs retain only error classes, never paths,
        // SQL payloads, titles, or media. Normal app runs emit nothing here.
        let class = match &error {
            open_scribe_core::StoreError::Io(value) => {
                format!("io_errno:{:?}", value.raw_os_error())
            }
            open_scribe_core::StoreError::Sqlite(value) => {
                format!("sqlite_code:{:?}", value.sqlite_error_code())
            }
            open_scribe_core::StoreError::InvalidState(_) => "invalid_state".to_owned(),
            open_scribe_core::StoreError::IntegrityMismatch(_) => "integrity_mismatch".to_owned(),
            _ => "other_rejection".to_owned(),
        };
        eprintln!("M1_STORAGE_DIAGNOSTIC {class}");
    }
    match error {
        open_scribe_core::StoreError::InvalidManagedRoot(_) => {
            NativeStorageError::InvalidManagedRoot
        }
        open_scribe_core::StoreError::InvalidRequest(_) => NativeStorageError::InvalidRequest,
        open_scribe_core::StoreError::ImportSizeLimit => NativeStorageError::ImportSizeLimit,
        open_scribe_core::StoreError::ImportDurationLimit => {
            NativeStorageError::ImportDurationLimit
        }
        open_scribe_core::StoreError::InvalidState(_) => NativeStorageError::InvalidState,
        open_scribe_core::StoreError::IntegrityMismatch(_) => NativeStorageError::IntegrityMismatch,
        open_scribe_core::StoreError::Io(_)
        | open_scribe_core::StoreError::Sqlite(_)
        | open_scribe_core::StoreError::Json(_)
        | open_scribe_core::StoreError::JournalRecordTooLarge
        | open_scribe_core::StoreError::InjectedInterruption => NativeStorageError::StorageFailure,
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq, uniffi::Enum)]
pub enum NativeFixture {
    Idle,
    Ready,
    Starting,
    Recording,
    Paused,
    Finalizing,
    RecordingDegraded,
    PermissionRevoked,
    RecoveryRequired,
    Complete,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq, uniffi::Enum)]
pub enum NativeCommandKind {
    Prepare,
    RequestStart,
    CancelStart,
    ConfirmRecording,
    Pause,
    Resume,
    BeginFinalizing,
    Complete,
    Interrupt,
    AdvanceTimer,
}

#[derive(Clone, Debug, Eq, PartialEq, uniffi::Record)]
pub struct NativeCommand {
    pub kind: NativeCommandKind,
    pub journal_durable: bool,
    pub media_files_open: bool,
    pub media_safe: bool,
    pub elapsed_seconds: u64,
}

#[derive(Clone, Debug, Eq, PartialEq, uniffi::Record)]
pub struct NativeSourceSnapshot {
    pub id: String,
    pub name: String,
    pub kind: String,
    pub activity: String,
    pub health: String,
    pub health_detail: Option<String>,
    pub permission: String,
    pub permission_recovery_hint: Option<String>,
}

#[derive(Clone, Debug, Eq, PartialEq, uniffi::Record)]
pub struct NativeSessionSnapshot {
    pub fixture: String,
    pub session_id: String,
    pub title: String,
    pub lifecycle: String,
    pub presentation: String,
    pub health: String,
    pub elapsed_seconds: u64,
    pub timer_behavior: String,
    pub timer_text: Option<String>,
    pub label: String,
    pub primary_symbol: Option<String>,
    pub fallback_symbol: Option<String>,
    pub accessibility_value: String,
    pub announcement: Option<String>,
    pub journal_durable: bool,
    pub media_files_open: bool,
    pub media_safe: bool,
    pub recovery_status: String,
    pub recovery_summary: Option<String>,
    pub sources: Vec<NativeSourceSnapshot>,
}

#[derive(Debug, thiserror::Error, uniffi::Error)]
pub enum NativeSessionError {
    #[error("The command is illegal for the current durable lifecycle and conditions.")]
    IllegalTransition,
    #[error("Recording requires durable journal and open-media evidence.")]
    DurabilityEvidenceMissing,
    #[error("Finalization requires evidence that media is safe.")]
    MediaNotSafe,
}

impl NativeSessionError {
    #[must_use]
    pub const fn code(&self) -> &'static str {
        match self {
            Self::IllegalTransition => "illegal_transition",
            Self::DurabilityEvidenceMissing => "durability_evidence_missing",
            Self::MediaNotSafe => "media_not_safe",
        }
    }
}

#[uniffi::export]
pub fn native_fixture_catalog() -> Vec<NativeSessionSnapshot> {
    open_scribe_core::fixture_snapshots()
        .into_iter()
        .map(|(fixture, snapshot)| map_snapshot(fixture, snapshot))
        .collect()
}

#[uniffi::export]
pub fn native_fixture(fixture: NativeFixture) -> NativeSessionSnapshot {
    let fixture = map_fixture(fixture);
    let snapshot = open_scribe_core::FixtureSessionController::new(fixture).snapshot();
    map_snapshot(fixture, snapshot)
}

#[uniffi::export]
pub fn native_apply_fixture_command(
    fixture: NativeFixture,
    command: NativeCommand,
) -> Result<NativeSessionSnapshot, NativeSessionError> {
    let fixture = map_fixture(fixture);
    let mut controller = open_scribe_core::FixtureSessionController::new(fixture);
    let previous = controller.snapshot();
    let snapshot = controller
        .apply(map_command(command))
        .map_err(map_transition_error)?;
    let announcement = open_scribe_core::announcement(&previous, &snapshot);
    let mut native = map_snapshot(fixture, snapshot);
    native.announcement = announcement;
    Ok(native)
}

fn map_fixture(fixture: NativeFixture) -> open_scribe_core::Fixture {
    match fixture {
        NativeFixture::Idle => open_scribe_core::Fixture::Idle,
        NativeFixture::Ready => open_scribe_core::Fixture::Ready,
        NativeFixture::Starting => open_scribe_core::Fixture::Starting,
        NativeFixture::Recording => open_scribe_core::Fixture::Recording,
        NativeFixture::Paused => open_scribe_core::Fixture::Paused,
        NativeFixture::Finalizing => open_scribe_core::Fixture::Finalizing,
        NativeFixture::RecordingDegraded => open_scribe_core::Fixture::RecordingDegraded,
        NativeFixture::PermissionRevoked => open_scribe_core::Fixture::PermissionRevoked,
        NativeFixture::RecoveryRequired => open_scribe_core::Fixture::RecoveryRequired,
        NativeFixture::Complete => open_scribe_core::Fixture::Complete,
    }
}

fn map_command(command: NativeCommand) -> open_scribe_core::Command {
    match command.kind {
        NativeCommandKind::Prepare => open_scribe_core::Command::Prepare,
        NativeCommandKind::RequestStart => open_scribe_core::Command::RequestStart,
        NativeCommandKind::CancelStart => open_scribe_core::Command::CancelStart,
        NativeCommandKind::ConfirmRecording => open_scribe_core::Command::ConfirmRecording {
            journal_durable: command.journal_durable,
            media_files_open: command.media_files_open,
        },
        NativeCommandKind::Pause => open_scribe_core::Command::Pause,
        NativeCommandKind::Resume => open_scribe_core::Command::Resume,
        NativeCommandKind::BeginFinalizing => open_scribe_core::Command::BeginFinalizing {
            media_safe: command.media_safe,
        },
        NativeCommandKind::Complete => open_scribe_core::Command::Complete,
        NativeCommandKind::Interrupt => open_scribe_core::Command::Interrupt,
        NativeCommandKind::AdvanceTimer => {
            open_scribe_core::Command::AdvanceTimer(command.elapsed_seconds)
        }
    }
}

fn map_transition_error(error: open_scribe_core::TransitionError) -> NativeSessionError {
    match error {
        open_scribe_core::TransitionError::IllegalTransition => {
            NativeSessionError::IllegalTransition
        }
        open_scribe_core::TransitionError::DurabilityEvidenceMissing => {
            NativeSessionError::DurabilityEvidenceMissing
        }
        open_scribe_core::TransitionError::MediaNotSafe => NativeSessionError::MediaNotSafe,
    }
}

fn map_snapshot(
    _fixture: open_scribe_core::Fixture,
    snapshot: open_scribe_core::SessionSnapshot,
) -> NativeSessionSnapshot {
    NativeSessionSnapshot {
        fixture: presentation_name(snapshot.presentation).into(),
        session_id: snapshot.session.id.0,
        title: snapshot.session.title,
        lifecycle: lifecycle_name(snapshot.session.lifecycle).into(),
        presentation: presentation_name(snapshot.presentation).into(),
        health: health_name(snapshot.session.health).into(),
        elapsed_seconds: snapshot.session.elapsed_seconds,
        timer_behavior: timer_name(snapshot.timer).into(),
        timer_text: snapshot.timer_text,
        label: snapshot.label,
        primary_symbol: snapshot.symbol.primary.map(str::to_owned),
        fallback_symbol: snapshot.symbol.fallback.map(str::to_owned),
        accessibility_value: snapshot.accessibility_value,
        announcement: None,
        journal_durable: snapshot.session.durability.journal_durable,
        media_files_open: snapshot.session.durability.media_files_open,
        media_safe: snapshot.session.durability.media_safe,
        recovery_status: recovery_name(snapshot.session.recovery.status).into(),
        recovery_summary: snapshot.session.recovery.preserved_evidence_summary,
        sources: snapshot
            .session
            .sources
            .into_iter()
            .map(|source| NativeSourceSnapshot {
                id: source.id.0,
                name: source.name,
                kind: source_kind_name(source.kind).into(),
                activity: source_activity_name(source.activity).into(),
                health: source_health_name(source.health).into(),
                health_detail: source.health_detail,
                permission: permission_name(source.permission.state).into(),
                permission_recovery_hint: source.permission.recovery_hint,
            })
            .collect(),
    }
}

const fn lifecycle_name(lifecycle: open_scribe_types::Lifecycle) -> &'static str {
    match lifecycle {
        open_scribe_types::Lifecycle::Idle => "idle",
        open_scribe_types::Lifecycle::Ready => "ready",
        open_scribe_types::Lifecycle::Recording => "recording",
        open_scribe_types::Lifecycle::Paused => "paused",
        open_scribe_types::Lifecycle::Finalizing => "finalizing",
        open_scribe_types::Lifecycle::ReadyForReview => "ready_for_review",
        open_scribe_types::Lifecycle::Interrupted => "interrupted",
    }
}

const fn presentation_name(presentation: open_scribe_core::Presentation) -> &'static str {
    match presentation {
        open_scribe_core::Presentation::Idle => "idle",
        open_scribe_core::Presentation::Ready => "ready",
        open_scribe_core::Presentation::Starting => "starting",
        open_scribe_core::Presentation::Recording => "recording",
        open_scribe_core::Presentation::Paused => "paused",
        open_scribe_core::Presentation::Finalizing => "finalizing",
        open_scribe_core::Presentation::RecordingDegraded => "recording_degraded",
        open_scribe_core::Presentation::PermissionRevoked => "permission_revoked",
        open_scribe_core::Presentation::RecoveryRequired => "recovery_required",
        open_scribe_core::Presentation::Complete => "complete",
    }
}

const fn timer_name(timer: open_scribe_core::TimerBehavior) -> &'static str {
    match timer {
        open_scribe_core::TimerBehavior::Hidden => "hidden",
        open_scribe_core::TimerBehavior::Advancing => "advancing",
        open_scribe_core::TimerBehavior::Frozen => "frozen",
    }
}

const fn health_name(health: open_scribe_types::SessionHealth) -> &'static str {
    match health {
        open_scribe_types::SessionHealth::Healthy => "healthy",
        open_scribe_types::SessionHealth::Degraded => "degraded",
    }
}

const fn recovery_name(status: open_scribe_types::RecoveryStatus) -> &'static str {
    match status {
        open_scribe_types::RecoveryStatus::NotRequired => "not_required",
        open_scribe_types::RecoveryStatus::Required => "required",
        open_scribe_types::RecoveryStatus::Deferred => "deferred",
        open_scribe_types::RecoveryStatus::Recovered => "recovered",
    }
}

const fn source_kind_name(kind: open_scribe_types::SourceKind) -> &'static str {
    match kind {
        open_scribe_types::SourceKind::Microphone => "microphone",
        open_scribe_types::SourceKind::ApplicationAudio => "application_audio",
        open_scribe_types::SourceKind::SystemAudio => "system_audio",
    }
}

const fn source_activity_name(activity: open_scribe_types::SourceActivity) -> &'static str {
    match activity {
        open_scribe_types::SourceActivity::Selected => "selected",
        open_scribe_types::SourceActivity::Active => "active",
        open_scribe_types::SourceActivity::Paused => "paused",
        open_scribe_types::SourceActivity::Failed => "failed",
    }
}

const fn source_health_name(health: open_scribe_types::SourceHealth) -> &'static str {
    match health {
        open_scribe_types::SourceHealth::Healthy => "healthy",
        open_scribe_types::SourceHealth::Failed => "failed",
    }
}

const fn permission_name(permission: open_scribe_types::PermissionState) -> &'static str {
    match permission {
        open_scribe_types::PermissionState::NotRequested => "not_requested",
        open_scribe_types::PermissionState::Granted => "granted",
        open_scribe_types::PermissionState::Denied => "denied",
        open_scribe_types::PermissionState::Revoked => "revoked",
        open_scribe_types::PermissionState::Restricted => "restricted",
    }
}

mod context;
pub use context::*;
mod evidence;
pub use evidence::*;
mod recorder;
pub use recorder::*;
mod speech;
pub use speech::*;
mod transcript_library;
pub use transcript_library::*;
uniffi::setup_scaffolding!();

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn every_fixture_round_trips_as_a_coarse_native_snapshot() {
        let fixtures = native_fixture_catalog();
        let expected = [
            NativeFixture::Idle,
            NativeFixture::Ready,
            NativeFixture::Starting,
            NativeFixture::Recording,
            NativeFixture::Paused,
            NativeFixture::Finalizing,
            NativeFixture::RecordingDegraded,
            NativeFixture::PermissionRevoked,
            NativeFixture::RecoveryRequired,
            NativeFixture::Complete,
        ];

        assert_eq!(fixtures.len(), 10);
        assert!(fixtures.iter().all(|snapshot| !snapshot.label.is_empty()));
        assert!(fixtures.iter().all(|snapshot| snapshot.sources.len() == 2));
        for (fixture, catalog_snapshot) in expected.into_iter().zip(fixtures) {
            assert_eq!(native_fixture(fixture), catalog_snapshot);
        }
    }

    #[test]
    fn starting_remains_ready_across_uniffi() {
        let snapshot = native_fixture(NativeFixture::Starting);

        assert_eq!(snapshot.lifecycle, "ready");
        assert_eq!(snapshot.presentation, "starting");
        assert_eq!(snapshot.timer_behavior, "hidden");
        assert!(!snapshot.journal_durable);
        assert!(!snapshot.media_files_open);
    }

    #[test]
    fn illegal_native_command_fails_with_stable_code() {
        let error = native_apply_fixture_command(
            NativeFixture::Idle,
            NativeCommand {
                kind: NativeCommandKind::Pause,
                journal_durable: false,
                media_files_open: false,
                media_safe: false,
                elapsed_seconds: 0,
            },
        )
        .unwrap_err();

        assert_eq!(error.code(), "illegal_transition");
    }

    #[test]
    fn recording_evidence_guard_survives_uniffi() {
        let error = native_apply_fixture_command(
            NativeFixture::Starting,
            NativeCommand {
                kind: NativeCommandKind::ConfirmRecording,
                journal_durable: true,
                media_files_open: false,
                media_safe: false,
                elapsed_seconds: 0,
            },
        )
        .unwrap_err();

        assert_eq!(error.code(), "durability_evidence_missing");
    }

    #[test]
    fn native_status_is_truthful_and_non_media() {
        let status = native_status();

        assert_eq!(status.product_name, "Open Scribe");
        assert_eq!(
            status.core_version,
            open_scribe_core::status_snapshot().core_version
        );
        assert_eq!(status.persistence, "Durable local audio and recovery");
        assert_eq!(status.capture, "Development microphone + system audio");
        assert_eq!(status.intelligence, "Not implemented");
    }

    #[test]
    fn managed_caf_import_round_trips_through_uniffi_and_the_runtime_library() {
        use std::fs::{self, File};
        use std::io::Write;
        use std::time::{SystemTime, UNIX_EPOCH};

        let unique = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let base = std::env::temp_dir().join(format!(
            "open-scribe-uniffi-import-{}-{unique}",
            std::process::id()
        ));
        fs::create_dir_all(&base).unwrap();
        let source = base.join("customer-interview.caf");
        let mut file = File::create(&source).unwrap();
        file.write_all(b"caff\0\x01\0\0").unwrap();
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
        file.write_all(&vec![0_u8; 960 * 2]).unwrap();
        file.sync_all().unwrap();
        drop(file);

        let managed_root = base.join("Open Scribe");
        let controller =
            NativeRecordingPreparation::open(managed_root.to_string_lossy().into_owned()).unwrap();
        let evidence = controller
            .import_recoverable_caf(
                "Customer interview".to_owned(),
                source.to_string_lossy().into_owned(),
            )
            .unwrap();

        assert!(evidence.original_untouched);
        assert!(evidence.ready_for_review);
        assert_eq!(evidence.sample_count, 960);
        let snapshot = controller.runtime_library_snapshot().unwrap();
        assert!(snapshot.current_session.is_none());
        assert_eq!(snapshot.saved_sessions.len(), 1);
        assert_eq!(snapshot.saved_sessions[0].session_id, evidence.session_id);
        assert_eq!(snapshot.saved_sessions[0].title, "Customer interview");
        let lease = controller
            .lease_imported_playback(evidence.session_id)
            .unwrap();
        let playback_receipt = lease.playback_path();
        assert!(playback_receipt.starts_with("v1;fd="));
        assert!(playback_receipt.contains(";max_byte_length=268435456"));
        fs::remove_dir_all(base).unwrap();
    }

    #[test]
    fn coarse_media_open_round_trips_without_recording() {
        use std::fs::{self, OpenOptions};
        use std::io::Write;
        use std::time::{SystemTime, UNIX_EPOCH};

        let unique = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let root = std::env::temp_dir().join(format!(
            "open-scribe-uniffi-media-{}-{unique}",
            std::process::id()
        ));
        let controller =
            NativeRecordingPreparation::open(root.to_string_lossy().into_owned()).unwrap();
        let prepared = controller
            .prepare_session("UniFFI media preparation".to_owned())
            .unwrap();
        assert!(prepared.journal_durable);
        assert!(!prepared.media_files_open);
        assert!(!prepared.recording_started);

        let authorization = controller
            .authorize_initial_media(
                prepared.session_id,
                NativeMediaSourceKind::Microphone,
                "Synthetic microphone".to_owned(),
            )
            .unwrap();
        let mut file = OpenOptions::new()
            .create_new(true)
            .write(true)
            .open(&authorization.absolute_path)
            .unwrap();
        file.write_all(b"caff\0\x01\0\0uniffi-test-media").unwrap();
        file.sync_all().unwrap();
        let byte_length = file.metadata().unwrap().len();

        let evidence = controller
            .accept_media_open(NativeMediaOpenReceipt {
                session_id: authorization.session_id.clone(),
                track_id: authorization.track_id.clone(),
                segment_id: authorization.segment_id.clone(),
                open_token: authorization.open_token.clone(),
                writer_generation: authorization.writer_generation,
                relative_path: authorization.relative_path.clone(),
                channels: authorization.channels,
                initial_byte_length: byte_length,
            })
            .unwrap();
        assert!(evidence.journal_durable);
        assert!(evidence.media_files_open);
        assert!(!evidence.recording_started);

        file.write_all(b"first-sample").unwrap();
        file.sync_all().unwrap();
        let first_sample = controller
            .accept_first_sample(NativeFirstSampleReceipt {
                session_id: authorization.session_id,
                track_id: authorization.track_id,
                segment_id: authorization.segment_id,
                open_token: authorization.open_token,
                writer_generation: authorization.writer_generation,
                relative_path: authorization.relative_path,
                first_sample_host_time: 42_000,
                first_sample_frame_count: 480,
                observed_byte_length: file.metadata().unwrap().len(),
            })
            .unwrap();
        assert!(first_sample.first_sample_durable);
        assert_eq!(first_sample.first_sample_session_nanoseconds, 0);
        assert!(!first_sample.recording_started);
        let recording = controller
            .confirm_recording(first_sample.session_id.clone())
            .unwrap();
        assert!(recording.journal_durable);
        assert!(recording.media_files_open);
        assert!(recording.recording_started);
        let runtime = controller.runtime_library_snapshot().unwrap();
        let current = runtime.current_session.unwrap();
        assert_eq!(current.session_id, first_sample.session_id);
        assert_eq!(current.lifecycle, "recording");
        assert_eq!(current.sources.len(), 1);
        assert_eq!(current.sources[0].kind, NativeMediaSourceKind::Microphone);
        assert_eq!(current.sources[0].lifecycle, "capturing");
        assert!(runtime.saved_sessions.is_empty());
        let interruption = controller
            .interrupt_session(
                first_sample.session_id,
                NativeSessionInterruptionReason::CaptureFailed,
            )
            .unwrap();
        assert!(interruption.journal_durable);
        assert!(interruption.session_interrupted);
        assert!(!interruption.recording_started);
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn recovered_playable_identity_round_trips_through_uniffi() {
        use std::fs::{self, OpenOptions};
        use std::io::Write;
        use std::time::{SystemTime, UNIX_EPOCH};

        let unique = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let root = std::env::temp_dir().join(format!(
            "open-scribe-uniffi-recovery-{}-{unique}",
            std::process::id()
        ));
        let controller =
            NativeRecordingPreparation::open(root.to_string_lossy().into_owned()).unwrap();
        let prepared = controller
            .prepare_session("Recovered identity".to_owned())
            .unwrap();
        let authorization = controller
            .authorize_initial_media(
                prepared.session_id.clone(),
                NativeMediaSourceKind::Microphone,
                "Synthetic microphone".to_owned(),
            )
            .unwrap();
        let mut file = OpenOptions::new()
            .create_new(true)
            .write(true)
            .open(&authorization.absolute_path)
            .unwrap();
        file.write_all(b"caff\0\x01\0\0").unwrap();
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
        file.sync_all().unwrap();
        let initial_byte_length = file.metadata().unwrap().len();

        controller
            .accept_media_open(NativeMediaOpenReceipt {
                session_id: authorization.session_id.clone(),
                track_id: authorization.track_id.clone(),
                segment_id: authorization.segment_id.clone(),
                open_token: authorization.open_token.clone(),
                writer_generation: authorization.writer_generation,
                relative_path: authorization.relative_path.clone(),
                channels: authorization.channels,
                initial_byte_length,
            })
            .unwrap();
        file.write_all(&vec![0_u8; 960 * 2]).unwrap();
        file.sync_all().unwrap();
        controller
            .accept_first_sample(NativeFirstSampleReceipt {
                session_id: authorization.session_id.clone(),
                track_id: authorization.track_id.clone(),
                segment_id: authorization.segment_id.clone(),
                open_token: authorization.open_token.clone(),
                writer_generation: authorization.writer_generation,
                relative_path: authorization.relative_path.clone(),
                first_sample_host_time: 42_000,
                first_sample_frame_count: 960,
                observed_byte_length: file.metadata().unwrap().len(),
            })
            .unwrap();
        controller
            .confirm_recording(authorization.session_id.clone())
            .unwrap();
        controller
            .interrupt_session(
                authorization.session_id.clone(),
                NativeSessionInterruptionReason::CaptureFailed,
            )
            .unwrap();
        drop(file);

        let recovered = controller.recover_playable_sessions().unwrap();
        assert_eq!(recovered.len(), 1);
        assert_eq!(recovered[0].session_id, authorization.session_id);
        assert_eq!(recovered[0].source_id, authorization.source_id);
        assert_eq!(recovered[0].track_id, authorization.track_id);
        assert_eq!(recovered[0].segment_id, authorization.segment_id);
        assert_eq!(recovered[0].source_kind, NativeMediaSourceKind::Microphone);
        assert_eq!(recovered[0].source_display_name, "Synthetic microphone");
        assert_eq!(recovered[0].sample_count, 960);
        let lease = controller
            .lease_recovered_playback(
                authorization.session_id,
                authorization.source_id,
                authorization.track_id,
                authorization.segment_id,
            )
            .unwrap();
        let receipt = lease.playback_path();
        assert!(receipt.starts_with("v2;fd="));
        assert!(receipt.contains(";chunk_byte_length=65536"));
        drop(lease);
        fs::remove_dir_all(root).unwrap();
    }
}
