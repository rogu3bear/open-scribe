//! Managed media files: CAF inspection and descriptor-bound validation.

use super::*;

/// The managed session layout. Every name below is on disk in existing
/// libraries.
pub(crate) const AUDIO_DIRECTORY: &str = "audio";
pub(crate) const EXPORTS_DIRECTORY: &str = "exports";
pub(crate) const SESSION_SUBDIRECTORIES: [&str; 4] =
    [AUDIO_DIRECTORY, "video", "context", EXPORTS_DIRECTORY];

/// Capture segment `sequence` in its track directory.
pub(crate) fn capture_segment_file(sequence: u64) -> String {
    format!("{sequence:06}-0.caf")
}

/// An imported file once staged; `suffix` is `caf` or `m4a`.
pub(crate) fn import_file(suffix: &str) -> String {
    format!("000000-import.{suffix}")
}

/// An imported file while its copy is in progress.
pub(crate) fn import_staging_file(suffix: &str) -> String {
    format!(".importing.{suffix}")
}

/// Session-relative path of a file in a track directory.
pub(crate) fn track_file_path(track_id: &str, file_name: &str) -> String {
    format!("{AUDIO_DIRECTORY}/{track_id}/{file_name}")
}

/// Session-relative path of a new mix.
pub(crate) fn mixdown_path(mix_id: &str) -> String {
    format!("{EXPORTS_DIRECTORY}/mix-{mix_id}.m4a")
}

/// Exact duration of `frames` frames at the capture rate. Every stored frame
/// count is at `MEDIA_SAMPLE_RATE_HZ`.
pub(crate) fn frames_to_nanoseconds(frames: u64) -> u128 {
    u128::from(frames) * 1_000_000_000 / u128::from(MEDIA_SAMPLE_RATE_HZ)
}

/// Duration of `frames` frames, saturating where a duration is only shown or
/// compared against a limit.
pub(crate) fn saturating_frames_to_nanoseconds(frames: u64) -> u64 {
    frames.saturating_mul(1_000_000_000) / u64::from(MEDIA_SAMPLE_RATE_HZ)
}

pub(crate) const MEDIA_FORMAT_CAF_PCM_S16LE: &str = "caf-pcm-s16le";

pub(crate) const CAF_HEADER: &[u8; 8] = b"caff\0\x01\0\0";

pub(crate) struct ValidatedMediaFile {
    pub(crate) file: File,
    pub(crate) identity: sealed_media_identity::MediaIdentity,
    pub(crate) byte_length: u64,
    pub(crate) device: u64,
    pub(crate) inode: u64,
    pub(crate) digest_sha256: Option<String>,
    pub(crate) recoverable_sample_count: Option<u64>,
    pub(crate) channels: Option<u16>,
}

pub(crate) struct CafInspection {
    pub(crate) channels: u16,
    pub(crate) sample_count: Option<u64>,
    /// Byte offset of the first interleaved frame.
    pub(crate) audio_offset: u64,
}

#[derive(Clone, Copy)]
pub(crate) enum MediaLengthRequirement {
    Exact(u64),
    AtLeast(u64),
}

