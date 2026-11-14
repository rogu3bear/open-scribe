//! One transcription of one saved conversation: plan, admit, run, finish.
//! Every way a run can end maps to one work outcome here, so the result the
//! platform shows and the outcome the queue records cannot disagree.

use crate::speech::{SpeechError, SpeechModelError, SpeechModels, verify_readiness};
use crate::transcription::{TranscriptionError, TranscriptionProgress, TranscriptionStage};
use open_scribe_store::{DecodedAudioError, SessionStore, StoreError, TranscriptionFailure};
use open_scribe_types::{
    ModelReadiness, SessionId, TranscriptionIntent, WorkObservations, WorkOutcome,
};
use std::path::Path;
use std::sync::atomic::{AtomicBool, AtomicI64, AtomicU8, AtomicU32, Ordering};

/// Why the caller asked a run to stop. A user cancel replaces a capture
/// preemption; a preemption never replaces a cancel.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum StopReason {
    UserCancelled,
    CapturePreempted,
}

impl StopReason {
    #[must_use]
    pub const fn outcome(self) -> WorkOutcome {
        match self {
            Self::UserCancelled => WorkOutcome::UserCancelled,
            Self::CapturePreempted => WorkOutcome::CapturePreempted,
        }
    }

    const fn code(self) -> u8 {
        match self {
            Self::UserCancelled => 1,
            Self::CapturePreempted => 2,
        }
    }

    const fn from_code(code: u8) -> Option<Self> {
        match code {
            1 => Some(Self::UserCancelled),
            2 => Some(Self::CapturePreempted),
            _ => None,
        }
    }
}

/// Coarse progress the platform polls; it is never pushed per chunk.
/// `stage` is `None` until the first track starts.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct JobProgress {
    pub stage: Option<TranscriptionStage>,
    pub track_index: u32,
    pub track_count: u32,
    pub completed_nanoseconds: i64,
    pub required_nanoseconds: i64,
}

/// Cancellation and progress shared by one run and the caller that started it.
#[derive(Debug, Default)]
pub struct TranscriptionJob {
    cancel: AtomicBool,
    stop: AtomicU8,
    stage: AtomicU8,
    track_index: AtomicU32,
    track_count: AtomicU32,
    completed: AtomicI64,
    required: AtomicI64,
}

impl TranscriptionJob {
    pub fn cancel(&self) {
        self.stop
            .store(StopReason::UserCancelled.code(), Ordering::Release);
        self.cancel.store(true, Ordering::Release);
    }

    pub fn preempt_for_capture(&self) {
        let _ = self.stop.compare_exchange(
            0,
            StopReason::CapturePreempted.code(),
            Ordering::AcqRel,
            Ordering::Acquire,
        );
        self.cancel.store(true, Ordering::Release);
    }

    pub fn is_cancelled(&self) -> bool {
        self.cancel.load(Ordering::Acquire)
    }

    pub fn stop_reason(&self) -> Option<StopReason> {
        StopReason::from_code(self.stop.load(Ordering::Acquire))
    }

    /// The flag the recognizer and the store checkpoints poll.
    pub fn cancellation(&self) -> &AtomicBool {
        &self.cancel
    }

    pub fn progress(&self) -> JobProgress {
        JobProgress {
            stage: match self.stage.load(Ordering::Relaxed) {
                1 => Some(TranscriptionStage::Decoding),
                2 => Some(TranscriptionStage::Transcribing),
                3 => Some(TranscriptionStage::Reconciling),
                _ => None,
            },
            track_index: self.track_index.load(Ordering::Relaxed),
            track_count: self.track_count.load(Ordering::Relaxed),
            completed_nanoseconds: self.completed.load(Ordering::Relaxed),
            required_nanoseconds: self.required.load(Ordering::Relaxed),
        }
    }

