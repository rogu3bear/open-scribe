use crate::{
    DecodeOptions, Language, MODEL_SAMPLE_RATE_HZ, RecognizerError, SpeechRecognizer,
    WHISPER_ENGINE_COMPATIBILITY, WHISPER_ENGINE_VERSION, WhisperLoadError, WhisperRecognizer,
    engine_version,
};
use std::path::{Path, PathBuf};
use std::sync::atomic::AtomicBool;

#[test]
fn the_linked_engine_is_the_pinned_release() {
    assert_eq!(engine_version(), WHISPER_ENGINE_VERSION);
    assert!(WHISPER_ENGINE_COMPATIBILITY.starts_with("whisper.cpp 1.8.3 ("));
}

#[test]
fn a_file_that_is_not_a_model_is_refused_without_loading() {
    let path = std::env::temp_dir().join(format!("open-scribe-not-a-model-{}", std::process::id()));
    std::fs::write(&path, b"not a ggml model").unwrap();
    let result = WhisperRecognizer::load(&path, "fixture", "0");
    std::fs::remove_file(&path).unwrap();
    assert_eq!(result.err(), Some(WhisperLoadError::ModelRejected));
}

/// Reads a 16 kHz mono float32 WAV's `data` chunk.
fn wav_f32(path: &Path) -> Vec<f32> {
    let bytes = std::fs::read(path).unwrap();
    let mut offset = 12;
    while offset + 8 <= bytes.len() {
        let length = u32::from_le_bytes(bytes[offset + 4..offset + 8].try_into().unwrap()) as usize;
        if &bytes[offset..offset + 4] == b"data" {
            return bytes[offset + 8..offset + 8 + length]
                .chunks_exact(4)
                .map(|sample| f32::from_le_bytes(sample.try_into().unwrap()))
                .collect();
        }
        offset += 8 + length + (length & 1);
    }
    panic!("WAV has no data chunk");
}

/// Known-answer run against the real pinned model. Set
/// `OPEN_SCRIBE_WHISPER_MODEL` to a verified `ggml-small.en-q5_1.bin` and
/// `OPEN_SCRIBE_WHISPER_SPEECH_WAV` to the output of
/// `say -v Samantha -o speech.wav --file-format=WAVE --data-format=LEF32@16000 "Open Scribe keeps the recording safe before it writes a transcript."`.
/// Without both, the test reports a skip and passes.
#[test]
fn the_pinned_model_transcribes_known_speech_and_honors_cancellation() {
    let (Some(model), Some(speech)) = (
        std::env::var_os("OPEN_SCRIBE_WHISPER_MODEL").map(PathBuf::from),
        std::env::var_os("OPEN_SCRIBE_WHISPER_SPEECH_WAV").map(PathBuf::from),
    ) else {
        eprintln!(
            "WHISPER_KNOWN_ANSWER_SKIPPED: set OPEN_SCRIBE_WHISPER_MODEL and OPEN_SCRIBE_WHISPER_SPEECH_WAV"
        );
        return;
    };
    let mut recognizer =
        WhisperRecognizer::load(&model, "whisper-small.en-q5_1", "fixture").unwrap();
    assert_eq!(recognizer.identity().engine_version, WHISPER_ENGINE_VERSION);
    let options = DecodeOptions::final_pass(Language::English);
    let audio = wav_f32(&speech);
    let hypothesis = recognizer
        .transcribe(&audio, &options, &AtomicBool::new(false))
        .unwrap();
    assert_eq!(hypothesis.language, "en");
    let text = hypothesis
        .segments
        .iter()
        .map(|segment| segment.text.as_str())
        .collect::<String>()
        .to_lowercase();
    assert!(text.contains("recording safe"), "{text:?}");
    let duration_ms = (audio.len() as u64 * 1_000 / u64::from(MODEL_SAMPLE_RATE_HZ)) as u32;
    assert!(hypothesis.segments.iter().all(|segment| {
        segment.start_ms <= segment.end_ms
            && segment.end_ms <= duration_ms
            && segment
                .mean_probability
                .is_some_and(|p| (0.0..=1.0).contains(&p))
    }));

    let too_long = vec![0.0_f32; 31 * MODEL_SAMPLE_RATE_HZ as usize];
    assert_eq!(
        recognizer.transcribe(&too_long, &options, &AtomicBool::new(false)),
        Err(RecognizerError::Engine("window_out_of_range"))
    );
    assert_eq!(
        recognizer.transcribe(&audio, &options, &AtomicBool::new(true)),
        Err(RecognizerError::Cancelled)
    );
    eprintln!("WHISPER_KNOWN_ANSWER_GREEN text={text:?}");
}