pub(crate) fn inspect_pcm_caf(
    file: &mut File,
    byte_length: u64,
) -> Result<Option<CafInspection>, StoreError> {
    if byte_length < CAF_HEADER.len() as u64 + 12 {
        return Ok(None);
    }
    file.rewind()?;
    let mut header = [0_u8; 8];
    file.read_exact(&mut header)?;
    if &header != CAF_HEADER {
        return Ok(None);
    }

    let mut offset = CAF_HEADER.len() as u64;
    let mut descriptor_channels = None;
    while offset
        .checked_add(12)
        .is_some_and(|value| value <= byte_length)
    {
        file.seek(std::io::SeekFrom::Start(offset))?;
        let mut chunk_header = [0_u8; 12];
        file.read_exact(&mut chunk_header)?;
        let chunk_type = &chunk_header[..4];
        let chunk_size = i64::from_be_bytes(
            chunk_header[4..12]
                .try_into()
                .map_err(|_| StoreError::IntegrityMismatch("CAF chunk size is malformed"))?,
        );
        let payload_start = offset
            .checked_add(12)
            .ok_or(StoreError::IntegrityMismatch("CAF chunk offset overflowed"))?;

        if chunk_type == b"desc" {
            if chunk_size != 32 {
                return Ok(None);
            }
            let mut descriptor = [0_u8; 32];
            file.read_exact(&mut descriptor)?;
            let sample_rate =
                f64::from_bits(u64::from_be_bytes(descriptor[0..8].try_into().map_err(
                    |_| StoreError::IntegrityMismatch("CAF sample rate is malformed"),
                )?));
            let flags =
                u32::from_be_bytes(descriptor[12..16].try_into().map_err(|_| {
                    StoreError::IntegrityMismatch("CAF format flags are malformed")
                })?);
            let bytes_per_packet = u32::from_be_bytes(
                descriptor[16..20]
                    .try_into()
                    .map_err(|_| StoreError::IntegrityMismatch("CAF packet width is malformed"))?,
            );
            let frames_per_packet =
                u32::from_be_bytes(descriptor[20..24].try_into().map_err(|_| {
                    StoreError::IntegrityMismatch("CAF packet frame count is malformed")
                })?);
            let channels =
                u32::from_be_bytes(descriptor[24..28].try_into().map_err(|_| {
                    StoreError::IntegrityMismatch("CAF channel count is malformed")
                })?);
            let bits_per_channel = u32::from_be_bytes(
                descriptor[28..32]
                    .try_into()
                    .map_err(|_| StoreError::IntegrityMismatch("CAF sample width is malformed"))?,
            );
            let descriptor_matches = sample_rate == f64::from(MEDIA_SAMPLE_RATE_HZ)
                && &descriptor[8..12] == b"lpcm"
                && flags == 2
                && (channels == 1 || channels == 2)
                // CAF stores LPCM interleaved: one packet is one frame of
                // 16-bit samples for every channel.
                && bytes_per_packet == 2 * channels
                && frames_per_packet == 1
                && bits_per_channel == 16;
            descriptor_channels = descriptor_matches.then_some(channels as u16);
        }

        if chunk_type == b"data" {
            let Some(channels) = descriptor_channels else {
                return Ok(None);
            };
            if chunk_size < -1 {
                return Ok(None);
            }
            let chunk_end = if chunk_size == -1 {
                byte_length
            } else {
                let Some(chunk_end) = payload_start
                    .checked_add(chunk_size as u64)
                    .filter(|value| *value <= byte_length)
                else {
                    return Ok(None);
                };
                chunk_end
            };
            let audio_start = payload_start
                .checked_add(4)
                .ok_or(StoreError::IntegrityMismatch("CAF audio offset overflowed"))?;
            if audio_start > chunk_end {
                return Ok(None);
            }
            let audio_bytes = chunk_end - audio_start;
            let bytes_per_frame = 2 * u64::from(channels);
            if audio_bytes % bytes_per_frame != 0 {
                return Ok(None);
            }
            return Ok(Some(CafInspection {
                channels,
                sample_count: (audio_bytes > 0).then_some(audio_bytes / bytes_per_frame),
                audio_offset: audio_start,
            }));
        }

        if chunk_size < 0 {
            return Ok(None);
        }
        let Some(next_offset) = payload_start
            .checked_add(chunk_size as u64)
            .filter(|value| *value <= byte_length)
        else {
            return Ok(None);
        };
        offset = next_offset;
    }
    Ok(None)
}

pub(crate) fn valid_relative_path(relative_path: &str) -> bool {
    let path = Path::new(relative_path);
    !path.is_absolute()
        && path
            .components()
            .all(|component| matches!(component, Component::Normal(_) | Component::CurDir))
}

pub(crate) fn valid_media_relative_path(relative_path: &str) -> bool {
    valid_relative_path(relative_path)
        && relative_path.starts_with(&format!("{AUDIO_DIRECTORY}/"))
        && relative_path.ends_with(".caf")
        && Path::new(relative_path).components().count() == 3
}

