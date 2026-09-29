//! Physically allocated emergency space for journaling and sealing after ENOSPC.
//! Only explicit capture preparation replenishes it; opening/recovering a library
//! must leave released space available. The ordinary capture floor stays intact.
use super::*;

const NAME: &str = ".capture-journal-reserve-v1";
const MAGIC: &[u8] = b"Open Scribe emergency journal reserve v1\n";
const BYTES: u64 = 16 * 1024 * 1024;

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
            let mut remaining = BYTES - MAGIC.len() as u64;
            while remaining > 0 {
                let count = remaining.min(block.len() as u64) as usize;
                file.write_all(&block[..count])?;
                remaining -= count as u64;
            }
            file.sync_all()
        })();
        if let Err(error) = allocation {
            // No session has been created. Retain ownership but return the
            // partial allocation so a failed preparation cannot consume it.
            file.set_len(MAGIC.len() as u64)?;
            file.sync_all()?;
            return Err(StoreError::Io(error));
        }
        Ok(())
    }

    pub(super) fn release_storage_reserve(&self) -> Result<(), StoreError> {
        if let Some(file) = self.open_storage_reserve(false)? {
            // Retain the validated header, not the blocks. Missing reserves are
            // allowed for libraries created before this policy was implemented.
            file.set_len(MAGIC.len() as u64)?;
            file.sync_all()?;
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
            if header != MAGIC || stat.st_size < MAGIC.len() as i64 || stat.st_size > BYTES as i64 {
                return Err(StoreError::IntegrityMismatch(
                    "emergency reserve ownership is invalid",
                ));
            }
        }
        Ok(Some(file))
    }
}
