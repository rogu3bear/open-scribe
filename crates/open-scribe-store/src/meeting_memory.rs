//! Ingest `open-scribe.meeting-memory-delta/v1` (ADR 0013).
//!
//! The model proposal is stored whole. Only an accepted operation appends a
//! claim revision, and Rust chooses that revision's ids. A human acceptance,
//! correction, or rejection is left in effect.

use open_scribe_evidence::{
    AdjudicationAction, ClaimError, ClaimKind, ClaimProducer, ClaimStatus, DERIVED_CLAIM_SCHEMA,
    DeltaError, DeltaIngestReceipt, DeltaOperation, DeltaOperationReceipt, DerivedClaim,
    DerivedClaimSummary, EvidenceRef, MEETING_MEMORY_DELTA_RECEIPT_SCHEMA, MeetingMemoryDelta,
    ResolutionState, claim_status_allowed,
};
use open_scribe_types::SessionId;
use rusqlite::{OptionalExtension, params};
use uuid::Uuid;

use super::{SessionStore, StoreError, wall_time_milliseconds};

pub(super) const MEETING_MEMORY_MIGRATION_VERSION: i64 = 18;

pub(super) fn apply_schema(transaction: &rusqlite::Transaction<'_>) -> Result<(), StoreError> {
    transaction.execute_batch(
        "CREATE TABLE IF NOT EXISTS meeting_memory_projection (
            session_id TEXT PRIMARY KEY REFERENCES sessions(id),
            revision TEXT NOT NULL
        );
        CREATE TABLE IF NOT EXISTS meeting_memory_delta_receipts (
            receipt_id TEXT PRIMARY KEY,
            session_id TEXT NOT NULL REFERENCES sessions(id),
            model_run_id TEXT NOT NULL,
            base_revision TEXT NOT NULL,
            proposal TEXT NOT NULL,
            result TEXT NOT NULL,
            created_at_ms INTEGER NOT NULL
        );
        CREATE INDEX IF NOT EXISTS meeting_memory_delta_receipts_by_session
            ON meeting_memory_delta_receipts(session_id);
        CREATE TABLE IF NOT EXISTS meeting_memory_delta_operations (
            session_id TEXT NOT NULL,
            operation_id TEXT NOT NULL,
            receipt_id TEXT NOT NULL,
            PRIMARY KEY (session_id, operation_id)
        );
        CREATE TRIGGER IF NOT EXISTS meeting_memory_delta_receipts_append_only
        BEFORE UPDATE ON meeting_memory_delta_receipts
        BEGIN SELECT RAISE(ABORT, 'meeting memory delta receipts are append-only'); END;
        CREATE TRIGGER IF NOT EXISTS meeting_memory_delta_operations_append_only
        BEFORE UPDATE ON meeting_memory_delta_operations
        BEGIN SELECT RAISE(ABORT, 'meeting memory delta operations are append-only'); END;",
    )?;
    transaction.execute(
        "INSERT OR IGNORE INTO schema_migrations VALUES(?1, ?2)",
        params![MEETING_MEMORY_MIGRATION_VERSION, wall_time_milliseconds()],
    )?;
    Ok(())
}

struct Planned {
    operation_id: String,
    claim_id: Option<String>,
    revision_id: Option<String>,
    outcome: &'static str,
    reason: Option<&'static str>,
    body: Option<DerivedClaim>,
}

impl Planned {
    fn reject(
        operation_id: &str,
        reason: &'static str,
        claim_id: Option<String>,
        revision_id: Option<String>,
    ) -> Self {
        Self {
            operation_id: operation_id.to_owned(),
            claim_id,
            revision_id,
            outcome: "rejected",
            reason: Some(reason),
            body: None,
        }
    }

    fn append(operation_id: &str, claim: DerivedClaim) -> Self {
        Self {
            operation_id: operation_id.to_owned(),
            claim_id: Some(claim.claim_id.clone()),
            revision_id: Some(claim.revision_id.clone()),
            outcome: "accepted",
            reason: None,
            body: Some(claim),
        }
    }

    fn recorded(operation_id: &str, claim_id: &str, revision_id: &str) -> Self {
        Self {
            operation_id: operation_id.to_owned(),
            claim_id: Some(claim_id.to_owned()),
            revision_id: Some(revision_id.to_owned()),
            outcome: "accepted",
            reason: Some("resolution_recorded"),
            body: None,
        }
    }
}

