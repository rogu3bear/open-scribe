//! Coarse Swift/Rust control boundary for the Milestone 0 native proof.
//!
//! This crate intentionally exposes one immutable, non-media snapshot. It has
//! no capture, persistence, provider, model, or session operations.

/// Non-media state used to prove the native Rust-to-Swift boundary.
#[derive(Clone, Debug, Eq, PartialEq, uniffi::Record)]
pub struct NativeStatus {
    pub product_name: String,
    pub core_version: String,
    pub persistence: String,
    pub capture: String,
    pub intelligence: String,
}

/// Returns the current M0 capability posture as one coarse query.
#[uniffi::export]
pub fn native_status() -> NativeStatus {
    let status = open_scribe_core::status_snapshot();

    NativeStatus {
        product_name: status.product_name.to_owned(),
        core_version: status.core_version.to_owned(),
        persistence: status.persistence.to_owned(),
        capture: status.capture.to_owned(),
        intelligence: status.intelligence.to_owned(),
    }
}

uniffi::setup_scaffolding!();

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn native_status_is_truthful_and_non_media() {
        let status = native_status();

        assert_eq!(status.product_name, "Open Scribe");
        assert_eq!(
            status.core_version,
            open_scribe_core::status_snapshot().core_version
        );
        assert_eq!(status.persistence, "Not implemented");
        assert_eq!(status.capture, "Not implemented");
        assert_eq!(status.intelligence, "Not implemented");
    }
}
