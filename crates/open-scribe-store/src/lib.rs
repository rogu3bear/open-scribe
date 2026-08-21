//! Native persistence and recovery boundary for Open Scribe.
//!
//! This crate owns the single SQLite writer and the independently durable
//! per-session recovery journal. It does not own media I/O and cannot authorize
//! `Recording`: a prepared session has durable intent but no open media.

#![forbid(unsafe_code)]

use std::collections::{BTreeMap, BTreeSet};
use std::ffi::OsStr;
use std::fmt;
use std::fs::{self, File, OpenOptions};
use std::io::{BufRead, BufReader, Write};
use std::os::fd::{AsFd, OwnedFd};
use std::path::{Component, Path, PathBuf};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use open_scribe_types::SessionId;
use rusqlite::{Connection, OpenFlags, Transaction, params};
use rustix::fs as fd_fs;
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use uuid::Uuid;

const SCHEMA_VERSION: i64 = 2;
const JOURNAL_VERSION: u32 = 1;
const MAX_TITLE_BYTES: usize = 512;
const MAX_DISPLAY_NAME_BYTES: usize = 512;
const MAX_JOURNAL_RECORD_BYTES: usize = 16 * 1024;
const DATABASE_NAME: &str = "Library.sqlite3";
const SESSIONS_DIRECTORY: &str = "Sessions";
const JOURNAL_NAME: &str = "recovery.jsonl";
const SESSION_SUBDIRECTORIES: [&str; 4] = ["audio", "video", "context", "exports"];
const MEDIA_FORMAT_CAF_PCM_S16LE: &str = "caf-pcm-s16le";
const MEDIA_SAMPLE_RATE_HZ: u32 = 48_000;
const CAF_HEADER: &[u8; 8] = b"caff\0\x01\0\0";

/// Origin is persisted independently from user-visible naming.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum SessionOrigin {
    Capture,
    Import,
}

impl SessionOrigin {
    const fn as_str(self) -> &'static str {
        match self {
            Self::Capture => "capture",
            Self::Import => "import",
        }
    }
}

/// Request to create durable intent for one future session.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct PrepareSessionRequest {
    pub title: String,
    pub origin: SessionOrigin,
}

/// Coarse evidence returned after both the journal and SQLite projection agree.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct PreparedSessionReceipt {
    pub session_id: SessionId,
    pub schema_version: u32,
    pub journal_version: u32,
    pub last_journal_sequence: u64,
    pub journal_durable: bool,
    pub database_projected: bool,
    pub media_files_open: bool,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum MediaSourceKind {
    Microphone,
    ApplicationAudio,
    SystemAudio,
}

impl MediaSourceKind {
    const fn as_str(self) -> &'static str {
        match self {
            Self::Microphone => "microphone",
            Self::ApplicationAudio => "application_audio",
            Self::SystemAudio => "system_audio",
        }
    }
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

/// Rust-validated first-sample evidence. Active-session recovery is not yet
/// implemented, so this evidence deliberately does not start Recording.
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

impl PreparedSessionReceipt {
    /// Preparation alone is deliberately insufficient to report Recording.
    #[must_use]
    pub const fn permits_recording(&self) -> bool {
        self.journal_durable && self.media_files_open
    }
}