fn reject_delta(error: DeltaError) -> StoreError {
    let reason = match error {
        DeltaError::Malformed => "meeting memory delta is malformed",
        DeltaError::UnsupportedVersion => "meeting memory delta version is unsupported",
        DeltaError::Oversized => "meeting memory delta is too large",
        DeltaError::TooDeep => "meeting memory delta is too deep",
        DeltaError::InvalidIdentifier => "meeting memory delta identifier is invalid",
        DeltaError::DuplicateOperation => "meeting memory delta repeats an operation",
        DeltaError::CrossSession => "meeting memory delta cites another session",
        DeltaError::InvalidDigest => "meeting memory delta digest is invalid",
        DeltaError::Empty => "meeting memory delta has no operations",
        DeltaError::Evidence => "meeting memory delta cites invalid evidence",
        DeltaError::InvalidText => "meeting memory delta text is invalid",
        DeltaError::StatusNotAllowed => "meeting memory delta status is not allowed",
        DeltaError::UnsupportedMaterial => "material derived claim needs support",
    };
    StoreError::InvalidRequest(reason)
}

fn locked(claim: &DerivedClaim) -> bool {
    matches!(
        claim.adjudication.as_ref().map(|item| item.action),
        Some(
            AdjudicationAction::Accepted
                | AdjudicationAction::Corrected
                | AdjudicationAction::Rejected
        )
    )
}

fn transition_allowed(kind: ClaimKind, from: ClaimStatus, to: ClaimStatus) -> bool {
    if to == ClaimStatus::Unsupported || !claim_status_allowed(kind, to) {
        return false;
    }
    if from == to {
        return true;
    }
    match kind {
        ClaimKind::Decision => decision_transition(from, to),
        ClaimKind::Commitment => commitment_transition(from, to),
        _ => true,
    }
}

fn decision_transition(from: ClaimStatus, to: ClaimStatus) -> bool {
    use ClaimStatus::*;
    matches!(
        (from, to),
        (Mentioned, Proposed | Contradicted | Unknown | Superseded)
            | (Proposed, Agreed | Contradicted | Unknown | Superseded)
            | (Agreed, Contradicted | Superseded | Unknown)
            | (Contradicted, Proposed | Superseded | Unknown)
            | (Unknown, Mentioned | Proposed | Superseded)
    )
}

fn commitment_transition(from: ClaimStatus, to: ClaimStatus) -> bool {
    use ClaimStatus::*;
    matches!(
        (from, to),
        (
            Mentioned,
            Proposed | Contradicted | Unknown | Unresolved | Superseded
        ) | (
            Proposed,
            Assigned | Accepted | Contradicted | Unknown | Unresolved | Superseded
        ) | (
            Assigned,
            Accepted | Completed | Contradicted | Unknown | Unresolved | Superseded
        ) | (
            Accepted,
            Completed | Contradicted | Unknown | Unresolved | Superseded
        ) | (Completed, Contradicted | Superseded)
            | (Contradicted, Proposed | Unresolved | Superseded)
            | (
                Unresolved,
                Proposed | Assigned | Contradicted | Superseded | Unknown
            )
            | (Unknown, Mentioned | Proposed | Superseded)
    )
}

fn model_claim(
    session: &SessionId,
    claim_id: String,
    revision_id: String,
    kind: ClaimKind,
    text: &str,
    status: ClaimStatus,
    supporting: &[EvidenceRef],
    contradicting: &[EvidenceRef],
) -> DerivedClaim {
    DerivedClaim {
        schema: DERIVED_CLAIM_SCHEMA.to_owned(),
        claim_id,
        revision_id,
        session_id: session.0.clone(),
        kind,
        text: text.to_owned(),
        status,
        supporting: supporting.to_vec(),
        contradicting: contradicting.to_vec(),
        producer: ClaimProducer::ModelRun,
        adjudication: None,
    }
}

fn fresh_id() -> String {
    Uuid::now_v7().to_string()
}