    fn record(&self, track_index: usize, track_count: usize, update: TranscriptionProgress) {
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

    /// The outcome a stop request decides, else the failure's own outcome.
    fn outcome_of(&self, failure: &TranscriptionRunFailure) -> WorkOutcome {
        self.stop_reason()
            .map_or_else(|| failure.outcome(), StopReason::outcome)
    }
}

/// Why a run ended without a transcript. Content-free; the platform words it.
#[derive(Clone, Debug, Eq, PartialEq)]
pub enum TranscriptionRunFailure {
    ModelNotInstalled,
    ModelRejected {
        reason: String,
    },
    ModelReadiness {
        state: ModelReadiness,
        reason: String,
    },
    NoTranscribableAudio,
    DecodedAudioFormatRejected,
    DecodedAudioChannelsMismatch {
        expected: u16,
        actual: u16,
    },
    DecodedAudioLengthMismatch {
        expected: u64,
        actual: u64,
    },
    EvidenceChanged,
    Cancelled,
    CapturePreempted,
    Deferred,
    TranscriptionFailed {
        reason: String,
    },
    StorageFailure,
}

impl TranscriptionRunFailure {
    /// The one work outcome for this failure. A missing or unready model
    /// waits for the model; a model that verified but cannot run fails, so
    /// the queue does not readmit it in a loop.
    #[must_use]
    pub fn outcome(&self) -> WorkOutcome {
        match self {
            Self::Cancelled => WorkOutcome::UserCancelled,
            Self::CapturePreempted => WorkOutcome::CapturePreempted,
            Self::Deferred | Self::ModelNotInstalled | Self::ModelReadiness { .. } => {
                WorkOutcome::Deferred
            }
            _ => WorkOutcome::Failed,
        }
    }

    #[must_use]
    pub fn from_model(error: SpeechModelError) -> Self {
        match error {
            SpeechModelError::NotInstalled | SpeechModelError::UnknownModel => {
                Self::ModelNotInstalled
            }
            SpeechModelError::Verify(error) => Self::ModelReadiness {
                state: verify_readiness(&error),
                reason: error.class().to_owned(),
            },
            other => Self::ModelRejected {
                reason: other.class().to_owned(),
            },
        }
    }

    /// `cancel_requested` reports a run the caller stopped, whatever failure
    /// class the run recorded on its way out.
    #[must_use]
    pub fn from_transcription(error: &TranscriptionError, cancel_requested: bool) -> Self {
        match error {
            TranscriptionError::Preempted
            | TranscriptionError::RunEnded {
                failure: TranscriptionFailure::CapturePreempted,
                ..
            } => Self::CapturePreempted,
            TranscriptionError::Cancelled
            | TranscriptionError::RunEnded {
                failure: TranscriptionFailure::Cancelled,
                ..
            } => Self::Cancelled,
            TranscriptionError::RunEnded { .. } if cancel_requested => Self::Cancelled,
            TranscriptionError::RunEnded { failure, .. } => Self::TranscriptionFailed {
                reason: failure.class().as_str().to_owned(),
            },
            TranscriptionError::RecognizerRequired => Self::ModelNotInstalled,
            TranscriptionError::Store(error) => Self::from_store(error),
        }
    }

    #[must_use]
    pub fn from_store(error: &StoreError) -> Self {
        match error {
            StoreError::InvalidState(_) => Self::NoTranscribableAudio,
            StoreError::InvalidRequest(_) => Self::TranscriptionFailed {
                reason: "transcript_validation".to_owned(),
            },
            StoreError::DecodedAudio(DecodedAudioError::UnsupportedFormat) => {
                Self::DecodedAudioFormatRejected
            }
            StoreError::DecodedAudio(DecodedAudioError::ChannelMismatch { expected, actual }) => {
                Self::DecodedAudioChannelsMismatch {
                    expected: *expected,
                    actual: *actual,
                }
            }
            StoreError::DecodedAudio(DecodedAudioError::FrameCountMismatch {
                expected,
                actual,
            }) => Self::DecodedAudioLengthMismatch {
                expected: *expected,
                actual: *actual,
            },
            StoreError::IntegrityMismatch(_) => Self::EvidenceChanged,
            _ => Self::StorageFailure,
        }
    }

    fn from_speech(error: SpeechError, cancel_requested: bool) -> Self {
        match error {
            SpeechError::Model(error) => Self::from_model(error),
            SpeechError::Transcription(error) => Self::from_transcription(&error, cancel_requested),
        }
    }
}

/// One request to transcribe a saved conversation.
#[derive(Clone, Copy, Debug)]
pub struct TranscriptionRunRequest<'a> {
    pub model_id: &'a str,
    pub session: &'a SessionId,
    pub intent: TranscriptionIntent,
    /// An admission the caller already holds and finishes itself. Without
    /// one, the run is admitted and finished here.
    pub admission: Option<&'a str>,
    /// The platform's PCM decode of a compressed import.
    pub decoded_companion: Option<&'a Path>,
}

