//! Coarse local speech-model and transcription calls. Installation and one
//! session's transcription are each a single blocking call the app runs off
//! the main actor; progress is polled from the job object, never pushed per
//! chunk.

use super::*;
use open_scribe_core::{
    SpeechError, SpeechModelError, SpeechModels, StoreError, TranscriptionError, TranscriptionStage,
};
use open_scribe_types::SessionId;
use std::path::Path;
use std::sync::atomic::{AtomicBool, AtomicI64, AtomicU32, Ordering};

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

/// One transcription's cancellation flag and coarse progress.
#[derive(uniffi::Object)]
pub struct NativeTranscriptionJob {
    cancel: AtomicBool,
    stop_reason: AtomicU32,
    stage: AtomicU32,
    track_index: AtomicU32,
    track_count: AtomicU32,
    completed: AtomicI64,
    required: AtomicI64,
}

#[uniffi::export]
impl NativeTranscriptionJob {
    #[uniffi::constructor]
    pub fn new() -> Arc<Self> {
        Arc::new(Self {
            cancel: AtomicBool::new(false),
            stop_reason: AtomicU32::new(0),
            stage: AtomicU32::new(0),
            track_index: AtomicU32::new(0),
            track_count: AtomicU32::new(0),
            completed: AtomicI64::new(0),
            required: AtomicI64::new(0),
        })
    }

    pub fn cancel(&self) {
        self.stop_reason.store(1, Ordering::Release);
        self.cancel.store(true, Ordering::Relaxed);
    }

    pub fn preempt_for_capture(&self) {
        let _ = self
            .stop_reason
            .compare_exchange(0, 2, Ordering::AcqRel, Ordering::Acquire);
        self.cancel.store(true, Ordering::Release);
    }

    pub fn is_cancelled(&self) -> bool {
        self.cancel.load(Ordering::Relaxed)
    }

    pub fn stop_outcome(&self) -> Option<NativeWorkOutcome> {
        match self.stop_reason.load(Ordering::Acquire) {
            1 => Some(NativeWorkOutcome::UserCancelled),
            2 => Some(NativeWorkOutcome::CapturePreempted),
            _ => None,
        }
    }

    pub fn progress(&self) -> NativeTranscriptionProgress {
        NativeTranscriptionProgress {
            stage: match self.stage.load(Ordering::Relaxed) {
                1 => NativeTranscriptionStage::Decoding,
                2 => NativeTranscriptionStage::Transcribing,
                3 => NativeTranscriptionStage::Reconciling,
                _ => NativeTranscriptionStage::Waiting,
            },
            track_index: self.track_index.load(Ordering::Relaxed),
            track_count: self.track_count.load(Ordering::Relaxed),
            completed_nanoseconds: self.completed.load(Ordering::Relaxed),
            required_nanoseconds: self.required.load(Ordering::Relaxed),
        }
    }
}

impl NativeTranscriptionJob {
    pub(crate) fn cancellation(&self) -> &AtomicBool {
        &self.cancel
    }
    fn record(&self, track_index: usize, track_count: usize, update: TranscriptionProgressUpdate) {
        self.track_index
            .store(track_index as u32, Ordering::Relaxed);
        self.track_count
            .store(track_count as u32, Ordering::Relaxed);
        self.stage.store(
            match update.stage {
                TranscriptionStage::Decoding => 1,
                TranscriptionStage::Transcribing => 2,
                TranscriptionStage::Reconciling => 3,
            },
            Ordering::Relaxed,
        );
        self.completed
            .store(update.completed_nanoseconds, Ordering::Relaxed);
        self.required
            .store(update.required_nanoseconds, Ordering::Relaxed);
    }
}

