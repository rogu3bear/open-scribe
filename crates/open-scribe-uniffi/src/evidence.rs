//! Coarse evidence citation and resolution (ADR 0013). References cross as
//! canonical `open-scribe.evidence-ref/v1` JSON; Swift never assembles or
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
}
