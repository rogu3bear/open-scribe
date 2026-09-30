//! WASM-safe evidence and derived-claim semantics for Open Scribe.
//!
//! This crate owns the `open-scribe.evidence-ref/v1` schema and its
//! deterministic validation (ADR 0013). Native Rust resolves references
//! through the media ledger, transcript revisions, and SQLite; other surfaces
//! consume resolved projections and never reinterpret reference identity.
//! Derived-claim schemas remain unimplemented.

#![forbid(unsafe_code)]

use serde::{Deserialize, Serialize};
use std::fmt;

pub const EVIDENCE_REF_SCHEMA: &str = "open-scribe.evidence-ref/v1";

/// What an evidence reference cites.
#[derive(Clone, Copy, Debug, Deserialize, Eq, Hash, PartialEq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum EvidenceKind {
    /// One segment of an immutable transcript revision.
    TranscriptSegment,
    /// A range of one sealed audio track.
    AudioRange,
    Marker,
    HumanCorrection,
    /// An accepted context event, or one of its text blocks (`block-N`).
    ContextEvent,
}

/// A stable pointer to evidence. Identity never depends on display text, a
/// mutable row number, or a filesystem path.
#[derive(Clone, Debug, Deserialize, Eq, Hash, PartialEq, Serialize)]
#[serde(deny_unknown_fields)]
pub struct EvidenceRef {
    pub schema: String,
    pub session_id: String,
    pub kind: EvidenceKind,
    /// Stable record: a track, correction, marker, or context event ID.
    pub record_id: String,
    /// Immutable revision where the kind has one.
    pub revision_id: Option<String>,
    /// Half-open session range `[start_ns, end_ns)`.
    pub start_ns: i64,
    pub end_ns: i64,
    /// Bounded item inside the record, such as a segment sequence.
    pub sub_item: Option<String>,
    /// Lowercase SHA-256 of the cited content.
    pub content_digest: String,
    /// Last resolver outcome observed by the writer. A hint only: it is not
    /// part of the stored identity, and readers re-resolve before display.
    pub resolver_hint: Option<ResolutionState>,
}

/// Exactly the resolution outcomes ADR 0013 permits. Missing or deleted
/// evidence is never silently substituted.
#[derive(Clone, Copy, Debug, Deserialize, Eq, Hash, PartialEq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum ResolutionState {
    Available,
    Superseded,
    Missing,
    Deleted,
    IntegrityMismatch,
    UnsupportedVersion,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum EvidenceRefError {
    Malformed,
    UnsupportedVersion,
    InvalidIdentifier,
    InvalidRange,
    InvalidDigest,
    MissingRevision,
    MissingSubItem,
}

impl fmt::Display for EvidenceRefError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(match self {
            Self::Malformed => "evidence reference is not valid JSON of the v1 shape",
            Self::UnsupportedVersion => "unsupported evidence reference version",
            Self::InvalidIdentifier => "evidence reference identifier is invalid",
            Self::InvalidRange => "evidence reference range is invalid",
            Self::InvalidDigest => "evidence reference digest is invalid",
            Self::MissingRevision => "evidence kind requires an immutable revision",
            Self::MissingSubItem => "evidence kind requires a sub-item",
        })
    }
}

impl std::error::Error for EvidenceRefError {}

impl EvidenceRef {
    pub fn validate(&self) -> Result<(), EvidenceRefError> {
        if self.schema != EVIDENCE_REF_SCHEMA {
            return Err(EvidenceRefError::UnsupportedVersion);
        }
        let optional_ok = |value: &Option<String>| value.as_deref().is_none_or(identifier_is_valid);
        if !identifier_is_valid(&self.session_id)
            || !identifier_is_valid(&self.record_id)
            || !optional_ok(&self.revision_id)
            || !optional_ok(&self.sub_item)
        {
            return Err(EvidenceRefError::InvalidIdentifier);
        }
        if self.start_ns < 0 || self.end_ns <= self.start_ns {
            return Err(EvidenceRefError::InvalidRange);
        }
        if self.content_digest.len() != 64
            || !self
                .content_digest
                .bytes()
                .all(|byte| matches!(byte, b'0'..=b'9' | b'a'..=b'f'))
        {
            return Err(EvidenceRefError::InvalidDigest);
        }
        if self.kind == EvidenceKind::TranscriptSegment {
            if self.revision_id.is_none() {
                return Err(EvidenceRefError::MissingRevision);
            }
            if self.sub_item.is_none() {
                return Err(EvidenceRefError::MissingSubItem);
            }
        }
        Ok(())
    }