fn kind_name(kind: ClaimKind) -> &'static str {
    match kind {
        ClaimKind::Fact => "fact",
        ClaimKind::Decision => "decision",
        ClaimKind::Commitment => "commitment",
        ClaimKind::Question => "question",
        ClaimKind::OpenLoop => "open_loop",
        ClaimKind::LooseEnd => "loose_end",
        ClaimKind::Topic => "topic",
        ClaimKind::NumberOrTerm => "number_or_term",
        ClaimKind::SummaryStatement => "summary_statement",
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

fn producer_label(producer: ClaimProducer) -> &'static str {
    match producer {
        ClaimProducer::Human => "human",
        ClaimProducer::ModelRun => "model_run",
    }
}

fn evidence_phrase(claim: &DerivedClaim) -> String {
    let mut parts = Vec::new();
    for reference in &claim.supporting {
        parts.push(format!(
            "supporting {}-{} ns",
            reference.start_ns, reference.end_ns
        ));
    }
    for reference in &claim.contradicting {
        parts.push(format!(
            "contradicting {}-{} ns",
            reference.start_ns, reference.end_ns
        ));
    }
    parts.join(", ")
}

fn action_name(action: AdjudicationAction) -> &'static str {
    match action {
        AdjudicationAction::Accepted => "accepted",
        AdjudicationAction::Corrected => "corrected",
        AdjudicationAction::Rejected => "rejected",
        AdjudicationAction::Unresolved => "unresolved",
    }
}

fn evidence_reason(state: ResolutionState) -> Option<&'static str> {
    match state {
        ResolutionState::Available => None,
        ResolutionState::Superseded => Some("evidence was superseded"),
        ResolutionState::Missing => Some("evidence is missing"),
        ResolutionState::Deleted => Some("evidence was deleted"),
        ResolutionState::IntegrityMismatch => Some("evidence digest does not match"),
        ResolutionState::UnsupportedVersion => Some("evidence version is unsupported"),
    }
}

impl SessionStore {
    pub fn meeting_memory_revision(&self, session: &SessionId) -> Result<String, StoreError> {
        self.require_session(&session.0)?;
        self.stored_revision(&session.0)
    }

