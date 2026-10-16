//! Coarse operational intent/admission; no queue or lifecycle authority in Swift.
use super::*;
use open_scribe_core::{RuntimeTranscriptState, SessionStore};
use open_scribe_types::{
    AttemptState, DocumentAvailability, ModelReadiness, SessionId, TranscriptionIntent, WorkHold,
    WorkObservations, WorkOutcome,
};

macro_rules! vocabulary {
    ($native:ident, $core:ident, $($variant:ident),+ $(,)?) => {
        #[derive(Clone, Copy, Debug, Eq, PartialEq, uniffi::Enum)]
        pub enum $native { $($variant),+ }
        impl From<$native> for $core { fn from(value: $native) -> Self { match value { $($native::$variant => Self::$variant),+ } } }
        impl From<$core> for $native { fn from(value: $core) -> Self { match value { $($core::$variant => Self::$variant),+ } } }
    };
}
vocabulary!(
    NativeTranscriptionIntent,
    TranscriptionIntent,
    ResumeIncomplete,
    ReconcileRetained,
    ReprocessAll
);
vocabulary!(
    NativeWorkOutcome,
    WorkOutcome,
    Completed,
    UserCancelled,
    CapturePreempted,
    Failed,
    Deferred
);
vocabulary!(
    NativeModelReadiness,
    ModelReadiness,
    Absent,
    PresentUnverified,
    Verifying,
    Ready,
    Invalid,
    Incompatible
);
vocabulary!(
    NativeRuntimeTranscriptState,
    RuntimeTranscriptState,
    None,
    Running,
    Final,
    Partial,
    Failed,
    Cancelled,
    Unknown
);
vocabulary!(
    NativeAttemptState,
    AttemptState,
    None,
    Running,
    Complete,
    Failed,
    Cancelled,
    Preempted,
    Unknown
);
vocabulary!(
    NativeDocumentAvailability,
    DocumentAvailability,
    None,
    Partial,
    Final,
    Unavailable
);
vocabulary!(
    NativeWorkHold,
    WorkHold,
    Capture,
    MediaRecovery,
    ModelAbsent,
    ModelUnverified,
    ModelInvalid,
    ModelIncompatible,
    DiskPressure,
    MemoryPressure,
    ThermalPressure,
    AutomaticPaused,
    AutomaticDisabled,
    NoAudio,
    UnknownState,
    AlreadyRunning
);

#[derive(Clone, Copy, Debug, uniffi::Record)]
pub struct NativeWorkObservations {
    pub automatic: bool,
    pub paused: bool,
    pub capture_active: bool,
    pub media_recovery_pending: bool,
    pub model: NativeModelReadiness,
    pub available_disk_bytes: Option<u64>,
    pub memory_critical: bool,
    pub thermal_critical: bool,
}
impl From<NativeWorkObservations> for WorkObservations {
    fn from(value: NativeWorkObservations) -> Self {
        Self {
            automatic: value.automatic,
            paused: value.paused,
            capture_active: value.capture_active,
            media_recovery_pending: value.media_recovery_pending,
            model: value.model.into(),
            available_disk_bytes: value.available_disk_bytes,
            memory_critical: value.memory_critical,
            thermal_critical: value.thermal_critical,
        }
    }
}
#[derive(Clone, Debug, uniffi::Record)]
pub struct NativeTranscriptionWork {
    pub session_id: String,
    pub manual: bool,
    pub intent: NativeTranscriptionIntent,
    pub hold: Option<NativeWorkHold>,
    pub admission: Option<String>,
    pub outcome: Option<NativeWorkOutcome>,
}
impl From<open_scribe_core::TranscriptionWork> for NativeTranscriptionWork {
    fn from(value: open_scribe_core::TranscriptionWork) -> Self {
        Self {
            session_id: value.session_id.0,
            manual: value.manual,
            intent: value.intent.into(),
            hold: value.hold.map(Into::into),
            admission: value.admission,
            outcome: value.outcome.map(Into::into),
        }
    }
}
#[derive(Clone, Debug, uniffi::Record)]
pub struct NativeSessionWorkOutcome {
    pub session_id: String,
    pub outcome: NativeWorkOutcome,
}

