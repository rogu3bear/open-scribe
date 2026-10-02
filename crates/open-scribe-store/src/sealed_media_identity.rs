//! A mount's device number is transient; sealed content and inode stay binding.
use super::*;
use std::os::unix::fs::MetadataExt;

/// Timestamp-bound identity of the descriptor being validated, never atime.
pub(super) type MediaIdentity = (u64, u64, u64, i64, i64, i64, i64);

pub(super) fn media_identity(file: &File) -> Result<MediaIdentity, StoreError> {
    let metadata = file.metadata()?;
    Ok((
        metadata.dev(),
        metadata.ino(),
        metadata.len(),
        metadata.mtime(),
        metadata.mtime_nsec(),
        metadata.ctime(),
        metadata.ctime_nsec(),
    ))
}

impl ValidatedMediaFile {
    /// Only callers with durable sealed evidence use this rule. A changed
    /// mount number requires the full recorded digest, exact length, and the
    /// original inode; copying/replacing a file never acquires its identity.
    /// Writers and unsealed recovery continue to compare device and inode.
    pub(super) fn matches_sealed_identity(
        &self,
        expected_device: u64,
        expected_inode: u64,
        expected_length: u64,
        expected_digest: &str,
    ) -> bool {
        expected_device != 0
            && expected_inode != 0
            && self.inode == expected_inode
            && self.byte_length == expected_length
            && (self.device == expected_device
                || (expected_digest.len() == 64
                    && self.digest_sha256.as_deref() == Some(expected_digest)))
    }
}

impl SessionStore {
    #[cfg(test)]
    pub(super) fn run_media_validation_hook(&self) {
        let hook = self.media_validation_hook.borrow_mut().take();
        if let Some(hook) = hook {
            hook();
        }
    }
}
