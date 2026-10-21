use super::*;
use crate::transcripts::tests::{imported_fixture, sample, write_caf};
use open_scribe_types::{
    ModelReadiness, TranscriptionIntent, WorkHold, WorkObservations, WorkOutcome,
};

fn ready() -> WorkObservations {
    WorkObservations {
        model: ModelReadiness::Ready,
        ..Default::default()
    }
}

#[test]
fn manual_origin_survives_capture_pause_restart_and_idempotent_requests() {
    let mut f = imported_fixture(48_000);
    f.store
        .request_transcription(&f.session, TranscriptionIntent::ResumeIncomplete)
        .unwrap();
    f.store
        .request_transcription(&f.session, TranscriptionIntent::ResumeIncomplete)
        .unwrap();
    let paused = WorkObservations {
        automatic: false,
        paused: true,
        ..ready()
    };
    let admitted = f.store.admit_transcription(paused).unwrap().unwrap();
    assert!(admitted.manual);
    let mut other = SessionStore::open(&f.root).unwrap();
    assert!(
        other
            .start_transcription_execution(
                &f.session,
                admitted.admission.as_deref().unwrap(),
                admitted.intent
            )
            .unwrap()
    );
    assert!(
        !f.store
            .start_transcription_execution(
                &f.session,
                admitted.admission.as_deref().unwrap(),
                admitted.intent
            )
            .unwrap(),
        "duplicate runner rejected across handles"
    );
    assert!(
        f.store.admit_transcription(paused).unwrap().is_none(),
        "one admitted runner per library"
    );
    f.store
        .finish_transcription(
            admitted.admission.as_deref().unwrap(),
            WorkOutcome::CapturePreempted,
        )
        .unwrap();
    let mut reopened = SessionStore::open(&f.root).unwrap();
    let captured = WorkObservations {
        capture_active: true,
        ..paused
    };
    assert_eq!(
        reopened.transcription_queue(captured).unwrap()[0].hold,
        Some(WorkHold::Capture)
    );
    assert!(reopened.admit_transcription(captured).unwrap().is_none());
    let resumed = reopened.admit_transcription(paused).unwrap().unwrap();
    assert!(resumed.manual);
    assert_eq!(resumed.intent, TranscriptionIntent::ResumeIncomplete);
    // Stale completion may not clear the current token.
    reopened
        .finish_transcription(
            admitted.admission.as_deref().unwrap(),
            WorkOutcome::Completed,
        )
        .unwrap();
    assert!(reopened.admit_transcription(paused).unwrap().is_none());
    reopened
        .finish_transcription(
            resumed.admission.as_deref().unwrap(),
            WorkOutcome::UserCancelled,
        )
        .unwrap();
    assert!(reopened.transcription_queue(ready()).unwrap().is_empty());
}

#[test]
fn automatic_off_preemption_and_new_arrivals_preserve_intent_and_priority() {
    let mut f = imported_fixture(48_000);
    let first = f.store.admit_transcription(ready()).unwrap().unwrap();
    assert!(!first.manual);
    f.store
        .finish_transcription(
            first.admission.as_deref().unwrap(),
            WorkOutcome::CapturePreempted,
        )
        .unwrap();
    assert!(
        f.store
            .transcription_queue(WorkObservations {
                automatic: false,
                ..ready()
            })
            .unwrap()
            .is_empty()
    );
    let source = f.root.join("new.caf");
    write_caf(&source, 48_000, sample);
    let new = f
        .store
        .import_recoverable_caf(ImportMediaRequest {
            title: "Later arrival".into(),
            source_path: source,
        })
        .unwrap()
        .session_id;
    let queue = f.store.transcription_queue(ready()).unwrap();
    assert_eq!(
        queue
            .iter()
            .map(|entry| &entry.session_id)
            .collect::<Vec<_>>(),
        [&new, &f.session]
    );
    f.store
        .request_transcription(&f.session, TranscriptionIntent::ReprocessAll)
        .unwrap();
    let queue = f.store.transcription_queue(ready()).unwrap();
    assert_eq!(queue[0].session_id, f.session);
    assert!(queue[0].manual);
}

