use crate::catalog::ModelRecord;
use crate::verify::{VerifiedArtifact, modified_nanoseconds, open_no_follow};
use sha2::{Digest, Sha256};
use std::fmt;
use std::fs::{self, File, OpenOptions};
use std::io::{self, Read};
use std::os::unix::fs::{MetadataExt, OpenOptionsExt};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::{SystemTime, UNIX_EPOCH};

const MODELS_DIRECTORY: &str = "Models";
const STAGING_DIRECTORY: &str = ".staging";
static LOCAL_ATTEMPT: AtomicU64 = AtomicU64::new(0);

/// A local-file copy owns only the inode it created. Interrupted attempts and
/// legacy download partials are preserved; a retry uses an independent path.
#[derive(Debug)]
pub struct LocalStagedModel {
    path: PathBuf,
    file: File,
    model_id: String,
    version: String,
    device: u64,
    inode: u64,
}

impl LocalStagedModel {
    pub fn path(&self) -> &Path {
        &self.path
    }
}

impl Drop for LocalStagedModel {
    fn drop(&mut self) {
        let _ = discard_owned_file(&self.path, self.device, self.inode);
    }
}

/// Managed model paths under the application's managed root.
#[derive(Clone, Debug)]
pub struct ModelLayout {
    models: PathBuf,
}

impl ModelLayout {
    pub fn new(managed_root: &Path) -> Self {
        Self {
            models: managed_root.join(MODELS_DIRECTORY),
        }
    }

    pub fn staging_directory(&self) -> PathBuf {
        self.models.join(STAGING_DIRECTORY)
    }

    /// The only path a platform adapter may download into.
    pub fn partial_path(&self, record: &ModelRecord) -> PathBuf {
        self.staging_directory()
            .join(format!("{}-{}.part", record.id, record.version))
    }

    /// Creates or truncates the download partial. A symlink or extra hard
    /// link is left untouched. This does not open a socket or read model bytes.
    /// Callers append only after `resume_decision` returns `Resume`; this
    /// restart path never appends.
    pub fn prepare_download_partial(
        &self,
        record: &ModelRecord,
    ) -> Result<PreparedPartial, InstallError> {
        self.ensure_owned_directory(&self.staging_directory())?;
        let path = self.partial_path(record);
        match fs::symlink_metadata(&path) {
            Ok(metadata) => {
                if !single_regular_file(&metadata) {
                    return Err(InstallError::NotRegularFile);
                }
                let file = OpenOptions::new()
                    .write(true)
                    .truncate(true)
                    .custom_flags(rustix::fs::OFlags::NOFOLLOW.bits() as i32)
                    .open(&path)?;
                let current = file.metadata()?;
                if !single_regular_file(&current)
                    || current.dev() != metadata.dev()
                    || current.ino() != metadata.ino()
                {
                    return Err(InstallError::NotRegularFile);
                }
                file.sync_all()?;
                sync_directory(&self.staging_directory())?;
                Ok(PreparedPartial { path, length: 0 })
            }
            Err(error) if error.kind() == io::ErrorKind::NotFound => {
                let file = OpenOptions::new()
                    .write(true)
                    .create_new(true)
                    .mode(0o600)
                    .custom_flags(rustix::fs::OFlags::NOFOLLOW.bits() as i32)
                    .open(&path)?;
                let metadata = file.metadata()?;
                if !single_regular_file(&metadata) {
                    return Err(InstallError::NotRegularFile);
                }
                file.sync_all()?;
                sync_directory(&self.staging_directory())?;
                Ok(PreparedPartial { path, length: 0 })
            }
            Err(error) => Err(error.into()),
        }
    }

    pub fn install_directory(&self, record: &ModelRecord) -> PathBuf {
        self.models.join(&record.id).join(&record.version)
    }

    pub fn installed_path(&self, record: &ModelRecord) -> PathBuf {
        self.install_directory(record).join(&record.file_name)
    }

    pub fn relative_installed_path(record: &ModelRecord) -> String {
        format!(
            "{MODELS_DIRECTORY}/{}/{}/{}",
            record.id, record.version, record.file_name
        )
    }
}

/// HTTP validators observed for a transfer. A partial resumes only when
/// every validator and the manifest identity still agree.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct TransferValidator {
    pub url: String,
    pub etag: Option<String>,
    pub last_modified: Option<String>,
    pub expected_length: u64,
    pub manifest_sha256: String,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum ResumeDecision {
    Resume { offset: u64 },
    Restart,
}

/// An empty regular file at the catalog partial path.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct PreparedPartial {
    pub path: PathBuf,
    pub length: u64,
}

