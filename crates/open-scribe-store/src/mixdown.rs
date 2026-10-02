//! Derived AAC mix evidence. Source CAF segments and their journal remain the
//! authority; this module never changes a source track or session lifecycle.
use super::*;

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct MixdownAuthorization {
    pub session_id: SessionId,
    pub relative_path: String,
    pub absolute_path: PathBuf,
    pub expected_frame_count: u64,
    pub source_digest_sha256: String,
    pub write_floor_bytes: u64,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct MixdownReceipt {
    pub session_id: SessionId,
    pub relative_path: String,
    pub byte_length: u64,
    pub decoded_frame_count: u64,
    pub sample_rate_hz: u32,
    pub channels: u16,
    pub codec: String,
    pub boundary_frames_readable: bool,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ValidatedMixdown {
    pub session_id: SessionId,
    pub relative_path: String,
    pub byte_length: u64,
    pub decoded_frame_count: u64,
    pub expected_frame_count: u64,
    pub digest_sha256: String,
    pub source_digest_sha256: String,
}

struct MixFile {
    file: File,
    byte_length: u64,
    digest_sha256: String,
}

impl SessionStore {
    pub fn authorize_mixdown(
        &mut self,
        session_id: SessionId,
        available_bytes: u64,
    ) -> Result<MixdownAuthorization, StoreError> {
        let (expected_frame_count, source_digest_sha256) = self.mix_source_plan(&session_id)?;
        if expected_frame_count == 0 {
            return Err(StoreError::InvalidState("mixdown has no source frames"));
        }
        if self.validated_mixdown(&session_id)?.is_some() {
            return Err(StoreError::InvalidState("validated mixdown already exists"));
        }
        // A completed recording may have stopped under critical pressure. A
        // fresh capacity observation governs this derived file without changing
        // the source session's recorded health or consuming its reserve.
        let write_floor_bytes = recorder::RESERVE_BYTES + 16 * 1024 * 1024;
        let minimum_free_bytes =
            write_floor_bytes.saturating_add(expected_frame_count.saturating_mul(2));
        if available_bytes < minimum_free_bytes {
            return Err(StoreError::InvalidState(
                "storage reserve prohibits derived mixdown",
            ));
        }
        let relative_path = format!("exports/mix-{}.m4a", Uuid::now_v7());
        let absolute_path = self.session_directory(&session_id.0)?.join(&relative_path);
        if fs::symlink_metadata(&absolute_path).is_ok() {
            return Err(StoreError::IntegrityMismatch("mixdown path already exists"));
        }
        let payload = json!({
            "relative_path": relative_path,
            "expected_frame_count": expected_frame_count,
            "source_digest_sha256": source_digest_sha256,
            "available_bytes": available_bytes,
            "minimum_free_bytes": minimum_free_bytes,
        });
        self.append_session_journal(
            &session_id.0,
            "mixdown_intent",
            Some(&relative_path),
            payload,
        )?;
        Ok(MixdownAuthorization {
            session_id,
            relative_path,
            absolute_path,
            expected_frame_count,
            source_digest_sha256,
            write_floor_bytes,
        })
    }

    pub fn accept_mixdown(
        &mut self,
        receipt: MixdownReceipt,
    ) -> Result<ValidatedMixdown, StoreError> {
        if Uuid::parse_str(&receipt.session_id.0).is_err()
            || !valid_mix_path(&receipt.relative_path)
            || receipt.byte_length < 32
            || receipt.decoded_frame_count == 0
            || receipt.sample_rate_hz != MEDIA_SAMPLE_RATE_HZ
            || receipt.channels != 2
            || receipt.codec != "aac"
            || !receipt.boundary_frames_readable
        {
            return Err(StoreError::InvalidRequest("mixdown receipt is invalid"));
        }
        let (expected_frame_count, source_digest_sha256) =
            self.mix_source_plan(&receipt.session_id)?;
        if receipt.decoded_frame_count.abs_diff(expected_frame_count) > 1024 {
            return Err(StoreError::IntegrityMismatch(
                "mixdown duration differs from sources",
            ));
        }
        let records = self.mix_journal(&receipt.session_id.0)?;
        let intent = records
            .iter()
            .find(|record| {
                record.body.event_kind == "mixdown_intent"
                    && record.body.relative_path.as_deref() == Some(receipt.relative_path.as_str())
            })
            .ok_or(StoreError::InvalidState("mixdown lacks Rust authorization"))?;
        if payload_u64(&intent.body.payload, "expected_frame_count")? != expected_frame_count
            || payload_string(&intent.body.payload, "source_digest_sha256")? != source_digest_sha256
        {
            return Err(StoreError::IntegrityMismatch("mixdown source plan changed"));
        }
        let media = self.open_mix_file(&receipt.session_id.0, &receipt.relative_path)?;
        if media.byte_length != receipt.byte_length {
            return Err(StoreError::IntegrityMismatch("mixdown byte length changed"));
        }
        let evidence = ValidatedMixdown {
            session_id: receipt.session_id.clone(),
            relative_path: receipt.relative_path.clone(),
            byte_length: media.byte_length,
            decoded_frame_count: receipt.decoded_frame_count,
            expected_frame_count,
            digest_sha256: media.digest_sha256,
            source_digest_sha256,
        };
        if let Some(prior) = records.iter().find(|record| {
            record.body.event_kind == "mixdown_validated"
                && record.body.relative_path.as_deref() == Some(receipt.relative_path.as_str())
        }) {
            if serde_json::from_value::<Value>(prior.body.payload.clone())?
                != mix_payload(&evidence)
            {
                return Err(StoreError::IntegrityMismatch(
                    "validated mixdown receipt changed",
                ));
            }
            return Ok(evidence);
        }
        self.append_session_journal(
            &receipt.session_id.0,
            "mixdown_validated",
            Some(&receipt.relative_path),
            mix_payload(&evidence),
        )?;
        Ok(evidence)
    }

    pub fn validated_mixdown(
        &self,
        session_id: &SessionId,
    ) -> Result<Option<ValidatedMixdown>, StoreError> {
        let (expected_frame_count, source_digest_sha256) = self.mix_source_plan(session_id)?;
        let records = self.mix_journal(&session_id.0)?;
        let Some(record) = records.iter().rev().find(|record| {
            record.body.event_kind == "mixdown_validated"
                && record
                    .body
                    .payload
                    .get("source_digest_sha256")
                    .and_then(Value::as_str)
                    == Some(source_digest_sha256.as_str())
        }) else {
            return Ok(None);
        };
        let relative_path =
            record
                .body
                .relative_path
                .as_deref()
                .ok_or(StoreError::IntegrityMismatch(
                    "validated mixdown lacks path",
                ))?;
        if !valid_mix_path(relative_path)
            || payload_u64(&record.body.payload, "expected_frame_count")? != expected_frame_count
        {
            return Err(StoreError::IntegrityMismatch(
                "validated mixdown plan changed",
            ));
        }
        let media = match self.open_mix_file(&session_id.0, relative_path) {
            Ok(media) => media,
            Err(StoreError::IntegrityMismatch(_)) => return Ok(None),
            Err(error) => return Err(error),
        };
        if media.byte_length != payload_u64(&record.body.payload, "byte_length")?
            || media.digest_sha256 != payload_string(&record.body.payload, "digest_sha256")?
        {
            return Ok(None);
        }
        Ok(Some(ValidatedMixdown {
            session_id: session_id.clone(),
            relative_path: relative_path.to_owned(),
            byte_length: media.byte_length,
            decoded_frame_count: payload_u64(&record.body.payload, "decoded_frame_count")?,
            expected_frame_count,
            digest_sha256: media.digest_sha256,
            source_digest_sha256,
        }))
    }

    pub fn lease_validated_mixdown(
        &self,
        session_id: &SessionId,
    ) -> Result<Option<ImportedPlaybackLease>, StoreError> {
        let Some(evidence) = self.validated_mixdown(session_id)? else {
            return Ok(None);
        };
        let media = self.open_mix_file(&session_id.0, &evidence.relative_path)?;
        if media.digest_sha256 != evidence.digest_sha256
            || media.byte_length != evidence.byte_length
        {
            return Err(StoreError::IntegrityMismatch(
                "mixdown changed before lease",
            ));
        }
        Ok(Some(ImportedPlaybackLease::verified_derived_m4a(
            media.file,
            media.byte_length,
            media.digest_sha256,
        )))
    }

    fn mix_source_plan(&self, session_id: &SessionId) -> Result<(u64, String), StoreError> {
        let segments = self.playback_timeline(session_id)?;
        let origin = segments
            .iter()
            .map(|segment| segment.start_nanoseconds)
            .min()
            .unwrap_or(0)
            .min(0);
        let mut expected_frames = 0_u64;
        let mut signature = Vec::with_capacity(segments.len());
        for segment in segments {
            let offset = i128::from(segment.start_nanoseconds) - i128::from(origin);
            let start_frames = u64::try_from(
                (offset * i128::from(MEDIA_SAMPLE_RATE_HZ) + 500_000_000) / 1_000_000_000,
            )
            .map_err(|_| StoreError::IntegrityMismatch("mixdown timeline exceeds range"))?;
            expected_frames = expected_frames.max(
                start_frames
                    .checked_add(segment.sample_count)
                    .ok_or(StoreError::IntegrityMismatch("mixdown duration overflow"))?,
            );
            signature.push(json!({
                "segment_id": segment.segment_id,
                "track_id": segment.track_id,
                "start_nanoseconds": segment.start_nanoseconds,
                "sample_count": segment.sample_count,
                "channels": segment.channels,
            }));
        }
        Ok((expected_frames, digest_json(&signature)?))
    }

    fn mix_journal(&self, session_id: &str) -> Result<Vec<JournalRecord>, StoreError> {
        match validate_journal(
            &self.session_directory(session_id)?.join(JOURNAL_NAME),
            session_id,
        )? {
            JournalValidation::Valid(records) => Ok(records),
            _ => Err(StoreError::IntegrityMismatch("mixdown journal is invalid")),
        }
    }

    fn open_mix_file(&self, session_id: &str, relative_path: &str) -> Result<MixFile, StoreError> {
        if !valid_mix_path(relative_path) {
            return Err(StoreError::IntegrityMismatch("invalid mixdown path"));
        }
        let managed = open_managed_directory(&self.managed_root)?;
        let sessions = open_managed_directory_at(&managed, OsStr::new(SESSIONS_DIRECTORY))?;
        let session = open_managed_directory_at(&sessions, OsStr::new(session_id))?;
        let exports = open_managed_directory_at(&session, OsStr::new("exports"))?;
        let name = OsStr::new(relative_path.strip_prefix("exports/").unwrap());
        let fd = fd_fs::openat(
            &exports,
            name,
            fd_fs::OFlags::RDWR | fd_fs::OFlags::CLOEXEC | fd_fs::OFlags::NOFOLLOW,
            fd_fs::Mode::empty(),
        )
        .map_err(|_| StoreError::IntegrityMismatch("mixdown file is unavailable"))?;
        let mut file = File::from(fd);
        file.sync_all()?;
        let stat = fd_fs::fstat(&file)
            .map_err(|_| StoreError::IntegrityMismatch("mixdown identity is unreadable"))?;
        if fd_fs::FileType::from_raw_mode(stat.st_mode) != fd_fs::FileType::RegularFile
            || stat.st_size < 32
        {
            return Err(StoreError::IntegrityMismatch("mixdown file is invalid"));
        }
        let byte_length = stat.st_size as u64;
        let mut header = [0_u8; 12];
        file.read_exact(&mut header)?;
        if &header[4..8] != b"ftyp" {
            return Err(StoreError::IntegrityMismatch(
                "mixdown container is not M4A",
            ));
        }
        file.rewind()?;
        let mut hasher = Sha256::new();
        let mut buffer = [0_u8; 64 * 1024];
        loop {
            let read = file.read(&mut buffer)?;
            if read == 0 {
                break;
            }
            hasher.update(&buffer[..read]);
        }
        let post = fd_fs::fstat(&file)
            .map_err(|_| StoreError::IntegrityMismatch("mixdown identity changed"))?;
        if post.st_dev != stat.st_dev || post.st_ino != stat.st_ino || post.st_size != stat.st_size
        {
            return Err(StoreError::IntegrityMismatch(
                "mixdown changed during validation",
            ));
        }
        let rebound = fd_fs::openat(
            &exports,
            name,
            fd_fs::OFlags::RDONLY | fd_fs::OFlags::CLOEXEC | fd_fs::OFlags::NOFOLLOW,
            fd_fs::Mode::empty(),
        )
        .map_err(|_| StoreError::IntegrityMismatch("mixdown path changed"))?;
        let rebound_stat = fd_fs::fstat(&rebound)
            .map_err(|_| StoreError::IntegrityMismatch("mixdown path changed"))?;
        if rebound_stat.st_dev != stat.st_dev
            || rebound_stat.st_ino != stat.st_ino
            || rebound_stat.st_size != stat.st_size
        {
            return Err(StoreError::IntegrityMismatch("mixdown path changed"));
        }
        file.rewind()?;
        Ok(MixFile {
            file,
            byte_length,
            digest_sha256: format!("{:x}", hasher.finalize()),
        })
    }
}

fn valid_mix_path(path: &str) -> bool {
    let Some(name) = path
        .strip_prefix("exports/mix-")
        .and_then(|value| value.strip_suffix(".m4a"))
    else {
        return false;
    };
    Uuid::parse_str(name).is_ok()
}

fn mix_payload(evidence: &ValidatedMixdown) -> Value {
    json!({
        "relative_path": evidence.relative_path,
        "byte_length": evidence.byte_length,
        "decoded_frame_count": evidence.decoded_frame_count,
        "expected_frame_count": evidence.expected_frame_count,
        "digest_sha256": evidence.digest_sha256,
        "source_digest_sha256": evidence.source_digest_sha256,
    })
}
