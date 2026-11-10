//! Local speech models and final transcription of a saved session (ADR 0008,
//! ADR 0009). The checked manifest is the only catalog. A model file enters
//! only by copy into managed staging, full verification, a decode self-test,
//! and atomic installation, and it is reverified before every load. Removal
//! blocks a new run, asks an active run to stop at its next checkpoint, then
//! renames the version directory out of the loadable path. Nothing here
//! touches the network or the conversation library.

use crate::transcription::{TranscriptionError, TranscriptionOutcome, TranscriptionProgress};
use open_scribe_asr::{
    DecodeOptions, Language, MODEL_SAMPLE_RATE_HZ, RecognizerError, SpeechRecognizer,
    WHISPER_ENGINE, WHISPER_ENGINE_COMPATIBILITY, WhisperLoadError, WhisperRecognizer,
};
use open_scribe_models::{
    Catalog, CatalogError, InstallError, InstalledArtifact, ModelLayout, ModelRecord,
    QuarantinedModel, ResumeDecision, TransferValidator, VerifyError, resume_decision,
    verify_staged,
};
use open_scribe_store::{SessionStore, StoreError};
use open_scribe_types::{ModelReadiness, SessionId};
use std::collections::HashMap;
use std::fmt;
use std::fs;
use std::os::unix::fs::MetadataExt;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex, MutexGuard};

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
    /// A transcription run still holds this model. The installed directory
    /// stays where it is.
    ActiveRun,
    /// Removal has blocked new runs and the installed directory is not yet
    /// quarantined.
    Removing,
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
            Self::ActiveRun => "active_run",
            Self::Removing => "removing",
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

/// What to do with a transcription run that still holds the model.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum RemovalChoice {
    /// Leave the installed directory in place until the run drops.
    Wait,
    /// Ask the run to stop. The directory stays until the run drops.
    CancelActive,
}

/// The former version directory, no longer on the loadable path.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct RemovedSpeechModel {
    pub model_id: String,
    pub version: String,
    pub quarantined_directory: PathBuf,
}

/// Where a platform adapter may write one explicit catalog download.
/// This plan does not open a socket. `resume_offset` is zero until a
/// persisted validator exists; unknown bytes are never appended.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ModelDownloadPlan {
    pub url: String,
    pub partial_path: PathBuf,
    pub expected_length: u64,
    pub resume_offset: u64,
}

struct ModelRunState {
    holders: usize,
    cancel: Arc<AtomicBool>,
    removing: bool,
}

impl Default for ModelRunState {
    fn default() -> Self {
        Self {
            holders: 0,
            cancel: Arc::new(AtomicBool::new(false)),
            removing: false,
        }
    }
}

struct ModelRunGate {
    inner: Mutex<HashMap<String, ModelRunState>>,
}

impl ModelRunGate {
    fn lock(&self) -> MutexGuard<'_, HashMap<String, ModelRunState>> {
        self.inner.lock().unwrap_or_else(|error| error.into_inner())
    }
}

/// Held for the recognizer portion of one transcription call.
pub(crate) struct ModelRunGuard {
    gate: Arc<ModelRunGate>,
    model_id: String,
    pub(crate) cancel: Arc<AtomicBool>,
}

impl Drop for ModelRunGuard {
    fn drop(&mut self) {
        let mut runs = self.gate.lock();
        let Some(entry) = runs.get_mut(&self.model_id) else {
            return;
        };
        entry.holders = entry.holders.saturating_sub(1);
        if entry.holders == 0 && !entry.removing {
            runs.remove(&self.model_id);
        }
    }
}

pub struct SpeechModels {
    managed_root: PathBuf,
    catalog: Catalog,
    layout: ModelLayout,
    runs: Arc<ModelRunGate>,
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
            runs: Arc::new(ModelRunGate {
                inner: Mutex::new(HashMap::new()),
            }),
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

    /// Blocks new runs, then renames the version directory out of the loadable
    /// path. An active run keeps that directory until it drops. Cancel asks
    /// the run to stop at its next checkpoint. Bytes stay in the quarantined
    /// directory. This does not open the conversation library.
    pub fn remove(
        &self,
        model_id: &str,
        choice: RemovalChoice,
    ) -> Result<RemovedSpeechModel, SpeechModelError> {
        let record = self.record(model_id)?.clone();
        let mut runs = self.runs.lock();
        {
            let entry = runs.entry(record.id.clone()).or_default();
            entry.removing = true;
            if entry.holders > 0 {
                if choice == RemovalChoice::CancelActive {
                    entry.cancel.store(true, Ordering::Release);
                }
                return Err(SpeechModelError::ActiveRun);
            }
        }
        let quarantined = match self.layout.quarantine_installed(&record) {
            Ok(quarantined) => quarantined,
            Err(InstallError::NotInstalled) => {
                runs.remove(&record.id);
                return Err(SpeechModelError::NotInstalled);
            }
            Err(error) => {
                if let Some(entry) = runs.get_mut(&record.id) {
                    entry.removing = false;
                    if entry.holders == 0 {
                        runs.remove(&record.id);
                    }
                }
                return Err(SpeechModelError::Install(error));
            }
        };
        runs.remove(&record.id);
        Ok(removed_model(quarantined))
    }