impl SessionStore {
    pub(crate) fn validate_media_file(
        &self,
        session_id: &str,
        relative_path: &str,
        length_requirement: MediaLengthRequirement,
        calculate_digest: bool,
    ) -> Result<ValidatedMediaFile, StoreError> {
        self.validate_media_file_with(
            session_id,
            relative_path,
            length_requirement,
            calculate_digest,
            true,
            false,
        )
    }

    /// Reads sealed media without flushing it. Launch listing and the library
    /// snapshot use this. A digest already accepted for the UI snapshot is
    /// reused; promotion and leases keep `validate_media_file`, which still
    /// flushes and hashes on its own.
    pub(crate) fn observe_sealed_media_file(
        &self,
        session_id: &str,
        relative_path: &str,
        length_requirement: MediaLengthRequirement,
        calculate_digest: bool,
    ) -> Result<ValidatedMediaFile, StoreError> {
        self.validate_media_file_with(
            session_id,
            relative_path,
            length_requirement,
            calculate_digest,
            false,
            true,
        )
    }

    pub(crate) fn validate_media_file_with(
        &self,
        session_id: &str,
        relative_path: &str,
        length_requirement: MediaLengthRequirement,
        calculate_digest: bool,
        synchronize: bool,
        reuse_snapshot_digest: bool,
    ) -> Result<ValidatedMediaFile, StoreError> {
        if !valid_media_relative_path(relative_path) {
            return Err(StoreError::IntegrityMismatch("invalid media relative path"));
        }
        let components: Vec<_> = Path::new(relative_path)
            .components()
            .filter_map(|component| match component {
                Component::Normal(value) => Some(value),
                _ => None,
            })
            .collect();
        let [audio_component, track_component, file_component] = components.as_slice() else {
            return Err(StoreError::IntegrityMismatch(
                "media path has an invalid component count",
            ));
        };
        if *audio_component != OsStr::new(AUDIO_DIRECTORY) {
            return Err(StoreError::IntegrityMismatch(
                "media path is outside the audio directory",
            ));
        }

        let audio = self.open_managed_audio_directory(session_id)?;
        let track = open_managed_directory_at(&audio, track_component)?;
        let open_flags = if synchronize {
            fd_fs::OFlags::RDWR | fd_fs::OFlags::CLOEXEC | fd_fs::OFlags::NOFOLLOW
        } else {
            fd_fs::OFlags::RDONLY | fd_fs::OFlags::CLOEXEC | fd_fs::OFlags::NOFOLLOW
        };
        let media_fd = fd_fs::openat(&track, *file_component, open_flags, fd_fs::Mode::empty())
            .map_err(|error| {
                if error == rustix::io::Errno::NOENT {
                    StoreError::IntegrityMismatch("accepted media file is missing")
                } else {
                    StoreError::IntegrityMismatch("media file is missing, replaced, or symlinked")
                }
            })?;
        let mut file = File::from(media_fd);
        if synchronize {
            file.sync_all()?;
        }
        let stat = fd_fs::fstat(&file)
            .map_err(|_| StoreError::IntegrityMismatch("media file identity could not be read"))?;
        if fd_fs::FileType::from_raw_mode(stat.st_mode) != fd_fs::FileType::RegularFile {
            return Err(StoreError::IntegrityMismatch(
                "media path is not a regular file",
            ));
        }
        let byte_length = u64::try_from(stat.st_size)
            .map_err(|_| StoreError::IntegrityMismatch("media byte length is negative"))?;
        let length_matches = match length_requirement {
            MediaLengthRequirement::Exact(expected) => byte_length == expected,
            MediaLengthRequirement::AtLeast(minimum) => byte_length >= minimum,
        };
        if !length_matches || byte_length < CAF_HEADER.len() as u64 {
            return Err(StoreError::IntegrityMismatch(
                "media byte length violates the accepted writer evidence",
            ));
        }
        let mut header = [0_u8; 8];
        file.read_exact(&mut header)?;
        if &header != CAF_HEADER {
            return Err(StoreError::IntegrityMismatch("media header is not CAF"));
        }
        let media_identity = sealed_media_identity::media_identity(&file)?;
        if media_identity.0 != stat.st_dev as u64
            || media_identity.1 != stat.st_ino as u64
            || media_identity.2 != byte_length
        {
            return Err(StoreError::IntegrityMismatch(
                "media changed before hashing",
            ));
        }
        let snapshot_cached = if reuse_snapshot_digest {
            self.snapshot_digest_memo
                .borrow()
                .get(&media_identity)
                .cloned()
        } else {
            None
        };
        let cached_digest =
            snapshot_cached.or_else(|| self.digest_memo.borrow().recall(media_identity));
        let reused_digest = cached_digest.is_some();
        let digest_sha256 = if !calculate_digest {
            None
        } else if let Some(known) = cached_digest {
            Some(known)
        } else {
            file.rewind()?;
            let digest = sha256_of_length(
                &mut file,
                byte_length,
                "sealed media ended before its accepted byte length",
            )?;
            if file.read(&mut [0_u8; 1])? != 0 {
                return Err(StoreError::IntegrityMismatch(
                    "sealed media exceeds its accepted byte length",
                ));
            }
            self.digest_memo.borrow_mut().computed();
            Some(digest)
        };
        file.rewind()?;
        let inspection = inspect_pcm_caf(&mut file, byte_length)?;
        #[cfg(test)]
        self.run_media_validation_hook();
        let post_read_stat = fd_fs::fstat(&file).map_err(|_| {
            StoreError::IntegrityMismatch("sealed media identity could not be revalidated")
        })?;
        if post_read_stat.st_dev != stat.st_dev
            || post_read_stat.st_ino != stat.st_ino
            || post_read_stat.st_size != stat.st_size
            || sealed_media_identity::media_identity(&file)? != media_identity
        {
            return Err(StoreError::IntegrityMismatch(
                "media file changed while Rust validated it",
            ));
        }
        // Reopen the complete managed path: the retained track descriptor can
        // still name a directory that was replaced while the file was hashed.
        let current_audio = self.open_managed_audio_directory(session_id)?;
        let current_track = open_managed_directory_at(&current_audio, track_component)?;
        let rebound_fd = fd_fs::openat(
            &current_track,
            *file_component,
            open_flags,
            fd_fs::Mode::empty(),
        )
        .map_err(|_| StoreError::IntegrityMismatch("media path changed while Rust validated it"))?;
        let rebound_stat = fd_fs::fstat(&rebound_fd).map_err(|_| {
            StoreError::IntegrityMismatch("media path identity could not be rebound")
        })?;
        if rebound_stat.st_dev != stat.st_dev
            || rebound_stat.st_ino != stat.st_ino
            || rebound_stat.st_size != stat.st_size
            || sealed_media_identity::media_identity(&File::from(rebound_fd))? != media_identity
        {
            return Err(StoreError::IntegrityMismatch(
                "media path no longer names the validated file",
            ));
        }
        if synchronize {
            fd_fs::fsync(&track).map_err(|_| {
                StoreError::IntegrityMismatch("media directory could not be synchronized")
            })?;
        }
        if !reused_digest && let Some(digest) = &digest_sha256 {
            self.digest_memo.borrow_mut().record(media_identity, digest);
        }
        Ok(ValidatedMediaFile {
            file,
            identity: media_identity,
            byte_length,
            device: stat.st_dev as u64,
            inode: stat.st_ino as u64,
            digest_sha256,
            recoverable_sample_count: inspection.as_ref().and_then(|value| value.sample_count),
            channels: inspection.map(|value| value.channels),
        })
    }

    pub(crate) fn open_managed_audio_directory(
        &self,
        session_id: &str,
    ) -> Result<OwnedFd, StoreError> {
        let managed_root = open_managed_directory(&self.managed_root)?;
        let sessions = open_managed_directory_at(&managed_root, OsStr::new(SESSIONS_DIRECTORY))?;
        let session = open_managed_directory_at(&sessions, OsStr::new(session_id))?;
        open_managed_directory_at(&session, OsStr::new(AUDIO_DIRECTORY))
    }
}
