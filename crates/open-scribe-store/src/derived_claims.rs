//! Append-only derived-claim revisions (ADR 0013).
//!
//! A claim cites evidence that the store already resolved. Human adjudication
//! is a new revision. A later model proposal is kept, and it does not replace
//! an accepted, corrected, or rejected revision of the same claim.

use super::{SessionStore, StoreError, wall_time_milliseconds};
use open_scribe_evidence::{
    AdjudicationAction, ClaimError, ClaimProducer, ClaimStatus, DerivedClaim, EvidenceRef,
    ResolutionState,
};
use open_scribe_types::SessionId;
use rusqlite::{OptionalExtension, params};
use uuid::Uuid;

pub(super) fn apply_schema(transaction: &rusqlite::Transaction<'_>) -> Result<(), StoreError> {
    transaction.execute_batch(
        "CREATE TABLE IF NOT EXISTS derived_claim_revisions (
            revision_id TEXT PRIMARY KEY,
            claim_id TEXT NOT NULL,
            session_id TEXT NOT NULL REFERENCES sessions(id),
            producer TEXT NOT NULL,
            status TEXT NOT NULL,
            adjudication_action TEXT,
            body TEXT NOT NULL,
            created_at_ms INTEGER NOT NULL
        );
        CREATE INDEX IF NOT EXISTS derived_claim_revisions_by_claim
            ON derived_claim_revisions(session_id, claim_id);
        CREATE TRIGGER IF NOT EXISTS derived_claim_revisions_append_only
        BEFORE UPDATE ON derived_claim_revisions
        BEGIN SELECT RAISE(ABORT, 'derived claim revisions are append-only'); END;",
    )?;
    Ok(())
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum ClaimEvidenceSide {
    Supporting,
    Contradicting,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ClaimNavigationTarget {
    pub side: ClaimEvidenceSide,
    pub record_id: String,
    pub start_ns: i64,
    pub end_ns: i64,
    pub state: ResolutionState,
    pub text: Option<String>,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ClaimNavigation {
    pub claim_id: String,
    pub revision_id: String,
    pub text: String,
    pub adjudication: Option<AdjudicationAction>,
    pub targets: Vec<ClaimNavigationTarget>,
}

fn reject_claim(error: ClaimError) -> StoreError {
    let reason = match error {
        ClaimError::Malformed => "derived claim is malformed",
        ClaimError::UnsupportedVersion => "derived claim version is unsupported",
        ClaimError::InvalidIdentifier => "derived claim identifier is invalid",
        ClaimError::InvalidText => "derived claim text is invalid",
        ClaimError::StatusNotAllowed => "derived claim status is not allowed",
        ClaimError::UnsupportedMaterial => "material derived claim needs support",
        ClaimError::Evidence(_) => "derived claim cites invalid evidence",
        ClaimError::CrossSession => "derived claim cites another session",
        ClaimError::AdjudicationMismatch => "adjudication does not match the claim revision",
    };
    StoreError::InvalidRequest(reason)
}

fn action_name(action: AdjudicationAction) -> &'static str {
    match action {
        AdjudicationAction::Accepted => "accepted",
        AdjudicationAction::Corrected => "corrected",
        AdjudicationAction::Rejected => "rejected",
        AdjudicationAction::Unresolved => "unresolved",
    }
}

fn producer_name(producer: ClaimProducer) -> &'static str {
    match producer {
        ClaimProducer::Human => "human",
        ClaimProducer::ModelRun => "model_run",
    }
}

fn status_name(status: ClaimStatus) -> &'static str {
    match status {
        ClaimStatus::Mentioned => "mentioned",
        ClaimStatus::Proposed => "proposed",
        ClaimStatus::Agreed => "agreed",
        ClaimStatus::Assigned => "assigned",
        ClaimStatus::Accepted => "accepted",
        ClaimStatus::Completed => "completed",
        ClaimStatus::Contradicted => "contradicted",
        ClaimStatus::Superseded => "superseded",
        ClaimStatus::Unresolved => "unresolved",
        ClaimStatus::Unknown => "unknown",
        ClaimStatus::Open => "open",
        ClaimStatus::Answered => "answered",
        ClaimStatus::Closed => "closed",
        ClaimStatus::Unsupported => "unsupported",
    }
}