#[test]
fn declines_have_no_eviction_and_launch_recovery_retains_manual_action() {
    let mut f = imported_fixture(48_000);
    for index in 0..205 {
        let session = f
            .store
            .prepare_session(PrepareSessionRequest {
                title: format!("declined {index}"),
                origin: SessionOrigin::Import,
            })
            .unwrap()
            .session_id;
        f.store.cancel_transcription(&session).unwrap();
    }
    f.store
        .request_transcription(&f.session, TranscriptionIntent::ReconcileRetained)
        .unwrap();
    let claim = f
        .store
        .admit_transcription(WorkObservations::default())
        .unwrap()
        .unwrap();
    assert_eq!(claim.intent, TranscriptionIntent::ReconcileRetained);
    let mut reopened = SessionStore::open(&f.root).unwrap();
    reopened.recover_transcription_admissions().unwrap();
    assert_eq!(
        reopened
            .connection
            .query_row(
                "SELECT COUNT(*) FROM transcription_intent WHERE declined_auto = 1",
                [],
                |r| r.get::<_, u32>(0)
            )
            .unwrap(),
        205
    );
    let resumed = reopened
        .admit_transcription(WorkObservations {
            automatic: false,
            ..Default::default()
        })
        .unwrap()
        .unwrap();
    assert!(resumed.manual);
    assert_eq!(resumed.intent, TranscriptionIntent::ReconcileRetained);
}

#[test]
fn model_pressure_recovery_and_durable_capture_holds_are_final_admission() {
    let mut f = imported_fixture(48_000);
    f.store
        .request_transcription(&f.session, TranscriptionIntent::ResumeIncomplete)
        .unwrap();
    let cases = [
        (WorkObservations::default(), WorkHold::ModelAbsent),
        (
            WorkObservations {
                model: ModelReadiness::Invalid,
                ..ready()
            },
            WorkHold::ModelInvalid,
        ),
        (
            WorkObservations {
                media_recovery_pending: true,
                ..ready()
            },
            WorkHold::MediaRecovery,
        ),
        (
            WorkObservations {
                memory_critical: true,
                ..ready()
            },
            WorkHold::MemoryPressure,
        ),
        (
            WorkObservations {
                thermal_critical: true,
                ..ready()
            },
            WorkHold::ThermalPressure,
        ),
        (
            WorkObservations {
                available_disk_bytes: Some(1),
                ..ready()
            },
            WorkHold::DiskPressure,
        ),
    ];
    for (observations, hold) in cases {
        assert_eq!(
            f.store.transcription_queue(observations).unwrap()[0].hold,
            Some(hold)
        );
        assert!(f.store.admit_transcription(observations).unwrap().is_none());
    }
    f.store
        .prepare_session(PrepareSessionRequest {
            title: "Preparing capture".into(),
            origin: SessionOrigin::Capture,
        })
        .unwrap();
    assert_eq!(
        f.store.transcription_queue(ready()).unwrap()[0].hold,
        Some(WorkHold::Capture)
    );
    assert!(
        f.store.admit_transcription(ready()).unwrap().is_none(),
        "native stale false cannot waive durable preparation"
    );
}

#[test]
fn cancellation_is_persistent_and_cannot_be_replaced_by_failed_completion() {
    let mut f = imported_fixture(48_000);
    let claim = f.store.admit_transcription(ready()).unwrap().unwrap();
    f.store.cancel_transcription(&f.session).unwrap();
    f.store
        .finish_transcription(claim.admission.as_deref().unwrap(), WorkOutcome::Failed)
        .unwrap();
    let reopened = SessionStore::open(&f.root).unwrap();
    assert_eq!(
        reopened.transcription_outcomes().unwrap(),
        [(f.session.0.clone(), WorkOutcome::UserCancelled, None)]
    );
    assert!(reopened.transcription_queue(ready()).unwrap().is_empty());
}

