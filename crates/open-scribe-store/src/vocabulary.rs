//! Persisted vocabularies. Each `as_str` is the exact token SQLite rows and
//! journal payloads hold, so existing libraries read back unchanged. Schema
//! CHECK constraints keep their literal lists: that text is on disk.
//!
//! SQL that filters on a named set uses the `*_sql!` literal for it; the tests
//! below hold each literal equal to the Rust set it renders.

use super::{MediaSourceKind, StoreError};

macro_rules! stored_vocabulary {
    (
        $(#[$meta:meta])*
        pub enum $name:ident ($unsupported:literal) {
            $($(#[$variant_meta:meta])* $variant:ident = $token:literal,)+
        }
    ) => {
        $(#[$meta])*
        #[derive(Clone, Copy, Debug, Eq, Hash, PartialEq)]
        pub enum $name {
            $($(#[$variant_meta])* $variant,)+
        }

        impl $name {
            pub const ALL: &'static [Self] = &[$(Self::$variant),+];

            #[must_use]
            pub const fn as_str(self) -> &'static str {
                match self {
                    $(Self::$variant => $token,)+
                }
            }

            pub fn parse(value: &str) -> Result<Self, StoreError> {
                match value {
                    $($token => Ok(Self::$variant),)+
                    _ => Err(StoreError::IntegrityMismatch($unsupported)),
                }
            }
        }

        impl std::fmt::Display for $name {
            fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
                formatter.write_str(self.as_str())
            }
        }

        impl rusqlite::types::ToSql for $name {
            fn to_sql(&self) -> rusqlite::Result<rusqlite::types::ToSqlOutput<'_>> {
                Ok(self.as_str().into())
            }
        }

        impl rusqlite::types::FromSql for $name {
            fn column_result(
                value: rusqlite::types::ValueRef<'_>,
            ) -> rusqlite::types::FromSqlResult<Self> {
                Self::parse(value.as_str()?)
                    .map_err(|error| rusqlite::types::FromSqlError::Other(Box::new(error)))
            }
        }

        /// Store tests assert the exact stored token.
        #[cfg(test)]
        impl PartialEq<&str> for $name {
            fn eq(&self, token: &&str) -> bool {
                self.as_str() == *token
            }
        }
    };
}

stored_vocabulary! {
    /// `sessions.lifecycle`.
    pub enum SessionLifecycle ("session lifecycle is unsupported") {
        Preparing = "preparing",
        Recording = "recording",
        Paused = "paused",
        Finalizing = "finalizing",
        ReadyForReview = "ready_for_review",
        Interrupted = "interrupted",
        Deleted = "deleted",
    }
}

impl SessionLifecycle {
    /// Capture whose media writers an interruption can still stop. A paused
    /// capture has already sealed its sources.
    pub const INTERRUPTIBLE: &'static [Self] =
        &[Self::Preparing, Self::Recording, Self::Finalizing];
    /// Capture that is not yet saved, interrupted or deleted.
    pub const OPEN_CAPTURE: &'static [Self] = &[
        Self::Preparing,
        Self::Recording,
        Self::Paused,
        Self::Finalizing,
    ];
    /// Capture that never reached review: still open, or interrupted.
    pub const UNSAVED: &'static [Self] = &[
        Self::Preparing,
        Self::Recording,
        Self::Paused,
        Self::Finalizing,
        Self::Interrupted,
    ];
    /// A person may move these to Trash whatever audio they hold. An isolated
    /// capture qualifies only when it holds none (`session_deletion`).
    pub const TRASHABLE: &'static [Self] = &[Self::ReadyForReview, Self::Interrupted];

    #[must_use]
    pub fn is_trashable(self) -> bool {
        Self::TRASHABLE.contains(&self)
    }

    #[must_use]
    pub fn is_interruptible(self) -> bool {
        Self::INTERRUPTIBLE.contains(&self)
    }

    #[must_use]
    pub fn is_open_capture(self) -> bool {
        Self::OPEN_CAPTURE.contains(&self)
    }

    #[must_use]
    pub fn is_unsaved(self) -> bool {
        Self::UNSAVED.contains(&self)
    }
}

macro_rules! interruptible_lifecycles_sql {
    () => {
        "('preparing', 'recording', 'finalizing')"
    };
}

macro_rules! open_capture_lifecycles_sql {
    () => {
        "('preparing', 'recording', 'paused', 'finalizing')"
    };
}

macro_rules! unsaved_lifecycles_sql {
    () => {
        "('preparing', 'recording', 'paused', 'finalizing', 'interrupted')"
    };
}

stored_vocabulary! {
    /// Bounded, content-free reason for preserving a partial capture as
    /// interrupted: the `reason` of a `session_interrupted` payload.
    pub enum SessionInterruptionReason ("session interruption reason is unsupported") {
        CaptureStartFailed = "capture_start_failed",
        CaptureFailed = "capture_failed",
        FirstSampleRejected = "first_sample_rejected",
        StopWithoutDurableSample = "stop_without_durable_sample",
        SegmentSealFailed = "segment_seal_failed",
        /// The last capture source lost its operating-system permission.
        PermissionRevoked = "permission_revoked",
    }
}

stored_vocabulary! {
    /// `sessions.health`.
    pub enum SessionHealth ("session health is unsupported") {
        Healthy = "healthy",
        Degraded = "degraded",
    }
}

stored_vocabulary! {
    /// `required_sources.lifecycle`, as the library snapshot reports it.
    pub enum SourceLifecycle ("source lifecycle is unsupported") {
        Required = "required",
        Opening = "opening",
        Open = "open",
        Capturing = "capturing",
        Failed = "failed",
        Sealed = "sealed",
        /// Snapshot only: a capture recovery isolated. Never stored.
        Unavailable = "unavailable",
    }
}

impl SourceLifecycle {
    /// A source or segment with a writer that may still change its media.
    /// Segments and source rows use the same three tokens.
    pub const ACTIVE: &'static [Self] = &[Self::Opening, Self::Open, Self::Capturing];
}

macro_rules! active_media_sql {
    () => {
        "('opening', 'open', 'capturing')"
    };
}

stored_vocabulary! {
    /// The `level` of a `storage_observed` payload. `Unchecked` is reported
    /// before the first observation and is never journaled.
    pub enum StorageLevel ("storage level is unsupported") {
        Unchecked = "unchecked",
        Normal = "normal",
        Warning = "warning",
        Critical = "critical",
    }
}

stored_vocabulary! {
    /// Journal and `session_events.event_kind` tokens the recorder writes or
    /// shows. `SourceFailed` is written by source failure, not the recorder.
    pub enum RecorderEventKind ("recorder event kind is unsupported") {
        PauseRequested = "pause_requested",
        CapturePaused = "capture_paused",
        ResumeRequested = "resume_requested",
        CaptureResumed = "capture_resumed",
        PausedSessionFinalized = "paused_session_finalized",
        MarkerAdded = "marker_added",
        SourceScopeSelected = "source_scope_selected",
        StorageObserved = "storage_observed",
        SourceFailed = "source_failed",
        SystemSleepObserved = "system_sleep_observed",
        SystemWakeObserved = "system_wake_observed",
        MicrophoneRestoreRequested = "microphone_restore_requested",
        MicrophoneRestoreCancelled = "microphone_restore_cancelled",
        MicrophoneRetiredUnstarted = "microphone_retired_unstarted",
    }
}

impl RecorderEventKind {
    /// Events the recorder detail lists for the activity log.
    pub const DETAIL: &'static [Self] = &[
        Self::MarkerAdded,
        Self::CapturePaused,
        Self::CaptureResumed,
        Self::SourceScopeSelected,
        Self::StorageObserved,
        Self::SourceFailed,
        Self::SystemSleepObserved,
        Self::SystemWakeObserved,
        Self::MicrophoneRestoreRequested,
        Self::MicrophoneRestoreCancelled,
        Self::MicrophoneRetiredUnstarted,
    ];

    /// The three outcomes of an explicit microphone restore.
    pub const MICROPHONE_RESTORE: &'static [Self] = &[
        Self::MicrophoneRestoreRequested,
        Self::MicrophoneRestoreCancelled,
        Self::MicrophoneRetiredUnstarted,
    ];

    /// Kinds the recorder itself journals, and so replays on launch.
    #[must_use]
    pub const fn is_recorder_journaled(self) -> bool {
        !matches!(self, Self::SourceFailed)
    }

    /// Lifecycle a live recorder action moves the session to.
    #[must_use]
    pub const fn lifecycle_effect(self) -> Option<SessionLifecycle> {
        match self {
            Self::PauseRequested => Some(SessionLifecycle::Finalizing),
            Self::CapturePaused => Some(SessionLifecycle::Paused),
            Self::ResumeRequested => Some(SessionLifecycle::Preparing),
            Self::PausedSessionFinalized => Some(SessionLifecycle::ReadyForReview),
            _ => None,
        }
    }
}

