//! Production multi-track projections must not depend on track-ID order.
use crate::transcription::tests::{BurstRecognizer, complete_fixture_chunks};
use crate::{SessionStore, TranscriptionFailure, transcribe_track};
use open_scribe_asr::{DecodeOptions, Language};
use open_scribe_types::{AttemptState, DocumentAvailability};
use std::sync::atomic::AtomicBool;
use tempfile::TempDir;

#[test]
fn retained_automatic_work_can_pass_a_newer_model_hold_without_asr() {
    use crate::transcription::tests::{imported, write_burst_caf};
    use open_scribe_types::{ModelReadiness, WorkHold, WorkObservations, WorkOutcome};
    for model in [ModelReadiness::Absent, ModelReadiness::Invalid] {
        let mut fixture = imported(5);
        let ready = WorkObservations {
            model: ModelReadiness::Ready,
            ..Default::default()
        };
        let original = fixture.store.admit_transcription(ready).unwrap().unwrap();
        assert!(!original.manual);
        assert!(
            fixture
                .store
                .start_transcription_execution(
                    &fixture.session,
                    original.admission.as_deref().unwrap(),
                    original.intent,
                )
                .unwrap()
        );
        let run = complete_fixture_chunks(&mut fixture.store, &fixture.session, &fixture.track);
        fixture
            .store
            .fail_transcription_run(&run, None, TranscriptionFailure::CapturePreempted)
            .unwrap();
        fixture
            .store
            .finish_transcription(
                original.admission.as_deref().unwrap(),
                WorkOutcome::CapturePreempted,
            )
            .unwrap();
        let source = fixture.root.join("later.caf");
        write_burst_caf(&source, 48_000);
        let newest = fixture
            .store
            .import_recoverable_caf(open_scribe_store::ImportMediaRequest {
                title: "Later automatic arrival".into(),
                source_path: source,
            })
            .unwrap()
            .session_id;
        let observations = WorkObservations {
            model,
            ..Default::default()
        };
        let mut store = SessionStore::open(&fixture.root).unwrap();
        let queue = store.transcription_queue(observations).unwrap();
        assert_eq!(queue.len(), 2);
        assert_eq!(queue[0].session_id, newest);
        assert_eq!(
            queue[0].hold,
            Some(if model == ModelReadiness::Absent {
                WorkHold::ModelAbsent
            } else {
                WorkHold::ModelInvalid
            })
        );
        assert_eq!(queue[1].session_id, fixture.session);
        assert!(!queue[1].manual);
        assert_eq!(queue[1].hold, None);
        assert!(
            store
                .admit_retained_reconciliation(&fixture.session, observations)
                .unwrap()
                .is_none(),
            "queued work owns this automatic reconciliation"
        );
        let admitted = store
            .admit_transcription(observations)
            .unwrap()
            .expect("an eligible retained conversation must not be stranded by a model hold");
        assert_eq!(admitted.session_id, fixture.session);
        assert!(!admitted.manual);
        let token = admitted.admission.as_deref().unwrap();
        assert!(
            store
                .start_transcription_execution(&fixture.session, token, admitted.intent)
                .unwrap()
        );
        let operation = store
            .transcription_operation(&fixture.session, token)
            .unwrap();
        let plan = crate::plan_transcription_operation(
            &store,
            &fixture.session,
            admitted.intent,
            &operation,
        )
        .unwrap();
        assert!(!plan.needs_recognizer());
        let completed = crate::execute_transcription_plan(
            &mut store,
            None,
            &DecodeOptions::final_pass(Language::English),
            &plan,
            None,
            &AtomicBool::new(false),
            &mut |_, _, _| {},
        )
        .unwrap();
        assert_eq!(completed.len(), 1);
        assert_eq!(completed[0].transcribed_chunks, 0);
        store
            .finish_transcription(token, WorkOutcome::Completed)
            .unwrap();
        let snapshot = store.runtime_library_snapshot().unwrap();
        let rebuilt = snapshot
            .saved_sessions
            .iter()
            .find(|session| session.session_id == fixture.session)
            .unwrap();
        assert_eq!(rebuilt.transcript.document, DocumentAvailability::Final);
        assert_eq!(
            store.transcription_run_record(&run).unwrap().state,
            "cancelled"
        );
        let remaining = store.transcription_queue(observations).unwrap();
        assert_eq!(remaining.len(), 1);
        assert_eq!(remaining[0].session_id, newest);
        assert!(remaining[0].hold.is_some());
    }
}

