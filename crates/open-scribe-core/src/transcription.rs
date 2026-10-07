//! Final transcription of one sealed track (ADR 0009).
//!
//! Reads verified sealed samples, converts them to 16 kHz mono, runs the
//! recognizer chunk by chunk with a durable commit after each chunk, then
//! reconciles overlaps into one immutable verbatim revision. Recognizer
//! failure or cancellation ends only the run: media, prior revisions, and
//! the current selection are never touched.

use open_scribe_asr::{
    ChunkHypothesis, Decimator, DecodeOptions, Hypothesis, MODEL_SAMPLE_RATE_HZ,
    RECONCILIATION_VERSION, RecognizerError, Rejections, SOURCE_SAMPLE_RATE_HZ, SpeechRecognizer,
    plan_chunks, reconcile,
};
use open_scribe_store::{
    PlannedTranscriptChunk, RevisionSegmentInput, SessionStore, StoreError, TranscriptChunkState,
    TranscriptionFailure, TranscriptionInput, TranscriptionRunIdentity,
};
use open_scribe_types::SessionId;
use std::fmt;
use std::path::Path;
use std::sync::atomic::{AtomicBool, Ordering};

const NANOSECONDS_PER_SECOND: i64 = 1_000_000_000;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum TranscriptionStage {
    Decoding,
    Transcribing,
    Reconciling,
}

/// Progress is verified media duration completed over required duration.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct TranscriptionProgress {
    pub stage: TranscriptionStage,
    pub completed_nanoseconds: i64,
    pub required_nanoseconds: i64,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct TranscriptionOutcome {
    pub run_id: String,
    pub revision_id: String,
    pub resumed: bool,
    pub reused_chunks: u32,
    pub transcribed_chunks: u32,
    pub segment_count: u32,
    pub rejections: Rejections,
}

#[derive(Debug)]
pub enum TranscriptionError {
    /// Input could not be read or storage refused; no run may exist.
    Store(StoreError),
    /// The run ended without a revision; its committed chunks remain.
    RunEnded {
        run_id: String,
        failure: TranscriptionFailure,
    },
}

impl fmt::Display for TranscriptionError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Store(error) => write!(f, "transcription storage failed: {error}"),
            Self::RunEnded { failure, .. } => {
                write!(f, "transcription run ended: {}", failure.class())
            }
        }
    }
}

impl std::error::Error for TranscriptionError {}

impl From<StoreError> for TranscriptionError {
    fn from(error: StoreError) -> Self {
        Self::Store(error)
    }
}

pub(crate) struct PlannedWindow {
    span_index: usize,
    start_sample: u64,
    end_sample: u64,
    chunk: PlannedTranscriptChunk,
}

/// One track to transcribe. A compressed import also needs the PCM companion
/// the platform decoded from its leased bytes.
#[derive(Clone, Copy, Debug)]
pub struct TrackRequest<'a> {
    pub session: &'a SessionId,
    pub track_id: &'a str,
    pub decoded_companion: Option<&'a Path>,
}

pub fn transcribe_track(
    store: &mut SessionStore,
    recognizer: &mut dyn SpeechRecognizer,
    options: &DecodeOptions,
    session: &SessionId,
    track_id: &str,
    cancel: &AtomicBool,
    progress: &mut dyn FnMut(TranscriptionProgress),
) -> Result<TranscriptionOutcome, TranscriptionError> {
    let request = TrackRequest {
        session,
        track_id,
        decoded_companion: None,
    };
    transcribe_request(store, recognizer, options, request, cancel, progress)
}

