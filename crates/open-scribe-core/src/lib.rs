//! Native session authority for Open Scribe: durable capture preparation,
//! review, export, and local transcription through a manifest-verified model.
//! Provider configuration authorizes no content category and opens no
//! connection. This crate performs no capture, playback, or network work.

use std::path::Path;

mod export;
pub use export::{
    TRANSCRIPT_V1_SCHEMA_JSON, TranscriptAvailability, TranscriptExport, TranscriptExportError,
    TranscriptExportFormat, TranscriptExportReceipt, write_atomically_with,
    write_transcript_export,
};
mod conversation_text;
pub use conversation_text::{
    ConversationText, ConversationTurn, compact_clock, conversation_text, conversation_turns,
    render_conversation_text,
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
mod package_import;
#[cfg(test)]
mod session_export_tests;
pub use package_import::{PackageImportReceipt, import_portable_package};
#[cfg(test)]
mod package_import_tests;
mod speech;
mod transcription_plan;
mod transcription_runner;
pub use open_scribe_asr::{WHISPER_ENGINE, WHISPER_ENGINE_VERSION};
pub use open_scribe_types::TranscriptionIntent;
pub use speech::{
    ModelDownloadPlan, RemovalChoice, RemovedSpeechModel, SpeechError, SpeechModelError,
    SpeechModelStatus, SpeechModels, decode_language, transcribe_session,
};
pub use transcription_plan::{
    SessionTranscriptionPlan, execute_transcription_plan, plan_session_transcription,
    plan_transcription_operation,
};
pub use transcription_runner::{
    JobProgress, StopReason, TranscriptionJob, TranscriptionRunFailure, TranscriptionRunRequest,
    TranscriptionRunResult, TranscriptionRunSummary,
};
#[cfg(test)]
mod conversation_text_tests;
#[cfg(test)]
mod speech_tests;
#[cfg(test)]
mod transcript_library_tests;
#[cfg(test)]
mod transcription_projection_tests;

pub use open_scribe_domain::{
    Command, Fixture, Presentation, SessionSnapshot, TRANSCRIPTION_DISK_FLOOR_BYTES, TimerBehavior,
    TransitionError, announcement, transcription_hold,
};
pub use open_scribe_evidence::{
    AdjudicationAction, DerivedClaim, EvidenceKind, EvidenceRef, EvidenceRefError, ResolutionState,
};
pub use open_scribe_memory::{
    ContentCategory, ExecutionMode, OfferedRecord, PolicyError, PreparedReview,
    ProviderConfiguration, RunAuthorization, UNCONFIGURED_PROVIDER_NOTICE, authorize_run,
    configure_provider, materialize_review, outbound_from_configuration, retarget_remote,
};
pub use open_scribe_store::{
    ClaimEvidenceSide, ClaimNavigation, ClaimNavigationTarget, DecodedAudioError, LibraryRecovery,
    RecoveryDisposition, ResolvedEvidence, RuntimeTranscriptState, SessionStore,
    TranscriptionFailure, TranscriptionOperation, TranscriptionRunPolicy, TranscriptionWork,
};
pub use open_scribe_store::{
    RecorderEventKind, RetainedRunUse, SessionHealth, SessionLifecycle, SourceLifecycle,
    StorageLevel, SuggestionBasis, TitleSource, TrackSourceKind, TranscriptFinality,
    TranscriptionFailureClass, TranscriptionRunState,
};

/// Canonical `open-scribe.evidence-ref/v1` JSON for a Rust-derived reference.
pub fn encode_evidence_ref(reference: &EvidenceRef) -> Result<String, StoreError> {
    serde_json::to_string(reference).map_err(StoreError::Json)
}
pub use open_scribe_diarize::SpeakerDisposition;
pub use open_scribe_store::{
    AcceptedContextEvent, CONTEXT_EVENT_SCHEMA, CONTEXT_EXCLUSIONS, CONTEXT_SCOPE_SCHEMA,
    ContextAction, ContextBounds, ContextCondition, ContextDecision, ContextDetail,
    ContextEventReason, ContextEventRecord, ContextFailureReason, ContextMode, ContextPauseReason,
    ContextProposal, ContextRejection, ContextRetention, ContextScope, ContextScopeRequest,
    ContextSource, ContextTarget, ContextTargetKind, ContextTextBlock, DisplayTopology,
    ScreenPermission, SessionDeclaration,
};
pub use open_scribe_store::{
    AuthorizeMediaOpenRequest, CaptureClock, CapturePolicy, CompressedImportMetadata,
    FirstSampleEvidence, FirstSampleReceipt, ImportMediaRequest, ImportPolicy,
    ImportedMediaEvidence, ImportedPlaybackLease, InterruptSessionRequest, MediaOpenAuthorization,
    MediaOpenEvidence, MediaOpenReceipt, MediaSourceKind, MixdownAuthorization, MixdownReceipt,
    MixdownWork, OriginalImportMetadata, PrepareSessionRequest, PreparedSessionReceipt,
    RecorderAction, RecorderDetail, RecorderEvent, RecordingStartedEvidence,
    RecoveredPlayableSession, RequiredSourcePlanEvidence, RuntimeLibrarySnapshot,
    RuntimePlayableMediaAvailability, RuntimePlayableMediaSnapshot, RuntimeSessionSnapshot,
    RuntimeSourceSnapshot, SealSegmentReceipt, SealedSegmentEvidence, SessionInterruptionEvidence,
    SessionInterruptionReason, SessionOrigin, SourceFailureEvidence, SourceFailureReason,
    SourceFailureRequest, StoreError, TimelineSegment, ValidatedMixdown, capture_policy,
    import_policy, source_defaults,
};
pub use open_scribe_store::{
    ConversationDocument, ConversationTitle, DocumentScope, LiveDraftWindow, NamedSpeakerTurn,
    NamedSpeakerTurnHistory, NamedSpeakerTurnRevision, NamedTranscriptSpeaker,
    SelectedRevisionProvenance, SessionDeletionInventory, SessionDeletionReceipt, SessionSpeaker,
    SpeakerDiarization, SpeakerDiarizationTrack, SpeakerLabelHistory, SpeakerLabelOrigin,
    SpeakerLabelRevision, TranscriptDocumentSegment, TranscriptExportContext, TranscriptProvenance,
    TranscriptProvenanceRange, TranscriptSearchHit, TranscriptSpeakerAssignment,
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
    /// The capture store. The platform adapter calls its methods directly;
    /// this controller adds only the coarse receipts and maintenance.
    pub fn store(&self) -> &SessionStore {
        &self.store
    }

    pub fn store_mut(&mut self) -> &mut SessionStore {
        &mut self.store
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

    pub fn open(managed_root: impl AsRef<Path>) -> Result<Self, StoreError> {
        Ok(Self {
            store: open_scribe_store::SessionStore::open(managed_root)?,
        })
    }

    /// Without a title, Rust names the capture with its placeholder.
    pub fn prepare_session_with_required_sources(
        &mut self,
        title: Option<String>,
        required_sources: Vec<MediaSourceKind>,
    ) -> Result<PreparedSessionReceipt, StoreError> {
        self.store.prepare_session_with_required_sources(
            PrepareSessionRequest::capture(title),
            required_sources,
        )
    }

    /// Draft text a reader can show. Selected Final text is omitted.
    pub fn readable_draft_texts(
        &self,
        session: &open_scribe_types::SessionId,
    ) -> Result<Vec<String>, StoreError> {
        Ok(self
            .store
            .conversation_document(session, DocumentScope::Readable)?
            .segments
            .into_iter()
            .filter(|segment| segment.finality == TranscriptFinality::Draft)
            .map(|segment| segment.effective_text)
            .collect())
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
            sample_rate_hz: open_scribe_types::MEDIA_SAMPLE_RATE_HZ,
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

    /// Reconciles retained transcripts when neither capture nor admitted work
    /// holds the library. A stop request on `job` decides the outcome.
    pub fn maintain_retained_transcripts(
        &mut self,
        job: &TranscriptionJob,
        observations: open_scribe_types::WorkObservations,
    ) -> Result<open_scribe_types::WorkOutcome, StoreError> {
        use open_scribe_types::WorkOutcome;
        if self.store.capture_active()? || observations.capture_active {
            return Ok(WorkOutcome::CapturePreempted);
        }
        if self.store.work_admission_active()?
            || transcription_hold(false, TranscriptionIntent::ReconcileRetained, observations)
                .is_some()
        {
            return Ok(WorkOutcome::Deferred);
        }
        let outcome = self.maintain_transcripts(job.cancellation(), observations)?;
        Ok(job.stop_reason().map_or(outcome, StopReason::outcome))
    }

    /// Lower-priority derived maintenance, explicitly outside capture-safety
    /// recovery. Cancellation yields between durable runs, never hides media.
    pub fn maintain_transcripts(
        &mut self,
        cancel: &std::sync::atomic::AtomicBool,
        observations: open_scribe_types::WorkObservations,
    ) -> Result<open_scribe_types::WorkOutcome, StoreError> {
        use open_scribe_types::WorkOutcome;
        let (pending, _) = self.store.recover_orphan_transcription_runs()?;
        // Class A: all chunks complete, worker gone — finalize without ASR,
        // under the reconciliation version this build actually applies.
        if let Some(stopped) = self.reconcile_maintenance_runs(pending, cancel, observations)? {
            return Ok(stopped);
        }
        // Runs an earlier build failed after every chunk was durable, or left
        // under a label this build no longer commits, are rebuilt from their
        // retained chunks once; media and the failed runs stay as evidence.
        let candidates = self
            .store
            .retained_transcript_candidates(open_scribe_asr::RECONCILIATION_VERSION)?;
        Ok(self
            .reconcile_maintenance_runs(candidates, cancel, observations)?
            .unwrap_or(WorkOutcome::Completed))
    }

    /// Reconciles `runs` in order; `Some` is the outcome that stopped them.
    fn reconcile_maintenance_runs(
        &mut self,
        runs: Vec<String>,
        cancel: &std::sync::atomic::AtomicBool,
        observations: open_scribe_types::WorkObservations,
    ) -> Result<Option<open_scribe_types::WorkOutcome>, StoreError> {
        use open_scribe_types::WorkOutcome;
        for run_id in runs {
            if cancel.load(std::sync::atomic::Ordering::Acquire) {
                return Ok(Some(WorkOutcome::UserCancelled));
            }
            if !self.reconcile_maintenance_run(&run_id, observations)? {
                return Ok(Some(
                    if self.store.capture_active()? || observations.capture_active {
                        WorkOutcome::CapturePreempted
                    } else {
                        WorkOutcome::Deferred
                    },
                ));
            }
        }
        Ok(None)
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
            Err(error) => TranscriptionRunFailure::from_transcription(error, false).outcome(),
        };
        self.store.finish_transcription(token, outcome)?;
        match result {
            Err(crate::TranscriptionError::Preempted)
            | Err(crate::TranscriptionError::RunEnded {
                failure: TranscriptionFailure::CapturePreempted,
                ..
            }) => Ok(false),
            Ok(_)
            | Err(
                crate::TranscriptionError::RunEnded { .. }
                | crate::TranscriptionError::Cancelled
                | crate::TranscriptionError::RecognizerRequired,
            ) => Ok(true),
            Err(crate::TranscriptionError::Store(
                StoreError::InvalidState(_)
                | StoreError::InvalidRequest(_)
                | StoreError::IntegrityMismatch(_),
            )) => Ok(true),
            Err(crate::TranscriptionError::Store(error)) => Err(error),
        }
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

pub use open_scribe_types::{NO_PUBLIC_RELEASE, public_capability_label};

/// One checked capability and the words a public surface may show for it.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct CapabilityClaim {
    pub id: String,
    pub terminology: String,
    pub maturity: String,
    pub public_label: String,
}

/// Reads the embedded registry. A manifest that cannot be read yields no
/// claims, so a broken registry cannot invent an Available capability.
#[must_use]
pub fn capability_claims() -> Vec<CapabilityClaim> {
    let Ok(manifest) = serde_json::from_str::<serde_json::Value>(RUNTIME_CAPABILITY_MANIFEST_JSON)
    else {
        return Vec::new();
    };
    let Some(capabilities) = manifest["capabilities"].as_array() else {
        return Vec::new();
    };
    capabilities
        .iter()
        .filter_map(|capability| {
            let id = capability["id"].as_str()?.to_owned();
            let terminology = capability["terminology"].as_str()?.to_owned();
            let maturity = capability["maturity"].as_str()?.to_owned();
            Some(CapabilityClaim {
                id,
                terminology,
                maturity: maturity.clone(),
                public_label: public_capability_label(&maturity).to_owned(),
            })
        })
        .collect()
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

    #[test]
    fn runtime_registry_matches_the_website_claim_manifest() {
        let website = include_str!("../../../docs/capabilities/manifest.v1.json");
        assert_eq!(website, RUNTIME_CAPABILITY_MANIFEST_JSON);
        let claims = capability_claims();
        assert_eq!(claims.len(), 8);
        assert!(claims.iter().all(|claim| {
            claim.public_label == public_capability_label(&claim.maturity)
                && claim.public_label != "Available"
        }));
    }

    #[test]
    fn runtime_capabilities_stay_excluded_without_a_signed_release() {
        let claims = capability_claims();

        assert_eq!(claims.len(), 8);
        assert!(claims.iter().all(|claim| claim.maturity != "Available"));
        assert!(claims.iter().all(|claim| claim.public_label != "Available"));
        let transcript = claims
            .iter()
            .find(|claim| claim.id == "local-transcription")
            .unwrap();
        assert_eq!(transcript.terminology, "Transcript");
        assert_eq!(transcript.public_label, "Unavailable");
        let recording = claims
            .iter()
            .find(|claim| claim.id == "multi-source-recording")
            .unwrap();
        assert_eq!(
            recording.public_label,
            "Development fixture — not available to users"
        );
        assert_eq!(NO_PUBLIC_RELEASE, "No public release is available.");
    }
}
