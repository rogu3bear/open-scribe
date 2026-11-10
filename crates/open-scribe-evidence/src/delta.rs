//! Validation for `open-scribe.meeting-memory-delta/v1` (ADR 0013).
//!
//! A model proposes claim operations. It does not write evidence, choose
//! storage keys, or adjudicate. The store decides which operations append a
//! revision and receipts every one.

use super::claim::{claim_status_allowed, claim_text_is_valid};
use crate::{ClaimKind, ClaimStatus, EvidenceRef, identifier_is_valid};
use serde::{Deserialize, Serialize};
use serde_json::Value;

pub const MEETING_MEMORY_DELTA_SCHEMA: &str = "open-scribe.meeting-memory-delta/v1";
pub const MEETING_MEMORY_DELTA_RECEIPT_SCHEMA: &str = "open-scribe.meeting-memory-delta-receipt/v1";
pub const MAX_DELTA_BYTES: usize = 256 * 1024;
pub const MAX_DELTA_OPERATIONS: usize = 32;
pub const MAX_DELTA_DEPTH: usize = 16;

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(deny_unknown_fields)]
pub struct MeetingMemoryDelta {
    pub schema: String,
    pub model_run_id: String,
    pub input_manifest_digest: String,
    pub session_id: String,
    pub base_revision: String,
    pub operations: Vec<DeltaOperation>,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(tag = "op", rename_all = "snake_case", deny_unknown_fields)]
pub enum DeltaOperation {
    ProposeClaim {
        operation_id: String,
        kind: ClaimKind,
        text: String,
        status: ClaimStatus,
        supporting: Vec<EvidenceRef>,
        contradicting: Vec<EvidenceRef>,
    },
    ReviseClaim {
        operation_id: String,
        claim_id: String,
        kind: ClaimKind,
        text: String,
        status: ClaimStatus,
        supporting: Vec<EvidenceRef>,
        contradicting: Vec<EvidenceRef>,
    },
    ChangeRelations {
        operation_id: String,
        claim_id: String,
        status: ClaimStatus,
        supporting: Vec<EvidenceRef>,
        contradicting: Vec<EvidenceRef>,
    },
    ResolutionSearch {
        operation_id: String,
        claim_id: String,
        status: ClaimStatus,
        note: String,
    },
    Supersede {
        operation_id: String,
        claim_id: String,
        superseded_by: String,
    },
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(deny_unknown_fields)]
pub struct DeltaOperationReceipt {
    pub operation_id: String,
    pub outcome: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub reason: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub claim_id: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub revision_id: Option<String>,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(deny_unknown_fields)]
pub struct DeltaIngestReceipt {
    pub schema: String,
    pub receipt_id: String,
    pub session_id: String,
    pub model_run_id: String,
    pub base_revision: String,
    pub next_revision: String,
    pub operations: Vec<DeltaOperationReceipt>,
}

/// Display projection of one effective claim. Rust fills every field.
#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(deny_unknown_fields)]
pub struct DerivedClaimSummary {
    pub claim_id: String,
    pub revision_id: String,
    pub kind: String,
    pub status: String,
    pub text: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub adjudication: Option<String>,
    pub supporting_count: u32,
    pub contradicting_count: u32,
    /// `model_run` or `human`. Empty when an older projection omitted it.
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub producer: String,
    /// Supporting and contradicting ranges. This is not the cited words.
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub evidence: String,
    /// The meeting-memory run that accepted this claim, when one was stored.
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub model_run_id: String,
    /// Input manifest digest of that run. Empty when no run was stored.
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub input_digest: String,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum DeltaError {
    Malformed,
    UnsupportedVersion,
    Oversized,
    TooDeep,
    InvalidIdentifier,
    DuplicateOperation,
    CrossSession,
    InvalidDigest,
    Empty,
    Evidence,
    InvalidText,
    StatusNotAllowed,
    UnsupportedMaterial,
}

impl MeetingMemoryDelta {
    pub fn parse(json: &str) -> Result<Self, DeltaError> {
        if json.len() > MAX_DELTA_BYTES {
            return Err(DeltaError::Oversized);
        }
        let value: Value = serde_json::from_str(json).map_err(|_| DeltaError::Malformed)?;
        if json_depth(&value) > MAX_DELTA_DEPTH {
            return Err(DeltaError::TooDeep);
        }
        let delta: Self = serde_json::from_value(value).map_err(|_| DeltaError::Malformed)?;
        delta.validate()?;
        Ok(delta)
    }