pub fn transcribe_request(
    store: &mut SessionStore,
    recognizer: &mut dyn SpeechRecognizer,
    options: &DecodeOptions,
    request: TrackRequest<'_>,
    cancel: &AtomicBool,
    progress: &mut dyn FnMut(TranscriptionProgress),
) -> Result<TranscriptionOutcome, TranscriptionError> {
    let TrackRequest {
        session,
        track_id,
        decoded_companion,
    } = request;
    let input = store.transcription_input(session, track_id)?;
    let reader = match decoded_companion {
        Some(decoded) if input.compressed => {
            store.open_decoded_transcription_input(&input, decoded)?
        }
        _ => store.open_transcription_input(&input)?,
    };
    let windows = plan_windows(&input);
    let required = windows
        .iter()
        .map(|window| window.chunk.end_nanoseconds - window.chunk.start_nanoseconds)
        .sum::<i64>();
    let recognizer_identity = recognizer.identity().clone();
    let identity = TranscriptionRunIdentity {
        session_id: session.clone(),
        track_id: track_id.to_owned(),
        input_digest: input.input_digest.clone(),
        engine: recognizer_identity.engine,
        engine_version: recognizer_identity.engine_version,
        model_id: recognizer_identity.model_id,
        model_sha256: recognizer_identity.model_sha256,
        options_digest: options.digest(),
        reconciliation_version: RECONCILIATION_VERSION.to_owned(),
    };
    let plan: Vec<_> = windows.iter().map(|window| window.chunk).collect();
    let handle = store.begin_transcription_run(&identity, &plan)?;
    let run_id = handle.run_id.clone();
    let reused_chunks = handle
        .chunks
        .iter()
        .filter(|chunk| chunk.reused_from_run.is_some())
        .count() as u32;

    let mut completed = 0_i64;
    let mut transcribed_chunks = 0_u32;
    for (chunk, window) in handle.chunks.iter().zip(&windows) {
        let duration = window.chunk.end_nanoseconds - window.chunk.start_nanoseconds;
        if chunk.state == TranscriptChunkState::Complete {
            let valid = chunk
                .hypothesis_json
                .as_deref()
                .and_then(|json| serde_json::from_str::<Hypothesis>(json).ok())
                .is_some();
            if !valid {
                return Err(end_run(
                    store,
                    &run_id,
                    Some(chunk.sequence),
                    TranscriptionFailure::InvalidResult,
                ));
            }
            completed += duration;
            continue;
        }
        if cancel.load(Ordering::Acquire) {
            return Err(end_run(
                store,
                &run_id,
                None,
                TranscriptionFailure::Cancelled,
            ));
        }
        progress(TranscriptionProgress {
            stage: TranscriptionStage::Decoding,
            completed_nanoseconds: completed,
            required_nanoseconds: required,
        });
        let span = &input.spans[window.span_index];
        let decimator = Decimator::new(span.frames);
        let (first, last) = decimator.source_window(window.start_sample, window.end_sample);
        let audio = match reader
            .read_frames(window.span_index, first, last)
            .map_err(|_| ())
            .and_then(|frames| {
                decimator
                    .convert(
                        &frames,
                        input.channels,
                        window.start_sample,
                        window.end_sample,
                    )
                    .map_err(|_| ())
            }) {
            Ok(audio) => audio,
            Err(()) => {
                return Err(end_run(
                    store,
                    &run_id,
                    Some(chunk.sequence),
                    TranscriptionFailure::InputUnavailable,
                ));
            }
        };
        store.mark_transcript_chunk_running(&run_id, chunk.sequence)?;
        progress(TranscriptionProgress {
            stage: TranscriptionStage::Transcribing,
            completed_nanoseconds: completed,
            required_nanoseconds: required,
        });
        let hypothesis = match recognizer.transcribe(&audio, options, cancel) {
            Ok(hypothesis) => hypothesis,
            Err(error) => {
                let failure = match error {
                    RecognizerError::Cancelled => TranscriptionFailure::Cancelled,
                    RecognizerError::ResourceExhausted => TranscriptionFailure::ResourceExhausted,
                    RecognizerError::Engine(_) => TranscriptionFailure::EngineError,
                };
                return Err(end_run(store, &run_id, Some(chunk.sequence), failure));
            }
        };
        let json = serde_json::to_string(&hypothesis).map_err(StoreError::Json)?;
        store.complete_transcript_chunk(&run_id, chunk.sequence, &hypothesis.language, &json)?;
        transcribed_chunks += 1;
        completed += duration;
    }

    progress(TranscriptionProgress {
        stage: TranscriptionStage::Reconciling,
        completed_nanoseconds: completed,
        required_nanoseconds: required,
    });
    // Finish-or-fail: once every chunk is durable, never leave the run running.
    let (revision_id, segment_count, rejections) = match finalize_transcription_run(store, &run_id)
    {
        Ok(outcome) => outcome,
        Err(error) => return Err(error),
    };
    Ok(TranscriptionOutcome {
        run_id,
        revision_id,
        resumed: handle.resumed,
        reused_chunks,
        transcribed_chunks,
        segment_count,
        rejections,
    })
}

/// Reconcile stored complete-chunk hypotheses and commit a revision.
/// On failure the run is failed closed (`invalid_result`) so it never stays
/// forever-running. No ASR; launch recovery uses this for Class A orphans.
pub fn finalize_transcription_run(
    store: &mut SessionStore,
    run_id: &str,
) -> Result<(String, u32, Rejections), TranscriptionError> {
    let result = finalize_transcription_run_inner(store, run_id);
    match result {
        Ok(outcome) => Ok(outcome),
        Err(TranscriptionError::RunEnded { .. }) => Err(TranscriptionError::RunEnded {
            run_id: run_id.to_owned(),
            failure: TranscriptionFailure::InvalidResult,
        }),
        Err(error) => {
            match store.fail_transcription_run(run_id, None, TranscriptionFailure::InvalidResult) {
                Ok(()) => Err(TranscriptionError::RunEnded {
                    run_id: run_id.to_owned(),
                    failure: TranscriptionFailure::InvalidResult,
                }),
                Err(StoreError::InvalidState(_)) => Err(error),
                Err(store_error) => Err(TranscriptionError::Store(store_error)),
            }
        }
    }
}

