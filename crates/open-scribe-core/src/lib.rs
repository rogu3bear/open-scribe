//! Native session authority for Open Scribe.
//!
//! The current tranche keeps deterministic fixture commands and adds native
//! durable session/media-open preparation. It performs no capture, playback,
//! model, provider, or network work and never starts Recording.

use std::path::Path;

pub use open_scribe_domain::{
    Command, Fixture, Presentation, SessionSnapshot, TimerBehavior, TransitionError, announcement,
};
pub use open_scribe_store::{
    AuthorizeMediaOpenRequest, FirstSampleEvidence, FirstSampleReceipt, InterruptSessionRequest,
    MediaOpenAuthorization, MediaOpenEvidence, MediaOpenReceipt, MediaSourceKind,
    PrepareSessionRequest, PreparedSessionReceipt, RecordingStartedEvidence,
    RecoveredPlayableSession, RequiredSourcePlanEvidence, RuntimeLibrarySnapshot,
    RuntimeSessionSnapshot, RuntimeSourceSnapshot, SealSegmentReceipt, SealedSegmentEvidence,
    SessionInterruptionEvidence, SessionInterruptionReason, SessionOrigin, StoreError,
};

pub struct CoarseMediaOpenReceipt {
    pub session_id: open_scribe_types::SessionId,
    pub track_id: String,
    pub segment_id: String,
    pub open_token: String,
    pub writer_generation: u64,
    pub relative_path: String,
    pub initial_byte_length: u64,
}

pub struct CoarseFirstSampleReceipt {
    pub session_id: open_scribe_types::SessionId,
    pub track_id: String,
    pub segment_id: String,
    pub open_token: String,
    pub writer_generation: u64,
    pub relative_path: String,
    pub first_sample_host_time: u64,
    pub first_sample_frame_count: u64,
    pub observed_byte_length: u64,
}

pub struct CoarseSealSegmentReceipt {
    pub session_id: open_scribe_types::SessionId,
    pub track_id: String,
    pub segment_id: String,
    pub open_token: String,
    pub writer_generation: u64,
    pub relative_path: String,
    pub final_sample_host_time: u64,
    pub final_sample_count: u64,
    pub final_byte_length: u64,
}

/// Native Rust authority used by the coarse Swift preparation adapter.
pub struct RecordingPreparationController {
    store: open_scribe_store::SessionStore,
}

impl RecordingPreparationController {
    pub fn open(managed_root: impl AsRef<Path>) -> Result<Self, StoreError> {
        Ok(Self {
            store: open_scribe_store::SessionStore::open(managed_root)?,
        })
    }

    pub fn prepare_session(&mut self, title: String) -> Result<PreparedSessionReceipt, StoreError> {
        self.store.prepare_session(PrepareSessionRequest {
            title,
            origin: SessionOrigin::Capture,
        })
    }

    pub fn prepare_session_with_required_sources(
        &mut self,
        title: String,
        required_sources: Vec<MediaSourceKind>,
    ) -> Result<PreparedSessionReceipt, StoreError> {
        self.store.prepare_session_with_required_sources(
            PrepareSessionRequest {
                title,
                origin: SessionOrigin::Capture,
            },
            required_sources,
        )
    }

    pub fn plan_required_sources(
        &mut self,
        session_id: open_scribe_types::SessionId,
        required_sources: Vec<MediaSourceKind>,
    ) -> Result<RequiredSourcePlanEvidence, StoreError> {
        self.store
            .plan_required_sources(session_id, required_sources)
    }

    pub fn confirm_recording(
        &mut self,
        session_id: open_scribe_types::SessionId,
    ) -> Result<RecordingStartedEvidence, StoreError> {
        self.store.confirm_recording(session_id)
    }

    pub fn authorize_initial_media(
        &mut self,
        request: AuthorizeMediaOpenRequest,
    ) -> Result<MediaOpenAuthorization, StoreError> {
        self.store.authorize_media_open(request)
    }

    pub fn accept_coarse_media_open(
        &mut self,
        receipt: CoarseMediaOpenReceipt,
    ) -> Result<MediaOpenEvidence, StoreError> {
        self.store.accept_media_open(MediaOpenReceipt {
            session_id: receipt.session_id,
            track_id: receipt.track_id,
            segment_id: receipt.segment_id,
            open_token: receipt.open_token,
            writer_generation: receipt.writer_generation,
            relative_path: receipt.relative_path,
            media_format: "caf-pcm-s16le".to_owned(),
            sample_rate_hz: 48_000,
            channels: 1,
            initial_byte_length: receipt.initial_byte_length,
        })
    }

