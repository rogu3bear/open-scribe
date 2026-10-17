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

/// Read-only reuse of explicitly supplied proof inputs. Unlike the installation
/// test below, this neither stages nor installs weights in any model library.
/// This is the Rust import/review/export consumer, not native UI or audible proof.
#[test]
fn verified_file_import_review_export_preserves_original_evidence() {
    use crate::{ResolutionState, TranscriptAvailability, TranscriptExportFormat};
    use open_scribe_asr::WhisperRecognizer;
    use sha2::{Digest, Sha256};
    use std::fs;

    let (Some(model), Some(speech)) = (
        std::env::var_os("OPEN_SCRIBE_WHISPER_MODEL").map(PathBuf::from),
        std::env::var_os("OPEN_SCRIBE_WHISPER_SPEECH_CAF").map(PathBuf::from),
    ) else {
        eprintln!("IMPORTED_REVIEW_WORKFLOW_SKIPPED: supply the documented model and speech CAF");
        return;
    };
    let digest = |path: &std::path::Path| format!("{:x}", Sha256::digest(fs::read(path).unwrap()));
    let input_digest = digest(&speech);
    let catalog = Catalog::canonical().unwrap();
    let record = catalog
        .records()
        .iter()
        .find(|r| r.id == "whisper-small.en-q5_1")
        .unwrap();
    let verified = open_scribe_models::verify_staged(
        record,
        WHISPER_ENGINE,
        WHISPER_ENGINE_COMPATIBILITY,
        &model,
    )
    .unwrap();
    let mut recognizer = WhisperRecognizer::load(&model, &record.id, &verified.sha256).unwrap();
    let temp = tempfile::tempdir().unwrap();
    let root = temp.path().join("Library");
    let mut store = SessionStore::open(&root).unwrap();
    let session = store
        .import_recoverable_caf(ImportMediaRequest {
            title: "Supplied synthetic speech".into(),
            source_path: speech.clone(),
        })
        .unwrap()
        .session_id;
    // Media recovery publishes before recognition or review begins.
    let recovery = store.recover_library().unwrap();
    assert!(recovery.pending_transcript_finalizations.is_empty());
    let inventory = store.session_inventory(&session).unwrap();
    assert_eq!(inventory.media.len(), 1);
    let media = store
        .open_verified_media(&session, &inventory.media[0])
        .unwrap();
    assert_eq!(media.digest_sha256, input_digest);
    let tracks = store.transcription_tracks(&session).unwrap();
    assert_eq!(tracks.len(), 1);
    let result = crate::transcribe_track(
        &mut store,
        &mut recognizer,
        &DecodeOptions::final_pass(Language::English),
        &session,
        &tracks[0],
        &AtomicBool::new(false),
        &mut |_| {},
    )
    .unwrap();
    let original = store.transcript_document(&session).unwrap();
    let first = original
        .first()
        .expect("real recognizer produced timed text");
    assert!(
        original
            .iter()
            .map(|s| s.verbatim_text.as_str())
            .collect::<Vec<_>>()
            .join(" ")
            .to_lowercase()
            .contains("recording safe")
    );
    let verbatim = first.verbatim_text.clone();
    let reference = store
        .cite_transcript_segment(&session, &first.revision_id, first.sequence)
        .unwrap();
    store
        .correct_transcript_segment(
            &session,
            &first.revision_id,
            first.sequence,
            Some("Reviewed agreement evidence"),
        )
        .unwrap();
    assert_eq!(
        store.resolve_evidence(&reference).unwrap().state,
        ResolutionState::Available
    );
    drop(recognizer);
    drop(store);

    let library = TranscriptLibrary::open(&root).unwrap();
    assert_eq!(
        library.availability(&session).unwrap(),
        TranscriptAvailability::Final
    );
    let reviewed = library.document(&session).unwrap();
    assert_eq!(reviewed[0].verbatim_text, verbatim);
    assert_eq!(reviewed[0].effective_text, "Reviewed agreement evidence");
    assert!(reviewed[0].corrected);
    assert_eq!(
        library
            .search("Reviewed agreement evidence", Some(&session), 10)
            .unwrap()[0]
            .revision_id,
        result.revision_id
    );
    let export_path = temp.path().join("reviewed.json");
    let receipt = library
        .export(
            &session,
            TranscriptExportFormat::TranscriptJson,
            &export_path,
        )
        .unwrap();
    assert_eq!(receipt.availability, TranscriptAvailability::Final);
    let exported: serde_json::Value =
        serde_json::from_slice(&fs::read(&export_path).unwrap()).unwrap();
    assert_eq!(
        exported["segments"][0]["effective_text"],
        "Reviewed agreement evidence"
    );
    let exported_reference =
        serde_json::from_value(exported["segments"][0]["evidence_ref"].clone()).unwrap();
    assert_eq!(
        library.resolve_evidence(&exported_reference).unwrap().state,
        ResolutionState::Available
    );
    // Export omits the advisory resolver hint. All identity, time, and digest
    // fields still bind the exact original hypothesis after correction.
    let mut expected_reference = reference;
    expected_reference.resolver_hint = None;
    assert_eq!(exported_reference, expected_reference);
    let source = temp.path().join("original.caf");
    let audio_receipt = library.export_original_media(&session, &source).unwrap();
    assert_eq!(audio_receipt.sha256, input_digest);
    assert_eq!(digest(&source), input_digest);
    let wav = temp.path().join("track.wav");
    let wav_receipt = library
        .export_track_wav(&session, &tracks[0], &wav)
        .unwrap();
    assert!(wav_receipt.byte_length > 44);
    assert_eq!(&fs::read(&wav).unwrap()[..4], b"RIFF");
    assert_eq!(digest(&speech), input_digest);
    assert_eq!(digest(&model), verified.sha256);
    assert!(
        !root.join("Models").exists(),
        "proof must not install model bytes"
    );
    eprintln!(
        "IMPORTED_REVIEW_WORKFLOW_GREEN segments={} model_sha256={} input_sha256={} proof=real_local_asr,media_recovery,review_restart,correction_search,evidence_resolution,json_export,source_export,wav_render excludes=native_ui,audible_playback,installation,live_capture",
        reviewed.len(),
        verified.sha256,
        input_digest
    );
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
        Err(SpeechError::Transcription(TranscriptionError::Store(
            StoreError::InvalidState(_)
        )))
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
