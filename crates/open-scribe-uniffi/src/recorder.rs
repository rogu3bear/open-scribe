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
    pub kind: String,
    pub session_nanoseconds: i64,
    pub label: String,
}

#[derive(uniffi::Record)]
pub struct NativeRecorderDetail {
    pub lifecycle: String,
    pub captured_nanoseconds: i64,
    pub storage_level: String,
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
                kind: kind.map(|k| match k {
                    NativeMediaSourceKind::Microphone => {
                        open_scribe_core::MediaSourceKind::Microphone
                    }
                    NativeMediaSourceKind::SystemAudio => {
                        open_scribe_core::MediaSourceKind::SystemAudio
                    }
                    NativeMediaSourceKind::ApplicationAudio => {
                        open_scribe_core::MediaSourceKind::ApplicationAudio
                    }
                }),
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
            lifecycle: value.lifecycle,
            captured_nanoseconds: value.captured_nanoseconds,
            storage_level: value.storage_level,
            events: value
                .events
                .into_iter()
                .map(|e| NativeRecorderEvent {
                    id: e.id,
                    kind: e.kind,
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
            .recorder_action(open_scribe_types::SessionId(session_id), action.into())
            .map(Into::into)
            .map_err(map_storage_error)
    }
    pub fn recorder_detail(
        &self,
        session_id: String,
    ) -> Result<NativeRecorderDetail, NativeStorageError> {
        self.controller()?
            .recorder_detail(open_scribe_types::SessionId(session_id))
            .map(Into::into)
            .map_err(map_storage_error)
    }

    /// One sealed provisional window. Probabilities stay unset: the capture
    /// writer does not invent a recognizer score. Empty text is still rejected
    /// by the store.
    pub fn commit_live_draft_window(
        &self,
        session_id: String,
        track_id: String,
        start_nanoseconds: i64,
        end_nanoseconds: i64,
        text: String,
        engine: String,
        engine_version: String,
        model_id: String,
        model_sha256: String,
        options_digest: String,
        reconciliation_version: String,
    ) -> Result<String, NativeStorageError> {
        let window = open_scribe_core::LiveDraftWindow {
            session_id: open_scribe_types::SessionId(session_id),
            track_id,
            start_nanoseconds,
            end_nanoseconds,
            text,
            mean_probability: None,
            no_speech_probability: None,
            engine,
            engine_version,
            model_id,
            model_sha256,
            options_digest,
            reconciliation_version,
        };
        self.controller()?
            .commit_live_draft_window(window)
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