    /// Names the catalog origin and an empty regular partial. No validator
    /// is stored yet, so the resume rule restarts and the partial is truncated.
    /// A symlink or extra link at that path is left untouched.
    pub fn plan_download(&self, model_id: &str) -> Result<ModelDownloadPlan, SpeechModelError> {
        self.ensure_not_removing(model_id)?;
        let record = self.record(model_id)?.clone();
        let url = record
            .download_origins
            .iter()
            .find(|origin| origin.starts_with("https://"))
            .cloned()
            .ok_or(SpeechModelError::UnknownModel)?;
        let partial = self.layout.partial_path(&record);
        let partial_length = fs::symlink_metadata(&partial)
            .ok()
            .filter(|metadata| metadata.is_file())
            .map(|metadata| metadata.len())
            .unwrap_or(0);
        let validator = TransferValidator {
            url: url.clone(),
            etag: None,
            last_modified: None,
            expected_length: record.byte_length,
            manifest_sha256: record.sha256.clone(),
        };
        // No ETag or Last-Modified is persisted. Restart is the only
        // decision that may prepare the partial, and it truncates.
        match resume_decision(&record, None, &validator, partial_length) {
            ResumeDecision::Restart => {}
            ResumeDecision::Resume { .. } => {
                return Err(SpeechModelError::Install(InstallError::RecordMismatch));
            }
        }
        let prepared = self
            .layout
            .prepare_download_partial(&record)
            .map_err(SpeechModelError::Install)?;
        Ok(ModelDownloadPlan {
            url,
            partial_path: prepared.path,
            expected_length: record.byte_length,
            resume_offset: prepared.length,
        })
    }

    /// Verifies the download partial with the same checks as a chosen file.
    /// A symlink or extra hard link is refused and left in place. A rejected
    /// partial stays where the adapter wrote it. A successful install drops
    /// only that same inode.
    pub fn finish_download(&self, model_id: &str) -> Result<InstalledArtifact, SpeechModelError> {
        self.ensure_not_removing(model_id)?;
        let record = self.record(model_id)?.clone();
        let path = self.layout.partial_path(&record);
        let metadata =
            fs::symlink_metadata(&path).map_err(|error| SpeechModelError::Install(error.into()))?;
        if !metadata.is_file() || metadata.file_type().is_symlink() || metadata.nlink() != 1 {
            return Err(SpeechModelError::Install(InstallError::NotRegularFile));
        }
        let installed = self.install_from_file(&record.id, &path)?;
        // The loadable copy is already installed. A partial that was swapped
        // after that copy is left alone instead of failing the install.
        let _ = self
            .layout
            .discard_owned_partial(&record, metadata.dev(), metadata.ino());
        Ok(installed)
    }

    /// One in-flight recognizer use. Transcription holds this across load and
    /// execution so removal cannot rename the model underneath it.
    pub(crate) fn begin_model_run(
        &self,
        model_id: &str,
    ) -> Result<ModelRunGuard, SpeechModelError> {
        let mut runs = self.runs.lock();
        let entry = runs.entry(model_id.to_owned()).or_default();
        if entry.removing {
            return Err(SpeechModelError::Removing);
        }
        entry.holders += 1;
        Ok(ModelRunGuard {
            gate: Arc::clone(&self.runs),
            model_id: model_id.to_owned(),
            cancel: Arc::clone(&entry.cancel),
        })
    }

    fn ensure_not_removing(&self, model_id: &str) -> Result<(), SpeechModelError> {
        let runs = self.runs.lock();
        if runs.get(model_id).is_some_and(|entry| entry.removing) {
            return Err(SpeechModelError::Removing);
        }
        Ok(())
    }

    /// Reverifies the installed bytes, then loads them.
    pub fn load(&self, model_id: &str) -> Result<WhisperRecognizer, SpeechModelError> {
        self.ensure_not_removing(model_id)?;
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
        let run = self.begin_model_run(model_id).map_err(SpeechError::Model)?;
        let removal_cancel = Arc::clone(&run.cancel);
        let mut bridge = |index, count, update| {
            if removal_cancel.load(Ordering::Acquire) {
                cancel.store(true, Ordering::Release);
            }
            progress(index, count, update);
        };
        if removal_cancel.load(Ordering::Acquire) {
            cancel.store(true, Ordering::Release);
        }
        let options = DecodeOptions::final_pass(decode_language(&record.languages));
        let mut recognizer = self.load(model_id).map_err(SpeechError::Model)?;
        let transcribed = crate::execute_transcription_plan(
            &mut store,
            Some(&mut recognizer),
            &options,
            &plan,
            decoded_companion,
            cancel,
            &mut bridge,
        );
        drop(recognizer);
        drop(run);
        transcribed.map_err(SpeechError::Transcription)
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
fn removed_model(quarantined: QuarantinedModel) -> RemovedSpeechModel {
    RemovedSpeechModel {
        model_id: quarantined.model_id,
        version: quarantined.version,
        quarantined_directory: quarantined.directory,
    }
}

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
