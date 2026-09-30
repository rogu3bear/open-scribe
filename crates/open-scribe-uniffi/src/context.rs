//! Coarse context scope and sparse event calls (ADR 0011, ADR 0012).
//!
//! Swift proposes only reduced text blocks and bounded names. Frames,
//! pointer samples, fingerprints, and frame-rate values never cross here.
//! Scope changes and proposals go through the recording controller, the one
//! writer of the session journal.

use super::*;
use open_scribe_core::{
    ContextAction, ContextBounds, ContextCondition, ContextDecision, ContextDetail,
    ContextEventReason, ContextFailureReason, ContextMode, ContextPauseReason, ContextProposal,
    ContextRejection, ContextRetention, ContextScopeRequest, ContextSource, ContextTarget,
    ContextTargetKind, ContextTextBlock, DisplayTopology, ScreenPermission, SessionDeclaration,
};
use open_scribe_types::SessionId;

#[derive(Clone, Copy, Debug, Eq, PartialEq, uniffi::Enum)]
pub enum NativeContextMode {
    FollowPointer,
    WatchDisplay,
    WatchWindow,
    WatchRegion,
    AddCurrentWindow,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq, uniffi::Enum)]
pub enum NativeContextTargetKind {
    Display,
    Window,
}

#[derive(Clone, Debug, Eq, PartialEq, uniffi::Record)]
pub struct NativeContextTarget {
    pub kind: NativeContextTargetKind,
    pub platform_id: String,
    pub name: String,
    pub application: Option<String>,
    pub description: String,
}

/// Normalized display-relative bounds with a top-left origin.
#[derive(Clone, Debug, PartialEq, uniffi::Record)]
pub struct NativeContextBounds {
    pub display_id: String,
    pub x: f64,
    pub y: f64,
    pub width: f64,
    pub height: f64,
}

#[derive(Clone, Debug, PartialEq, uniffi::Record)]
pub struct NativeDisplayTopology {
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

#[derive(Clone, Copy, Debug, Eq, PartialEq, uniffi::Enum)]
pub enum NativeScreenPermission {
    Granted,
    NotDetermined,
    Denied,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq, uniffi::Enum)]
pub enum NativeContextRetention {
    NoPixels,
    UserMarkedSnapshots,
    MeaningfulSnapshots,
}

#[derive(Clone, Debug, PartialEq, uniffi::Record)]
pub struct NativeContextScopeRequest {
    pub mode: NativeContextMode,
    pub targets: Vec<NativeContextTarget>,
    pub bounds: Option<NativeContextBounds>,
    pub topology: Vec<NativeDisplayTopology>,
    pub exclusions: Vec<String>,
    pub permission: NativeScreenPermission,
    pub retention: NativeContextRetention,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq, uniffi::Enum)]
pub enum NativeContextPauseReason {
    User,
    TopologyChanged,
    ScreenLocked,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq, uniffi::Enum)]
pub enum NativeContextFailureReason {
    PermissionLost,
    DisplayRemoved,
    CaptureFailed,
}

#[derive(Clone, Debug, PartialEq, uniffi::Enum)]
pub enum NativeContextAction {
    Authorize { request: NativeContextScopeRequest },
    Pause { reason: NativeContextPauseReason },
    Resume { permission: NativeScreenPermission },
    Revoke,
    Fail { reason: NativeContextFailureReason },
}

#[derive(Clone, Copy, Debug, Eq, PartialEq, uniffi::Enum)]
pub enum NativeContextCondition {
    Active,
    Paused,
    Revoked,
    Failed,
    Superseded,
    Ended,
}

#[derive(Clone, Debug, PartialEq, uniffi::Record)]
pub struct NativeContextScope {
    pub scope_id: String,
    pub epoch: u32,
    pub request: NativeContextScopeRequest,
    pub condition: NativeContextCondition,
    pub reason: Option<String>,
    pub authorized_at_ms: i64,
    pub changed_at_ms: i64,
}

#[derive(Clone, Debug, Eq, PartialEq, uniffi::Record)]
pub struct NativeSessionDeclaration {
    pub participants: Vec<String>,
    pub topic: Option<String>,
}

#[derive(Clone, Debug, PartialEq, uniffi::Record)]
pub struct NativeContextDetail {
    /// Every epoch in authorization order; the last is current.
    pub scopes: Vec<NativeContextScope>,
    pub accepted_events: u32,
    pub declaration: NativeSessionDeclaration,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq, uniffi::Enum)]
pub enum NativeContextEventReason {
    Attention,
    FixedScopeChange,
    UserMarked,
}

#[derive(Clone, Debug, Eq, PartialEq, uniffi::Record)]
pub struct NativeContextSource {
    pub platform_id: String,
    pub name: String,
    pub application: Option<String>,
}

