use crate::catalog::{ModelHeader, ModelRecord};
use sha2::{Digest, Sha256};
use std::fmt;
use std::fs::{File, OpenOptions};
use std::io::{self, Read};
use std::os::unix::fs::{MetadataExt, OpenOptionsExt};
use std::path::Path;

const HEADER_BYTES: usize = 48;
const READ_CHUNK: usize = 1 << 20;

/// Identity of the exact file that passed verification. Installation
/// re-checks it so a replaced staging file is never renamed into place.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct VerifiedArtifact {
    pub model_id: String,
    pub version: String,
    pub sha256: String,
    pub byte_length: u64,
    pub(crate) device: u64,
    pub(crate) inode: u64,
    pub(crate) modified_nanoseconds: i128,
}

#[derive(Debug)]
pub enum VerifyError {
    NotRegularFile,
    Truncated { expected: u64, actual: u64 },
    Oversized { expected: u64, actual: u64 },
    NotGgml,
    WrongModel,
    IncompatibleEngine,
    DigestMismatch,
    ChangedDuringRead,
    Io(io::Error),
}

impl VerifyError {
    /// Stable, content-free diagnostic class.
    pub const fn class(&self) -> &'static str {
        match self {
            Self::NotRegularFile => "not_regular_file",
            Self::Truncated { .. } => "truncated",
            Self::Oversized { .. } => "oversized",
            Self::NotGgml => "not_ggml",
            Self::WrongModel => "wrong_model",
            Self::IncompatibleEngine => "incompatible_engine",
            Self::DigestMismatch => "digest_mismatch",
            Self::ChangedDuringRead => "changed_during_read",
            Self::Io(_) => "io",
        }
    }
}

impl fmt::Display for VerifyError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "model verification failed: {}", self.class())
    }
}

impl std::error::Error for VerifyError {}

/// Verifies completed staged bytes against one catalog record and the
/// running engine's declared compatibility. The file is read, never mapped
/// or loaded.
pub fn verify_staged(
    record: &ModelRecord,
    engine: &str,
    engine_compatibility: &str,
    path: &Path,
) -> Result<VerifiedArtifact, VerifyError> {
    if record.engine != engine || record.compatibility != engine_compatibility {
        return Err(VerifyError::IncompatibleEngine);
    }
    let mut file = open_no_follow(path).map_err(VerifyError::Io)?;
    let before = file.metadata().map_err(VerifyError::Io)?;
    if !before.file_type().is_file() {
        return Err(VerifyError::NotRegularFile);
    }
    check_length(record.byte_length, before.len())?;

    let mut hasher = Sha256::new();
    let mut header = Vec::with_capacity(HEADER_BYTES);
    let mut buffer = vec![0_u8; READ_CHUNK];
    let mut total = 0_u64;
    loop {
        let read = file.read(&mut buffer).map_err(VerifyError::Io)?;
        if read == 0 {
            break;
        }
        if header.len() < HEADER_BYTES {
            let take = (HEADER_BYTES - header.len()).min(read);
            header.extend_from_slice(&buffer[..take]);
        }
        hasher.update(&buffer[..read]);
        total += read as u64;
    }
    let after = file.metadata().map_err(VerifyError::Io)?;
    if total != before.len() || !same_file_state(&before, &after) {
        return Err(VerifyError::ChangedDuringRead);
    }
    check_header(&record.header, &header)?;
    let digest = hex(&hasher.finalize());
    if digest != record.sha256 {
        return Err(VerifyError::DigestMismatch);
    }
    Ok(VerifiedArtifact {
        model_id: record.id.clone(),
        version: record.version.clone(),
        sha256: digest,
        byte_length: total,
        device: after.dev(),
        inode: after.ino(),
        modified_nanoseconds: modified_nanoseconds(&after),
    })
}

fn check_length(expected: u64, actual: u64) -> Result<(), VerifyError> {
    match actual.cmp(&expected) {
        std::cmp::Ordering::Less => Err(VerifyError::Truncated { expected, actual }),
        std::cmp::Ordering::Greater => Err(VerifyError::Oversized { expected, actual }),
        std::cmp::Ordering::Equal => Ok(()),
    }
}

fn check_header(expected: &ModelHeader, bytes: &[u8]) -> Result<(), VerifyError> {
    if bytes.len() < HEADER_BYTES {
        return Err(VerifyError::NotGgml);
    }
    let field = |index: usize| {
        let start = index * 4;
        i32::from_le_bytes(
            bytes[start..start + 4]
                .try_into()
                .expect("four header bytes"),
        )
    };
    if field(0) as u32 != expected.magic {
        return Err(VerifyError::NotGgml);
    }
    let actual = ModelHeader {
        magic: field(0) as u32,
        n_vocab: field(1),
        n_audio_ctx: field(2),
        n_audio_state: field(3),
        n_audio_head: field(4),
        n_audio_layer: field(5),
        n_text_ctx: field(6),
        n_text_state: field(7),
        n_text_head: field(8),
        n_text_layer: field(9),
        n_mels: field(10),
        ftype: field(11),
    };
    if actual != *expected {
        return Err(VerifyError::WrongModel);
    }
    Ok(())
}

pub(crate) fn open_no_follow(path: &Path) -> io::Result<File> {
    OpenOptions::new()
        .read(true)
        .custom_flags(rustix::fs::OFlags::NOFOLLOW.bits() as i32)
        .open(path)
}

