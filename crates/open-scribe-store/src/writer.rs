//! One short durable mutation at a time across handles and processes. The
//! advisory lock spans journal read/replace and SQLite projection together.
//! It is reentrant only on the owning thread; no compute job owns this guard.
use super::StoreError;
use std::cell::RefCell;
use std::collections::BTreeMap;
use std::fs::{File, OpenOptions};
use std::marker::PhantomData;
use std::os::unix::fs::{MetadataExt, OpenOptionsExt};
use std::path::{Path, PathBuf};
use std::rc::Rc;

thread_local! {
    static HELD: RefCell<BTreeMap<PathBuf, (File, usize)>> = const { RefCell::new(BTreeMap::new()) };
}

pub(super) struct WriterGuard {
    root: PathBuf,
    _thread: PhantomData<Rc<()>>,
}

impl WriterGuard {
    pub(super) fn acquire(root: &Path) -> Result<Self, StoreError> {
        let root = root.canonicalize()?;
        HELD.with(|held| -> Result<(), StoreError> {
            let mut held = held.borrow_mut();
            if let Some((_, depth)) = held.get_mut(&root) {
                *depth += 1;
                return Ok(());
            }
            let file = OpenOptions::new()
                .read(true)
                .write(true)
                .create(true)
                .truncate(false)
                .mode(0o600)
                .custom_flags(rustix::fs::OFlags::NOFOLLOW.bits() as i32)
                .open(root.join(".writer-lock-v1"))?;
            let metadata = file.metadata()?;
            if !metadata.is_file() || metadata.nlink() != 1 || metadata.len() != 0 {
                return Err(StoreError::InvalidState("unsafe library writer lock"));
            }
            rustix::fs::flock(&file, rustix::fs::FlockOperation::LockExclusive)
                .map_err(std::io::Error::from)?;
            held.insert(root.clone(), (file, 1));
            Ok(())
        })?;
        Ok(Self {
            root,
            _thread: PhantomData,
        })
    }
}

impl Drop for WriterGuard {
    fn drop(&mut self) {
        HELD.with(|held| {
            let mut held = held.borrow_mut();
            if let Some((_, depth)) = held.get_mut(&self.root) {
                *depth -= 1;
                if *depth == 0 {
                    held.remove(&self.root);
                }
            }
        }); // last descriptor close releases flock, including on unwind
    }
}
