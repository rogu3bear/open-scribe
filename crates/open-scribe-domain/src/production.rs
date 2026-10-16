//! Pure production decisions shared by the durable store and fixture inputs.
use open_scribe_types::{
    AttemptState, ModelReadiness, TranscriptionIntent, WorkHold, WorkObservations,
};

/// Aggregate the latest attempt on each track independently of track order.
/// Active work and unresolved stops remain visible beside completed tracks.
pub fn merge_transcription_attempt(left: AttemptState, right: AttemptState) -> AttemptState {
    let priority = |state| match state {
        AttemptState::None => 0,
        AttemptState::Complete => 1,
        AttemptState::Cancelled => 2,
        AttemptState::Preempted => 3,
        AttemptState::Failed => 4,
        AttemptState::Running => 5,
        AttemptState::Unknown => 6,
    };
    if priority(right) > priority(left) {
        right
    } else {
        left
    }
}

pub fn recording_evidence_sufficient(
    required: usize,
    active: usize,
    journal: bool,
    media: bool,
) -> bool {
    required > 0 && required == active && journal && media
}

pub fn transcription_hold(
    manual: bool,
    intent: TranscriptionIntent,
    observations: WorkObservations,
) -> Option<WorkHold> {
    if observations.capture_active {
        return Some(WorkHold::Capture);
    }
    if observations.media_recovery_pending {
        return Some(WorkHold::MediaRecovery);
    }
    if observations
        .available_disk_bytes
        .is_some_and(|bytes| bytes < 1 << 30)
    {
        return Some(WorkHold::DiskPressure);
    }
    if observations.memory_critical {
        return Some(WorkHold::MemoryPressure);
    }
    if observations.thermal_critical {
        return Some(WorkHold::ThermalPressure);
    }
    if !manual && !observations.automatic {
        return Some(WorkHold::AutomaticDisabled);
    }
    if !manual && observations.paused {
        return Some(WorkHold::AutomaticPaused);
    }
    if intent != TranscriptionIntent::ReconcileRetained {
        match observations.model {
            ModelReadiness::Ready => {}
            ModelReadiness::Absent => return Some(WorkHold::ModelAbsent),
            ModelReadiness::PresentUnverified | ModelReadiness::Verifying => {
                return Some(WorkHold::ModelUnverified);
            }
            ModelReadiness::Invalid => return Some(WorkHold::ModelInvalid),
            ModelReadiness::Incompatible => return Some(WorkHold::ModelIncompatible),
        }
    }
    None
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn completed_fixture_tracks_cannot_hide_unresolved_or_active_attempts() {
        for state in [
            AttemptState::Cancelled,
            AttemptState::Preempted,
            AttemptState::Failed,
            AttemptState::Running,
            AttemptState::Unknown,
        ] {
            assert_eq!(
                merge_transcription_attempt(AttemptState::Complete, state),
                state
            );
            assert_eq!(
                merge_transcription_attempt(state, AttemptState::Complete),
                state
            );
        }
        assert_eq!(
            merge_transcription_attempt(AttemptState::Failed, AttemptState::Running),
            AttemptState::Running
        );
        assert_eq!(
            merge_transcription_attempt(AttemptState::Running, AttemptState::Failed),
            AttemptState::Running
        );
    }
    #[test]
    fn manual_and_reconciliation_intent_preserve_capture_priority() {
        let observations = WorkObservations {
            automatic: false,
            paused: true,
            model: ModelReadiness::Ready,
            ..Default::default()
        };
        assert_eq!(
            transcription_hold(true, TranscriptionIntent::ResumeIncomplete, observations),
            None
        );
        assert_eq!(
            transcription_hold(false, TranscriptionIntent::ResumeIncomplete, observations),
            Some(WorkHold::AutomaticDisabled)
        );
        assert_eq!(
            transcription_hold(
                true,
                TranscriptionIntent::ReconcileRetained,
                WorkObservations::default()
            ),
            None
        );
        assert_eq!(
            transcription_hold(
                true,
                TranscriptionIntent::ReconcileRetained,
                WorkObservations {
                    capture_active: true,
                    ..Default::default()
                }
            ),
            Some(WorkHold::Capture)
        );
        assert!(!recording_evidence_sufficient(2, 1, true, true));
        assert!(!recording_evidence_sufficient(0, 0, true, true));
        assert!(recording_evidence_sufficient(2, 2, true, true));
    }
}
