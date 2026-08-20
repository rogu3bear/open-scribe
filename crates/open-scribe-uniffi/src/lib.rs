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
    NativeStatus {
        product_name: "Open Scribe".to_owned(),
        core_version: env!("CARGO_PKG_VERSION").to_owned(),
        persistence: "Not implemented".to_owned(),
        capture: "Not implemented".to_owned(),
        intelligence: "Not implemented".to_owned(),
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
        assert_eq!(status.core_version, env!("CARGO_PKG_VERSION"));
        assert_eq!(status.persistence, "Not implemented");
        assert_eq!(status.capture, "Not implemented");
        assert_eq!(status.intelligence, "Not implemented");
    }
}
