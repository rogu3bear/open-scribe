//! Validation for `open-scribe.derived-claim/v1` (ADR 0013).
//!
//! A claim cites evidence; it does not replace it. Human adjudication is a
//! new revision. The original revision stays intact for the caller to keep.
use crate::{EvidenceRef, EvidenceRefError, identifier_is_valid};
use serde::{Deserialize, Serialize};

pub const DERIVED_CLAIM_SCHEMA: &str = "open-scribe.derived-claim/v1";

#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum ClaimKind {
    Fact,
    Decision,
    Commitment,
    Question,
    OpenLoop,
    LooseEnd,
    Topic,
    NumberOrTerm,
    SummaryStatement,
}

#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum ClaimStatus {
    Mentioned,
    Proposed,
    Agreed,
    Assigned,
    Accepted,
    Completed,
    Contradicted,
    Superseded,
    Unresolved,
    Unknown,
    Open,
    Answered,
    Closed,
    /// Human draft only. It is not settled memory.
    Unsupported,
}

#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum ClaimProducer {
    Human,
    ModelRun,
}

#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum AdjudicationAction {
    Accepted,
    Corrected,
    Rejected,
    Unresolved,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(deny_unknown_fields)]
pub struct Adjudication {
    pub id: String,
    pub action: AdjudicationAction,
    pub claim_revision_id: String,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(deny_unknown_fields)]
pub struct DerivedClaim {
    pub schema: String,
    pub claim_id: String,
    pub revision_id: String,
    pub session_id: String,
    pub kind: ClaimKind,
    pub text: String,
    pub status: ClaimStatus,
    pub supporting: Vec<EvidenceRef>,
    pub contradicting: Vec<EvidenceRef>,
    pub producer: ClaimProducer,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub adjudication: Option<Adjudication>,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum ClaimError {
    Malformed,
    UnsupportedVersion,
    InvalidIdentifier,
    InvalidText,
    StatusNotAllowed,
    UnsupportedMaterial,
    Evidence(EvidenceRefError),
    CrossSession,
    AdjudicationMismatch,
}

impl DerivedClaim {
    pub fn validate(&self) -> Result<(), ClaimError> {
        if self.schema != DERIVED_CLAIM_SCHEMA {
            return Err(ClaimError::UnsupportedVersion);
        }
        if !identifier_is_valid(&self.claim_id)
            || !identifier_is_valid(&self.revision_id)
            || !identifier_is_valid(&self.session_id)
        {
            return Err(ClaimError::InvalidIdentifier);
        }
        if !text_is_valid(&self.text) {
            return Err(ClaimError::InvalidText);
        }
        if !status_allowed(self.kind, self.status) {
            return Err(ClaimError::StatusNotAllowed);
        }
        if self.status == ClaimStatus::Unsupported && self.producer != ClaimProducer::Human {
            return Err(ClaimError::UnsupportedMaterial);
        }
        for reference in self.supporting.iter().chain(self.contradicting.iter()) {
            reference.validate().map_err(ClaimError::Evidence)?;
            if reference.session_id != self.session_id {
                return Err(ClaimError::CrossSession);
            }
        }
        if self.requires_support() && self.supporting.is_empty() {
            return Err(ClaimError::UnsupportedMaterial);
        }
        if let Some(adjudication) = &self.adjudication {
            if !identifier_is_valid(&adjudication.id)
                || adjudication.claim_revision_id != self.revision_id
            {
                return Err(ClaimError::AdjudicationMismatch);
            }
        }
        Ok(())
    }

    /// Settled memory needs support. A human "unsupported" draft is review
    /// material, not a canonical claim.
    pub fn is_canonical(&self) -> bool {
        self.validate().is_ok()
            && self.status != ClaimStatus::Unsupported
            && !self.supporting.is_empty()
    }

    pub fn parse(json: &str) -> Result<Self, ClaimError> {
        let claim: Self = serde_json::from_str(json).map_err(|_| ClaimError::Malformed)?;
        claim.validate()?;
        Ok(claim)
    }

    /// Append a human adjudication as a new revision. `self` is not changed.
    pub fn with_adjudication(
        &self,
        action: AdjudicationAction,
        revision_id: impl Into<String>,
        adjudication_id: impl Into<String>,
    ) -> Result<Self, ClaimError> {
        self.validate()?;
        let revision_id = revision_id.into();
        let adjudication_id = adjudication_id.into();
        if !identifier_is_valid(&revision_id)
            || !identifier_is_valid(&adjudication_id)
            || revision_id == self.revision_id
        {
            return Err(ClaimError::InvalidIdentifier);
        }
        let mut revised = self.clone();
        revised.revision_id = revision_id;
        revised.adjudication = Some(Adjudication {
            id: adjudication_id,
            action,
            claim_revision_id: revised.revision_id.clone(),
        });
        revised.validate()?;
        Ok(revised)
    }