macro_rules! recorder_detail_kinds_sql {
    () => {
        "('marker_added', 'capture_paused', 'capture_resumed', 'source_scope_selected', \
         'storage_observed', 'source_failed', 'system_sleep_observed', 'system_wake_observed', \
         'microphone_restore_requested', 'microphone_restore_cancelled', \
         'microphone_retired_unstarted')"
    };
}

macro_rules! microphone_restore_kinds_sql {
    () => {
        "('microphone_restore_requested', 'microphone_restore_cancelled', \
         'microphone_retired_unstarted')"
    };
}

stored_vocabulary! {
    /// `transcript_revisions.finality`.
    pub enum TranscriptFinality ("transcript finality is unsupported") {
        Draft = "draft",
        Final = "final",
        Superseded = "superseded",
    }
}

stored_vocabulary! {
    /// `transcription_runs.state`.
    pub enum TranscriptionRunState ("transcription run state is unsupported") {
        Running = "running",
        Complete = "complete",
        Failed = "failed",
        Cancelled = "cancelled",
    }
}

stored_vocabulary! {
    /// `transcription_runs.failure_class`: every `TranscriptionFailure`, plus
    /// the cancellation the store records when a newer run supersedes one.
    pub enum TranscriptionFailureClass ("transcription failure class is unsupported") {
        Cancelled = "cancelled",
        CapturePreempted = "capture_preempted",
        ModelUnavailable = "model_unavailable",
        EngineError = "engine_error",
        ResourceExhausted = "resource_exhausted",
        InvalidResult = "invalid_result",
        InputUnavailable = "input_unavailable",
        StorageError = "storage_error",
        Orphaned = "orphaned",
        StaleReconciliation = "stale_reconciliation",
        Superseded = "superseded",
    }
}