/// Recovery result for one nonterminal database row or managed directory.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum RecoveryDisposition {
    Prepared,
    ProjectionRepaired,
    MediaOpenPrepared,
    MediaOpenProjectionRepaired,
    MediaOpenAwaitingReceipt,
    FirstSamplePrepared,
    FirstSampleProjectionRepaired,
    MissingMediaFile,
    InvalidMediaFile,
    MissingDirectory,
    MissingJournal,
    TruncatedJournal,
    MalformedJournal,
    IntegrityMismatch,
    UnsupportedJournalVersion,
    OrphanDirectory,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct RecoveryFinding {
    pub session_id: SessionId,
    pub disposition: RecoveryDisposition,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum FailurePoint {
    DatabaseIntent,
    SessionDirectory,
    JournalSync,
    DatabaseProjection,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum MediaFailurePoint {
    AuthorizationJournalSync,
    AuthorizationDatabaseProjection,
    ReceiptJournalSync,
    ReceiptDatabaseProjection,
    FirstSampleJournalSync,
    FirstSampleDatabaseProjection,
}

#[derive(Debug)]
pub enum StoreError {
    InvalidManagedRoot(&'static str),
    InvalidRequest(&'static str),
    InvalidState(&'static str),
    IntegrityMismatch(&'static str),
    Io(std::io::Error),
    Sqlite(rusqlite::Error),
    Json(serde_json::Error),
    JournalRecordTooLarge,
    InjectedInterruption,
}

impl fmt::Display for StoreError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::InvalidManagedRoot(reason) => write!(formatter, "invalid managed root: {reason}"),
            Self::InvalidRequest(reason) => write!(formatter, "invalid request: {reason}"),
            Self::InvalidState(reason) => write!(formatter, "invalid state: {reason}"),
            Self::IntegrityMismatch(reason) => write!(formatter, "integrity mismatch: {reason}"),
            Self::Io(error) => write!(formatter, "storage I/O failed: {error}"),
            Self::Sqlite(error) => write!(formatter, "SQLite operation failed: {error}"),
            Self::Json(error) => write!(formatter, "journal encoding failed: {error}"),
            Self::JournalRecordTooLarge => write!(formatter, "journal record exceeds size bound"),
            Self::InjectedInterruption => write!(formatter, "injected preparation interruption"),
        }
    }
}

impl std::error::Error for StoreError {}

impl From<std::io::Error> for StoreError {
    fn from(error: std::io::Error) -> Self {
        Self::Io(error)
    }
}

impl From<rusqlite::Error> for StoreError {
    fn from(error: rusqlite::Error) -> Self {
        Self::Sqlite(error)
    }
}

impl From<serde_json::Error> for StoreError {
    fn from(error: serde_json::Error) -> Self {
        Self::Json(error)
    }
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
struct JournalBody {
    version: u32,
    sequence: u64,
    event_id: String,
    session_id: String,
    event_kind: String,
    session_nanoseconds: i64,
    wall_time_milliseconds: i64,
    relative_path: Option<String>,
    payload: Value,
    prior_digest: Option<String>,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
struct JournalRecord {
    #[serde(flatten)]
    body: JournalBody,
    record_digest: String,
}

enum JournalValidation {
    Valid(Vec<JournalRecord>),
    Truncated,
    Malformed,
    IntegrityMismatch,
    UnsupportedVersion,
}

struct StoredMediaAuthorization {
    session_id: String,
    track_id: String,
    relative_path: String,
    media_format: String,
    lifecycle: String,
    open_token: String,
    writer_generation: u64,
    byte_length: Option<u64>,
    file_device: Option<u64>,
    file_inode: Option<u64>,
}

struct ValidatedMediaFile {
    byte_length: u64,
    device: u64,
    inode: u64,
}

#[derive(Clone, Copy)]
enum MediaLengthRequirement {
    Exact(u64),
    AtLeast(u64),
}

/// Native store with one owned SQLite writer connection.
pub struct SessionStore {
    managed_root: PathBuf,
    sessions_root: PathBuf,
    connection: Connection,
}

impl SessionStore {
    /// Opens or creates the managed root, configures SQLite, and applies schema v1.
    pub fn open(managed_root: impl AsRef<Path>) -> Result<Self, StoreError> {
        let managed_root = managed_root.as_ref().to_path_buf();
        validate_or_create_managed_root(&managed_root)?;

        let sessions_root = managed_root.join(SESSIONS_DIRECTORY);
        create_directory_if_missing(&sessions_root)?;

        let database_path = managed_root.join(DATABASE_NAME);
        let flags = OpenFlags::SQLITE_OPEN_READ_WRITE
            | OpenFlags::SQLITE_OPEN_CREATE
            | OpenFlags::SQLITE_OPEN_NO_MUTEX;
        let mut connection = Connection::open_with_flags(database_path, flags)?;
        configure_connection(&connection)?;
        apply_schema(&mut connection)?;

        Ok(Self {
            managed_root,
            sessions_root,
            connection,
        })
    }

    #[must_use]
    pub fn managed_root(&self) -> &Path {
        &self.managed_root
    }

    pub fn prepare_session(
        &mut self,
        request: PrepareSessionRequest,
    ) -> Result<PreparedSessionReceipt, StoreError> {
        self.prepare_session_inner(request, None)
    }

    /// Allocates one deterministic managed path before Swift opens media.
    pub fn authorize_media_open(
        &mut self,
        request: AuthorizeMediaOpenRequest,
    ) -> Result<MediaOpenAuthorization, StoreError> {
        self.authorize_media_open_inner(request, None)
    }

    /// Validates coarse Swift writer evidence and persists it without entering Recording.
    pub fn accept_media_open(
        &mut self,
        receipt: MediaOpenReceipt,
    ) -> Result<MediaOpenEvidence, StoreError> {
        self.accept_media_open_inner(receipt, None)
    }

    /// Persists coarse first-sample evidence without entering Recording.
    pub fn accept_first_sample(
        &mut self,
        receipt: FirstSampleReceipt,
    ) -> Result<FirstSampleEvidence, StoreError> {
        self.accept_first_sample_inner(receipt, None)
    }

    fn authorize_media_open_inner(
        &mut self,
        request: AuthorizeMediaOpenRequest,
        failure: Option<MediaFailurePoint>,
    ) -> Result<MediaOpenAuthorization, StoreError> {
        validate_media_request(&request)?;
        let (lifecycle, journal_durable, media_files_open): (String, bool, bool) = self
            .connection
            .query_row(
                "SELECT lifecycle, journal_durable, media_files_open FROM sessions WHERE id = ?1",
                [&request.session_id.0],
                |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?)),
            )
            .map_err(|error| match error {
                rusqlite::Error::QueryReturnedNoRows => {
                    StoreError::InvalidState("session does not exist")
                }
                other => StoreError::Sqlite(other),
            })?;
        if lifecycle != "preparing" || !journal_durable || media_files_open {
            return Err(StoreError::InvalidState(
                "session is not awaiting its initial media file",
            ));
        }
        let existing_tracks: i64 = self.connection.query_row(
            "SELECT COUNT(*) FROM tracks WHERE session_id = ?1",
            [&request.session_id.0],
            |row| row.get(0),
        )?;
        if existing_tracks != 0 {
            return Err(StoreError::InvalidState(
                "initial media authorization already exists",
            ));
        }

        let source_id = Uuid::now_v7().to_string();
        let track_id = Uuid::now_v7().to_string();
        let segment_id = Uuid::now_v7().to_string();
        let open_token = Uuid::now_v7().to_string();
        let writer_generation = 1_u64;
        let relative_path = format!("audio/{track_id}/000000-0.caf");
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
            "channels": 1,
            "mapped_start_nanoseconds": 0,
        });
        let journal_record = self.append_session_journal(
            &request.session_id.0,
            "segment_open_intent",
            Some(&relative_path),
            payload.clone(),
        )?;
        interrupt_media_if(failure, MediaFailurePoint::AuthorizationJournalSync)?;
        self.project_media_authorization(&request.session_id.0, &payload, &journal_record)?;
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
            channels: 1,
            mapped_start_nanoseconds: 0,
        })
    }

    fn accept_media_open_inner(
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
                )
                .map_err(|error| match error {
                    StoreError::Io(io_error) if io_error.kind() == std::io::ErrorKind::NotFound => {
                        StoreError::IntegrityMismatch("accepted media file is missing")
                    }
                    other => other,
                })?;
            if validated.device != expected_device || validated.inode != expected_inode {
                return Err(StoreError::IntegrityMismatch(
                    "accepted media file identity changed",
                ));
            }
            return Ok(MediaOpenEvidence {
                session_id: receipt.session_id,
                segment_id: receipt.segment_id,
                journal_durable: true,
                media_files_open: true,
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
        )?;
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
        self.project_media_open(&receipt.session_id.0, &payload, &journal_record)?;
        interrupt_media_if(failure, MediaFailurePoint::ReceiptDatabaseProjection)?;

        Ok(MediaOpenEvidence {
            session_id: receipt.session_id,
            segment_id: receipt.segment_id,
            journal_durable: true,
            media_files_open: true,
            recording_started: false,
            last_journal_sequence: journal_record.body.sequence,
        })
    }

    fn accept_first_sample_inner(
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
        )?;
        if validated.device != expected_device || validated.inode != expected_inode {
            return Err(StoreError::IntegrityMismatch(
                "accepted media file identity changed",
            ));
        }

        if stored.lifecycle == "capturing" {
            let payload: String = self.connection.query_row(
                "SELECT payload_json FROM session_events
                 WHERE session_id = ?1 AND event_kind = 'first_sample_captured'
                 ORDER BY sequence DESC LIMIT 1",
                [&stored.session_id],
                |row| row.get(0),
            )?;
            let payload: Value = serde_json::from_str(&payload)?;
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
                first_sample_session_nanoseconds: 0,
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
        let (session_lifecycle, journal_durable, media_files_open): (String, bool, bool) =
            self.connection.query_row(
                "SELECT lifecycle, journal_durable, media_files_open
                 FROM sessions WHERE id = ?1",
                [&stored.session_id],
                |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?)),
            )?;
        if session_lifecycle != "preparing" || !journal_durable || !media_files_open {
            return Err(StoreError::InvalidState(
                "session is not ready for first-sample evidence",
            ));
        }

        let payload = json!({
            "track_id": stored.track_id,
            "segment_id": receipt.segment_id,
            "open_token": stored.open_token,
            "writer_generation": stored.writer_generation,
            "relative_path": stored.relative_path,
            "first_sample_host_time": receipt.first_sample_host_time,
            "first_sample_frame_count": receipt.first_sample_frame_count,
            "first_sample_session_nanoseconds": 0,
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
        self.project_first_sample(&receipt.session_id.0, &payload, &journal_record)?;
        interrupt_media_if(failure, MediaFailurePoint::FirstSampleDatabaseProjection)?;

        Ok(FirstSampleEvidence {
            session_id: receipt.session_id,
            segment_id: receipt.segment_id,
            first_sample_session_nanoseconds: 0,
            journal_durable: true,
            media_files_open: true,
            first_sample_durable: true,
            recording_started: false,
            last_journal_sequence: journal_record.body.sequence,
        })
    }

    fn session_directory(&self, session_id: &str) -> Result<PathBuf, StoreError> {
        let directory = self.sessions_root.join(session_id);
        require_real_directory(&directory)?;
        Ok(directory)
    }

    fn append_session_journal(
        &self,
        session_id: &str,
        event_kind: &str,
        relative_path: Option<&str>,
        payload: Value,
    ) -> Result<JournalRecord, StoreError> {
        let session_directory = self.session_directory(session_id)?;
        let journal_path = session_directory.join(JOURNAL_NAME);
        let records = match validate_journal(&journal_path, session_id)? {
            JournalValidation::Valid(records) if !records.is_empty() => records,
            _ => {
                return Err(StoreError::IntegrityMismatch(
                    "session journal is not a valid append target",
                ));
            }
        };
        let previous = records.last().expect("validated non-empty journal");
        let body = JournalBody {
            version: JOURNAL_VERSION,
            sequence: previous.body.sequence + 1,
            event_id: Uuid::now_v7().to_string(),
            session_id: session_id.to_owned(),
            event_kind: event_kind.to_owned(),
            session_nanoseconds: 0,
            wall_time_milliseconds: wall_time_milliseconds(),
            relative_path: relative_path.map(str::to_owned),
            payload,
            prior_digest: Some(previous.record_digest.clone()),
        };
        let record = JournalRecord {
            record_digest: digest_json(&body)?,
            body,
        };
        let mut journal = OpenOptions::new().append(true).open(&journal_path)?;
        append_journal_record(&mut journal, &record)?;
        journal.sync_all()?;
        sync_directory(&session_directory)?;
        Ok(record)
    }

    fn project_media_authorization(
        &mut self,
        session_id: &str,
        payload: &Value,
        journal_record: &JournalRecord,
    ) -> Result<(), StoreError> {
        let source_id = payload_string(payload, "source_id")?;
        let source_kind = payload_string(payload, "source_kind")?;
        let source_display_name = payload_string(payload, "source_display_name")?;
        let track_id = payload_string(payload, "track_id")?;
        let segment_id = payload_string(payload, "segment_id")?;
        let open_token = payload_string(payload, "open_token")?;
        let writer_generation = payload_u64(payload, "writer_generation")?;
        let relative_path = payload_string(payload, "relative_path")?;
        let media_format = payload_string(payload, "media_format")?;
        let mapped_start_ns = payload_i64(payload, "mapped_start_nanoseconds")?;
        let (event_sequence, prior_digest) = next_database_event(&self.connection, session_id)?;
        let digest = event_digest(
            session_id,
            event_sequence,
            "segment_open_intent",
            payload,
            prior_digest.as_deref(),
        )?;
        let transaction = self.connection.transaction()?;
        transaction.execute(
            "INSERT OR IGNORE INTO sources (
                id, schema_version, session_id, kind, display_name, lifecycle
             ) VALUES (?1, ?2, ?3, ?4, ?5, 'opening')",
            params![
                source_id,
                SCHEMA_VERSION,
                session_id,
                source_kind,
                source_display_name
            ],
        )?;
        transaction.execute(
            "INSERT OR IGNORE INTO tracks (
                id, schema_version, session_id, source_id, kind, lifecycle
             ) VALUES (?1, ?2, ?3, ?4, 'audio', 'opening')",
            params![track_id, SCHEMA_VERSION, session_id, source_id],
        )?;
        transaction.execute(
            "INSERT OR IGNORE INTO segments (
                id, schema_version, session_id, track_id, sequence, relative_path,
                lifecycle, original_start, mapped_start_ns, media_format,
                sample_count, byte_length, digest, seal_state, recovery_state,
                open_token, writer_generation, file_device, file_inode
             ) VALUES (?1, ?2, ?3, ?4, 0, ?5, 'opening', NULL, ?6, ?7,
                       NULL, NULL, NULL, 'open', 'not_required', ?8, ?9, NULL, NULL)",
            params![
                segment_id,
                SCHEMA_VERSION,
                session_id,
                track_id,
                relative_path,
                mapped_start_ns,
                media_format,
                open_token,
                writer_generation as i64,
            ],
        )?;
        insert_event_with_id(
            &transaction,
            &journal_record.body.event_id,
            session_id,
            event_sequence,
            "segment_open_intent",
            journal_record.body.wall_time_milliseconds,
            payload,
            prior_digest.as_deref(),
            &digest,
        )?;
        transaction.commit()?;
        Ok(())
    }

    fn project_media_open(
        &mut self,
        session_id: &str,
        payload: &Value,
        journal_record: &JournalRecord,
    ) -> Result<(), StoreError> {
        let segment_id = payload_string(payload, "segment_id")?;
        let byte_length = payload_u64(payload, "initial_byte_length")?;
        let file_device = payload_u64(payload, "file_device")?;
        let file_inode = payload_u64(payload, "file_inode")?;
        let (event_sequence, prior_digest) = next_database_event(&self.connection, session_id)?;
        let digest = event_digest(
            session_id,
            event_sequence,
            "segment_opened",
            payload,
            prior_digest.as_deref(),
        )?;
        let now = wall_time_milliseconds();
        let transaction = self.connection.transaction()?;
        let changed = transaction.execute(
            "UPDATE segments
             SET lifecycle = 'open', byte_length = ?2, file_device = ?3, file_inode = ?4
             WHERE id = ?1 AND session_id = ?5 AND lifecycle = 'opening'",
            params![
                segment_id,
                byte_length as i64,
                file_device as i64,
                file_inode as i64,
                session_id
            ],
        )?;
        if changed != 1 {
            return Err(StoreError::InvalidState(
                "segment projection is not awaiting media-open evidence",
            ));
        }
        transaction.execute(
            "UPDATE sources SET lifecycle = 'open' WHERE session_id = ?1",
            [session_id],
        )?;
        transaction.execute(
            "UPDATE tracks SET lifecycle = 'open' WHERE session_id = ?1",
            [session_id],
        )?;
        transaction.execute(
            "UPDATE sessions
             SET media_files_open = 1, updated_at_ms = ?2
             WHERE id = ?1 AND lifecycle = 'preparing' AND journal_durable = 1",
            params![session_id, now],
        )?;
        insert_event_with_id(
            &transaction,
            &journal_record.body.event_id,
            session_id,
            event_sequence,
            "segment_opened",
            journal_record.body.wall_time_milliseconds,
            payload,
            prior_digest.as_deref(),
            &digest,
        )?;
        transaction.commit()?;
        Ok(())
    }

    fn project_first_sample(
        &mut self,
        session_id: &str,
        payload: &Value,
        journal_record: &JournalRecord,
    ) -> Result<(), StoreError> {
        let segment_id = payload_string(payload, "segment_id")?;
        let first_sample_host_time = payload_u64(payload, "first_sample_host_time")?;
        let _first_sample_frame_count = payload_u64(payload, "first_sample_frame_count")?;
        let (event_sequence, prior_digest) = next_database_event(&self.connection, session_id)?;
        let digest = event_digest(
            session_id,
            event_sequence,
            "first_sample_captured",
            payload,
            prior_digest.as_deref(),
        )?;
        let now = wall_time_milliseconds();
        let transaction = self.connection.transaction()?;
        let changed = transaction.execute(
            "UPDATE segments
             SET lifecycle = 'capturing', original_start = ?2,
                 mapped_start_ns = 0, sample_count = NULL
             WHERE id = ?1 AND session_id = ?3 AND lifecycle = 'open'",
            params![segment_id, first_sample_host_time as i64, session_id],
        )?;
        if changed != 1 {
            return Err(StoreError::InvalidState(
                "segment projection is not awaiting first-sample evidence",
            ));
        }
        transaction.execute(
            "UPDATE sources SET lifecycle = 'capturing'
             WHERE session_id = ?1 AND lifecycle = 'open'",
            [session_id],
        )?;
        transaction.execute(
            "UPDATE tracks SET lifecycle = 'capturing'
             WHERE session_id = ?1 AND lifecycle = 'open'",
            [session_id],
        )?;
        transaction.execute(
            "UPDATE sessions SET updated_at_ms = ?2
             WHERE id = ?1 AND lifecycle = 'preparing'
               AND journal_durable = 1 AND media_files_open = 1",
            params![session_id, now],
        )?;
        insert_event_with_id(
            &transaction,
            &journal_record.body.event_id,
            session_id,
            event_sequence,
            "first_sample_captured",
            journal_record.body.wall_time_milliseconds,
            payload,
            prior_digest.as_deref(),
            &digest,
        )?;
        transaction.commit()?;
        Ok(())
    }

    fn media_authorization_row(
        &self,
        segment_id: &str,
    ) -> Result<StoredMediaAuthorization, StoreError> {
        self.connection
            .query_row(
                "SELECT session_id, track_id, relative_path, media_format, lifecycle,
                        open_token, writer_generation, byte_length, file_device, file_inode
                 FROM segments WHERE id = ?1",
                [segment_id],
                |row| {
                    Ok(StoredMediaAuthorization {
                        session_id: row.get(0)?,
                        track_id: row.get(1)?,
                        relative_path: row.get(2)?,
                        media_format: row.get(3)?,
                        lifecycle: row.get(4)?,
                        open_token: row.get(5)?,
                        writer_generation: row.get::<_, i64>(6)? as u64,
                        byte_length: row.get::<_, Option<i64>>(7)?.map(|value| value as u64),
                        file_device: row.get::<_, Option<i64>>(8)?.map(|value| value as u64),
                        file_inode: row.get::<_, Option<i64>>(9)?.map(|value| value as u64),
                    })
                },
            )
            .map_err(|error| match error {
                rusqlite::Error::QueryReturnedNoRows => {
                    StoreError::InvalidState("media authorization does not exist")
                }
                other => StoreError::Sqlite(other),
            })
    }

    fn validate_media_file(
        &self,
        session_id: &str,
        relative_path: &str,
        length_requirement: MediaLengthRequirement,
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
        if *audio_component != OsStr::new("audio") {
            return Err(StoreError::IntegrityMismatch(
                "media path is outside the audio directory",
            ));
        }

        let audio = self.open_managed_audio_directory(session_id)?;
        let track = open_managed_directory_at(&audio, track_component)?;
        let media_fd = fd_fs::openat(
            &track,
            *file_component,
            fd_fs::OFlags::RDWR | fd_fs::OFlags::CLOEXEC | fd_fs::OFlags::NOFOLLOW,
            fd_fs::Mode::empty(),
        )
        .map_err(|error| {
            if error == rustix::io::Errno::NOENT {
                StoreError::IntegrityMismatch("accepted media file is missing")
            } else {
                StoreError::IntegrityMismatch("media file is missing, replaced, or symlinked")
            }
        })?;
        let stat = fd_fs::fstat(&media_fd)
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
        use std::io::Read;
        let mut file = File::from(media_fd);
        file.read_exact(&mut header)?;
        if &header != CAF_HEADER {
            return Err(StoreError::IntegrityMismatch("media header is not CAF"));
        }
        file.sync_all()?;
        fd_fs::fsync(&track).map_err(|_| {
            StoreError::IntegrityMismatch("media directory could not be synchronized")
        })?;
        Ok(ValidatedMediaFile {
            byte_length,
            device: stat.st_dev as u64,
            inode: stat.st_ino as u64,
        })
    }

    fn open_managed_audio_directory(&self, session_id: &str) -> Result<OwnedFd, StoreError> {
        let managed_root = open_managed_directory(&self.managed_root)?;
        let sessions = open_managed_directory_at(&managed_root, OsStr::new(SESSIONS_DIRECTORY))?;
        let session = open_managed_directory_at(&sessions, OsStr::new(session_id))?;
        open_managed_directory_at(&session, OsStr::new("audio"))
    }

    fn last_journal_sequence(&self, session_id: &str) -> Result<u64, StoreError> {
        let journal_path = self.session_directory(session_id)?.join(JOURNAL_NAME);
        match validate_journal(&journal_path, session_id)? {
            JournalValidation::Valid(records) => records
                .last()
                .map(|record| record.body.sequence)
                .ok_or(StoreError::IntegrityMismatch("session journal is empty")),
            _ => Err(StoreError::IntegrityMismatch("session journal is invalid")),
        }
    }

    /// Reconciles preparation evidence without claiming media or recording.
    pub fn recover_preparations(&mut self) -> Result<Vec<RecoveryFinding>, StoreError> {
        let mut database_sessions = BTreeMap::new();
        {
            let mut statement = self.connection.prepare(
                "SELECT id, journal_durable FROM sessions WHERE lifecycle = 'preparing' ORDER BY id",
            )?;
            let rows = statement.query_map([], |row| {
                Ok((row.get::<_, String>(0)?, row.get::<_, bool>(1)?))
            })?;
            for row in rows {
                let (id, journal_durable) = row?;
                database_sessions.insert(id, journal_durable);
            }
        }

        let mut directory_sessions = BTreeSet::new();
        for entry in fs::read_dir(&self.sessions_root)? {
            let entry = entry?;
            if entry.file_type()?.is_dir() {
                directory_sessions.insert(entry.file_name().to_string_lossy().into_owned());
            }
        }

        let mut findings = Vec::new();
        for (session_id, journal_durable) in database_sessions {
            directory_sessions.remove(&session_id);
            let session_directory = self.sessions_root.join(&session_id);
            match fs::symlink_metadata(&session_directory) {
                Ok(metadata) if metadata.is_dir() && !metadata.file_type().is_symlink() => {}
                Ok(_) => {
                    findings.push(finding(&session_id, RecoveryDisposition::IntegrityMismatch));
                    continue;
                }
                Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
                    findings.push(finding(&session_id, RecoveryDisposition::MissingDirectory));
                    continue;
                }
                Err(error) => return Err(error.into()),
            }

            let journal_path = session_directory.join(JOURNAL_NAME);
            match fs::symlink_metadata(&journal_path) {
                Ok(_) => {}
                Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
                    findings.push(finding(&session_id, RecoveryDisposition::MissingJournal));
                    continue;
                }
                Err(error) => return Err(error.into()),
            }

            match validate_journal(&journal_path, &session_id)? {
                JournalValidation::Valid(records) if journal_has_directory_ready(&records) => {
                    let disposition =
                        self.recover_valid_journal(&session_id, journal_durable, &records)?;
                    findings.push(finding(&session_id, disposition));
                }
                JournalValidation::Valid(_) => {
                    findings.push(finding(&session_id, RecoveryDisposition::MissingJournal))
                }
                JournalValidation::Truncated => {
                    findings.push(finding(&session_id, RecoveryDisposition::TruncatedJournal))
                }
                JournalValidation::Malformed => {
                    findings.push(finding(&session_id, RecoveryDisposition::MalformedJournal))
                }
                JournalValidation::IntegrityMismatch => {
                    findings.push(finding(&session_id, RecoveryDisposition::IntegrityMismatch))
                }
                JournalValidation::UnsupportedVersion => findings.push(finding(
                    &session_id,
                    RecoveryDisposition::UnsupportedJournalVersion,
                )),
            }
        }

        for session_id in directory_sessions {
            findings.push(finding(&session_id, RecoveryDisposition::OrphanDirectory));
        }
        findings.sort_by(|left, right| left.session_id.0.cmp(&right.session_id.0));
        Ok(findings)
    }

    fn recover_valid_journal(
        &mut self,
        session_id: &str,
        journal_durable: bool,
        records: &[JournalRecord],
    ) -> Result<RecoveryDisposition, StoreError> {
        let repaired_directory = if journal_durable {
            false
        } else {
            self.repair_directory_projection(session_id, records)?;
            true
        };
        let authorization_record = records
            .iter()
            .rev()
            .find(|record| record.body.event_kind == "segment_open_intent");
        let opened_record = records
            .iter()
            .rev()
            .find(|record| record.body.event_kind == "segment_opened");
        let first_sample_record = records
            .iter()
            .rev()
            .find(|record| record.body.event_kind == "first_sample_captured");

        let Some(authorization_record) = authorization_record else {
            return Ok(if repaired_directory {
                RecoveryDisposition::ProjectionRepaired
            } else {
                RecoveryDisposition::Prepared
            });
        };
        let segment_id = payload_string(&authorization_record.body.payload, "segment_id")?;
        let projected: bool = self.connection.query_row(
            "SELECT EXISTS(SELECT 1 FROM segments WHERE id = ?1 AND session_id = ?2)",
            params![segment_id, session_id],
            |row| row.get(0),
        )?;
        if !projected {
            self.project_media_authorization(
                session_id,
                &authorization_record.body.payload,
                authorization_record,
            )?;
        }

        if let Some(opened_record) = opened_record {
            let relative_path = payload_string(&opened_record.body.payload, "relative_path")?;
            let byte_length = payload_u64(&opened_record.body.payload, "initial_byte_length")?;
            let validated = match self.validate_media_file(
                session_id,
                relative_path,
                MediaLengthRequirement::AtLeast(byte_length),
            ) {
                Ok(validated) => validated,
                Err(_) => {
                    return Ok(classify_media_path(
                        &self.session_directory(session_id)?.join(relative_path),
                    ));
                }
            };
            let expected_device = payload_u64(&opened_record.body.payload, "file_device")?;
            let expected_inode = payload_u64(&opened_record.body.payload, "file_inode")?;
            if validated.device != expected_device || validated.inode != expected_inode {
                return Ok(RecoveryDisposition::InvalidMediaFile);
            }
            let media_open: bool = self.connection.query_row(
                "SELECT media_files_open FROM sessions WHERE id = ?1",
                [session_id],
                |row| row.get(0),
            )?;
            if !media_open {
                self.project_media_open(session_id, &opened_record.body.payload, opened_record)?;
            }

            if let Some(first_sample_record) = first_sample_record {
                let payload = &first_sample_record.body.payload;
                if payload_string(payload, "segment_id")? != segment_id
                    || payload_string(payload, "relative_path")? != relative_path
                    || payload_u64(payload, "file_device")? != expected_device
                    || payload_u64(payload, "file_inode")? != expected_inode
                    || payload_i64(payload, "first_sample_session_nanoseconds")? != 0
                {
                    return Ok(RecoveryDisposition::IntegrityMismatch);
                }
                let observed_byte_length = payload_u64(payload, "observed_byte_length")?;
                if self
                    .validate_media_file(
                        session_id,
                        relative_path,
                        MediaLengthRequirement::AtLeast(observed_byte_length),
                    )
                    .is_err()
                {
                    return Ok(RecoveryDisposition::InvalidMediaFile);
                }
                let segment_lifecycle: String = self.connection.query_row(
                    "SELECT lifecycle FROM segments WHERE id = ?1 AND session_id = ?2",
                    params![segment_id, session_id],
                    |row| row.get(0),
                )?;
                if segment_lifecycle == "capturing" {
                    return Ok(RecoveryDisposition::FirstSamplePrepared);
                }
                if segment_lifecycle != "open" {
                    return Ok(RecoveryDisposition::IntegrityMismatch);
                }
                self.project_first_sample(session_id, payload, first_sample_record)?;
                return Ok(RecoveryDisposition::FirstSampleProjectionRepaired);
            }

            return Ok(if media_open {
                RecoveryDisposition::MediaOpenPrepared
            } else {
                RecoveryDisposition::MediaOpenProjectionRepaired
            });
        }

        let relative_path = payload_string(&authorization_record.body.payload, "relative_path")?;
        let media_path = self.session_directory(session_id)?.join(relative_path);
        let metadata = match fs::symlink_metadata(&media_path) {
            Ok(metadata) => metadata,
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
                return Ok(RecoveryDisposition::MissingMediaFile);
            }
            Err(error) => return Err(error.into()),
        };
        if self
            .validate_media_file(
                session_id,
                relative_path,
                MediaLengthRequirement::Exact(metadata.len()),
            )
            .is_ok()
        {
            Ok(RecoveryDisposition::MediaOpenAwaitingReceipt)
        } else {
            Ok(RecoveryDisposition::InvalidMediaFile)
        }
    }

    fn prepare_session_inner(
        &mut self,
        request: PrepareSessionRequest,
        failure: Option<FailurePoint>,
    ) -> Result<PreparedSessionReceipt, StoreError> {
        validate_request(&request)?;
        require_real_directory(&self.sessions_root)?;
        let session_id = Uuid::now_v7().to_string();
        let now = wall_time_milliseconds();

        let intent_payload = json!({ "origin": request.origin.as_str() });
        let intent_digest = event_digest(
            &session_id,
            1,
            "session_create_intent",
            &intent_payload,
            None,
        )?;
        {
            let transaction = self.connection.transaction()?;
            transaction.execute(
                "INSERT INTO sessions (
                    id, schema_version, title, origin, lifecycle, health,
                    journal_durable, media_files_open, created_at_ms, updated_at_ms
                 ) VALUES (?1, ?2, ?3, ?4, 'preparing', 'healthy', 0, 0, ?5, ?5)",
                params![
                    session_id,
                    SCHEMA_VERSION,
                    request.title,
                    request.origin.as_str(),
                    now
                ],
            )?;
            insert_event(
                &transaction,
                &session_id,
                1,
                "session_create_intent",
                now,
                &intent_payload,
                None,
                &intent_digest,
            )?;
            transaction.commit()?;
        }
        interrupt_if(failure, FailurePoint::DatabaseIntent)?;

        let session_directory = self.sessions_root.join(&session_id);
        fs::create_dir(&session_directory)?;
        for subdirectory in SESSION_SUBDIRECTORIES {
            fs::create_dir(session_directory.join(subdirectory))?;
        }
        sync_directory(&session_directory)?;
        sync_directory(&self.sessions_root)?;
        interrupt_if(failure, FailurePoint::SessionDirectory)?;

        let journal_path = session_directory.join(JOURNAL_NAME);
        let mut journal = OpenOptions::new()
            .create_new(true)
            .write(true)
            .open(&journal_path)?;
        let record = new_journal_record(&session_id, now)?;
        append_journal_record(&mut journal, &record)?;
        journal.sync_all()?;
        sync_directory(&session_directory)?;
        interrupt_if(failure, FailurePoint::JournalSync)?;

        let directory_payload = json!({ "relative_path": "." });
        let directory_digest = event_digest(
            &session_id,
            2,
            "session_directory_ready",
            &directory_payload,
            Some(&intent_digest),
        )?;
        {
            let transaction = self.connection.transaction()?;
            insert_event(
                &transaction,
                &session_id,
                2,
                "session_directory_ready",
                now,
                &directory_payload,
                Some(&intent_digest),
                &directory_digest,
            )?;
            transaction.execute(
                "UPDATE sessions
                 SET journal_durable = 1, updated_at_ms = ?2
                 WHERE id = ?1 AND lifecycle = 'preparing'",
                params![session_id, now],
            )?;
            transaction.commit()?;
        }
        interrupt_if(failure, FailurePoint::DatabaseProjection)?;

        Ok(PreparedSessionReceipt {
            session_id: SessionId(session_id),
            schema_version: SCHEMA_VERSION as u32,
            journal_version: JOURNAL_VERSION,
            last_journal_sequence: record.body.sequence,
            journal_durable: true,
            database_projected: true,
            media_files_open: false,
        })
    }

    fn repair_directory_projection(
        &mut self,
        session_id: &str,
        records: &[JournalRecord],
    ) -> Result<(), StoreError> {
        let now = wall_time_milliseconds();
        let journal_record = records.last().expect("validated non-empty journal");
        let event_exists: bool = self.connection.query_row(
            "SELECT EXISTS(
                SELECT 1 FROM session_events
                WHERE session_id = ?1 AND event_kind = 'session_directory_ready'
             )",
            [session_id],
            |row| row.get(0),
        )?;

        let transaction = self.connection.transaction()?;
        if !event_exists {
            let (sequence, prior_digest): (i64, Option<String>) = transaction.query_row(
                "SELECT COALESCE(MAX(sequence), 0) + 1,
                        (SELECT digest FROM session_events
                         WHERE session_id = ?1 ORDER BY sequence DESC LIMIT 1)
                 FROM session_events WHERE session_id = ?1",
                [session_id],
                |row| Ok((row.get(0)?, row.get(1)?)),
            )?;
            let payload = json!({
                "recovered_from_journal_digest": journal_record.record_digest,
            });
            let digest = event_digest(
                session_id,
                sequence as u64,
                "session_directory_ready",
                &payload,
                prior_digest.as_deref(),
            )?;
            insert_event(
                &transaction,
                session_id,
                sequence as u64,
                "session_directory_ready",
                now,
                &payload,
                prior_digest.as_deref(),
                &digest,
            )?;
        }
        transaction.execute(
            "UPDATE sessions SET journal_durable = 1, updated_at_ms = ?2 WHERE id = ?1",
            params![session_id, now],
        )?;
        transaction.execute(
            "INSERT INTO recovery_runs (
                id, schema_version, session_id, disposition, created_at_ms
             ) VALUES (?1, ?2, ?3, 'projection_repaired', ?4)",
            params![Uuid::now_v7().to_string(), SCHEMA_VERSION, session_id, now],
        )?;
        transaction.commit()?;
        Ok(())
    }
}

