//! Coarse evidence citation, claim review, and resolution (ADR 0013).
//! References and claims cross as canonical JSON; Swift never assembles or
//! reinterprets their identity.

use super::*;
use open_scribe_core::{EvidenceKind, EvidenceRef, EvidenceRefError, ResolutionState};
use open_scribe_types::SessionId;

#[derive(Clone, Copy, Debug, Eq, PartialEq, uniffi::Enum)]
pub enum NativeEvidenceState {
    Available,
    Superseded,
    Missing,
    Deleted,
    IntegrityMismatch,
    UnsupportedVersion,
}

#[derive(Clone, Debug, Eq, PartialEq, uniffi::Record)]
pub struct NativeResolvedEvidence {
    pub state: NativeEvidenceState,
    /// `transcript_segment`, `audio_range`, `marker`, `human_correction`, or
    /// `context_event`; empty for an unsupported version.
    pub kind: String,
    pub session_id: String,
    /// The cited half-open session range.
    pub start_ns: i64,
    pub end_ns: i64,
    pub text: Option<String>,
    pub current_revision_id: Option<String>,
}

fn encode(reference: EvidenceRef) -> Result<String, NativeStorageError> {
    open_scribe_core::encode_evidence_ref(&reference).map_err(map_storage_error)
}

#[derive(Clone, Debug, Eq, PartialEq, uniffi::Record)]
pub struct NativeClaimTarget {
    pub side: String,
    pub state: NativeEvidenceState,
    pub record_id: String,
    pub start_ns: i64,
    pub end_ns: i64,
    pub text: Option<String>,
}

#[derive(Clone, Debug, Eq, PartialEq, uniffi::Record)]
pub struct NativeClaimNavigation {
    pub claim_id: String,
    pub revision_id: String,
    pub text: String,
    pub adjudication: Option<String>,
    pub targets: Vec<NativeClaimTarget>,
}

fn evidence_state(state: ResolutionState) -> NativeEvidenceState {
    match state {
        ResolutionState::Available => NativeEvidenceState::Available,
        ResolutionState::Superseded => NativeEvidenceState::Superseded,
        ResolutionState::Missing => NativeEvidenceState::Missing,
        ResolutionState::Deleted => NativeEvidenceState::Deleted,
        ResolutionState::IntegrityMismatch => NativeEvidenceState::IntegrityMismatch,
        ResolutionState::UnsupportedVersion => NativeEvidenceState::UnsupportedVersion,
    }
}

/// The same tokens `derived_claim_revisions.adjudication_action` stores.
fn adjudication_token(action: open_scribe_core::AdjudicationAction) -> &'static str {
    match action {
        open_scribe_core::AdjudicationAction::Accepted => "accepted",
        open_scribe_core::AdjudicationAction::Corrected => "corrected",
        open_scribe_core::AdjudicationAction::Rejected => "rejected",
        open_scribe_core::AdjudicationAction::Unresolved => "unresolved",
    }
}

#[uniffi::export]
impl NativeTranscriptLibrary {
    pub fn cite_context_event(
        &self,
        session_id: String,
        event_id: String,
        block: Option<u32>,
    ) -> Result<String, NativeStorageError> {
        encode(
            self.library()?
                .cite_context_event(
                    &SessionId(session_id),
                    &event_id,
                    block.map(|index| index as usize),
                )
                .map_err(map_storage_error)?,
        )
    }

    pub fn cite_transcript_segment(
        &self,
        session_id: String,
        revision_id: String,
        sequence: u32,
    ) -> Result<String, NativeStorageError> {
        encode(
            self.library()?
                .cite_transcript_segment(&SessionId(session_id), &revision_id, sequence)
                .map_err(map_storage_error)?,
        )
    }

    /// Re-reads the cited evidence. A malformed reference is an error; a
    /// newer schema version is reported as such.
    pub fn resolve_evidence(
        &self,
        reference_json: String,
    ) -> Result<NativeResolvedEvidence, NativeStorageError> {
        let reference = match EvidenceRef::parse(&reference_json) {
            Ok(reference) => reference,
            Err(EvidenceRefError::UnsupportedVersion) => {
                return Ok(NativeResolvedEvidence {
                    state: NativeEvidenceState::UnsupportedVersion,
                    kind: String::new(),
                    session_id: String::new(),
                    start_ns: 0,
                    end_ns: 0,
                    text: None,
                    current_revision_id: None,
                });
            }
            Err(_) => return Err(NativeStorageError::InvalidRequest),
        };
        let resolved = self
            .library()?
            .resolve_evidence(&reference)
            .map_err(map_storage_error)?;
        Ok(NativeResolvedEvidence {
            state: match resolved.state {
                ResolutionState::Available => NativeEvidenceState::Available,
                ResolutionState::Superseded => NativeEvidenceState::Superseded,
                ResolutionState::Missing => NativeEvidenceState::Missing,
                ResolutionState::Deleted => NativeEvidenceState::Deleted,
                ResolutionState::IntegrityMismatch => NativeEvidenceState::IntegrityMismatch,
                ResolutionState::UnsupportedVersion => NativeEvidenceState::UnsupportedVersion,
            },
            kind: match reference.kind {
                EvidenceKind::TranscriptSegment => "transcript_segment",
                EvidenceKind::AudioRange => "audio_range",
                EvidenceKind::Marker => "marker",
                EvidenceKind::HumanCorrection => "human_correction",
                EvidenceKind::ContextEvent => "context_event",
            }
            .to_owned(),
            session_id: reference.session_id,
            start_ns: reference.start_ns,
            end_ns: reference.end_ns,
            text: resolved.text,
            current_revision_id: resolved.current_revision_id,
        })
    }

