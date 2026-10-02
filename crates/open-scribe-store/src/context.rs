//! Explicit context scope authority (ADR 0011) and declared session metadata.
//!
//! Swift owns selection, topology, sampling, and overlays; this module owns
//! the durable scope receipt, its authorization epoch, and its condition.
//! Every change is journaled before it is projected. Any change to what is
//! observed, including resuming after a pause, issues a new epoch, so work
//! queued under an earlier epoch can never be accepted
//! (`context_events.rs`). Context never moves the recording lifecycle.

use super::*;
use rusqlite::OptionalExtension;

pub(super) const CONTEXT_MIGRATION_VERSION: i64 = 8;
pub const CONTEXT_SCOPE_SCHEMA: &str = "open-scribe.context-scope/v1";
const MAX_TARGETS: usize = 16;
const MAX_DISPLAYS: usize = 16;
const MAX_NAME_BYTES: usize = 512;
const MAX_PLATFORM_ID_BYTES: usize = 128;
const MAX_PARTICIPANTS: usize = 32;
const MAX_TOPIC_BYTES: usize = 512;
/// Surfaces a scope may exclude. Self-exclusion is mandatory; the others are
/// best-effort safeguards the UI discloses as such.
pub const CONTEXT_EXCLUSIONS: [&str; 7] = [
    "open_scribe",
    "dock",
    "menu_bar",
    "notifications",
    "password_managers",
    "private_windows",
    "lock_screen",
];
const OPEN_LIFECYCLES: [&str; 4] = ["preparing", "recording", "finalizing", "paused"];

pub(super) fn apply_context_schema(transaction: &Transaction<'_>) -> Result<(), StoreError> {
    transaction.execute_batch(
        "CREATE TABLE IF NOT EXISTS context_scopes (
            scope_id TEXT NOT NULL,
            epoch INTEGER NOT NULL CHECK (epoch >= 1),
            session_id TEXT NOT NULL REFERENCES sessions(id),
            receipt_json TEXT NOT NULL,
            condition TEXT NOT NULL
                CHECK (condition IN ('active', 'paused', 'revoked', 'failed', 'superseded')),
            reason TEXT,
            authorized_at_ms INTEGER NOT NULL,
            changed_at_ms INTEGER NOT NULL,
            PRIMARY KEY (scope_id, epoch)
        );
        CREATE INDEX IF NOT EXISTS context_scopes_by_session
            ON context_scopes(session_id, authorized_at_ms);
        CREATE TABLE IF NOT EXISTS context_events (
            id TEXT PRIMARY KEY,
            session_id TEXT NOT NULL REFERENCES sessions(id),
            scope_id TEXT NOT NULL,
            epoch INTEGER NOT NULL,
            start_ns INTEGER NOT NULL CHECK (start_ns >= 0),
            end_ns INTEGER NOT NULL CHECK (end_ns >= start_ns),
            observed_at_ms INTEGER NOT NULL,
            reason TEXT NOT NULL
                CHECK (reason IN ('attention', 'fixed_scope_change', 'user_marked')),
            semantic_hash TEXT NOT NULL,
            prior_event_digest TEXT,
            event_digest TEXT NOT NULL,
            retention TEXT NOT NULL CHECK (retention = 'no_pixels'),
            text TEXT NOT NULL,
            event_json TEXT NOT NULL,
            FOREIGN KEY (scope_id, epoch) REFERENCES context_scopes(scope_id, epoch)
        );
        CREATE INDEX IF NOT EXISTS context_events_by_session
            ON context_events(session_id, start_ns);
        CREATE TRIGGER IF NOT EXISTS context_events_append_only
            BEFORE UPDATE ON context_events
            BEGIN SELECT RAISE(ABORT, 'context events are append-only'); END;
        CREATE TABLE IF NOT EXISTS session_declarations (
            session_id TEXT PRIMARY KEY REFERENCES sessions(id),
            participants_json TEXT NOT NULL,
            topic TEXT,
            declared_at_ms INTEGER NOT NULL
        );",
    )?;
    Ok(())
}