#[test]
fn outcome_admission_distinguishes_retries_and_rejects_old_completion() {
    let mut f = imported_fixture(48_000);
    f.store
        .request_transcription(&f.session, TranscriptionIntent::ResumeIncomplete)
        .unwrap();
    let first = f.store.admit_transcription(ready()).unwrap().unwrap();
    f.store
        .finish_transcription(first.admission.as_deref().unwrap(), WorkOutcome::Failed)
        .unwrap();
    assert_eq!(
        f.store.transcription_outcomes().unwrap(),
        [(
            f.session.0.clone(),
            WorkOutcome::Failed,
            first.admission.clone()
        )]
    );
    f.store
        .request_transcription(&f.session, TranscriptionIntent::ResumeIncomplete)
        .unwrap();
    let second = f.store.admit_transcription(ready()).unwrap().unwrap();
    assert_ne!(second.admission, first.admission);
    f.store
        .finish_transcription(first.admission.as_deref().unwrap(), WorkOutcome::Failed)
        .unwrap();
    assert!(f.store.transcription_outcomes().unwrap().is_empty());
    f.store
        .finish_transcription(second.admission.as_deref().unwrap(), WorkOutcome::Completed)
        .unwrap();
    let reopened = SessionStore::open(&f.root).unwrap();
    assert_eq!(
        reopened.transcription_outcomes().unwrap(),
        [(
            f.session.0.clone(),
            WorkOutcome::Completed,
            second.admission
        )]
    );
}

#[test]
fn resumed_replacement_keeps_its_operation_but_has_a_new_completion_receipt() {
    let mut f = imported_fixture(48_000);
    f.store
        .request_transcription(&f.session, TranscriptionIntent::ReprocessAll)
        .unwrap();
    let first = f.store.admit_transcription(ready()).unwrap().unwrap();
    let first_token = first.admission.as_deref().unwrap();
    let operation = f
        .store
        .transcription_operation(&f.session, first_token)
        .unwrap();
    f.store
        .finish_transcription(first_token, WorkOutcome::Failed)
        .unwrap();
    assert_eq!(
        f.store.transcription_outcomes().unwrap(),
        [(
            f.session.0.clone(),
            WorkOutcome::Failed,
            first.admission.clone()
        )]
    );

    // This entire execution can happen on another handle between UI polls.
    let mut other = SessionStore::open(&f.root).unwrap();
    other.resume_replacement(&f.session).unwrap();
    assert!(other.transcription_outcomes().unwrap().is_empty());
    let second = other.admit_transcription(ready()).unwrap().unwrap();
    let second_token = second.admission.as_deref().unwrap();
    assert_ne!(second.admission, first.admission);
    let resumed = other
        .transcription_operation(&f.session, second_token)
        .unwrap();
    assert_eq!(
        resumed.key, operation.key,
        "resume preserves the replacement generation"
    );
    assert_eq!(resumed.selections, operation.selections);
    other
        .finish_transcription(first_token, WorkOutcome::Failed)
        .unwrap();
    assert!(other.transcription_outcomes().unwrap().is_empty());
    other
        .finish_transcription(second_token, WorkOutcome::Failed)
        .unwrap();
    let reopened = SessionStore::open(&f.root).unwrap();
    assert_eq!(
        reopened.transcription_outcomes().unwrap(),
        [(f.session.0.clone(), WorkOutcome::Failed, second.admission)]
    );
}

#[test]
fn migration_16_leaves_legacy_failures_unbound_and_preserves_replacement_guards() {
    let mut f = imported_fixture(48_000);
    let original_media = fs::read(&f.media).unwrap();
    f.store
        .request_transcription(&f.session, TranscriptionIntent::ReprocessAll)
        .unwrap();
    let first = f.store.admit_transcription(ready()).unwrap().unwrap();
    let token = first.admission.as_deref().unwrap();
    let operation = f.store.transcription_operation(&f.session, token).unwrap();
    f.store
        .finish_transcription(token, WorkOutcome::Failed)
        .unwrap();
    // Recreate the previous intent-table shape in this owned synthetic store.
    f.store
        .connection
        .execute_batch(
            "ALTER TABLE transcription_intent DROP COLUMN last_outcome_admission;
         DELETE FROM schema_migrations WHERE version = 16;",
        )
        .unwrap();

    for _ in 0..2 {
        let reopened = SessionStore::open(&f.root).unwrap();
        assert_eq!(
            reopened.transcription_outcomes().unwrap(),
            [(f.session.0.clone(), WorkOutcome::Failed, None)]
        );
        assert_eq!(fs::read(&f.media).unwrap(), original_media);
        let versions: Vec<i64> = reopened
            .connection
            .prepare("SELECT version FROM schema_migrations ORDER BY version")
            .unwrap()
            .query_map([], |row| row.get(0))
            .unwrap()
            .map(Result::unwrap)
            .collect();
        assert_eq!(versions, (1..=16).collect::<Vec<_>>());
    }
    let mut reopened = SessionStore::open(&f.root).unwrap();
    reopened.resume_replacement(&f.session).unwrap();
    let resumed = reopened.admit_transcription(ready()).unwrap().unwrap();
    let current = reopened
        .transcription_operation(&f.session, resumed.admission.as_deref().unwrap())
        .unwrap();
    assert_eq!(current.key, operation.key);
    assert_eq!(current.selections, operation.selections);
}

