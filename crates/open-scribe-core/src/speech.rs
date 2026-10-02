//! Local speech models and final transcription of a saved session (ADR 0008,
//! ADR 0009). The checked manifest is the only catalog. A model file enters
//! only by copy into managed staging, full verification, a decode self-test,
//! and atomic installation, and it is reverified before every load. Nothing
//! here touches the network.

use crate::transcription::{
    TrackRequest, TranscriptionError, TranscriptionOutcome, TranscriptionProgress,
    transcribe_request,
};
use open_scribe_asr::{
    DecodeOptions, Language, MODEL_SAMPLE_RATE_HZ, RecognizerError, SpeechRecognizer,
    WHISPER_ENGINE, WHISPER_ENGINE_COMPATIBILITY, WhisperLoadError, WhisperRecognizer,
};
use open_scribe_models::{
    Catalog, CatalogError, InstallError, InstalledArtifact, ModelLayout, ModelRecord, VerifyError,
    verify_staged,
};
use open_scribe_store::{SessionStore, StoreError};
use open_scribe_types::SessionId;
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
            .map(|record| SpeechModelStatus {
                model_id: record.id.clone(),
                profile: record.profile.clone(),
                languages: record.languages.clone(),
                file_name: record.file_name.clone(),
                byte_length: record.byte_length,
                sha256: record.sha256.clone(),
                download_origin: record.download_origins.first().cloned().unwrap_or_default(),
                license: record.license.clone(),
                installed: fs::symlink_metadata(self.layout.installed_path(record)).is_ok_and(
                    |metadata| metadata.is_file() && metadata.len() == record.byte_length,
                ),
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
        let result = self.stage_verify_install(record, source);
        if result.is_err() {
            let _ = self.layout.discard_partial(record);
        }
        result
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
        let record = self.record(model_id).map_err(SpeechError::Model)?;
        let options = DecodeOptions::final_pass(decode_language(&record.languages));
        let mut recognizer = self.load(model_id).map_err(SpeechError::Model)?;
        let mut store = SessionStore::open(&self.managed_root)
            .map_err(|error| SpeechError::Transcription(error.into()))?;
        transcribe_session(
            &mut store,
            &mut recognizer,
            &options,
            session,
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
    ) -> Result<InstalledArtifact, SpeechModelError> {
        let staged = self
            .layout
            .stage_from_file(record, source)
            .map_err(SpeechModelError::Install)?;
        let verified = verify_staged(
            record,
            WHISPER_ENGINE,
            WHISPER_ENGINE_COMPATIBILITY,
            &staged,
        )
        .map_err(SpeechModelError::Verify)?;
        self_test(&staged, record)?;
        self.layout
            .install(record, &verified, &staged)
            .map_err(SpeechModelError::Install)
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
    let tracks = store.transcription_tracks(session)?;
    if tracks.is_empty() {
        return Err(
            StoreError::InvalidState("session has no sealed PCM track to transcribe").into(),
        );
    }
    let count = tracks.len();
    let mut outcomes = Vec::with_capacity(count);
    for (index, track) in tracks.iter().enumerate() {
        let request = TrackRequest {
            session,
            track_id: track,
            decoded_companion,
        };
        outcomes.push(transcribe_request(
            store,
            recognizer,
            options,
            request,
            cancel,
            &mut |update| progress(index, count, update),
        )?);
    }
    Ok(outcomes)
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
