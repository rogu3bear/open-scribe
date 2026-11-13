//! Coarse local speech-model and transcription calls. Installation and one
//! session's transcription are each a single blocking call the app runs off
//! the main actor; progress is polled from the job object, never pushed per
//! chunk.

use super::*;
use open_scribe_core::{
    RemovalChoice, SpeechModels, TranscriptionJob, TranscriptionRunFailure,
    TranscriptionRunRequest, TranscriptionStage,
};
use open_scribe_types::SessionId;
use std::path::Path;

#[derive(Clone, Debug, Eq, PartialEq, uniffi::Record)]
pub struct NativeSpeechModel {
    pub model_id: String,
    pub profile: String,
    pub languages: Vec<String>,
    pub file_name: String,
    pub byte_length: u64,
    pub sha256: String,
    pub download_origin: String,
    pub license: String,
    pub engine: String,
    pub installed: bool,
    pub readiness: NativeModelReadiness,
    pub diagnostic: Option<String>,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq, uniffi::Enum)]
pub enum NativeTranscriptionStage {
    Waiting,
    Decoding,
    Transcribing,
    Reconciling,
}

#[derive(Clone, Debug, Eq, PartialEq, uniffi::Record)]
pub struct NativeTranscriptionProgress {
    pub stage: NativeTranscriptionStage,
    pub track_index: u32,
    pub track_count: u32,
    pub completed_nanoseconds: i64,
    pub required_nanoseconds: i64,
}

#[derive(Clone, Debug, Eq, PartialEq, uniffi::Record)]
pub struct NativeModelDownloadPlan {
    pub url: String,
    pub partial_path: String,
    pub expected_length: u64,
    pub resume_offset: u64,
}

#[derive(Clone, Debug, Eq, PartialEq, uniffi::Record)]
pub struct NativeTranscriptionSummary {
    pub tracks: u32,
    pub segments: u32,
    pub transcribed_chunks: u32,
    pub reused_chunks: u32,
}

#[derive(Clone, Debug, thiserror::Error, uniffi::Error)]
pub enum NativeSpeechError {
    #[error("No verified speech model is installed.")]
    ModelNotInstalled,
    #[error("The speech model was rejected ({reason}).")]
    ModelRejected { reason: String },
    #[error("The speech model is not ready ({reason}).")]
    ModelReadiness {
        state: NativeModelReadiness,
        reason: String,
    },
    #[error("The conversation has no recorded audio this build can transcribe.")]
    NoTranscribableAudio,
    #[error("The decoded audio did not match the imported recording.")]
    DecodedAudioRejected,
    #[error(
        "The decoded audio is not the required 48 kHz, 16-bit PCM CAF format. The original recording is unchanged."
    )]
    DecodedAudioFormatRejected,
    #[error(
        "The decoded audio has {actual} channels; the imported recording requires {expected}. The original recording is unchanged."
    )]
    DecodedAudioChannelsMismatch { expected: u16, actual: u16 },
    #[error(
        "The decoded audio has {actual} frames; the imported recording requires {expected}. The original recording is unchanged."
    )]
    DecodedAudioLengthMismatch { expected: u64, actual: u64 },
    #[error(
        "Saved conversation data no longer matches its verified state. Transcription stopped; no recording was changed."
    )]
    EvidenceChanged,
    #[error("Transcription was cancelled.")]
    Cancelled,
    #[error("Transcription yielded to capture.")]
    CapturePreempted,
    #[error("Transcription is deferred by current admission.")]
    Deferred,
    #[error("Transcription ended ({reason}); recorded audio is unchanged.")]
    TranscriptionFailed { reason: String },
    #[error("The durable storage operation failed.")]
    StorageFailure,
}

impl From<TranscriptionStage> for NativeTranscriptionStage {
    fn from(value: TranscriptionStage) -> Self {
        match value {
            TranscriptionStage::Decoding => Self::Decoding,
            TranscriptionStage::Transcribing => Self::Transcribing,
            TranscriptionStage::Reconciling => Self::Reconciling,
        }
    }
}

/// One transcription's cancellation flag and coarse progress.
#[derive(uniffi::Object)]
pub struct NativeTranscriptionJob {
    job: TranscriptionJob,
}