pub fn resume_decision(
    record: &ModelRecord,
    prior: Option<&TransferValidator>,
    current: &TransferValidator,
    partial_length: u64,
) -> ResumeDecision {
    let Some(prior) = prior else {
        return ResumeDecision::Restart;
    };
    let identity_agrees = prior == current
        && current.expected_length == record.byte_length
        && current.manifest_sha256 == record.sha256
        && record.download_origins.contains(&current.url);
    let has_validator = current.etag.is_some() || current.last_modified.is_some();
    if identity_agrees && has_validator && partial_length > 0 && partial_length < record.byte_length
    {
        ResumeDecision::Resume {
            offset: partial_length,
        }
    } else {
        ResumeDecision::Restart
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct InstalledArtifact {
    pub model_id: String,
    pub version: String,
    pub sha256: String,
    pub byte_length: u64,
    pub path: PathBuf,
    pub relative_path: String,
}

/// An installed version directory renamed out of its loadable path.
/// The bytes are still in `directory`. The platform may move that directory
/// to Trash; this crate does not delete them.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct QuarantinedModel {
    pub model_id: String,
    pub version: String,
    pub directory: PathBuf,
}

#[derive(Debug)]
pub enum InstallError {
    RecordMismatch,
    NotRegularFile,
    NotStagingPath,
    ChangedSinceVerification,
    ConflictingInstallation,
    StagingExists,
    NotInstalled,
    NotOwnedDirectory,
    Io(io::Error),
}

impl InstallError {
    pub const fn class(&self) -> &'static str {
        match self {
            Self::RecordMismatch => "record_mismatch",
            Self::NotRegularFile => "not_regular_file",
            Self::NotStagingPath => "not_staging_path",
            Self::ChangedSinceVerification => "changed_since_verification",
            Self::ConflictingInstallation => "conflicting_installation",
            Self::StagingExists => "staging_exists",
            Self::NotInstalled => "not_installed",
            Self::NotOwnedDirectory => "not_owned_directory",
            Self::Io(_) => "io",
        }
    }
}

impl fmt::Display for InstallError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "model installation failed: {}", self.class())
    }
}

impl std::error::Error for InstallError {}

impl From<io::Error> for InstallError {
    fn from(error: io::Error) -> Self {
        Self::Io(error)
    }
}

impl ModelLayout {
    /// Synchronizes and atomically renames the exact verified staging file
    /// into its versioned directory. An existing different file is never
    /// replaced; an identical existing installation is accepted idempotently.
    pub fn install(
        &self,
        record: &ModelRecord,
        verified: &VerifiedArtifact,
        staged: &Path,
    ) -> Result<InstalledArtifact, InstallError> {
        self.install_checked(record, verified, staged, false, None)
    }

    /// Explicit repair retains the old invalid inode in the owned directory.
    /// Foreign or redirected names and unowned additional links are never replaced.
    /// Only the exact owned retention pair can resume an interrupted repair.
    pub fn repair_install(
        &self,
        record: &ModelRecord,
        verified: &VerifiedArtifact,
        staged: &Path,
    ) -> Result<InstalledArtifact, InstallError> {
        self.install_checked(record, verified, staged, true, None)
    }

    /// Installs only this local attempt's verified inode. The private token
    /// cannot authorize another staging path or a different catalog record.
    pub fn install_local(
        &self,
        record: &ModelRecord,
        verified: &VerifiedArtifact,
        staged: &LocalStagedModel,
        repair: bool,
    ) -> Result<InstalledArtifact, InstallError> {
        self.install_checked(record, verified, staged.path(), repair, Some(staged))
    }