/// One recognized line, normalized to the observed region (top-left origin).
#[derive(Clone, Debug, PartialEq, uniffi::Record)]
pub struct NativeContextTextBlock {
    pub text: String,
    pub x: f64,
    pub y: f64,
    pub width: f64,
    pub height: f64,
}

#[derive(Clone, Debug, PartialEq, uniffi::Record)]
pub struct NativeContextProposal {
    pub scope_id: String,
    pub epoch: u32,
    pub reason: NativeContextEventReason,
    pub start_host_time: u64,
    pub end_host_time: u64,
    pub observed_at_ms: i64,
    pub source: NativeContextSource,
    pub bounds: Option<NativeContextBounds>,
    pub reducer_revision: String,
    pub vision_revision: String,
    pub languages: Vec<String>,
    pub blocks: Vec<NativeContextTextBlock>,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq, uniffi::Enum)]
pub enum NativeContextRejection {
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

#[derive(Clone, Debug, Eq, PartialEq, uniffi::Enum)]
pub enum NativeContextDecision {
    Accepted {
        event_id: String,
        start_ns: i64,
        end_ns: i64,
        semantic_hash: String,
    },
    Rejected {
        reason: NativeContextRejection,
    },
}

#[derive(Clone, Debug, Eq, PartialEq, uniffi::Record)]
pub struct NativeContextEvent {
    pub event_id: String,
    pub scope_id: String,
    pub epoch: u32,
    pub start_ns: i64,
    pub end_ns: i64,
    pub observed_at_ms: i64,
    pub reason: NativeContextEventReason,
    pub source_name: String,
    pub application: Option<String>,
    pub text: String,
    pub block_count: u32,
    pub semantic_hash: String,
    pub retention: String,
}

fn mode(value: NativeContextMode) -> ContextMode {
    match value {
        NativeContextMode::FollowPointer => ContextMode::FollowPointer,
        NativeContextMode::WatchDisplay => ContextMode::WatchDisplay,
        NativeContextMode::WatchWindow => ContextMode::WatchWindow,
        NativeContextMode::WatchRegion => ContextMode::WatchRegion,
        NativeContextMode::AddCurrentWindow => ContextMode::AddCurrentWindow,
    }
}

fn native_mode(value: ContextMode) -> NativeContextMode {
    match value {
        ContextMode::FollowPointer => NativeContextMode::FollowPointer,
        ContextMode::WatchDisplay => NativeContextMode::WatchDisplay,
        ContextMode::WatchWindow => NativeContextMode::WatchWindow,
        ContextMode::WatchRegion => NativeContextMode::WatchRegion,
        ContextMode::AddCurrentWindow => NativeContextMode::AddCurrentWindow,
    }
}

fn permission(value: NativeScreenPermission) -> ScreenPermission {
    match value {
        NativeScreenPermission::Granted => ScreenPermission::Granted,
        NativeScreenPermission::NotDetermined => ScreenPermission::NotDetermined,
        NativeScreenPermission::Denied => ScreenPermission::Denied,
    }
}

fn native_permission(value: ScreenPermission) -> NativeScreenPermission {
    match value {
        ScreenPermission::Granted => NativeScreenPermission::Granted,
        ScreenPermission::NotDetermined => NativeScreenPermission::NotDetermined,
        ScreenPermission::Denied => NativeScreenPermission::Denied,
    }
}

fn bounds(value: NativeContextBounds) -> ContextBounds {
    ContextBounds {
        display_id: value.display_id,
        x: value.x,
        y: value.y,
        width: value.width,
        height: value.height,
    }
}

fn native_bounds(value: ContextBounds) -> NativeContextBounds {
    NativeContextBounds {
        display_id: value.display_id,
        x: value.x,
        y: value.y,
        width: value.width,
        height: value.height,
    }
}

fn request(value: NativeContextScopeRequest) -> ContextScopeRequest {
    ContextScopeRequest {
        mode: mode(value.mode),
        targets: value
            .targets
            .into_iter()
            .map(|target| ContextTarget {
                kind: match target.kind {
                    NativeContextTargetKind::Display => ContextTargetKind::Display,
                    NativeContextTargetKind::Window => ContextTargetKind::Window,
                },
                platform_id: target.platform_id,
                name: target.name,
                application: target.application,
                description: target.description,
            })
            .collect(),
        bounds: value.bounds.map(bounds),
        topology: value
            .topology
            .into_iter()
            .map(|display| DisplayTopology {
                display_id: display.display_id,
                name: display.name,
                x: display.x,
                y: display.y,
                width: display.width,
                height: display.height,
                scale: display.scale,
                rotation: display.rotation,
                is_main: display.is_main,
            })
            .collect(),
        exclusions: value.exclusions,
        permission: permission(value.permission),
        retention: match value.retention {
            NativeContextRetention::NoPixels => ContextRetention::NoPixels,
            NativeContextRetention::UserMarkedSnapshots => ContextRetention::UserMarkedSnapshots,
            NativeContextRetention::MeaningfulSnapshots => ContextRetention::MeaningfulSnapshots,
        },
    }
}

fn native_request(value: ContextScopeRequest) -> NativeContextScopeRequest {
    NativeContextScopeRequest {
        mode: native_mode(value.mode),
        targets: value
            .targets
            .into_iter()
            .map(|target| NativeContextTarget {
                kind: match target.kind {
                    ContextTargetKind::Display => NativeContextTargetKind::Display,
                    ContextTargetKind::Window => NativeContextTargetKind::Window,
                },
                platform_id: target.platform_id,
                name: target.name,
                application: target.application,
                description: target.description,
            })
            .collect(),
        bounds: value.bounds.map(native_bounds),
        topology: value
            .topology
            .into_iter()
            .map(|display| NativeDisplayTopology {
                display_id: display.display_id,
                name: display.name,
                x: display.x,
                y: display.y,
                width: display.width,
                height: display.height,
                scale: display.scale,
                rotation: display.rotation,
                is_main: display.is_main,
            })
            .collect(),
        exclusions: value.exclusions,
        permission: native_permission(value.permission),
        retention: match value.retention {
            ContextRetention::NoPixels => NativeContextRetention::NoPixels,
            ContextRetention::UserMarkedSnapshots => NativeContextRetention::UserMarkedSnapshots,
            ContextRetention::MeaningfulSnapshots => NativeContextRetention::MeaningfulSnapshots,
        },
    }
}

fn native_detail(detail: ContextDetail) -> NativeContextDetail {
    NativeContextDetail {
        scopes: detail
            .scopes
            .into_iter()
            .map(|scope| NativeContextScope {
                scope_id: scope.scope_id,
                epoch: scope.epoch,
                request: native_request(scope.request),
                condition: match scope.condition {
                    ContextCondition::Active => NativeContextCondition::Active,
                    ContextCondition::Paused => NativeContextCondition::Paused,
                    ContextCondition::Revoked => NativeContextCondition::Revoked,
                    ContextCondition::Failed => NativeContextCondition::Failed,
                    ContextCondition::Superseded => NativeContextCondition::Superseded,
                    ContextCondition::Ended => NativeContextCondition::Ended,
                },
                reason: scope.reason,
                authorized_at_ms: scope.authorized_at_ms,
                changed_at_ms: scope.changed_at_ms,
            })
            .collect(),
        accepted_events: detail.accepted_events,
        declaration: NativeSessionDeclaration {
            participants: detail.declaration.participants,
            topic: detail.declaration.topic,
        },
    }
}

fn action(value: NativeContextAction) -> ContextAction {
    match value {
        NativeContextAction::Authorize { request: value } => {
            ContextAction::Authorize(request(value))
        }
        NativeContextAction::Pause { reason } => ContextAction::Pause(match reason {
            NativeContextPauseReason::User => ContextPauseReason::User,
            NativeContextPauseReason::TopologyChanged => ContextPauseReason::TopologyChanged,
            NativeContextPauseReason::ScreenLocked => ContextPauseReason::ScreenLocked,
        }),
        NativeContextAction::Resume { permission: value } => ContextAction::Resume {
            permission: permission(value),
        },
        NativeContextAction::Revoke => ContextAction::Revoke,
        NativeContextAction::Fail { reason } => ContextAction::Fail(match reason {
            NativeContextFailureReason::PermissionLost => ContextFailureReason::PermissionLost,
            NativeContextFailureReason::DisplayRemoved => ContextFailureReason::DisplayRemoved,
            NativeContextFailureReason::CaptureFailed => ContextFailureReason::CaptureFailed,
        }),
    }
}

fn proposal(value: NativeContextProposal) -> ContextProposal {
    ContextProposal {
        scope_id: value.scope_id,
        epoch: value.epoch,
        reason: match value.reason {
            NativeContextEventReason::Attention => ContextEventReason::Attention,
            NativeContextEventReason::FixedScopeChange => ContextEventReason::FixedScopeChange,
            NativeContextEventReason::UserMarked => ContextEventReason::UserMarked,
        },
        start_host_time: value.start_host_time,
        end_host_time: value.end_host_time,
        observed_at_ms: value.observed_at_ms,
        source: ContextSource {
            platform_id: value.source.platform_id,
            name: value.source.name,
            application: value.source.application,
        },
        bounds: value.bounds.map(bounds),
        reducer_revision: value.reducer_revision,
        vision_revision: value.vision_revision,
        languages: value.languages,
        blocks: value
            .blocks
            .into_iter()
            .map(|block| ContextTextBlock {
                text: block.text,
                x: block.x,
                y: block.y,
                width: block.width,
                height: block.height,
            })
            .collect(),
    }
}

#[uniffi::export]
impl NativeRecordingPreparation {
    pub fn context_action(
        &self,
        session_id: String,
        action: NativeContextAction,
    ) -> Result<NativeContextDetail, NativeStorageError> {
        self.controller()?
            .context_action(SessionId(session_id), self::action(action))
            .map(native_detail)
            .map_err(map_storage_error)
    }

