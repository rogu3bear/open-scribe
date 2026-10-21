//! Native session authority for Open Scribe.
//!
//! The current tranche keeps deterministic fixture commands and adds native
//! durable session/media-open preparation, review, and local transcription
//! through a manifest-verified model. It performs no capture, playback,
//! provider, or network work and never starts Recording.

use std::path::{Path, PathBuf};

mod export;
pub use export::{
    TRANSCRIPT_V1_SCHEMA_JSON, TranscriptAvailability, TranscriptExport, TranscriptExportError,
    TranscriptExportFormat, TranscriptExportReceipt, write_transcript_export,
};
mod transcript_library;
pub use transcript_library::{AudioExportOptions, TranscriptLibrary};
mod transcription;
pub use transcription::{
    RetainedTranscriptRecovery, TrackRequest, TranscriptionError, TranscriptionOutcome,
    TranscriptionProgress, TranscriptionStage, finalize_transcription_run,
    reconcile_retained_chunks, recover_retained_transcripts, transcribe_request, transcribe_track,
};
mod session_export;
pub use session_export::{
    FileExportReceipt, PORTABLE_V1_SCHEMA_JSON, PortableSummary, SESSION_MANIFEST_V1_SCHEMA_JSON,
    SessionExportError, export_source_media, export_track_wav, export_validated_mix,
    render_session_manifest, verify_portable_package, write_portable_package,
    write_session_manifest,
};
mod drift_measurement;
mod drift_stimulus;
pub use drift_measurement::{
    DRIFT_REPORT_SCHEMA, DriftOptions, DriftReport, TWO_HOURS_NANOSECONDS, measure_drift,
};
pub use drift_stimulus::{
    DRIFT_STIMULUS_SCHEMA, DriftError, STIMULUS_SAMPLE_RATE, StimulusSpec, stimulus_sha256,
    write_stimulus_wav,
};
mod package_import;
#[cfg(test)]
mod session_export_tests;
pub use package_import::{PackageImportReceipt, import_portable_package};
#[cfg(test)]
mod package_import_tests;
mod speech;
mod transcription_plan;
pub use open_scribe_asr::{WHISPER_ENGINE, WHISPER_ENGINE_VERSION};
pub use open_scribe_types::TranscriptionIntent;
pub use speech::{
    SpeechError, SpeechModelError, SpeechModelStatus, SpeechModels, decode_language,
    transcribe_session,
};
pub use transcription_plan::{
    SessionTranscriptionPlan, execute_transcription_plan, plan_session_transcription,
    plan_transcription_operation,
};
#[cfg(test)]
mod speech_tests;
#[cfg(test)]
mod transcription_projection_tests;

pub use open_scribe_domain::{
    Command, Fixture, Presentation, SessionSnapshot, TimerBehavior, TransitionError, announcement,
    transcription_hold,
};
pub use open_scribe_evidence::{EvidenceKind, EvidenceRef, EvidenceRefError, ResolutionState};
pub use open_scribe_store::{
    DecodedAudioError, LibraryRecovery, RecoveryDisposition, ResolvedEvidence,
    RuntimeTranscriptState, SessionStore, TranscriptionFailure, TranscriptionOperation,
    TranscriptionRunPolicy, TranscriptionWork,
};

/// Canonical `open-scribe.evidence-ref/v1` JSON for a Rust-derived reference.
pub fn encode_evidence_ref(reference: &EvidenceRef) -> Result<String, StoreError> {
    serde_json::to_string(reference).map_err(StoreError::Json)
}
pub use open_scribe_store::{
    AcceptedContextEvent, CONTEXT_EVENT_SCHEMA, CONTEXT_EXCLUSIONS, CONTEXT_SCOPE_SCHEMA,
    ContextAction, ContextBounds, ContextCondition, ContextDecision, ContextDetail,
    ContextEventReason, ContextEventRecord, ContextFailureReason, ContextMode, ContextPauseReason,
    ContextProposal, ContextRejection, ContextRetention, ContextScope, ContextScopeRequest,
    ContextSource, ContextTarget, ContextTargetKind, ContextTextBlock, DisplayTopology,
    ScreenPermission, SessionDeclaration,
};
pub use open_scribe_store::{
    AuthorizeMediaOpenRequest, CaptureClock, CompressedImportMetadata, FirstSampleEvidence,
    FirstSampleReceipt, ImportMediaRequest, ImportPolicy, ImportedMediaEvidence,
    ImportedPlaybackLease, InterruptSessionRequest, MediaOpenAuthorization, MediaOpenEvidence,
    MediaOpenReceipt, MediaSourceKind, MixdownAuthorization, MixdownReceipt, MixdownWork,
    OriginalImportMetadata, PrepareSessionRequest, PreparedSessionReceipt, RecorderAction,
    RecorderDetail, RecorderEvent, RecordingStartedEvidence, RecoveredPlayableSession,
    RequiredSourcePlanEvidence, RuntimeLibrarySnapshot, RuntimePlayableMediaAvailability,
    RuntimePlayableMediaSnapshot, RuntimeSessionSnapshot, RuntimeSourceSnapshot,
    SealSegmentReceipt, SealedSegmentEvidence, SessionInterruptionEvidence,
    SessionInterruptionReason, SessionOrigin, SourceFailureEvidence, SourceFailureReason,
    SourceFailureRequest, StoreError, TimelineSegment, ValidatedMixdown, import_policy,
};
pub use open_scribe_store::{
    NamedTranscriptSpeaker, SelectedRevisionProvenance, SessionDeletionInventory,
    SessionDeletionReceipt, SessionSpeaker, SpeakerLabelOrigin, TranscriptDocumentSegment,
    TranscriptExportContext, TranscriptSearchHit, TranscriptSpeakerAssignment,
};

