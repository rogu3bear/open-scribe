//! The ADR 0008 engine: whisper.cpp 1.8.3, compiled in process from the
//! source pinned by `whisper-rs-sys` 0.15.0 (Accelerate and Metal, static).
//! This module is the crate's only unsafe code. It admits three C calls:
//! load a verified model file, run one full decode of at most one model
//! window, and read the resulting segments back.

use crate::MODEL_SAMPLE_RATE_HZ;
use crate::recognizer::{
    DecodeOptions, Hypothesis, HypothesisSegment, RecognizerError, RecognizerIdentity,
    SpeechRecognizer,
};
use std::ffi::{CStr, CString, c_char, c_void};
use std::fmt;
use std::os::unix::ffi::OsStrExt;
use std::path::Path;
use std::ptr::NonNull;
use std::sync::Once;
use std::sync::atomic::{AtomicBool, Ordering};
use whisper_rs_sys as sys;

pub const WHISPER_ENGINE: &str = "whisper.cpp";
/// The engine version this crate pins; a different linked version refuses to
/// load rather than silently changing run identity.
pub const WHISPER_ENGINE_VERSION: &str = "1.8.3";
/// Must equal the model manifest's `compatibility` for every loadable model.
pub const WHISPER_ENGINE_COMPATIBILITY: &str =
    "whisper.cpp 1.8.3 (2eeeba56e9edd762b4b38467bab96c2517163158) GGML loader";
/// Whisper's context: one call never receives more than 30 seconds.
const MAX_WINDOW_SAMPLES: usize = 30 * MODEL_SAMPLE_RATE_HZ as usize;

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum WhisperLoadError {
    UnsupportedPath,
    EngineVersion(String),
    ModelRejected,
}

impl WhisperLoadError {
    pub const fn class(&self) -> &'static str {
        match self {
            Self::UnsupportedPath => "unsupported_path",
            Self::EngineVersion(_) => "engine_version",
            Self::ModelRejected => "model_rejected",
        }
    }
}

impl fmt::Display for WhisperLoadError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "speech engine could not load: {}", self.class())
    }
}

impl std::error::Error for WhisperLoadError {}

pub struct WhisperRecognizer {
    context: NonNull<sys::whisper_context>,
    identity: RecognizerIdentity,
    threads: i32,
}

// SAFETY: a whisper context has no thread affinity. `transcribe` takes
// `&mut self`, so one thread uses the context at a time; it is never shared.
unsafe impl Send for WhisperRecognizer {}

impl WhisperRecognizer {
    /// Loads a model the caller has already verified against the checked
    /// manifest. `model_sha256` becomes part of every run identity.
    pub fn load(
        model_path: &Path,
        model_id: &str,
        model_sha256: &str,
    ) -> Result<Self, WhisperLoadError> {
        silence_engine_logs();
        let linked = engine_version();
        if linked != WHISPER_ENGINE_VERSION {
            return Err(WhisperLoadError::EngineVersion(linked));
        }
        let path = CString::new(model_path.as_os_str().as_bytes())
            .map_err(|_| WhisperLoadError::UnsupportedPath)?;
        // SAFETY: plain value constructors with no preconditions.
        let mut params = unsafe { sys::whisper_context_default_params() };
        params.use_gpu = true;
        params.flash_attn = false;
        // SAFETY: `path` is NUL-terminated and outlives the call; whisper.cpp
        // copies what it needs and returns null on any rejection.
        let context = unsafe { sys::whisper_init_from_file_with_params(path.as_ptr(), params) };
        let context = NonNull::new(context).ok_or(WhisperLoadError::ModelRejected)?;
        let threads = std::thread::available_parallelism()
            .map(|count| (count.get() / 2).clamp(1, 4))
            .unwrap_or(1) as i32;
        Ok(Self {
            context,
            identity: RecognizerIdentity {
                engine: WHISPER_ENGINE.to_owned(),
                engine_version: linked,
                model_id: model_id.to_owned(),
                model_sha256: model_sha256.to_owned(),
            },
            threads,
        })
    }

