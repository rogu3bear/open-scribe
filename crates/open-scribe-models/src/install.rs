use crate::catalog::ModelRecord;
use crate::verify::{VerifiedArtifact, modified_nanoseconds, open_no_follow};
use sha2::{Digest, Sha256};
use std::fmt;
use std::fs::{self, File, OpenOptions};
use std::io::{self, Read};
use std::os::unix::fs::{MetadataExt, OpenOptionsExt};
use std::path::{Path, PathBuf};

const MODELS_DIRECTORY: &str = "Models";
const STAGING_DIRECTORY: &str = ".staging";

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

#[derive(Debug)]
pub enum InstallError {
    RecordMismatch,
    NotRegularFile,
    NotStagingPath,
    ChangedSinceVerification,
    ConflictingInstallation,
    StagingExists,
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
        self.install_checked(record, verified, staged, false)
    }

    /// Explicit repair retains the old invalid inode in the owned directory.
    /// A foreign, redirected, or multiply-linked destination is never replaced.
    pub fn repair_install(
        &self,
        record: &ModelRecord,
        verified: &VerifiedArtifact,
        staged: &Path,
    ) -> Result<InstalledArtifact, InstallError> {
        self.install_checked(record, verified, staged, true)
    }

    fn install_checked(
        &self,
        record: &ModelRecord,
        verified: &VerifiedArtifact,
        staged: &Path,
        repair: bool,
    ) -> Result<InstalledArtifact, InstallError> {
        if verified.model_id != record.id
            || verified.version != record.version
            || verified.sha256 != record.sha256
            || verified.byte_length != record.byte_length
        {
            return Err(InstallError::RecordMismatch);
        }
        if staged != self.partial_path(record) {
            return Err(InstallError::NotStagingPath);
        }
        let file = open_no_follow(staged)?;
        let metadata = file.metadata()?;
        if metadata.dev() != verified.device
            || metadata.ino() != verified.inode
            || metadata.len() != verified.byte_length
            || modified_nanoseconds(&metadata) != verified.modified_nanoseconds
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
                if !existing.is_file()
                    || existing.nlink() != 1
                    || existing.uid() != fs::metadata(self.models.parent().unwrap())?.uid()
                {
                    return Err(InstallError::ConflictingInstallation);
                }
                let mut prior = open_no_follow(&destination)?;
                let mut digest = Sha256::new();
                io::copy(&mut prior, &mut digest)?;
                let unchanged = prior.metadata()?.len() == existing.len()
                    && modified_nanoseconds(&prior.metadata()?) == modified_nanoseconds(&existing);
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
                let retained = directory.join(format!(
                    "{}.invalid.{}.{}",
                    record.file_name,
                    existing.ino(),
                    modified_nanoseconds(&existing)
                ));
                // create-new hard link retains evidence before unlinking only
                // the owned destination. A prior retained name refuses repair.
                fs::hard_link(&destination, &retained)?;
                sync_directory(&directory)?;
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

    /// Copies a user-chosen local file into this record's staging path for
    /// verification. The source is only read. The copy stops one byte past
    /// the manifest length, so an oversized file fails verification without
    /// being staged whole. Nothing here loads the bytes.
    pub fn stage_from_file(
        &self,
        record: &ModelRecord,
        source: &Path,
    ) -> Result<PathBuf, InstallError> {
        let input = File::open(source)?;
        if !input.metadata()?.is_file() {
            return Err(InstallError::NotRegularFile);
        }
        self.ensure_owned_directory(&self.staging_directory())?;
        let staged = self.partial_path(record);
        let mut output = OpenOptions::new()
            .write(true)
            .create_new(true)
            .custom_flags(rustix::fs::OFlags::NOFOLLOW.bits() as i32)
            .open(&staged)
            .map_err(|error| {
                if error.kind() == io::ErrorKind::AlreadyExists {
                    InstallError::StagingExists
                } else {
                    error.into()
                }
            })?;
        let identity = output.metadata()?;
        let result = (|| -> io::Result<()> {
            io::copy(&mut input.take(record.byte_length + 1), &mut output)?;
            output.sync_all()?;
            sync_directory(&self.staging_directory())
        })();
        if let Err(error) = result {
            let _ = self.discard_owned_partial(record, identity.dev(), identity.ino());
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
        let path = self.partial_path(record);
        match fs::symlink_metadata(&path) {
            Ok(metadata)
                if metadata.is_file()
                    && metadata.nlink() == 1
                    && metadata.dev() == device
                    && metadata.ino() == inode =>
            {
                fs::remove_file(path)?;
                sync_directory(&self.staging_directory())
            }
            Err(error) if error.kind() == io::ErrorKind::NotFound => Ok(()),
            Ok(_) => Err(io::Error::other("staging ownership changed")),
            Err(error) => Err(error),
        }
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
    fn staging_refuses_existing_symlink_and_hardlink_without_touching_foreign_bytes() {
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
        assert!(matches!(
            layout.stage_from_file(&record, &source),
            Err(InstallError::StagingExists)
        ));
        assert_eq!(fs::read(&foreign).unwrap(), b"preserve");
        fs::remove_file(&path).unwrap();
        fs::hard_link(&foreign, &path).unwrap();
        assert!(matches!(
            layout.stage_from_file(&record, &source),
            Err(InstallError::StagingExists)
        ));
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
    fn a_chosen_file_is_staged_verified_and_installed_without_changing_it() {
        let root = tempfile::tempdir().unwrap();
        let layout = ModelLayout::new(root.path());
        let bytes = fixture_bytes(51864);
        let record = fixture(&bytes);
        let chosen = root.path().join("Downloads-ggml.bin");
        fs::write(&chosen, &bytes).unwrap();

        let staged = layout.stage_from_file(&record, &chosen).unwrap();
        assert_eq!(staged, layout.partial_path(&record));
        let verified = verify_staged(&record, ENGINE, COMPATIBILITY, &staged).unwrap();
        let installed = layout.install(&record, &verified, &staged).unwrap();
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
        assert_eq!(fs::metadata(&staged).unwrap().len(), record.byte_length + 1);
        assert!(matches!(
            verify_staged(&record, ENGINE, COMPATIBILITY, &staged),
            Err(crate::VerifyError::Oversized { .. })
        ));
        assert!(matches!(
            layout.stage_from_file(&record, root.path()),
            Err(InstallError::NotRegularFile)
        ));
    }
}