pub struct CoarseMediaOpenReceipt {
    pub session_id: open_scribe_types::SessionId,
    pub track_id: String,
    pub segment_id: String,
    pub open_token: String,
    pub writer_generation: u64,
    pub relative_path: String,
    pub channels: u16,
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
    /// Scope changes share the recording writer, so context records and
    /// media records never race for the session journal.
    pub fn context_action(
        &mut self,
        session: open_scribe_types::SessionId,
        action: ContextAction,
    ) -> Result<ContextDetail, StoreError> {
        self.store.context_action(session, action)
    }

    pub fn propose_context_event(
        &mut self,
        session: open_scribe_types::SessionId,
        proposal: ContextProposal,
    ) -> Result<ContextDecision, StoreError> {
        self.store.propose_context_event(session, proposal)
    }

    pub fn context_detail(
        &self,
        session: &open_scribe_types::SessionId,
    ) -> Result<ContextDetail, StoreError> {
        self.store.context_detail(session)
    }

    pub fn declare_session(
        &mut self,
        session: open_scribe_types::SessionId,
        declaration: SessionDeclaration,
    ) -> Result<SessionDeclaration, StoreError> {
        self.store.declare_session(session, declaration)
    }

    pub fn recorder_action(
        &mut self,
        session: open_scribe_types::SessionId,
        action: RecorderAction,
    ) -> Result<RecorderDetail, StoreError> {
        self.store.recorder_action(session, action)
    }

    pub fn recorder_detail(
        &self,
        session: open_scribe_types::SessionId,
    ) -> Result<RecorderDetail, StoreError> {
        self.store.recorder_detail(&session)
    }
    pub fn anchor_capture_clock(
        &mut self,
        session_id: open_scribe_types::SessionId,
        clock: CaptureClock,
    ) -> Result<(), StoreError> {
        self.store.anchor_capture_clock(session_id, clock)
    }

    pub fn authorize_next_segment(
        &mut self,
        session_id: open_scribe_types::SessionId,
        previous: String,
    ) -> Result<MediaOpenAuthorization, StoreError> {
        self.store.authorize_next_segment(session_id, previous)
    }

    pub fn playback_timeline(
        &self,
        session_id: open_scribe_types::SessionId,
    ) -> Result<Vec<TimelineSegment>, StoreError> {
        self.store.playback_timeline(&session_id)
    }

    pub fn abandon_reserved_segment(
        &mut self,
        session_id: open_scribe_types::SessionId,
        segment_id: String,
    ) -> Result<(), StoreError> {
        self.store.abandon_reserved_segment(session_id, segment_id)
    }

    pub fn lease_timeline_segment(
        &self,
        segment: &TimelineSegment,
    ) -> Result<ImportedPlaybackLease, StoreError> {
        self.store.lease_capture_playback(
            &segment.session_id,
            &segment.source_id,
            &segment.track_id,
            &segment.segment_id,
            true,
        )
    }

    pub fn authorize_mixdown(
        &mut self,
        session_id: open_scribe_types::SessionId,
        available_bytes: u64,
    ) -> Result<MixdownAuthorization, StoreError> {
        self.store.authorize_mixdown(session_id, available_bytes)
    }

    pub fn accept_mixdown(
        &mut self,
        receipt: MixdownReceipt,
    ) -> Result<ValidatedMixdown, StoreError> {
        self.store.accept_mixdown(receipt)
    }

    pub fn validated_mixdown(
        &self,
        session_id: &open_scribe_types::SessionId,
    ) -> Result<Option<ValidatedMixdown>, StoreError> {
        self.store.validated_mixdown(session_id)
    }

