//! Storage policy for capture.
//!
//! Two floors protect a recording. The capture floor (`RESERVE_BYTES`) is free
//! space sealing and recovery may spend; opening another source segment under
//! critical pressure never does. The emergency reserve is physically allocated
//! space for journaling and sealing after ENOSPC. Only explicit capture
//! preparation replenishes it; opening/recovering a library must leave
//! released space available.
use super::*;

/// Below this free space the volume is critical for capture.
pub(crate) const RESERVE_BYTES: u64 = 512 * 1024 * 1024;
/// Below this free space a recording continues with a visible warning.
pub(crate) const WARNING_BYTES: u64 = 1024 * 1024 * 1024;
/// The allocated emergency reserve, released before journaling at ENOSPC.
pub(crate) const EMERGENCY_RESERVE_BYTES: u64 = 16 * 1024 * 1024;
/// A preparing or paused capture must have room for this much new audio.
const PREFLIGHT_SECONDS: u64 = 5 * 60;

const NAME: &str = ".capture-journal-reserve-v1";
const MAGIC: &[u8] = b"Open Scribe emergency journal reserve v1\n";

/// The capture floor plus `PREFLIGHT_SECONDS` of 16-bit PCM for each source.
pub(crate) fn preflight_bytes(sources: impl IntoIterator<Item = MediaSourceKind>) -> u64 {
    let pcm_bytes: u64 = sources
        .into_iter()
        .map(|kind| {
            u64::from(capture_channels(kind))
                * u64::from(MEDIA_SAMPLE_RATE_HZ)
                * 2
                * PREFLIGHT_SECONDS
        })
        .sum();
    RESERVE_BYTES + pcm_bytes
}

impl SessionStore {
    pub(super) fn prepare_storage_reserve(&self) -> Result<(), StoreError> {
        let mut file = self
            .open_storage_reserve(true)?
            .ok_or(StoreError::InvalidState(
                "capture emergency reserve could not be created",
            ))?;
        // Actual writes, not set_len: a sparse file cannot free emergency blocks.
        file.seek(std::io::SeekFrom::Start(MAGIC.len() as u64))?;
        let block = [0xa5; 64 * 1024];
        let allocation = (|| -> std::io::Result<()> {
            let mut remaining = EMERGENCY_RESERVE_BYTES - MAGIC.len() as u64;
            while remaining > 0 {
                let count = remaining.min(block.len() as u64) as usize;
                file.write_all(&block[..count])?;
                remaining -= count as u64;
            }
            file.sync_all()
        })();
        if let Err(error) = allocation {
            // No session has been created. Return a partial allocation too;
            // truncation itself can need unavailable APFS metadata space.
            drop(file);
            self.release_storage_reserve()?;
            return Err(StoreError::Io(error));
        }
        Ok(())
    }

    pub(super) fn release_storage_reserve(&self) -> Result<(), StoreError> {
        if let Some(file) = self.open_storage_reserve(false)? {
            // On a fully exhausted APFS volume even truncate-to-zero can fail
            // with ENOSPC. Unlink the validated owned allocation, close its last
            // descriptor, then sync the directory before journaling. Missing
            // reserves are allowed for released or pre-policy libraries.
            let root = open_managed_directory(&self.managed_root)?;
            let opened = fd_fs::fstat(&file).map_err(std::io::Error::from)?;
            let named = fd_fs::statat(&root, NAME, fd_fs::AtFlags::SYMLINK_NOFOLLOW)
                .map_err(std::io::Error::from)?;
            if opened.st_dev != named.st_dev || opened.st_ino != named.st_ino || named.st_nlink != 1
            {
                return Err(StoreError::IntegrityMismatch(
                    "emergency reserve changed before release",
                ));
            }
            fd_fs::unlinkat(&root, NAME, fd_fs::AtFlags::empty()).map_err(std::io::Error::from)?;
            drop(file);
            fd_fs::fsync(&root).map_err(std::io::Error::from)?;
        }
        Ok(())
    }

    fn open_storage_reserve(&self, create: bool) -> Result<Option<File>, StoreError> {
        let root = open_managed_directory(&self.managed_root)?;
        let flags = fd_fs::OFlags::RDWR | fd_fs::OFlags::CLOEXEC | fd_fs::OFlags::NOFOLLOW;
        let mut created = false;
        let fd = match fd_fs::openat(&root, NAME, flags, fd_fs::Mode::empty()) {
            Ok(fd) => fd,
            Err(rustix::io::Errno::NOENT) if create => {
                let fd = fd_fs::openat(
                    &root,
                    NAME,
                    flags | fd_fs::OFlags::CREATE | fd_fs::OFlags::EXCL,
                    fd_fs::Mode::RUSR | fd_fs::Mode::WUSR,
                )
                .map_err(std::io::Error::from)?;
                created = true;
                fd
            }
            Err(rustix::io::Errno::NOENT) => return Ok(None),
            Err(error) => return Err(StoreError::Io(error.into())),
        };
        let mut file = File::from(fd);
        let stat = fd_fs::fstat(&file).map_err(std::io::Error::from)?;
        if fd_fs::FileType::from_raw_mode(stat.st_mode) != fd_fs::FileType::RegularFile
            || stat.st_nlink != 1
        {
            return Err(StoreError::IntegrityMismatch(
                "emergency reserve is not an owned regular file",
            ));
        }
        if created {
            file.write_all(MAGIC)?;
            file.sync_all()?;
            fd_fs::fsync(&root).map_err(std::io::Error::from)?;
        } else {
            let mut header = vec![0; MAGIC.len()];
            file.read_exact(&mut header)?;
            if header != MAGIC
                || stat.st_size < MAGIC.len() as i64
                || stat.st_size > EMERGENCY_RESERVE_BYTES as i64
            {
                return Err(StoreError::IntegrityMismatch(
                    "emergency reserve ownership is invalid",
                ));
            }
        }
        Ok(Some(file))
    }
}
