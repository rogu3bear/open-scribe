//! Managed directories and durable directory synchronization.

use super::*;

pub(crate) fn validate_or_create_managed_root(path: &Path) -> Result<(), StoreError> {
    if path.as_os_str().is_empty() {
        return Err(StoreError::InvalidManagedRoot("path is empty"));
    }
    if path.exists() {
        let metadata = fs::symlink_metadata(path)?;
        if metadata.file_type().is_symlink() || !metadata.is_dir() {
            return Err(StoreError::InvalidManagedRoot(
                "root must be a real directory",
            ));
        }
    } else {
        fs::create_dir_all(path)?;
    }
    Ok(())
}

pub(crate) fn create_directory_if_missing(path: &Path) -> Result<(), StoreError> {
    if path.exists() {
        let metadata = fs::symlink_metadata(path)?;
        if metadata.file_type().is_symlink() || !metadata.is_dir() {
            return Err(StoreError::InvalidManagedRoot(
                "managed child must be a real directory",
            ));
        }
    } else {
        fs::create_dir(path)?;
        if let Some(parent) = path.parent() {
            sync_directory(parent)?;
        }
    }
    Ok(())
}

pub(crate) fn require_real_directory(path: &Path) -> Result<(), StoreError> {
    let metadata = fs::symlink_metadata(path)?;
    if metadata.file_type().is_symlink() || !metadata.is_dir() {
        return Err(StoreError::InvalidManagedRoot(
            "managed child must remain a real directory",
        ));
    }
    Ok(())
}

pub(crate) fn directory_open_flags() -> fd_fs::OFlags {
    fd_fs::OFlags::RDONLY
        | fd_fs::OFlags::DIRECTORY
        | fd_fs::OFlags::CLOEXEC
        | fd_fs::OFlags::NOFOLLOW
}

pub(crate) fn open_managed_directory(path: &Path) -> Result<OwnedFd, StoreError> {
    fd_fs::open(path, directory_open_flags(), fd_fs::Mode::empty()).map_err(|_| {
        StoreError::IntegrityMismatch("managed media ancestor is missing, replaced, or symlinked")
    })
}

pub(crate) fn open_managed_directory_at(
    parent: &impl AsFd,
    name: &OsStr,
) -> Result<OwnedFd, StoreError> {
    fd_fs::openat(parent, name, directory_open_flags(), fd_fs::Mode::empty()).map_err(|_| {
        StoreError::IntegrityMismatch("managed media ancestor is missing, replaced, or symlinked")
    })
}

pub(crate) fn sync_directory(path: &Path) -> Result<(), StoreError> {
    File::open(path)?.sync_all()?;
    Ok(())
}