impl TranscriptionFailureClass {
    /// Failures after which a successor run may reuse the complete chunks.
    pub const RETAINS_CHUNKS: &'static [Self] = &[
        Self::InvalidResult,
        Self::StaleReconciliation,
        Self::Orphaned,
        Self::StorageError,
    ];

    #[must_use]
    pub fn retains_chunks(self) -> bool {
        Self::RETAINS_CHUNKS.contains(&self)
    }
}

/// What a later run reuses a stored run's complete chunks for.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum RetainedRunUse {
    /// Continuing a track the queue left without a current Final.
    Continue,
    /// Rebuilding every track, which may also reuse a completed run.
    Reprocess,
    /// Launch reconciliation under a newer reconciliation version. It revives
    /// only runs whose result never committed: still running, or rejected by
    /// reconciliation.
    LaunchReconcile,
}

impl RetainedRunUse {
    /// The reuse a queued transcription intent makes of retained runs.
    #[must_use]
    pub fn for_intent(intent: open_scribe_types::TranscriptionIntent) -> Self {
        if intent == open_scribe_types::TranscriptionIntent::ReprocessAll {
            Self::Reprocess
        } else {
            Self::Continue
        }
    }
}

impl TranscriptionRunState {
    /// The one rule for which stored runs keep chunks a successor may
    /// reconcile without the recognizer. Callers also require every chunk of
    /// the run to be complete.
    #[must_use]
    pub fn retains_chunks(
        self,
        failure: Option<TranscriptionFailureClass>,
        purpose: RetainedRunUse,
    ) -> bool {
        match self {
            Self::Running => true,
            Self::Cancelled => purpose != RetainedRunUse::LaunchReconcile,
            Self::Complete => purpose == RetainedRunUse::Reprocess,
            Self::Failed => failure.is_some_and(|class| match purpose {
                RetainedRunUse::LaunchReconcile => matches!(
                    class,
                    TranscriptionFailureClass::InvalidResult
                        | TranscriptionFailureClass::StaleReconciliation
                ),
                RetainedRunUse::Continue | RetainedRunUse::Reprocess => class.retains_chunks(),
            }),
        }
    }
}