#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub struct TranscriptionRunSummary {
    pub tracks: u32,
    pub segments: u32,
    pub transcribed_chunks: u32,
    pub reused_chunks: u32,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct TranscriptionRunResult {
    pub outcome: WorkOutcome,
    pub summary: Option<TranscriptionRunSummary>,
    pub failure: Option<TranscriptionRunFailure>,
}

impl SpeechModels {
    /// Reverifies the model, then transcribes the session's planned tracks.
    /// Blocking; honors `job` between and within chunks.
    pub fn run_transcription(
        &self,
        request: TranscriptionRunRequest<'_>,
        job: &TranscriptionJob,
    ) -> TranscriptionRunResult {
        match self.run_admitted(request, job) {
            Ok((outcome, summary)) => TranscriptionRunResult {
                outcome,
                summary: Some(summary),
                failure: None,
            },
            Err(failure) => TranscriptionRunResult {
                outcome: job.outcome_of(&failure),
                summary: None,
                failure: Some(failure),
            },
        }
    }

    fn run_admitted(
        &self,
        request: TranscriptionRunRequest<'_>,
        job: &TranscriptionJob,
    ) -> Result<(WorkOutcome, TranscriptionRunSummary), TranscriptionRunFailure> {
        if job.is_cancelled() {
            return Err(TranscriptionRunFailure::Cancelled);
        }
        let storage = |_| TranscriptionRunFailure::StorageFailure;
        let mut control = SessionStore::open(self.managed_root()).map_err(storage)?;
        let session = request.session;
        // Planned before model loading, companion decoding, or a new admission.
        let plan = crate::plan_session_transcription(&control, session, request.intent)
            .map_err(|error| TranscriptionRunFailure::from_store(&error))?;
        let completion = plan.completion_outcome();
        if plan.tracks.is_empty() && completion == WorkOutcome::Completed {
            return Ok((completion, TranscriptionRunSummary::default()));
        }
        let owned;
        let token = match request.admission {
            Some(token) => token,
            None => {
                owned = admit(&mut control, session, request.intent)?;
                owned.as_str()
            }
        };
        let owns_admission = request.admission.is_none();
        if !control
            .start_transcription_execution(session, token, request.intent)
            .map_err(storage)?
        {
            if owns_admission {
                control
                    .finish_transcription(token, WorkOutcome::Deferred)
                    .map_err(storage)?;
            }
            return Err(TranscriptionRunFailure::Deferred);
        }
        let operation = control
            .transcription_operation(session, token)
            .map_err(storage)?;
        let result = self
            .transcribe_with_operation(
                request.model_id,
                session,
                &operation,
                request.decoded_companion,
                job.cancellation(),
                &mut |index, count, update| job.record(index, count, update),
            )
            .map_err(|error| TranscriptionRunFailure::from_speech(error, job.is_cancelled()));
        if owns_admission {
            let outcome = match &result {
                Ok(_) => completion,
                Err(failure) => job.outcome_of(failure),
            };
            control
                .finish_transcription(token, outcome)
                .map_err(storage)?;
        }
        let outcomes = result?;
        Ok((
            completion,
            TranscriptionRunSummary {
                tracks: outcomes.len() as u32,
                segments: outcomes.iter().map(|outcome| outcome.segment_count).sum(),
                transcribed_chunks: outcomes
                    .iter()
                    .map(|outcome| outcome.transcribed_chunks)
                    .sum(),
                reused_chunks: outcomes.iter().map(|outcome| outcome.reused_chunks).sum(),
            },
        ))
    }
}