fn configure_connection(connection: &Connection) -> Result<(), StoreError> {
    connection.busy_timeout(Duration::from_secs(5))?;
    connection.pragma_update(None, "foreign_keys", true)?;
    let journal_mode: String =
        connection.query_row("PRAGMA journal_mode = WAL", [], |row| row.get(0))?;
    if !journal_mode.eq_ignore_ascii_case("wal") {
        return Err(StoreError::InvalidManagedRoot("SQLite WAL unavailable"));
    }
    connection.pragma_update(None, "synchronous", "FULL")?;
    connection.pragma_update(None, "wal_autocheckpoint", 1000_i64)?;

    let foreign_keys: bool = connection.query_row("PRAGMA foreign_keys", [], |row| row.get(0))?;
    let synchronous: i64 = connection.query_row("PRAGMA synchronous", [], |row| row.get(0))?;
    if !foreign_keys || synchronous != 2 {
        return Err(StoreError::InvalidManagedRoot(
            "required SQLite durability settings were not applied",
        ));
    }
    Ok(())
}

fn apply_schema(connection: &mut Connection) -> Result<(), StoreError> {
    let transaction = connection.transaction()?;
    transaction.execute_batch(
        "CREATE TABLE IF NOT EXISTS schema_migrations (
            version INTEGER PRIMARY KEY,
            applied_at_ms INTEGER NOT NULL
        );
        CREATE TABLE IF NOT EXISTS sessions (
            id TEXT PRIMARY KEY,
            schema_version INTEGER NOT NULL,
            title TEXT NOT NULL,
            origin TEXT NOT NULL CHECK (origin IN ('capture', 'import')),
            lifecycle TEXT NOT NULL CHECK (
                lifecycle IN ('preparing', 'recording', 'paused', 'finalizing',
                              'ready_for_review', 'interrupted', 'deleted')
            ),
            health TEXT NOT NULL CHECK (health IN ('healthy', 'degraded')),
            journal_durable INTEGER NOT NULL CHECK (journal_durable IN (0, 1)),
            media_files_open INTEGER NOT NULL CHECK (media_files_open IN (0, 1)),
            created_at_ms INTEGER NOT NULL,
            updated_at_ms INTEGER NOT NULL
        );
        CREATE TABLE IF NOT EXISTS sources (
            id TEXT PRIMARY KEY,
            schema_version INTEGER NOT NULL,
            session_id TEXT NOT NULL REFERENCES sessions(id),
            kind TEXT NOT NULL,
            display_name TEXT NOT NULL,
            lifecycle TEXT NOT NULL,
            UNIQUE(session_id, id)
        );
        CREATE TABLE IF NOT EXISTS tracks (
            id TEXT PRIMARY KEY,
            schema_version INTEGER NOT NULL,
            session_id TEXT NOT NULL REFERENCES sessions(id),
            source_id TEXT NOT NULL REFERENCES sources(id),
            kind TEXT NOT NULL,
            lifecycle TEXT NOT NULL
        );
        CREATE TABLE IF NOT EXISTS segments (
            id TEXT PRIMARY KEY,
            schema_version INTEGER NOT NULL,
            session_id TEXT NOT NULL REFERENCES sessions(id),
            track_id TEXT NOT NULL REFERENCES tracks(id),
            sequence INTEGER NOT NULL,
            relative_path TEXT NOT NULL,
            lifecycle TEXT NOT NULL,
            original_start INTEGER,
            mapped_start_ns INTEGER NOT NULL,
            media_format TEXT NOT NULL,
            sample_count INTEGER,
            byte_length INTEGER,
            digest TEXT,
            seal_state TEXT NOT NULL,
            recovery_state TEXT NOT NULL,
            open_token TEXT,
            writer_generation INTEGER NOT NULL DEFAULT 0,
            file_device INTEGER,
            file_inode INTEGER,
            UNIQUE(track_id, sequence)
        );
        CREATE TABLE IF NOT EXISTS session_events (
            id TEXT PRIMARY KEY,
            schema_version INTEGER NOT NULL,
            session_id TEXT NOT NULL REFERENCES sessions(id),
            sequence INTEGER NOT NULL,
            event_kind TEXT NOT NULL,
            session_nanoseconds INTEGER NOT NULL,
            wall_time_ms INTEGER NOT NULL,
            payload_json TEXT NOT NULL,
            prior_digest TEXT,
            digest TEXT NOT NULL,
            UNIQUE(session_id, sequence)
        );
        CREATE TABLE IF NOT EXISTS markers (
            id TEXT PRIMARY KEY,
            schema_version INTEGER NOT NULL,
            session_id TEXT NOT NULL REFERENCES sessions(id),
            session_nanoseconds INTEGER NOT NULL,
            label TEXT
        );
        CREATE TABLE IF NOT EXISTS imports (
            id TEXT PRIMARY KEY,
            schema_version INTEGER NOT NULL,
            session_id TEXT NOT NULL REFERENCES sessions(id),
            relative_path TEXT NOT NULL,
            source_digest TEXT NOT NULL,
            created_at_ms INTEGER NOT NULL
        );
        CREATE TABLE IF NOT EXISTS deletion_receipts (
            id TEXT PRIMARY KEY,
            schema_version INTEGER NOT NULL,
            session_id TEXT NOT NULL REFERENCES sessions(id),
            trash_reference TEXT,
            created_at_ms INTEGER NOT NULL
        );
        CREATE TABLE IF NOT EXISTS recovery_runs (
            id TEXT PRIMARY KEY,
            schema_version INTEGER NOT NULL,
            session_id TEXT NOT NULL REFERENCES sessions(id),
            disposition TEXT NOT NULL,
            created_at_ms INTEGER NOT NULL
        );",
    )?;
    let segment_columns: BTreeSet<String> = {
        let mut statement = transaction.prepare("PRAGMA table_info(segments)")?;
        statement
            .query_map([], |row| row.get::<_, String>(1))?
            .collect::<Result<BTreeSet<_>, _>>()?
    };
    for (name, declaration) in [
        ("open_token", "TEXT"),
        ("writer_generation", "INTEGER NOT NULL DEFAULT 0"),
        ("file_device", "INTEGER"),
        ("file_inode", "INTEGER"),
    ] {
        if !segment_columns.contains(name) {
            transaction.execute_batch(&format!(
                "ALTER TABLE segments ADD COLUMN {name} {declaration};"
            ))?;
        }
    }
    let applied_at = wall_time_milliseconds();
    transaction.execute(
        "INSERT OR IGNORE INTO schema_migrations (version, applied_at_ms) VALUES (1, ?1)",
        [applied_at],
    )?;
    transaction.execute(
        "INSERT OR IGNORE INTO schema_migrations (version, applied_at_ms) VALUES (2, ?1)",
        [applied_at],
    )?;
    transaction.commit()?;
    Ok(())
}

