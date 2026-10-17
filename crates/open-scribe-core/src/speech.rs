//! Local speech models and final transcription of a saved session (ADR 0008,
//! ADR 0009). The checked manifest is the only catalog. A model file enters
//! only by copy into managed staging, full verification, a decode self-test,
//! and atomic installation, and it is reverified before every load. Nothing
//! here touches the network.

use crate::transcription::{TranscriptionError, TranscriptionOutcome, TranscriptionProgress};
use open_scribe_asr::{
    DecodeOptions, Language, MODEL_SAMPLE_RATE_HZ, RecognizerError, SpeechRecognizer,
    WHISPER_ENGINE, WHISPER_ENGINE_COMPATIBILITY, WhisperLoadError, WhisperRecognizer,
};
use open_scribe_models::{
    Catalog, CatalogError, InstallError, InstalledArtifact, ModelLayout, ModelRecord, VerifyError,
    verify_staged,
};
use open_scribe_store::{SessionStore, StoreError};
use open_scribe_types::{ModelReadiness, SessionId};
use std::fmt;
use std::fs;
use std::path::{Path, PathBuf};
use std::sync::atomic::AtomicBool;

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct SpeechModelStatus {
    pub model_id: String,
    pub profile: String,
    pub languages: Vec<String>,
    pub file_name: String,
    pub byte_length: u64,
    pub sha256: String,
    pub download_origin: String,
    pub license: String,
    /// A regular file of the manifest length sits at the installed path. Its
    /// bytes are reverified before any load.
    pub installed: bool,
    pub readiness: ModelReadiness,
    pub diagnostic: Option<String>,
}

#[derive(Debug)]
pub enum SpeechModelError {
    Catalog(CatalogError),
    UnknownModel,
    NotInstalled,
    Verify(VerifyError),
    Install(InstallError),
    Load(WhisperLoadError),
    SelfTest(RecognizerError),
}

impl SpeechModelError {
    /// Stable, content-free diagnostic class.
    pub fn class(&self) -> &'static str {
        match self {
            Self::Catalog(_) => "catalog",
            Self::UnknownModel => "unknown_model",
            Self::NotInstalled => "not_installed",
            Self::Verify(error) => error.class(),
            Self::Install(error) => error.class(),
            Self::Load(error) => error.class(),
            Self::SelfTest(_) => "self_test_failed",
        }
    }
}

impl fmt::Display for SpeechModelError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "speech model unavailable: {}", self.class())
    }
}

impl std::error::Error for SpeechModelError {}

#[derive(Debug)]
pub enum SpeechError {
    Model(SpeechModelError),
    Transcription(TranscriptionError),
}

impl fmt::Display for SpeechError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Model(error) => error.fmt(f),
            Self::Transcription(error) => error.fmt(f),
        }
    }
}

impl std::error::Error for SpeechError {}

pub struct SpeechModels {
    managed_root: PathBuf,
    catalog: Catalog,
    layout: ModelLayout,
}

impl SpeechModels {
    pub fn managed_root(&self) -> &Path {
        &self.managed_root
    }
    pub fn open(managed_root: impl AsRef<Path>) -> Result<Self, SpeechModelError> {
        let managed_root = managed_root.as_ref().to_path_buf();
        Ok(Self {
            catalog: Catalog::canonical().map_err(SpeechModelError::Catalog)?,
            layout: ModelLayout::new(&managed_root),
            managed_root,
        })
    }