#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum ContextMode {
    FollowPointer,
    WatchDisplay,
    WatchWindow,
    WatchRegion,
    AddCurrentWindow,
}

#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum ContextTargetKind {
    Display,
    Window,
}

/// One authorized platform surface, named as the user saw it.
#[derive(Clone, Debug, Deserialize, PartialEq, Serialize)]
#[serde(deny_unknown_fields)]
pub struct ContextTarget {
    pub kind: ContextTargetKind,
    pub platform_id: String,
    pub name: String,
    pub application: Option<String>,
    /// Human-readable identity, such as "Built-in Display, left of Studio Display".
    pub description: String,
}

/// Display-relative bounds, normalized to the display with a top-left origin.
#[derive(Clone, Debug, Deserialize, PartialEq, Serialize)]
#[serde(deny_unknown_fields)]
pub struct ContextBounds {
    pub display_id: String,
    pub x: f64,
    pub y: f64,
    pub width: f64,
    pub height: f64,
}

/// One display in global Core Graphics points at authorization time.
#[derive(Clone, Debug, Deserialize, PartialEq, Serialize)]
#[serde(deny_unknown_fields)]
pub struct DisplayTopology {
    pub display_id: String,
    pub name: String,
    pub x: f64,
    pub y: f64,
    pub width: f64,
    pub height: f64,
    pub scale: f64,
    pub rotation: f64,
    pub is_main: bool,
}

#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum ScreenPermission {
    Granted,
    NotDetermined,
    Denied,
}

#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum ContextRetention {
    NoPixels,
    UserMarkedSnapshots,
    MeaningfulSnapshots,
}