    /// Rejection is a value: the caller shows no success signal for it.
    pub fn propose_context_event(
        &self,
        session_id: String,
        proposal: NativeContextProposal,
    ) -> Result<NativeContextDecision, NativeStorageError> {
        let decision = self
            .controller()?
            .propose_context_event(SessionId(session_id), self::proposal(proposal))
            .map_err(map_storage_error)?;
        Ok(match decision {
            ContextDecision::Accepted(event) => NativeContextDecision::Accepted {
                event_id: event.event_id,
                start_ns: event.start_ns,
                end_ns: event.end_ns,
                semantic_hash: event.semantic_hash,
            },
            ContextDecision::Rejected(reason) => NativeContextDecision::Rejected {
                reason: match reason {
                    ContextRejection::UnknownScope => NativeContextRejection::UnknownScope,
                    ContextRejection::StaleEpoch => NativeContextRejection::StaleEpoch,
                    ContextRejection::Paused => NativeContextRejection::Paused,
                    ContextRejection::Revoked => NativeContextRejection::Revoked,
                    ContextRejection::Failed => NativeContextRejection::Failed,
                    ContextRejection::NotRecording => NativeContextRejection::NotRecording,
                    ContextRejection::NonMonotonic => NativeContextRejection::NonMonotonic,
                    ContextRejection::Duplicate => NativeContextRejection::Duplicate,
                    ContextRejection::NoSemanticContent => {
                        NativeContextRejection::NoSemanticContent
                    }
                    ContextRejection::TooLarge => NativeContextRejection::TooLarge,
                },
            },
        })
    }