    pub fn statuses(&self) -> Vec<SpeechModelStatus> {
        self.catalog
            .records()
            .iter()
            .filter(|record| record.purpose == "asr")
            .map(|record| {
                let path = self.layout.installed_path(record);
                let (readiness, diagnostic) = match fs::symlink_metadata(&path) {
                    Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
                        (ModelReadiness::Absent, None)
                    }
                    Err(_) => (ModelReadiness::PresentUnverified, Some("unreadable".into())),
                    Ok(metadata) if !metadata.is_file() => {
                        (ModelReadiness::Invalid, Some("not_regular_file".into()))
                    }
                    Ok(_) => match verify_staged(
                        record,
                        WHISPER_ENGINE,
                        WHISPER_ENGINE_COMPATIBILITY,
                        &path,
                    ) {
                        Ok(_) => (ModelReadiness::Ready, None),
                        Err(error) => (
                            if matches!(error.class(), "incompatible_engine" | "engine_version") {
                                ModelReadiness::Incompatible
                            } else {
                                ModelReadiness::Invalid
                            },
                            Some(error.class().to_owned()),
                        ),
                    },
                };
                SpeechModelStatus {
                    model_id: record.id.clone(),
                    profile: record.profile.clone(),
                    languages: record.languages.clone(),
                    file_name: record.file_name.clone(),
                    byte_length: record.byte_length,
                    sha256: record.sha256.clone(),
                    download_origin: record.download_origins.first().cloned().unwrap_or_default(),
                    license: record.license.clone(),
                    installed: readiness == ModelReadiness::Ready,
                    readiness,
                    diagnostic,
                }
            })
            .collect()
    }

    /// Stages a user-chosen file, verifies length, header, and SHA-256
    /// against the manifest, runs a one-second decode self-test, then installs
    /// atomically. The chosen file is not modified; a rejected file leaves no
    /// staged bytes.
    pub fn install_from_file(
        &self,
        model_id: &str,
        source: &Path,
    ) -> Result<InstalledArtifact, SpeechModelError> {
        let record = self.record(model_id)?;
        self.stage_verify_install(record, source, false)
    }

    pub fn repair_from_file(
        &self,
        model_id: &str,
        source: &Path,
    ) -> Result<InstalledArtifact, SpeechModelError> {
        let record = self.record(model_id)?;
        self.stage_verify_install(record, source, true)
    }

    /// Reverifies the installed bytes, then loads them.
    pub fn load(&self, model_id: &str) -> Result<WhisperRecognizer, SpeechModelError> {
        let record = self.record(model_id)?;
        let path = self.layout.installed_path(record);
        if !fs::symlink_metadata(&path).is_ok_and(|metadata| metadata.is_file()) {
            return Err(SpeechModelError::NotInstalled);
        }
        verify_staged(record, WHISPER_ENGINE, WHISPER_ENGINE_COMPATIBILITY, &path)
            .map_err(SpeechModelError::Verify)?;
        WhisperRecognizer::load(&path, &record.id, &record.sha256).map_err(SpeechModelError::Load)
    }

    /// Whether the session is a compressed import that the platform must first
    /// decode to a PCM companion for transcription.
    pub fn needs_decoded_companion(&self, session: &SessionId) -> Result<bool, StoreError> {
        let store = SessionStore::open(&self.managed_root)?;
        for track in store.transcription_tracks(session)? {
            if store.transcription_input(session, &track)?.compressed {
                return Ok(true);
            }
        }
        Ok(false)
    }

    pub fn needs_decoded_companion_for_intent(
        &self,
        session: &SessionId,
        intent: crate::TranscriptionIntent,
    ) -> Result<bool, StoreError> {
        let store = SessionStore::open(&self.managed_root)?;
        let plan = crate::plan_session_transcription(&store, session, intent)?;
        if !plan.needs_recognizer() {
            return Ok(false);
        }
        self.needs_decoded_companion(session)
    }

    /// Reverifies and loads the model, then transcribes every sealed track of
    /// one saved session with its own store connection.
    pub fn transcribe(
        &self,
        model_id: &str,
        session: &SessionId,
        decoded_companion: Option<&Path>,
        cancel: &AtomicBool,
        progress: &mut dyn FnMut(usize, usize, TranscriptionProgress),
    ) -> Result<Vec<TranscriptionOutcome>, SpeechError> {
        self.transcribe_with_intent(
            model_id,
            session,
            crate::TranscriptionIntent::ResumeIncomplete,
            decoded_companion,
            cancel,
            progress,
        )
    }

    pub fn transcribe_with_intent(
        &self,
        model_id: &str,
        session: &SessionId,
        intent: crate::TranscriptionIntent,
        decoded_companion: Option<&Path>,
        cancel: &AtomicBool,
        progress: &mut dyn FnMut(usize, usize, TranscriptionProgress),
    ) -> Result<Vec<TranscriptionOutcome>, SpeechError> {
        self.transcribe_with_operation(
            model_id,
            session,
            &crate::TranscriptionOperation {
                intent,
                ..Default::default()
            },
            decoded_companion,
            cancel,
            progress,
        )
    }

    pub fn transcribe_with_operation(
        &self,
        model_id: &str,
        session: &SessionId,
        operation: &crate::TranscriptionOperation,
        decoded_companion: Option<&Path>,
        cancel: &AtomicBool,
        progress: &mut dyn FnMut(usize, usize, TranscriptionProgress),
    ) -> Result<Vec<TranscriptionOutcome>, SpeechError> {
        let mut store = SessionStore::open(&self.managed_root)
            .map_err(|error| SpeechError::Transcription(error.into()))?;
        let plan =
            crate::plan_transcription_operation(&store, session, operation.intent, operation)
                .map_err(|error| SpeechError::Transcription(error.into()))?;
        if !plan.needs_recognizer() {
            return crate::execute_transcription_plan(
                &mut store,
                None,
                &DecodeOptions::final_pass(Language::Detect),
                &plan,
                decoded_companion,
                cancel,
                progress,
            )
            .map_err(SpeechError::Transcription);
        }
        let record = self.record(model_id).map_err(SpeechError::Model)?;
        let options = DecodeOptions::final_pass(decode_language(&record.languages));
        let mut recognizer = self.load(model_id).map_err(SpeechError::Model)?;
        crate::execute_transcription_plan(
            &mut store,
            Some(&mut recognizer),
            &options,
            &plan,
            decoded_companion,
            cancel,
            progress,
        )
        .map_err(SpeechError::Transcription)
    }

    fn stage_verify_install(
        &self,
        record: &ModelRecord,
        source: &Path,
        repair: bool,
    ) -> Result<InstalledArtifact, SpeechModelError> {
        let staged = self
            .layout
            .stage_from_file(record, source)
            .map_err(SpeechModelError::Install)?;
        (|| {
            let verified = verify_staged(
                record,
                WHISPER_ENGINE,
                WHISPER_ENGINE_COMPATIBILITY,
                staged.path(),
            )
            .map_err(SpeechModelError::Verify)?;
            self_test(staged.path(), record)?;
            self.layout
                .install_local(record, &verified, &staged, repair)
                .map_err(SpeechModelError::Install)
        })()
    }

    fn record(&self, model_id: &str) -> Result<&ModelRecord, SpeechModelError> {
        self.catalog
            .get(model_id)
            .filter(|record| record.purpose == "asr")
            .ok_or(SpeechModelError::UnknownModel)
    }
}