/// What the user confirmed in preflight.
#[derive(Clone, Debug, Deserialize, PartialEq, Serialize)]
#[serde(deny_unknown_fields)]
pub struct ContextScopeRequest {
    pub mode: ContextMode,
    pub targets: Vec<ContextTarget>,
    pub bounds: Option<ContextBounds>,
    pub topology: Vec<DisplayTopology>,
    pub exclusions: Vec<String>,
    pub permission: ScreenPermission,
    pub retention: ContextRetention,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum ContextPauseReason {
    User,
    TopologyChanged,
    ScreenLocked,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum ContextFailureReason {
    PermissionLost,
    DisplayRemoved,
    CaptureFailed,
}

#[derive(Clone, Debug, PartialEq)]
pub enum ContextAction {
    /// Authorizes a scope; while one is live this is a change and issues a new epoch.
    Authorize(ContextScopeRequest),
    Pause(ContextPauseReason),
    /// Continues a user or lock-screen pause under a new epoch. A topology
    /// pause needs a newly confirmed scope instead.
    Resume {
        permission: ScreenPermission,
    },
    Revoke,
    Fail(ContextFailureReason),
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum ContextCondition {
    Active,
    Paused,
    Revoked,
    Failed,
    Superseded,
    /// Derived: the capture session closed while the scope was live.
    Ended,
}

#[derive(Clone, Debug, PartialEq)]
pub struct ContextScope {
    pub scope_id: String,
    pub epoch: u32,
    pub request: ContextScopeRequest,
    pub condition: ContextCondition,
    pub reason: Option<String>,
    pub authorized_at_ms: i64,
    pub changed_at_ms: i64,
}

#[derive(Clone, Debug, Default, PartialEq)]
pub struct SessionDeclaration {
    pub participants: Vec<String>,
    pub topic: Option<String>,
}

#[derive(Clone, Debug, PartialEq)]
pub struct ContextDetail {
    /// Every epoch in authorization order; the last is current.
    pub scopes: Vec<ContextScope>,
    pub accepted_events: u32,
    pub declaration: SessionDeclaration,
}

impl ContextDetail {
    pub fn current(&self) -> Option<&ContextScope> {
        self.scopes.last()
    }
}

fn bounded(value: &str, maximum: usize) -> bool {
    !value.trim().is_empty() && value.len() <= maximum && !value.chars().any(char::is_control)
}

fn validate_request(request: &ContextScopeRequest) -> Result<(), StoreError> {
    let invalid = StoreError::InvalidRequest;
    if request.retention != ContextRetention::NoPixels {
        return Err(invalid("snapshot retention is not available"));
    }
    if request.targets.is_empty() || request.targets.len() > MAX_TARGETS {
        return Err(invalid("a scope names between one and sixteen targets"));
    }
    for target in &request.targets {
        if !bounded(&target.platform_id, MAX_PLATFORM_ID_BYTES)
            || !bounded(&target.name, MAX_NAME_BYTES)
            || !bounded(&target.description, MAX_NAME_BYTES)
            || !target
                .application
                .as_deref()
                .is_none_or(|name| bounded(name, MAX_NAME_BYTES))
        {
            return Err(invalid("a scope target needs bounded identity and names"));
        }
    }
    let kinds: Vec<_> = request.targets.iter().map(|target| target.kind).collect();
    let displays_only = kinds.iter().all(|kind| *kind == ContextTargetKind::Display);
    let consistent = match request.mode {
        ContextMode::FollowPointer => displays_only,
        ContextMode::WatchDisplay | ContextMode::WatchRegion => displays_only && kinds.len() == 1,
        ContextMode::WatchWindow | ContextMode::AddCurrentWindow => {
            kinds == [ContextTargetKind::Window]
        }
    };
    if !consistent {
        return Err(invalid("scope targets do not match the selected mode"));
    }
    if request.topology.is_empty() || request.topology.len() > MAX_DISPLAYS {
        return Err(invalid("topology names between one and sixteen displays"));
    }
    let mut display_ids = BTreeSet::new();
    for display in &request.topology {
        let finite = [
            display.x,
            display.y,
            display.width,
            display.height,
            display.scale,
        ]
        .iter()
        .all(|value| value.is_finite());
        if !bounded(&display.display_id, MAX_PLATFORM_ID_BYTES)
            || !bounded(&display.name, MAX_NAME_BYTES)
            || !finite
            || display.width <= 0.0
            || display.height <= 0.0
            || display.scale <= 0.0
            || display.scale > 8.0
            || ![0.0, 90.0, 180.0, 270.0].contains(&display.rotation)
            || !display_ids.insert(display.display_id.as_str())
        {
            return Err(invalid("topology display is malformed or duplicated"));
        }
    }
    if request.targets.iter().any(|target| {
        target.kind == ContextTargetKind::Display
            && !display_ids.contains(target.platform_id.as_str())
    }) {
        return Err(invalid("a display target is absent from the topology"));
    }
    match (&request.bounds, request.mode) {
        (Some(bounds), ContextMode::WatchRegion) => {
            validate_bounds(bounds)?;
            if bounds.display_id != request.targets[0].platform_id {
                return Err(invalid("region bounds belong to another display"));
            }
        }
        (None, ContextMode::WatchRegion) => return Err(invalid("a region scope needs bounds")),
        (Some(_), _) => return Err(invalid("only a region scope carries bounds")),
        (None, _) => {}
    }
    let mut exclusions = BTreeSet::new();
    for exclusion in &request.exclusions {
        if !CONTEXT_EXCLUSIONS.contains(&exclusion.as_str()) || !exclusions.insert(exclusion) {
            return Err(invalid("unknown or repeated exclusion"));
        }
    }
    if !exclusions.contains(&"open_scribe".to_owned()) {
        return Err(invalid("a scope must exclude Open Scribe itself"));
    }
    Ok(())
}

pub(super) fn validate_bounds(bounds: &ContextBounds) -> Result<(), StoreError> {
    const SLACK: f64 = 1e-9;
    let values = [bounds.x, bounds.y, bounds.width, bounds.height];
    if !bounded(&bounds.display_id, MAX_PLATFORM_ID_BYTES)
        || !values.iter().all(|value| value.is_finite())
        || bounds.x < 0.0
        || bounds.y < 0.0
        || bounds.width <= 0.0
        || bounds.height <= 0.0
        || bounds.x + bounds.width > 1.0 + SLACK
        || bounds.y + bounds.height > 1.0 + SLACK
    {
        return Err(StoreError::InvalidRequest(
            "bounds must be normalized inside the display",
        ));
    }
    Ok(())
}

struct EpochRow {
    scope_id: String,
    epoch: u32,
    condition: String,
    reason: Option<String>,
}

fn condition_from(value: &str) -> Result<ContextCondition, StoreError> {
    Ok(match value {
        "active" => ContextCondition::Active,
        "paused" => ContextCondition::Paused,
        "revoked" => ContextCondition::Revoked,
        "failed" => ContextCondition::Failed,
        "superseded" => ContextCondition::Superseded,
        _ => return Err(StoreError::IntegrityMismatch("unknown context condition")),
    })
}

impl SessionStore {
    fn session_lifecycle(&self, session: &str) -> Result<String, StoreError> {
        self.connection
            .query_row(
                "SELECT lifecycle FROM sessions WHERE id = ?1",
                [session],
                |row| row.get(0),
            )
            .optional()?
            .ok_or(StoreError::InvalidRequest("unknown session"))
    }

    /// The latest epoch row for the session, with its stored condition.
    fn current_context_scope(&self, session: &str) -> Result<Option<EpochRow>, StoreError> {
        Ok(self
            .connection
            .query_row(
                "SELECT scope_id, epoch, condition, reason FROM context_scopes
                 WHERE session_id = ?1 ORDER BY rowid DESC LIMIT 1",
                [session],
                |row| {
                    Ok(EpochRow {
                        scope_id: row.get(0)?,
                        epoch: row.get(1)?,
                        condition: row.get(2)?,
                        reason: row.get(3)?,
                    })
                },
            )
            .optional()?)
    }

    pub fn context_action(
        &mut self,
        session: SessionId,
        action: ContextAction,
    ) -> Result<ContextDetail, StoreError> {
        let lifecycle = self.session_lifecycle(&session.0)?;
        if !OPEN_LIFECYCLES.contains(&lifecycle.as_str()) {
            return Err(StoreError::InvalidState(
                "context requires an open capture session",
            ));
        }
        let current = self.current_context_scope(&session.0)?;
        let live = current
            .as_ref()
            .filter(|scope| matches!(scope.condition.as_str(), "active" | "paused"));
        let now = wall_time_milliseconds();
        let (kind, payload) = match action {
            ContextAction::Authorize(request) => {
                validate_request(&request)?;
                if request.permission != ScreenPermission::Granted {
                    return Err(StoreError::InvalidState(
                        "screen recording permission is not granted",
                    ));
                }
                let (scope_id, epoch, superseded) = match live {
                    Some(scope) => (scope.scope_id.clone(), scope.epoch + 1, Some(scope.epoch)),
                    None => (Uuid::now_v7().to_string(), 1, None),
                };
                let mut receipt = serde_json::to_value(&request)?;
                receipt["schema"] = json!(CONTEXT_SCOPE_SCHEMA);
                receipt["scope_id"] = json!(scope_id);
                receipt["epoch"] = json!(epoch);
                receipt["authorized_at_ms"] = json!(now);
                (
                    "context_scope_authorized",
                    json!({"receipt": receipt, "superseded_epoch": superseded}),
                )
            }
            ContextAction::Pause(reason) => {
                let EpochRow {
                    scope_id, epoch, ..
                } = live
                    .filter(|scope| scope.condition == "active")
                    .ok_or(StoreError::InvalidState("no active context scope"))?;
                let reason = match reason {
                    ContextPauseReason::User => "user",
                    ContextPauseReason::TopologyChanged => "topology_changed",
                    ContextPauseReason::ScreenLocked => "screen_locked",
                };
                (
                    "context_scope_paused",
                    json!({"scope_id": scope_id, "epoch": epoch, "reason": reason}),
                )
            }
            ContextAction::Resume { permission } => {
                let EpochRow {
                    scope_id,
                    epoch,
                    reason,
                    ..
                } = live
                    .filter(|scope| scope.condition == "paused")
                    .ok_or(StoreError::InvalidState("no paused context scope"))?;
                if !matches!(reason.as_deref(), Some("user" | "screen_locked")) {
                    return Err(StoreError::InvalidState(
                        "the displays changed; confirm a valid scope",
                    ));
                }
                if permission != ScreenPermission::Granted {
                    return Err(StoreError::InvalidState(
                        "screen recording permission is not granted",
                    ));
                }
                (
                    "context_scope_resumed",
                    json!({"scope_id": scope_id, "prior_epoch": epoch, "epoch": epoch + 1}),
                )
            }
            ContextAction::Revoke => {
                let EpochRow {
                    scope_id, epoch, ..
                } = live.ok_or(StoreError::InvalidState("no live context scope"))?;
                (
                    "context_scope_revoked",
                    json!({"scope_id": scope_id, "epoch": epoch, "reason": "user"}),
                )
            }
            ContextAction::Fail(reason) => {
                let EpochRow {
                    scope_id, epoch, ..
                } = live.ok_or(StoreError::InvalidState("no live context scope"))?;
                let reason = match reason {
                    ContextFailureReason::PermissionLost => "permission_lost",
                    ContextFailureReason::DisplayRemoved => "display_removed",
                    ContextFailureReason::CaptureFailed => "capture_failed",
                };
                (
                    "context_scope_failed",
                    json!({"scope_id": scope_id, "epoch": epoch, "reason": reason}),
                )
            }
        };
        let record = self.append_session_journal(&session.0, kind, None, payload)?;
        self.project_context_record(&session.0, &record)?;
        self.context_detail(&session)
    }

    /// Records optional participant and topic metadata. Declaring them grants
    /// no context permission (ADR 0011).
    pub fn declare_session(
        &mut self,
        session: SessionId,
        declaration: SessionDeclaration,
    ) -> Result<SessionDeclaration, StoreError> {
        let lifecycle = self.session_lifecycle(&session.0)?;
        if !OPEN_LIFECYCLES.contains(&lifecycle.as_str()) && lifecycle != "ready_for_review" {
            return Err(StoreError::InvalidState("the session cannot be declared"));
        }
        let participants: Vec<String> = declaration
            .participants
            .iter()
            .map(|name| name.trim().to_owned())
            .filter(|name| !name.is_empty())
            .collect();
        let topic = declaration
            .topic
            .map(|topic| topic.trim().to_owned())
            .filter(|topic| !topic.is_empty());
        if participants.len() > MAX_PARTICIPANTS
            || participants
                .iter()
                .any(|name| !bounded(name, MAX_NAME_BYTES))
            || !topic
                .as_deref()
                .is_none_or(|topic| bounded(topic, MAX_TOPIC_BYTES))
        {
            return Err(StoreError::InvalidRequest(
                "participants and topic must be bounded text",
            ));
        }
        let record = self.append_session_journal(
            &session.0,
            "session_declared",
            None,
            json!({"participants": participants, "topic": topic}),
        )?;
        self.project_context_record(&session.0, &record)?;
        Ok(self.context_detail(&session)?.declaration)
    }

    pub fn context_detail(&self, session: &SessionId) -> Result<ContextDetail, StoreError> {
        let lifecycle = self.session_lifecycle(&session.0)?;
        let open = OPEN_LIFECYCLES.contains(&lifecycle.as_str());
        let mut statement = self.connection.prepare(
            "SELECT scope_id, epoch, receipt_json, condition, reason, authorized_at_ms, changed_at_ms
             FROM context_scopes WHERE session_id = ?1 ORDER BY rowid",
        )?;
        let scopes = statement
            .query_map([&session.0], |row| {
                Ok((
                    row.get::<_, String>(0)?,
                    row.get::<_, u32>(1)?,
                    row.get::<_, String>(2)?,
                    row.get::<_, String>(3)?,
                    row.get::<_, Option<String>>(4)?,
                    row.get::<_, i64>(5)?,
                    row.get::<_, i64>(6)?,
                ))
            })?
            .map(|row| {
                let (scope_id, epoch, receipt, condition, reason, authorized, changed) = row?;
                let mut receipt: Value = serde_json::from_str(&receipt)?;
                if receipt.get("schema").and_then(Value::as_str) != Some(CONTEXT_SCOPE_SCHEMA) {
                    return Err(StoreError::IntegrityMismatch("unsupported scope receipt"));
                }
                if let Some(object) = receipt.as_object_mut() {
                    for key in ["schema", "scope_id", "epoch", "authorized_at_ms"] {
                        object.remove(key);
                    }
                }
                let mut condition = condition_from(&condition)?;
                if !open
                    && matches!(
                        condition,
                        ContextCondition::Active | ContextCondition::Paused
                    )
                {
                    condition = ContextCondition::Ended;
                }
                Ok(ContextScope {
                    scope_id,
                    epoch,
                    request: serde_json::from_value(receipt)?,
                    condition,
                    reason,
                    authorized_at_ms: authorized,
                    changed_at_ms: changed,
                })
            })
            .collect::<Result<Vec<_>, StoreError>>()?;
        let accepted_events: u32 = self.connection.query_row(
            "SELECT COUNT(*) FROM context_events WHERE session_id = ?1",
            [&session.0],
            |row| row.get(0),
        )?;
        let declaration = self
            .connection
            .query_row(
                "SELECT participants_json, topic FROM session_declarations WHERE session_id = ?1",
                [&session.0],
                |row| Ok((row.get::<_, String>(0)?, row.get::<_, Option<String>>(1)?)),
            )
            .optional()?
            .map(|(participants, topic)| {
                Ok::<_, StoreError>(SessionDeclaration {
                    participants: serde_json::from_str(&participants)?,
                    topic,
                })
            })
            .transpose()?
            .unwrap_or_default();
        Ok(ContextDetail {
            scopes,
            accepted_events,
            declaration,
        })
    }

    /// Projects one journaled context record; a record already projected is
    /// skipped, so replay after a crash is idempotent.
    pub(super) fn project_context_record(
        &mut self,
        session: &str,
        record: &JournalRecord,
    ) -> Result<(), StoreError> {
        let present: bool = self.connection.query_row(
            "SELECT EXISTS(SELECT 1 FROM session_events WHERE id = ?1)",
            [&record.body.event_id],
            |row| row.get(0),
        )?;
        if present {
            return Ok(());
        }
        let kind = record.body.event_kind.as_str();
        let p = &record.body.payload;
        let at = record.body.wall_time_milliseconds;
        let (sequence, prior) = next_database_event(&self.connection, session)?;
        let digest = event_digest(session, sequence, kind, p, prior.as_deref())?;
        let tx = self.connection.transaction()?;
        let set_condition = |condition: &str, epoch_key: &str, reason: Option<&str>| {
            tx.execute(
                "UPDATE context_scopes SET condition = ?3, reason = ?4, changed_at_ms = ?5
                 WHERE scope_id = ?1 AND epoch = ?2 AND session_id = ?6",
                params![
                    payload_string(p, "scope_id")?,
                    payload_i64(p, epoch_key)?,
                    condition,
                    reason,
                    at,
                    session
                ],
            )
            .map_err(StoreError::from)
        };
        match kind {
            "context_scope_authorized" => {
                let receipt = p
                    .get("receipt")
                    .ok_or(StoreError::IntegrityMismatch("scope receipt is missing"))?;
                let scope_id = payload_string(receipt, "scope_id")?;
                if let Some(epoch) = p.get("superseded_epoch").and_then(Value::as_i64) {
                    tx.execute(
                        "UPDATE context_scopes SET condition = 'superseded', reason = 'changed',
                         changed_at_ms = ?3 WHERE scope_id = ?1 AND epoch = ?2",
                        params![scope_id, epoch, at],
                    )?;
                }
                tx.execute(
                    "INSERT INTO context_scopes (scope_id, epoch, session_id, receipt_json,
                     condition, reason, authorized_at_ms, changed_at_ms)
                     VALUES (?1, ?2, ?3, ?4, 'active', NULL, ?5, ?5)",
                    params![
                        scope_id,
                        payload_i64(receipt, "epoch")?,
                        session,
                        serde_json::to_string(receipt)?,
                        payload_i64(receipt, "authorized_at_ms")?
                    ],
                )?;
            }
            "context_scope_paused" => {
                set_condition("paused", "epoch", Some(payload_string(p, "reason")?))?;
            }
            "context_scope_resumed" => {
                set_condition("superseded", "prior_epoch", Some("resumed"))?;
                let scope_id = payload_string(p, "scope_id")?;
                let receipt: String = tx.query_row(
                    "SELECT receipt_json FROM context_scopes WHERE scope_id = ?1 AND epoch = ?2",
                    params![scope_id, payload_i64(p, "prior_epoch")?],
                    |row| row.get(0),
                )?;
                let mut receipt: Value = serde_json::from_str(&receipt)?;
                receipt["epoch"] = json!(payload_i64(p, "epoch")?);
                receipt["authorized_at_ms"] = json!(at);
                tx.execute(
                    "INSERT INTO context_scopes (scope_id, epoch, session_id, receipt_json,
                     condition, reason, authorized_at_ms, changed_at_ms)
                     VALUES (?1, ?2, ?3, ?4, 'active', NULL, ?5, ?5)",
                    params![
                        scope_id,
                        payload_i64(p, "epoch")?,
                        session,
                        serde_json::to_string(&receipt)?,
                        at
                    ],
                )?;
            }
            "context_scope_revoked" => {
                set_condition("revoked", "epoch", Some(payload_string(p, "reason")?))?;
            }
            "context_scope_failed" => {
                set_condition("failed", "epoch", Some(payload_string(p, "reason")?))?;
            }
            "context_event_accepted" => {
                super::context_events::project_accepted_context_event(&tx, session, p)?;
            }
            "session_declared" => {
                tx.execute(
                    "INSERT INTO session_declarations (session_id, participants_json, topic,
                     declared_at_ms) VALUES (?1, ?2, ?3, ?4)
                     ON CONFLICT(session_id) DO UPDATE SET participants_json = excluded.participants_json,
                     topic = excluded.topic, declared_at_ms = excluded.declared_at_ms",
                    params![
                        session,
                        serde_json::to_string(
                            p.get("participants")
                                .ok_or(StoreError::IntegrityMismatch("participants are missing"))?
                        )?,
                        p.get("topic").and_then(Value::as_str),
                        at
                    ],
                )?;
            }
            _ => return Err(StoreError::IntegrityMismatch("not a context record")),
        }
        insert_event_with_id(
            &tx,
            &record.body.event_id,
            session,
            sequence,
            kind,
            at,
            p,
            prior.as_deref(),
            &digest,
        )?;
        tx.commit()?;
        Ok(())
    }

    pub(super) fn reconcile_context_events(
        &mut self,
        session: &str,
        records: &[JournalRecord],
    ) -> Result<(), StoreError> {
        for record in records.iter().filter(|record| {
            matches!(
                record.body.event_kind.as_str(),
                "context_scope_authorized"
                    | "context_scope_paused"
                    | "context_scope_resumed"
                    | "context_scope_revoked"
                    | "context_scope_failed"
                    | "context_event_accepted"
                    | "session_declared"
            )
        }) {
            self.project_context_record(session, record)?;
        }
        Ok(())
    }
}