#[allow(clippy::too_many_arguments)]
fn insert_event(
    transaction: &Transaction<'_>,
    session_id: &str,
    sequence: u64,
    event_kind: &str,
    wall_time_ms: i64,
    payload: &Value,
    prior_digest: Option<&str>,
    digest: &str,
) -> Result<(), StoreError> {
    insert_event_with_id(
        transaction,
        &Uuid::now_v7().to_string(),
        session_id,
        sequence,
        event_kind,
        wall_time_ms,
        payload,
        prior_digest,
        digest,
    )
}

#[allow(clippy::too_many_arguments)]
fn insert_event_with_id(
    transaction: &Transaction<'_>,
    event_id: &str,
    session_id: &str,
    sequence: u64,
    event_kind: &str,
    wall_time_ms: i64,
    payload: &Value,
    prior_digest: Option<&str>,
    digest: &str,
) -> Result<(), StoreError> {
    transaction.execute(
        "INSERT INTO session_events (
            id, schema_version, session_id, sequence, event_kind,
            session_nanoseconds, wall_time_ms, payload_json, prior_digest, digest
         ) VALUES (?1, ?2, ?3, ?4, ?5, 0, ?6, ?7, ?8, ?9)",
        params![
            event_id,
            SCHEMA_VERSION,
            session_id,
            sequence as i64,
            event_kind,
            wall_time_ms,
            serde_json::to_string(payload)?,
            prior_digest,
            digest
        ],
    )?;
    Ok(())
}