#[uniffi::export]
impl NativeTranscriptionJob {
    #[uniffi::constructor]
    pub fn new() -> Arc<Self> {
        Arc::new(Self {
            job: TranscriptionJob::default(),
        })
    }

    pub fn cancel(&self) {
        self.job.cancel();
    }

    pub fn preempt_for_capture(&self) {
        self.job.preempt_for_capture();
    }

    pub fn is_cancelled(&self) -> bool {
        self.job.is_cancelled()
    }

    pub fn stop_outcome(&self) -> Option<NativeWorkOutcome> {
        self.job.stop_reason().map(|reason| reason.outcome().into())
    }

    pub fn progress(&self) -> NativeTranscriptionProgress {
        let progress = self.job.progress();
        NativeTranscriptionProgress {
            stage: progress
                .stage
                .map_or(NativeTranscriptionStage::Waiting, Into::into),
            track_index: progress.track_index,
            track_count: progress.track_count,
            completed_nanoseconds: progress.completed_nanoseconds,
            required_nanoseconds: progress.required_nanoseconds,
        }
    }
}

impl NativeTranscriptionJob {
    pub(crate) fn job(&self) -> &TranscriptionJob {
        &self.job
    }
}

#[derive(uniffi::Object)]
pub struct NativeSpeechModels {
    models: SpeechModels,
}

#[uniffi::export]
impl NativeSpeechModels {
    #[uniffi::constructor]
    pub fn open(managed_root: String) -> Result<Arc<Self>, NativeStorageError> {
        let models =
            SpeechModels::open(managed_root).map_err(|_| NativeStorageError::InvalidManagedRoot)?;
        Ok(Arc::new(Self { models }))
    }

    pub fn models(&self) -> Vec<NativeSpeechModel> {
        let engine = format!(
            "{} {}",
            open_scribe_core::WHISPER_ENGINE,
            open_scribe_core::WHISPER_ENGINE_VERSION
        );
        self.models
            .statuses()
            .into_iter()
            .map(|status| NativeSpeechModel {
                model_id: status.model_id,
                profile: status.profile,
                languages: status.languages,
                file_name: status.file_name,
                byte_length: status.byte_length,
                sha256: status.sha256,
                download_origin: status.download_origin,
                license: status.license,
                engine: engine.clone(),
                installed: status.installed,
                readiness: status.readiness.into(),
                diagnostic: status.diagnostic,
            })
            .collect()
    }

    /// Verifies and installs a user-chosen model file. Blocking: it hashes
    /// the whole file and runs a one-second decode.
    pub fn install_from_file(
        &self,
        model_id: String,
        source_path: String,
    ) -> Result<(), NativeSpeechError> {
        self.models
            .install_from_file(&model_id, Path::new(&source_path))
            .map(|_| ())
            .map_err(map_model_error)
    }

    pub fn repair_from_file(
        &self,
        model_id: String,
        source_path: String,
    ) -> Result<(), NativeSpeechError> {
        self.models
            .repair_from_file(&model_id, Path::new(&source_path))
            .map(|_| ())
            .map_err(map_model_error)
    }

    /// Quarantines one installed model version. The returned directory is no
    /// longer loadable; the caller may move it to Trash. `active_run` means
    /// a transcription still holds the version, so the caller retries.
    pub fn remove_installed(
        &self,
        model_id: String,
        cancel_active_runs: bool,
    ) -> Result<String, NativeSpeechError> {
        let choice = if cancel_active_runs {
            RemovalChoice::CancelActive
        } else {
            RemovalChoice::Wait
        };
        self.models
            .remove(&model_id, choice)
            .map(|removed| removed.quarantined_directory.to_string_lossy().into_owned())
            .map_err(map_model_error)
    }

    /// Returns the catalog origin and an empty managed partial. The caller
    /// writes bytes there. This process does not fetch them.
    pub fn plan_model_download(
        &self,
        model_id: String,
    ) -> Result<NativeModelDownloadPlan, NativeSpeechError> {
        self.models
            .plan_download(&model_id)
            .map(|plan| NativeModelDownloadPlan {
                url: plan.url,
                partial_path: plan.partial_path.to_string_lossy().into_owned(),
                expected_length: plan.expected_length,
                resume_offset: plan.resume_offset,
            })
            .map_err(map_model_error)
    }

