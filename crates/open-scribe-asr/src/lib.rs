//! Native speech-recognition capability boundary for Open Scribe.
//!
//! This crate owns final transcription's engine side (ADR 0008, ADR 0009):
//! the `SpeechRecognizer` capability, 48 kHz to 16 kHz mono input
//! conversion, chunk planning, overlap reconciliation, and the in-process
//! whisper.cpp recognizer. The recognizer loads only a model the caller has
//! verified against the checked manifest and makes no network request.

mod audio;
mod chunking;
mod recognizer;
mod reconcile;
mod whisper;

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
pub use whisper::{
    WHISPER_ENGINE, WHISPER_ENGINE_COMPATIBILITY, WHISPER_ENGINE_VERSION, WhisperLoadError,
    WhisperRecognizer, engine_version,
};

#[cfg(test)]
mod whisper_tests;
