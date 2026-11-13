//! Capture lifecycle: required sources, media authorization, writer receipts,
//! first sample, seal and interruption.

use super::*;

/// Durable declaration of the sources that must become active before Recording.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct RequiredSourcePlanEvidence {
    pub session_id: SessionId,
    pub required_sources: Vec<MediaSourceKind>,
    pub journal_durable: bool,
    pub recording_started: bool,
    pub last_journal_sequence: u64,
}

/// Coarse authority returned only when every declared source is durably capturing.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct RecordingStartedEvidence {
    pub session_id: SessionId,
    pub required_sources: Vec<MediaSourceKind>,
    pub active_sources: Vec<MediaSourceKind>,
    pub journal_durable: bool,
    pub media_files_open: bool,
    pub recording_started: bool,
    pub last_journal_sequence: u64,
}

/// Request for one Rust-authorized initial source segment.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct AuthorizeMediaOpenRequest {
    pub session_id: SessionId,
    pub source_kind: MediaSourceKind,
    pub source_display_name: String,
}

/// Coarse path and format authority passed to the Swift-owned writer.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct MediaOpenAuthorization {
    pub session_id: SessionId,
    pub source_id: String,
    pub track_id: String,
    pub segment_id: String,
    pub open_token: String,
    pub writer_generation: u64,
    pub relative_path: String,
    pub absolute_path: PathBuf,
    pub media_format: String,
    pub sample_rate_hz: u32,
    pub channels: u16,
    pub mapped_start_nanoseconds: i64,
}

/// Coarse writer evidence. Audio buffers and frame-rate values never enter Rust.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct MediaOpenReceipt {
    pub session_id: SessionId,
    pub track_id: String,
    pub segment_id: String,
    pub open_token: String,
    pub writer_generation: u64,
    pub relative_path: String,
    pub media_format: String,
    pub sample_rate_hz: u32,
    pub channels: u16,
    pub initial_byte_length: u64,
}

/// Rust-validated evidence. This is still not a Recording transition.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct MediaOpenEvidence {
    pub session_id: SessionId,
    pub segment_id: String,
    pub journal_durable: bool,
    pub media_files_open: bool,
    pub recording_started: bool,
    pub last_journal_sequence: u64,
}

/// Coarse evidence that the Swift writer durably wrote its first valid capture buffer.
/// Media samples and frame-rate telemetry remain Swift-owned.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct FirstSampleReceipt {
    pub session_id: SessionId,
    pub track_id: String,
    pub segment_id: String,
    pub open_token: String,
    pub writer_generation: u64,
    pub relative_path: String,
    pub first_sample_host_time: u64,
    pub first_sample_frame_count: u64,
    pub observed_byte_length: u64,
}