#[test]
fn cancelling_then_requesting_again_before_completion_preserves_the_new_operation() {
    let mut f = imported_fixture(48_000);
    f.store
        .request_transcription(&f.session, TranscriptionIntent::ResumeIncomplete)
        .unwrap();
    let old = f.store.admit_transcription(ready()).unwrap().unwrap();
    f.store.cancel_transcription(&f.session).unwrap();
    f.store
        .request_transcription(&f.session, TranscriptionIntent::ReprocessAll)
        .unwrap();
    f.store
        .finish_transcription(
            old.admission.as_deref().unwrap(),
            WorkOutcome::UserCancelled,
        )
        .unwrap();
    let observations = WorkObservations {
        automatic: false,
        paused: true,
        ..ready()
    };
    let next = f.store.admit_transcription(observations).unwrap().unwrap();
    assert!(next.manual);
    assert_eq!(next.intent, TranscriptionIntent::ReprocessAll);
}

#[test]
fn unsupported_durable_intent_or_outcome_is_a_visible_non_admission() {
    let mut f = imported_fixture(48_000);
    f.store
        .request_transcription(&f.session, TranscriptionIntent::ResumeIncomplete)
        .unwrap();
    for field in ["requested_action", "last_outcome"] {
        f.store.connection.execute(&format!("UPDATE transcription_intent SET {field} = 'future-unsupported-state' WHERE session_id = ?1"), [&f.session.0]).unwrap();
        assert_eq!(
            f.store.transcription_queue(ready()).unwrap()[0].hold,
            Some(WorkHold::UnknownState)
        );
        assert!(f.store.admit_transcription(ready()).unwrap().is_none());
        f.store
            .connection
            .execute(
                "UPDATE transcription_intent SET requested_action = 'resume', last_outcome = NULL",
                [],
            )
            .unwrap();
    }
}

#[test]
fn maintenance_and_manual_execution_share_one_atomic_admission_across_handles() {
    let mut f = imported_fixture(48_000);
    let maintenance = f
        .store
        .admit_retained_reconciliation(&f.session, WorkObservations::default())
        .unwrap()
        .unwrap();
    let token = maintenance.admission.as_deref().unwrap();
    assert!(!maintenance.manual);
    assert!(
        f.store
            .start_transcription_execution(&f.session, token, maintenance.intent)
            .unwrap()
    );
    let mut other = SessionStore::open(&f.root).unwrap();
    other
        .request_transcription(&f.session, TranscriptionIntent::ResumeIncomplete)
        .unwrap();
    assert!(other.admit_transcription(ready()).unwrap().is_none());
    assert!(
        other
            .admit_retained_reconciliation(&f.session, WorkObservations::default())
            .unwrap()
            .is_none()
    );
    assert!(
        other
            .recover_orphan_transcription_runs()
            .unwrap()
            .0
            .is_empty()
    );
    f.store
        .finish_transcription(token, WorkOutcome::Completed)
        .unwrap();
    assert!(
        other
            .admit_retained_reconciliation(&f.session, WorkObservations::default())
            .unwrap()
            .is_none(),
        "queued explicit intent keeps priority"
    );
    let manual = other.admit_transcription(ready()).unwrap().unwrap();
    assert!(manual.manual);
    assert_eq!(manual.intent, TranscriptionIntent::ResumeIncomplete);
}