    pub fn accept_coarse_first_sample(
        &mut self,
        receipt: CoarseFirstSampleReceipt,
    ) -> Result<FirstSampleEvidence, StoreError> {
        self.store.accept_first_sample(FirstSampleReceipt {
            session_id: receipt.session_id,
            track_id: receipt.track_id,
            segment_id: receipt.segment_id,
            open_token: receipt.open_token,
            writer_generation: receipt.writer_generation,
            relative_path: receipt.relative_path,
            first_sample_host_time: receipt.first_sample_host_time,
            first_sample_frame_count: receipt.first_sample_frame_count,
            observed_byte_length: receipt.observed_byte_length,
        })
    }

    pub fn seal_coarse_segment(
        &mut self,
        receipt: CoarseSealSegmentReceipt,
    ) -> Result<SealedSegmentEvidence, StoreError> {
        self.store.seal_segment(SealSegmentReceipt {
            session_id: receipt.session_id,
            track_id: receipt.track_id,
            segment_id: receipt.segment_id,
            open_token: receipt.open_token,
            writer_generation: receipt.writer_generation,
            relative_path: receipt.relative_path,
            final_sample_host_time: receipt.final_sample_host_time,
            sample_count: receipt.final_sample_count,
            final_byte_length: receipt.final_byte_length,
        })
    }

    pub fn interrupt_session(
        &mut self,
        session_id: open_scribe_types::SessionId,
        reason: SessionInterruptionReason,
    ) -> Result<SessionInterruptionEvidence, StoreError> {
        self.store
            .interrupt_session(InterruptSessionRequest { session_id, reason })
    }

    pub fn recover_playable_sessions(
        &mut self,
    ) -> Result<Vec<RecoveredPlayableSession>, StoreError> {
        self.store.recover_playable_sessions()
    }

    pub fn runtime_library_snapshot(&self) -> Result<RuntimeLibrarySnapshot, StoreError> {
        self.store.runtime_library_snapshot()
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct FixtureSessionController {
    machine: open_scribe_domain::SessionMachine,
}

impl FixtureSessionController {
    #[must_use]
    pub fn new(fixture: Fixture) -> Self {
        Self {
            machine: open_scribe_domain::SessionMachine::from_fixture(fixture),
        }
    }

    #[must_use]
    pub fn snapshot(&self) -> SessionSnapshot {
        self.machine.snapshot()
    }

    pub fn apply(&mut self, command: Command) -> Result<SessionSnapshot, TransitionError> {
        self.machine.apply(command)
    }
}

#[must_use]
pub fn fixture_snapshots() -> Vec<(Fixture, SessionSnapshot)> {
    open_scribe_domain::fixture_catalog()
}

/// Current non-media state owned by the Rust core.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct CoreStatus {
    pub product_name: &'static str,
    pub core_version: &'static str,
    pub persistence: &'static str,
    pub capture: &'static str,
    pub intelligence: &'static str,
}

/// Returns the current coarse capability posture without performing I/O.
#[must_use]
pub const fn status_snapshot() -> CoreStatus {
    CoreStatus {
        product_name: "Open Scribe",
        core_version: env!("CARGO_PKG_VERSION"),
        persistence: "Durable local audio and recovery",
        capture: "Development microphone + system audio",
        intelligence: "Not implemented",
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn core_refuses_recording_without_complete_durability_evidence() {
        let mut controller = FixtureSessionController::new(Fixture::Starting);

        let error = controller
            .apply(Command::ConfirmRecording {
                journal_durable: true,
                media_files_open: false,
            })
            .unwrap_err();

        assert_eq!(error, TransitionError::DurabilityEvidenceMissing);
        assert_eq!(controller.snapshot().presentation, Presentation::Starting);
    }

    #[test]
    fn core_exposes_every_deterministic_fixture() {
        assert_eq!(fixture_snapshots().len(), Fixture::ALL.len());
    }

    #[test]
    fn status_snapshot_reports_bounded_dual_source_capture_without_intelligence() {
        let status = status_snapshot();

        assert_eq!(status.product_name, "Open Scribe");
        assert_eq!(status.core_version, env!("CARGO_PKG_VERSION"));
        assert_eq!(status.persistence, "Durable local audio and recovery");
        assert_eq!(status.capture, "Development microphone + system audio");
        assert_eq!(status.intelligence, "Not implemented");
    }
}