    pub fn validate(&self) -> Result<(), DeltaError> {
        if self.schema != MEETING_MEMORY_DELTA_SCHEMA {
            return Err(DeltaError::UnsupportedVersion);
        }
        if !identifier_is_valid(&self.model_run_id)
            || !identifier_is_valid(&self.session_id)
            || !identifier_is_valid(&self.base_revision)
        {
            return Err(DeltaError::InvalidIdentifier);
        }
        if !digest_is_valid(&self.input_manifest_digest) {
            return Err(DeltaError::InvalidDigest);
        }
        if self.operations.is_empty() {
            return Err(DeltaError::Empty);
        }
        if self.operations.len() > MAX_DELTA_OPERATIONS {
            return Err(DeltaError::Oversized);
        }
        let mut seen = std::collections::BTreeSet::new();
        for operation in &self.operations {
            let operation_id = operation.operation_id();
            if !identifier_is_valid(operation_id) || !seen.insert(operation_id.to_owned()) {
                return Err(DeltaError::DuplicateOperation);
            }
            operation.validate(&self.session_id)?;
        }
        Ok(())
    }
}

impl DeltaOperation {
    pub fn operation_id(&self) -> &str {
        match self {
            Self::ProposeClaim { operation_id, .. }
            | Self::ReviseClaim { operation_id, .. }
            | Self::ChangeRelations { operation_id, .. }
            | Self::ResolutionSearch { operation_id, .. }
            | Self::Supersede { operation_id, .. } => operation_id,
        }
    }

    fn validate(&self, session_id: &str) -> Result<(), DeltaError> {
        match self {
            Self::ProposeClaim {
                kind,
                text,
                status,
                supporting,
                contradicting,
                ..
            }
            | Self::ReviseClaim {
                kind,
                text,
                status,
                supporting,
                contradicting,
                ..
            } => {
                if let Self::ReviseClaim { claim_id, .. } = self {
                    if !identifier_is_valid(claim_id) {
                        return Err(DeltaError::InvalidIdentifier);
                    }
                }
                validate_material(*kind, *status, text, supporting, contradicting, session_id)
            }
            Self::ChangeRelations {
                claim_id,
                status,
                supporting,
                contradicting,
                ..
            } => {
                if !identifier_is_valid(claim_id) {
                    return Err(DeltaError::InvalidIdentifier);
                }
                if *status == ClaimStatus::Unsupported {
                    return Err(DeltaError::UnsupportedMaterial);
                }
                if !status_allowed_for_any(*status) {
                    return Err(DeltaError::StatusNotAllowed);
                }
                validate_refs(supporting, contradicting, session_id)
            }
            Self::ResolutionSearch {
                claim_id,
                status,
                note,
                ..
            } => {
                if !identifier_is_valid(claim_id) {
                    return Err(DeltaError::InvalidIdentifier);
                }
                if *status == ClaimStatus::Unsupported || !status_allowed_for_any(*status) {
                    return Err(DeltaError::StatusNotAllowed);
                }
                if !claim_text_is_valid(note) && !note.is_empty() {
                    return Err(DeltaError::InvalidText);
                }
                Ok(())
            }
            Self::Supersede {
                claim_id,
                superseded_by,
                ..
            } => {
                if !identifier_is_valid(claim_id)
                    || !identifier_is_valid(superseded_by)
                    || claim_id == superseded_by
                {
                    return Err(DeltaError::InvalidIdentifier);
                }
                Ok(())
            }
        }
    }
}

fn validate_material(
    kind: ClaimKind,
    status: ClaimStatus,
    text: &str,
    supporting: &[EvidenceRef],
    contradicting: &[EvidenceRef],
    session_id: &str,
) -> Result<(), DeltaError> {
    if !claim_text_is_valid(text) {
        return Err(DeltaError::InvalidText);
    }
    if status == ClaimStatus::Unsupported {
        return Err(DeltaError::UnsupportedMaterial);
    }
    if !claim_status_allowed(kind, status) {
        return Err(DeltaError::StatusNotAllowed);
    }
    validate_refs(supporting, contradicting, session_id)
}

fn validate_refs(
    supporting: &[EvidenceRef],
    contradicting: &[EvidenceRef],
    session_id: &str,
) -> Result<(), DeltaError> {
    for reference in supporting.iter().chain(contradicting.iter()) {
        reference.validate().map_err(|_| DeltaError::Evidence)?;
        if reference.session_id != session_id {
            return Err(DeltaError::CrossSession);
        }
    }
    Ok(())
}

fn status_allowed_for_any(status: ClaimStatus) -> bool {
    ClaimKind::ALL
        .iter()
        .any(|kind| claim_status_allowed(*kind, status))
}

fn digest_is_valid(value: &str) -> bool {
    value.len() == 64
        && value
            .bytes()
            .all(|byte| matches!(byte, b'0'..=b'9' | b'a'..=b'f'))
}

fn json_depth(value: &Value) -> usize {
    match value {
        Value::Array(items) => 1 + items.iter().map(json_depth).max().unwrap_or(0),
        Value::Object(map) => 1 + map.values().map(json_depth).max().unwrap_or(0),
        _ => 1,
    }
}

impl ClaimKind {
    const ALL: [ClaimKind; 9] = [
        ClaimKind::Fact,
        ClaimKind::Decision,
        ClaimKind::Commitment,
        ClaimKind::Question,
        ClaimKind::OpenLoop,
        ClaimKind::LooseEnd,
        ClaimKind::Topic,
        ClaimKind::NumberOrTerm,
        ClaimKind::SummaryStatement,
    ];
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{EVIDENCE_REF_SCHEMA, EvidenceKind};

