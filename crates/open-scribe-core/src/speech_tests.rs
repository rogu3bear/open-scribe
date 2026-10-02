use crate::speech::{
    SpeechError, SpeechModelError, SpeechModels, decode_language, transcribe_session,
};
use crate::transcription::tests::{BurstRecognizer, imported};
use crate::{TranscriptLibrary, TranscriptionError};
use open_scribe_asr::{
    DecodeOptions, Language, WHISPER_ENGINE, WHISPER_ENGINE_COMPATIBILITY, WHISPER_ENGINE_VERSION,
};
use open_scribe_models::{Catalog, VerifyError};
use open_scribe_store::{ImportMediaRequest, SessionStore, StoreError};
use open_scribe_types::SessionId;
use std::path::PathBuf;
use std::sync::atomic::AtomicBool;

#[test]
fn every_manifest_speech_model_names_this_exact_engine() {
    let catalog = Catalog::canonical().unwrap();
    let asr: Vec<_> = catalog
        .records()
        .iter()
        .filter(|record| record.purpose == "asr")
        .collect();
    assert_eq!(asr.len(), 2);
    for record in asr {
        assert_eq!(record.engine, WHISPER_ENGINE);
        assert_eq!(record.compatibility, WHISPER_ENGINE_COMPATIBILITY);
    }
    assert_eq!(WHISPER_ENGINE_VERSION, open_scribe_asr::engine_version());
}

#[test]
fn a_fresh_library_lists_the_catalog_uninstalled_and_refuses_wrong_files() {
    let root = tempfile::tempdir().unwrap();
    let models = SpeechModels::open(root.path()).unwrap();
    let statuses = models.statuses();
    assert_eq!(
        statuses
            .iter()
            .map(|status| status.model_id.as_str())
            .collect::<Vec<_>>(),
        ["whisper-small.en-q5_1", "whisper-small-q5_1"]
    );
    assert!(statuses.iter().all(|status| {
        !status.installed
            && status
                .download_origin
                .starts_with("https://huggingface.co/ggerganov/whisper.cpp/resolve/")
            && status.sha256.len() == 64
    }));

    let short = root.path().join("ggml-small.en-q5_1.bin");
    std::fs::write(&short, b"lmgg too short").unwrap();
    let rejected = models
        .install_from_file("whisper-small.en-q5_1", &short)
        .unwrap_err();
    assert!(matches!(
        rejected,
        SpeechModelError::Verify(VerifyError::Truncated { .. })
    ));
    assert_eq!(rejected.class(), "truncated");
    assert!(
        !root
            .path()
            .join("Models/.staging/whisper-small.en-q5_1-1.0.0.part")
            .exists(),
        "a rejected file leaves no staged bytes"
    );
    assert_eq!(std::fs::read(&short).unwrap(), b"lmgg too short");
    assert!(matches!(
        models.install_from_file("not-a-model", &short),
        Err(SpeechModelError::UnknownModel)
    ));
    assert!(matches!(
        models.load("whisper-small.en-q5_1"),
        Err(SpeechModelError::NotInstalled)
    ));
    assert!(matches!(
        models.transcribe(
            "whisper-small.en-q5_1",
            &SessionId("missing".into()),
            None,
            &AtomicBool::new(false),
            &mut |_, _, _| {}
        ),
        Err(SpeechError::Model(SpeechModelError::NotInstalled))
    ));
    assert!(models.statuses().iter().all(|status| !status.installed));
}

#[test]
fn english_only_models_decode_english_and_multilingual_models_detect() {
    assert_eq!(decode_language(&["en".to_owned()]), Language::English);
    assert_eq!(
        decode_language(&["en".to_owned(), "de".to_owned()]),
        Language::Detect
    );
}

#[test]
fn a_session_transcribes_every_track_and_one_without_audio_is_refused() {
    let mut fixture = imported(30);
    let mut recognizer = BurstRecognizer::new("model");
    let options = DecodeOptions::final_pass(Language::English);
    let mut seen = Vec::new();
    let outcomes = transcribe_session(
        &mut fixture.store,
        &mut recognizer,
        &options,
        &fixture.session,
        None,
        &AtomicBool::new(false),
        &mut |index, count, _| seen.push((index, count)),
    )
    .unwrap();
    assert_eq!(outcomes.len(), 1);
    assert!(outcomes[0].segment_count > 0);
    assert!(!seen.is_empty() && seen.iter().all(|&progress| progress == (0, 1)));

    let refused = transcribe_session(
        &mut fixture.store,
        &mut recognizer,
        &options,
        &SessionId("no-such-session".into()),
        None,
        &AtomicBool::new(false),
        &mut |_, _, _| {},
    );
    assert!(matches!(
        refused,
        Err(TranscriptionError::Store(StoreError::InvalidState(_)))
    ));
}

/// End to end on the real pinned model: install from a chosen file (full
/// SHA-256 and self-test), import spoken audio, transcribe, and read the
/// transcript back through the review library. Set
/// `OPEN_SCRIBE_WHISPER_MODEL` to `ggml-small.en-q5_1.bin` and
/// `OPEN_SCRIBE_WHISPER_SPEECH_CAF` to the output of
/// `say -v Samantha -o speech48.caf --file-format=caff --data-format=LEI16@48000 "Open Scribe keeps the recording safe before it writes a transcript."`.
#[test]
fn the_pinned_model_installs_and_transcribes_an_imported_conversation() {
    let (Some(model), Some(speech)) = (
        std::env::var_os("OPEN_SCRIBE_WHISPER_MODEL").map(PathBuf::from),
        std::env::var_os("OPEN_SCRIBE_WHISPER_SPEECH_CAF").map(PathBuf::from),
    ) else {
        eprintln!(
            "SPEECH_END_TO_END_SKIPPED: set OPEN_SCRIBE_WHISPER_MODEL and OPEN_SCRIBE_WHISPER_SPEECH_CAF"
        );
        return;
    };
    let temp = tempfile::tempdir().unwrap();
    let root = temp.path().join("Open Scribe");
    let session = SessionStore::open(&root)
        .unwrap()
        .import_recoverable_caf(ImportMediaRequest {
            title: "Spoken".into(),
            source_path: speech,
        })
        .unwrap()
        .session_id;
    let models = SpeechModels::open(&root).unwrap();
    let installed = models
        .install_from_file("whisper-small.en-q5_1", &model)
        .unwrap();
    assert_eq!(
        installed.relative_path,
        "Models/whisper-small.en-q5_1/1.0.0/ggml-small.en-q5_1.bin"
    );
    assert!(models.statuses()[0].installed);

    let outcomes = models
        .transcribe(
            "whisper-small.en-q5_1",
            &session,
            None,
            &AtomicBool::new(false),
            &mut |_, _, _| {},
        )
        .unwrap();
    assert_eq!(outcomes.len(), 1);
    let library = TranscriptLibrary::open(&root).unwrap();
    let text = library
        .document(&session)
        .unwrap()
        .iter()
        .map(|segment| segment.effective_text.clone())
        .collect::<Vec<_>>()
        .join(" ")
        .to_lowercase();
    assert!(text.contains("recording safe"), "{text:?}");
    let hits = library.search("transcript", None, 10).unwrap();
    assert_eq!(hits.len(), 1);
    eprintln!(
        "SPEECH_END_TO_END_GREEN segments={} text={text:?}",
        outcomes[0].segment_count
    );
}
