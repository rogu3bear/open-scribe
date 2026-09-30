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

#[derive(Debug, thiserror::Error, uniffi::Error)]
pub enum NativeSpeechError {
    #[error("No verified speech model is installed.")]
    ModelNotInstalled,
    #[error("The speech model was rejected ({reason}).")]
    ModelRejected { reason: String },
    #[error("The conversation has no recorded audio this build can transcribe.")]
    NoTranscribableAudio,
    #[error("Transcription was cancelled.")]
    Cancelled,
    #[error("Transcription ended ({reason}); recorded audio is unchanged.")]
    TranscriptionFailed { reason: String },
    #[error("The durable storage operation failed.")]
    StorageFailure,
}

/// One transcription's cancellation flag and coarse progress.
#[derive(uniffi::Object)]
pub struct NativeTranscriptionJob {
    cancel: AtomicBool,
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
            stage: AtomicU32::new(0),
            track_index: AtomicU32::new(0),
            track_count: AtomicU32::new(0),
            completed: AtomicI64::new(0),
            required: AtomicI64::new(0),
        })
    }

    pub fn cancel(&self) {
        self.cancel.store(true, Ordering::Relaxed);
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

    /// Reverifies the model, then transcribes every sealed track of one saved
    /// session. Blocking; honors `job.cancel()` between and within chunks.
    pub fn transcribe_session(
        &self,
        model_id: String,
        session_id: String,
        job: Arc<NativeTranscriptionJob>,
    ) -> Result<NativeTranscriptionSummary, NativeSpeechError> {
        let outcomes = self
            .models
            .transcribe(
                &model_id,
                &SessionId(session_id),
                &job.cancel,
                &mut |index, count, update| job.record(index, count, update),
            )
            .map_err(|error| match error {
                SpeechError::Model(error) => map_model_error(error),
                SpeechError::Transcription(error) => {
                    map_transcription_error(error, job.cancel.load(Ordering::Relaxed))
                }
            })?;
        Ok(NativeTranscriptionSummary {
            tracks: outcomes.len() as u32,
            segments: outcomes.iter().map(|outcome| outcome.segment_count).sum(),
            transcribed_chunks: outcomes
                .iter()
                .map(|outcome| outcome.transcribed_chunks)
                .sum(),
            reused_chunks: outcomes.iter().map(|outcome| outcome.reused_chunks).sum(),
        })
    }
}

fn map_model_error(error: SpeechModelError) -> NativeSpeechError {
    match error {
        SpeechModelError::NotInstalled | SpeechModelError::UnknownModel => {
            NativeSpeechError::ModelNotInstalled
        }
        other => NativeSpeechError::ModelRejected {
            reason: other.class().to_owned(),
        },
    }
}

fn map_transcription_error(error: TranscriptionError, cancelled: bool) -> NativeSpeechError {
    match error {
        TranscriptionError::RunEnded { .. } if cancelled => NativeSpeechError::Cancelled,
        TranscriptionError::RunEnded { failure, .. } => NativeSpeechError::TranscriptionFailed {
            reason: failure.class().to_owned(),
        },
        TranscriptionError::Store(StoreError::InvalidState(_)) => {
            NativeSpeechError::NoTranscribableAudio
        }
        TranscriptionError::Store(_) => NativeSpeechError::StorageFailure,
    }
}
