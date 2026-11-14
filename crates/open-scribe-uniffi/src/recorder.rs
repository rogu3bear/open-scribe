use super::*;

#[derive(uniffi::Enum)]
pub enum NativeRecorderAction {
    BeginPause,
    CompletePause {
        host_time: u64,
    },
    PrepareResume,
    AnchorResume {
        host_time: u64,
    },
    FinishPaused,
    Marker {
        host_time: u64,
        label: String,
    },
    SelectAudio {
        kind: Option<NativeMediaSourceKind>,
        identity: String,
        display_name: String,
    },
    ObserveStorage {
        available_bytes: u64,
    },
    ObserveSystemPower {
        host_time: u64,
        asleep: bool,
    },
    RestoreMicrophone,
    CancelMicrophoneRestore,
    RetireUnstartedMicrophone,
}

#[derive(uniffi::Record)]
pub struct NativeRecorderEvent {
    pub id: String,
    pub kind: NativeRecorderEventKind,
    pub session_nanoseconds: i64,
    pub label: String,
}

/// One provisional caption window and the engine identity that produced it.
#[derive(uniffi::Record)]
pub struct NativeLiveDraftWindow {
    pub session_id: String,
    pub track_id: String,
    pub start_nanoseconds: i64,
    pub end_nanoseconds: i64,
    pub text: String,
    pub engine: String,
    pub engine_version: String,
    pub model_id: String,
    pub model_sha256: String,
    pub options_digest: String,
    pub reconciliation_version: String,
}

impl From<NativeLiveDraftWindow> for open_scribe_core::LiveDraftWindow {
    fn from(value: NativeLiveDraftWindow) -> Self {
        Self {
            session_id: open_scribe_types::SessionId(value.session_id),
            track_id: value.track_id,
            start_nanoseconds: value.start_nanoseconds,
            end_nanoseconds: value.end_nanoseconds,
            text: value.text,
            mean_probability: None,
            no_speech_probability: None,
            engine: value.engine,
            engine_version: value.engine_version,
            model_id: value.model_id,
            model_sha256: value.model_sha256,
            options_digest: value.options_digest,
            reconciliation_version: value.reconciliation_version,
        }
    }
}

#[derive(uniffi::Record)]
pub struct NativeRecorderDetail {
    pub lifecycle: NativeSessionLifecycle,
    pub captured_nanoseconds: i64,
    pub storage_level: NativeStorageLevel,
    pub events: Vec<NativeRecorderEvent>,
}

impl From<NativeRecorderAction> for open_scribe_core::RecorderAction {
    fn from(value: NativeRecorderAction) -> Self {
        match value {
            NativeRecorderAction::BeginPause => Self::BeginPause,
            NativeRecorderAction::CompletePause { host_time } => Self::CompletePause { host_time },
            NativeRecorderAction::PrepareResume => Self::PrepareResume,
            NativeRecorderAction::AnchorResume { host_time } => Self::AnchorResume { host_time },
            NativeRecorderAction::FinishPaused => Self::FinishPaused,
            NativeRecorderAction::Marker { host_time, label } => Self::Marker { host_time, label },
            NativeRecorderAction::SelectAudio {
                kind,
                identity,
                display_name,
            } => Self::SelectAudio {
                kind: kind.map(Into::into),
                identity,
                display_name,
            },
            NativeRecorderAction::ObserveStorage { available_bytes } => {
                Self::ObserveStorage { available_bytes }
            }
            NativeRecorderAction::ObserveSystemPower { host_time, asleep } => {
                Self::ObserveSystemPower { host_time, asleep }
            }
            NativeRecorderAction::RestoreMicrophone => Self::RestoreMicrophone,
            NativeRecorderAction::CancelMicrophoneRestore => Self::CancelMicrophoneRestore,
            NativeRecorderAction::RetireUnstartedMicrophone => Self::RetireUnstartedMicrophone,
        }
    }
}

impl From<open_scribe_core::RecorderDetail> for NativeRecorderDetail {
    fn from(value: open_scribe_core::RecorderDetail) -> Self {
        Self {
            lifecycle: value.lifecycle.into(),
            captured_nanoseconds: value.captured_nanoseconds,
            storage_level: value.storage_level.into(),
            events: value
                .events
                .into_iter()
                .map(|e| NativeRecorderEvent {
                    id: e.id,
                    kind: e.kind.into(),
                    session_nanoseconds: e.session_nanoseconds,
                    label: e.label,
                })
                .collect(),
        }
    }
}

#[uniffi::export]
impl NativeRecordingPreparation {
    pub fn recorder_action(
        &self,
        session_id: String,
        action: NativeRecorderAction,
    ) -> Result<NativeRecorderDetail, NativeStorageError> {
        self.controller()?
            .store_mut()
            .recorder_action(open_scribe_types::SessionId(session_id), action.into())
            .map(Into::into)
            .map_err(map_storage_error)
    }
    pub fn recorder_detail(
        &self,
        session_id: String,
    ) -> Result<NativeRecorderDetail, NativeStorageError> {
        self.controller()?
            .store()
            .recorder_detail(&open_scribe_types::SessionId(session_id))
            .map(Into::into)
            .map_err(map_storage_error)
    }

    /// One sealed provisional window. Probabilities stay unset: the capture
    /// writer does not invent a recognizer score. Empty text is still rejected
    /// by the store.
    pub fn commit_live_draft_window(
        &self,
        window: NativeLiveDraftWindow,
    ) -> Result<String, NativeStorageError> {
        self.controller()?
            .store_mut()
            .commit_live_draft_window(&window.into())
            .map_err(map_storage_error)
    }

    pub fn readable_draft_texts(
        &self,
        session_id: String,
    ) -> Result<Vec<String>, NativeStorageError> {
        self.controller()?
            .readable_draft_texts(&open_scribe_types::SessionId(session_id))
            .map_err(map_storage_error)
    }
}