fn finalize_transcription_run_inner(
    store: &mut SessionStore,
    run_id: &str,
) -> Result<(String, u32, Rejections), TranscriptionError> {
    let chunks = store.transcript_chunks_for_run(run_id)?;
    if chunks.is_empty()
        || chunks
            .iter()
            .any(|chunk| chunk.state != TranscriptChunkState::Complete)
    {
        return Err(TranscriptionError::Store(StoreError::InvalidState(
            "transcription run has incomplete chunks",
        )));
    }
    let mut parsed = Vec::with_capacity(chunks.len());
    for chunk in &chunks {
        let Some(hypothesis) = chunk
            .hypothesis_json
            .as_deref()
            .and_then(|json| serde_json::from_str::<Hypothesis>(json).ok())
        else {
            return Err(end_run(
                store,
                run_id,
                Some(chunk.sequence),
                TranscriptionFailure::InvalidResult,
            ));
        };
        parsed.push(hypothesis);
    }
    let chunk_views: Vec<ChunkHypothesis<'_>> = chunks
        .iter()
        .zip(&parsed)
        .map(|(chunk, hypothesis)| ChunkHypothesis {
            chunk_id: &chunk.identity,
            span_index: chunk.span_index,
            start_nanoseconds: chunk.start_nanoseconds,
            end_nanoseconds: chunk.end_nanoseconds,
            hypothesis,
        })
        .collect();
    let (reconciled, rejections) = reconcile(&chunk_views);
    let segments: Vec<RevisionSegmentInput> = reconciled
        .into_iter()
        .map(|segment| RevisionSegmentInput {
            start_nanoseconds: segment.start_nanoseconds,
            end_nanoseconds: segment.end_nanoseconds,
            text: segment.text,
            mean_probability: segment.mean_probability,
            no_speech_probability: segment.no_speech_probability,
            chunk_identity: segment.chunk_id,
        })
        .collect();
    let rejections_json = serde_json::json!({
        "empty": rejections.empty,
        "non_speech": rejections.non_speech,
        "inverted": rejections.inverted,
        "outside_coverage": rejections.outside_coverage,
        "overlap_duplicates": rejections.overlap_duplicates,
    })
    .to_string();
    let (session_id, track_id) = store.transcription_run_binding(run_id)?;
    let discontinuities_json = match store.transcription_input(&session_id, &track_id) {
        Ok(input) => discontinuities(&input).to_string(),
        Err(_) => "[]".to_owned(),
    };
    let revision_id = store.commit_transcript_revision(
        run_id,
        &segments,
        &rejections_json,
        &discontinuities_json,
    )?;
    Ok((revision_id, segments.len() as u32, rejections))
}

fn end_run(
    store: &mut SessionStore,
    run_id: &str,
    sequence: Option<u32>,
    failure: TranscriptionFailure,
) -> TranscriptionError {
    match store.fail_transcription_run(run_id, sequence, failure) {
        Ok(()) => TranscriptionError::RunEnded {
            run_id: run_id.to_owned(),
            failure,
        },
        Err(error) => TranscriptionError::Store(error),
    }
}

fn span_duration(frames: u64) -> i64 {
    (i128::from(frames) * i128::from(NANOSECONDS_PER_SECOND) / i128::from(SOURCE_SAMPLE_RATE_HZ))
        as i64
}

pub(crate) fn plan_windows(input: &TranscriptionInput) -> Vec<PlannedWindow> {
    let nanoseconds_per_sample = NANOSECONDS_PER_SECOND / i64::from(MODEL_SAMPLE_RATE_HZ);
    let mut windows = Vec::new();
    for (span_index, span) in input.spans.iter().enumerate() {
        let span_end = span_duration(span.frames);
        for range in plan_chunks(Decimator::new(span.frames).output_len()) {
            let start = (range.start as i64 * nanoseconds_per_sample).min(span_end);
            let end = (range.end as i64 * nanoseconds_per_sample).min(span_end);
            if end <= start {
                continue;
            }
            windows.push(PlannedWindow {
                span_index,
                start_sample: range.start,
                end_sample: range.end,
                chunk: PlannedTranscriptChunk {
                    span_index: span_index as u32,
                    start_nanoseconds: span.start_nanoseconds + start,
                    end_nanoseconds: span.start_nanoseconds + end,
                },
            });
        }
    }
    windows
}

fn discontinuities(input: &TranscriptionInput) -> serde_json::Value {
    let gaps: Vec<serde_json::Value> = input
        .spans
        .windows(2)
        .map(|pair| {
            serde_json::json!({
                "kind": "media_gap",
                "start_ns": pair[0].start_nanoseconds + span_duration(pair[0].frames),
                "end_ns": pair[1].start_nanoseconds,
            })
        })
        .collect();
    serde_json::Value::Array(gaps)
}

#[cfg(test)]
#[path = "transcription_tests.rs"]
pub(crate) mod tests;
