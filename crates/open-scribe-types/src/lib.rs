//! WASM-safe stable session records shared across Open Scribe surfaces.

#![forbid(unsafe_code)]

mod capability;
mod work;
pub use capability::{NO_PUBLIC_RELEASE, public_capability_label};
pub use work::{
    AttemptState, DocumentAvailability, ModelReadiness, TranscriptionIntent, WorkHold,
    WorkObservations, WorkOutcome,
};

/// Every managed PCM file, captured or imported, is 48 kHz. The native
/// writers, the store's timeline arithmetic and the recognizer's decimator
/// all read this one value.
pub const MEDIA_SAMPLE_RATE_HZ: u32 = 48_000;

/// Lowercase hexadecimal: the encoding of every stored, exported and
/// manifest digest.
#[must_use]
pub fn lowercase_hex(bytes: &[u8]) -> String {
    const DIGITS: &[u8; 16] = b"0123456789abcdef";
    let mut out = String::with_capacity(bytes.len() * 2);
    for byte in bytes {
        out.push(char::from(DIGITS[usize::from(byte >> 4)]));
        out.push(char::from(DIGITS[usize::from(byte & 0x0f)]));
    }
    out
}

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

/// One capture source kind. `as_str` is the token stored in SQLite, journal
/// payloads and exports.
#[derive(Clone, Copy, Debug, Eq, Hash, PartialEq)]
pub enum SourceKind {
    Microphone,
    ApplicationAudio,
    SystemAudio,
}

impl SourceKind {
    pub const ALL: [Self; 3] = [Self::Microphone, Self::ApplicationAudio, Self::SystemAudio];

    #[must_use]
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::Microphone => "microphone",
            Self::ApplicationAudio => "application_audio",
            Self::SystemAudio => "system_audio",
        }
    }

    #[must_use]
    pub fn parse(value: &str) -> Option<Self> {
        Self::ALL.into_iter().find(|kind| kind.as_str() == value)
    }
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

#[cfg(test)]
mod tests {
    #[test]
    fn lowercase_hex_writes_two_lowercase_digits_per_byte() {
        assert_eq!(super::lowercase_hex(&[]), "");
        assert_eq!(super::lowercase_hex(&[0x00, 0x0f, 0xa0, 0xff]), "000fa0ff");
    }
}