/// Rust-validated first-sample evidence. It deliberately does not start
/// Recording.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct FirstSampleEvidence {
    pub session_id: SessionId,
    pub segment_id: String,
    pub first_sample_session_nanoseconds: i64,
    pub journal_durable: bool,
    pub media_files_open: bool,
    pub first_sample_durable: bool,
    pub recording_started: bool,
    pub last_journal_sequence: u64,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct InterruptSessionRequest {
    pub session_id: SessionId,
    pub reason: SessionInterruptionReason,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct SessionInterruptionEvidence {
    pub session_id: SessionId,
    pub reason: SessionInterruptionReason,
    pub journal_durable: bool,
    pub session_interrupted: bool,
    pub recording_started: bool,
    pub last_journal_sequence: u64,
}

/// Coarse evidence produced only after Swift has stopped writing and closed the
/// segment. Rust independently validates the final file and calculates its digest.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct SealSegmentReceipt {
    pub session_id: SessionId,
    pub track_id: String,
    pub segment_id: String,
    pub open_token: String,
    pub writer_generation: u64,
    pub relative_path: String,
    pub final_sample_host_time: u64,
    pub sample_count: u64,
    pub final_byte_length: u64,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct SealedSegmentEvidence {
    pub session_id: SessionId,
    pub segment_id: String,
    pub sample_count: u64,
    pub final_byte_length: u64,
    pub digest_sha256: String,
    pub segment_sealed: bool,
    pub recording_started: bool,
    pub last_journal_sequence: u64,
}

pub(crate) struct StoredMediaAuthorization {
    pub(crate) session_id: String,
    pub(crate) source_id: String,
    pub(crate) track_id: String,
    pub(crate) relative_path: String,
    pub(crate) media_format: String,
    pub(crate) channels: u16,
    pub(crate) lifecycle: String,
    pub(crate) open_token: String,
    pub(crate) writer_generation: u64,
    pub(crate) byte_length: Option<u64>,
    pub(crate) file_device: Option<u64>,
    pub(crate) file_inode: Option<u64>,
}

pub(crate) fn validate_media_request(
    request: &AuthorizeMediaOpenRequest,
) -> Result<(), StoreError> {
    if Uuid::parse_str(&request.session_id.0).is_err() {
        return Err(StoreError::InvalidRequest("session ID is not a UUID"));
    }
    let display_name = request.source_display_name.trim();
    if display_name.is_empty() {
        return Err(StoreError::InvalidRequest("source display name is empty"));
    }
    if request.source_display_name.len() > MAX_DISPLAY_NAME_BYTES {
        return Err(StoreError::InvalidRequest(
            "source display name exceeds byte limit",
        ));
    }
    Ok(())
}

pub(crate) fn normalized_source_kinds(
    required_sources: Vec<MediaSourceKind>,
) -> Result<Vec<MediaSourceKind>, StoreError> {
    if required_sources.is_empty() || required_sources.len() > 3 {
        return Err(StoreError::InvalidRequest(
            "required-source plan must contain one to three sources",
        ));
    }
    let mut names = required_sources
        .into_iter()
        .map(|kind| kind.as_str())
        .collect::<Vec<_>>();
    names.sort_unstable();
    names.dedup();
    if names.is_empty() {
        return Err(StoreError::InvalidRequest("required-source plan is empty"));
    }
    names.into_iter().map(parse_source_kind).collect()
}

pub(crate) fn validate_media_receipt_shape(receipt: &MediaOpenReceipt) -> Result<(), StoreError> {
    if Uuid::parse_str(&receipt.session_id.0).is_err()
        || Uuid::parse_str(&receipt.track_id).is_err()
        || Uuid::parse_str(&receipt.segment_id).is_err()
        || Uuid::parse_str(&receipt.open_token).is_err()
    {
        return Err(StoreError::InvalidRequest(
            "media receipt identity is not a UUID",
        ));
    }
    if receipt.writer_generation == 0
        || receipt.writer_generation > i64::MAX as u64
        || receipt.media_format != MEDIA_FORMAT_CAF_PCM_S16LE
        || receipt.sample_rate_hz != MEDIA_SAMPLE_RATE_HZ
        || (receipt.channels != 1 && receipt.channels != 2)
        || !valid_media_relative_path(&receipt.relative_path)
    {
        return Err(StoreError::InvalidRequest(
            "media receipt format or path is unsupported",
        ));
    }
    Ok(())
}

pub(crate) fn validate_first_sample_receipt_shape(
    receipt: &FirstSampleReceipt,
) -> Result<(), StoreError> {
    if Uuid::parse_str(&receipt.session_id.0).is_err()
        || Uuid::parse_str(&receipt.track_id).is_err()
        || Uuid::parse_str(&receipt.segment_id).is_err()
        || Uuid::parse_str(&receipt.open_token).is_err()
    {
        return Err(StoreError::InvalidRequest(
            "first-sample receipt identity is not a UUID",
        ));
    }
    if receipt.writer_generation == 0
        || receipt.writer_generation > i64::MAX as u64
        || !valid_media_relative_path(&receipt.relative_path)
    {
        return Err(StoreError::InvalidRequest(
            "first-sample receipt path or writer generation is unsupported",
        ));
    }
    if receipt.first_sample_host_time == 0
        || receipt.first_sample_host_time > i64::MAX as u64
        || receipt.first_sample_frame_count == 0
        || receipt.first_sample_frame_count > i64::MAX as u64
        || receipt.observed_byte_length > i64::MAX as u64
    {
        return Err(StoreError::InvalidRequest(
            "first-sample timing, frame count, or length is invalid",
        ));
    }
    Ok(())
}

pub(crate) fn validate_seal_receipt_shape(receipt: &SealSegmentReceipt) -> Result<(), StoreError> {
    if Uuid::parse_str(&receipt.session_id.0).is_err()
        || Uuid::parse_str(&receipt.track_id).is_err()
        || Uuid::parse_str(&receipt.segment_id).is_err()
        || Uuid::parse_str(&receipt.open_token).is_err()
    {
        return Err(StoreError::InvalidRequest(
            "segment-seal receipt identity is not a UUID",
        ));
    }
    if receipt.writer_generation == 0
        || receipt.writer_generation > i64::MAX as u64
        || !valid_media_relative_path(&receipt.relative_path)
    {
        return Err(StoreError::InvalidRequest(
            "segment-seal receipt path or writer generation is unsupported",
        ));
    }
    if receipt.final_sample_host_time == 0
        || receipt.final_sample_host_time > i64::MAX as u64
        || receipt.sample_count == 0
        || receipt.sample_count > i64::MAX as u64
        || receipt.final_byte_length > i64::MAX as u64
    {
        return Err(StoreError::InvalidRequest(
            "segment-seal timing, sample count, or length is invalid",
        ));
    }
    Ok(())
}

impl SessionStore {
    /// Persists the complete required-source contract before any media is authorized.
    pub fn plan_required_sources(
        &mut self,
        session_id: SessionId,
        required_sources: Vec<MediaSourceKind>,
    ) -> Result<RequiredSourcePlanEvidence, StoreError> {
        let _writer = self.write_guard()?;
        if Uuid::parse_str(&session_id.0).is_err() {
            return Err(StoreError::InvalidRequest("session ID is not a UUID"));
        }
        let required_sources = normalized_source_kinds(required_sources)?;
        let (lifecycle, journal_durable): (SessionLifecycle, bool) = self
            .connection
            .query_row(
                "SELECT lifecycle, journal_durable FROM sessions WHERE id = ?1",
                [&session_id.0],
                |row| Ok((row.get(0)?, row.get(1)?)),
            )
            .map_err(missing_row("session does not exist"))?;
        if lifecycle != SessionLifecycle::Preparing || !journal_durable {
            return Err(StoreError::InvalidState(
                "session is not awaiting a required-source plan",
            ));
        }
        let existing: Vec<MediaSourceKind> = self.required_source_kinds(&session_id.0)?;
        if !existing.is_empty() {
            if existing != required_sources {
                return Err(StoreError::IntegrityMismatch(
                    "repeated required-source plan changed accepted scope",
                ));
            }
            let last_journal_sequence = self.last_journal_sequence(&session_id.0)?;
            return Ok(RequiredSourcePlanEvidence {
                session_id,
                required_sources,
                journal_durable: true,
                recording_started: false,
                last_journal_sequence,
            });
        }
        let payload = json!({
            "required_sources": required_sources.iter().map(|kind| kind.as_str()).collect::<Vec<_>>()
        });
        let journal_record = self.append_session_journal(
            &session_id.0,
            "required_sources_planned",
            None,
            payload.clone(),
        )?;
        let transaction = self.connection.transaction()?;
        for kind in &required_sources {
            transaction.execute(
                "INSERT INTO required_sources (
                    session_id, schema_version, kind, lifecycle
                 ) VALUES (?1, ?2, ?3, 'required')",
                params![session_id.0, SCHEMA_VERSION, kind.as_str()],
            )?;
        }
        insert_journaled_event(&transaction, &journal_record, "required_sources_planned")?;
        transaction.commit()?;
        Ok(RequiredSourcePlanEvidence {
            session_id,
            required_sources,
            journal_durable: true,
            recording_started: false,
            last_journal_sequence: journal_record.body.sequence,
        })
    }

    /// Enters Recording only after every required source has durable first-sample evidence.
    pub fn confirm_recording(
        &mut self,
        session_id: SessionId,
    ) -> Result<RecordingStartedEvidence, StoreError> {
        let _writer = self.write_guard()?;
        let required_sources = self.required_source_kinds(&session_id.0)?;
        if required_sources.is_empty() {
            return Err(StoreError::InvalidState("required-source plan is missing"));
        }
        let active_sources = self.active_source_kinds(&session_id.0)?;
        if active_sources != required_sources {
            return Err(StoreError::InvalidState(
                "not every required source has durable first-sample evidence",
            ));
        }
        let (lifecycle, journal_durable, media_files_open): (SessionLifecycle, bool, bool) =
            self.connection.query_row(
                "SELECT lifecycle, journal_durable, media_files_open FROM sessions WHERE id = ?1",
                [&session_id.0],
                |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?)),
            )?;
        if lifecycle == SessionLifecycle::Recording {
            let last_journal_sequence = self.last_journal_sequence(&session_id.0)?;
            return Ok(RecordingStartedEvidence {
                session_id,
                required_sources,
                active_sources,
                journal_durable,
                media_files_open,
                recording_started: true,
                last_journal_sequence,
            });
        }
        if lifecycle != SessionLifecycle::Preparing
            || !open_scribe_domain::recording_evidence_sufficient(
                required_sources.len(),
                active_sources.len(),
                journal_durable,
                media_files_open,
            )
        {
            return Err(StoreError::InvalidState(
                "session durability is insufficient for Recording",
            ));
        }
        let payload = json!({
            "required_sources": required_sources.iter().map(|kind| kind.as_str()).collect::<Vec<_>>(),
            "active_sources": active_sources.iter().map(|kind| kind.as_str()).collect::<Vec<_>>()
        });
        let journal_record =
            self.append_session_journal(&session_id.0, "recording_started", None, payload.clone())?;
        let transaction = self.connection.transaction()?;
        let changed = transaction.execute(
            "UPDATE sessions SET lifecycle = 'recording', updated_at_ms = ?2
             WHERE id = ?1 AND lifecycle = 'preparing'
               AND journal_durable = 1 AND media_files_open = 1",
            params![session_id.0, journal_record.body.wall_time_milliseconds],
        )?;
        if changed != 1 {
            return Err(StoreError::InvalidState(
                "session is not awaiting Recording authority",
            ));
        }
        insert_journaled_event(&transaction, &journal_record, "recording_started")?;
        transaction.commit()?;
        Ok(RecordingStartedEvidence {
            session_id,
            required_sources,
            active_sources,
            journal_durable: true,
            media_files_open: true,
            recording_started: true,
            last_journal_sequence: journal_record.body.sequence,
        })
    }

    /// Allocates one deterministic managed path before Swift opens media.
    pub fn authorize_media_open(
        &mut self,
        request: AuthorizeMediaOpenRequest,
    ) -> Result<MediaOpenAuthorization, StoreError> {
        let _writer = self.write_guard()?;
        self.authorize_media_open_inner(request, None)
    }

    /// Validates coarse Swift writer evidence and persists it without entering Recording.
    pub fn accept_media_open(
        &mut self,
        receipt: MediaOpenReceipt,
    ) -> Result<MediaOpenEvidence, StoreError> {
        let _writer = self.write_guard()?;
        self.accept_media_open_inner(receipt, None)
    }

    /// Persists coarse first-sample evidence without entering Recording.
    pub fn accept_first_sample(
        &mut self,
        receipt: FirstSampleReceipt,
    ) -> Result<FirstSampleEvidence, StoreError> {
        let _writer = self.write_guard()?;
        self.accept_first_sample_inner(receipt, None)
    }

    /// Accepts a closed, synchronized segment, independently digests the file,
    /// and binds the writer-reported final counters to that immutable evidence.
    pub fn seal_segment(
        &mut self,
        receipt: SealSegmentReceipt,
    ) -> Result<SealedSegmentEvidence, StoreError> {
        let _writer = self.write_guard()?;
        self.seal_segment_inner(receipt, None)
    }

    /// Durably marks a partial capture as interrupted without altering media.
    pub fn interrupt_session(
        &mut self,
        request: InterruptSessionRequest,
    ) -> Result<SessionInterruptionEvidence, StoreError> {
        let _writer = self.write_guard()?;
        if Uuid::parse_str(&request.session_id.0).is_err() {
            return Err(StoreError::InvalidRequest("session ID is not a UUID"));
        }
        let lifecycle: SessionLifecycle = self
            .connection
            .query_row(
                "SELECT lifecycle FROM sessions WHERE id = ?1",
                [&request.session_id.0],
                |row| row.get(0),
            )
            .map_err(missing_row("session does not exist"))?;
        let journal_path = self
            .session_directory(&request.session_id.0)?
            .join(JOURNAL_NAME);
        let records = match validate_journal(&journal_path, &request.session_id.0)? {
            JournalValidation::Valid(records) => records,
            _ => return Err(StoreError::IntegrityMismatch("session journal is invalid")),
        };
        let last = records
            .last()
            .ok_or(StoreError::IntegrityMismatch("session journal is empty"))?;
        if last.body.event_kind == "session_interrupted" {
            if SessionInterruptionReason::parse(payload_string(&last.body.payload, "reason")?)?
                != request.reason
            {
                return Err(StoreError::IntegrityMismatch(
                    "repeated interruption changed accepted evidence",
                ));
            }
            if lifecycle.is_interruptible() {
                self.project_session_interruption(&request.session_id.0, last)?;
            } else if lifecycle != SessionLifecycle::Interrupted {
                return Err(StoreError::InvalidState(
                    "session is not awaiting interruption evidence",
                ));
            }
            return Ok(SessionInterruptionEvidence {
                session_id: request.session_id,
                reason: request.reason,
                journal_durable: true,
                session_interrupted: true,
                recording_started: false,
                last_journal_sequence: last.body.sequence,
            });
        }
        if lifecycle == SessionLifecycle::Interrupted {
            return Err(StoreError::IntegrityMismatch(
                "session projection has no interruption evidence",
            ));
        }
        if !lifecycle.is_interruptible() {
            return Err(StoreError::InvalidState(
                "session is not awaiting interruption evidence",
            ));
        }

        let payload = json!({ "reason": request.reason.as_str() });
        let journal_record = self.append_session_journal(
            &request.session_id.0,
            "session_interrupted",
            None,
            payload.clone(),
        )?;
        self.project_session_interruption(&request.session_id.0, &journal_record)?;

        Ok(SessionInterruptionEvidence {
            session_id: request.session_id,
            reason: request.reason,
            journal_durable: true,
            session_interrupted: true,
            recording_started: false,
            last_journal_sequence: journal_record.body.sequence,
        })
    }

    pub(crate) fn authorize_media_open_inner(
        &mut self,
        request: AuthorizeMediaOpenRequest,
        failure: Option<MediaFailurePoint>,
    ) -> Result<MediaOpenAuthorization, StoreError> {
        self.require_storage_headroom(&request.session_id.0)?;
        validate_media_request(&request)?;
        let (lifecycle, journal_durable): (SessionLifecycle, bool) = self
            .connection
            .query_row(
                "SELECT lifecycle, journal_durable FROM sessions WHERE id = ?1",
                [&request.session_id.0],
                |row| Ok((row.get(0)?, row.get(1)?)),
            )
            .map_err(missing_row("session does not exist"))?;
        let restoring_microphone = lifecycle == SessionLifecycle::Recording
            && request.source_kind == MediaSourceKind::Microphone
            && self.microphone_restore_is_open(&request.session_id.0)?;
        if (!restoring_microphone && lifecycle != SessionLifecycle::Preparing) || !journal_durable {
            return Err(StoreError::InvalidState(
                "session is not awaiting required media files",
            ));
        }
        let required: bool = self.connection.query_row(
            "SELECT EXISTS(
                SELECT 1 FROM required_sources
                WHERE session_id = ?1 AND kind = ?2 AND lifecycle != 'failed'
             )",
            params![request.session_id.0, request.source_kind.as_str()],
            |row| row.get(0),
        )?;
        if !required {
            return Err(StoreError::InvalidState(
                "media source is not part of the required-source plan",
            ));
        }
        // Ended and failed sources are terminal: a kind selected again after a
        // failure is a new source (ADR 0005 source-added; ADR 0007 restoration).
        let existing_kind: bool = self.connection.query_row(
            "SELECT EXISTS(
                SELECT 1 FROM sources
                WHERE session_id = ?1 AND kind = ?2 AND lifecycle NOT IN ('ended', 'failed')
             )",
            params![request.session_id.0, request.source_kind.as_str()],
            |row| row.get(0),
        )?;
        if existing_kind {
            return Err(StoreError::InvalidState(
                "media authorization already exists for this required source",
            ));
        }

        let source_id = Uuid::now_v7().to_string();
        let track_id = Uuid::now_v7().to_string();
        let segment_id = Uuid::now_v7().to_string();
        let open_token = Uuid::now_v7().to_string();
        let writer_generation = 1_u64;
        let channels = capture_channels(request.source_kind);
        let relative_path = track_file_path(&track_id, &capture_segment_file(0));
        let session_directory = self.session_directory(&request.session_id.0)?;
        let audio_directory = self.open_managed_audio_directory(&request.session_id.0)?;
        fd_fs::mkdirat(
            &audio_directory,
            &track_id,
            fd_fs::Mode::from_raw_mode(0o700),
        )
        .map_err(|_| StoreError::IntegrityMismatch("managed media track could not be created"))?;
        let track_directory = fd_fs::openat(
            &audio_directory,
            &track_id,
            directory_open_flags(),
            fd_fs::Mode::empty(),
        )
        .map_err(|_| StoreError::IntegrityMismatch("managed media track could not be opened"))?;
        fd_fs::fsync(&track_directory).map_err(|_| {
            StoreError::IntegrityMismatch("managed media track could not be synchronized")
        })?;
        fd_fs::fsync(&audio_directory).map_err(|_| {
            StoreError::IntegrityMismatch("managed audio directory could not be synchronized")
        })?;
        let absolute_path = session_directory.join(&relative_path);
        if fs::symlink_metadata(&absolute_path).is_ok() {
            return Err(StoreError::IntegrityMismatch(
                "authorized media path already exists",
            ));
        }

        let payload = json!({
            "source_id": source_id,
            "source_kind": request.source_kind.as_str(),
            "source_display_name": request.source_display_name,
            "track_id": track_id,
            "segment_id": segment_id,
            "open_token": open_token,
            "writer_generation": writer_generation,
            "relative_path": relative_path,
            "media_format": MEDIA_FORMAT_CAF_PCM_S16LE,
            "sample_rate_hz": MEDIA_SAMPLE_RATE_HZ,
            "channels": channels,
            "mapped_start_nanoseconds": 0,
        });
        let journal_record = self.append_session_journal(
            &request.session_id.0,
            "segment_open_intent",
            Some(&relative_path),
            payload.clone(),
        )?;
        interrupt_media_if(failure, MediaFailurePoint::AuthorizationJournalSync)?;
        self.project_media_authorization(&request.session_id.0, &journal_record)?;
        interrupt_media_if(failure, MediaFailurePoint::AuthorizationDatabaseProjection)?;

        Ok(MediaOpenAuthorization {
            session_id: request.session_id,
            source_id,
            track_id,
            segment_id,
            open_token,
            writer_generation,
            relative_path,
            absolute_path,
            media_format: MEDIA_FORMAT_CAF_PCM_S16LE.to_owned(),
            sample_rate_hz: MEDIA_SAMPLE_RATE_HZ,
            channels,
            mapped_start_nanoseconds: 0,
        })
    }

    pub(crate) fn accept_media_open_inner(
        &mut self,
        receipt: MediaOpenReceipt,
        failure: Option<MediaFailurePoint>,
    ) -> Result<MediaOpenEvidence, StoreError> {
        validate_media_receipt_shape(&receipt)?;
        let stored = self.media_authorization_row(&receipt.segment_id)?;
        if stored.session_id != receipt.session_id.0
            || stored.track_id != receipt.track_id
            || stored.open_token != receipt.open_token
            || stored.writer_generation != receipt.writer_generation
            || stored.relative_path != receipt.relative_path
            || stored.media_format != receipt.media_format
            || stored.channels != receipt.channels
        {
            return Err(StoreError::IntegrityMismatch(
                "writer receipt does not match Rust authorization",
            ));
        }
        if stored.lifecycle == "open" {
            let expected_byte_length = stored.byte_length.ok_or(StoreError::IntegrityMismatch(
                "accepted media length is missing",
            ))?;
            let expected_device = stored.file_device.ok_or(StoreError::IntegrityMismatch(
                "accepted media device is missing",
            ))?;
            let expected_inode = stored.file_inode.ok_or(StoreError::IntegrityMismatch(
                "accepted media inode is missing",
            ))?;
            if receipt.initial_byte_length != expected_byte_length {
                return Err(StoreError::IntegrityMismatch(
                    "repeated receipt changed the accepted media length",
                ));
            }
            let validated = self
                .validate_media_file(
                    &stored.session_id,
                    &stored.relative_path,
                    MediaLengthRequirement::AtLeast(expected_byte_length),
                    false,
                )
                .map_err(|error| match error {
                    StoreError::Io(io_error) if io_error.kind() == std::io::ErrorKind::NotFound => {
                        StoreError::IntegrityMismatch("accepted media file is missing")
                    }
                    other => other,
                })?;
            if validated.device != expected_device
                || validated.inode != expected_inode
                || validated
                    .channels
                    .is_some_and(|channels| channels != stored.channels)
            {
                return Err(StoreError::IntegrityMismatch(
                    "accepted media file identity changed",
                ));
            }
            return Ok(MediaOpenEvidence {
                session_id: receipt.session_id,
                segment_id: receipt.segment_id,
                journal_durable: true,
                media_files_open: self.session_media_files_open(&stored.session_id)?,
                recording_started: false,
                last_journal_sequence: self.last_journal_sequence(&stored.session_id)?,
            });
        }
        if stored.lifecycle != "opening" {
            return Err(StoreError::InvalidState(
                "segment is not awaiting media-open evidence",
            ));
        }

        let validated = self.validate_media_file(
            &stored.session_id,
            &stored.relative_path,
            MediaLengthRequirement::Exact(receipt.initial_byte_length),
            false,
        )?;
        if validated
            .channels
            .is_some_and(|channels| channels != stored.channels)
        {
            return Err(StoreError::IntegrityMismatch(
                "writer media channel layout changed from authorization",
            ));
        }
        let payload = json!({
            "track_id": stored.track_id,
            "segment_id": receipt.segment_id,
            "open_token": stored.open_token,
            "writer_generation": stored.writer_generation,
            "relative_path": stored.relative_path,
            "media_format": stored.media_format,
            "sample_rate_hz": receipt.sample_rate_hz,
            "channels": receipt.channels,
            "initial_byte_length": validated.byte_length,
            "file_device": validated.device,
            "file_inode": validated.inode,
        });
        let journal_record = self.append_session_journal(
            &receipt.session_id.0,
            "segment_opened",
            Some(&receipt.relative_path),
            payload.clone(),
        )?;
        interrupt_media_if(failure, MediaFailurePoint::ReceiptJournalSync)?;
        self.project_media_open(&receipt.session_id.0, &journal_record)?;
        interrupt_media_if(failure, MediaFailurePoint::ReceiptDatabaseProjection)?;

        Ok(MediaOpenEvidence {
            session_id: receipt.session_id,
            segment_id: receipt.segment_id,
            journal_durable: true,
            media_files_open: self.session_media_files_open(&stored.session_id)?,
            recording_started: false,
            last_journal_sequence: journal_record.body.sequence,
        })
    }

    pub(crate) fn accept_first_sample_inner(
        &mut self,
        receipt: FirstSampleReceipt,
        failure: Option<MediaFailurePoint>,
    ) -> Result<FirstSampleEvidence, StoreError> {
        validate_first_sample_receipt_shape(&receipt)?;
        let stored = self.media_authorization_row(&receipt.segment_id)?;
        if stored.session_id != receipt.session_id.0
            || stored.track_id != receipt.track_id
            || stored.open_token != receipt.open_token
            || stored.writer_generation != receipt.writer_generation
            || stored.relative_path != receipt.relative_path
        {
            return Err(StoreError::IntegrityMismatch(
                "first-sample receipt does not match Rust authorization",
            ));
        }
        let accepted_byte_length = stored
            .byte_length
            .ok_or(StoreError::InvalidState("media-open evidence is missing"))?;
        let expected_device = stored.file_device.ok_or(StoreError::IntegrityMismatch(
            "accepted media device is missing",
        ))?;
        let expected_inode = stored.file_inode.ok_or(StoreError::IntegrityMismatch(
            "accepted media inode is missing",
        ))?;
        if receipt.observed_byte_length <= accepted_byte_length {
            return Err(StoreError::IntegrityMismatch(
                "first-sample evidence did not grow the media file",
            ));
        }
        let validated = self.validate_media_file(
            &stored.session_id,
            &stored.relative_path,
            MediaLengthRequirement::AtLeast(receipt.observed_byte_length),
            false,
        )?;
        if validated.device != expected_device
            || validated.inode != expected_inode
            || validated
                .channels
                .is_some_and(|channels| channels != stored.channels)
        {
            return Err(StoreError::IntegrityMismatch(
                "accepted media file identity changed",
            ));
        }

        if stored.lifecycle == "capturing" {
            let payload = self.segment_event_payload(
                &stored.session_id,
                "first_sample_captured",
                &receipt.segment_id,
                "first-sample evidence is missing",
            )?;
            if payload_u64(&payload, "first_sample_host_time")? != receipt.first_sample_host_time
                || payload_u64(&payload, "first_sample_frame_count")?
                    != receipt.first_sample_frame_count
                || payload_u64(&payload, "observed_byte_length")? != receipt.observed_byte_length
            {
                return Err(StoreError::IntegrityMismatch(
                    "repeated first-sample receipt changed accepted evidence",
                ));
            }
            return Ok(FirstSampleEvidence {
                session_id: receipt.session_id,
                segment_id: receipt.segment_id,
                first_sample_session_nanoseconds: payload_i64(
                    &payload,
                    "first_sample_session_nanoseconds",
                )?,
                journal_durable: true,
                media_files_open: true,
                first_sample_durable: true,
                recording_started: false,
                last_journal_sequence: self.last_journal_sequence(&stored.session_id)?,
            });
        }
        if stored.lifecycle != "open" {
            return Err(StoreError::InvalidState(
                "segment is not awaiting first-sample evidence",
            ));
        }
        let (session_lifecycle, journal_durable, media_files_open): (SessionLifecycle, bool, bool) =
            self.connection.query_row(
                "SELECT lifecycle, journal_durable, media_files_open
                 FROM sessions WHERE id = ?1",
                [&stored.session_id],
                |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?)),
            )?;
        if !session_lifecycle.is_interruptible() || !journal_durable || !media_files_open {
            return Err(StoreError::InvalidState(
                "session is not ready for first-sample evidence",
            ));
        }

        self.require_resumed_sample(&stored.session_id, receipt.first_sample_host_time)?;
        let mapped_start =
            self.map_capture_time(&stored.session_id, receipt.first_sample_host_time)?;
        let payload = json!({
            "track_id": stored.track_id,
            "segment_id": receipt.segment_id,
            "open_token": stored.open_token,
            "writer_generation": stored.writer_generation,
            "relative_path": stored.relative_path,
            "first_sample_host_time": receipt.first_sample_host_time,
            "first_sample_frame_count": receipt.first_sample_frame_count,
            "first_sample_session_nanoseconds": mapped_start,
            "observed_byte_length": receipt.observed_byte_length,
            "file_device": expected_device,
            "file_inode": expected_inode,
        });
        let journal_record = self.append_session_journal(
            &receipt.session_id.0,
            "first_sample_captured",
            Some(&receipt.relative_path),
            payload.clone(),
        )?;
        interrupt_media_if(failure, MediaFailurePoint::FirstSampleJournalSync)?;
        self.project_first_sample(&receipt.session_id.0, &journal_record)?;
        interrupt_media_if(failure, MediaFailurePoint::FirstSampleDatabaseProjection)?;

        Ok(FirstSampleEvidence {
            session_id: receipt.session_id,
            segment_id: receipt.segment_id,
            first_sample_session_nanoseconds: mapped_start,
            journal_durable: true,
            media_files_open: true,
            first_sample_durable: true,
            recording_started: false,
            last_journal_sequence: journal_record.body.sequence,
        })
    }

    pub(crate) fn seal_segment_inner(
        &mut self,
        receipt: SealSegmentReceipt,
        failure: Option<MediaFailurePoint>,
    ) -> Result<SealedSegmentEvidence, StoreError> {
        validate_seal_receipt_shape(&receipt)?;
        let stored = self.media_authorization_row(&receipt.segment_id)?;
        if stored.session_id != receipt.session_id.0
            || stored.track_id != receipt.track_id
            || stored.open_token != receipt.open_token
            || stored.writer_generation != receipt.writer_generation
            || stored.relative_path != receipt.relative_path
        {
            return Err(StoreError::IntegrityMismatch(
                "segment-seal receipt does not match Rust authorization",
            ));
        }
        let expected_device = stored
            .file_device
            .ok_or(StoreError::InvalidState("media-open evidence is missing"))?;
        let expected_inode = stored
            .file_inode
            .ok_or(StoreError::InvalidState("media-open evidence is missing"))?;
        let first_payload = self.segment_event_payload(
            &stored.session_id,
            "first_sample_captured",
            &receipt.segment_id,
            "first-sample evidence is missing",
        )?;
        if payload_string(&first_payload, "track_id")? != receipt.track_id
            || receipt.final_sample_host_time
                < payload_u64(&first_payload, "first_sample_host_time")?
            || receipt.sample_count < payload_u64(&first_payload, "first_sample_frame_count")?
        {
            return Err(StoreError::IntegrityMismatch(
                "segment-seal timing or sample total precedes the first sample",
            ));
        }
        let validated = self.validate_media_file(
            &stored.session_id,
            &stored.relative_path,
            MediaLengthRequirement::Exact(receipt.final_byte_length),
            true,
        )?;
        if validated.device != expected_device
            || validated.inode != expected_inode
            || validated.channels != Some(stored.channels)
        {
            return Err(StoreError::IntegrityMismatch(
                "accepted media file identity changed",
            ));
        }
        if let Some(decoded_sample_count) = validated.recoverable_sample_count
            && decoded_sample_count != receipt.sample_count
        {
            return Err(StoreError::IntegrityMismatch(
                "segment-seal sample total does not match the accepted CAF",
            ));
        }
        let digest = validated
            .digest_sha256
            .ok_or(StoreError::IntegrityMismatch(
                "sealed media digest is missing",
            ))?;

        if stored.lifecycle == "sealed" {
            let payload = self.segment_event_payload(
                &stored.session_id,
                "segment_sealed",
                &receipt.segment_id,
                "segment-seal evidence is missing",
            )?;
            if payload_string(&payload, "track_id")? != receipt.track_id
                || payload_string(&payload, "open_token")? != receipt.open_token
                || payload_string(&payload, "relative_path")? != receipt.relative_path
                || payload_u64(&payload, "writer_generation")? != receipt.writer_generation
                || payload_u64(&payload, "final_sample_host_time")?
                    != receipt.final_sample_host_time
                || payload_u64(&payload, "sample_count")? != receipt.sample_count
                || payload_u64(&payload, "final_byte_length")? != receipt.final_byte_length
                || payload_string(&payload, "digest_sha256")? != digest
            {
                return Err(StoreError::IntegrityMismatch(
                    "repeated segment-seal receipt changed accepted evidence",
                ));
            }
            return Ok(SealedSegmentEvidence {
                session_id: receipt.session_id,
                segment_id: receipt.segment_id,
                sample_count: receipt.sample_count,
                final_byte_length: receipt.final_byte_length,
                digest_sha256: digest,
                segment_sealed: true,
                recording_started: false,
                last_journal_sequence: self.last_journal_sequence(&stored.session_id)?,
            });
        }
        if stored.lifecycle != "capturing" {
            return Err(StoreError::InvalidState(
                "segment is not awaiting seal evidence",
            ));
        }

        let mut payload = json!({
            "source_id": stored.source_id,
            "track_id": stored.track_id,
            "segment_id": receipt.segment_id,
            "open_token": stored.open_token,
            "writer_generation": stored.writer_generation,
            "relative_path": stored.relative_path,
            "final_sample_host_time": receipt.final_sample_host_time,
            "sample_count": receipt.sample_count,
            "final_byte_length": receipt.final_byte_length,
            "digest_sha256": digest,
            "file_device": expected_device,
            "file_inode": expected_inode,
        });
        self.annotate_segment_timing(&stored.session_id, &first_payload, &mut payload)?;
        let journal_record = self.append_session_journal(
            &receipt.session_id.0,
            "segment_sealed",
            Some(&receipt.relative_path),
            payload.clone(),
        )?;
        interrupt_media_if(failure, MediaFailurePoint::SegmentSealJournalSync)?;
        self.project_segment_seal(&receipt.session_id.0, &journal_record)?;
        interrupt_media_if(failure, MediaFailurePoint::SegmentSealDatabaseProjection)?;

        Ok(SealedSegmentEvidence {
            session_id: receipt.session_id,
            segment_id: receipt.segment_id,
            sample_count: receipt.sample_count,
            final_byte_length: receipt.final_byte_length,
            digest_sha256: payload_string(&payload, "digest_sha256")?.to_owned(),
            segment_sealed: true,
            recording_started: false,
            last_journal_sequence: journal_record.body.sequence,
        })
    }

    /// The required-source plan for the current capture span. A source that
    /// failed during Recording leaves the plan for later spans; its captured
    /// media stays journaled and playable.
    pub(crate) fn required_source_kinds(
        &self,
        session_id: &str,
    ) -> Result<Vec<MediaSourceKind>, StoreError> {
        let mut statement = self.connection.prepare(
            "SELECT kind FROM required_sources
             WHERE session_id = ?1 AND lifecycle != 'failed' ORDER BY kind",
        )?;
        statement
            .query_map([session_id], |row| row.get::<_, String>(0))?
            .map(|value| parse_source_kind(&value?))
            .collect()
    }

    pub(crate) fn active_source_kinds(
        &self,
        session_id: &str,
    ) -> Result<Vec<MediaSourceKind>, StoreError> {
        let mut statement = self.connection.prepare(
            "SELECT DISTINCT kind FROM sources
             WHERE session_id = ?1 AND lifecycle = 'capturing'
             ORDER BY kind",
        )?;
        statement
            .query_map([session_id], |row| row.get::<_, String>(0))?
            .map(|value| parse_source_kind(&value?))
            .collect()
    }

    pub(crate) fn session_media_files_open(&self, session_id: &str) -> Result<bool, StoreError> {
        self.connection
            .query_row(
                "SELECT media_files_open FROM sessions WHERE id = ?1",
                [session_id],
                |row| row.get(0),
            )
            .map_err(StoreError::Sqlite)
    }
}