impl SessionStore {
    /// Stores one immutable revision. The JSON body is the validated claim.
    pub fn insert_derived_claim(&mut self, claim: &DerivedClaim) -> Result<(), StoreError> {
        let _writer = self.write_guard()?;
        claim.validate().map_err(reject_claim)?;
        super::session_deletion::require_available(&self.connection, &claim.session_id)?;
        let body = serde_json::to_string(claim)?;
        let adjudication = claim
            .adjudication
            .as_ref()
            .map(|item| action_name(item.action));
        let producer = producer_name(claim.producer);
        let status = status_name(claim.status);
        let transaction = self.connection.transaction()?;
        let exists: bool = transaction.query_row(
            "SELECT EXISTS(SELECT 1 FROM derived_claim_revisions WHERE revision_id = ?1)",
            [&claim.revision_id],
            |row| row.get(0),
        )?;
        if exists {
            return Err(StoreError::InvalidState(
                "derived claim revision already exists",
            ));
        }
        transaction.execute(
            "INSERT INTO derived_claim_revisions(
                revision_id, claim_id, session_id, producer, status,
                adjudication_action, body, created_at_ms)
             VALUES(?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)",
            params![
                claim.revision_id,
                claim.claim_id,
                claim.session_id,
                producer,
                status,
                adjudication,
                body,
                wall_time_milliseconds(),
            ],
        )?;
        transaction.commit()?;
        Ok(())
    }

    /// Records a human confirmation, correction, or rejection of the effective
    /// claim. Rust chooses the revision and adjudication ids. Leaving a claim
    /// unresolved writes nothing, and this does not advance meeting memory.
    pub fn adjudicate_derived_claim(
        &mut self,
        session: &SessionId,
        claim_id: &str,
        action: AdjudicationAction,
        text: Option<&str>,
    ) -> Result<DerivedClaim, StoreError> {
        let _writer = self.write_guard()?;
        if action == AdjudicationAction::Unresolved {
            return Err(StoreError::InvalidRequest(
                "leaving a claim unresolved does not write a revision",
            ));
        }
        let current = self
            .effective_derived_claim(session, claim_id)?
            .ok_or(StoreError::InvalidRequest("derived claim was not found"))?;
        if matches!(
            action,
            AdjudicationAction::Accepted | AdjudicationAction::Rejected
        ) && text.is_some_and(|value| value != current.text)
        {
            return Err(StoreError::InvalidRequest(
                "only a correction can change claim text",
            ));
        }
        let mut revised = current
            .with_adjudication(
                action,
                Uuid::now_v7().to_string(),
                Uuid::now_v7().to_string(),
            )
            .map_err(reject_claim)?;
        if action == AdjudicationAction::Corrected
            && let Some(value) = text
        {
            revised.text = value.to_owned();
        }
        revised.validate().map_err(reject_claim)?;
        self.insert_derived_claim(&revised)?;
        Ok(revised)
    }

    /// The effective claim is the latest accepted, corrected, or rejected
    /// revision. Otherwise it is the latest supported revision.
    pub fn effective_derived_claim(
        &self,
        session: &SessionId,
        claim_id: &str,
    ) -> Result<Option<DerivedClaim>, StoreError> {
        let body: Option<String> = self
            .connection
            .query_row(
                "SELECT body FROM derived_claim_revisions
                 WHERE session_id = ?1 AND claim_id = ?2 AND status != 'unsupported'
                 ORDER BY CASE
                    WHEN adjudication_action IN ('accepted', 'corrected', 'rejected') THEN 1
                    ELSE 0 END DESC,
                    rowid DESC
                 LIMIT 1",
                params![session.0, claim_id],
                |row| row.get(0),
            )
            .optional()?;
        body.map(|json| DerivedClaim::parse(&json).map_err(reject_claim))
            .transpose()
    }

    /// Resolves the effective claim's supporting and contradicting evidence.
    pub fn navigate_derived_claim(
        &self,
        session: &SessionId,
        claim_id: &str,
    ) -> Result<ClaimNavigation, StoreError> {
        let claim = self
            .effective_derived_claim(session, claim_id)?
            .ok_or(StoreError::InvalidRequest("no canonical derived claim"))?;
        if claim.session_id != session.0 {
            return Err(StoreError::InvalidRequest(
                "derived claim cites another session",
            ));
        }
        let mut targets = Vec::with_capacity(claim.supporting.len() + claim.contradicting.len());
        for (side, reference) in sides(&claim) {
            let resolved = self.resolve_evidence(reference)?;
            targets.push(ClaimNavigationTarget {
                side,
                record_id: reference.record_id.clone(),
                start_ns: reference.start_ns,
                end_ns: reference.end_ns,
                state: resolved.state,
                text: resolved.text,
            });
        }
        Ok(ClaimNavigation {
            claim_id: claim.claim_id,
            revision_id: claim.revision_id,
            text: claim.text,
            adjudication: claim.adjudication.map(|item| item.action),
            targets,
        })
    }
}

fn sides(claim: &DerivedClaim) -> Vec<(ClaimEvidenceSide, &EvidenceRef)> {
    claim
        .supporting
        .iter()
        .map(|reference| (ClaimEvidenceSide::Supporting, reference))
        .chain(
            claim
                .contradicting
                .iter()
                .map(|reference| (ClaimEvidenceSide::Contradicting, reference)),
        )
        .collect()
}

#[cfg(test)]
#[path = "derived_claims_tests.rs"]
mod tests;