    fn install_checked(
        &self,
        record: &ModelRecord,
        verified: &VerifiedArtifact,
        staged: &Path,
        repair: bool,
        local: Option<&LocalStagedModel>,
    ) -> Result<InstalledArtifact, InstallError> {
        if verified.model_id != record.id
            || verified.version != record.version
            || verified.sha256 != record.sha256
            || verified.byte_length != record.byte_length
        {
            return Err(InstallError::RecordMismatch);
        }
        let local_matches = local.is_some_and(|attempt| {
            attempt.path() == staged
                && staged.parent() == Some(self.staging_directory().as_path())
                && attempt.model_id == record.id
                && attempt.version == record.version
                && attempt.device == verified.device
                && attempt.inode == verified.inode
        });
        if (local.is_some() && !local_matches)
            || (local.is_none() && staged != self.partial_path(record))
        {
            return Err(InstallError::NotStagingPath);
        }
        let file = open_no_follow(staged)?;
        let metadata = file.metadata()?;
        if metadata.dev() != verified.device
            || metadata.ino() != verified.inode
            || metadata.len() != verified.byte_length
            || modified_nanoseconds(&metadata) != verified.modified_nanoseconds
            || (local_matches && metadata.nlink() != 1)
        {
            return Err(InstallError::ChangedSinceVerification);
        }
        file.sync_all()?;

        let directory = self.install_directory(record);
        self.ensure_owned_directory(&directory)?;
        let destination = self.installed_path(record);
        let installed = InstalledArtifact {
            model_id: record.id.clone(),
            version: record.version.clone(),
            sha256: record.sha256.clone(),
            byte_length: record.byte_length,
            path: destination.clone(),
            relative_path: Self::relative_installed_path(record),
        };
        match fs::symlink_metadata(&destination) {
            Ok(existing) => {
                let retained = directory.join(format!(
                    "{}.invalid.{}.{}",
                    record.file_name,
                    existing.ino(),
                    modified_nanoseconds(&existing)
                ));
                // Exactly two links, both at the owned repair names, can be
                // our durable post-retention/pre-unlink interruption point.
                // A third link or a redirected/unrelated retained name refuses.
                let resuming_retention =
                    repair && existing.nlink() == 2 && retained_invalid_pair(&existing, &retained)?;
                if !existing.is_file()
                    || (existing.nlink() != 1 && !resuming_retention)
                    || existing.uid() != fs::metadata(self.models.parent().unwrap())?.uid()
                {
                    return Err(InstallError::ConflictingInstallation);
                }
                let mut prior = open_no_follow(&destination)?;
                let mut digest = Sha256::new();
                io::copy(&mut prior, &mut digest)?;
                let observed = prior.metadata()?;
                let unchanged = observed.dev() == existing.dev()
                    && observed.ino() == existing.ino()
                    && observed.nlink() == existing.nlink()
                    && observed.len() == existing.len()
                    && modified_nanoseconds(&observed) == modified_nanoseconds(&existing);
                if unchanged
                    && existing.len() == record.byte_length
                    && format!("{:x}", digest.finalize()) == record.sha256
                {
                    fs::remove_file(staged)?;
                    sync_directory(&self.staging_directory())?;
                    return Ok(installed);
                }
                if !repair || !unchanged {
                    return Err(InstallError::ConflictingInstallation);
                }
                // create-new hard link retains evidence before unlinking only
                // the owned destination. Restart reuses only that exact pair.
                if !resuming_retention {
                    fs::hard_link(&destination, &retained)?;
                }
                sync_directory(&directory)?;
                let current = fs::symlink_metadata(&destination)?;
                if current.dev() != existing.dev()
                    || current.ino() != existing.ino()
                    || !retained_invalid_pair(&current, &retained)?
                {
                    return Err(InstallError::ConflictingInstallation);
                }
                fs::remove_file(&destination)?;
                sync_directory(&directory)?;
            }
            Err(error) if error.kind() == io::ErrorKind::NotFound => {}
            Err(error) => return Err(error.into()),
        }
        fs::rename(staged, &destination)?;
        sync_directory(&directory)?;
        sync_directory(&self.staging_directory())?;
        Ok(installed)
    }

    /// Copies a user-chosen local file into an independently owned staging path for
    /// verification. The source is only read. The copy stops one byte past
    /// the manifest length, so an oversized file fails verification without
    /// being staged whole. Nothing here loads the bytes.
    pub fn stage_from_file(
        &self,
        record: &ModelRecord,
        source: &Path,
    ) -> Result<LocalStagedModel, InstallError> {
        let input = File::open(source)?;
        if !input.metadata()?.is_file() {
            return Err(InstallError::NotRegularFile);
        }
        self.ensure_owned_directory(&self.staging_directory())?;
        let timestamp = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap_or_default()
            .as_nanos();
        let (staged, output) = loop {
            let counter = LOCAL_ATTEMPT.fetch_add(1, Ordering::Relaxed);
            let path = self.staging_directory().join(format!(
                "{}-{}.local-{}-{timestamp}-{counter}.part",
                record.id,
                record.version,
                std::process::id()
            ));
            match OpenOptions::new()
                .write(true)
                .create_new(true)
                .mode(0o600)
                .custom_flags(rustix::fs::OFlags::NOFOLLOW.bits() as i32)
                .open(&path)
            {
                Ok(file) => break (path, file),
                Err(error) if error.kind() == io::ErrorKind::AlreadyExists => continue,
                Err(error) => return Err(error.into()),
            }
        };
        let identity = output.metadata()?;
        let mut staged = LocalStagedModel {
            path: staged,
            model_id: record.id.clone(),
            version: record.version.clone(),
            device: identity.dev(),
            inode: identity.ino(),
            file: output,
        };
        let result = (|| -> io::Result<()> {
            io::copy(&mut input.take(record.byte_length + 1), &mut staged.file)?;
            staged.file.sync_all()?;
            sync_directory(&self.staging_directory())
        })();
        if let Err(error) = result {
            return Err(error.into());
        }
        Ok(staged)
    }

    /// Discards a partial after an explicit restart decision or user action.
    pub fn discard_partial(&self, record: &ModelRecord) -> io::Result<()> {
        match fs::remove_file(self.partial_path(record)) {
            Err(error) if error.kind() == io::ErrorKind::NotFound => Ok(()),
            result => result,
        }
    }

    /// Cleanup for one created staging inode; substitutions remain untouched.
    pub fn discard_owned_partial(
        &self,
        record: &ModelRecord,
        device: u64,
        inode: u64,
    ) -> io::Result<()> {
        discard_owned_file(&self.partial_path(record), device, inode)
    }

