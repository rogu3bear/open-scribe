//! WASM-safe stable session records shared across Open Scribe surfaces.

#![forbid(unsafe_code)]

/// Stable identity for one conversation session.
#[derive(Clone, Debug, Eq, Hash, PartialEq)]
pub struct SessionId(pub String);

/// Stable identity for one requested or active source.
#[derive(Clone, Debug, Eq, Hash, PartialEq)]
pub struct SourceId(pub String);

/// Durable lifecycle persisted by Rust. Transitional UI states do not belong here.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum Lifecycle {
    Idle,
    Ready,
    Recording,
    Paused,
    Finalizing,
    ReadyForReview,
    Interrupted,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum SourceKind {
    Microphone,
    ApplicationAudio,
    SystemAudio,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum SourceActivity {
    Selected,
    Active,
    Paused,
    Failed,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum PermissionState {
    NotRequested,
    Granted,
    Denied,
    Revoked,
    Restricted,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct PermissionRecord {
    pub state: PermissionState,
    pub recovery_hint: Option<String>,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum SourceHealth {
    Healthy,
    Failed,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct SourceRecord {
    pub id: SourceId,
    pub name: String,
    pub kind: SourceKind,
    pub activity: SourceActivity,
    pub health: SourceHealth,
    pub health_detail: Option<String>,
    pub permission: PermissionRecord,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum SessionHealth {
    Healthy,
    Degraded,
}

/// Evidence that must exist before Rust may enter `Lifecycle::Recording`.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct DurabilityRecord {
    pub journal_durable: bool,
    pub media_files_open: bool,
    pub media_safe: bool,
}

impl DurabilityRecord {
    #[must_use]
    pub const fn permits_recording(self) -> bool {
        self.journal_durable && self.media_files_open
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum RecoveryStatus {
    NotRequired,
    Required,
    Deferred,
    Recovered,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct RecoveryRecord {
    pub status: RecoveryStatus,
    pub preserved_evidence_summary: Option<String>,
}

/// Stable Rust-owned record. Presentation labels, symbols, and transient progress
/// are derived by `open-scribe-domain` and are never persisted as lifecycle truth.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct SessionRecord {
    pub id: SessionId,
    pub title: String,
    pub lifecycle: Lifecycle,
    pub health: SessionHealth,
    pub elapsed_seconds: u64,
    pub sources: Vec<SourceRecord>,
    pub durability: DurabilityRecord,
    pub recovery: RecoveryRecord,
}