    fn requires_support(&self) -> bool {
        self.producer == ClaimProducer::ModelRun || self.status != ClaimStatus::Unsupported
    }
}

pub(crate) fn claim_text_is_valid(value: &str) -> bool {
    text_is_valid(value)
}

pub fn claim_status_allowed(kind: ClaimKind, status: ClaimStatus) -> bool {
    status_allowed(kind, status)
}

fn text_is_valid(value: &str) -> bool {
    let trimmed = value.trim();
    !trimmed.is_empty()
        && trimmed.len() <= 4_000
        && trimmed
            .chars()
            .all(|character| character == '\n' || character == '\t' || !character.is_control())
}

fn status_allowed(kind: ClaimKind, status: ClaimStatus) -> bool {
    use ClaimKind::*;
    use ClaimStatus::*;
    match kind {
        Decision => matches!(
            status,
            Mentioned | Proposed | Agreed | Contradicted | Superseded | Unknown | Unsupported
        ),
        Commitment => matches!(
            status,
            Mentioned
                | Proposed
                | Assigned
                | Accepted
                | Completed
                | Contradicted
                | Unresolved
                | Unknown
                | Unsupported
        ),
        Fact | Topic | NumberOrTerm | SummaryStatement => {
            matches!(
                status,
                Mentioned | Contradicted | Unresolved | Unknown | Unsupported
            )
        }
        Question | OpenLoop => matches!(
            status,
            Open | Answered | Closed | Contradicted | Unknown | Unsupported
        ),
        LooseEnd => matches!(status, Open | Closed | Unresolved | Unknown | Unsupported),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{EVIDENCE_REF_SCHEMA, EvidenceKind};

    fn evidence(session: &str) -> EvidenceRef {
        EvidenceRef {
            schema: EVIDENCE_REF_SCHEMA.into(),
            session_id: session.into(),
            kind: EvidenceKind::TranscriptSegment,
            record_id: "track-1".into(),
            revision_id: Some("revision-1".into()),
            start_ns: 0,
            end_ns: 1_000,
            sub_item: Some("0".into()),
            content_digest: "ab".repeat(32),
            resolver_hint: None,
        }
    }

    fn decision(producer: ClaimProducer, supporting: Vec<EvidenceRef>) -> DerivedClaim {
        DerivedClaim {
            schema: DERIVED_CLAIM_SCHEMA.into(),
            claim_id: "claim-1".into(),
            revision_id: "revision-a".into(),
            session_id: "session-1".into(),
            kind: ClaimKind::Decision,
            text: "Ship the local recorder".into(),
            status: ClaimStatus::Agreed,
            supporting,
            contradicting: Vec::new(),
            producer,
            adjudication: None,
        }
    }

    #[test]
    fn a_supported_claim_round_trips_and_names_its_evidence() {
        let claim = decision(ClaimProducer::Human, vec![evidence("session-1")]);
        claim.validate().unwrap();
        assert!(claim.is_canonical());
        let parsed = DerivedClaim::parse(&serde_json::to_string(&claim).unwrap()).unwrap();
        assert_eq!(parsed, claim);
        assert_eq!(
            parsed.supporting[0].content_digest,
            claim.supporting[0].content_digest
        );
        assert_eq!(parsed.supporting[0].record_id, "track-1");
    }

    #[test]
    fn model_material_without_support_is_rejected_and_human_adjudication_keeps_the_original() {
        let unsupported = decision(ClaimProducer::ModelRun, Vec::new());
        assert_eq!(unsupported.validate(), Err(ClaimError::UnsupportedMaterial));
        let mut draft = decision(ClaimProducer::Human, Vec::new());
        draft.status = ClaimStatus::Unsupported;
        draft.validate().unwrap();
        assert!(!draft.is_canonical());

        let original = decision(ClaimProducer::Human, vec![evidence("session-1")]);
        let revised = original
            .with_adjudication(AdjudicationAction::Rejected, "revision-b", "adjudication-1")
            .unwrap();
        assert_eq!(original.revision_id, "revision-a");
        assert!(original.adjudication.is_none());
        assert_eq!(revised.revision_id, "revision-b");
        assert_eq!(revised.supporting, original.supporting);
        assert_eq!(
            revised.adjudication.unwrap().action,
            AdjudicationAction::Rejected
        );
        assert_eq!(original.text, revised.text);
    }

    #[test]
    fn wrong_status_cross_session_and_unknown_fields_fail() {
        let mut agreed = decision(ClaimProducer::Human, vec![evidence("session-1")]);
        agreed.kind = ClaimKind::Fact;
        assert_eq!(agreed.validate(), Err(ClaimError::StatusNotAllowed));

        let mut foreign = decision(ClaimProducer::Human, vec![evidence("other-session")]);
        foreign.supporting[0].session_id = "other-session".into();
        assert_eq!(foreign.validate(), Err(ClaimError::CrossSession));

        let extra =
            serde_json::to_string(&decision(ClaimProducer::Human, vec![evidence("session-1")]))
                .unwrap()
                .replace("\"schema\"", "\"confidence\":0.9,\"schema\"");
        assert_eq!(DerivedClaim::parse(&extra), Err(ClaimError::Malformed));
    }
}
