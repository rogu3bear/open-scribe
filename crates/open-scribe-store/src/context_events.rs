//! Sparse context event acceptance (ADR 0012).
//!
//! Swift reduces a frame to ordered text blocks and proposes them; Rust alone
//! decides whether they become evidence. A proposal is accepted only under
//! the scope's current, active epoch while audio is recording. Its host
//! times map onto the session timeline and never move backward. Text that
//! repeats the epoch's last accepted reading is suppressed unless the user
//! marked the moment. Rejection is a value, never a durable effect: nothing
//! is journaled and no success signal may follow. No pixels, pointer
//! samples, or frame-rate values reach this module.

use super::context::{ContextBounds, ContextMode, validate_bounds};
use super::*;
use rusqlite::OptionalExtension;

pub const CONTEXT_EVENT_SCHEMA: &str = "open-scribe.context-event/v1";
const MAX_BLOCKS: usize = 128;
const MAX_BLOCK_TEXT_BYTES: usize = 1024;
const MAX_LANGUAGES: usize = 8;
/// A journal record carries its body, digests, and identifiers beside the
/// payload; this margin keeps an accepted event inside the record bound.
const JOURNAL_ENVELOPE_BYTES: usize = 1024;
/// Box coordinates are stored in thousandths of the observed region.
const BOX_SCALE: f64 = 1000.0;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum ContextEventReason {
    Attention,
    FixedScopeChange,
    UserMarked,
}

impl ContextEventReason {
    fn as_str(self) -> &'static str {
        match self {
            Self::Attention => "attention",
            Self::FixedScopeChange => "fixed_scope_change",
            Self::UserMarked => "user_marked",
        }
    }
}

/// The observed surface, as bounded names and identifiers only.
#[derive(Clone, Debug, PartialEq)]
pub struct ContextSource {
    pub platform_id: String,
    pub name: String,
    pub application: Option<String>,
}

/// One recognized line, with bounds normalized to the observed region
/// (top-left origin).
#[derive(Clone, Debug, PartialEq)]
pub struct ContextTextBlock {
    pub text: String,
    pub x: f64,
    pub y: f64,
    pub width: f64,
    pub height: f64,
}

#[derive(Clone, Debug, PartialEq)]
pub struct ContextProposal {
    pub scope_id: String,
    pub epoch: u32,
    pub reason: ContextEventReason,
    pub start_host_time: u64,
    pub end_host_time: u64,
    pub observed_at_ms: i64,
    pub source: ContextSource,
    pub bounds: Option<ContextBounds>,
    pub reducer_revision: String,
    pub vision_revision: String,
    pub languages: Vec<String>,
    pub blocks: Vec<ContextTextBlock>,
}