    /// Confirms, corrects, or rejects the effective claim. `action` is
    /// `accepted`, `corrected`, or `rejected`. Rust chooses the new ids.
    /// A correction may replace the text; confirmation and rejection may not.
    /// Leaving a claim unresolved is not an action and writes nothing.
    pub fn adjudicate_derived_claim(
        &self,
        session_id: String,
        claim_id: String,
        action: String,
        text: Option<String>,
    ) -> Result<String, NativeStorageError> {
        let action = match action.as_str() {
            "accepted" => open_scribe_core::AdjudicationAction::Accepted,
            "corrected" => open_scribe_core::AdjudicationAction::Corrected,
            "rejected" => open_scribe_core::AdjudicationAction::Rejected,
            _ => return Err(NativeStorageError::InvalidRequest),
        };
        self.library()?
            .adjudicate_derived_claim(&SessionId(session_id), &claim_id, action, text.as_deref())
            .map_err(map_storage_error)
    }

    /// Accepts canonical `open-scribe.derived-claim/v1` JSON. Swift does not
    /// choose storage keys or rewrite the cited evidence.
    pub fn insert_derived_claim(&self, claim_json: String) -> Result<(), NativeStorageError> {
        let claim = open_scribe_core::DerivedClaim::parse(&claim_json)
            .map_err(|_| NativeStorageError::InvalidRequest)?;
        self.library()?
            .insert_derived_claim(&claim)
            .map_err(map_storage_error)
    }

    /// The meeting-memory revision a model delta must name. `"0"` means none yet.
    pub fn meeting_memory_revision(
        &self,
        session_id: String,
    ) -> Result<String, NativeStorageError> {
        self.library()?
            .meeting_memory_revision(&SessionId(session_id))
            .map_err(map_storage_error)
    }

    /// Accepts `open-scribe.meeting-memory-delta/v1`. Rust derives storage ids,
    /// receipts every operation, and does not replace a human adjudication.
    /// The returned text is the canonical receipt JSON.
    pub fn ingest_meeting_memory_delta(
        &self,
        delta_json: String,
    ) -> Result<String, NativeStorageError> {
        self.library()?
            .ingest_meeting_memory_delta(&delta_json)
            .map_err(map_storage_error)
    }

    /// Effective canonical claims as a JSON array. Swift displays this projection
    /// and passes a claim id back to navigation. It does not assemble identity.
    pub fn effective_derived_claims(
        &self,
        session_id: String,
    ) -> Result<String, NativeStorageError> {
        self.library()?
            .effective_derived_claims(&SessionId(session_id))
            .map_err(map_storage_error)
    }

    /// Opens the effective claim. A later model revision does not replace a
    /// human acceptance, correction, or rejection.
    pub fn navigate_derived_claim(
        &self,
        session_id: String,
        claim_id: String,
    ) -> Result<NativeClaimNavigation, NativeStorageError> {
        let navigation = self
            .library()?
            .navigate_derived_claim(&SessionId(session_id), &claim_id)
            .map_err(map_storage_error)?;
        Ok(NativeClaimNavigation {
            claim_id: navigation.claim_id,
            revision_id: navigation.revision_id,
            text: navigation.text,
            adjudication: navigation
                .adjudication
                .map(|action| adjudication_token(action).to_owned()),
            targets: navigation
                .targets
                .into_iter()
                .map(|target| NativeClaimTarget {
                    side: match target.side {
                        open_scribe_core::ClaimEvidenceSide::Supporting => "supporting",
                        open_scribe_core::ClaimEvidenceSide::Contradicting => "contradicting",
                    }
                    .to_owned(),
                    state: evidence_state(target.state),
                    record_id: target.record_id,
                    start_ns: target.start_ns,
                    end_ns: target.end_ns,
                    text: target.text,
                })
                .collect(),
        })
    }
}