    /// Renames `Models/<id>/<version>` out of the loadable path. The bytes
    /// stay in the returned directory. A symlink, or a directory that is not
    /// directly owned, is left untouched. An absent version is `NotInstalled`.
    pub fn quarantine_installed(
        &self,
        record: &ModelRecord,
    ) -> Result<QuarantinedModel, InstallError> {
        let source = self.install_directory(record);
        if !source.starts_with(&self.models) {
            return Err(InstallError::NotOwnedDirectory);
        }
        let metadata = match fs::symlink_metadata(&source) {
            Ok(metadata) => metadata,
            Err(error) if error.kind() == io::ErrorKind::NotFound => {
                return Err(InstallError::NotInstalled);
            }
            Err(error) => return Err(error.into()),
        };
        self.require_direct_owned(&source, &metadata)?;
        let removed_root = self.models.join(".removed").join(&record.id);
        self.ensure_owned_directory(&removed_root)?;
        let destination = quarantine_destination(&removed_root, &record.version, metadata.ino())?;
        let current = fs::symlink_metadata(&source)?;
        if current.file_type() != metadata.file_type()
            || current.dev() != metadata.dev()
            || current.ino() != metadata.ino()
        {
            return Err(InstallError::NotOwnedDirectory);
        }
        fs::rename(&source, &destination)?;
        sync_directory(&removed_root)?;
        if let Some(parent) = source.parent() {
            sync_directory(parent)?;
        }
        Ok(QuarantinedModel {
            model_id: record.id.clone(),
            version: record.version.clone(),
            directory: destination,
        })
    }

    fn require_direct_owned(
        &self,
        directory: &Path,
        metadata: &fs::Metadata,
    ) -> Result<(), InstallError> {
        let root = self.models.parent().expect("managed model parent");
        let owner = fs::symlink_metadata(root)?.uid();
        if !metadata.is_dir() || metadata.file_type().is_symlink() || metadata.uid() != owner {
            return Err(InstallError::NotOwnedDirectory);
        }
        let mut path = root.to_path_buf();
        for part in directory
            .strip_prefix(root)
            .map_err(|_| InstallError::NotOwnedDirectory)?
            .components()
        {
            path.push(part);
            let metadata = fs::symlink_metadata(&path)?;
            if !metadata.is_dir() || metadata.file_type().is_symlink() || metadata.uid() != owner {
                return Err(InstallError::NotOwnedDirectory);
            }
        }
        Ok(())
    }

    fn ensure_owned_directory(&self, directory: &Path) -> io::Result<()> {
        let root = self.models.parent().expect("managed model parent");
        let metadata = fs::symlink_metadata(root)?;
        if !metadata.is_dir() || metadata.file_type().is_symlink() {
            return Err(io::Error::other("model root is redirected"));
        }
        let owner = metadata.uid();
        let mut path = root.to_path_buf();
        for part in directory
            .strip_prefix(root)
            .map_err(io::Error::other)?
            .components()
        {
            path.push(part);
            match fs::create_dir(&path) {
                Ok(()) => {}
                Err(error) if error.kind() == io::ErrorKind::AlreadyExists => {}
                Err(error) => return Err(error),
            }
            let metadata = fs::symlink_metadata(&path)?;
            if !metadata.is_dir() || metadata.file_type().is_symlink() || metadata.uid() != owner {
                return Err(io::Error::other("model directory is not owned and direct"));
            }
        }
        Ok(())
    }
}

fn retained_invalid_pair(existing: &fs::Metadata, retained: &Path) -> io::Result<bool> {
    let retained = match fs::symlink_metadata(retained) {
        Ok(metadata) => metadata,
        Err(error) if error.kind() == io::ErrorKind::NotFound => return Ok(false),
        Err(error) => return Err(error),
    };
    Ok(existing.is_file()
        && existing.nlink() == 2
        && retained.is_file()
        && retained.nlink() == 2
        && retained.dev() == existing.dev()
        && retained.ino() == existing.ino()
        && retained.uid() == existing.uid())
}

fn quarantine_destination(root: &Path, version: &str, inode: u64) -> io::Result<PathBuf> {
    for attempt in 0..1_000 {
        let name = if attempt == 0 {
            format!("{version}-{inode}")
        } else {
            format!("{version}-{inode}-{attempt}")
        };
        let path = root.join(name);
        match fs::symlink_metadata(&path) {
            Err(error) if error.kind() == io::ErrorKind::NotFound => return Ok(path),
            Ok(_) => continue,
            Err(error) => return Err(error),
        }
    }
    Err(io::Error::other("model quarantine name is exhausted"))
}

fn single_regular_file(metadata: &fs::Metadata) -> bool {
    metadata.is_file() && !metadata.file_type().is_symlink() && metadata.nlink() == 1
}

fn discard_owned_file(path: &Path, device: u64, inode: u64) -> io::Result<()> {
    match fs::symlink_metadata(path) {
        Ok(metadata)
            if metadata.is_file()
                && metadata.nlink() == 1
                && metadata.dev() == device
                && metadata.ino() == inode =>
        {
            fs::remove_file(path)?;
            sync_directory(path.parent().expect("managed staging parent"))
        }
        Err(error) if error.kind() == io::ErrorKind::NotFound => Ok(()),
        Ok(_) => Err(io::Error::other("staging ownership changed")),
        Err(error) => Err(error),
    }
}

