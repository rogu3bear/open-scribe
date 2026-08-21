//! WASM-safe deterministic session semantics for Open Scribe.

#![forbid(unsafe_code)]

use open_scribe_types::{
    DurabilityRecord, Lifecycle, PermissionRecord, PermissionState, RecoveryRecord, RecoveryStatus,
    SessionHealth, SessionId, SessionRecord, SourceActivity, SourceHealth, SourceId, SourceKind,
    SourceRecord,
};

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum Presentation {
    Idle,
    Ready,
    Starting,
    Recording,
    Paused,
    Finalizing,
    RecordingDegraded,
    PermissionRevoked,
    RecoveryRequired,
    Complete,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum TimerBehavior {
    Hidden,
    Advancing,
    Frozen,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct SymbolContract {
    pub primary: Option<&'static str>,
    pub fallback: Option<&'static str>,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct SessionSnapshot {
    pub session: SessionRecord,
    pub presentation: Presentation,
    pub label: String,
    pub timer: TimerBehavior,
    pub timer_text: Option<String>,
    pub symbol: SymbolContract,
    pub accessibility_value: String,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum Fixture {
    Idle,
    Ready,
    Starting,
    Recording,
    Paused,
    Finalizing,
    RecordingDegraded,
    PermissionRevoked,
    RecoveryRequired,
    Complete,
}

impl Fixture {
    pub const ALL: [Self; 10] = [
        Self::Idle,
        Self::Ready,
        Self::Starting,
        Self::Recording,
        Self::Paused,
        Self::Finalizing,
        Self::RecordingDegraded,
        Self::PermissionRevoked,
        Self::RecoveryRequired,
        Self::Complete,
    ];
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum Command {
    Prepare,
    RequestStart,
    CancelStart,
    ConfirmRecording {
        journal_durable: bool,
        media_files_open: bool,
    },
    Pause,
    Resume,
    BeginFinalizing {
        media_safe: bool,
    },
    Complete,
    Interrupt,
    AdvanceTimer(u64),
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum TransitionError {
    IllegalTransition,
    DurabilityEvidenceMissing,
    MediaNotSafe,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct SessionMachine {
    session: SessionRecord,
    starting: bool,
}

impl SessionMachine {
    #[must_use]
    pub fn from_fixture(fixture: Fixture) -> Self {
        fixture_machine(fixture)
    }

    #[must_use]
    pub fn snapshot(&self) -> SessionSnapshot {
        snapshot_for(&self.session, self.starting)
    }

    pub fn apply(&mut self, command: Command) -> Result<SessionSnapshot, TransitionError> {
        match command {
            Command::Prepare if self.session.lifecycle == Lifecycle::Idle => {
                self.session.lifecycle = Lifecycle::Ready;
            }
            Command::RequestStart
                if self.session.lifecycle == Lifecycle::Ready && !self.starting =>
            {
                self.starting = true;
            }
            Command::CancelStart if self.session.lifecycle == Lifecycle::Ready && self.starting => {
                self.starting = false;
            }
            Command::ConfirmRecording {
                journal_durable,
                media_files_open,
            } if self.session.lifecycle == Lifecycle::Ready && self.starting => {
                let durability = DurabilityRecord {
                    journal_durable,
                    media_files_open,
                    media_safe: false,
                };
                if !durability.permits_recording() {
                    return Err(TransitionError::DurabilityEvidenceMissing);
                }
                self.session.durability = durability;
                self.session.lifecycle = Lifecycle::Recording;
                self.starting = false;
                set_source_activity(&mut self.session.sources, SourceActivity::Active);
            }
            Command::Pause if self.session.lifecycle == Lifecycle::Recording => {
                self.session.lifecycle = Lifecycle::Paused;
                set_source_activity(&mut self.session.sources, SourceActivity::Paused);
            }
            Command::Resume
                if self.session.lifecycle == Lifecycle::Paused
                    && self.session.durability.permits_recording() =>
            {
                self.session.lifecycle = Lifecycle::Recording;
                set_source_activity(&mut self.session.sources, SourceActivity::Active);
            }
            Command::BeginFinalizing { media_safe }
                if matches!(
                    self.session.lifecycle,
                    Lifecycle::Recording | Lifecycle::Paused
                ) =>
            {
                if !media_safe {
                    return Err(TransitionError::MediaNotSafe);
                }
                self.session.durability.media_safe = true;
                self.session.lifecycle = Lifecycle::Finalizing;
                set_source_activity(&mut self.session.sources, SourceActivity::Paused);
            }
            Command::Complete if self.session.lifecycle == Lifecycle::Finalizing => {
                if !self.session.durability.media_safe {
                    return Err(TransitionError::MediaNotSafe);
                }
                self.session.lifecycle = Lifecycle::ReadyForReview;
            }
            Command::Interrupt
                if matches!(
                    self.session.lifecycle,
                    Lifecycle::Ready
                        | Lifecycle::Recording
                        | Lifecycle::Paused
                        | Lifecycle::Finalizing
                ) =>
            {
                self.starting = false;
                self.session.lifecycle = Lifecycle::Interrupted;
                self.session.recovery = RecoveryRecord {
                    status: RecoveryStatus::Required,
                    preserved_evidence_summary: Some(
                        "Durable journal and available media segments".into(),
                    ),
                };
                set_source_activity(&mut self.session.sources, SourceActivity::Paused);
            }
            Command::AdvanceTimer(seconds) if self.session.lifecycle == Lifecycle::Recording => {
                self.session.elapsed_seconds = self.session.elapsed_seconds.saturating_add(seconds);
            }
            _ => return Err(TransitionError::IllegalTransition),
        }

        Ok(self.snapshot())
    }
}

#[must_use]
pub fn fixture_catalog() -> Vec<(Fixture, SessionSnapshot)> {
    Fixture::ALL
        .into_iter()
        .map(|fixture| (fixture, SessionMachine::from_fixture(fixture).snapshot()))
        .collect()
}

#[must_use]
pub fn announcement(previous: &SessionSnapshot, current: &SessionSnapshot) -> Option<String> {
    if previous.presentation == current.presentation {
        return None;
    }

    match current.presentation {
        Presentation::Recording => Some("Recording".into()),
        Presentation::Paused => Some("Paused".into()),
        Presentation::RecordingDegraded => Some(source_failure_announcement(current)),
        Presentation::PermissionRevoked => Some(permission_loss_announcement(current)),
        Presentation::RecoveryRequired => {
            Some(format!("Recovery required for {}", current.session.title))
        }
        _ => None,
    }
}

fn fixture_machine(fixture: Fixture) -> SessionMachine {
    let mut session = base_session();
    let mut starting = false;

    match fixture {
        Fixture::Idle => {}
        Fixture::Ready => session.lifecycle = Lifecycle::Ready,
        Fixture::Starting => {
            session.lifecycle = Lifecycle::Ready;
            starting = true;
        }
        Fixture::Recording => enter_recording(&mut session),
        Fixture::Paused => {
            enter_recording(&mut session);
            session.lifecycle = Lifecycle::Paused;
            set_source_activity(&mut session.sources, SourceActivity::Paused);
        }
        Fixture::Finalizing => {
            enter_recording(&mut session);
            session.lifecycle = Lifecycle::Finalizing;
            session.durability.media_safe = true;
            set_source_activity(&mut session.sources, SourceActivity::Paused);
        }
        Fixture::RecordingDegraded => {
            enter_recording(&mut session);
            session.health = SessionHealth::Degraded;
            fail_source(
                &mut session.sources,
                "application",
                "Application audio stopped",
            );
        }
        Fixture::PermissionRevoked => {
            enter_recording(&mut session);
            session.health = SessionHealth::Degraded;
            if let Some(source) = session
                .sources
                .iter_mut()
                .find(|source| source.id.0 == "application")
            {
                source.permission = PermissionRecord {
                    state: PermissionState::Revoked,
                    recovery_hint: Some("Open System Settings → Privacy & Security".into()),
                };
                source.activity = SourceActivity::Failed;
                source.health = SourceHealth::Failed;
                source.health_detail = Some("Screen and system audio permission revoked".into());
            }
        }
        Fixture::RecoveryRequired => {
            enter_recording(&mut session);
            session.lifecycle = Lifecycle::Interrupted;
            session.recovery = RecoveryRecord {
                status: RecoveryStatus::Required,
                preserved_evidence_summary: Some("Journal and two media segments preserved".into()),
            };
            set_source_activity(&mut session.sources, SourceActivity::Paused);
        }
        Fixture::Complete => {
            enter_recording(&mut session);
            session.lifecycle = Lifecycle::ReadyForReview;
            session.durability.media_safe = true;
            set_source_activity(&mut session.sources, SourceActivity::Paused);
        }
    }

    SessionMachine { session, starting }
}

fn base_session() -> SessionRecord {
    SessionRecord {
        id: SessionId("fixture-session-001".into()),
        title: "Fixture session".into(),
        lifecycle: Lifecycle::Idle,
        health: SessionHealth::Healthy,
        elapsed_seconds: 754,
        sources: vec![
            SourceRecord {
                id: SourceId("microphone".into()),
                name: "Studio Microphone".into(),
                kind: SourceKind::Microphone,
                activity: SourceActivity::Selected,
                health: SourceHealth::Healthy,
                health_detail: None,
                permission: PermissionRecord {
                    state: PermissionState::Granted,
                    recovery_hint: None,
                },
            },
            SourceRecord {
                id: SourceId("application".into()),
                name: "FaceTime audio".into(),
                kind: SourceKind::ApplicationAudio,
                activity: SourceActivity::Selected,
                health: SourceHealth::Healthy,
                health_detail: None,
                permission: PermissionRecord {
                    state: PermissionState::Granted,
                    recovery_hint: None,
                },
            },
        ],
        durability: DurabilityRecord {
            journal_durable: false,
            media_files_open: false,
            media_safe: false,
        },
        recovery: RecoveryRecord {
            status: RecoveryStatus::NotRequired,
            preserved_evidence_summary: None,
        },
    }
}

fn enter_recording(session: &mut SessionRecord) {
    session.lifecycle = Lifecycle::Recording;
    session.durability = DurabilityRecord {
        journal_durable: true,
        media_files_open: true,
        media_safe: false,
    };
    set_source_activity(&mut session.sources, SourceActivity::Active);
}

fn set_source_activity(sources: &mut [SourceRecord], activity: SourceActivity) {
    for source in sources
        .iter_mut()
        .filter(|source| source.health == SourceHealth::Healthy)
    {
        source.activity = activity;
    }
}

fn fail_source(sources: &mut [SourceRecord], id: &str, detail: &str) {
    if let Some(source) = sources.iter_mut().find(|source| source.id.0 == id) {
        source.activity = SourceActivity::Failed;
        source.health = SourceHealth::Failed;
        source.health_detail = Some(detail.into());
    }
}

fn snapshot_for(session: &SessionRecord, starting: bool) -> SessionSnapshot {
    let presentation = presentation_for(session, starting);
    let timer = timer_for(presentation);
    let timer_text =
        (timer != TimerBehavior::Hidden).then(|| format_duration(session.elapsed_seconds));
    let label = label_for(presentation, timer_text.as_deref(), session);
    let accessibility_value = accessibility_value(&label, session);

    SessionSnapshot {
        session: session.clone(),
        presentation,
        label,
        timer,
        timer_text,
        symbol: symbol_for(presentation),
        accessibility_value,
    }
}

fn presentation_for(session: &SessionRecord, starting: bool) -> Presentation {
    if session.recovery.status == RecoveryStatus::Required
        || session.lifecycle == Lifecycle::Interrupted
    {
        return Presentation::RecoveryRequired;
    }
    if session
        .sources
        .iter()
        .any(|source| source.permission.state == PermissionState::Revoked)
    {
        return Presentation::PermissionRevoked;
    }
    if session.lifecycle == Lifecycle::Recording && session.health == SessionHealth::Degraded {
        return Presentation::RecordingDegraded;
    }
    if starting {
        return Presentation::Starting;
    }

    match session.lifecycle {
        Lifecycle::Idle => Presentation::Idle,
        Lifecycle::Ready => Presentation::Ready,
        Lifecycle::Recording => Presentation::Recording,
        Lifecycle::Paused => Presentation::Paused,
        Lifecycle::Finalizing => Presentation::Finalizing,
        Lifecycle::ReadyForReview => Presentation::Complete,
        Lifecycle::Interrupted => Presentation::RecoveryRequired,
    }
}

const fn timer_for(presentation: Presentation) -> TimerBehavior {
    match presentation {
        Presentation::Recording
        | Presentation::RecordingDegraded
        | Presentation::PermissionRevoked => TimerBehavior::Advancing,
        Presentation::Paused | Presentation::Finalizing | Presentation::Complete => {
            TimerBehavior::Frozen
        }
        Presentation::Idle
        | Presentation::Ready
        | Presentation::Starting
        | Presentation::RecoveryRequired => TimerBehavior::Hidden,
    }
}

fn label_for(
    presentation: Presentation,
    timer_text: Option<&str>,
    session: &SessionRecord,
) -> String {
    match presentation {
        Presentation::Idle => "Idle".into(),
        Presentation::Ready => format!("Ready · {} sources", session.sources.len()),
        Presentation::Starting => "Starting…".into(),
        Presentation::Recording => format!("Recording · {}", timer_text.unwrap_or("00:00:00")),
        Presentation::Paused => format!("Paused · {}", timer_text.unwrap_or("00:00:00")),
        Presentation::Finalizing => "Finalizing".into(),
        Presentation::RecordingDegraded => "Recording — degraded".into(),
        Presentation::PermissionRevoked => "Permission revoked".into(),
        Presentation::RecoveryRequired => "Recovery required".into(),
        Presentation::Complete => "Complete".into(),
    }
}

const fn symbol_for(presentation: Presentation) -> SymbolContract {
    match presentation {
        Presentation::Idle => SymbolContract {
            primary: Some("waveform"),
            fallback: Some("circle"),
        },
        Presentation::Ready => SymbolContract {
            primary: Some("waveform.circle"),
            fallback: Some("waveform"),
        },
        Presentation::Starting => SymbolContract {
            primary: Some("ellipsis.circle"),
            fallback: Some("ellipsis"),
        },
        Presentation::Recording => SymbolContract {
            primary: Some("record.circle.fill"),
            fallback: Some("circle.fill"),
        },
        Presentation::Paused => SymbolContract {
            primary: Some("pause.circle.fill"),
            fallback: Some("pause.fill"),
        },
        Presentation::RecordingDegraded => SymbolContract {
            primary: Some("exclamationmark.triangle.fill"),
            fallback: Some("exclamationmark.triangle"),
        },
        Presentation::RecoveryRequired => SymbolContract {
            primary: Some("clock.arrow.circlepath"),
            fallback: Some("clock"),
        },
        Presentation::PermissionRevoked | Presentation::Finalizing | Presentation::Complete => {
            SymbolContract {
                primary: None,
                fallback: None,
            }
        }
    }
}

fn format_duration(seconds: u64) -> String {
    let hours = seconds / 3_600;
    let minutes = (seconds % 3_600) / 60;
    let seconds = seconds % 60;
    format!("{hours:02}:{minutes:02}:{seconds:02}")
}

fn source_summary(session: &SessionRecord) -> String {
    session
        .sources
        .iter()
        .map(|source| source.name.as_str())
        .collect::<Vec<_>>()
        .join(", ")
}

fn accessibility_value(label: &str, session: &SessionRecord) -> String {
    let mut value = format!("{label}. Sources: {}.", source_summary(session));
    for source in session
        .sources
        .iter()
        .filter(|source| source.health == SourceHealth::Failed)
    {
        let detail = source.health_detail.as_deref().unwrap_or("Source failed");
        value.push_str(&format!(" {}: {}.", source.name, detail));
    }
    value
}

fn source_failure_announcement(snapshot: &SessionSnapshot) -> String {
    let failed = snapshot
        .session
        .sources
        .iter()
        .find(|source| source.health == SourceHealth::Failed)
        .map(|source| source.name.as_str())
        .unwrap_or("A source");
    let remaining = snapshot
        .session
        .sources
        .iter()
        .find(|source| source.activity == SourceActivity::Active)
        .map(|source| source.name.as_str())
        .unwrap_or("Remaining source");
    format!("{failed} stopped. {remaining} recording continues.")
}

fn permission_loss_announcement(snapshot: &SessionSnapshot) -> String {
    let revoked = snapshot
        .session
        .sources
        .iter()
        .find(|source| source.permission.state == PermissionState::Revoked)
        .map(|source| source.name.as_str())
        .unwrap_or("Source");
    let remaining = snapshot
        .session
        .sources
        .iter()
        .find(|source| source.activity == SourceActivity::Active)
        .map(|source| source.name.as_str())
        .unwrap_or("Remaining source");
    format!("{revoked} permission revoked. {remaining} recording continues.")
}

#[cfg(test)]
mod tests {
    use super::*;
    use open_scribe_types::{Lifecycle, PermissionState, SessionHealth};

    #[test]
    fn starting_is_presentation_not_a_durable_lifecycle() {
        let mut machine = SessionMachine::from_fixture(Fixture::Ready);

        machine.apply(Command::RequestStart).unwrap();
        let snapshot = machine.snapshot();

        assert_eq!(snapshot.session.lifecycle, Lifecycle::Ready);
        assert_eq!(snapshot.presentation, Presentation::Starting);
        assert_eq!(snapshot.timer, TimerBehavior::Hidden);
    }

    #[test]
    fn recording_requires_both_journal_and_media_open_evidence() {
        let mut machine = SessionMachine::from_fixture(Fixture::Ready);
        machine.apply(Command::RequestStart).unwrap();

        let error = machine
            .apply(Command::ConfirmRecording {
                journal_durable: true,
                media_files_open: false,
            })
            .unwrap_err();

        assert_eq!(error, TransitionError::DurabilityEvidenceMissing);
        assert_eq!(machine.snapshot().session.lifecycle, Lifecycle::Ready);
        assert_eq!(machine.snapshot().presentation, Presentation::Starting);
    }

    #[test]
    fn degraded_health_and_permission_loss_are_orthogonal_conditions() {
        let degraded = SessionMachine::from_fixture(Fixture::RecordingDegraded).snapshot();
        assert_eq!(degraded.session.lifecycle, Lifecycle::Recording);
        assert_eq!(degraded.session.health, SessionHealth::Degraded);

        let permission = SessionMachine::from_fixture(Fixture::PermissionRevoked).snapshot();
        assert_eq!(permission.session.lifecycle, Lifecycle::Recording);
        assert_eq!(permission.session.health, SessionHealth::Degraded);
        assert!(
            permission
                .session
                .sources
                .iter()
                .any(|source| source.permission.state == PermissionState::Revoked)
        );
    }

    #[test]
    fn every_fixture_has_a_distinct_truthful_snapshot() {
        let catalog = fixture_catalog();
        assert_eq!(catalog.len(), Fixture::ALL.len());
        assert!(
            catalog
                .iter()
                .all(|(_, snapshot)| !snapshot.label.is_empty())
        );
        assert_eq!(
            SessionMachine::from_fixture(Fixture::Recording)
                .snapshot()
                .label,
            "Recording · 00:12:34"
        );
        assert_eq!(
            SessionMachine::from_fixture(Fixture::Ready)
                .snapshot()
                .label,
            "Ready · 2 sources"
        );
    }

    #[test]
    fn timer_ticks_do_not_generate_announcements() {
        let before = SessionMachine::from_fixture(Fixture::Recording).snapshot();
        let mut machine = SessionMachine::from_fixture(Fixture::Recording);
        let after = machine.apply(Command::AdvanceTimer(1)).unwrap();
        assert_eq!(announcement(&before, &after), None);
    }
}
