//! Native speech-recognition capability boundary for Open Scribe.
//!
//! This crate owns the engine-independent half of final transcription
//! (ADR 0009): the `SpeechRecognizer` capability, 48 kHz to 16 kHz mono
//! input conversion, chunk planning, and overlap reconciliation. The ADR 0008
//! whisper.cpp engine is not integrated, so no production recognizer exists
//! and transcription remains Unavailable.

mod audio;
mod chunking;
mod recognizer;
mod reconcile;

pub use audio::{DECIMATION_FACTOR, Decimator, MODEL_SAMPLE_RATE_HZ, SOURCE_SAMPLE_RATE_HZ};
pub use chunking::{
    CHUNK_OVERLAP_SECONDS, CHUNK_PLANNER_VERSION, CHUNK_WINDOW_SECONDS, ChunkRange, plan_chunks,
};
pub use recognizer::{
    DecodeOptions, Hypothesis, HypothesisSegment, Language, RecognizerError, RecognizerIdentity,
    SpeechRecognizer,
};
pub use reconcile::{
    ChunkHypothesis, RECONCILIATION_VERSION, ReconciledSegment, Rejections, reconcile,
};