type TranscriptionProgressUpdate = open_scribe_core::TranscriptionProgress;

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

    /// Whether the app must first decode the session's compressed import to a
    /// 48 kHz 16-bit linear CAF companion and pass it to `transcribe_session`.
    pub fn needs_decoded_companion(&self, session_id: String) -> Result<bool, NativeSpeechError> {
        self.models
            .needs_decoded_companion(&SessionId(session_id))
            .map_err(|error| match error {
                StoreError::InvalidState(_) => NativeSpeechError::NoTranscribableAudio,
                _ => NativeSpeechError::StorageFailure,
            })
    }

    pub fn needs_decoded_companion_for_intent(
        &self,
        session_id: String,
        intent: NativeTranscriptionIntent,
    ) -> Result<bool, NativeSpeechError> {
        self.models
            .needs_decoded_companion_for_intent(&SessionId(session_id), intent.into())
            .map_err(|_| NativeSpeechError::NoTranscribableAudio)
    }

    /// Reverifies the model, then transcribes every sealed track of one saved
    /// session. Blocking; honors `job.cancel()` between and within chunks.
    /// `decoded_companion_path` is required for a compressed import.
    pub fn transcribe_session(
        &self,
        model_id: String,
        session_id: String,
        decoded_companion_path: Option<String>,
        job: Arc<NativeTranscriptionJob>,
    ) -> Result<NativeTranscriptionSummary, NativeSpeechError> {
        self.transcribe_intent(
            model_id,
            session_id,
            NativeTranscriptionIntent::ResumeIncomplete,
            None,
            decoded_companion_path,
            job,
        )
        .map(|completion| completion.summary)
    }

    pub fn transcribe_with_intent(
        &self,
        model_id: String,
        session_id: String,
        intent: NativeTranscriptionIntent,
        admission: Option<String>,
        decoded_companion_path: Option<String>,
        job: Arc<NativeTranscriptionJob>,
    ) -> NativeTranscriptionResult {
        match self.transcribe_intent(
            model_id,
            session_id,
            intent,
            admission,
            decoded_companion_path,
            job.clone(),
        ) {
            Ok(completion) => NativeTranscriptionResult {
                outcome: completion.outcome,
                summary: Some(completion.summary),
                reason: (completion.outcome == NativeWorkOutcome::Incomplete)
                    .then(|| "Some tracks still need recognition; no complete saved parts were available for them.".into()),
                failure: None,
            },
            Err(error) => NativeTranscriptionResult {
                outcome: match job.stop_reason.load(Ordering::Acquire) {
                    1 => NativeWorkOutcome::UserCancelled,
                    2 => NativeWorkOutcome::CapturePreempted,
                    _ => {
                        if matches!(error, NativeSpeechError::CapturePreempted) {
                            NativeWorkOutcome::CapturePreempted
                        } else if matches!(error, NativeSpeechError::Cancelled) {
                            NativeWorkOutcome::UserCancelled
                        } else if matches!(
                            error,
                            NativeSpeechError::Deferred
                                | NativeSpeechError::ModelNotInstalled
                                | NativeSpeechError::ModelReadiness { .. }
                        ) {
                            NativeWorkOutcome::Deferred
                        } else {
                            NativeWorkOutcome::Failed
                        }
                    }
                },
                summary: None,
                reason: Some(error.to_string()),
                failure: Some(error),
            },
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

struct IntentCompletion {
    summary: NativeTranscriptionSummary,
    outcome: NativeWorkOutcome,
}

impl NativeSpeechModels {
    fn transcribe_intent(
        &self,
        model_id: String,
        session_id: String,
        intent: NativeTranscriptionIntent,
        admission: Option<String>,
        decoded_companion_path: Option<String>,
        job: Arc<NativeTranscriptionJob>,
    ) -> Result<IntentCompletion, NativeSpeechError> {
        if job.is_cancelled() {
            return Err(NativeSpeechError::Cancelled);
        }
        let mut control = open_scribe_core::SessionStore::open(self.models.managed_root())
            .map_err(|_| NativeSpeechError::StorageFailure)?;
        let session = SessionId(session_id);
        // Build before model loading, companion decoding, or a new admission.
        let plan = open_scribe_core::plan_session_transcription(&control, &session, intent.into())
            .map_err(|_| NativeSpeechError::NoTranscribableAudio)?;
        let completion_outcome = plan.completion_outcome();
        if plan.tracks.is_empty() && completion_outcome == open_scribe_types::WorkOutcome::Completed
        {
            return Ok(IntentCompletion {
                summary: NativeTranscriptionSummary {
                    tracks: 0,
                    segments: 0,
                    transcribed_chunks: 0,
                    reused_chunks: 0,
                },
                outcome: completion_outcome.into(),
            });
        }
        let owns_admission = admission.is_none();
        let token = match admission {
            Some(token) => token,
            None => {
                control
                    .request_transcription(&session, intent.into())
                    .map_err(|_| NativeSpeechError::StorageFailure)?;
                let observations = open_scribe_types::WorkObservations {
                    automatic: false,
                    model: open_scribe_types::ModelReadiness::Ready,
                    ..Default::default()
                };
                let first = control
                    .transcription_queue(observations)
                    .map_err(|_| NativeSpeechError::StorageFailure)?;
                if first.first().is_none_or(|entry| {
                    entry.session_id != session || entry.hold.is_some() || entry.admission.is_some()
                }) {
                    return Err(NativeSpeechError::Deferred);
                }
                control
                    .admit_transcription(observations)
                    .map_err(|_| NativeSpeechError::StorageFailure)?
                    .and_then(|entry| entry.admission)
                    .ok_or(NativeSpeechError::Deferred)?
            }
        };
        if !control
            .start_transcription_execution(&session, &token, intent.into())
            .map_err(|_| NativeSpeechError::StorageFailure)?
        {
            if owns_admission {
                let _ =
                    control.finish_transcription(&token, open_scribe_types::WorkOutcome::Deferred);
            }
            return Err(NativeSpeechError::Deferred);
        }
        let operation = control
            .transcription_operation(&session, &token)
            .map_err(|_| NativeSpeechError::StorageFailure)?;
        let result = self
            .models
            .transcribe_with_operation(
                &model_id,
                &session,
                &operation,
                decoded_companion_path.as_deref().map(Path::new),
                &job.cancel,
                &mut |index, count, update| job.record(index, count, update),
            )
            .map_err(|error| match error {
                SpeechError::Model(error) => map_model_error(error),
                SpeechError::Transcription(error) => {
                    map_transcription_error(error, job.cancel.load(Ordering::Relaxed))
                }
            });
        if owns_admission {
            let outcome = if result.is_ok() {
                completion_outcome
            } else {
                match job.stop_reason.load(Ordering::Acquire) {
                    1 => open_scribe_types::WorkOutcome::UserCancelled,
                    2 => open_scribe_types::WorkOutcome::CapturePreempted,
                    _ => match result.as_ref().err() {
                        Some(NativeSpeechError::Cancelled) => {
                            open_scribe_types::WorkOutcome::UserCancelled
                        }
                        Some(NativeSpeechError::CapturePreempted) => {
                            open_scribe_types::WorkOutcome::CapturePreempted
                        }
                        Some(
                            NativeSpeechError::Deferred
                            | NativeSpeechError::ModelReadiness { .. }
                            | NativeSpeechError::ModelNotInstalled
                            | NativeSpeechError::ModelRejected { .. },
                        ) => open_scribe_types::WorkOutcome::Deferred,
                        _ => open_scribe_types::WorkOutcome::Failed,
                    },
                }
            };
            control
                .finish_transcription(&token, outcome)
                .map_err(|_| NativeSpeechError::StorageFailure)?;
        }
        let outcomes = result?;
        Ok(IntentCompletion {
            summary: NativeTranscriptionSummary {
                tracks: outcomes.len() as u32,
                segments: outcomes.iter().map(|outcome| outcome.segment_count).sum(),
                transcribed_chunks: outcomes
                    .iter()
                    .map(|outcome| outcome.transcribed_chunks)
                    .sum(),
                reused_chunks: outcomes.iter().map(|outcome| outcome.reused_chunks).sum(),
            },
            outcome: completion_outcome.into(),
        })
    }
}

fn map_model_error(error: SpeechModelError) -> NativeSpeechError {
    match error {
        SpeechModelError::NotInstalled | SpeechModelError::UnknownModel => {
            NativeSpeechError::ModelNotInstalled
        }
        SpeechModelError::Verify(error) => NativeSpeechError::ModelReadiness {
            state: if error.class() == "incompatible_engine" {
                NativeModelReadiness::Incompatible
            } else {
                NativeModelReadiness::Invalid
            },
            reason: error.class().to_owned(),
        },
        other => NativeSpeechError::ModelRejected {
            reason: other.class().to_owned(),
        },
    }
}

fn map_transcription_error(error: TranscriptionError, cancelled: bool) -> NativeSpeechError {
    match error {
        TranscriptionError::Preempted => NativeSpeechError::CapturePreempted,
        TranscriptionError::RunEnded {
            failure: open_scribe_core::TranscriptionFailure::CapturePreempted,
            ..
        } => NativeSpeechError::CapturePreempted,
        TranscriptionError::RunEnded { .. } if cancelled => NativeSpeechError::Cancelled,
        TranscriptionError::RunEnded { failure, .. } => NativeSpeechError::TranscriptionFailed {
            reason: failure.class().to_owned(),
        },
        TranscriptionError::Store(StoreError::InvalidState(_)) => {
            NativeSpeechError::NoTranscribableAudio
        }
        TranscriptionError::Store(StoreError::InvalidRequest(_)) => {
            NativeSpeechError::TranscriptionFailed {
                reason: "transcript_validation".to_owned(),
            }
        }
        TranscriptionError::Store(StoreError::DecodedAudio(error)) => match error {
            open_scribe_core::DecodedAudioError::UnsupportedFormat => {
                NativeSpeechError::DecodedAudioFormatRejected
            }
            open_scribe_core::DecodedAudioError::ChannelMismatch { expected, actual } => {
                NativeSpeechError::DecodedAudioChannelsMismatch { expected, actual }
            }
            open_scribe_core::DecodedAudioError::FrameCountMismatch { expected, actual } => {
                NativeSpeechError::DecodedAudioLengthMismatch { expected, actual }
            }
        },
        TranscriptionError::Store(StoreError::IntegrityMismatch(_)) => {
            NativeSpeechError::EvidenceChanged
        }
        TranscriptionError::Store(_) => NativeSpeechError::StorageFailure,
    }
}

#[cfg(test)]
mod failure_tests {
    use super::*;

    #[test]
    fn invalid_transcript_request_is_not_reported_as_failed_audio_decoding() {
        let mapped = map_transcription_error(
            TranscriptionError::Store(StoreError::InvalidRequest(
                "revision segment is outside its chunk",
            )),
            false,
        );
        assert!(matches!(
            mapped,
            NativeSpeechError::TranscriptionFailed { reason } if reason == "transcript_validation"
        ));
    }

    #[test]
    fn decoded_audio_failures_keep_their_reason_and_safe_counts() {
        use open_scribe_core::DecodedAudioError;
        let mapped = |reason| {
            map_transcription_error(
                TranscriptionError::Store(StoreError::DecodedAudio(reason)),
                false,
            )
        };
        assert!(matches!(
            mapped(DecodedAudioError::UnsupportedFormat),
            NativeSpeechError::DecodedAudioFormatRejected
        ));
        assert!(matches!(
            mapped(DecodedAudioError::ChannelMismatch {
                expected: 2,
                actual: 1
            }),
            NativeSpeechError::DecodedAudioChannelsMismatch {
                expected: 2,
                actual: 1
            }
        ));
        assert!(matches!(
            mapped(DecodedAudioError::FrameCountMismatch {
                expected: 48_000,
                actual: 47_999
            }),
            NativeSpeechError::DecodedAudioLengthMismatch {
                expected: 48_000,
                actual: 47_999
            }
        ));
    }

    #[test]
    fn changed_source_is_distinct_from_library_failure() {
        assert!(matches!(
            map_transcription_error(
                TranscriptionError::Store(StoreError::IntegrityMismatch("private canary")),
                false
            ),
            NativeSpeechError::EvidenceChanged
        ));
    }
}
