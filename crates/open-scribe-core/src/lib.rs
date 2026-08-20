//! Native durable-state and orchestration authority for Open Scribe.
//!
//! Milestone 0 exposes only an immutable capability snapshot. This crate has no
//! session operations and performs no persistence, capture, model, provider, or
//! network work.

/// Current non-media state owned by the Rust core.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct CoreStatus {
    pub product_name: &'static str,
    pub core_version: &'static str,
    pub persistence: &'static str,
    pub capture: &'static str,
    pub intelligence: &'static str,
}

/// Returns the immutable M0 capability posture without performing I/O.
#[must_use]
pub const fn status_snapshot() -> CoreStatus {
    CoreStatus {
        product_name: "Open Scribe",
        core_version: env!("CARGO_PKG_VERSION"),
        persistence: "Not implemented",
        capture: "Not implemented",
        intelligence: "Not implemented",
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn status_snapshot_reports_only_m0_posture() {
        let status = status_snapshot();

        assert_eq!(status.product_name, "Open Scribe");
        assert_eq!(status.core_version, env!("CARGO_PKG_VERSION"));
        assert_eq!(status.persistence, "Not implemented");
        assert_eq!(status.capture, "Not implemented");
        assert_eq!(status.intelligence, "Not implemented");
    }
}
