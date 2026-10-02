//! Native model catalog, verification, and installation policy.
//!
//! The checked `docs/models/manifest.v1.json` is the only catalog authority
//! (ADR 0008, ADR 0017). This crate never downloads: platform adapters move
//! bytes into a staging `.part` file, and this crate decides whether a
//! partial may resume, verifies completed bytes, and atomically installs a
//! verified artifact. Nothing here loads or executes a model.

mod catalog;
mod install;
mod verify;

pub use catalog::{Catalog, CatalogError, ModelHeader, ModelRecord};
pub use install::{
    InstallError, InstalledArtifact, ModelLayout, ResumeDecision, TransferValidator,
    resume_decision,
};
pub use verify::{VerifiedArtifact, VerifyError, verify_staged};

/// Observable model-manager states from ADR 0008. Model state never changes
/// session lifecycle or media durability.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum ModelState {
    Unavailable,
    Downloading,
    Verifying,
    Installed,
    Failed,
    Removing,
}

impl ModelState {
    pub const fn label(self) -> &'static str {
        match self {
            Self::Unavailable => "Unavailable",
            Self::Downloading => "Downloading",
            Self::Verifying => "Verifying",
            Self::Installed => "Installed",
            Self::Failed => "Failed",
            Self::Removing => "Removing",
        }
    }
}