    pub fn lease_validated_mixdown(
        &self,
        session_id: &open_scribe_types::SessionId,
    ) -> Result<Option<ImportedPlaybackLease>, StoreError> {
        self.store.lease_validated_mixdown(session_id)
    }
    pub fn open(managed_root: impl AsRef<Path>) -> Result<Self, StoreError> {
        Ok(Self {
            store: open_scribe_store::SessionStore::open(managed_root)?,
        })
    }

    /// Replaces a conversation's user-visible title; nothing else changes.
    pub fn rename_session(
        &mut self,
        session: open_scribe_types::SessionId,
        title: String,
    ) -> Result<String, StoreError> {
        self.store.rename_session(&session, &title)
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
            channels: receipt.channels,
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

    pub fn record_source_failure(
        &mut self,
        session_id: open_scribe_types::SessionId,
        source_kind: MediaSourceKind,
        reason: SourceFailureReason,
    ) -> Result<SourceFailureEvidence, StoreError> {
        self.store.record_source_failure(SourceFailureRequest {
            session_id,
            source_kind,
            reason,
        })
    }

    pub fn recover_playable_sessions(
        &mut self,
    ) -> Result<Vec<RecoveredPlayableSession>, StoreError> {
        Ok(self.recover_capture_safety()?.playable)
    }

    pub fn recover_capture_safety(&mut self) -> Result<LibraryRecovery, StoreError> {
        self.store.recover_library()
    }

    /// Lower-priority derived maintenance, explicitly outside capture-safety
    /// recovery. Cancellation yields between durable runs, never hides media.
    pub fn maintain_transcripts(
        &mut self,
        cancel: &std::sync::atomic::AtomicBool,
    ) -> Result<open_scribe_types::WorkOutcome, StoreError> {
        self.maintain_transcripts_with_observations(
            cancel,
            open_scribe_types::WorkObservations::default(),
        )
    }

    pub fn maintain_transcripts_with_observations(
        &mut self,
        cancel: &std::sync::atomic::AtomicBool,
        observations: open_scribe_types::WorkObservations,
    ) -> Result<open_scribe_types::WorkOutcome, StoreError> {
        use open_scribe_types::WorkOutcome;
        let (pending, _) = self.store.recover_orphan_transcription_runs()?;
        // Class A: all chunks complete, worker gone — finalize without ASR,
        // under the reconciliation version this build actually applies.
        for run_id in pending {
            if cancel.load(std::sync::atomic::Ordering::Acquire) {
                return Ok(WorkOutcome::UserCancelled);
            }
            if !self.reconcile_maintenance_run(&run_id, observations)? {
                return Ok(
                    if self.store.capture_active()? || observations.capture_active {
                        WorkOutcome::CapturePreempted
                    } else {
                        WorkOutcome::Deferred
                    },
                );
            }
        }
        // Runs an earlier build failed after every chunk was durable, or left
        // under a label this build no longer commits, are rebuilt from their
        // retained chunks once; media and the failed runs stay as evidence.
        let candidates = self
            .store
            .retained_transcript_candidates(open_scribe_asr::RECONCILIATION_VERSION)?;
        for run_id in candidates {
            if cancel.load(std::sync::atomic::Ordering::Acquire) {
                return Ok(WorkOutcome::UserCancelled);
            }
            if !self.reconcile_maintenance_run(&run_id, observations)? {
                return Ok(
                    if self.store.capture_active()? || observations.capture_active {
                        WorkOutcome::CapturePreempted
                    } else {
                        WorkOutcome::Deferred
                    },
                );
            }
        }
        Ok(WorkOutcome::Completed)
    }

    fn reconcile_maintenance_run(
        &mut self,
        run_id: &str,
        observations: open_scribe_types::WorkObservations,
    ) -> Result<bool, StoreError> {
        use open_scribe_types::WorkOutcome;
        let record = self.store.transcription_run_record(run_id)?;
        let session = &record.identity.session_id;
        let Some(claim) = self
            .store
            .admit_retained_reconciliation(session, observations)?
        else {
            return Ok(false);
        };
        let token = claim
            .admission
            .as_deref()
            .expect("store admission has token");
        if !self
            .store
            .start_transcription_execution(session, token, claim.intent)?
        {
            self.store
                .finish_transcription(token, WorkOutcome::Deferred)?;
            return Ok(false);
        }
        let operation = match self.store.transcription_operation(session, token) {
            Ok(operation) => operation,
            Err(error) => {
                let _ = self.store.finish_transcription(token, WorkOutcome::Failed);
                return Err(error);
            }
        };
        let policy = crate::TranscriptionRunPolicy {
            operation_key: None,
            selection: operation
                .selections
                .iter()
                .find(|expected| expected.track_id == record.identity.track_id)
                .map(|expected| expected.selection.clone()),
        };
        let result = crate::transcription::reconcile_retained_chunks_with_policy(
            &mut self.store,
            run_id,
            &policy,
        );
        let outcome = match &result {
            Ok(_) => {
                // Partial maintenance must not suppress ordinary automatic ASR
                // for the conversation's still-missing tracks.
                let all_final = match self.store.selection_expectations(session) {
                    Ok(selections) => selections
                        .iter()
                        .all(|expected| expected.selection.revision_id.is_some()),
                    Err(error) => {
                        let _ = self.store.finish_transcription(token, WorkOutcome::Failed);
                        return Err(error);
                    }
                };
                if all_final {
                    WorkOutcome::Completed
                } else {
                    WorkOutcome::Deferred
                }
            }
            Err(crate::TranscriptionError::Preempted) => WorkOutcome::CapturePreempted,
            Err(crate::TranscriptionError::RunEnded {
                failure: TranscriptionFailure::CapturePreempted,
                ..
            }) => WorkOutcome::CapturePreempted,
            Err(crate::TranscriptionError::RunEnded {
                failure: TranscriptionFailure::Cancelled,
                ..
            }) => WorkOutcome::UserCancelled,
            Err(_) => WorkOutcome::Failed,
        };
        self.store.finish_transcription(token, outcome)?;
        match result {
            Err(crate::TranscriptionError::Preempted)
            | Err(crate::TranscriptionError::RunEnded {
                failure: TranscriptionFailure::CapturePreempted,
                ..
            }) => Ok(false),
            Ok(_) | Err(crate::TranscriptionError::RunEnded { .. }) => Ok(true),
            Err(crate::TranscriptionError::Store(
                StoreError::InvalidState(_)
                | StoreError::InvalidRequest(_)
                | StoreError::IntegrityMismatch(_),
            )) => Ok(true),
            Err(crate::TranscriptionError::Store(error)) => Err(error),
        }
    }

    pub fn import_recoverable_caf(
        &mut self,
        title: String,
        source_path: PathBuf,
    ) -> Result<ImportedMediaEvidence, StoreError> {
        self.store
            .import_recoverable_caf(ImportMediaRequest { title, source_path })
    }

    pub fn import_normalized_caf(
        &mut self,
        title: String,
        source_path: PathBuf,
        original: OriginalImportMetadata,
    ) -> Result<ImportedMediaEvidence, StoreError> {
        self.store
            .import_normalized_caf(ImportMediaRequest { title, source_path }, original)
    }

    pub fn import_compressed_m4a(
        &mut self,
        title: String,
        source_path: PathBuf,
        metadata: CompressedImportMetadata,
    ) -> Result<ImportedMediaEvidence, StoreError> {
        self.store
            .import_compressed_m4a(ImportMediaRequest { title, source_path }, metadata)
    }

    pub fn lease_imported_playback(
        &self,
        session_id: open_scribe_types::SessionId,
    ) -> Result<ImportedPlaybackLease, StoreError> {
        self.store.lease_imported_playback(&session_id)
    }

    pub fn lease_recovered_playback(
        &self,
        session_id: open_scribe_types::SessionId,
        source_id: String,
        track_id: String,
        segment_id: String,
    ) -> Result<ImportedPlaybackLease, StoreError> {
        self.store
            .lease_recovered_playback(&session_id, &source_id, &track_id, &segment_id)
    }

    pub fn runtime_library_snapshot(&self) -> Result<RuntimeLibrarySnapshot, StoreError> {
        self.store.runtime_library_snapshot()
    }

    pub fn runtime_library_snapshot_at_host(
        &self,
        host_time: u64,
    ) -> Result<RuntimeLibrarySnapshot, StoreError> {
        self.store.runtime_library_snapshot_at_host(host_time)
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

/// Rust-owned compile-time capability registry embedded into native release
/// artifacts. Preparation compares these checked bytes with the public claim
/// manifest without compiling or executing code.
pub const RUNTIME_CAPABILITY_MANIFEST_JSON: &str = include_str!("../runtime-capabilities.v1.json");

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

    #[test]
    fn runtime_capability_registry_is_unique_and_fail_closed() {
        let manifest: serde_json::Value =
            serde_json::from_str(RUNTIME_CAPABILITY_MANIFEST_JSON).unwrap();
        let capabilities = manifest["capabilities"].as_array().unwrap();
        let mut ids = capabilities
            .iter()
            .map(|capability| capability["id"].as_str().unwrap())
            .collect::<Vec<_>>();
        ids.sort_unstable();
        ids.dedup();

        assert_eq!(ids.len(), capabilities.len());
        assert_eq!(manifest["schema"], "open-scribe.capabilities/v1");
        assert!(capabilities.iter().any(|capability| {
            capability["id"] == "local-transcription" && capability["maturity"] == "Unavailable"
        }));
        assert!(capabilities.iter().any(|capability| {
            capability["id"] == "optional-intelligence" && capability["maturity"] == "Unavailable"
        }));
    }
}
