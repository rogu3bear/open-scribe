//! Deterministic operational vocabulary; no storage, platform, or model runtime.
#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub enum DocumentAvailability {
    #[default]
    None,
    Partial,
    Final,
    Unavailable,
}
#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub enum TranscriptionIntent {
    #[default]
    ResumeIncomplete,
    ReconcileRetained,
    ReprocessAll,
}
impl TranscriptionIntent {
    pub const fn code(self) -> &'static str {
        match self {
            Self::ResumeIncomplete => "resume",
            Self::ReconcileRetained => "reconcile",
            Self::ReprocessAll => "reprocess",
        }
    }
    pub fn from_code(code: &str) -> Option<Self> {
        match code {
            "resume" => Some(Self::ResumeIncomplete),
            "reconcile" => Some(Self::ReconcileRetained),
            "reprocess" => Some(Self::ReprocessAll),
            _ => None,
        }
    }
}
#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub enum AttemptState {
    #[default]
    None,
    Running,
    Complete,
    Failed,
    Cancelled,
    Preempted,
    Unknown,
}
impl AttemptState {
    pub fn from_code(code: &str) -> Self {
        match code {
            "none" => Self::None,
            "running" => Self::Running,
            "complete" => Self::Complete,
            "failed" => Self::Failed,
            "cancelled" => Self::Cancelled,
            "preempted" => Self::Preempted,
            _ => Self::Unknown,
        }
    }
}
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum WorkOutcome {
    Completed,
    UserCancelled,
    CapturePreempted,
    Failed,
    Deferred,
}
impl WorkOutcome {
    pub const fn code(self) -> &'static str {
        match self {
            Self::Completed => "completed",
            Self::UserCancelled => "cancelled",
            Self::CapturePreempted => "preempted",
            Self::Failed => "failed",
            Self::Deferred => "deferred",
        }
    }
    pub fn from_code(code: &str) -> Option<Self> {
        match code {
            "completed" => Some(Self::Completed),
            "cancelled" => Some(Self::UserCancelled),
            "preempted" => Some(Self::CapturePreempted),
            "failed" => Some(Self::Failed),
            "deferred" => Some(Self::Deferred),
            _ => None,
        }
    }
}
#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub enum ModelReadiness {
    #[default]
    Absent,
    PresentUnverified,
    Verifying,
    Ready,
    Invalid,
    Incompatible,
}
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum WorkHold {
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
    AlreadyRunning,
}
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct WorkObservations {
    pub automatic: bool,
    pub paused: bool,
    pub capture_active: bool,
    pub media_recovery_pending: bool,
    pub model: ModelReadiness,
    pub available_disk_bytes: Option<u64>,
    pub memory_critical: bool,
    pub thermal_critical: bool,
}
impl Default for WorkObservations {
    fn default() -> Self {
        Self {
            automatic: true,
            paused: false,
            capture_active: false,
            media_recovery_pending: false,
            model: ModelReadiness::Absent,
            available_disk_bytes: None,
            memory_critical: false,
            thermal_critical: false,
        }
    }
}
