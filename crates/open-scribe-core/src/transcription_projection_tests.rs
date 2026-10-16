//! Production multi-track projections must not depend on track-ID order.
use crate::transcription::tests::BurstRecognizer;
use crate::{SessionStore, TranscriptionFailure, transcribe_track};
use open_scribe_asr::{DecodeOptions, Language};
use open_scribe_types::{AttemptState, DocumentAvailability};
use std::sync::atomic::AtomicBool;
use tempfile::TempDir;

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