    pub fn ingest_meeting_memory_delta(
        &mut self,
        json: &str,
    ) -> Result<DeltaIngestReceipt, StoreError> {
        let _writer = self.write_guard()?;
        let delta = MeetingMemoryDelta::parse(json).map_err(reject_delta)?;
        super::session_deletion::require_available(&self.connection, &delta.session_id)?;
        let current = self.stored_revision(&delta.session_id)?;
        if current != delta.base_revision {
            return Err(StoreError::InvalidRequest(
                "meeting memory base revision is stale",
            ));
        }
        if self.operation_already_used(&delta)? {
            return Err(StoreError::InvalidRequest(
                "meeting memory delta repeats an operation",
            ));
        }
        let session = SessionId(delta.session_id.clone());
        let planned = self.plan_operations(&session, &delta.operations)?;
        let accepted = planned.iter().any(|item| item.outcome == "accepted");
        let receipt_id = fresh_id();
        let next_revision = if accepted {
            receipt_id.clone()
        } else {
            current
        };
        let receipt = DeltaIngestReceipt {
            schema: MEETING_MEMORY_DELTA_RECEIPT_SCHEMA.to_owned(),
            receipt_id: receipt_id.clone(),
            session_id: delta.session_id.clone(),
            model_run_id: delta.model_run_id.clone(),
            base_revision: delta.base_revision.clone(),
            next_revision: next_revision.clone(),
            operations: planned
                .iter()
                .map(|item| DeltaOperationReceipt {
                    operation_id: item.operation_id.clone(),
                    outcome: item.outcome.to_owned(),
                    reason: item.reason.map(str::to_owned),
                    claim_id: item.claim_id.clone(),
                    revision_id: item.revision_id.clone(),
                })
                .collect(),
        };
        let result = serde_json::to_string(&receipt)?;
        let now = wall_time_milliseconds();
        let transaction = self.connection.transaction()?;
        transaction.execute(
            "INSERT INTO meeting_memory_delta_receipts(
                receipt_id, session_id, model_run_id, base_revision, proposal, result, created_at_ms)
             VALUES(?1, ?2, ?3, ?4, ?5, ?6, ?7)",
            params![
                receipt_id,
                delta.session_id,
                delta.model_run_id,
                delta.base_revision,
                json,
                result,
                now,
            ],
        )?;
        for item in &planned {
            transaction.execute(
                "INSERT INTO meeting_memory_delta_operations(session_id, operation_id, receipt_id)
                 VALUES(?1, ?2, ?3)",
                params![delta.session_id, item.operation_id, receipt.receipt_id],
            )?;
            if let Some(claim) = &item.body {
                insert_claim(&transaction, claim, now)?;
            }
        }
        if accepted {
            transaction.execute(
                "INSERT INTO meeting_memory_projection(session_id, revision) VALUES(?1, ?2)
                 ON CONFLICT(session_id) DO UPDATE SET revision = excluded.revision",
                params![delta.session_id, next_revision],
            )?;
        }
        transaction.commit()?;
        Ok(receipt)
    }

    pub fn effective_derived_claim_summaries(
        &self,
        session: &SessionId,
    ) -> Result<Vec<DerivedClaimSummary>, StoreError> {
        self.require_session(&session.0)?;
        let mut statement = self.connection.prepare(
            "SELECT DISTINCT claim_id FROM derived_claim_revisions
             WHERE session_id = ?1 ORDER BY claim_id",
        )?;
        let ids: Vec<String> = statement
            .query_map(params![session.0], |row| row.get(0))?
            .collect::<Result<_, _>>()?;
        let mut summaries = Vec::new();
        for claim_id in ids {
            let Some(claim) = self.effective_derived_claim(session, &claim_id)? else {
                continue;
            };
            if !claim.is_canonical() {
                continue;
            }
            let (model_run_id, input_digest) =
                self.accepted_model_run(&session.0, &claim.claim_id)?;
            let producer = producer_label(claim.producer).to_owned();
            let evidence = evidence_phrase(&claim);
            summaries.push(DerivedClaimSummary {
                claim_id: claim.claim_id,
                revision_id: claim.revision_id,
                kind: kind_name(claim.kind).to_owned(),
                status: status_name(claim.status).to_owned(),
                text: claim.text,
                adjudication: claim
                    .adjudication
                    .map(|item| action_name(item.action).to_owned()),
                supporting_count: u32::try_from(claim.supporting.len()).unwrap_or(u32::MAX),
                contradicting_count: u32::try_from(claim.contradicting.len()).unwrap_or(u32::MAX),
                producer,
                evidence,
                model_run_id,
                input_digest,
            });
        }
        Ok(summaries)
    }

    /// The latest accepted meeting-memory run for this claim, and that run's
    /// input digest. A rejected later proposal does not replace it.
    fn accepted_model_run(
        &self,
        session: &str,
        claim_id: &str,
    ) -> Result<(String, String), StoreError> {
        let mut statement = self.connection.prepare(
            "SELECT proposal, result FROM meeting_memory_delta_receipts
             WHERE session_id = ?1 ORDER BY created_at_ms, receipt_id",
        )?;
        let rows = statement.query_map(params![session], |row| {
            Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?))
        })?;
        let mut found = (String::new(), String::new());
        for row in rows {
            let (proposal, result) = row?;
            let Ok(receipt) = serde_json::from_str::<DeltaIngestReceipt>(&result) else {
                continue;
            };
            let accepted = receipt.operations.iter().any(|item| {
                item.outcome == "accepted" && item.claim_id.as_deref() == Some(claim_id)
            });
            if !accepted {
                continue;
            }
            let digest = serde_json::from_str::<MeetingMemoryDelta>(&proposal)
                .map(|delta| delta.input_manifest_digest)
                .unwrap_or_default();
            found = (receipt.model_run_id, digest);
        }
        Ok(found)
    }

    fn require_session(&self, session: &str) -> Result<(), StoreError> {
        let exists: bool = self.connection.query_row(
            "SELECT EXISTS(SELECT 1 FROM sessions WHERE id = ?1)",
            [session],
            |row| row.get(0),
        )?;
        if exists {
            Ok(())
        } else {
            Err(StoreError::InvalidRequest("no such session"))
        }
    }

    fn stored_revision(&self, session: &str) -> Result<String, StoreError> {
        let found: Option<String> = self
            .connection
            .query_row(
                "SELECT revision FROM meeting_memory_projection WHERE session_id = ?1",
                [session],
                |row| row.get(0),
            )
            .optional()?;
        Ok(found.unwrap_or_else(|| "0".to_owned()))
    }

    fn operation_already_used(&self, delta: &MeetingMemoryDelta) -> Result<bool, StoreError> {
        for operation in &delta.operations {
            let exists: bool = self.connection.query_row(
                "SELECT EXISTS(
                    SELECT 1 FROM meeting_memory_delta_operations
                    WHERE session_id = ?1 AND operation_id = ?2)",
                params![delta.session_id, operation.operation_id()],
                |row| row.get(0),
            )?;
            if exists {
                return Ok(true);
            }
        }
        Ok(false)
    }

    fn plan_operations(
        &self,
        session: &SessionId,
        operations: &[DeltaOperation],
    ) -> Result<Vec<Planned>, StoreError> {
        let mut planned = Vec::with_capacity(operations.len());
        for operation in operations {
            planned.push(self.plan_operation(session, operation)?);
        }
        Ok(planned)
    }

    fn plan_operation(
        &self,
        session: &SessionId,
        operation: &DeltaOperation,
    ) -> Result<Planned, StoreError> {
        match operation {
            DeltaOperation::ProposeClaim {
                operation_id,
                kind,
                text,
                status,
                supporting,
                contradicting,
            } => {
                if let Some(reason) = self.unavailable(supporting, contradicting)? {
                    return Ok(Planned::reject(operation_id, reason, None, None));
                }
                let claim = model_claim(
                    session,
                    fresh_id(),
                    fresh_id(),
                    *kind,
                    text,
                    *status,
                    supporting,
                    contradicting,
                );
                Ok(self.validated_append(operation_id, claim))
            }
            DeltaOperation::ReviseClaim {
                operation_id,
                claim_id,
                kind,
                text,
                status,
                supporting,
                contradicting,
            } => {
                let Some(existing) = self.effective_derived_claim(session, claim_id)? else {
                    return Ok(Planned::reject(
                        operation_id,
                        "unknown claim",
                        Some(claim_id.clone()),
                        None,
                    ));
                };
                if locked(&existing) {
                    return Ok(self.kept_human(operation_id, &existing));
                }
                if existing.kind != *kind
                    || !transition_allowed(existing.kind, existing.status, *status)
                {
                    return Ok(Planned::reject(
                        operation_id,
                        "illegal transition",
                        Some(existing.claim_id),
                        Some(existing.revision_id),
                    ));
                }
                if let Some(reason) = self.unavailable(supporting, contradicting)? {
                    return Ok(Planned::reject(
                        operation_id,
                        reason,
                        Some(existing.claim_id),
                        Some(existing.revision_id),
                    ));
                }
                let claim = model_claim(
                    session,
                    existing.claim_id,
                    fresh_id(),
                    *kind,
                    text,
                    *status,
                    supporting,
                    contradicting,
                );
                Ok(self.validated_append(operation_id, claim))
            }
            DeltaOperation::ChangeRelations {
                operation_id,
                claim_id,
                status,
                supporting,
                contradicting,
            } => self.plan_revision(
                session,
                operation_id,
                claim_id,
                None,
                *status,
                supporting,
                contradicting,
            ),
            DeltaOperation::ResolutionSearch {
                operation_id,
                claim_id,
                status,
                ..
            } => {
                let Some(existing) = self.effective_derived_claim(session, claim_id)? else {
                    return Ok(Planned::reject(
                        operation_id,
                        "unknown claim",
                        Some(claim_id.clone()),
                        None,
                    ));
                };
                if locked(&existing) {
                    return Ok(self.kept_human(operation_id, &existing));
                }
                if !transition_allowed(existing.kind, existing.status, *status) {
                    return Ok(Planned::reject(
                        operation_id,
                        "illegal transition",
                        Some(existing.claim_id),
                        Some(existing.revision_id),
                    ));
                }
                if existing.status == *status {
                    return Ok(Planned::recorded(
                        operation_id,
                        &existing.claim_id,
                        &existing.revision_id,
                    ));
                }
                let claim = model_claim(
                    session,
                    existing.claim_id,
                    fresh_id(),
                    existing.kind,
                    &existing.text,
                    *status,
                    &existing.supporting,
                    &existing.contradicting,
                );
                Ok(self.validated_append(operation_id, claim))
            }
            DeltaOperation::Supersede {
                operation_id,
                claim_id,
                superseded_by,
            } => {
                let Some(existing) = self.effective_derived_claim(session, claim_id)? else {
                    return Ok(Planned::reject(
                        operation_id,
                        "unknown claim",
                        Some(claim_id.clone()),
                        None,
                    ));
                };
                if locked(&existing) {
                    return Ok(self.kept_human(operation_id, &existing));
                }
                let replacement = self.effective_derived_claim(session, superseded_by)?;
                if replacement
                    .as_ref()
                    .is_none_or(|claim| !claim.is_canonical())
                {
                    return Ok(Planned::reject(
                        operation_id,
                        "unknown claim",
                        Some(existing.claim_id),
                        Some(existing.revision_id),
                    ));
                }
                if !transition_allowed(existing.kind, existing.status, ClaimStatus::Superseded) {
                    return Ok(Planned::reject(
                        operation_id,
                        "illegal transition",
                        Some(existing.claim_id),
                        Some(existing.revision_id),
                    ));
                }
                let claim = model_claim(
                    session,
                    existing.claim_id,
                    fresh_id(),
                    existing.kind,
                    &existing.text,
                    ClaimStatus::Superseded,
                    &existing.supporting,
                    &existing.contradicting,
                );
                Ok(self.validated_append(operation_id, claim))
            }
        }
    }

    fn plan_revision(
        &self,
        session: &SessionId,
        operation_id: &str,
        claim_id: &str,
        text: Option<&str>,
        status: ClaimStatus,
        supporting: &[EvidenceRef],
        contradicting: &[EvidenceRef],
    ) -> Result<Planned, StoreError> {
        let Some(existing) = self.effective_derived_claim(session, claim_id)? else {
            return Ok(Planned::reject(
                operation_id,
                "unknown claim",
                Some(claim_id.to_owned()),
                None,
            ));
        };
        if locked(&existing) {
            return Ok(self.kept_human(operation_id, &existing));
        }
        if !transition_allowed(existing.kind, existing.status, status) {
            return Ok(Planned::reject(
                operation_id,
                "illegal transition",
                Some(existing.claim_id),
                Some(existing.revision_id),
            ));
        }
        if let Some(reason) = self.unavailable(supporting, contradicting)? {
            return Ok(Planned::reject(
                operation_id,
                reason,
                Some(existing.claim_id),
                Some(existing.revision_id),
            ));
        }
        let claim = model_claim(
            session,
            existing.claim_id,
            fresh_id(),
            existing.kind,
            text.unwrap_or(&existing.text),
            status,
            supporting,
            contradicting,
        );
        Ok(self.validated_append(operation_id, claim))
    }

    fn kept_human(&self, operation_id: &str, existing: &DerivedClaim) -> Planned {
        Planned::reject(
            operation_id,
            "human adjudication stays in effect",
            Some(existing.claim_id.clone()),
            Some(existing.revision_id.clone()),
        )
    }

    fn validated_append(&self, operation_id: &str, claim: DerivedClaim) -> Planned {
        match claim.validate() {
            Ok(()) => Planned::append(operation_id, claim),
            Err(ClaimError::UnsupportedMaterial) => Planned::reject(
                operation_id,
                "material derived claim needs support",
                None,
                None,
            ),
            Err(_) => Planned::reject(operation_id, "invalid claim", None, None),
        }
    }

    fn unavailable(
        &self,
        supporting: &[EvidenceRef],
        contradicting: &[EvidenceRef],
    ) -> Result<Option<&'static str>, StoreError> {
        for reference in supporting.iter().chain(contradicting) {
            if let Some(reason) = evidence_reason(self.resolve_evidence(reference)?.state) {
                return Ok(Some(reason));
            }
        }
        Ok(None)
    }
}

fn insert_claim(
    transaction: &rusqlite::Transaction<'_>,
    claim: &DerivedClaim,
    now: i64,
) -> Result<(), StoreError> {
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
    let body = serde_json::to_string(claim)?;
    transaction.execute(
        "INSERT INTO derived_claim_revisions(
            revision_id, claim_id, session_id, producer, status,
            adjudication_action, body, created_at_ms)
         VALUES(?1, ?2, ?3, 'model_run', ?4, NULL, ?5, ?6)",
        params![
            claim.revision_id,
            claim.claim_id,
            claim.session_id,
            status_name(claim.status),
            body,
            now,
        ],
    )?;
    Ok(())
}