    /// Verifies the partial and installs it only when the existing checks pass.
    pub fn finish_model_download(&self, model_id: String) -> Result<(), NativeSpeechError> {
        self.models
            .finish_download(&model_id)
            .map(|_| ())
            .map_err(map_model_error)
    }

    /// Whether this intent's run must first be given a 48 kHz 16-bit linear
    /// CAF companion decoded from the session's compressed import.
    pub fn needs_decoded_companion_for_intent(
        &self,
        session_id: String,
        intent: NativeTranscriptionIntent,
    ) -> Result<bool, NativeSpeechError> {
        self.models
            .needs_decoded_companion_for_intent(&SessionId(session_id), intent.into())
            .map_err(|error| TranscriptionRunFailure::from_store(&error).into())
    }

    /// Reverifies the model, then transcribes the session's planned tracks.
    /// Blocking; honors `job.cancel()` between and within chunks.
    /// `decoded_companion_path` is required for a compressed import.
    pub fn transcribe_with_intent(
        &self,
        model_id: String,
        session_id: String,
        intent: NativeTranscriptionIntent,
        admission: Option<String>,
        decoded_companion_path: Option<String>,
        job: Arc<NativeTranscriptionJob>,
    ) -> NativeTranscriptionResult {
        let session = SessionId(session_id);
        let result = self.models.run_transcription(
            TranscriptionRunRequest {
                model_id: &model_id,
                session: &session,
                intent: intent.into(),
                admission: admission.as_deref(),
                decoded_companion: decoded_companion_path.as_deref().map(Path::new),
            },
            job.job(),
        );
        let outcome: NativeWorkOutcome = result.outcome.into();
        let failure: Option<NativeSpeechError> = result.failure.map(Into::into);
        NativeTranscriptionResult {
            outcome,
            summary: result.summary.map(|summary| NativeTranscriptionSummary {
                tracks: summary.tracks,
                segments: summary.segments,
                transcribed_chunks: summary.transcribed_chunks,
                reused_chunks: summary.reused_chunks,
            }),
            reason: match &failure {
                Some(failure) => Some(failure.to_string()),
                None => (outcome == NativeWorkOutcome::Incomplete).then(|| {
                    "Some tracks still need recognition; no complete saved parts were available for them.".into()
                }),
            },
            failure,
        }
    }
}

#[derive(Clone, Debug, uniffi::Record)]
pub struct NativeTranscriptionResult {
    pub outcome: NativeWorkOutcome,
    pub summary: Option<NativeTranscriptionSummary>,
    pub reason: Option<String>,
    /// Typed, content-free failure for presentation. Never parse `reason`.
    pub failure: Option<NativeSpeechError>,
}

impl From<TranscriptionRunFailure> for NativeSpeechError {
    fn from(value: TranscriptionRunFailure) -> Self {
        match value {
            TranscriptionRunFailure::ModelNotInstalled => Self::ModelNotInstalled,
            TranscriptionRunFailure::ModelRejected { reason } => Self::ModelRejected { reason },
            TranscriptionRunFailure::ModelReadiness { state, reason } => Self::ModelReadiness {
                state: state.into(),
                reason,
            },
            TranscriptionRunFailure::NoTranscribableAudio => Self::NoTranscribableAudio,
            TranscriptionRunFailure::DecodedAudioFormatRejected => Self::DecodedAudioFormatRejected,
            TranscriptionRunFailure::DecodedAudioChannelsMismatch { expected, actual } => {
                Self::DecodedAudioChannelsMismatch { expected, actual }
            }
            TranscriptionRunFailure::DecodedAudioLengthMismatch { expected, actual } => {
                Self::DecodedAudioLengthMismatch { expected, actual }
            }
            TranscriptionRunFailure::EvidenceChanged => Self::EvidenceChanged,
            TranscriptionRunFailure::Cancelled => Self::Cancelled,
            TranscriptionRunFailure::CapturePreempted => Self::CapturePreempted,
            TranscriptionRunFailure::Deferred => Self::Deferred,
            TranscriptionRunFailure::TranscriptionFailed { reason } => {
                Self::TranscriptionFailed { reason }
            }
            TranscriptionRunFailure::StorageFailure => Self::StorageFailure,
        }
    }
}

fn map_model_error(error: open_scribe_core::SpeechModelError) -> NativeSpeechError {
    TranscriptionRunFailure::from_model(error).into()
}