fn new_journal_record(session_id: &str, now: i64) -> Result<JournalRecord, StoreError> {
    let body = JournalBody {
        version: JOURNAL_VERSION,
        sequence: 1,
        event_id: Uuid::now_v7().to_string(),
        session_id: session_id.to_owned(),
        event_kind: "session_directory_ready".to_owned(),
        session_nanoseconds: 0,
        wall_time_milliseconds: now,
        relative_path: Some(".".to_owned()),
        payload: json!({ "subdirectories": SESSION_SUBDIRECTORIES }),
        prior_digest: None,
    };
    let record_digest = digest_json(&body)?;
    Ok(JournalRecord {
        body,
        record_digest,
    })
}

fn append_journal_record(file: &mut File, record: &JournalRecord) -> Result<(), StoreError> {
    let encoded = serde_json::to_vec(record)?;
    if encoded.len() > MAX_JOURNAL_RECORD_BYTES {
        return Err(StoreError::JournalRecordTooLarge);
    }
    file.write_all(&encoded)?;
    file.write_all(b"\n")?;
    Ok(())
}

fn validate_journal(
    path: &Path,
    expected_session_id: &str,
) -> Result<JournalValidation, StoreError> {
    let metadata = fs::symlink_metadata(path)?;
    if metadata.file_type().is_symlink() || !metadata.is_file() {
        return Ok(JournalValidation::IntegrityMismatch);
    }
    let bytes = fs::read(path)?;
    if bytes.is_empty() || !bytes.ends_with(b"\n") {
        return Ok(JournalValidation::Truncated);
    }

    let mut records = Vec::new();
    let mut expected_sequence = 1_u64;
    let mut prior_digest: Option<String> = None;
    for line in BufReader::new(bytes.as_slice()).split(b'\n') {
        let line = line?;
        if line.is_empty() {
            continue;
        }
        if line.len() > MAX_JOURNAL_RECORD_BYTES {
            return Ok(JournalValidation::Malformed);
        }
        let record: JournalRecord = match serde_json::from_slice(&line) {
            Ok(record) => record,
            Err(_) => return Ok(JournalValidation::Malformed),
        };
        if record.body.version != JOURNAL_VERSION {
            return Ok(JournalValidation::UnsupportedVersion);
        }
        if record.body.sequence != expected_sequence
            || record.body.session_id != expected_session_id
            || record.body.prior_digest != prior_digest
            || record.record_digest != digest_json(&record.body)?
            || !record
                .body
                .relative_path
                .as_deref()
                .is_none_or(valid_relative_path)
        {
            return Ok(JournalValidation::IntegrityMismatch);
        }
        expected_sequence += 1;
        prior_digest = Some(record.record_digest.clone());
        records.push(record);
    }
    Ok(JournalValidation::Valid(records))
}

fn journal_has_directory_ready(records: &[JournalRecord]) -> bool {
    records
        .iter()
        .any(|record| record.body.event_kind == "session_directory_ready")
}