    pub fn context_detail(
        &self,
        session_id: String,
    ) -> Result<NativeContextDetail, NativeStorageError> {
        self.controller()?
            .context_detail(&SessionId(session_id))
            .map(native_detail)
            .map_err(map_storage_error)
    }

    /// Optional participant and topic metadata; it grants no context permission.
    pub fn declare_session(
        &self,
        session_id: String,
        declaration: NativeSessionDeclaration,
    ) -> Result<NativeSessionDeclaration, NativeStorageError> {
        self.controller()?
            .declare_session(
                SessionId(session_id),
                SessionDeclaration {
                    participants: declaration.participants,
                    topic: declaration.topic,
                },
            )
            .map(|declaration| NativeSessionDeclaration {
                participants: declaration.participants,
                topic: declaration.topic,
            })
            .map_err(map_storage_error)
    }
}

#[uniffi::export]
impl NativeTranscriptLibrary {
    pub fn context_detail(
        &self,
        session_id: String,
    ) -> Result<NativeContextDetail, NativeStorageError> {
        self.library()?
            .context_detail(&SessionId(session_id))
            .map(native_detail)
            .map_err(map_storage_error)
    }

    pub fn context_events(
        &self,
        session_id: String,
    ) -> Result<Vec<NativeContextEvent>, NativeStorageError> {
        let events = self
            .library()?
            .context_events(&SessionId(session_id))
            .map_err(map_storage_error)?;
        events
            .into_iter()
            .map(|event| {
                Ok(NativeContextEvent {
                    reason: match event.reason.as_str() {
                        "attention" => NativeContextEventReason::Attention,
                        "fixed_scope_change" => NativeContextEventReason::FixedScopeChange,
                        "user_marked" => NativeContextEventReason::UserMarked,
                        _ => return Err(NativeStorageError::IntegrityMismatch),
                    },
                    event_id: event.event_id,
                    scope_id: event.scope_id,
                    epoch: event.epoch,
                    start_ns: event.start_ns,
                    end_ns: event.end_ns,
                    observed_at_ms: event.observed_at_ms,
                    source_name: event.source_name,
                    application: event.application,
                    text: event.text,
                    block_count: event.block_count,
                    semantic_hash: event.semantic_hash,
                    retention: event.retention,
                })
            })
            .collect()
    }
}