fn sync_directory(path: &Path) -> io::Result<()> {
    File::open(path)?.sync_all()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::verify::tests::{COMPATIBILITY, ENGINE, fixture, fixture_bytes};
    use crate::verify_staged;

    fn stage(layout: &ModelLayout, record: &ModelRecord, bytes: &[u8]) -> PathBuf {
        fs::create_dir_all(layout.staging_directory()).unwrap();
        let path = layout.partial_path(record);
        fs::write(&path, bytes).unwrap();
        path
    }

    #[test]
    fn verified_staging_file_installs_atomically_and_idempotently() {
        let root = tempfile::tempdir().unwrap();
        let layout = ModelLayout::new(root.path());
        let bytes = fixture_bytes(51864);
        let record = fixture(&bytes);
        let staged = stage(&layout, &record, &bytes);
        let verified = verify_staged(&record, ENGINE, COMPATIBILITY, &staged).unwrap();
        let installed = layout.install(&record, &verified, &staged).unwrap();
        assert_eq!(
            installed.relative_path,
            "Models/fixture-model/1.0.0/fixture.bin"
        );
        assert_eq!(fs::read(&installed.path).unwrap(), bytes);
        assert!(!staged.exists());

        let staged = stage(&layout, &record, &bytes);
        let verified = verify_staged(&record, ENGINE, COMPATIBILITY, &staged).unwrap();
        assert_eq!(
            layout.install(&record, &verified, &staged).unwrap(),
            installed
        );
        assert!(!staged.exists());
    }

    #[test]
    fn replaced_or_foreign_files_are_never_installed() {
        let root = tempfile::tempdir().unwrap();
        let layout = ModelLayout::new(root.path());
        let bytes = fixture_bytes(51864);
        let record = fixture(&bytes);
        let staged = stage(&layout, &record, &bytes);
        let verified = verify_staged(&record, ENGINE, COMPATIBILITY, &staged).unwrap();

        fs::remove_file(&staged).unwrap();
        fs::write(&staged, &bytes).unwrap();
        assert!(matches!(
            layout.install(&record, &verified, &staged),
            Err(InstallError::ChangedSinceVerification)
        ));

        let elsewhere = root.path().join("elsewhere.part");
        fs::write(&elsewhere, &bytes).unwrap();
        assert!(matches!(
            layout.install(&record, &verified, &elsewhere),
            Err(InstallError::NotStagingPath)
        ));

        let mut other = record.clone();
        other.version = "2.0.0".into();
        assert!(matches!(
            layout.install(&other, &verified, &staged),
            Err(InstallError::RecordMismatch)
        ));

        let verified = verify_staged(&record, ENGINE, COMPATIBILITY, &staged).unwrap();
        fs::create_dir_all(layout.install_directory(&record)).unwrap();
        fs::write(layout.installed_path(&record), b"someone else's file").unwrap();
        assert!(matches!(
            layout.install(&record, &verified, &staged),
            Err(InstallError::ConflictingInstallation)
        ));
        assert_eq!(
            fs::read(layout.installed_path(&record)).unwrap(),
            b"someone else's file"
        );
        assert!(staged.exists());
    }

    #[test]
    fn same_length_corruption_requires_explicit_repair_and_keeps_invalid_bytes() {
        let root = tempfile::tempdir().unwrap();
        let layout = ModelLayout::new(root.path());
        let bytes = fixture_bytes(51864);
        let record = fixture(&bytes);
        let staged = stage(&layout, &record, &bytes);
        let verified = verify_staged(&record, ENGINE, COMPATIBILITY, &staged).unwrap();
        let installed = layout.install(&record, &verified, &staged).unwrap();
        let mut corrupt = bytes.clone();
        *corrupt.last_mut().unwrap() ^= 1;
        fs::write(&installed.path, &corrupt).unwrap();
        assert!(matches!(
            verify_staged(&record, ENGINE, COMPATIBILITY, &installed.path),
            Err(crate::VerifyError::DigestMismatch)
        ));
        let staged = stage(&layout, &record, &bytes);
        let verified = verify_staged(&record, ENGINE, COMPATIBILITY, &staged).unwrap();
        assert!(matches!(
            layout.install(&record, &verified, &staged),
            Err(InstallError::ConflictingInstallation)
        ));
        layout.repair_install(&record, &verified, &staged).unwrap();
        verify_staged(&record, ENGINE, COMPATIBILITY, &installed.path).unwrap();
        let retained = fs::read_dir(layout.install_directory(&record))
            .unwrap()
            .map(Result::unwrap)
            .find(|entry| entry.file_name().to_string_lossy().contains(".invalid."))
            .unwrap();
        assert_eq!(fs::read(retained.path()).unwrap(), corrupt);
        fs::write(&installed.path, &corrupt).unwrap();
        assert!(
            verify_staged(&record, ENGINE, COMPATIBILITY, &installed.path).is_err(),
            "load-boundary verification remains mandatory"
        );
    }

    #[test]
    fn repair_resumes_after_preserved_invalid_inode_was_linked_before_interruption() {
        let root = tempfile::tempdir().unwrap();
        let layout = ModelLayout::new(root.path());
        let bytes = fixture_bytes(51864);
        let record = fixture(&bytes);
        let staged = stage(&layout, &record, &bytes);
        let verified = verify_staged(&record, ENGINE, COMPATIBILITY, &staged).unwrap();
        let installed = layout.install(&record, &verified, &staged).unwrap();
        let mut corrupt = bytes.clone();
        *corrupt.last_mut().unwrap() ^= 1;
        fs::write(&installed.path, &corrupt).unwrap();
        let old = fs::metadata(&installed.path).unwrap();
        let retained = layout.install_directory(&record).join(format!(
            "{}.invalid.{}.{}",
            record.file_name,
            old.ino(),
            modified_nanoseconds(&old)
        ));
        // Exact durable post-link/pre-unlink checkpoint of explicit repair.
        // A new layout/attempt represents restart; no model is loaded here.
        fs::hard_link(&installed.path, &retained).unwrap();
        sync_directory(&layout.install_directory(&record)).unwrap();
        assert_eq!(fs::metadata(&installed.path).unwrap().nlink(), 2);
        let layout = ModelLayout::new(root.path());
        let chosen = root.path().join("chosen.bin");
        fs::write(&chosen, &bytes).unwrap();
        let staged = layout.stage_from_file(&record, &chosen).unwrap();
        let verified = verify_staged(&record, ENGINE, COMPATIBILITY, staged.path()).unwrap();
        assert!(
            matches!(
                layout.install_local(&record, &verified, &staged, false),
                Err(InstallError::ConflictingInstallation)
            ),
            "resuming quarantine is explicit repair only"
        );
        layout
            .install_local(&record, &verified, &staged, true)
            .unwrap();
        verify_staged(&record, ENGINE, COMPATIBILITY, &installed.path).unwrap();
        assert_eq!(fs::read(&retained).unwrap(), corrupt);
        assert_eq!(fs::metadata(&retained).unwrap().nlink(), 1);
        assert_eq!(fs::read(&chosen).unwrap(), bytes);
    }

    #[test]
    fn repair_never_reuses_unrelated_or_redirected_retained_links() {
        for kind in ["unrelated", "symlink", "extra-link"] {
            let root = tempfile::tempdir().unwrap();
            let layout = ModelLayout::new(root.path());
            let bytes = fixture_bytes(51864);
            let record = fixture(&bytes);
            let staged = stage(&layout, &record, &bytes);
            let verified = verify_staged(&record, ENGINE, COMPATIBILITY, &staged).unwrap();
            let installed = layout.install(&record, &verified, &staged).unwrap();
            let corrupt = b"preserve this invalid file";
            fs::write(&installed.path, corrupt).unwrap();
            let old = fs::metadata(&installed.path).unwrap();
            let retained = layout.install_directory(&record).join(format!(
                "{}.invalid.{}.{}",
                record.file_name,
                old.ino(),
                modified_nanoseconds(&old)
            ));
            let external = root.path().join("foreign-link");
            fs::hard_link(&installed.path, &external).unwrap();
            match kind {
                "unrelated" => fs::write(&retained, b"unrelated retention").unwrap(),
                "symlink" => std::os::unix::fs::symlink(&installed.path, &retained).unwrap(),
                _ => fs::hard_link(&installed.path, &retained).unwrap(),
            }
            let staged = stage(&layout, &record, &bytes);
            let verified = verify_staged(&record, ENGINE, COMPATIBILITY, &staged).unwrap();
            assert!(
                matches!(
                    layout.repair_install(&record, &verified, &staged),
                    Err(InstallError::ConflictingInstallation)
                ),
                "{kind}"
            );
            assert_eq!(fs::read(&installed.path).unwrap(), corrupt, "{kind}");
            assert_eq!(fs::read(&external).unwrap(), corrupt, "{kind}");
            assert!(
                staged.exists(),
                "rejected input remains owned by the caller"
            );
            if kind == "unrelated" {
                assert_eq!(fs::read(&retained).unwrap(), b"unrelated retention");
            } else if kind == "symlink" {
                assert!(
                    fs::symlink_metadata(&retained)
                        .unwrap()
                        .file_type()
                        .is_symlink()
                );
            } else {
                assert_eq!(fs::metadata(&retained).unwrap().nlink(), 3);
            }
        }
    }

    #[test]
    fn local_staging_preserves_existing_symlink_and_hardlink_without_touching_foreign_bytes() {
        use std::os::unix::fs::symlink;
        let root = tempfile::tempdir().unwrap();
        let layout = ModelLayout::new(root.path());
        let bytes = fixture_bytes(51864);
        let record = fixture(&bytes);
        let source = root.path().join("chosen.bin");
        fs::write(&source, &bytes).unwrap();
        fs::create_dir_all(layout.staging_directory()).unwrap();
        let foreign = root.path().join("foreign.bin");
        fs::write(&foreign, b"preserve").unwrap();
        let path = layout.partial_path(&record);
        symlink(&foreign, &path).unwrap();
        let independent = layout.stage_from_file(&record, &source).unwrap();
        assert_ne!(independent.path(), path);
        drop(independent);
        assert!(
            fs::symlink_metadata(&path)
                .unwrap()
                .file_type()
                .is_symlink()
        );
        assert_eq!(fs::read(&foreign).unwrap(), b"preserve");
        fs::remove_file(&path).unwrap();
        fs::hard_link(&foreign, &path).unwrap();
        let independent = layout.stage_from_file(&record, &source).unwrap();
        assert_ne!(independent.path(), path);
        drop(independent);
        assert_eq!(fs::metadata(&path).unwrap().nlink(), 2);
        assert_eq!(fs::read(&foreign).unwrap(), b"preserve");
        assert!(path.exists());
    }

    #[test]
    fn partials_resume_only_when_every_validator_and_identity_agree() {
        let bytes = fixture_bytes(51864);
        let record = fixture(&bytes);
        let current = TransferValidator {
            url: record.download_origins[0].clone(),
            etag: Some("\"abc\"".into()),
            last_modified: None,
            expected_length: record.byte_length,
            manifest_sha256: record.sha256.clone(),
        };
        assert_eq!(
            resume_decision(&record, Some(&current), &current, 10),
            ResumeDecision::Resume { offset: 10 }
        );
        assert_eq!(
            resume_decision(&record, None, &current, 10),
            ResumeDecision::Restart
        );
        assert_eq!(
            resume_decision(&record, Some(&current), &current, 0),
            ResumeDecision::Restart
        );
        assert_eq!(
            resume_decision(&record, Some(&current), &current, record.byte_length),
            ResumeDecision::Restart
        );

        let changed_etag = TransferValidator {
            etag: Some("\"def\"".into()),
            ..current.clone()
        };
        assert_eq!(
            resume_decision(&record, Some(&current), &changed_etag, 10),
            ResumeDecision::Restart
        );
        let no_validators = TransferValidator {
            etag: None,
            ..current.clone()
        };
        assert_eq!(
            resume_decision(&record, Some(&no_validators), &no_validators, 10),
            ResumeDecision::Restart
        );
        let foreign_url = TransferValidator {
            url: "https://example.invalid/other".into(),
            ..current.clone()
        };
        assert_eq!(
            resume_decision(&record, Some(&foreign_url), &foreign_url, 10),
            ResumeDecision::Restart
        );
        let wrong_length = TransferValidator {
            expected_length: 1,
            ..current
        };
        assert_eq!(
            resume_decision(&record, Some(&wrong_length), &wrong_length, 10),
            ResumeDecision::Restart
        );
    }

    #[test]
    fn quarantine_moves_an_installed_version_and_leaves_a_recording_in_place() {
        let root = tempfile::tempdir().unwrap();
        let layout = ModelLayout::new(root.path());
        let bytes = fixture_bytes(51864);
        let record = fixture(&bytes);
        let staged = stage(&layout, &record, &bytes);
        let verified = verify_staged(&record, ENGINE, COMPATIBILITY, &staged).unwrap();
        layout.install(&record, &verified, &staged).unwrap();
        let installed = layout.installed_path(&record);
        let recording = root.path().join("Sessions/s/audio/mic/000000-0.caf");
        fs::create_dir_all(recording.parent().unwrap()).unwrap();
        fs::write(&recording, b"recording-bytes").unwrap();

        let removed = layout.quarantine_installed(&record).unwrap();
        assert!(!installed.exists());
        assert!(
            removed
                .directory
                .starts_with(root.path().join("Models/.removed"))
        );
        assert_eq!(
            fs::read(removed.directory.join(&record.file_name)).unwrap(),
            bytes
        );
        assert_eq!(fs::read(&recording).unwrap(), b"recording-bytes");
        assert!(matches!(
            layout.quarantine_installed(&record),
            Err(InstallError::NotInstalled)
        ));

        let outside = root.path().join("outside-model");
        fs::create_dir_all(&outside).unwrap();
        fs::write(outside.join(&record.file_name), b"keep-me").unwrap();
        fs::create_dir_all(layout.install_directory(&record).parent().unwrap()).unwrap();
        std::os::unix::fs::symlink(&outside, layout.install_directory(&record)).unwrap();
        assert!(matches!(
            layout.quarantine_installed(&record),
            Err(InstallError::NotOwnedDirectory)
        ));
        assert_eq!(
            fs::read(outside.join(&record.file_name)).unwrap(),
            b"keep-me"
        );
    }

    #[test]
    fn discarding_a_missing_partial_is_not_an_error() {
        let root = tempfile::tempdir().unwrap();
        let layout = ModelLayout::new(root.path());
        let record = fixture(&fixture_bytes(51864));
        layout.discard_partial(&record).unwrap();
        let staged = stage(&layout, &record, b"partial");
        layout.discard_partial(&record).unwrap();
        assert!(!staged.exists());
    }

    #[test]
    fn local_install_restarts_after_an_interrupted_copy_without_removing_prior_bytes() {
        let root = tempfile::tempdir().unwrap();
        let layout = ModelLayout::new(root.path());
        let bytes = fixture_bytes(51864);
        let record = fixture(&bytes);
        let abandoned = stage(&layout, &record, b"interrupted copy");
        let source = root.path().join("chosen.bin");
        fs::write(&source, &bytes).unwrap();

        let reopened = ModelLayout::new(root.path());
        let staged = reopened.stage_from_file(&record, &source).unwrap();
        let interrupted_attempt = staged.path().to_path_buf();
        // A killed process does not run Drop. Its independently owned bytes
        // must not block a later attempt, or be mistaken for that attempt.
        std::mem::forget(staged);
        let staged = reopened.stage_from_file(&record, &source).unwrap();
        assert_ne!(staged.path(), interrupted_attempt);
        let verified = verify_staged(&record, ENGINE, COMPATIBILITY, staged.path()).unwrap();
        reopened
            .install_local(&record, &verified, &staged, false)
            .unwrap();
        assert_eq!(fs::read(&abandoned).unwrap(), b"interrupted copy");
        assert_eq!(fs::read(&interrupted_attempt).unwrap(), bytes);
        assert_eq!(fs::read(reopened.installed_path(&record)).unwrap(), bytes);
        assert_eq!(fs::read(&source).unwrap(), bytes);
    }

    #[test]
    fn a_chosen_file_is_staged_verified_and_installed_without_changing_it() {
        let root = tempfile::tempdir().unwrap();
        let layout = ModelLayout::new(root.path());
        let bytes = fixture_bytes(51864);
        let record = fixture(&bytes);
        let chosen = root.path().join("Downloads-ggml.bin");
        fs::write(&chosen, &bytes).unwrap();

        let staged = layout.stage_from_file(&record, &chosen).unwrap();
        assert_ne!(staged.path(), layout.partial_path(&record));
        let verified = verify_staged(&record, ENGINE, COMPATIBILITY, staged.path()).unwrap();
        let installed = layout
            .install_local(&record, &verified, &staged, false)
            .unwrap();
        assert_eq!(fs::read(&installed.path).unwrap(), bytes);
        assert_eq!(
            fs::read(&chosen).unwrap(),
            bytes,
            "the chosen file is unchanged"
        );

        let oversized = root.path().join("oversized.bin");
        let mut longer = bytes.clone();
        longer.extend_from_slice(&[0; 4096]);
        fs::write(&oversized, &longer).unwrap();
        let staged = layout.stage_from_file(&record, &oversized).unwrap();
        assert_eq!(
            fs::metadata(staged.path()).unwrap().len(),
            record.byte_length + 1
        );
        assert!(matches!(
            verify_staged(&record, ENGINE, COMPATIBILITY, staged.path()),
            Err(crate::VerifyError::Oversized { .. })
        ));
        assert!(matches!(
            layout.stage_from_file(&record, root.path()),
            Err(InstallError::NotRegularFile)
        ));
    }

    #[test]
    fn local_attempt_refuses_substitution_and_cleanup_preserves_replacement() {
        let root = tempfile::tempdir().unwrap();
        let layout = ModelLayout::new(root.path());
        let bytes = fixture_bytes(51864);
        let record = fixture(&bytes);
        let source = root.path().join("chosen.bin");
        fs::write(&source, &bytes).unwrap();
        let staged = layout.stage_from_file(&record, &source).unwrap();
        let verified = verify_staged(&record, ENGINE, COMPATIBILITY, staged.path()).unwrap();
        let path = staged.path().to_path_buf();
        fs::remove_file(&path).unwrap();
        fs::write(&path, b"foreign replacement").unwrap();
        assert!(matches!(
            layout.install_local(&record, &verified, &staged, true),
            Err(InstallError::ChangedSinceVerification)
        ));
        drop(staged);
        assert_eq!(fs::read(path).unwrap(), b"foreign replacement");
        assert!(!layout.installed_path(&record).exists());
    }

    #[test]
    fn prepare_download_partial_truncates_a_regular_file_and_leaves_links_untouched() {
        use std::os::unix::fs::symlink;
        let root = tempfile::tempdir().unwrap();
        let layout = ModelLayout::new(root.path());
        let record = fixture(&fixture_bytes(51864));
        let path = layout.partial_path(&record);
        fs::create_dir_all(path.parent().unwrap()).unwrap();
        fs::write(&path, b"stale partial").unwrap();
        let prepared = layout.prepare_download_partial(&record).unwrap();
        assert_eq!(prepared.path, path);
        assert_eq!(prepared.length, 0);
        assert_eq!(fs::metadata(&path).unwrap().len(), 0);
        assert_eq!(fs::metadata(&path).unwrap().nlink(), 1);

        let foreign = root.path().join("foreign.bin");
        fs::write(&foreign, b"preserve").unwrap();
        fs::remove_file(&path).unwrap();
        symlink(&foreign, &path).unwrap();
        assert!(matches!(
            layout.prepare_download_partial(&record),
            Err(InstallError::NotRegularFile)
        ));
        assert!(
            fs::symlink_metadata(&path)
                .unwrap()
                .file_type()
                .is_symlink()
        );
        assert_eq!(fs::read(&foreign).unwrap(), b"preserve");

        fs::remove_file(&path).unwrap();
        fs::hard_link(&foreign, &path).unwrap();
        assert!(matches!(
            layout.prepare_download_partial(&record),
            Err(InstallError::NotRegularFile)
        ));
        assert_eq!(fs::metadata(&path).unwrap().nlink(), 2);
        assert_eq!(fs::read(&foreign).unwrap(), b"preserve");
        assert_eq!(fs::read(&path).unwrap(), b"preserve");
    }
}