    fn segments(&self, audio_len: usize) -> Result<Vec<HypothesisSegment>, RecognizerError> {
        let context = self.context.as_ptr();
        let duration_ms = (audio_len as u64 * 1_000 / u64::from(MODEL_SAMPLE_RATE_HZ)) as u32;
        // SAFETY: `context` is live and holds the result of the last decode.
        let count = unsafe { sys::whisper_full_n_segments(context) };
        let end_of_text = unsafe { sys::whisper_token_eot(context) };
        let mut segments = Vec::with_capacity(count.max(0) as usize);
        for index in 0..count {
            // SAFETY: `index` is within the segment count just read; the text
            // pointer stays valid until the next decode on this context.
            let (t0, t1, text, no_speech) = unsafe {
                (
                    sys::whisper_full_get_segment_t0(context, index),
                    sys::whisper_full_get_segment_t1(context, index),
                    sys::whisper_full_get_segment_text(context, index),
                    sys::whisper_full_get_segment_no_speech_prob(context, index),
                )
            };
            if text.is_null() {
                return Err(RecognizerError::Engine("segment_text_missing"));
            }
            // SAFETY: non-null, NUL-terminated, owned by the context.
            let text = unsafe { CStr::from_ptr(text) }
                .to_string_lossy()
                .into_owned();
            let tokens = unsafe { sys::whisper_full_n_tokens(context, index) };
            let mut probability_sum = 0.0_f32;
            let mut text_tokens = 0_u32;
            for token in 0..tokens {
                // SAFETY: `token` is within this segment's token count.
                let data = unsafe { sys::whisper_full_get_token_data(context, index, token) };
                if data.id < end_of_text {
                    probability_sum += data.p;
                    text_tokens += 1;
                }
            }
            // whisper.cpp reports times in centiseconds from the window start.
            let to_ms = |centiseconds: i64| {
                (centiseconds.max(0).saturating_mul(10)).min(i64::from(duration_ms)) as u32
            };
            segments.push(HypothesisSegment {
                start_ms: to_ms(t0),
                end_ms: to_ms(t1),
                text,
                mean_probability: (text_tokens > 0).then(|| probability_sum / text_tokens as f32),
                no_speech_probability: Some(no_speech),
            });
        }
        Ok(segments)
    }
}

impl Drop for WhisperRecognizer {
    fn drop(&mut self) {
        // SAFETY: the context was created by whisper_init and is freed once.
        unsafe { sys::whisper_free(self.context.as_ptr()) };
    }
}

impl SpeechRecognizer for WhisperRecognizer {
    fn identity(&self) -> &RecognizerIdentity {
        &self.identity
    }

    fn transcribe(
        &mut self,
        audio: &[f32],
        options: &DecodeOptions,
        cancel: &AtomicBool,
    ) -> Result<Hypothesis, RecognizerError> {
        if cancel.load(Ordering::Relaxed) {
            return Err(RecognizerError::Cancelled);
        }
        if audio.is_empty() || audio.len() > MAX_WINDOW_SAMPLES {
            return Err(RecognizerError::Engine("window_out_of_range"));
        }
        let language = CString::new(options.language.code()).expect("language code has no NUL");
        let strategy = if options.greedy {
            sys::whisper_sampling_strategy_WHISPER_SAMPLING_GREEDY
        } else {
            sys::whisper_sampling_strategy_WHISPER_SAMPLING_BEAM_SEARCH
        };
        // SAFETY: plain value constructor.
        let mut params = unsafe { sys::whisper_full_default_params(strategy) };
        params.n_threads = self.threads;
        params.language = language.as_ptr();
        params.detect_language = false;
        params.no_context = options.no_context;
        params.print_special = false;
        params.print_progress = false;
        params.print_realtime = false;
        params.print_timestamps = false;
        params.abort_callback = Some(abort_requested);
        params.abort_callback_user_data = std::ptr::from_ref(cancel).cast_mut().cast();
        // SAFETY: the context is live and exclusively borrowed; `audio` is a
        // valid slice for its length; `language` and `cancel` outlive the call.
        let status = unsafe {
            sys::whisper_full(
                self.context.as_ptr(),
                params,
                audio.as_ptr(),
                audio.len() as i32,
            )
        };
        if cancel.load(Ordering::Relaxed) {
            return Err(RecognizerError::Cancelled);
        }
        if status != 0 {
            return Err(RecognizerError::Engine("decode_failed"));
        }
        // SAFETY: the context holds the decode just completed.
        let language = unsafe {
            let id = sys::whisper_full_lang_id(self.context.as_ptr());
            let code = sys::whisper_lang_str(id);
            if code.is_null() {
                options.language.code().to_owned()
            } else {
                CStr::from_ptr(code).to_string_lossy().into_owned()
            }
        };
        Ok(Hypothesis {
            language,
            segments: self.segments(audio.len())?,
        })
    }
}

/// The linked engine's own version string.
pub fn engine_version() -> String {
    // SAFETY: returns a static NUL-terminated string.
    unsafe { CStr::from_ptr(sys::whisper_version()) }
        .to_string_lossy()
        .into_owned()
}

unsafe extern "C" fn abort_requested(user_data: *mut c_void) -> bool {
    // SAFETY: `transcribe` passes a pointer to an `AtomicBool` that outlives
    // the decode that invokes this callback.
    unsafe { &*user_data.cast::<AtomicBool>() }.load(Ordering::Relaxed)
}

unsafe extern "C" fn discard_log(
    _level: sys::ggml_log_level,
    _text: *const c_char,
    _: *mut c_void,
) {
}

/// Engine logs may carry model paths or decoded text; the app keeps
/// identifier-only logs, so the engine's are discarded.
fn silence_engine_logs() {
    static ONCE: Once = Once::new();
    // SAFETY: installs a static no-op callback before any engine call.
    ONCE.call_once(|| unsafe { sys::whisper_log_set(Some(discard_log), std::ptr::null_mut()) });
}
