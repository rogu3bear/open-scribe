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
}