/// Why a well-formed proposal did not become evidence.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum ContextRejection {
    UnknownScope,
    StaleEpoch,
    Paused,
    Revoked,
    Failed,
    NotRecording,
    NonMonotonic,
    Duplicate,
    NoSemanticContent,
    TooLarge,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct AcceptedContextEvent {
    pub event_id: String,
    pub start_ns: i64,
    pub end_ns: i64,
    pub semantic_hash: String,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum ContextDecision {
    Accepted(AcceptedContextEvent),
    Rejected(ContextRejection),
}

/// An accepted event as review surfaces read it.
#[derive(Clone, Debug, PartialEq)]
pub struct ContextEventRecord {
    pub event_id: String,
    pub scope_id: String,
    pub epoch: u32,
    pub start_ns: i64,
    pub end_ns: i64,
    pub observed_at_ms: i64,
    pub reason: String,
    pub source_name: String,
    pub application: Option<String>,
    /// Blocks in reading order, one per line.
    pub text: String,
    pub block_count: u32,
    pub semantic_hash: String,
    pub event_digest: String,
    pub retention: String,
}

fn bounded(value: &str, maximum: usize) -> bool {
    !value.trim().is_empty() && value.len() <= maximum && !value.chars().any(char::is_control)
}

fn revision_ok(value: &str) -> bool {
    !value.is_empty() && value.len() <= 64 && value.bytes().all(|byte| byte.is_ascii_graphic())
}

/// Collapses every whitespace run to one space; any other control
/// character makes the proposal malformed.
fn normalize_text(text: &str) -> Result<String, StoreError> {
    if text
        .chars()
        .any(|character| character.is_control() && !character.is_whitespace())
    {
        return Err(StoreError::InvalidRequest(
            "recognized text has a control character",
        ));
    }
    Ok(text.split_whitespace().collect::<Vec<_>>().join(" "))
}

fn quantize(block: &ContextTextBlock) -> Result<[u16; 4], StoreError> {
    let bounds = ContextBounds {
        display_id: "block".into(),
        x: block.x,
        y: block.y,
        width: block.width,
        height: block.height,
    };
    validate_bounds(&bounds)?;
    let scaled = |value: f64| (value * BOX_SCALE).round().clamp(0.0, BOX_SCALE) as u16;
    Ok([
        scaled(block.x),
        scaled(block.y),
        scaled(block.width).max(1),
        scaled(block.height).max(1),
    ])
}

/// Validates and orders the blocks: rows in bands of one hundredth of the
/// region height, left to right within a band.
fn reduce_blocks(blocks: &[ContextTextBlock]) -> Result<Vec<(String, [u16; 4])>, StoreError> {
    if blocks.len() > MAX_BLOCKS {
        return Err(StoreError::InvalidRequest("too many text blocks"));
    }
    let mut reduced = Vec::with_capacity(blocks.len());
    for block in blocks {
        let text = normalize_text(&block.text)?;
        if text.len() > MAX_BLOCK_TEXT_BYTES {
            return Err(StoreError::InvalidRequest("a text block is too long"));
        }
        let quantized = quantize(block)?;
        if !text.is_empty() {
            reduced.push((text, quantized));
        }
    }
    reduced.sort_by(|a, b| {
        (a.1[1] / 10, a.1[0], a.1[1], &a.0).cmp(&(b.1[1] / 10, b.1[0], b.1[1], &b.0))
    });
    Ok(reduced)
}

impl SessionStore {
    pub fn propose_context_event(
        &mut self,
        session: SessionId,
        proposal: ContextProposal,
    ) -> Result<ContextDecision, StoreError> {
        let invalid = StoreError::InvalidRequest;
        if !bounded(&proposal.source.platform_id, 128)
            || !bounded(&proposal.source.name, 512)
            || !proposal
                .source
                .application
                .as_deref()
                .is_none_or(|name| bounded(name, 512))
            || !revision_ok(&proposal.reducer_revision)
            || !revision_ok(&proposal.vision_revision)
            || proposal.languages.len() > MAX_LANGUAGES
            || proposal.languages.iter().any(|language| {
                !(2..=35).contains(&language.len())
                    || !language
                        .bytes()
                        .all(|byte| byte.is_ascii_alphanumeric() || byte == b'-')
            })
            || proposal.end_host_time < proposal.start_host_time
        {
            return Err(invalid("malformed context proposal"));
        }
        if let Some(bounds) = &proposal.bounds {
            validate_bounds(bounds)?;
        }
        let blocks = reduce_blocks(&proposal.blocks)?;

        let reject = |reason: ContextRejection| -> Result<ContextDecision, StoreError> {
            Ok(ContextDecision::Rejected(reason))
        };
        let known: Option<(String, String)> = self
            .connection
            .query_row(
                "SELECT condition, receipt_json FROM context_scopes
                 WHERE session_id = ?1 AND scope_id = ?2 AND epoch = ?3",
                params![session.0, proposal.scope_id, proposal.epoch],
                |row| Ok((row.get(0)?, row.get(1)?)),
            )
            .optional()?;
        let Some((condition, receipt)) = known else {
            return reject(ContextRejection::UnknownScope);
        };
        match condition.as_str() {
            "active" => {}
            "paused" => return reject(ContextRejection::Paused),
            "revoked" => return reject(ContextRejection::Revoked),
            "failed" => return reject(ContextRejection::Failed),
            _ => return reject(ContextRejection::StaleEpoch),
        }
        let receipt: Value = serde_json::from_str(&receipt)?;
        let mode: ContextMode = serde_json::from_value(
            receipt
                .get("mode")
                .cloned()
                .ok_or(StoreError::IntegrityMismatch("scope mode is missing"))?,
        )?;
        let reason_fits = match (mode, proposal.reason) {
            (_, ContextEventReason::UserMarked) => true,
            (ContextMode::FollowPointer, reason) => reason == ContextEventReason::Attention,
            (ContextMode::AddCurrentWindow, _) => false,
            (_, reason) => reason == ContextEventReason::FixedScopeChange,
        };
        if !reason_fits {
            return Err(invalid("the event reason does not match the scope mode"));
        }

        let lifecycle: String = self.connection.query_row(
            "SELECT lifecycle FROM sessions WHERE id = ?1",
            [&session.0],
            |row| row.get(0),
        )?;
        if lifecycle != "recording" || self.capture_clock(&session.0)?.is_none() {
            return reject(ContextRejection::NotRecording);
        }
        // A frame from before the latest pause or resume boundary was not
        // observed during the current recording span.
        let boundary: Option<i64> = self
            .connection
            .query_row(
                "SELECT json_extract(payload_json, '$.host_time') FROM session_events
                 WHERE session_id = ?1 AND event_kind IN ('capture_paused', 'capture_resumed')
                 ORDER BY sequence DESC LIMIT 1",
                [&session.0],
                |row| row.get(0),
            )
            .optional()?
            .flatten();
        if boundary.is_some_and(|host| i128::from(proposal.start_host_time) < i128::from(host)) {
            return reject(ContextRejection::NotRecording);
        }
        let start_ns = self.map_capture_time(&session.0, proposal.start_host_time)?;
        let end_ns = self.map_capture_time(&session.0, proposal.end_host_time)?;
        if start_ns < 0 || end_ns < start_ns {
            return reject(ContextRejection::NotRecording);
        }
        let last: Option<(i64, String)> = self
            .connection
            .query_row(
                "SELECT start_ns, event_digest FROM context_events
                 WHERE session_id = ?1 ORDER BY start_ns DESC, rowid DESC LIMIT 1",
                [&session.0],
                |row| Ok((row.get(0)?, row.get(1)?)),
            )
            .optional()?;
        if last
            .as_ref()
            .is_some_and(|(previous, _)| start_ns < *previous)
        {
            return reject(ContextRejection::NonMonotonic);
        }
        if blocks.is_empty() && proposal.reason != ContextEventReason::UserMarked {
            return reject(ContextRejection::NoSemanticContent);
        }
        let block_values: Vec<Value> = blocks
            .iter()
            .map(|(text, quantized)| json!({"text": text, "box": quantized}))
            .collect();
        let semantic_hash = digest_json(&json!({
            "reducer_revision": proposal.reducer_revision,
            "scope_id": proposal.scope_id,
            "blocks": block_values,
        }))?;
        if proposal.reason != ContextEventReason::UserMarked {
            let previous: Option<String> = self
                .connection
                .query_row(
                    "SELECT semantic_hash FROM context_events
                     WHERE scope_id = ?1 AND epoch = ?2 ORDER BY rowid DESC LIMIT 1",
                    params![proposal.scope_id, proposal.epoch],
                    |row| row.get(0),
                )
                .optional()?;
            if previous.as_deref() == Some(semantic_hash.as_str()) {
                return reject(ContextRejection::Duplicate);
            }
        }

        let event_id = Uuid::now_v7().to_string();
        let mut event = json!({
            "schema": CONTEXT_EVENT_SCHEMA,
            "event_id": event_id,
            "session_id": session.0,
            "scope_id": proposal.scope_id,
            "epoch": proposal.epoch,
            "mode": mode,
            "start_ns": start_ns,
            "end_ns": end_ns,
            "session_nanoseconds": start_ns,
            "observed_at_ms": proposal.observed_at_ms,
            "reason": proposal.reason.as_str(),
            "source": {
                "platform_id": proposal.source.platform_id,
                "name": proposal.source.name,
                "application": proposal.source.application,
            },
            "bounds": proposal.bounds,
            "reducer_revision": proposal.reducer_revision,
            "vision_revision": proposal.vision_revision,
            "languages": proposal.languages,
            "blocks": block_values,
            "semantic_hash": semantic_hash,
            "prior_event_digest": last.map(|(_, digest)| digest),
            "retention": "no_pixels",
            "snapshot": null,
        });
        let event_digest = digest_json(&event)?;
        event["event_digest"] = json!(event_digest);
        if serde_json::to_vec(&event)?.len() + JOURNAL_ENVELOPE_BYTES > MAX_JOURNAL_RECORD_BYTES {
            return reject(ContextRejection::TooLarge);
        }
        let record =
            self.append_session_journal(&session.0, "context_event_accepted", None, event)?;
        self.project_context_record(&session.0, &record)?;
        Ok(ContextDecision::Accepted(AcceptedContextEvent {
            event_id,
            start_ns,
            end_ns,
            semantic_hash,
        }))
    }

    pub fn context_events(
        &self,
        session: &SessionId,
    ) -> Result<Vec<ContextEventRecord>, StoreError> {
        let mut statement = self.connection.prepare(
            "SELECT id, scope_id, epoch, start_ns, end_ns, observed_at_ms, reason,
                    json_extract(event_json, '$.source.name'),
                    json_extract(event_json, '$.source.application'),
                    text, json_array_length(event_json, '$.blocks'), semantic_hash,
                    event_digest, retention
             FROM context_events WHERE session_id = ?1 ORDER BY start_ns, rowid",
        )?;
        let rows = statement
            .query_map([&session.0], |row| {
                Ok(ContextEventRecord {
                    event_id: row.get(0)?,
                    scope_id: row.get(1)?,
                    epoch: row.get(2)?,
                    start_ns: row.get(3)?,
                    end_ns: row.get(4)?,
                    observed_at_ms: row.get(5)?,
                    reason: row.get(6)?,
                    source_name: row.get(7)?,
                    application: row.get(8)?,
                    text: row.get(9)?,
                    block_count: row.get(10)?,
                    semantic_hash: row.get(11)?,
                    event_digest: row.get(12)?,
                    retention: row.get(13)?,
                })
            })?
            .collect::<Result<Vec<_>, _>>()?;
        Ok(rows)
    }
}

/// Projects an accepted event from its journal payload alone, so replay
/// reproduces exactly what the live acceptance stored.
pub(super) fn project_accepted_context_event(
    tx: &Transaction<'_>,
    session: &str,
    event: &Value,
) -> Result<(), StoreError> {
    if payload_string(event, "schema")? != CONTEXT_EVENT_SCHEMA {
        return Err(StoreError::IntegrityMismatch("unsupported context event"));
    }
    let text = event
        .get("blocks")
        .and_then(Value::as_array)
        .ok_or(StoreError::IntegrityMismatch("context blocks are missing"))?
        .iter()
        .map(|block| payload_string(block, "text"))
        .collect::<Result<Vec<_>, _>>()?
        .join("\n");
    let mut body = event.clone();
    if let Some(object) = body.as_object_mut() {
        object.remove("event_digest");
    }
    let event_digest = payload_string(event, "event_digest")?;
    if digest_json(&body)? != event_digest {
        return Err(StoreError::IntegrityMismatch(
            "context event digest mismatch",
        ));
    }
    tx.execute(
        "INSERT INTO context_events (id, session_id, scope_id, epoch, start_ns, end_ns,
         observed_at_ms, reason, semantic_hash, prior_event_digest, event_digest, retention,
         text, event_json)
         VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14)",
        params![
            payload_string(event, "event_id")?,
            session,
            payload_string(event, "scope_id")?,
            payload_i64(event, "epoch")?,
            payload_i64(event, "start_ns")?,
            payload_i64(event, "end_ns")?,
            payload_i64(event, "observed_at_ms")?,
            payload_string(event, "reason")?,
            payload_string(event, "semantic_hash")?,
            event.get("prior_event_digest").and_then(Value::as_str),
            event_digest,
            payload_string(event, "retention")?,
            text,
            serde_json::to_string(event)?
        ],
    )?;
    Ok(())
}