    fn reference(session: &str) -> EvidenceRef {
        EvidenceRef {
            schema: EVIDENCE_REF_SCHEMA.into(),
            session_id: session.into(),
            kind: EvidenceKind::TranscriptSegment,
            record_id: "revision-1".into(),
            revision_id: Some("revision-1".into()),
            start_ns: 0,
            end_ns: 1_000,
            sub_item: Some("0".into()),
            content_digest: "ab".repeat(32),
            resolver_hint: None,
        }
    }

    fn propose(session: &str) -> MeetingMemoryDelta {
        MeetingMemoryDelta {
            schema: MEETING_MEMORY_DELTA_SCHEMA.into(),
            model_run_id: "run-1".into(),
            input_manifest_digest: "cd".repeat(32),
            session_id: session.into(),
            base_revision: "0".into(),
            operations: vec![DeltaOperation::ProposeClaim {
                operation_id: "op-1".into(),
                kind: ClaimKind::Decision,
                text: "Ship the local recorder".into(),
                status: ClaimStatus::Agreed,
                supporting: vec![reference(session)],
                contradicting: Vec::new(),
            }],
        }
    }

    #[test]
    fn a_proposal_round_trips_and_rejects_structural_lies() {
        let delta = propose("session-1");
        let parsed = MeetingMemoryDelta::parse(&serde_json::to_string(&delta).unwrap()).unwrap();
        assert_eq!(parsed, delta);

        let mut extra = serde_json::to_value(&delta).unwrap();
        extra["adjudication"] = Value::String("accepted".into());
        assert_eq!(
            MeetingMemoryDelta::parse(&extra.to_string()),
            Err(DeltaError::Malformed)
        );
        extra.as_object_mut().unwrap().remove("adjudication");
        extra["operations"][0]["op"] = Value::String("delete_evidence".into());
        assert_eq!(
            MeetingMemoryDelta::parse(&extra.to_string()),
            Err(DeltaError::Malformed)
        );

        let mut duplicate = delta.clone();
        duplicate.operations.push(duplicate.operations[0].clone());
        assert_eq!(duplicate.validate(), Err(DeltaError::DuplicateOperation));

        let mut other_session = delta.clone();
        if let DeltaOperation::ProposeClaim { supporting, .. } = &mut other_session.operations[0] {
            supporting[0].session_id = "session-2".into();
        }
        assert_eq!(other_session.validate(), Err(DeltaError::CrossSession));

        let deep = (0..20).fold("0".to_owned(), |child, _| format!("{{\"x\":{child}}}"));
        assert_eq!(MeetingMemoryDelta::parse(&deep), Err(DeltaError::TooDeep));
        assert_eq!(
            MeetingMemoryDelta::parse(&" ".repeat(MAX_DELTA_BYTES + 1)),
            Err(DeltaError::Oversized)
        );
    }
}
