//! Resolve intent and review expectations before model loading or long reads.
use crate::transcription::reconcile_retained_chunks_with_policy;
use crate::{
    TrackRequest, TranscriptionError, TranscriptionOutcome, TranscriptionProgress,
    transcribe_request,
};
use open_scribe_asr::{DecodeOptions, SpeechRecognizer};
use open_scribe_store::{SessionStore, StoreError, TranscriptionOperation, TranscriptionRunPolicy};
use open_scribe_types::{SessionId, TranscriptionIntent, WorkOutcome};
use std::path::Path;
use std::sync::atomic::{AtomicBool, Ordering};

#[derive(Clone, Debug)]
pub struct PlannedTrack {
    pub track_id: String,
    pub retained_run: Option<String>,
    pub policy: TranscriptionRunPolicy,
}
#[derive(Clone, Debug)]
pub struct SessionTranscriptionPlan {
    pub session: SessionId,
    pub intent: TranscriptionIntent,
    pub tracks: Vec<PlannedTrack>,
    /// Required incomplete tracks without complete compatible retained chunks.
    /// Reconciliation cannot recognize them, but future recognition may.
    pub unreconciled_tracks: usize,
}
impl SessionTranscriptionPlan {
    pub fn needs_recognizer(&self) -> bool {
        self.tracks.iter().any(|track| track.retained_run.is_none())
    }
    pub fn completion_outcome(&self) -> WorkOutcome {
        if self.unreconciled_tracks > 0 {
            WorkOutcome::Incomplete
        } else {
            WorkOutcome::Completed
        }
    }
}
pub fn plan_session_transcription(
    store: &SessionStore,
    session: &SessionId,
    intent: TranscriptionIntent,
) -> Result<SessionTranscriptionPlan, StoreError> {
    plan_transcription_operation(store, session, intent, &TranscriptionOperation::default())
}
pub fn plan_transcription_operation(
    store: &SessionStore,
    session: &SessionId,
    intent: TranscriptionIntent,
    operation: &TranscriptionOperation,
) -> Result<SessionTranscriptionPlan, StoreError> {
    let tracks = store.transcription_tracks(session)?;
    if tracks.is_empty() {
        return Err(StoreError::InvalidState(
            "session has no sealed track to transcribe",
        ));
    }
    // One read snapshot before any full media hash or model load. Queued manual
    // intent supplies its earlier durable expectation instead.
    let selections = if operation.selections.is_empty() {
        store.selection_expectations(session)?
    } else {
        operation.selections.clone()
    };
    let operation_key = (intent == TranscriptionIntent::ReprocessAll).then(|| {
        operation
            .key
            .clone()
            .unwrap_or_else(SessionStore::fresh_transcription_operation)
    });
    let runs = store.transcription_runs(session)?;
    let mut planned = Vec::new();
    let mut unreconciled_tracks = 0;
    for track in tracks {
        let input = store.transcription_input(session, &track)?;
        if let Some(key) = &operation_key {
            if store.completed_operation_track(key, session, &track, &input.input_digest)? {
                continue;
            }
        } else if store.selected_final_matches_input(session, &track, &input.input_digest)? {
            continue;
        }
        let candidates = runs.iter().rev().filter(|run| {
            run.track_id == track
                && run.total_chunks > 0
                && run.completed_chunks == run.total_chunks
                && (matches!(run.state.as_str(), "running" | "cancelled")
                    || (intent == TranscriptionIntent::ReprocessAll && run.state == "complete")
                    || (run.state == "failed"
                        && matches!(
                            run.failure_class.as_deref(),
                            Some(
                                "invalid_result"
                                    | "stale_reconciliation"
                                    | "orphaned"
                                    | "storage_error"
                            )
                        )))
        });
        let mut retained = None;
        for run in candidates {
            let record = store.transcription_run_record(&run.run_id)?;
            if record.identity.input_digest == input.input_digest {
                retained = Some(run.run_id.clone());
                break;
            }
        }
        if intent == TranscriptionIntent::ReconcileRetained && retained.is_none() {
            unreconciled_tracks += 1;
            continue;
        }
        planned.push(PlannedTrack {
            policy: TranscriptionRunPolicy {
                operation_key: operation_key.clone(),
                selection: selections
                    .iter()
                    .find(|expected| expected.track_id == track)
                    .map(|expected| expected.selection.clone()),
            },
            track_id: track,
            retained_run: retained,
        });
    }
    Ok(SessionTranscriptionPlan {
        session: session.clone(),
        intent,
        tracks: planned,
        unreconciled_tracks,
    })
}
pub fn execute_transcription_plan(
    store: &mut SessionStore,
    mut recognizer: Option<&mut dyn SpeechRecognizer>,
    options: &DecodeOptions,
    plan: &SessionTranscriptionPlan,
    decoded_companion: Option<&Path>,
    cancel: &AtomicBool,
    progress: &mut dyn FnMut(usize, usize, TranscriptionProgress),
) -> Result<Vec<TranscriptionOutcome>, TranscriptionError> {
    let mut outcomes = Vec::new();
    for (index, track) in plan.tracks.iter().enumerate() {
        if cancel.load(Ordering::Acquire) {
            return Err(StoreError::InvalidState("transcription deferred or cancelled").into());
        }
        if plan.intent != TranscriptionIntent::ReprocessAll
            && store.has_compatible_selected_final(&plan.session, &track.track_id)?
        {
            continue;
        }
        if let Some(retained) = &track.retained_run {
            let recovered = reconcile_retained_chunks_with_policy(store, retained, &track.policy)?;
            outcomes.push(TranscriptionOutcome {
                run_id: recovered.run_id,
                revision_id: recovered.revision_id,
                resumed: false,
                reused_chunks: recovered.reused_chunks,
                transcribed_chunks: 0,
                segment_count: recovered.segment_count,
                rejections: recovered.rejections,
            });
        } else {
            let Some(ref mut recognizer) = recognizer else {
                return Err(
                    StoreError::InvalidState("recognition required but no model loaded").into(),
                );
            };
            outcomes.push(transcribe_request(
                store,
                *recognizer,
                options,
                TrackRequest {
                    session: &plan.session,
                    track_id: &track.track_id,
                    decoded_companion,
                    policy: Some(&track.policy),
                },
                cancel,
                &mut |update| progress(index, plan.tracks.len(), update),
            )?);
        }
    }
    Ok(outcomes)
}
