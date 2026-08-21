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
pub struct NativeMediaOpenAuthorization {
    pub session_id: String,
    pub source_id: String,
    pub track_id: String,
    pub segment_id: String,
    pub open_token: String,
    pub writer_generation: u64,
    pub relative_path: String,
    pub absolute_path: String,
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

#[derive(Debug, thiserror::Error, uniffi::Error)]
pub enum NativeStorageError {
    #[error("The storage root is invalid.")]
    InvalidManagedRoot,
    #[error("The preparation request is invalid.")]
    InvalidRequest,
    #[error("The durable session is not in the required preparation state.")]
    InvalidState,
    #[error("Media or journal evidence does not match Rust authority.")]
    IntegrityMismatch,
    #[error("The durable storage operation failed.")]
    StorageFailure,
}

#[derive(uniffi::Object)]
pub struct NativeRecordingPreparation {
    controller: Mutex<open_scribe_core::RecordingPreparationController>,
}

#[uniffi::export]
impl NativeRecordingPreparation {
    #[uniffi::constructor]
    pub fn open(managed_root: String) -> Result<Arc<Self>, NativeStorageError> {
        let controller = open_scribe_core::RecordingPreparationController::open(managed_root)
            .map_err(map_storage_error)?;
        Ok(Arc::new(Self {
            controller: Mutex::new(controller),
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

fn map_storage_error(error: open_scribe_core::StoreError) -> NativeStorageError {
    match error {
        open_scribe_core::StoreError::InvalidManagedRoot(_) => {
            NativeStorageError::InvalidManagedRoot
        }
        open_scribe_core::StoreError::InvalidRequest(_) => NativeStorageError::InvalidRequest,
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
        assert_eq!(status.persistence, "Durable preparation only");
        assert_eq!(status.capture, "Not implemented");
        assert_eq!(status.intelligence, "Not implemented");
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
        fs::remove_dir_all(root).unwrap();
    }
}