fn validate_or_create_managed_root(path: &Path) -> Result<(), StoreError> {
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

fn create_directory_if_missing(path: &Path) -> Result<(), StoreError> {
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

fn require_real_directory(path: &Path) -> Result<(), StoreError> {
    let metadata = fs::symlink_metadata(path)?;
    if metadata.file_type().is_symlink() || !metadata.is_dir() {
        return Err(StoreError::InvalidManagedRoot(
            "managed child must remain a real directory",
        ));
    }
    Ok(())
}

fn directory_open_flags() -> fd_fs::OFlags {
    fd_fs::OFlags::RDONLY
        | fd_fs::OFlags::DIRECTORY
        | fd_fs::OFlags::CLOEXEC
        | fd_fs::OFlags::NOFOLLOW
}

fn open_managed_directory(path: &Path) -> Result<OwnedFd, StoreError> {
    fd_fs::open(path, directory_open_flags(), fd_fs::Mode::empty()).map_err(|_| {
        StoreError::IntegrityMismatch("managed media ancestor is missing, replaced, or symlinked")
    })
}

fn open_managed_directory_at(parent: &impl AsFd, name: &OsStr) -> Result<OwnedFd, StoreError> {
    fd_fs::openat(parent, name, directory_open_flags(), fd_fs::Mode::empty()).map_err(|_| {
        StoreError::IntegrityMismatch("managed media ancestor is missing, replaced, or symlinked")
    })
}

fn validate_request(request: &PrepareSessionRequest) -> Result<(), StoreError> {
    let title = request.title.trim();
    if title.is_empty() {
        return Err(StoreError::InvalidRequest("title is empty"));
    }
    if request.title.len() > MAX_TITLE_BYTES {
        return Err(StoreError::InvalidRequest("title exceeds byte limit"));
    }
    Ok(())
}

fn validate_media_request(request: &AuthorizeMediaOpenRequest) -> Result<(), StoreError> {
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

fn validate_media_receipt_shape(receipt: &MediaOpenReceipt) -> Result<(), StoreError> {
    if Uuid::parse_str(&receipt.session_id.0).is_err()
        || Uuid::parse_str(&receipt.track_id).is_err()
        || Uuid::parse_str(&receipt.segment_id).is_err()
        || Uuid::parse_str(&receipt.open_token).is_err()
    {
        return Err(StoreError::InvalidRequest(
            "media receipt identity is not a UUID",
        ));
    }
    if receipt.writer_generation != 1
        || receipt.media_format != MEDIA_FORMAT_CAF_PCM_S16LE
        || receipt.sample_rate_hz != MEDIA_SAMPLE_RATE_HZ
        || receipt.channels != 1
        || !valid_media_relative_path(&receipt.relative_path)
    {
        return Err(StoreError::InvalidRequest(
            "media receipt format or path is unsupported",
        ));
    }
    Ok(())
}

fn validate_first_sample_receipt_shape(receipt: &FirstSampleReceipt) -> Result<(), StoreError> {
    if Uuid::parse_str(&receipt.session_id.0).is_err()
        || Uuid::parse_str(&receipt.track_id).is_err()
        || Uuid::parse_str(&receipt.segment_id).is_err()
        || Uuid::parse_str(&receipt.open_token).is_err()
    {
        return Err(StoreError::InvalidRequest(
            "first-sample receipt identity is not a UUID",
        ));
    }
    if receipt.writer_generation != 1 || !valid_media_relative_path(&receipt.relative_path) {
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

fn valid_relative_path(relative_path: &str) -> bool {
    let path = Path::new(relative_path);
    !path.is_absolute()
        && path
            .components()
            .all(|component| matches!(component, Component::Normal(_) | Component::CurDir))
}

fn valid_media_relative_path(relative_path: &str) -> bool {
    valid_relative_path(relative_path)
        && relative_path.starts_with("audio/")
        && relative_path.ends_with(".caf")
        && Path::new(relative_path).components().count() == 3
}

fn payload_string<'a>(payload: &'a Value, key: &str) -> Result<&'a str, StoreError> {
    payload
        .get(key)
        .and_then(Value::as_str)
        .ok_or(StoreError::IntegrityMismatch(
            "journal payload is missing a string field",
        ))
}

fn payload_u64(payload: &Value, key: &str) -> Result<u64, StoreError> {
    payload
        .get(key)
        .and_then(Value::as_u64)
        .ok_or(StoreError::IntegrityMismatch(
            "journal payload is missing an unsigned field",
        ))
}

fn payload_i64(payload: &Value, key: &str) -> Result<i64, StoreError> {
    payload
        .get(key)
        .and_then(Value::as_i64)
        .ok_or(StoreError::IntegrityMismatch(
            "journal payload is missing a signed field",
        ))
}

fn next_database_event(
    connection: &Connection,
    session_id: &str,
) -> Result<(u64, Option<String>), StoreError> {
    let result: (i64, Option<String>) = connection.query_row(
        "SELECT COALESCE(MAX(sequence), 0) + 1,
                (SELECT digest FROM session_events
                 WHERE session_id = ?1 ORDER BY sequence DESC LIMIT 1)
         FROM session_events WHERE session_id = ?1",
        [session_id],
        |row| Ok((row.get(0)?, row.get(1)?)),
    )?;
    Ok((result.0 as u64, result.1))
}

fn sync_directory(path: &Path) -> Result<(), StoreError> {
    File::open(path)?.sync_all()?;
    Ok(())
}

fn wall_time_milliseconds() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or(Duration::ZERO)
        .as_millis()
        .min(i64::MAX as u128) as i64
}

fn digest_json(value: &impl Serialize) -> Result<String, StoreError> {
    let encoded = serde_json::to_vec(value)?;
    Ok(format!("{:x}", Sha256::digest(encoded)))
}

fn event_digest(
    session_id: &str,
    sequence: u64,
    event_kind: &str,
    payload: &Value,
    prior_digest: Option<&str>,
) -> Result<String, StoreError> {
    digest_json(&json!({
        "session_id": session_id,
        "sequence": sequence,
        "event_kind": event_kind,
        "payload": payload,
        "prior_digest": prior_digest,
    }))
}

fn interrupt_if(selected: Option<FailurePoint>, current: FailurePoint) -> Result<(), StoreError> {
    if selected == Some(current) {
        Err(StoreError::InjectedInterruption)
    } else {
        Ok(())
    }
}

fn interrupt_media_if(
    selected: Option<MediaFailurePoint>,
    current: MediaFailurePoint,
) -> Result<(), StoreError> {
    if selected == Some(current) {
        Err(StoreError::InjectedInterruption)
    } else {
        Ok(())
    }
}

fn classify_media_path(path: &Path) -> RecoveryDisposition {
    match fs::symlink_metadata(path) {
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
            RecoveryDisposition::MissingMediaFile
        }
        _ => RecoveryDisposition::InvalidMediaFile,
    }
}

fn finding(session_id: &str, disposition: RecoveryDisposition) -> RecoveryFinding {
    RecoveryFinding {
        session_id: SessionId(session_id.to_owned()),
        disposition,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::os::unix::fs::symlink;
    use tempfile::TempDir;

    fn request() -> PrepareSessionRequest {
        PrepareSessionRequest {
            title: "Design review".to_owned(),
            origin: SessionOrigin::Capture,
        }
    }

    fn open_store(temp: &TempDir) -> SessionStore {
        SessionStore::open(temp.path().join("Open Scribe")).unwrap()
    }

    fn database_value(store: &SessionStore, query: &str) -> i64 {
        store
            .connection
            .query_row(query, [], |row| row.get(0))
            .unwrap()
    }

    #[test]
    fn schema_v2_applies_required_durability_settings_tables_and_media_columns() {
        let temp = TempDir::new().unwrap();
        let store = open_store(&temp);

        let journal_mode: String = store
            .connection
            .query_row("PRAGMA journal_mode", [], |row| row.get(0))
            .unwrap();
        assert_eq!(journal_mode, "wal");
        assert_eq!(database_value(&store, "PRAGMA synchronous"), 2);
        assert_eq!(database_value(&store, "PRAGMA foreign_keys"), 1);

        let names: BTreeSet<String> = store
            .connection
            .prepare("SELECT name FROM sqlite_schema WHERE type = 'table'")
            .unwrap()
            .query_map([], |row| row.get(0))
            .unwrap()
            .map(Result::unwrap)
            .collect();
        for required in [
            "schema_migrations",
            "sessions",
            "sources",
            "tracks",
            "segments",
            "session_events",
            "markers",
            "imports",
            "deletion_receipts",
            "recovery_runs",
        ] {
            assert!(names.contains(required), "missing table {required}");
        }
        assert_eq!(
            database_value(&store, "SELECT MAX(version) FROM schema_migrations"),
            2
        );
        let segment_columns: BTreeSet<String> = store
            .connection
            .prepare("PRAGMA table_info(segments)")
            .unwrap()
            .query_map([], |row| row.get(1))
            .unwrap()
            .map(Result::unwrap)
            .collect();
        for required in [
            "open_token",
            "writer_generation",
            "file_device",
            "file_inode",
        ] {
            assert!(
                segment_columns.contains(required),
                "missing segment column {required}"
            );
        }
    }

    #[test]
    fn preparation_is_durable_but_never_permits_recording() {
        let temp = TempDir::new().unwrap();
        let mut store = open_store(&temp);
        let receipt = store.prepare_session(request()).unwrap();

        assert!(Uuid::parse_str(&receipt.session_id.0).is_ok());
        assert_eq!(receipt.schema_version, 2);
        assert_eq!(receipt.journal_version, 1);
        assert!(receipt.journal_durable);
        assert!(receipt.database_projected);
        assert!(!receipt.media_files_open);
        assert!(!receipt.permits_recording());

        let session_directory = store.sessions_root.join(&receipt.session_id.0);
        assert!(session_directory.join(JOURNAL_NAME).is_file());
        for child in SESSION_SUBDIRECTORIES {
            assert!(session_directory.join(child).is_dir());
        }
        let findings = store.recover_preparations().unwrap();
        assert_eq!(
            findings,
            vec![RecoveryFinding {
                session_id: receipt.session_id,
                disposition: RecoveryDisposition::Prepared,
            }]
        );
    }

    #[test]
    fn every_interruption_phase_has_deterministic_restart_classification() {
        let phases = [
            (
                FailurePoint::DatabaseIntent,
                RecoveryDisposition::MissingDirectory,
            ),
            (
                FailurePoint::SessionDirectory,
                RecoveryDisposition::MissingJournal,
            ),
            (
                FailurePoint::JournalSync,
                RecoveryDisposition::ProjectionRepaired,
            ),
            (
                FailurePoint::DatabaseProjection,
                RecoveryDisposition::Prepared,
            ),
        ];

        for (phase, expected) in phases {
            let temp = TempDir::new().unwrap();
            let root = temp.path().join("Open Scribe");
            {
                let mut store = SessionStore::open(&root).unwrap();
                let error = store
                    .prepare_session_inner(request(), Some(phase))
                    .unwrap_err();
                assert!(matches!(error, StoreError::InjectedInterruption));
            }

            let mut reopened = SessionStore::open(&root).unwrap();
            let first = reopened.recover_preparations().unwrap();
            assert_eq!(first.len(), 1, "phase {phase:?}");
            assert_eq!(first[0].disposition, expected, "phase {phase:?}");

            let second = reopened.recover_preparations().unwrap();
            let converged = if phase == FailurePoint::JournalSync {
                RecoveryDisposition::Prepared
            } else {
                expected
            };
            assert_eq!(second[0].disposition, converged, "phase {phase:?}");
        }
    }

    #[test]
    fn truncated_and_tampered_journals_are_never_repaired() {
        for disposition in [
            RecoveryDisposition::TruncatedJournal,
            RecoveryDisposition::IntegrityMismatch,
        ] {
            let temp = TempDir::new().unwrap();
            let mut store = open_store(&temp);
            let receipt = store.prepare_session(request()).unwrap();
            let journal_path = store
                .sessions_root
                .join(&receipt.session_id.0)
                .join(JOURNAL_NAME);
            let mut bytes = fs::read(&journal_path).unwrap();
            match disposition {
                RecoveryDisposition::TruncatedJournal => {
                    bytes.pop();
                }
                RecoveryDisposition::IntegrityMismatch => {
                    let needle = b"session_directory_ready";
                    let index = bytes
                        .windows(needle.len())
                        .position(|window| window == needle)
                        .unwrap();
                    bytes[index] = b'X';
                }
                _ => unreachable!(),
            }
            fs::write(&journal_path, bytes).unwrap();

            let findings = store.recover_preparations().unwrap();
            assert_eq!(findings[0].disposition, disposition);
            assert_eq!(
                database_value(
                    &store,
                    "SELECT COUNT(*) FROM recovery_runs WHERE disposition = 'projection_repaired'",
                ),
                0
            );
        }
    }

    #[test]
    fn symlinked_managed_roots_and_journals_are_rejected() {
        let temp = TempDir::new().unwrap();
        let real_root = temp.path().join("real");
        fs::create_dir(&real_root).unwrap();
        let linked_root = temp.path().join("linked");
        symlink(&real_root, &linked_root).unwrap();
        assert!(matches!(
            SessionStore::open(&linked_root),
            Err(StoreError::InvalidManagedRoot(_))
        ));

        let mut store = open_store(&temp);
        let receipt = store.prepare_session(request()).unwrap();
        let session_directory = store.sessions_root.join(&receipt.session_id.0);
        let journal_path = session_directory.join(JOURNAL_NAME);
        fs::remove_file(&journal_path).unwrap();
        symlink(temp.path().join("outside"), &journal_path).unwrap();
        let findings = store.recover_preparations().unwrap();
        assert_eq!(
            findings[0].disposition,
            RecoveryDisposition::IntegrityMismatch
        );
    }

    #[test]
    fn replaced_session_directory_is_an_integrity_failure() {
        let temp = TempDir::new().unwrap();
        let mut store = open_store(&temp);
        let receipt = store.prepare_session(request()).unwrap();
        let session_directory = store.sessions_root.join(&receipt.session_id.0);
        fs::remove_dir_all(&session_directory).unwrap();
        let outside = temp.path().join("outside-session");
        fs::create_dir(&outside).unwrap();
        symlink(&outside, &session_directory).unwrap();

        let findings = store.recover_preparations().unwrap();
        assert_eq!(
            findings[0].disposition,
            RecoveryDisposition::IntegrityMismatch
        );
    }

    #[test]
    fn request_bounds_fail_before_creating_session_state() {
        let temp = TempDir::new().unwrap();
        let mut store = open_store(&temp);

        for title in [String::new(), "x".repeat(MAX_TITLE_BYTES + 1)] {
            let error = store
                .prepare_session(PrepareSessionRequest {
                    title,
                    origin: SessionOrigin::Capture,
                })
                .unwrap_err();
            assert!(matches!(error, StoreError::InvalidRequest(_)));
        }
        assert_eq!(database_value(&store, "SELECT COUNT(*) FROM sessions"), 0);
        assert_eq!(fs::read_dir(&store.sessions_root).unwrap().count(), 0);
    }

    fn media_request(session_id: SessionId) -> AuthorizeMediaOpenRequest {
        AuthorizeMediaOpenRequest {
            session_id,
            source_kind: MediaSourceKind::Microphone,
            source_display_name: "Synthetic microphone".to_owned(),
        }
    }

    fn write_test_caf(authorization: &MediaOpenAuthorization) -> u64 {
        let mut file = OpenOptions::new()
            .create_new(true)
            .write(true)
            .open(&authorization.absolute_path)
            .unwrap();
        file.write_all(b"caff\0\x01\0\0deterministic-test-media")
            .unwrap();
        file.sync_all().unwrap();
        file.metadata().unwrap().len()
    }

    fn media_receipt(
        authorization: &MediaOpenAuthorization,
        initial_byte_length: u64,
    ) -> MediaOpenReceipt {
        MediaOpenReceipt {
            session_id: authorization.session_id.clone(),
            track_id: authorization.track_id.clone(),
            segment_id: authorization.segment_id.clone(),
            open_token: authorization.open_token.clone(),
            writer_generation: authorization.writer_generation,
            relative_path: authorization.relative_path.clone(),
            media_format: authorization.media_format.clone(),
            sample_rate_hz: authorization.sample_rate_hz,
            channels: authorization.channels,
            initial_byte_length,
        }
    }

    fn append_first_sample(authorization: &MediaOpenAuthorization) -> u64 {
        let mut writer = OpenOptions::new()
            .append(true)
            .open(&authorization.absolute_path)
            .unwrap();
        writer.write_all(b"first-captured-sample").unwrap();
        writer.sync_all().unwrap();
        writer.metadata().unwrap().len()
    }

    fn first_sample_receipt(
        authorization: &MediaOpenAuthorization,
        observed_byte_length: u64,
    ) -> FirstSampleReceipt {
        FirstSampleReceipt {
            session_id: authorization.session_id.clone(),
            track_id: authorization.track_id.clone(),
            segment_id: authorization.segment_id.clone(),
            open_token: authorization.open_token.clone(),
            writer_generation: authorization.writer_generation,
            relative_path: authorization.relative_path.clone(),
            first_sample_host_time: 42_000,
            first_sample_frame_count: 480,
            observed_byte_length,
        }
    }

    #[test]
    fn first_sample_is_durable_evidence_but_never_starts_recording() {
        let temp = TempDir::new().unwrap();
        let mut store = open_store(&temp);
        let prepared = store.prepare_session(request()).unwrap();
        let authorization = store
            .authorize_media_open(media_request(prepared.session_id.clone()))
            .unwrap();
        let initial_byte_length = write_test_caf(&authorization);
        store
            .accept_media_open(media_receipt(&authorization, initial_byte_length))
            .unwrap();

        let observed_byte_length = append_first_sample(&authorization);

        let evidence = store
            .accept_first_sample(first_sample_receipt(&authorization, observed_byte_length))
            .unwrap();

        assert!(evidence.journal_durable);
        assert!(evidence.media_files_open);
        assert!(evidence.first_sample_durable);
        assert!(!evidence.recording_started);
        assert_eq!(evidence.first_sample_session_nanoseconds, 0);
        assert_eq!(evidence.last_journal_sequence, 4);
        assert_eq!(
            store
                .connection
                .query_row(
                    "SELECT sample_count FROM segments WHERE id = ?1",
                    [&authorization.segment_id],
                    |row| row.get::<_, Option<i64>>(0),
                )
                .unwrap(),
            None
        );
        assert_eq!(
            store
                .connection
                .query_row(
                    "SELECT lifecycle FROM sessions WHERE id = ?1",
                    [&prepared.session_id.0],
                    |row| row.get::<_, String>(0),
                )
                .unwrap(),
            "preparing"
        );
    }

    #[test]
    fn first_sample_requires_open_media_and_rejects_changed_replay() {
        let temp = TempDir::new().unwrap();
        let mut store = open_store(&temp);
        let prepared = store.prepare_session(request()).unwrap();
        let authorization = store
            .authorize_media_open(media_request(prepared.session_id))
            .unwrap();
        let initial_byte_length = write_test_caf(&authorization);
        let premature = first_sample_receipt(&authorization, initial_byte_length + 1);

        assert!(matches!(
            store.accept_first_sample(premature),
            Err(StoreError::InvalidState("media-open evidence is missing"))
        ));
        store
            .accept_media_open(media_receipt(&authorization, initial_byte_length))
            .unwrap();
        let observed_byte_length = append_first_sample(&authorization);
        let receipt = first_sample_receipt(&authorization, observed_byte_length);
        let accepted = store.accept_first_sample(receipt.clone()).unwrap();
        let repeated = store.accept_first_sample(receipt.clone()).unwrap();
        assert_eq!(accepted, repeated);

        let mut changed = receipt;
        changed.first_sample_frame_count += 1;
        assert!(matches!(
            store.accept_first_sample(changed),
            Err(StoreError::IntegrityMismatch(
                "repeated first-sample receipt changed accepted evidence"
            ))
        ));
    }

    #[test]
    fn first_sample_interruption_recovery_converges_without_recording() {
        for (phase, expected_first) in [
            (
                MediaFailurePoint::FirstSampleJournalSync,
                RecoveryDisposition::FirstSampleProjectionRepaired,
            ),
            (
                MediaFailurePoint::FirstSampleDatabaseProjection,
                RecoveryDisposition::FirstSamplePrepared,
            ),
        ] {
            let temp = TempDir::new().unwrap();
            let root = temp.path().join("Open Scribe");
            {
                let mut store = SessionStore::open(&root).unwrap();
                let prepared = store.prepare_session(request()).unwrap();
                let authorization = store
                    .authorize_media_open(media_request(prepared.session_id))
                    .unwrap();
                let initial_byte_length = write_test_caf(&authorization);
                store
                    .accept_media_open(media_receipt(&authorization, initial_byte_length))
                    .unwrap();
                let observed_byte_length = append_first_sample(&authorization);
                let error = store
                    .accept_first_sample_inner(
                        first_sample_receipt(&authorization, observed_byte_length),
                        Some(phase),
                    )
                    .unwrap_err();
                assert!(matches!(error, StoreError::InjectedInterruption));
            }

            let mut reopened = SessionStore::open(&root).unwrap();
            let first = reopened.recover_preparations().unwrap().remove(0);
            assert_eq!(first.disposition, expected_first);
            let second = reopened.recover_preparations().unwrap().remove(0);
            assert_eq!(second.disposition, RecoveryDisposition::FirstSamplePrepared);
            assert_eq!(
                reopened
                    .connection
                    .query_row("SELECT lifecycle FROM sessions", [], |row| row
                        .get::<_, String>(0))
                    .unwrap(),
                "preparing"
            );
        }
    }

    #[test]
    fn media_open_requires_rust_authority_and_never_starts_recording() {
        let temp = TempDir::new().unwrap();
        let mut store = open_store(&temp);
        let prepared = store.prepare_session(request()).unwrap();
        let authorization = store
            .authorize_media_open(media_request(prepared.session_id.clone()))
            .unwrap();

        assert!(!authorization.absolute_path.exists());
        assert!(authorization.relative_path.starts_with("audio/"));
        assert_eq!(authorization.media_format, MEDIA_FORMAT_CAF_PCM_S16LE);
        assert_eq!(authorization.sample_rate_hz, MEDIA_SAMPLE_RATE_HZ);
        let byte_length = write_test_caf(&authorization);
        let evidence = store
            .accept_media_open(media_receipt(&authorization, byte_length))
            .unwrap();

        assert!(evidence.journal_durable);
        assert!(evidence.media_files_open);
        assert!(!evidence.recording_started);
        assert_eq!(evidence.last_journal_sequence, 3);
        let lifecycle: String = store
            .connection
            .query_row(
                "SELECT lifecycle FROM sessions WHERE id = ?1",
                [&prepared.session_id.0],
                |row| row.get(0),
            )
            .unwrap();
        assert_eq!(lifecycle, "preparing");

        let repeated = store
            .accept_media_open(media_receipt(&authorization, byte_length))
            .unwrap();
        assert_eq!(repeated.last_journal_sequence, 3);
    }

    #[test]
    fn idempotent_media_receipt_revalidates_the_accepted_file() {
        let temp = TempDir::new().unwrap();
        let mut store = open_store(&temp);
        let prepared = store.prepare_session(request()).unwrap();
        let authorization = store
            .authorize_media_open(media_request(prepared.session_id))
            .unwrap();
        let byte_length = write_test_caf(&authorization);
        let receipt = media_receipt(&authorization, byte_length);
        store.accept_media_open(receipt.clone()).unwrap();

        let mut retained_writer = OpenOptions::new()
            .append(true)
            .open(&authorization.absolute_path)
            .unwrap();
        retained_writer.write_all(b"more-media").unwrap();
        retained_writer.sync_all().unwrap();
        let grown = store.accept_media_open(receipt.clone()).unwrap();
        assert!(grown.media_files_open);
        assert_eq!(grown.last_journal_sequence, 3);

        let replacement_path = authorization.absolute_path.with_extension("replacement");
        let mut replacement = OpenOptions::new()
            .create_new(true)
            .write(true)
            .open(&replacement_path)
            .unwrap();
        replacement
            .write_all(b"caff\0\x01\0\0deterministic-test-media")
            .unwrap();
        replacement.sync_all().unwrap();

        fs::remove_file(&authorization.absolute_path).unwrap();
        assert!(matches!(
            store.accept_media_open(receipt.clone()),
            Err(StoreError::IntegrityMismatch(
                "accepted media file is missing"
            ))
        ));

        fs::rename(&replacement_path, &authorization.absolute_path).unwrap();
        assert!(matches!(
            store.accept_media_open(receipt),
            Err(StoreError::IntegrityMismatch(
                "accepted media file identity changed"
            ))
        ));
    }

    #[test]
    fn stale_foreign_and_symlinked_media_receipts_are_rejected() {
        let temp = TempDir::new().unwrap();
        let mut store = open_store(&temp);
        let prepared = store.prepare_session(request()).unwrap();
        let authorization = store
            .authorize_media_open(media_request(prepared.session_id))
            .unwrap();
        let byte_length = write_test_caf(&authorization);

        let mut stale = media_receipt(&authorization, byte_length);
        stale.open_token = Uuid::now_v7().to_string();
        assert!(matches!(
            store.accept_media_open(stale),
            Err(StoreError::IntegrityMismatch(_))
        ));

        fs::remove_file(&authorization.absolute_path).unwrap();
        let outside = temp.path().join("outside.caf");
        fs::write(&outside, b"caff-outside").unwrap();
        symlink(&outside, &authorization.absolute_path).unwrap();
        assert!(matches!(
            store.accept_media_open(media_receipt(
                &authorization,
                fs::metadata(&outside).unwrap().len(),
            )),
            Err(StoreError::IntegrityMismatch(_))
        ));

        let mut traversal = media_receipt(&authorization, byte_length);
        traversal.relative_path = "audio/../outside.caf".to_owned();
        assert!(matches!(
            store.accept_media_open(traversal),
            Err(StoreError::InvalidRequest(_))
        ));
    }

    fn assert_intermediate_media_symlink_is_rejected(replace_audio_directory: bool) {
        let temp = TempDir::new().unwrap();
        let mut store = open_store(&temp);
        let prepared = store.prepare_session(request()).unwrap();
        let authorization = store
            .authorize_media_open(media_request(prepared.session_id))
            .unwrap();
        let track_directory = authorization.absolute_path.parent().unwrap().to_path_buf();
        let audio_directory = track_directory.parent().unwrap().to_path_buf();
        let session_directory = audio_directory.parent().unwrap().to_path_buf();
        let original = if replace_audio_directory {
            audio_directory
        } else {
            track_directory
        };
        let escaped = temp.path().join(if replace_audio_directory {
            "escaped-audio"
        } else {
            "escaped-track"
        });
        fs::rename(&original, &escaped).unwrap();
        symlink(&escaped, &original).unwrap();

        let byte_length = write_test_caf(&authorization);
        let resolved_media = fs::canonicalize(&authorization.absolute_path).unwrap();
        assert!(!resolved_media.starts_with(&session_directory));
        assert!(matches!(
            store.accept_media_open(media_receipt(&authorization, byte_length)),
            Err(StoreError::IntegrityMismatch(_))
        ));
        assert_eq!(
            database_value(&store, "SELECT media_files_open FROM sessions"),
            0
        );
    }

    #[test]
    fn intermediate_audio_symlink_cannot_escape_the_session() {
        assert_intermediate_media_symlink_is_rejected(true);
    }

    #[test]
    fn intermediate_track_symlink_cannot_escape_the_session() {
        assert_intermediate_media_symlink_is_rejected(false);
    }

    #[test]
    fn media_interruption_phases_recover_without_recording_claims() {
        for phase in [
            MediaFailurePoint::AuthorizationJournalSync,
            MediaFailurePoint::AuthorizationDatabaseProjection,
        ] {
            let temp = TempDir::new().unwrap();
            let root = temp.path().join("Open Scribe");
            {
                let mut store = SessionStore::open(&root).unwrap();
                let prepared = store.prepare_session(request()).unwrap();
                let error = store
                    .authorize_media_open_inner(media_request(prepared.session_id), Some(phase))
                    .unwrap_err();
                assert!(matches!(error, StoreError::InjectedInterruption));
            }
            let mut reopened = SessionStore::open(&root).unwrap();
            let finding = reopened.recover_preparations().unwrap().remove(0);
            assert_eq!(finding.disposition, RecoveryDisposition::MissingMediaFile);
            assert_eq!(
                database_value(&reopened, "SELECT media_files_open FROM sessions"),
                0
            );
            assert_eq!(
                reopened
                    .connection
                    .query_row("SELECT lifecycle FROM sessions", [], |row| row
                        .get::<_, String>(0))
                    .unwrap(),
                "preparing"
            );
        }

        for (phase, expected_first) in [
            (
                MediaFailurePoint::ReceiptJournalSync,
                RecoveryDisposition::MediaOpenProjectionRepaired,
            ),
            (
                MediaFailurePoint::ReceiptDatabaseProjection,
                RecoveryDisposition::MediaOpenPrepared,
            ),
        ] {
            let temp = TempDir::new().unwrap();
            let root = temp.path().join("Open Scribe");
            {
                let mut store = SessionStore::open(&root).unwrap();
                let prepared = store.prepare_session(request()).unwrap();
                let authorization = store
                    .authorize_media_open(media_request(prepared.session_id))
                    .unwrap();
                let byte_length = write_test_caf(&authorization);
                let error = store
                    .accept_media_open_inner(
                        media_receipt(&authorization, byte_length),
                        Some(phase),
                    )
                    .unwrap_err();
                assert!(matches!(error, StoreError::InjectedInterruption));
            }
            let mut reopened = SessionStore::open(&root).unwrap();
            let first = reopened.recover_preparations().unwrap().remove(0);
            assert_eq!(first.disposition, expected_first);
            let second = reopened.recover_preparations().unwrap().remove(0);
            assert_eq!(second.disposition, RecoveryDisposition::MediaOpenPrepared);
            assert_eq!(
                database_value(&reopened, "SELECT media_files_open FROM sessions"),
                1
            );
            assert_eq!(
                reopened
                    .connection
                    .query_row("SELECT lifecycle FROM sessions", [], |row| row
                        .get::<_, String>(0))
                    .unwrap(),
                "preparing"
            );
        }
    }

    #[test]
    fn valid_unaccepted_media_remains_awaiting_receipt() {
        let temp = TempDir::new().unwrap();
        let mut store = open_store(&temp);
        let prepared = store.prepare_session(request()).unwrap();
        let authorization = store
            .authorize_media_open(media_request(prepared.session_id))
            .unwrap();
        write_test_caf(&authorization);

        let finding = store.recover_preparations().unwrap().remove(0);
        assert_eq!(
            finding.disposition,
            RecoveryDisposition::MediaOpenAwaitingReceipt
        );
        assert_eq!(
            database_value(&store, "SELECT media_files_open FROM sessions"),
            0
        );
    }

    #[test]
    fn recovery_rejects_replaced_media_after_journal_acceptance() {
        let temp = TempDir::new().unwrap();
        let root = temp.path().join("Open Scribe");
        let authorization;
        {
            let mut store = SessionStore::open(&root).unwrap();
            let prepared = store.prepare_session(request()).unwrap();
            authorization = store
                .authorize_media_open(media_request(prepared.session_id))
                .unwrap();
            let byte_length = write_test_caf(&authorization);
            let error = store
                .accept_media_open_inner(
                    media_receipt(&authorization, byte_length),
                    Some(MediaFailurePoint::ReceiptJournalSync),
                )
                .unwrap_err();
            assert!(matches!(error, StoreError::InjectedInterruption));
        }

        fs::remove_file(&authorization.absolute_path).unwrap();
        write_test_caf(&authorization);
        let mut reopened = SessionStore::open(&root).unwrap();
        let finding = reopened.recover_preparations().unwrap().remove(0);
        assert_eq!(finding.disposition, RecoveryDisposition::InvalidMediaFile);
        assert_eq!(
            database_value(&reopened, "SELECT media_files_open FROM sessions"),
            0
        );
    }

    #[test]
    fn recovery_accepts_growth_of_the_same_media_identity() {
        let temp = TempDir::new().unwrap();
        let root = temp.path().join("Open Scribe");
        {
            let mut store = SessionStore::open(&root).unwrap();
            let prepared = store.prepare_session(request()).unwrap();
            let authorization = store
                .authorize_media_open(media_request(prepared.session_id))
                .unwrap();
            let byte_length = write_test_caf(&authorization);
            store
                .accept_media_open(media_receipt(&authorization, byte_length))
                .unwrap();
            let mut retained_writer = OpenOptions::new()
                .append(true)
                .open(&authorization.absolute_path)
                .unwrap();
            retained_writer.write_all(b"more-media").unwrap();
            retained_writer.sync_all().unwrap();
        }

        let mut reopened = SessionStore::open(&root).unwrap();
        let finding = reopened.recover_preparations().unwrap().remove(0);
        assert_eq!(finding.disposition, RecoveryDisposition::MediaOpenPrepared);
        assert_eq!(
            database_value(&reopened, "SELECT media_files_open FROM sessions"),
            1
        );
    }
}