    /// Parses untrusted JSON and validates it; unknown fields are rejected.
    pub fn parse(json: &str) -> Result<Self, EvidenceRefError> {
        let reference: Self =
            serde_json::from_str(json).map_err(|_| EvidenceRefError::Malformed)?;
        reference.validate()?;
        Ok(reference)
    }
}

fn identifier_is_valid(value: &str) -> bool {
    !value.is_empty()
        && value.len() <= 128
        && value
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'-' | b'_' | b'.' | b':'))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn transcript_ref() -> EvidenceRef {
        EvidenceRef {
            schema: EVIDENCE_REF_SCHEMA.into(),
            session_id: "01a0ef0d-2600-76c4-8f7e-de8905518c51".into(),
            kind: EvidenceKind::TranscriptSegment,
            record_id: "01a0ef0d-2610-77cf-88eb-59e1220757d7".into(),
            revision_id: Some("01a0ef0d-2610-77cf-88eb-59e1220757d7".into()),
            start_ns: 1_000,
            end_ns: 2_000,
            sub_item: Some("3".into()),
            content_digest: "a".repeat(64),
            resolver_hint: None,
        }
    }

    #[test]
    fn a_complete_reference_round_trips_and_validates() {
        let reference = transcript_ref();
        reference.validate().unwrap();
        let json = serde_json::to_string(&reference).unwrap();
        assert!(json.contains("\"kind\":\"transcript_segment\""));
        assert_eq!(EvidenceRef::parse(&json).unwrap(), reference);
    }

    #[test]
    fn invalid_identity_range_digest_and_versions_are_rejected() {
        let check = |mutate: fn(&mut EvidenceRef), expected| {
            let mut reference = transcript_ref();
            mutate(&mut reference);
            assert_eq!(reference.validate(), Err(expected));
        };
        check(
            |r| r.schema = "open-scribe.evidence-ref/v2".into(),
            EvidenceRefError::UnsupportedVersion,
        );
        check(
            |r| r.session_id = "../escape".into(),
            EvidenceRefError::InvalidIdentifier,
        );
        check(
            |r| r.sub_item = Some(String::new()),
            EvidenceRefError::InvalidIdentifier,
        );
        check(|r| r.end_ns = r.start_ns, EvidenceRefError::InvalidRange);
        check(|r| r.start_ns = -1, EvidenceRefError::InvalidRange);
        check(
            |r| r.content_digest = "A".repeat(64),
            EvidenceRefError::InvalidDigest,
        );
        check(|r| r.revision_id = None, EvidenceRefError::MissingRevision);
        check(|r| r.sub_item = None, EvidenceRefError::MissingSubItem);

        let mut audio = transcript_ref();
        audio.kind = EvidenceKind::AudioRange;
        audio.revision_id = None;
        audio.sub_item = None;
        audio.validate().unwrap();

        let mut context = transcript_ref();
        context.kind = EvidenceKind::ContextEvent;
        context.revision_id = None;
        context.sub_item = Some("block-2".into());
        context.validate().unwrap();
        assert!(
            serde_json::to_string(&context)
                .unwrap()
                .contains("\"kind\":\"context_event\"")
        );

        let extra = serde_json::to_string(&transcript_ref())
            .unwrap()
            .replace("\"schema\"", "\"unexpected\":1,\"schema\"");
        assert_eq!(EvidenceRef::parse(&extra), Err(EvidenceRefError::Malformed));

        let mut hinted = transcript_ref();
        hinted.resolver_hint = Some(ResolutionState::Superseded);
        let json = serde_json::to_string(&hinted).unwrap();
        assert!(json.contains("\"resolver_hint\":\"superseded\""));
        assert_eq!(EvidenceRef::parse(&json).unwrap(), hinted);
        let without_hint = json.replace(",\"resolver_hint\":\"superseded\"", "");
        assert_eq!(
            EvidenceRef::parse(&without_hint).unwrap().resolver_hint,
            None
        );
    }
}