pub(crate) fn same_file_state(left: &std::fs::Metadata, right: &std::fs::Metadata) -> bool {
    left.dev() == right.dev()
        && left.ino() == right.ino()
        && left.len() == right.len()
        && modified_nanoseconds(left) == modified_nanoseconds(right)
}

pub(crate) fn modified_nanoseconds(metadata: &std::fs::Metadata) -> i128 {
    i128::from(metadata.mtime()) * 1_000_000_000 + i128::from(metadata.mtime_nsec())
}

fn hex(bytes: &[u8]) -> String {
    use fmt::Write;
    bytes
        .iter()
        .fold(String::with_capacity(bytes.len() * 2), |mut out, byte| {
            let _ = write!(out, "{byte:02x}");
            out
        })
}

#[cfg(test)]
pub(crate) mod tests {
    use super::*;

    pub(crate) const ENGINE: &str = "whisper.cpp";
    pub(crate) const COMPATIBILITY: &str = "test-loader";

    /// A catalog record describing `bytes`, with a real Whisper-shaped header.
    pub(crate) fn fixture(bytes: &[u8]) -> ModelRecord {
        ModelRecord {
            id: "fixture-model".into(),
            profile: "fixture".into(),
            version: "1.0.0".into(),
            purpose: "asr".into(),
            revision: "fixture".into(),
            license: "MIT".into(),
            engine: ENGINE.into(),
            format: "ggml-whisper".into(),
            compatibility: COMPATIBILITY.into(),
            header: header_of(bytes),
            languages: vec!["en".into()],
            file_name: "fixture.bin".into(),
            download_origins: vec!["https://example.invalid/fixture.bin".into()],
            removal_group: "asr".into(),
            sha256: hex(&Sha256::digest(bytes)),
            byte_length: bytes.len() as u64,
            bundled: false,
        }
    }

    pub(crate) fn fixture_bytes(n_vocab: i32) -> Vec<u8> {
        let fields = [
            0x6767_6d6c_u32 as i32,
            n_vocab,
            1500,
            384,
            6,
            4,
            448,
            384,
            6,
            4,
            80,
            1009,
        ];
        let mut bytes: Vec<u8> = fields
            .iter()
            .flat_map(|field| field.to_le_bytes())
            .collect();
        bytes.extend((0..4096_u32).map(|index| (index % 251) as u8));
        bytes
    }

    fn header_of(bytes: &[u8]) -> ModelHeader {
        let field =
            |index: usize| i32::from_le_bytes(bytes[index * 4..index * 4 + 4].try_into().unwrap());
        ModelHeader {
            magic: field(0) as u32,
            n_vocab: field(1),
            n_audio_ctx: field(2),
            n_audio_state: field(3),
            n_audio_head: field(4),
            n_audio_layer: field(5),
            n_text_ctx: field(6),
            n_text_state: field(7),
            n_text_head: field(8),
            n_text_layer: field(9),
            n_mels: field(10),
            ftype: field(11),
        }
    }

    fn verify(record: &ModelRecord, bytes: &[u8]) -> Result<VerifiedArtifact, VerifyError> {
        let root = tempfile::tempdir().unwrap();
        let path = root.path().join("model.part");
        std::fs::write(&path, bytes).unwrap();
        verify_staged(record, ENGINE, COMPATIBILITY, &path)
    }

    #[test]
    fn exact_bytes_verify_and_every_adr_failure_class_is_distinct() {
        let bytes = fixture_bytes(51864);
        let record = fixture(&bytes);
        let verified = verify(&record, &bytes).unwrap();
        assert_eq!(
            (verified.byte_length, verified.sha256.as_str()),
            (bytes.len() as u64, record.sha256.as_str())
        );

        assert!(matches!(
            verify(&record, &bytes[..bytes.len() - 1]),
            Err(VerifyError::Truncated { .. })
        ));
        let mut longer = bytes.clone();
        longer.push(0);
        assert!(matches!(
            verify(&record, &longer),
            Err(VerifyError::Oversized { .. })
        ));

        let mut flipped = bytes.clone();
        *flipped.last_mut().unwrap() ^= 1;
        assert!(matches!(
            verify(&record, &flipped),
            Err(VerifyError::DigestMismatch)
        ));

        let mut not_ggml = bytes.clone();
        not_ggml[0] = b'P';
        assert!(matches!(
            verify(&record, &not_ggml),
            Err(VerifyError::NotGgml)
        ));

        let other_model = fixture_bytes(51865);
        assert!(matches!(
            verify(&record, &other_model),
            Err(VerifyError::WrongModel)
        ));

        let root = tempfile::tempdir().unwrap();
        assert!(matches!(
            verify_staged(&record, ENGINE, "another-loader", root.path()),
            Err(VerifyError::IncompatibleEngine)
        ));
        assert!(matches!(
            verify_staged(&record, ENGINE, COMPATIBILITY, root.path()),
            Err(VerifyError::NotRegularFile)
        ));
    }

    #[test]
    fn symlinked_staging_files_are_refused() {
        let bytes = fixture_bytes(51864);
        let record = fixture(&bytes);
        let root = tempfile::tempdir().unwrap();
        let target = root.path().join("real.bin");
        std::fs::write(&target, &bytes).unwrap();
        let link = root.path().join("model.part");
        std::os::unix::fs::symlink(&target, &link).unwrap();
        assert!(matches!(
            verify_staged(&record, ENGINE, COMPATIBILITY, &link),
            Err(VerifyError::Io(_))
        ));
    }
}
