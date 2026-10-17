//! Production multi-track projections must not depend on track-ID order.
use crate::transcription::tests::{BurstRecognizer, complete_fixture_chunks};
use crate::{SessionStore, TranscriptionFailure, transcribe_track};
use open_scribe_asr::{DecodeOptions, Language};
use open_scribe_types::{AttemptState, DocumentAvailability};
use std::sync::atomic::AtomicBool;
use tempfile::TempDir;

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