#[derive(uniffi::Object)]
pub struct NativeWorkCoordinator {
    store: Mutex<SessionStore>,
    root: String,
}
#[uniffi::export]
impl NativeWorkCoordinator {
    #[uniffi::constructor]
    pub fn open(managed_root: String) -> Result<Arc<Self>, NativeStorageError> {
        let store = SessionStore::open(&managed_root).map_err(map_storage_error)?;
        Ok(Arc::new(Self {
            store: Mutex::new(store),
            root: managed_root,
        }))
    }
    pub fn request(
        &self,
        session_id: String,
        intent: NativeTranscriptionIntent,
    ) -> Result<(), NativeStorageError> {
        self.store
            .lock()
            .map_err(|_| NativeStorageError::StorageFailure)?
            .request_transcription(&SessionId(session_id), intent.into())
            .map_err(map_storage_error)
    }
    pub fn cancel(&self, session_id: String) -> Result<(), NativeStorageError> {
        self.store
            .lock()
            .map_err(|_| NativeStorageError::StorageFailure)?
            .cancel_transcription(&SessionId(session_id))
            .map_err(map_storage_error)
    }

    pub fn resume_replacement(&self, session_id: String) -> Result<(), NativeStorageError> {
        self.store
            .lock()
            .map_err(|_| NativeStorageError::StorageFailure)?
            .resume_replacement(&SessionId(session_id))
            .map_err(map_storage_error)
    }
    pub fn queue(
        &self,
        observations: NativeWorkObservations,
    ) -> Result<Vec<NativeTranscriptionWork>, NativeStorageError> {
        Ok(self
            .store
            .lock()
            .map_err(|_| NativeStorageError::StorageFailure)?
            .transcription_queue(observations.into())
            .map_err(map_storage_error)?
            .into_iter()
            .map(Into::into)
            .collect())
    }
    pub fn admit(
        &self,
        observations: NativeWorkObservations,
    ) -> Result<Option<NativeTranscriptionWork>, NativeStorageError> {
        Ok(self
            .store
            .lock()
            .map_err(|_| NativeStorageError::StorageFailure)?
            .admit_transcription(observations.into())
            .map_err(map_storage_error)?
            .map(Into::into))
    }
    pub fn finish(
        &self,
        admission: String,
        outcome: NativeWorkOutcome,
    ) -> Result<(), NativeStorageError> {
        self.store
            .lock()
            .map_err(|_| NativeStorageError::StorageFailure)?
            .finish_transcription(&admission, outcome.into())
            .map_err(map_storage_error)
    }
    pub fn outcomes(&self) -> Result<Vec<NativeSessionWorkOutcome>, NativeStorageError> {
        Ok(self
            .store
            .lock()
            .map_err(|_| NativeStorageError::StorageFailure)?
            .transcription_outcomes()
            .map_err(map_storage_error)?
            .into_iter()
            .map(|(session_id, outcome)| NativeSessionWorkOutcome {
                session_id,
                outcome: outcome.into(),
            })
            .collect())
    }
    /// Once per process after the capture-safety barrier. Uses its own handle;
    /// no coordinator mutex is held while reconciling retained hypotheses.
    pub fn recover_intent(&self) -> Result<(), NativeStorageError> {
        self.store
            .lock()
            .map_err(|_| NativeStorageError::StorageFailure)?
            .recover_transcription_admissions()
            .map_err(map_storage_error)
    }
    pub fn maintain_retained(
        &self,
        job: Arc<NativeTranscriptionJob>,
        observations: NativeWorkObservations,
    ) -> Result<NativeWorkOutcome, NativeStorageError> {
        let observations: WorkObservations = observations.into();
        {
            let store = self
                .store
                .lock()
                .map_err(|_| NativeStorageError::StorageFailure)?;
            if store.capture_active().map_err(map_storage_error)? || observations.capture_active {
                return Ok(NativeWorkOutcome::CapturePreempted);
            }
            if store.work_admission_active().map_err(map_storage_error)?
                || open_scribe_core::transcription_hold(
                    false,
                    TranscriptionIntent::ReconcileRetained,
                    observations,
                )
                .is_some()
            {
                return Ok(NativeWorkOutcome::Deferred);
            }
        }
        let mut controller = open_scribe_core::RecordingPreparationController::open(&self.root)
            .map_err(map_storage_error)?;
        let outcome = controller
            .maintain_transcripts_with_observations(job.cancellation(), observations)
            .map_err(map_storage_error)?;
        Ok(job.stop_outcome().unwrap_or_else(|| outcome.into()))
    }
}