/// Requests and admits this session's run. A manual run waits behind any
/// other queued or held work instead of overtaking it.
fn admit(
    control: &mut SessionStore,
    session: &SessionId,
    intent: TranscriptionIntent,
) -> Result<String, TranscriptionRunFailure> {
    let storage = |_| TranscriptionRunFailure::StorageFailure;
    control
        .request_transcription(session, intent)
        .map_err(storage)?;
    let observations = WorkObservations {
        automatic: false,
        model: ModelReadiness::Ready,
        ..Default::default()
    };
    let queue = control.transcription_queue(observations).map_err(storage)?;
    if queue.first().is_none_or(|entry| {
        &entry.session_id != session || entry.hold.is_some() || entry.admission.is_some()
    }) {
        return Err(TranscriptionRunFailure::Deferred);
    }
    control
        .admit_transcription(observations)
        .map_err(storage)?
        .and_then(|entry| entry.admission)
        .ok_or(TranscriptionRunFailure::Deferred)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn invalid_transcript_request_is_not_reported_as_failed_audio_decoding() {
        let mapped = TranscriptionRunFailure::from_transcription(
            &TranscriptionError::Store(StoreError::InvalidRequest(
                "revision segment is outside its chunk",
            )),
            false,
        );
        assert!(matches!(
            mapped,
            TranscriptionRunFailure::TranscriptionFailed { reason } if reason == "transcript_validation"
        ));
    }

    #[test]
    fn decoded_audio_failures_keep_their_reason_and_safe_counts() {
        let mapped = |reason| {
            TranscriptionRunFailure::from_transcription(
                &TranscriptionError::Store(StoreError::DecodedAudio(reason)),
                false,
            )
        };
        assert_eq!(
            mapped(DecodedAudioError::UnsupportedFormat),
            TranscriptionRunFailure::DecodedAudioFormatRejected
        );
        assert_eq!(
            mapped(DecodedAudioError::ChannelMismatch {
                expected: 2,
                actual: 1
            }),
            TranscriptionRunFailure::DecodedAudioChannelsMismatch {
                expected: 2,
                actual: 1
            }
        );
        assert_eq!(
            mapped(DecodedAudioError::FrameCountMismatch {
                expected: 48_000,
                actual: 47_999
            }),
            TranscriptionRunFailure::DecodedAudioLengthMismatch {
                expected: 48_000,
                actual: 47_999
            }
        );
    }

    #[test]
    fn changed_source_is_distinct_from_library_failure() {
        assert_eq!(
            TranscriptionRunFailure::from_transcription(
                &TranscriptionError::Store(StoreError::IntegrityMismatch("private canary")),
                false
            ),
            TranscriptionRunFailure::EvidenceChanged
        );
    }

    #[test]
    fn a_model_that_verified_but_cannot_run_fails_wherever_the_admission_is_held() {
        let failure = TranscriptionRunFailure::from_model(SpeechModelError::Removing);
        assert!(matches!(
            failure,
            TranscriptionRunFailure::ModelRejected { ref reason } if reason == "removing"
        ));
        assert_eq!(failure.outcome(), WorkOutcome::Failed);
        assert_eq!(
            TranscriptionJob::default().outcome_of(&failure),
            WorkOutcome::Failed
        );
        assert_eq!(
            TranscriptionRunFailure::ModelNotInstalled.outcome(),
            WorkOutcome::Deferred
        );
    }

    #[test]
    fn a_library_read_failure_while_planning_is_not_missing_audio() {
        let io = StoreError::Io(std::io::Error::other("disk"));
        assert_eq!(
            TranscriptionRunFailure::from_store(&io),
            TranscriptionRunFailure::StorageFailure
        );
        assert_eq!(
            TranscriptionRunFailure::from_store(&StoreError::InvalidState(
                "session has no sealed track to transcribe"
            )),
            TranscriptionRunFailure::NoTranscribableAudio
        );
    }

    #[test]
    fn a_stop_between_tracks_is_reported_by_its_reason() {
        let stopped =
            TranscriptionRunFailure::from_transcription(&TranscriptionError::Cancelled, true);
        assert_eq!(stopped, TranscriptionRunFailure::Cancelled);
        let job = TranscriptionJob::default();
        job.preempt_for_capture();
        assert_eq!(job.outcome_of(&stopped), WorkOutcome::CapturePreempted);
        job.cancel();
        assert_eq!(job.stop_reason(), Some(StopReason::UserCancelled));
        assert_eq!(job.outcome_of(&stopped), WorkOutcome::UserCancelled);
        assert_eq!(
            TranscriptionRunFailure::from_transcription(
                &TranscriptionError::RecognizerRequired,
                false
            ),
            TranscriptionRunFailure::ModelNotInstalled
        );
    }

    #[test]
    fn a_preemption_never_replaces_a_cancel() {
        let job = TranscriptionJob::default();
        job.cancel();
        job.preempt_for_capture();
        assert_eq!(job.stop_reason(), Some(StopReason::UserCancelled));
        assert!(job.is_cancelled());
    }
}