stored_vocabulary! {
    /// `sources.kind` of a stored track: a capture kind, or an imported file.
    pub enum TrackSourceKind ("track source kind is unsupported") {
        Microphone = "microphone",
        ApplicationAudio = "application_audio",
        SystemAudio = "system_audio",
        ImportedAudio = "imported_audio",
    }
}

impl TrackSourceKind {
    /// The capture source behind the track; `None` for imported audio.
    #[must_use]
    pub const fn capture(self) -> Option<MediaSourceKind> {
        match self {
            Self::Microphone => Some(MediaSourceKind::Microphone),
            Self::ApplicationAudio => Some(MediaSourceKind::ApplicationAudio),
            Self::SystemAudio => Some(MediaSourceKind::SystemAudio),
            Self::ImportedAudio => None,
        }
    }

    /// The speaker label shown until a person names the track.
    #[must_use]
    pub const fn default_speaker_label(self) -> &'static str {
        match self.capture() {
            Some(kind) => super::source_defaults(kind).speaker_label,
            None => super::UNKNOWN_SOURCE_SPEAKER_LABEL,
        }
    }
}

impl From<MediaSourceKind> for TrackSourceKind {
    fn from(kind: MediaSourceKind) -> Self {
        match kind {
            MediaSourceKind::Microphone => Self::Microphone,
            MediaSourceKind::ApplicationAudio => Self::ApplicationAudio,
            MediaSourceKind::SystemAudio => Self::SystemAudio,
        }
    }
}

stored_vocabulary! {
    /// `conversation_titles.suggestion_basis`: the transcript text a
    /// suggested title was derived from.
    pub enum SuggestionBasis ("suggestion basis is unsupported") {
        Draft = "draft",
        Final = "final",
    }
}

/// Reads a stored source kind; capture rows only ever hold the three kinds.
pub(crate) fn parse_source_kind(value: &str) -> Result<MediaSourceKind, StoreError> {
    MediaSourceKind::parse(value).ok_or(StoreError::IntegrityMismatch(
        "required media source kind is unsupported",
    ))
}