/// English-only models decode English; multilingual models detect.
pub fn decode_language(record_languages: &[String]) -> Language {
    if record_languages == ["en"] {
        Language::English
    } else {
        Language::Detect
    }
}

/// Final transcription of every sealed track of one saved session. Each track
/// is its own run; a failed or cancelled track ends the call and leaves
/// earlier tracks' committed revisions in place. `decoded_companion` is the
/// platform's PCM decode of a compressed import and is ignored otherwise.
pub fn transcribe_session(
    store: &mut SessionStore,
    recognizer: &mut dyn SpeechRecognizer,
    options: &DecodeOptions,
    session: &SessionId,
    decoded_companion: Option<&Path>,
    cancel: &AtomicBool,
    progress: &mut dyn FnMut(usize, usize, TranscriptionProgress),
) -> Result<Vec<TranscriptionOutcome>, TranscriptionError> {
    let plan = crate::plan_session_transcription(
        store,
        session,
        crate::TranscriptionIntent::ResumeIncomplete,
    )?;
    crate::execute_transcription_plan(
        store,
        Some(recognizer),
        options,
        &plan,
        decoded_companion,
        cancel,
        progress,
    )
}

/// One second of silence must decode before a model is installed. This
/// proves the verified bytes load and run in this engine; it is not an
/// accuracy test.
fn self_test(staged: &Path, record: &ModelRecord) -> Result<(), SpeechModelError> {
    let mut recognizer = WhisperRecognizer::load(staged, &record.id, &record.sha256)
        .map_err(SpeechModelError::Load)?;
    let silence = vec![0.0_f32; MODEL_SAMPLE_RATE_HZ as usize];
    let options = DecodeOptions::final_pass(decode_language(&record.languages));
    recognizer
        .transcribe(&silence, &options, &AtomicBool::new(false))
        .map(|_| ())
        .map_err(SpeechModelError::SelfTest)
}
