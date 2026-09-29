use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::fmt;
use std::sync::atomic::AtomicBool;

/// Exact engine and model identity used by one recognizer instance.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct RecognizerIdentity {
    pub engine: String,
    pub engine_version: String,
    pub model_id: String,
    pub model_sha256: String,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize)]
pub enum Language {
    English,
    Detect,
}

impl Language {
    pub const fn code(self) -> &'static str {
        match self {
            Self::English => "en",
            Self::Detect => "auto",
        }
    }
}

/// Decoding choices that change output. Their digest is part of every chunk
/// identity; changing any of them creates a new run.
#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
pub struct DecodeOptions {
    pub language: Language,
    pub planner: &'static str,
    pub greedy: bool,
    pub no_context: bool,
}

impl DecodeOptions {
    pub fn final_pass(language: Language) -> Self {
        Self {
            language,
            planner: crate::chunking::CHUNK_PLANNER_VERSION,
            greedy: true,
            no_context: true,
        }
    }

    pub fn digest(&self) -> String {
        let canonical = serde_json::to_vec(self).expect("decode options serialize");
        let mut hasher = Sha256::new();
        hasher.update(b"open-scribe.decode-options/v1\n");
        hasher.update(canonical);
        hasher
            .finalize()
            .iter()
            .map(|byte| format!("{byte:02x}"))
            .collect()
    }
}

/// One raw recognizer segment. Times are milliseconds relative to the start
/// of the audio passed to `transcribe`.
#[derive(Clone, Debug, Deserialize, PartialEq, Serialize)]
pub struct HypothesisSegment {
    pub start_ms: u32,
    pub end_ms: u32,
    pub text: String,
    pub mean_probability: Option<f32>,
    pub no_speech_probability: Option<f32>,
}

/// Verbatim recognizer output for one chunk, persisted before reconciliation.
#[derive(Clone, Debug, Deserialize, PartialEq, Serialize)]
pub struct Hypothesis {
    pub language: String,
    pub segments: Vec<HypothesisSegment>,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum RecognizerError {
    Cancelled,
    ResourceExhausted,
    Engine(&'static str),
}

impl RecognizerError {
    pub const fn class(self) -> &'static str {
        match self {
            Self::Cancelled => "cancelled",
            Self::ResourceExhausted => "resource_exhausted",
            Self::Engine(_) => "engine_error",
        }
    }
}

impl fmt::Display for RecognizerError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(self.class())
    }
}

impl std::error::Error for RecognizerError {}

/// The Rust speech-recognition capability. Implementations run in process,
/// offline, below capture priority, and must honor `cancel` promptly.
pub trait SpeechRecognizer {
    fn identity(&self) -> &RecognizerIdentity;

    /// `audio` is 16 kHz mono f32 in [-1, 1], at most one model window long.
    fn transcribe(
        &mut self,
        audio: &[f32],
        options: &DecodeOptions,
        cancel: &AtomicBool,
    ) -> Result<Hypothesis, RecognizerError>;
}