/// Channels the capture writer records for each source kind.
pub(crate) const fn capture_channels(kind: MediaSourceKind) -> u16 {
    match kind {
        MediaSourceKind::Microphone => 1,
        MediaSourceKind::ApplicationAudio | MediaSourceKind::SystemAudio => 2,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn sql_set(tokens: impl IntoIterator<Item = &'static str>) -> String {
        let quoted: Vec<String> = tokens
            .into_iter()
            .map(|token| format!("'{token}'"))
            .collect();
        format!("({})", quoted.join(", "))
    }

    #[test]
    fn sql_sets_render_their_rust_sets() {
        let lifecycles = |set: &[SessionLifecycle]| sql_set(set.iter().map(|value| value.as_str()));
        assert_eq!(
            interruptible_lifecycles_sql!(),
            lifecycles(SessionLifecycle::INTERRUPTIBLE)
        );
        assert_eq!(
            open_capture_lifecycles_sql!(),
            lifecycles(SessionLifecycle::OPEN_CAPTURE)
        );
        assert_eq!(
            unsaved_lifecycles_sql!(),
            lifecycles(SessionLifecycle::UNSAVED)
        );
        assert_eq!(
            active_media_sql!(),
            sql_set(SourceLifecycle::ACTIVE.iter().map(|value| value.as_str()))
        );
        assert_eq!(
            recorder_detail_kinds_sql!(),
            sql_set(RecorderEventKind::DETAIL.iter().map(|value| value.as_str()))
        );
        assert_eq!(
            microphone_restore_kinds_sql!(),
            sql_set(
                RecorderEventKind::MICROPHONE_RESTORE
                    .iter()
                    .map(|value| value.as_str())
            )
        );
    }

    #[test]
    fn every_token_parses_back_to_its_variant() {
        for value in SessionLifecycle::ALL {
            assert_eq!(SessionLifecycle::parse(value.as_str()).unwrap(), *value);
        }
        for value in SessionHealth::ALL {
            assert_eq!(SessionHealth::parse(value.as_str()).unwrap(), *value);
        }
        for value in SourceLifecycle::ALL {
            assert_eq!(SourceLifecycle::parse(value.as_str()).unwrap(), *value);
        }
        for value in StorageLevel::ALL {
            assert_eq!(StorageLevel::parse(value.as_str()).unwrap(), *value);
        }
        for value in RecorderEventKind::ALL {
            assert_eq!(RecorderEventKind::parse(value.as_str()).unwrap(), *value);
        }
        for value in TranscriptFinality::ALL {
            assert_eq!(TranscriptFinality::parse(value.as_str()).unwrap(), *value);
        }
        for value in TranscriptionRunState::ALL {
            assert_eq!(
                TranscriptionRunState::parse(value.as_str()).unwrap(),
                *value
            );
        }
        for value in TranscriptionFailureClass::ALL {
            assert_eq!(
                TranscriptionFailureClass::parse(value.as_str()).unwrap(),
                *value
            );
        }
        for kind in MediaSourceKind::ALL {
            assert_eq!(parse_source_kind(kind.as_str()).unwrap(), kind);
            assert_eq!(
                TrackSourceKind::parse(kind.as_str()).unwrap(),
                TrackSourceKind::from(kind)
            );
        }
        for value in TrackSourceKind::ALL {
            assert_eq!(TrackSourceKind::parse(value.as_str()).unwrap(), *value);
        }
        assert_eq!(TrackSourceKind::ImportedAudio.as_str(), "imported_audio");
        assert_eq!(
            TrackSourceKind::ImportedAudio.default_speaker_label(),
            "Speaker"
        );
        assert_eq!(TrackSourceKind::Microphone.default_speaker_label(), "You");
        assert_eq!(
            TrackSourceKind::SystemAudio.default_speaker_label(),
            "Others"
        );
        for value in SuggestionBasis::ALL {
            assert_eq!(SuggestionBasis::parse(value.as_str()).unwrap(), *value);
        }
        assert!(SessionLifecycle::parse("ready").is_err());
    }

    #[test]
    fn stored_tokens_are_unchanged() {
        assert_eq!(
            SessionLifecycle::ALL
                .iter()
                .map(|value| value.as_str())
                .collect::<Vec<_>>(),
            [
                "preparing",
                "recording",
                "paused",
                "finalizing",
                "ready_for_review",
                "interrupted",
                "deleted"
            ]
        );
        assert_eq!(
            SourceLifecycle::ALL
                .iter()
                .map(|value| value.as_str())
                .collect::<Vec<_>>(),
            [
                "required",
                "opening",
                "open",
                "capturing",
                "failed",
                "sealed",
                "unavailable"
            ]
        );
        assert_eq!(
            TranscriptionFailureClass::ALL
                .iter()
                .map(|value| value.as_str())
                .collect::<Vec<_>>(),
            [
                "cancelled",
                "capture_preempted",
                "model_unavailable",
                "engine_error",
                "resource_exhausted",
                "invalid_result",
                "input_unavailable",
                "storage_error",
                "orphaned",
                "stale_reconciliation",
                "superseded"
            ]
        );
    }

    #[test]
    fn one_rule_names_the_runs_whose_chunks_a_successor_may_reuse() {
        use RetainedRunUse::{Continue, LaunchReconcile, Reprocess};
        use TranscriptionFailureClass as Class;
        use TranscriptionRunState as State;
        for purpose in [Continue, Reprocess, LaunchReconcile] {
            assert!(State::Running.retains_chunks(None, purpose));
            assert!(!State::Failed.retains_chunks(None, purpose));
            assert!(!State::Failed.retains_chunks(Some(Class::EngineError), purpose));
        }
        assert!(State::Cancelled.retains_chunks(Some(Class::Superseded), Continue));
        assert!(!State::Cancelled.retains_chunks(Some(Class::Superseded), LaunchReconcile));
        assert!(State::Complete.retains_chunks(None, Reprocess));
        assert!(!State::Complete.retains_chunks(None, Continue));
        for class in Class::RETAINS_CHUNKS {
            assert!(State::Failed.retains_chunks(Some(*class), Continue));
            assert!(State::Failed.retains_chunks(Some(*class), Reprocess));
        }
        assert!(State::Failed.retains_chunks(Some(Class::InvalidResult), LaunchReconcile));
        assert!(State::Failed.retains_chunks(Some(Class::StaleReconciliation), LaunchReconcile));
        assert!(!State::Failed.retains_chunks(Some(Class::Orphaned), LaunchReconcile));
        assert!(!State::Failed.retains_chunks(Some(Class::StorageError), LaunchReconcile));
    }
}