#[test]
fn retained_rebuild_keeps_missing_tracks_eligible_without_repeating_the_request() {
    use open_scribe_types::{DocumentAvailability, ModelReadiness, WorkObservations, WorkOutcome};
    for retained_tracks in 0..=2 {
        let temp = TempDir::new().unwrap();
        let (mut store, session, _) = crate::package_import_tests::captured(&temp);
        let tracks = store.transcription_tracks(&session).unwrap();
        for track in tracks.iter().take(retained_tracks) {
            complete_fixture_chunks(&mut store, &session, track);
        }
        let intent = crate::TranscriptionIntent::ReconcileRetained;
        let off = WorkObservations {
            automatic: false,
            ..Default::default()
        };
        store.request_transcription(&session, intent).unwrap();
        let admission = store.admit_transcription(off).unwrap().unwrap();
        let plan = crate::plan_session_transcription(&store, &session, intent).unwrap();
        assert!(!plan.needs_recognizer());
        assert_eq!(plan.tracks.len(), retained_tracks);
        assert_eq!(plan.unreconciled_tracks, 2 - retained_tracks);
        let outcome = plan.completion_outcome();
        assert_eq!(
            outcome,
            if retained_tracks == 2 {
                WorkOutcome::Completed
            } else {
                WorkOutcome::Incomplete
            }
        );
        let built = crate::execute_transcription_plan(
            &mut store,
            None,
            &DecodeOptions::final_pass(Language::English),
            &plan,
            None,
            &AtomicBool::new(false),
            &mut |_, _, _| {},
        )
        .unwrap();
        assert_eq!(built.len(), retained_tracks);
        assert!(built.iter().all(|track| track.transcribed_chunks == 0));
        store
            .finish_transcription(admission.admission.as_deref().unwrap(), outcome)
            .unwrap();
        let reopened = SessionStore::open(temp.path().join("Open Scribe")).unwrap();
        assert!(
            reopened.transcription_queue(off).unwrap().is_empty(),
            "an exhausted manual rebuild must end"
        );
        let snapshot = reopened
            .runtime_library_snapshot()
            .unwrap()
            .saved_sessions
            .remove(0)
            .transcript;
        assert_eq!(snapshot.final_tracks, retained_tracks as u32);
        assert_eq!(
            snapshot.document,
            match retained_tracks {
                0 => DocumentAvailability::None,
                1 => DocumentAvailability::Partial,
                _ => DocumentAvailability::Final,
            }
        );
        let queued = reopened
            .transcription_queue(WorkObservations {
                model: ModelReadiness::Ready,
                ..Default::default()
            })
            .unwrap();
        assert_eq!(queued.len(), usize::from(retained_tracks < 2));
        if let Some(next) = queued.first() {
            assert!(!next.manual);
            assert_eq!(next.intent, crate::TranscriptionIntent::ResumeIncomplete);
            assert_eq!(next.hold, None);
            let resume =
                crate::plan_session_transcription(&reopened, &session, next.intent).unwrap();
            assert_eq!(resume.tracks.len(), 2 - retained_tracks);
        }
    }
}

#[test]
fn completed_tracks_cannot_hide_a_cancelled_or_preempted_replacement() {
    for stopped_track in [0, 1] {
        for (failure, attempt) in [
            (TranscriptionFailure::Cancelled, AttemptState::Cancelled),
            (
                TranscriptionFailure::CapturePreempted,
                AttemptState::Preempted,
            ),
        ] {
            let temp = TempDir::new().unwrap();
            let (mut store, session, _) = crate::package_import_tests::captured(&temp);
            let tracks = store.transcription_tracks(&session).unwrap();
            let options = DecodeOptions::final_pass(Language::English);
            for track in &tracks {
                transcribe_track(
                    &mut store,
                    &mut BurstRecognizer::new(&"a".repeat(64)),
                    &options,
                    &session,
                    track,
                    &AtomicBool::new(false),
                    &mut |_| {},
                )
                .unwrap();
            }
            let reviewed = store.transcript_document(&session).unwrap();
            let original = store
                .transcription_runs(&session)
                .unwrap()
                .into_iter()
                .find(|run| run.track_id == tracks[stopped_track])
                .unwrap();
            let record = store.transcription_run_record(&original.run_id).unwrap();
            let replacement = store
                .begin_transcription_run(
                    &open_scribe_store::TranscriptionRunIdentity {
                        options_digest: "replacement".into(),
                        ..record.identity
                    },
                    &record.plan,
                )
                .unwrap();
            store
                .fail_transcription_run(&replacement.run_id, None, failure)
                .unwrap();
            // Reopening must present the same accepted document and stop reason,
            // even without the in-memory scheduler's completion overlay.
            let reopened = SessionStore::open(temp.path().join("Open Scribe")).unwrap();
            let snapshot = reopened
                .runtime_library_snapshot()
                .unwrap()
                .saved_sessions
                .remove(0)
                .transcript;
            assert_eq!(snapshot.document, DocumentAvailability::Final);
            assert_eq!(reopened.transcript_document(&session).unwrap(), reviewed);
            assert_eq!(
                snapshot.attempt, attempt,
                "track {stopped_track}: {failure:?}"
            );
            assert!(snapshot.attempt_failure.is_none());

            for (index, track) in tracks.iter().enumerate() {
                let source = store
                    .transcription_runs(&session)
                    .unwrap()
                    .into_iter()
                    .find(|run| &run.track_id == track)
                    .unwrap();
                let record = store.transcription_run_record(&source.run_id).unwrap();
                let pending = store
                    .begin_transcription_run(
                        &open_scribe_store::TranscriptionRunIdentity {
                            options_digest: "new-work".into(),
                            ..record.identity
                        },
                        &record.plan,
                    )
                    .unwrap();
                if index == stopped_track {
                    store
                        .fail_transcription_run(
                            &pending.run_id,
                            None,
                            TranscriptionFailure::EngineError,
                        )
                        .unwrap();
                }
            }
            let running = reopened
                .runtime_library_snapshot()
                .unwrap()
                .saved_sessions
                .remove(0)
                .transcript;
            assert_eq!(running.attempt, AttemptState::Running);
            assert!(
                running.attempt_failure.is_none(),
                "an active track must not carry a different track's past failure"
            );
            assert_eq!(reopened.transcript_document(&session).unwrap(), reviewed);
        }
    }
}
