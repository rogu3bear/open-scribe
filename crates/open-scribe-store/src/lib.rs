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
use std::io::{BufRead, BufReader, Read, Seek, Write};
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

mod runtime_snapshot;

pub use runtime_snapshot::{RuntimeLibrarySnapshot, RuntimeSessionSnapshot, RuntimeSourceSnapshot};

const SCHEMA_VERSION: i64 = 3;
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

    fn from_str(value: &str) -> Result<Self, StoreError> {
        match value {
            "microphone" => Ok(Self::Microphone),
            "application_audio" => Ok(Self::ApplicationAudio),
            "system_audio" => Ok(Self::SystemAudio),
            _ => Err(StoreError::IntegrityMismatch(
                "required media source kind is unsupported",
            )),
        }
    }
}

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

/// Bounded, content-free reason for preserving a partial capture as interrupted.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum SessionInterruptionReason {
    CaptureStartFailed,
    CaptureFailed,
    FirstSampleRejected,
    StopWithoutDurableSample,
    SegmentSealFailed,
}

impl SessionInterruptionReason {
    const fn as_str(self) -> &'static str {
        match self {
            Self::CaptureStartFailed => "capture_start_failed",
            Self::CaptureFailed => "capture_failed",
            Self::FirstSampleRejected => "first_sample_rejected",
            Self::StopWithoutDurableSample => "stop_without_durable_sample",
            Self::SegmentSealFailed => "segment_seal_failed",
        }
    }

    fn from_str(value: &str) -> Result<Self, StoreError> {
        match value {
            "capture_start_failed" => Ok(Self::CaptureStartFailed),
            "capture_failed" => Ok(Self::CaptureFailed),
            "first_sample_rejected" => Ok(Self::FirstSampleRejected),
            "stop_without_durable_sample" => Ok(Self::StopWithoutDurableSample),
            "segment_seal_failed" => Ok(Self::SegmentSealFailed),
            _ => Err(StoreError::IntegrityMismatch(
                "session interruption reason is unsupported",
            )),
        }
    }
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

/// Coarse, content-free result for one source segment made playable after restart.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct RecoveredPlayableSession {
    pub session_id: SessionId,
    pub segment_id: String,
    pub relative_path: String,
    pub absolute_path: PathBuf,
    pub sample_count: u64,
    pub duration_nanoseconds: u64,
    pub byte_length: u64,
    pub digest_sha256: String,
    pub media_preserved: bool,
    pub ready_for_review: bool,
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
    SegmentSealedPrepared,
    SegmentSealProjectionRepaired,
    InterruptedPrepared,
    InterruptedMediaOpen,
    InterruptedFirstSample,
    InterruptedSegmentSealed,
    InterruptionProjectionRepaired,
    PlayableMediaRecovered,
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
    SegmentSealJournalSync,
    SegmentSealDatabaseProjection,
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
    source_id: String,
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

struct PlayableRecoveryCandidate {
    session_id: String,
    source_id: String,
    track_id: String,
    segment_id: String,
    relative_path: String,
    file_device: u64,
    file_inode: u64,
}

struct PlayableRecoveryProjection {
    payload: Value,
    journal_record: JournalRecord,
}

struct ValidatedMediaFile {
    byte_length: u64,
    device: u64,
    inode: u64,
    digest_sha256: Option<String>,
    recoverable_sample_count: Option<u64>,
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
        self.prepare_session_with_required_sources(request, vec![MediaSourceKind::Microphone])
    }

    pub fn prepare_session_with_required_sources(
        &mut self,
        request: PrepareSessionRequest,
        required_sources: Vec<MediaSourceKind>,
    ) -> Result<PreparedSessionReceipt, StoreError> {
        let required_sources = normalized_source_kinds(required_sources)?;
        let mut receipt = self.prepare_session_inner(request, None)?;
        let planned = self.plan_required_sources(receipt.session_id.clone(), required_sources)?;
        receipt.last_journal_sequence = planned.last_journal_sequence;
        Ok(receipt)
    }

    /// Persists the complete required-source contract before any media is authorized.
    pub fn plan_required_sources(
        &mut self,
        session_id: SessionId,
        required_sources: Vec<MediaSourceKind>,
    ) -> Result<RequiredSourcePlanEvidence, StoreError> {
        if Uuid::parse_str(&session_id.0).is_err() {
            return Err(StoreError::InvalidRequest("session ID is not a UUID"));
        }
        let required_sources = normalized_source_kinds(required_sources)?;
        let (lifecycle, journal_durable): (String, bool) = self
            .connection
            .query_row(
                "SELECT lifecycle, journal_durable FROM sessions WHERE id = ?1",
                [&session_id.0],
                |row| Ok((row.get(0)?, row.get(1)?)),
            )
            .map_err(|error| match error {
                rusqlite::Error::QueryReturnedNoRows => {
                    StoreError::InvalidState("session does not exist")
                }
                other => StoreError::Sqlite(other),
            })?;
        if lifecycle != "preparing" || !journal_durable {
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
        let (sequence, prior_digest) = next_database_event(&self.connection, &session_id.0)?;
        let digest = event_digest(
            &session_id.0,
            sequence,
            "required_sources_planned",
            &payload,
            prior_digest.as_deref(),
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
        insert_event_with_id(
            &transaction,
            &journal_record.body.event_id,
            &session_id.0,
            sequence,
            "required_sources_planned",
            journal_record.body.wall_time_milliseconds,
            &payload,
            prior_digest.as_deref(),
            &digest,
        )?;
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
        let (lifecycle, journal_durable, media_files_open): (String, bool, bool) =
            self.connection.query_row(
                "SELECT lifecycle, journal_durable, media_files_open FROM sessions WHERE id = ?1",
                [&session_id.0],
                |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?)),
            )?;
        if lifecycle == "recording" {
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
        if lifecycle != "preparing" || !journal_durable || !media_files_open {
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
        let (sequence, prior_digest) = next_database_event(&self.connection, &session_id.0)?;
        let digest = event_digest(
            &session_id.0,
            sequence,
            "recording_started",
            &payload,
            prior_digest.as_deref(),
        )?;
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
        insert_event_with_id(
            &transaction,
            &journal_record.body.event_id,
            &session_id.0,
            sequence,
            "recording_started",
            journal_record.body.wall_time_milliseconds,
            &payload,
            prior_digest.as_deref(),
            &digest,
        )?;
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

    /// Accepts a closed, synchronized segment, independently digests the file,
    /// and binds the writer-reported final counters to that immutable evidence.
    pub fn seal_segment(
        &mut self,
        receipt: SealSegmentReceipt,
    ) -> Result<SealedSegmentEvidence, StoreError> {
        self.seal_segment_inner(receipt, None)
    }

    /// Durably marks a partial capture as interrupted without altering media.
    pub fn interrupt_session(
        &mut self,
        request: InterruptSessionRequest,
    ) -> Result<SessionInterruptionEvidence, StoreError> {
        if Uuid::parse_str(&request.session_id.0).is_err() {
            return Err(StoreError::InvalidRequest("session ID is not a UUID"));
        }
        let lifecycle: String = self
            .connection
            .query_row(
                "SELECT lifecycle FROM sessions WHERE id = ?1",
                [&request.session_id.0],
                |row| row.get(0),
            )
            .map_err(|error| match error {
                rusqlite::Error::QueryReturnedNoRows => {
                    StoreError::InvalidState("session does not exist")
                }
                other => StoreError::Sqlite(other),
            })?;
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
            if SessionInterruptionReason::from_str(payload_string(&last.body.payload, "reason")?)?
                != request.reason
            {
                return Err(StoreError::IntegrityMismatch(
                    "repeated interruption changed accepted evidence",
                ));
            }
            if matches!(lifecycle.as_str(), "preparing" | "recording") {
                self.project_session_interruption(&request.session_id.0, &last.body.payload, last)?;
            } else if lifecycle != "interrupted" {
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
        if lifecycle == "interrupted" {
            return Err(StoreError::IntegrityMismatch(
                "session projection has no interruption evidence",
            ));
        }
        if !matches!(lifecycle.as_str(), "preparing" | "recording") {
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
        self.project_session_interruption(&request.session_id.0, &payload, &journal_record)?;

        Ok(SessionInterruptionEvidence {
            session_id: request.session_id,
            reason: request.reason,
            journal_durable: true,
            session_interrupted: true,
            recording_started: false,
            last_journal_sequence: journal_record.body.sequence,
        })
    }

    /// Plans every candidate before mutating one, then durably promotes only
    /// independently valid, closed-by-process-exit CAF media to reviewable playback.
    pub fn recover_playable_sessions(
        &mut self,
    ) -> Result<Vec<RecoveredPlayableSession>, StoreError> {
        let candidates = {
            let mut statement = self.connection.prepare(
                "SELECT sessions.id, sources.id, tracks.id, segments.id,
                        segments.relative_path, segments.file_device, segments.file_inode
                 FROM sessions
                 JOIN sources ON sources.session_id = sessions.id
                 JOIN tracks ON tracks.session_id = sessions.id AND tracks.source_id = sources.id
                 JOIN segments ON segments.session_id = sessions.id
                              AND segments.track_id = tracks.id
                 WHERE sessions.lifecycle IN (
                           'preparing', 'recording', 'interrupted', 'ready_for_review'
                       )
                   AND segments.lifecycle = 'capturing'
                 ORDER BY sessions.id, segments.sequence",
            )?;
            let rows = statement.query_map([], |row| {
                Ok(PlayableRecoveryCandidate {
                    session_id: row.get(0)?,
                    source_id: row.get(1)?,
                    track_id: row.get(2)?,
                    segment_id: row.get(3)?,
                    relative_path: row.get(4)?,
                    file_device: row.get::<_, i64>(5)? as u64,
                    file_inode: row.get::<_, i64>(6)? as u64,
                })
            })?;
            rows.collect::<Result<Vec<_>, _>>()?
        };

        let mut candidates_by_session = BTreeMap::<String, Vec<_>>::new();
        for candidate in candidates {
            candidates_by_session
                .entry(candidate.session_id.clone())
                .or_default()
                .push(candidate);
        }

        let mut plans_by_session = Vec::new();
        for (session_id, candidates) in candidates_by_session {
            let journal_path = self.session_directory(&session_id)?.join(JOURNAL_NAME);
            let records = match validate_journal(&journal_path, &session_id)? {
                JournalValidation::Valid(records) => records,
                _ => continue,
            };
            let mut plans = Vec::new();
            for candidate in candidates {
                let Some(first_sample) = journal_record_for_segment(
                    &records,
                    "first_sample_captured",
                    &candidate.segment_id,
                )?
                else {
                    plans.clear();
                    break;
                };
                let observed_byte_length =
                    payload_u64(&first_sample.body.payload, "observed_byte_length")?;
                let validated = match self.validate_media_file(
                    &candidate.session_id,
                    &candidate.relative_path,
                    MediaLengthRequirement::AtLeast(observed_byte_length),
                    true,
                ) {
                    Ok(validated) => validated,
                    Err(_) => {
                        plans.clear();
                        break;
                    }
                };
                if validated.device != candidate.file_device
                    || validated.inode != candidate.file_inode
                {
                    plans.clear();
                    break;
                }
                let Some(sample_count) = validated.recoverable_sample_count else {
                    plans.clear();
                    break;
                };
                let digest_sha256 = validated
                    .digest_sha256
                    .ok_or(StoreError::IntegrityMismatch("recovery digest is missing"))?;
                let payload = json!({
                    "source_id": candidate.source_id,
                    "track_id": candidate.track_id,
                    "segment_id": candidate.segment_id,
                    "relative_path": candidate.relative_path,
                    "sample_count": sample_count,
                    "final_byte_length": validated.byte_length,
                    "digest_sha256": digest_sha256,
                    "file_device": validated.device,
                    "file_inode": validated.inode,
                    "truncated_bytes": 0,
                });
                plans.push(payload);
            }
            if !plans.is_empty() {
                plans_by_session.push((session_id, plans));
            }
        }

        for (session_id, plans) in plans_by_session {
            let mut projections = Vec::new();
            for payload in plans {
                let segment_id = payload_string(&payload, "segment_id")?;
                let relative_path = payload_string(&payload, "relative_path")?;
                let journal_path = self.session_directory(&session_id)?.join(JOURNAL_NAME);
                let records = match validate_journal(&journal_path, &session_id)? {
                    JournalValidation::Valid(records) => records,
                    _ => return Err(StoreError::IntegrityMismatch("session journal changed")),
                };
                let journal_record = if let Some(existing) =
                    journal_record_for_segment(&records, "playable_media_recovered", segment_id)?
                {
                    if existing.body.payload != payload {
                        return Err(StoreError::IntegrityMismatch(
                            "recovery plan changed accepted evidence",
                        ));
                    }
                    existing.clone()
                } else {
                    self.append_session_journal(
                        &session_id,
                        "playable_media_recovered",
                        Some(relative_path),
                        payload.clone(),
                    )?
                };
                projections.push(PlayableRecoveryProjection {
                    payload,
                    journal_record,
                });
            }
            self.project_playable_recovery_session(&session_id, &projections)?;
        }
        self.recovered_playable_sessions()
    }

    fn recovered_playable_sessions(&self) -> Result<Vec<RecoveredPlayableSession>, StoreError> {
        let rows = {
            let mut statement = self.connection.prepare(
                "SELECT sessions.id, segments.id, segments.relative_path,
                        segments.sample_count, segments.byte_length, segments.digest,
                        segments.file_device, segments.file_inode,
                        MAX(session_events.sequence)
                 FROM sessions
                 JOIN segments ON segments.session_id = sessions.id
                 JOIN session_events ON session_events.session_id = sessions.id
                 WHERE sessions.lifecycle = 'ready_for_review'
                   AND segments.lifecycle = 'sealed'
                   AND EXISTS (
                       SELECT 1 FROM session_events recovery_events
                       WHERE recovery_events.session_id = sessions.id
                         AND recovery_events.event_kind = 'playable_media_recovered'
                   )
                 GROUP BY sessions.id, segments.id
                 ORDER BY sessions.updated_at_ms DESC, segments.sequence",
            )?;
            let mapped = statement.query_map([], |row| {
                Ok((
                    row.get::<_, String>(0)?,
                    row.get::<_, String>(1)?,
                    row.get::<_, String>(2)?,
                    row.get::<_, i64>(3)? as u64,
                    row.get::<_, i64>(4)? as u64,
                    row.get::<_, String>(5)?,
                    row.get::<_, i64>(6)? as u64,
                    row.get::<_, i64>(7)? as u64,
                    row.get::<_, i64>(8)? as u64,
                ))
            })?;
            mapped.collect::<Result<Vec<_>, _>>()?
        };

        rows.into_iter()
            .map(
                |(
                    session_id,
                    segment_id,
                    relative_path,
                    sample_count,
                    byte_length,
                    digest_sha256,
                    file_device,
                    file_inode,
                    last_journal_sequence,
                )| {
                    let validated = self.validate_media_file(
                        &session_id,
                        &relative_path,
                        MediaLengthRequirement::Exact(byte_length),
                        true,
                    )?;
                    if validated.device != file_device
                        || validated.inode != file_inode
                        || validated.recoverable_sample_count != Some(sample_count)
                        || validated.digest_sha256.as_deref() != Some(digest_sha256.as_str())
                    {
                        return Err(StoreError::IntegrityMismatch(
                            "recovered playable media changed after acceptance",
                        ));
                    }
                    Ok(RecoveredPlayableSession {
                        session_id: SessionId(session_id.clone()),
                        segment_id,
                        relative_path: relative_path.clone(),
                        absolute_path: self.session_directory(&session_id)?.join(relative_path),
                        sample_count,
                        duration_nanoseconds: sample_count.saturating_mul(1_000_000_000)
                            / u64::from(MEDIA_SAMPLE_RATE_HZ),
                        byte_length,
                        digest_sha256,
                        media_preserved: true,
                        ready_for_review: true,
                        recording_started: false,
                        last_journal_sequence,
                    })
                },
            )
            .collect()
    }

    fn authorize_media_open_inner(
        &mut self,
        request: AuthorizeMediaOpenRequest,
        failure: Option<MediaFailurePoint>,
    ) -> Result<MediaOpenAuthorization, StoreError> {
        validate_media_request(&request)?;
        let (lifecycle, journal_durable): (String, bool) = self
            .connection
            .query_row(
                "SELECT lifecycle, journal_durable FROM sessions WHERE id = ?1",
                [&request.session_id.0],
                |row| Ok((row.get(0)?, row.get(1)?)),
            )
            .map_err(|error| match error {
                rusqlite::Error::QueryReturnedNoRows => {
                    StoreError::InvalidState("session does not exist")
                }
                other => StoreError::Sqlite(other),
            })?;
        if lifecycle != "preparing" || !journal_durable {
            return Err(StoreError::InvalidState(
                "session is not awaiting required media files",
            ));
        }
        let required: bool = self.connection.query_row(
            "SELECT EXISTS(
                SELECT 1 FROM required_sources
                WHERE session_id = ?1 AND kind = ?2
             )",
            params![request.session_id.0, request.source_kind.as_str()],
            |row| row.get(0),
        )?;
        if !required {
            return Err(StoreError::InvalidState(
                "media source is not part of the required-source plan",
            ));
        }
        let existing_kind: bool = self.connection.query_row(
            "SELECT EXISTS(
                SELECT 1 FROM sources
                WHERE session_id = ?1 AND kind = ?2
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
                    false,
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
            media_files_open: self.session_media_files_open(&stored.session_id)?,
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
            false,
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

    fn seal_segment_inner(
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
        if validated.device != expected_device || validated.inode != expected_inode {
            return Err(StoreError::IntegrityMismatch(
                "accepted media file identity changed",
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

        let payload = json!({
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
        let journal_record = self.append_session_journal(
            &receipt.session_id.0,
            "segment_sealed",
            Some(&receipt.relative_path),
            payload.clone(),
        )?;
        interrupt_media_if(failure, MediaFailurePoint::SegmentSealJournalSync)?;
        self.project_segment_seal(&receipt.session_id.0, &payload, &journal_record)?;
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

    fn session_directory(&self, session_id: &str) -> Result<PathBuf, StoreError> {
        let directory = self.sessions_root.join(session_id);
        require_real_directory(&directory)?;
        Ok(directory)
    }

    fn required_source_kinds(&self, session_id: &str) -> Result<Vec<MediaSourceKind>, StoreError> {
        let mut statement = self.connection.prepare(
            "SELECT kind FROM required_sources
             WHERE session_id = ?1 ORDER BY kind",
        )?;
        statement
            .query_map([session_id], |row| row.get::<_, String>(0))?
            .map(|value| MediaSourceKind::from_str(&value?))
            .collect()
    }

    fn active_source_kinds(&self, session_id: &str) -> Result<Vec<MediaSourceKind>, StoreError> {
        let mut statement = self.connection.prepare(
            "SELECT DISTINCT kind FROM sources
             WHERE session_id = ?1 AND lifecycle = 'capturing'
             ORDER BY kind",
        )?;
        statement
            .query_map([session_id], |row| row.get::<_, String>(0))?
            .map(|value| MediaSourceKind::from_str(&value?))
            .collect()
    }

    fn session_media_files_open(&self, session_id: &str) -> Result<bool, StoreError> {
        self.connection
            .query_row(
                "SELECT media_files_open FROM sessions WHERE id = ?1",
                [session_id],
                |row| row.get(0),
            )
            .map_err(StoreError::Sqlite)
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
            "UPDATE required_sources SET lifecycle = 'opening'
             WHERE session_id = ?1 AND kind = ?2 AND lifecycle = 'required'",
            params![session_id, source_kind],
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
            "UPDATE required_sources SET lifecycle = 'open'
             WHERE session_id = ?1
               AND kind = (
                 SELECT sources.kind FROM sources
                 JOIN tracks ON tracks.source_id = sources.id
                 JOIN segments ON segments.track_id = tracks.id
                 WHERE segments.id = ?2
               )",
            params![session_id, segment_id],
        )?;
        let all_required_open: bool = transaction.query_row(
            "SELECT NOT EXISTS(
                SELECT 1 FROM required_sources required
                WHERE required.session_id = ?1
                  AND NOT EXISTS(
                    SELECT 1 FROM sources source
                    WHERE source.session_id = required.session_id
                      AND source.kind = required.kind
                      AND source.lifecycle IN ('open', 'capturing')
                  )
             )",
            [session_id],
            |row| row.get(0),
        )?;
        transaction.execute(
            "UPDATE sessions
             SET media_files_open = ?2, updated_at_ms = ?3
             WHERE id = ?1 AND lifecycle = 'preparing' AND journal_durable = 1",
            params![session_id, all_required_open, now],
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
             WHERE id = (
               SELECT tracks.source_id FROM tracks
               JOIN segments ON segments.track_id = tracks.id
               WHERE segments.id = ?2
             ) AND session_id = ?1 AND lifecycle = 'open'",
            params![session_id, segment_id],
        )?;
        transaction.execute(
            "UPDATE tracks SET lifecycle = 'capturing'
             WHERE id = (SELECT track_id FROM segments WHERE id = ?2)
               AND session_id = ?1 AND lifecycle = 'open'",
            params![session_id, segment_id],
        )?;
        transaction.execute(
            "UPDATE required_sources SET lifecycle = 'capturing'
             WHERE session_id = ?1
               AND kind = (
                 SELECT sources.kind FROM sources
                 JOIN tracks ON tracks.source_id = sources.id
                 JOIN segments ON segments.track_id = tracks.id
                 WHERE segments.id = ?2
               )",
            params![session_id, segment_id],
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

    fn project_segment_seal(
        &mut self,
        session_id: &str,
        payload: &Value,
        journal_record: &JournalRecord,
    ) -> Result<(), StoreError> {
        let segment_id = payload_string(payload, "segment_id")?;
        let source_id = payload_string(payload, "source_id")?;
        let track_id = payload_string(payload, "track_id")?;
        let sample_count = payload_u64(payload, "sample_count")?;
        let final_byte_length = payload_u64(payload, "final_byte_length")?;
        let digest = payload_string(payload, "digest_sha256")?;
        let (event_sequence, prior_digest) = next_database_event(&self.connection, session_id)?;
        let event_hash = event_digest(
            session_id,
            event_sequence,
            "segment_sealed",
            payload,
            prior_digest.as_deref(),
        )?;
        let now = wall_time_milliseconds();
        let transaction = self.connection.transaction()?;
        let changed = transaction.execute(
            "UPDATE segments
             SET lifecycle = 'sealed', sample_count = ?2, byte_length = ?3,
                 digest = ?4, seal_state = 'sealed'
             WHERE id = ?1 AND session_id = ?5 AND lifecycle = 'capturing'",
            params![
                segment_id,
                sample_count as i64,
                final_byte_length as i64,
                digest,
                session_id,
            ],
        )?;
        if changed != 1 {
            return Err(StoreError::InvalidState(
                "segment projection is not awaiting seal evidence",
            ));
        }
        let source_changed = transaction.execute(
            "UPDATE sources SET lifecycle = 'sealed'
             WHERE id = ?1 AND session_id = ?2 AND lifecycle = 'capturing'",
            params![source_id, session_id],
        )?;
        let track_changed = transaction.execute(
            "UPDATE tracks SET lifecycle = 'sealed'
             WHERE id = ?1 AND session_id = ?2 AND lifecycle = 'capturing'",
            params![track_id, session_id],
        )?;
        if source_changed != 1 || track_changed != 1 {
            return Err(StoreError::InvalidState(
                "source or track projection is not awaiting seal evidence",
            ));
        }
        transaction.execute(
            "UPDATE required_sources SET lifecycle = 'sealed'
             WHERE session_id = ?1
               AND kind = (SELECT kind FROM sources WHERE id = ?2 AND session_id = ?1)",
            params![session_id, source_id],
        )?;
        transaction.execute(
            "UPDATE sessions
             SET media_files_open = EXISTS(
                    SELECT 1 FROM segments
                    WHERE session_id = ?1 AND lifecycle IN ('opening', 'open', 'capturing')
                 ),
                 lifecycle = CASE
                    WHEN lifecycle = 'recording' AND NOT EXISTS(
                        SELECT 1 FROM segments
                        WHERE session_id = ?1 AND lifecycle IN ('opening', 'open', 'capturing')
                    ) THEN 'ready_for_review'
                    ELSE lifecycle
                 END,
                 updated_at_ms = ?2
             WHERE id = ?1 AND lifecycle IN ('preparing', 'recording')",
            params![session_id, now],
        )?;
        insert_event_with_id(
            &transaction,
            &journal_record.body.event_id,
            session_id,
            event_sequence,
            "segment_sealed",
            journal_record.body.wall_time_milliseconds,
            payload,
            prior_digest.as_deref(),
            &event_hash,
        )?;
        transaction.commit()?;
        Ok(())
    }

    fn project_session_interruption(
        &mut self,
        session_id: &str,
        payload: &Value,
        journal_record: &JournalRecord,
    ) -> Result<(), StoreError> {
        let reason = payload_string(payload, "reason")?;
        SessionInterruptionReason::from_str(reason)?;
        let (event_sequence, prior_digest) = next_database_event(&self.connection, session_id)?;
        let digest = event_digest(
            session_id,
            event_sequence,
            "session_interrupted",
            payload,
            prior_digest.as_deref(),
        )?;
        let transaction = self.connection.transaction()?;
        let changed = transaction.execute(
            "UPDATE sessions SET lifecycle = 'interrupted', updated_at_ms = ?2
             WHERE id = ?1 AND lifecycle IN ('preparing', 'recording')",
            params![session_id, journal_record.body.wall_time_milliseconds],
        )?;
        if changed != 1 {
            return Err(StoreError::InvalidState(
                "session projection is not awaiting interruption evidence",
            ));
        }
        insert_event_with_id(
            &transaction,
            &journal_record.body.event_id,
            session_id,
            event_sequence,
            "session_interrupted",
            journal_record.body.wall_time_milliseconds,
            payload,
            prior_digest.as_deref(),
            &digest,
        )?;
        transaction.commit()?;
        Ok(())
    }

    fn project_playable_recovery_session(
        &mut self,
        session_id: &str,
        projections: &[PlayableRecoveryProjection],
    ) -> Result<(), StoreError> {
        if projections.is_empty() {
            return Err(StoreError::InvalidRequest("recovery projection is empty"));
        }
        let (mut event_sequence, mut prior_digest) =
            next_database_event(&self.connection, session_id)?;
        let transaction = self.connection.transaction()?;
        let mut updated_at_ms = 0;
        for projection in projections {
            let payload = &projection.payload;
            let journal_record = &projection.journal_record;
            let source_id = payload_string(payload, "source_id")?;
            let track_id = payload_string(payload, "track_id")?;
            let segment_id = payload_string(payload, "segment_id")?;
            let sample_count = payload_u64(payload, "sample_count")?;
            let final_byte_length = payload_u64(payload, "final_byte_length")?;
            let digest_sha256 = payload_string(payload, "digest_sha256")?;
            let changed = transaction.execute(
                "UPDATE segments
                 SET lifecycle = 'sealed', sample_count = ?2, byte_length = ?3,
                     digest = ?4, seal_state = 'sealed', recovery_state = 'recovered'
                 WHERE id = ?1 AND session_id = ?5 AND lifecycle = 'capturing'",
                params![
                    segment_id,
                    sample_count as i64,
                    final_byte_length as i64,
                    digest_sha256,
                    session_id,
                ],
            )?;
            if changed != 1 {
                return Err(StoreError::InvalidState(
                    "segment projection is not awaiting playable recovery",
                ));
            }
            let source_changed = transaction.execute(
                "UPDATE sources SET lifecycle = 'sealed'
                 WHERE id = ?1 AND session_id = ?2 AND lifecycle = 'capturing'",
                params![source_id, session_id],
            )?;
            let track_changed = transaction.execute(
                "UPDATE tracks SET lifecycle = 'sealed'
                 WHERE id = ?1 AND session_id = ?2 AND lifecycle = 'capturing'",
                params![track_id, session_id],
            )?;
            if source_changed != 1 || track_changed != 1 {
                return Err(StoreError::InvalidState(
                    "source or track projection is not awaiting playable recovery",
                ));
            }
            transaction.execute(
                "UPDATE required_sources SET lifecycle = 'sealed'
                 WHERE session_id = ?1
                   AND kind = (SELECT kind FROM sources WHERE id = ?2 AND session_id = ?1)",
                params![session_id, source_id],
            )?;
            let event_hash = event_digest(
                session_id,
                event_sequence,
                "playable_media_recovered",
                payload,
                prior_digest.as_deref(),
            )?;
            insert_event_with_id(
                &transaction,
                &journal_record.body.event_id,
                session_id,
                event_sequence,
                "playable_media_recovered",
                journal_record.body.wall_time_milliseconds,
                payload,
                prior_digest.as_deref(),
                &event_hash,
            )?;
            event_sequence += 1;
            prior_digest = Some(event_hash);
            updated_at_ms = updated_at_ms.max(journal_record.body.wall_time_milliseconds);
        }
        transaction.execute(
            "UPDATE required_sources AS required
             SET lifecycle = 'sealed'
             WHERE required.session_id = ?1
               AND EXISTS (
                   SELECT 1 FROM sources
                   JOIN tracks ON tracks.source_id = sources.id
                   JOIN segments ON segments.track_id = tracks.id
                   WHERE sources.session_id = required.session_id
                     AND sources.kind = required.kind
                     AND sources.lifecycle = 'sealed'
                     AND tracks.lifecycle = 'sealed'
                     AND segments.lifecycle = 'sealed'
               )",
            [session_id],
        )?;
        let incomplete_segments: i64 = transaction.query_row(
            "SELECT COUNT(*) FROM segments
             WHERE session_id = ?1 AND lifecycle IN ('opening', 'open', 'capturing')",
            [session_id],
            |row| row.get(0),
        )?;
        let incomplete_sources: i64 = transaction.query_row(
            "SELECT COUNT(*) FROM required_sources
             WHERE session_id = ?1 AND lifecycle != 'sealed'",
            [session_id],
            |row| row.get(0),
        )?;
        if incomplete_segments != 0 || incomplete_sources != 0 {
            return Err(StoreError::InvalidState(
                "session recovery is missing a required playable source",
            ));
        }
        let session_changed = transaction.execute(
            "UPDATE sessions
             SET lifecycle = 'ready_for_review', media_files_open = 0, updated_at_ms = ?2
             WHERE id = ?1 AND lifecycle IN (
                       'preparing', 'recording', 'interrupted', 'ready_for_review'
                   )",
            params![session_id, updated_at_ms],
        )?;
        if session_changed != 1 {
            return Err(StoreError::InvalidState(
                "session projection is not awaiting playable recovery",
            ));
        }
        transaction.execute(
            "INSERT INTO recovery_runs (
                id, schema_version, session_id, disposition, created_at_ms
             ) VALUES (?1, ?2, ?3, 'playable_media_recovered', ?4)",
            params![
                Uuid::now_v7().to_string(),
                SCHEMA_VERSION,
                session_id,
                updated_at_ms,
            ],
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
                "SELECT segments.session_id, tracks.source_id, segments.track_id,
                        segments.relative_path, segments.media_format, segments.lifecycle,
                        segments.open_token, segments.writer_generation, segments.byte_length,
                        segments.file_device, segments.file_inode
                 FROM segments
                 JOIN tracks ON tracks.id = segments.track_id
                 WHERE segments.id = ?1",
                [segment_id],
                |row| {
                    Ok(StoredMediaAuthorization {
                        session_id: row.get(0)?,
                        source_id: row.get(1)?,
                        track_id: row.get(2)?,
                        relative_path: row.get(3)?,
                        media_format: row.get(4)?,
                        lifecycle: row.get(5)?,
                        open_token: row.get(6)?,
                        writer_generation: row.get::<_, i64>(7)? as u64,
                        byte_length: row.get::<_, Option<i64>>(8)?.map(|value| value as u64),
                        file_device: row.get::<_, Option<i64>>(9)?.map(|value| value as u64),
                        file_inode: row.get::<_, Option<i64>>(10)?.map(|value| value as u64),
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

    fn segment_event_payload(
        &self,
        session_id: &str,
        event_kind: &str,
        segment_id: &str,
        missing_message: &'static str,
    ) -> Result<Value, StoreError> {
        let mut statement = self.connection.prepare(
            "SELECT payload_json FROM session_events
             WHERE session_id = ?1 AND event_kind = ?2
             ORDER BY sequence DESC",
        )?;
        let payloads = statement.query_map(params![session_id, event_kind], |row| {
            row.get::<_, String>(0)
        })?;
        for payload in payloads {
            let payload: Value = serde_json::from_str(&payload?)?;
            if payload_string(&payload, "segment_id")? == segment_id {
                return Ok(payload);
            }
        }
        Err(StoreError::InvalidState(missing_message))
    }

    fn validate_media_file(
        &self,
        session_id: &str,
        relative_path: &str,
        length_requirement: MediaLengthRequirement,
        calculate_digest: bool,
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
        let mut file = File::from(media_fd);
        file.sync_all()?;
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
        let digest_sha256 = if calculate_digest {
            file.rewind()?;
            let mut hasher = Sha256::new();
            let mut buffer = [0_u8; 64 * 1024];
            let mut remaining = byte_length;
            while remaining > 0 {
                let read_limit = usize::try_from(remaining.min(buffer.len() as u64))
                    .map_err(|_| StoreError::IntegrityMismatch("media length is unsupported"))?;
                let read = file.read(&mut buffer[..read_limit])?;
                if read == 0 {
                    return Err(StoreError::IntegrityMismatch(
                        "sealed media ended before its accepted byte length",
                    ));
                }
                hasher.update(&buffer[..read]);
                remaining -= read as u64;
            }
            let mut extra = [0_u8; 1];
            if file.read(&mut extra)? != 0 {
                return Err(StoreError::IntegrityMismatch(
                    "sealed media exceeds its accepted byte length",
                ));
            }
            Some(format!("{:x}", hasher.finalize()))
        } else {
            None
        };
        file.rewind()?;
        let recoverable_sample_count = inspect_recoverable_pcm_caf(&mut file, byte_length)?;
        let post_read_stat = fd_fs::fstat(&file).map_err(|_| {
            StoreError::IntegrityMismatch("sealed media identity could not be revalidated")
        })?;
        if post_read_stat.st_dev != stat.st_dev
            || post_read_stat.st_ino != stat.st_ino
            || post_read_stat.st_size != stat.st_size
        {
            return Err(StoreError::IntegrityMismatch(
                "media file changed while Rust validated it",
            ));
        }
        let rebound_fd = fd_fs::openat(
            &track,
            *file_component,
            fd_fs::OFlags::RDWR | fd_fs::OFlags::CLOEXEC | fd_fs::OFlags::NOFOLLOW,
            fd_fs::Mode::empty(),
        )
        .map_err(|_| StoreError::IntegrityMismatch("media path changed while Rust validated it"))?;
        let rebound_stat = fd_fs::fstat(&rebound_fd).map_err(|_| {
            StoreError::IntegrityMismatch("media path identity could not be rebound")
        })?;
        if rebound_stat.st_dev != stat.st_dev
            || rebound_stat.st_ino != stat.st_ino
            || rebound_stat.st_size != stat.st_size
        {
            return Err(StoreError::IntegrityMismatch(
                "media path no longer names the validated file",
            ));
        }
        fd_fs::fsync(&track).map_err(|_| {
            StoreError::IntegrityMismatch("media directory could not be synchronized")
        })?;
        Ok(ValidatedMediaFile {
            byte_length,
            device: stat.st_dev as u64,
            inode: stat.st_ino as u64,
            digest_sha256,
            recoverable_sample_count,
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
                "SELECT id, journal_durable FROM sessions
                 WHERE lifecycle IN ('preparing', 'recording', 'interrupted') ORDER BY id",
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
                    let base =
                        self.recover_valid_journal(&session_id, journal_durable, &records)?;
                    let disposition = self.reconcile_interruption(&session_id, &records, base)?;
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

        let Some(authorization_record) = authorization_record else {
            return Ok(if repaired_directory {
                RecoveryDisposition::ProjectionRepaired
            } else {
                RecoveryDisposition::Prepared
            });
        };
        let segment_id = payload_string(&authorization_record.body.payload, "segment_id")?;
        let opened_record = journal_record_for_segment(records, "segment_opened", segment_id)?;
        let first_sample_record =
            journal_record_for_segment(records, "first_sample_captured", segment_id)?;
        let sealed_record = journal_record_for_segment(records, "segment_sealed", segment_id)?;
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
                false,
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
            if let Some(sealed_record) = sealed_record {
                let payload = &sealed_record.body.payload;
                if payload_string(payload, "segment_id")? != segment_id
                    || payload_string(payload, "relative_path")? != relative_path
                    || payload_u64(payload, "file_device")? != expected_device
                    || payload_u64(payload, "file_inode")? != expected_inode
                {
                    return Ok(RecoveryDisposition::IntegrityMismatch);
                }
                let final_byte_length = payload_u64(payload, "final_byte_length")?;
                let sealed = match self.validate_media_file(
                    session_id,
                    relative_path,
                    MediaLengthRequirement::Exact(final_byte_length),
                    true,
                ) {
                    Ok(sealed) => sealed,
                    Err(_) => return Ok(RecoveryDisposition::InvalidMediaFile),
                };
                if sealed.digest_sha256.as_deref()
                    != Some(payload_string(payload, "digest_sha256")?)
                {
                    return Ok(RecoveryDisposition::IntegrityMismatch);
                }
                let segment_lifecycle: String = self.connection.query_row(
                    "SELECT lifecycle FROM segments WHERE id = ?1 AND session_id = ?2",
                    params![segment_id, session_id],
                    |row| row.get(0),
                )?;
                if segment_lifecycle == "sealed" {
                    return Ok(RecoveryDisposition::SegmentSealedPrepared);
                }
                if segment_lifecycle != "capturing" {
                    return Ok(RecoveryDisposition::IntegrityMismatch);
                }
                self.project_segment_seal(session_id, payload, sealed_record)?;
                return Ok(RecoveryDisposition::SegmentSealProjectionRepaired);
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
                        false,
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
                false,
            )
            .is_ok()
        {
            Ok(RecoveryDisposition::MediaOpenAwaitingReceipt)
        } else {
            Ok(RecoveryDisposition::InvalidMediaFile)
        }
    }

    fn reconcile_interruption(
        &mut self,
        session_id: &str,
        records: &[JournalRecord],
        base: RecoveryDisposition,
    ) -> Result<RecoveryDisposition, StoreError> {
        let interruptions: Vec<_> = records
            .iter()
            .filter(|record| record.body.event_kind == "session_interrupted")
            .collect();
        if interruptions.is_empty() {
            return Ok(base);
        }
        if interruptions.len() != 1 || interruptions[0].body.sequence != records.len() as u64 {
            return Ok(RecoveryDisposition::IntegrityMismatch);
        }
        let interruption = interruptions[0];
        SessionInterruptionReason::from_str(payload_string(&interruption.body.payload, "reason")?)?;
        let lifecycle: String = self.connection.query_row(
            "SELECT lifecycle FROM sessions WHERE id = ?1",
            [session_id],
            |row| row.get(0),
        )?;
        if matches!(lifecycle.as_str(), "preparing" | "recording") {
            self.project_session_interruption(
                session_id,
                &interruption.body.payload,
                interruption,
            )?;
            return Ok(RecoveryDisposition::InterruptionProjectionRepaired);
        }
        if lifecycle != "interrupted" {
            return Ok(RecoveryDisposition::IntegrityMismatch);
        }
        Ok(match base {
            RecoveryDisposition::Prepared | RecoveryDisposition::ProjectionRepaired => {
                RecoveryDisposition::InterruptedPrepared
            }
            RecoveryDisposition::MediaOpenPrepared
            | RecoveryDisposition::MediaOpenProjectionRepaired
            | RecoveryDisposition::MediaOpenAwaitingReceipt => {
                RecoveryDisposition::InterruptedMediaOpen
            }
            RecoveryDisposition::FirstSamplePrepared
            | RecoveryDisposition::FirstSampleProjectionRepaired => {
                RecoveryDisposition::InterruptedFirstSample
            }
            RecoveryDisposition::SegmentSealedPrepared
            | RecoveryDisposition::SegmentSealProjectionRepaired => {
                RecoveryDisposition::InterruptedSegmentSealed
            }
            other => other,
        })
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
        CREATE TABLE IF NOT EXISTS required_sources (
            session_id TEXT NOT NULL REFERENCES sessions(id),
            schema_version INTEGER NOT NULL,
            kind TEXT NOT NULL CHECK (
                kind IN ('microphone', 'application_audio', 'system_audio')
            ),
            lifecycle TEXT NOT NULL CHECK (
                lifecycle IN ('required', 'opening', 'open', 'capturing', 'failed', 'sealed')
            ),
            PRIMARY KEY(session_id, kind)
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
    transaction.execute(
        "INSERT OR IGNORE INTO schema_migrations (version, applied_at_ms) VALUES (3, ?1)",
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

fn inspect_recoverable_pcm_caf(
    file: &mut File,
    byte_length: u64,
) -> Result<Option<u64>, StoreError> {
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
    let mut descriptor_matches = false;
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
            descriptor_matches = sample_rate == f64::from(MEDIA_SAMPLE_RATE_HZ)
                && &descriptor[8..12] == b"lpcm"
                && flags == 2
                && bytes_per_packet == 2
                && frames_per_packet == 1
                && channels == 1
                && bits_per_channel == 16;
        }

        if chunk_type == b"data" {
            if !descriptor_matches || chunk_size < -1 {
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
            if audio_bytes == 0 || audio_bytes % 2 != 0 {
                return Ok(None);
            }
            return Ok(Some(audio_bytes / 2));
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

fn normalized_source_kinds(
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
    names.into_iter().map(MediaSourceKind::from_str).collect()
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

fn validate_seal_receipt_shape(receipt: &SealSegmentReceipt) -> Result<(), StoreError> {
    if Uuid::parse_str(&receipt.session_id.0).is_err()
        || Uuid::parse_str(&receipt.track_id).is_err()
        || Uuid::parse_str(&receipt.segment_id).is_err()
        || Uuid::parse_str(&receipt.open_token).is_err()
    {
        return Err(StoreError::InvalidRequest(
            "segment-seal receipt identity is not a UUID",
        ));
    }
    if receipt.writer_generation != 1 || !valid_media_relative_path(&receipt.relative_path) {
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

fn journal_record_for_segment<'a>(
    records: &'a [JournalRecord],
    event_kind: &str,
    segment_id: &str,
) -> Result<Option<&'a JournalRecord>, StoreError> {
    for record in records.iter().rev() {
        if record.body.event_kind == event_kind
            && payload_string(&record.body.payload, "segment_id")? == segment_id
        {
            return Ok(Some(record));
        }
    }
    Ok(None)
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
    fn schema_v3_applies_required_durability_settings_tables_and_media_columns() {
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
            "required_sources",
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
            3
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
        assert_eq!(receipt.schema_version, 3);
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

    fn seal_receipt(
        authorization: &MediaOpenAuthorization,
        final_byte_length: u64,
    ) -> SealSegmentReceipt {
        SealSegmentReceipt {
            session_id: authorization.session_id.clone(),
            track_id: authorization.track_id.clone(),
            segment_id: authorization.segment_id.clone(),
            open_token: authorization.open_token.clone(),
            writer_generation: authorization.writer_generation,
            relative_path: authorization.relative_path.clone(),
            final_sample_host_time: 52_000,
            sample_count: 960,
            final_byte_length,
        }
    }

    fn prepared_first_sample(
        store: &mut SessionStore,
    ) -> (PreparedSessionReceipt, MediaOpenAuthorization, u64) {
        let prepared = store.prepare_session(request()).unwrap();
        let authorization = store
            .authorize_media_open(media_request(prepared.session_id.clone()))
            .unwrap();
        let initial_byte_length = write_test_caf(&authorization);
        store
            .accept_media_open(media_receipt(&authorization, initial_byte_length))
            .unwrap();
        let observed_byte_length = append_first_sample(&authorization);
        store
            .accept_first_sample(first_sample_receipt(&authorization, observed_byte_length))
            .unwrap();
        (prepared, authorization, observed_byte_length)
    }

    fn prepared_dual_first_samples(
        store: &mut SessionStore,
    ) -> (
        PreparedSessionReceipt,
        MediaOpenAuthorization,
        MediaOpenAuthorization,
    ) {
        let prepared = store
            .prepare_session_with_required_sources(
                request(),
                vec![MediaSourceKind::Microphone, MediaSourceKind::SystemAudio],
            )
            .unwrap();
        let microphone = store
            .authorize_media_open(AuthorizeMediaOpenRequest {
                session_id: prepared.session_id.clone(),
                source_kind: MediaSourceKind::Microphone,
                source_display_name: "Mac microphone".to_owned(),
            })
            .unwrap();
        let microphone_initial = write_test_caf(&microphone);
        store
            .accept_media_open(media_receipt(&microphone, microphone_initial))
            .unwrap();
        let system = store
            .authorize_media_open(AuthorizeMediaOpenRequest {
                session_id: prepared.session_id.clone(),
                source_kind: MediaSourceKind::SystemAudio,
                source_display_name: "Mac system audio".to_owned(),
            })
            .unwrap();
        let system_initial = write_test_caf(&system);
        store
            .accept_media_open(media_receipt(&system, system_initial))
            .unwrap();
        let microphone_observed = append_first_sample(&microphone);
        store
            .accept_first_sample(first_sample_receipt(&microphone, microphone_observed))
            .unwrap();
        let system_observed = append_first_sample(&system);
        store
            .accept_first_sample(first_sample_receipt(&system, system_observed))
            .unwrap();
        (prepared, microphone, system)
    }

    fn replace_with_recoverable_pcm_caf(authorization: &MediaOpenAuthorization, sample_count: u64) {
        let mut file = OpenOptions::new()
            .write(true)
            .truncate(true)
            .open(&authorization.absolute_path)
            .unwrap();
        file.write_all(CAF_HEADER).unwrap();
        file.write_all(b"desc").unwrap();
        file.write_all(&32_i64.to_be_bytes()).unwrap();
        file.write_all(&48_000_f64.to_bits().to_be_bytes()).unwrap();
        file.write_all(b"lpcm").unwrap();
        file.write_all(&2_u32.to_be_bytes()).unwrap();
        file.write_all(&2_u32.to_be_bytes()).unwrap();
        file.write_all(&1_u32.to_be_bytes()).unwrap();
        file.write_all(&1_u32.to_be_bytes()).unwrap();
        file.write_all(&16_u32.to_be_bytes()).unwrap();
        file.write_all(b"data").unwrap();
        file.write_all(&(-1_i64).to_be_bytes()).unwrap();
        file.write_all(&0_u32.to_be_bytes()).unwrap();
        file.write_all(&vec![0_u8; sample_count as usize * 2])
            .unwrap();
        file.sync_all().unwrap();
    }

    fn insert_parallel_database_event(
        store: &mut SessionStore,
        session_id: &str,
        event_kind: &str,
        payload: &Value,
    ) {
        let (sequence, prior_digest) = next_database_event(&store.connection, session_id).unwrap();
        let digest = event_digest(
            session_id,
            sequence,
            event_kind,
            payload,
            prior_digest.as_deref(),
        )
        .unwrap();
        let transaction = store.connection.transaction().unwrap();
        insert_event(
            &transaction,
            session_id,
            sequence,
            event_kind,
            wall_time_milliseconds(),
            payload,
            prior_digest.as_deref(),
            &digest,
        )
        .unwrap();
        transaction.commit().unwrap();
    }

    #[test]
    fn sealed_segment_binds_writer_totals_to_an_independent_digest_without_recording() {
        let temp = TempDir::new().unwrap();
        let mut store = open_store(&temp);
        let (prepared, authorization, final_byte_length) = prepared_first_sample(&mut store);
        let receipt = seal_receipt(&authorization, final_byte_length);

        let evidence = store.seal_segment(receipt.clone()).unwrap();
        assert!(evidence.segment_sealed);
        assert!(!evidence.recording_started);
        assert_eq!(evidence.sample_count, 960);
        assert_eq!(evidence.digest_sha256.len(), 64);
        assert_eq!(store.seal_segment(receipt.clone()).unwrap(), evidence);
        assert_eq!(
            store
                .connection
                .query_row(
                    "SELECT lifecycle, sample_count, byte_length, seal_state
                     FROM segments WHERE id = ?1",
                    [&authorization.segment_id],
                    |row| Ok((
                        row.get::<_, String>(0)?,
                        row.get::<_, i64>(1)?,
                        row.get::<_, i64>(2)?,
                        row.get::<_, String>(3)?,
                    )),
                )
                .unwrap(),
            (
                "sealed".to_owned(),
                960,
                final_byte_length as i64,
                "sealed".to_owned()
            )
        );
        assert_eq!(
            store
                .connection
                .query_row(
                    "SELECT lifecycle, media_files_open FROM sessions WHERE id = ?1",
                    [&prepared.session_id.0],
                    |row| Ok((row.get::<_, String>(0)?, row.get::<_, bool>(1)?)),
                )
                .unwrap(),
            ("preparing".to_owned(), false)
        );

        let mut changed = receipt;
        changed.sample_count += 1;
        assert!(matches!(
            store.seal_segment(changed),
            Err(StoreError::IntegrityMismatch(
                "repeated segment-seal receipt changed accepted evidence"
            ))
        ));
    }

    #[test]
    fn segment_seal_and_replay_ignore_later_parallel_events() {
        let temp = TempDir::new().unwrap();
        let mut store = open_store(&temp);
        let (prepared, authorization, final_byte_length) = prepared_first_sample(&mut store);
        let parallel_segment = Uuid::now_v7().to_string();
        insert_parallel_database_event(
            &mut store,
            &prepared.session_id.0,
            "first_sample_captured",
            &json!({
                "segment_id": parallel_segment,
                "track_id": Uuid::now_v7().to_string(),
            }),
        );

        let receipt = seal_receipt(&authorization, final_byte_length);
        let accepted = store.seal_segment(receipt.clone()).unwrap();
        insert_parallel_database_event(
            &mut store,
            &prepared.session_id.0,
            "segment_sealed",
            &json!({ "segment_id": parallel_segment }),
        );

        assert_eq!(store.seal_segment(receipt).unwrap(), accepted);
    }

    #[test]
    fn recovery_event_lookup_is_segment_keyed() {
        let session_id = Uuid::now_v7().to_string();
        let target_segment = Uuid::now_v7().to_string();
        let parallel_segment = Uuid::now_v7().to_string();
        let mut target = new_journal_record(&session_id, wall_time_milliseconds()).unwrap();
        target.body.event_kind = "segment_sealed".to_owned();
        target.body.payload = json!({ "segment_id": target_segment });
        let mut parallel = target.clone();
        parallel.body.sequence += 1;
        parallel.body.payload = json!({ "segment_id": parallel_segment });

        let records = [target, parallel];
        assert_eq!(
            payload_string(
                &journal_record_for_segment(&records, "segment_sealed", &target_segment)
                    .unwrap()
                    .unwrap()
                    .body
                    .payload,
                "segment_id",
            )
            .unwrap(),
            target_segment
        );
    }

    #[test]
    fn segment_seal_interruption_recovery_converges_without_recording() {
        for (phase, expected_first) in [
            (
                MediaFailurePoint::SegmentSealJournalSync,
                RecoveryDisposition::SegmentSealProjectionRepaired,
            ),
            (
                MediaFailurePoint::SegmentSealDatabaseProjection,
                RecoveryDisposition::SegmentSealedPrepared,
            ),
        ] {
            let temp = TempDir::new().unwrap();
            let root = temp.path().join("Open Scribe");
            {
                let mut store = SessionStore::open(&root).unwrap();
                let (_, authorization, final_byte_length) = prepared_first_sample(&mut store);
                let error = store
                    .seal_segment_inner(
                        seal_receipt(&authorization, final_byte_length),
                        Some(phase),
                    )
                    .unwrap_err();
                assert!(matches!(error, StoreError::InjectedInterruption));
            }

            let mut reopened = SessionStore::open(&root).unwrap();
            assert_eq!(
                reopened.recover_preparations().unwrap()[0].disposition,
                expected_first
            );
            assert_eq!(
                reopened.recover_preparations().unwrap()[0].disposition,
                RecoveryDisposition::SegmentSealedPrepared
            );
            assert_eq!(
                reopened
                    .connection
                    .query_row(
                        "SELECT lifecycle, media_files_open FROM sessions",
                        [],
                        |row| Ok((row.get::<_, String>(0)?, row.get::<_, bool>(1)?)),
                    )
                    .unwrap(),
                ("preparing".to_owned(), false)
            );
        }
    }

    #[test]
    fn sealing_one_segment_does_not_close_parallel_projection() {
        let temp = TempDir::new().unwrap();
        let mut store = open_store(&temp);
        let (prepared, authorization, final_byte_length) = prepared_first_sample(&mut store);
        let parallel_source = Uuid::now_v7().to_string();
        let parallel_track = Uuid::now_v7().to_string();
        let parallel_segment = Uuid::now_v7().to_string();
        store
            .connection
            .execute(
                "INSERT INTO sources (id, schema_version, session_id, kind, display_name, lifecycle)
                 VALUES (?1, ?2, ?3, 'system_audio', 'Parallel fixture', 'capturing')",
                params![parallel_source, SCHEMA_VERSION, prepared.session_id.0],
            )
            .unwrap();
        store
            .connection
            .execute(
                "INSERT INTO tracks (id, schema_version, session_id, source_id, kind, lifecycle)
                 VALUES (?1, ?2, ?3, ?4, 'system_audio', 'capturing')",
                params![
                    parallel_track,
                    SCHEMA_VERSION,
                    prepared.session_id.0,
                    parallel_source,
                ],
            )
            .unwrap();
        store
            .connection
            .execute(
                "INSERT INTO segments (
                    id, schema_version, session_id, track_id, sequence, relative_path,
                    lifecycle, mapped_start_ns, media_format, seal_state, recovery_state
                 ) VALUES (?1, ?2, ?3, ?4, 0, 'audio/parallel/000000-0.caf',
                           'capturing', 0, ?5, 'open', 'not_required')",
                params![
                    parallel_segment,
                    SCHEMA_VERSION,
                    prepared.session_id.0,
                    parallel_track,
                    MEDIA_FORMAT_CAF_PCM_S16LE,
                ],
            )
            .unwrap();

        store
            .seal_segment(seal_receipt(&authorization, final_byte_length))
            .unwrap();

        assert_eq!(
            store
                .connection
                .query_row(
                    "SELECT sources.lifecycle, tracks.lifecycle, segments.lifecycle,
                            sessions.media_files_open
                     FROM segments
                     JOIN tracks ON tracks.id = segments.track_id
                     JOIN sources ON sources.id = tracks.source_id
                     JOIN sessions ON sessions.id = segments.session_id
                     WHERE segments.id = ?1",
                    [&parallel_segment],
                    |row| Ok((
                        row.get::<_, String>(0)?,
                        row.get::<_, String>(1)?,
                        row.get::<_, String>(2)?,
                        row.get::<_, bool>(3)?,
                    )),
                )
                .unwrap(),
            (
                "capturing".to_owned(),
                "capturing".to_owned(),
                "capturing".to_owned(),
                true,
            )
        );
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
        assert_eq!(evidence.last_journal_sequence, 5);
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
        assert_eq!(evidence.last_journal_sequence, 4);
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
        assert_eq!(repeated.last_journal_sequence, 4);
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
        assert_eq!(grown.last_journal_sequence, 4);

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

    #[test]
    fn interrupted_first_sample_is_durable_discoverable_and_media_preserving() {
        let temp = TempDir::new().unwrap();
        let root = temp.path().join("Open Scribe");
        let session_id;
        let media_path;
        let media_before;
        {
            let mut store = SessionStore::open(&root).unwrap();
            let (prepared, authorization, _) = prepared_first_sample(&mut store);
            session_id = prepared.session_id;
            media_path = authorization.absolute_path;
            media_before = fs::read(&media_path).unwrap();

            let evidence = store
                .interrupt_session(InterruptSessionRequest {
                    session_id: session_id.clone(),
                    reason: SessionInterruptionReason::CaptureFailed,
                })
                .unwrap();

            assert!(evidence.journal_durable);
            assert!(evidence.session_interrupted);
            assert!(!evidence.recording_started);
            assert_eq!(evidence.last_journal_sequence, 6);
            assert_eq!(fs::read(&media_path).unwrap(), media_before);
        }

        let mut reopened = SessionStore::open(&root).unwrap();
        let finding = reopened.recover_preparations().unwrap().remove(0);
        assert_eq!(
            finding.disposition,
            RecoveryDisposition::InterruptedFirstSample
        );
        assert_eq!(
            reopened
                .connection
                .query_row(
                    "SELECT lifecycle FROM sessions WHERE id = ?1",
                    [&session_id.0],
                    |row| row.get::<_, String>(0),
                )
                .unwrap(),
            "interrupted"
        );
        assert_eq!(fs::read(media_path).unwrap(), media_before);
    }

    #[test]
    fn interruption_replay_is_idempotent_and_rejects_a_changed_reason() {
        let temp = TempDir::new().unwrap();
        let mut store = open_store(&temp);
        let (prepared, _, _) = prepared_first_sample(&mut store);
        let request = InterruptSessionRequest {
            session_id: prepared.session_id,
            reason: SessionInterruptionReason::CaptureFailed,
        };

        let accepted = store.interrupt_session(request.clone()).unwrap();
        let repeated = store.interrupt_session(request.clone()).unwrap();
        assert_eq!(accepted, repeated);

        let changed = InterruptSessionRequest {
            session_id: request.session_id,
            reason: SessionInterruptionReason::FirstSampleRejected,
        };
        assert!(matches!(
            store.interrupt_session(changed),
            Err(StoreError::IntegrityMismatch(
                "repeated interruption changed accepted evidence"
            ))
        ));
    }

    #[test]
    fn restart_repairs_journaled_interruption_projection_without_touching_media() {
        let temp = TempDir::new().unwrap();
        let root = temp.path().join("Open Scribe");
        let session_id;
        let media_path;
        let media_before;
        {
            let mut store = SessionStore::open(&root).unwrap();
            let (prepared, authorization, _) = prepared_first_sample(&mut store);
            session_id = prepared.session_id;
            media_path = authorization.absolute_path;
            media_before = fs::read(&media_path).unwrap();
            store
                .append_session_journal(
                    &session_id.0,
                    "session_interrupted",
                    None,
                    json!({ "reason": "capture_failed" }),
                )
                .unwrap();
        }

        let mut reopened = SessionStore::open(&root).unwrap();
        let first = reopened.recover_preparations().unwrap().remove(0);
        assert_eq!(
            first.disposition,
            RecoveryDisposition::InterruptionProjectionRepaired
        );
        let second = reopened.recover_preparations().unwrap().remove(0);
        assert_eq!(
            second.disposition,
            RecoveryDisposition::InterruptedFirstSample
        );
        assert_eq!(fs::read(media_path).unwrap(), media_before);
    }

    #[test]
    fn direct_retry_repairs_journaled_interruption_and_rejects_changed_reason() {
        let temp = TempDir::new().unwrap();
        let mut store = open_store(&temp);
        let (prepared, _, _) = prepared_first_sample(&mut store);
        store
            .append_session_journal(
                &prepared.session_id.0,
                "session_interrupted",
                None,
                json!({ "reason": "capture_failed" }),
            )
            .unwrap();

        let changed = store.interrupt_session(InterruptSessionRequest {
            session_id: prepared.session_id.clone(),
            reason: SessionInterruptionReason::FirstSampleRejected,
        });
        assert!(matches!(
            changed,
            Err(StoreError::IntegrityMismatch(
                "repeated interruption changed accepted evidence"
            ))
        ));

        let repaired = store
            .interrupt_session(InterruptSessionRequest {
                session_id: prepared.session_id.clone(),
                reason: SessionInterruptionReason::CaptureFailed,
            })
            .unwrap();
        assert!(repaired.journal_durable);
        assert!(repaired.session_interrupted);
        assert!(!repaired.recording_started);
        assert_eq!(repaired.last_journal_sequence, 6);
        assert_eq!(
            store
                .connection
                .query_row(
                    "SELECT lifecycle FROM sessions WHERE id = ?1",
                    [&prepared.session_id.0],
                    |row| row.get::<_, String>(0),
                )
                .unwrap(),
            "interrupted"
        );

        let replayed = store
            .interrupt_session(InterruptSessionRequest {
                session_id: prepared.session_id,
                reason: SessionInterruptionReason::CaptureFailed,
            })
            .unwrap();
        assert_eq!(repaired, replayed);
    }

    #[test]
    fn forced_exit_recovery_preserves_caf_and_converges_to_ready_for_review() {
        let temp = TempDir::new().unwrap();
        let root = temp.path().join("Open Scribe");
        let session_id;
        let media_path;
        let media_before;
        {
            let mut store = SessionStore::open(&root).unwrap();
            let (prepared, authorization, _) = prepared_first_sample(&mut store);
            session_id = prepared.session_id;
            replace_with_recoverable_pcm_caf(&authorization, 4_800);
            media_path = authorization.absolute_path;
            media_before = fs::read(&media_path).unwrap();
        }

        let mut reopened = SessionStore::open(&root).unwrap();
        let recovered = reopened.recover_playable_sessions().unwrap();
        assert_eq!(recovered.len(), 1);
        assert_eq!(recovered[0].session_id, session_id);
        assert_eq!(recovered[0].sample_count, 4_800);
        assert_eq!(recovered[0].duration_nanoseconds, 100_000_000);
        assert!(recovered[0].media_preserved);
        assert!(recovered[0].ready_for_review);
        assert!(!recovered[0].recording_started);
        assert_eq!(fs::read(&media_path).unwrap(), media_before);
        let repeated = reopened.recover_playable_sessions().unwrap();
        assert_eq!(repeated.len(), 1);
        assert_eq!(repeated[0].session_id, session_id);
        assert_eq!(
            reopened
                .connection
                .query_row(
                    "SELECT lifecycle FROM sessions WHERE id = ?1",
                    [&session_id.0],
                    |row| row.get::<_, String>(0),
                )
                .unwrap(),
            "ready_for_review"
        );
        assert_eq!(
            reopened
                .connection
                .query_row(
                    "SELECT recovery_state FROM segments WHERE session_id = ?1",
                    [&session_id.0],
                    |row| row.get::<_, String>(0),
                )
                .unwrap(),
            "recovered"
        );
        assert_eq!(
            database_value(
                &reopened,
                "SELECT COUNT(*) FROM recovery_runs WHERE disposition = 'playable_media_recovered'",
            ),
            1
        );
    }

    #[test]
    fn dual_source_recovery_projects_both_tracks_atomically_and_idempotently() {
        let temp = TempDir::new().unwrap();
        let root = temp.path().join("Open Scribe");
        let session_id;
        let microphone_path;
        let system_path;
        let microphone_bytes;
        let system_bytes;
        {
            let mut store = SessionStore::open(&root).unwrap();
            let (prepared, microphone, system) = prepared_dual_first_samples(&mut store);
            session_id = prepared.session_id.clone();
            replace_with_recoverable_pcm_caf(&microphone, 4_800);
            replace_with_recoverable_pcm_caf(&system, 4_800);
            microphone_path = microphone.absolute_path.clone();
            system_path = system.absolute_path.clone();
            microphone_bytes = fs::read(&microphone_path).unwrap();
            system_bytes = fs::read(&system_path).unwrap();
            store.confirm_recording(session_id.clone()).unwrap();
            store
                .interrupt_session(InterruptSessionRequest {
                    session_id: session_id.clone(),
                    reason: SessionInterruptionReason::CaptureFailed,
                })
                .unwrap();
        }

        let mut reopened = SessionStore::open(&root).unwrap();
        let recovered = reopened.recover_playable_sessions().unwrap();
        assert_eq!(recovered.len(), 2);
        assert!(recovered.iter().all(|item| item.session_id == session_id));
        assert_eq!(
            database_value(
                &reopened,
                "SELECT COUNT(*) FROM segments WHERE lifecycle = 'sealed' AND recovery_state = 'recovered'",
            ),
            2
        );
        assert_eq!(
            database_value(
                &reopened,
                "SELECT COUNT(*) FROM required_sources WHERE lifecycle = 'sealed'",
            ),
            2
        );
        assert_eq!(
            database_value(
                &reopened,
                "SELECT COUNT(*) FROM sessions WHERE lifecycle = 'ready_for_review'",
            ),
            1
        );
        assert_eq!(fs::read(&microphone_path).unwrap(), microphone_bytes);
        assert_eq!(fs::read(&system_path).unwrap(), system_bytes);

        let repeated = reopened.recover_playable_sessions().unwrap();
        assert_eq!(repeated.len(), 2);
        assert_eq!(
            database_value(
                &reopened,
                "SELECT COUNT(*) FROM recovery_runs WHERE disposition = 'playable_media_recovered'",
            ),
            1
        );
    }

    #[test]
    fn dual_source_recovery_refuses_partial_projection_when_one_track_is_invalid() {
        let temp = TempDir::new().unwrap();
        let root = temp.path().join("Open Scribe");
        let microphone_path;
        let microphone_bytes;
        {
            let mut store = SessionStore::open(&root).unwrap();
            let (prepared, microphone, _) = prepared_dual_first_samples(&mut store);
            replace_with_recoverable_pcm_caf(&microphone, 4_800);
            microphone_path = microphone.absolute_path.clone();
            microphone_bytes = fs::read(&microphone_path).unwrap();
            store
                .confirm_recording(prepared.session_id.clone())
                .unwrap();
            store
                .interrupt_session(InterruptSessionRequest {
                    session_id: prepared.session_id,
                    reason: SessionInterruptionReason::CaptureFailed,
                })
                .unwrap();
        }

        let mut reopened = SessionStore::open(&root).unwrap();
        assert!(reopened.recover_playable_sessions().unwrap().is_empty());
        assert_eq!(
            database_value(
                &reopened,
                "SELECT COUNT(*) FROM segments WHERE lifecycle = 'capturing'",
            ),
            2
        );
        assert_eq!(
            database_value(
                &reopened,
                "SELECT COUNT(*) FROM session_events WHERE event_kind = 'playable_media_recovered'",
            ),
            0
        );
        assert_eq!(
            database_value(
                &reopened,
                "SELECT COUNT(*) FROM sessions WHERE lifecycle = 'interrupted'",
            ),
            1
        );
        assert_eq!(fs::read(microphone_path).unwrap(), microphone_bytes);
    }

    #[test]
    fn recovery_returns_normally_sealed_companion_with_recovered_track() {
        let temp = TempDir::new().unwrap();
        let root = temp.path().join("Open Scribe");
        let microphone_path;
        let system_path;
        let microphone_bytes;
        let system_bytes;
        {
            let mut store = SessionStore::open(&root).unwrap();
            let (prepared, microphone, system) = prepared_dual_first_samples(&mut store);
            replace_with_recoverable_pcm_caf(&microphone, 960);
            replace_with_recoverable_pcm_caf(&system, 4_800);
            microphone_path = microphone.absolute_path.clone();
            system_path = system.absolute_path.clone();
            microphone_bytes = fs::read(&microphone_path).unwrap();
            system_bytes = fs::read(&system_path).unwrap();
            store
                .confirm_recording(prepared.session_id.clone())
                .unwrap();
            store
                .seal_segment(seal_receipt(&microphone, microphone_bytes.len() as u64))
                .unwrap();
            store
                .interrupt_session(InterruptSessionRequest {
                    session_id: prepared.session_id,
                    reason: SessionInterruptionReason::SegmentSealFailed,
                })
                .unwrap();
        }

        let mut reopened = SessionStore::open(&root).unwrap();
        let recovered = reopened.recover_playable_sessions().unwrap();
        assert_eq!(recovered.len(), 2);
        assert_eq!(
            database_value(
                &reopened,
                "SELECT COUNT(*) FROM segments WHERE lifecycle = 'sealed'",
            ),
            2
        );
        assert_eq!(
            database_value(
                &reopened,
                "SELECT COUNT(*) FROM segments WHERE recovery_state = 'recovered'",
            ),
            1
        );
        assert_eq!(fs::read(&microphone_path).unwrap(), microphone_bytes);
        assert_eq!(fs::read(&system_path).unwrap(), system_bytes);
        assert_eq!(reopened.recover_playable_sessions().unwrap().len(), 2);
    }

    #[test]
    fn forced_exit_recovery_repairs_a_journal_first_projection_interruption() {
        let temp = TempDir::new().unwrap();
        let root = temp.path().join("Open Scribe");
        let session_id;
        {
            let mut store = SessionStore::open(&root).unwrap();
            let (prepared, authorization, observed_byte_length) = prepared_first_sample(&mut store);
            session_id = prepared.session_id;
            replace_with_recoverable_pcm_caf(&authorization, 2_400);
            let validated = store
                .validate_media_file(
                    &session_id.0,
                    &authorization.relative_path,
                    MediaLengthRequirement::AtLeast(observed_byte_length),
                    true,
                )
                .unwrap();
            let payload = json!({
                "source_id": authorization.source_id,
                "track_id": authorization.track_id,
                "segment_id": authorization.segment_id,
                "relative_path": authorization.relative_path,
                "sample_count": validated.recoverable_sample_count.unwrap(),
                "final_byte_length": validated.byte_length,
                "digest_sha256": validated.digest_sha256.unwrap(),
                "file_device": validated.device,
                "file_inode": validated.inode,
                "truncated_bytes": 0,
            });
            store
                .append_session_journal(
                    &session_id.0,
                    "playable_media_recovered",
                    Some(&authorization.relative_path),
                    payload,
                )
                .unwrap();
        }

        let mut reopened = SessionStore::open(&root).unwrap();
        let recovered = reopened.recover_playable_sessions().unwrap();
        assert_eq!(recovered.len(), 1);
        assert_eq!(recovered[0].session_id, session_id);
        assert_eq!(recovered[0].sample_count, 2_400);
        let repeated = reopened.recover_playable_sessions().unwrap();
        assert_eq!(repeated.len(), 1);
        assert_eq!(repeated[0].session_id, session_id);
        assert_eq!(
            database_value(
                &reopened,
                "SELECT COUNT(*) FROM recovery_runs WHERE disposition = 'playable_media_recovered'",
            ),
            1
        );
    }

    #[test]
    fn forced_exit_recovery_refuses_unparseable_media_without_mutation() {
        let temp = TempDir::new().unwrap();
        let root = temp.path().join("Open Scribe");
        let media_path;
        let media_before;
        {
            let mut store = SessionStore::open(&root).unwrap();
            let (_, authorization, _) = prepared_first_sample(&mut store);
            media_path = authorization.absolute_path;
            media_before = fs::read(&media_path).unwrap();
        }

        let mut reopened = SessionStore::open(&root).unwrap();
        assert!(reopened.recover_playable_sessions().unwrap().is_empty());
        assert_eq!(fs::read(media_path).unwrap(), media_before);
        assert_eq!(
            database_value(
                &reopened,
                "SELECT COUNT(*) FROM sessions WHERE lifecycle = 'preparing'",
            ),
            1
        );
    }

    #[test]
    fn recording_requires_every_durably_planned_source() {
        let temp = TempDir::new().unwrap();
        let mut store = open_store(&temp);
        let prepared = store
            .prepare_session_with_required_sources(
                request(),
                vec![MediaSourceKind::SystemAudio, MediaSourceKind::Microphone],
            )
            .unwrap();

        let microphone = store
            .authorize_media_open(AuthorizeMediaOpenRequest {
                session_id: prepared.session_id.clone(),
                source_kind: MediaSourceKind::Microphone,
                source_display_name: "Mac microphone".to_owned(),
            })
            .unwrap();
        let microphone_initial = write_test_caf(&microphone);
        let microphone_open = store
            .accept_media_open(media_receipt(&microphone, microphone_initial))
            .unwrap();
        assert!(!microphone_open.media_files_open);

        let system = store
            .authorize_media_open(AuthorizeMediaOpenRequest {
                session_id: prepared.session_id.clone(),
                source_kind: MediaSourceKind::SystemAudio,
                source_display_name: "Selected system audio".to_owned(),
            })
            .unwrap();
        let system_initial = write_test_caf(&system);
        let system_open = store
            .accept_media_open(media_receipt(&system, system_initial))
            .unwrap();
        assert!(system_open.media_files_open);

        let microphone_observed = append_first_sample(&microphone);
        store
            .accept_first_sample(first_sample_receipt(&microphone, microphone_observed))
            .unwrap();
        assert!(matches!(
            store.confirm_recording(prepared.session_id.clone()),
            Err(StoreError::InvalidState(
                "not every required source has durable first-sample evidence"
            ))
        ));

        let system_observed = append_first_sample(&system);
        store
            .accept_first_sample(first_sample_receipt(&system, system_observed))
            .unwrap();
        let recording = store
            .confirm_recording(prepared.session_id.clone())
            .unwrap();
        assert_eq!(
            recording.required_sources,
            vec![MediaSourceKind::Microphone, MediaSourceKind::SystemAudio]
        );
        assert_eq!(recording.active_sources, recording.required_sources);
        assert!(recording.journal_durable);
        assert!(recording.media_files_open);
        assert!(recording.recording_started);
        assert_eq!(
            store
                .connection
                .query_row(
                    "SELECT lifecycle FROM sessions WHERE id = ?1",
                    [&prepared.session_id.0],
                    |row| row.get::<_, String>(0),
                )
                .unwrap(),
            "recording"
        );
    }

    #[test]
    fn post_recording_source_failure_is_durably_interrupted_and_replayable() {
        let temp = TempDir::new().unwrap();
        let root = temp.path().join("Open Scribe");
        let session_id;
        let microphone_path;
        let system_path;
        {
            let mut store = SessionStore::open(&root).unwrap();
            let prepared = store
                .prepare_session_with_required_sources(
                    request(),
                    vec![MediaSourceKind::Microphone, MediaSourceKind::SystemAudio],
                )
                .unwrap();
            session_id = prepared.session_id.clone();

            let microphone = store
                .authorize_media_open(AuthorizeMediaOpenRequest {
                    session_id: session_id.clone(),
                    source_kind: MediaSourceKind::Microphone,
                    source_display_name: "Mac microphone".to_owned(),
                })
                .unwrap();
            let microphone_initial = write_test_caf(&microphone);
            store
                .accept_media_open(media_receipt(&microphone, microphone_initial))
                .unwrap();
            microphone_path = microphone.absolute_path.clone();

            let system = store
                .authorize_media_open(AuthorizeMediaOpenRequest {
                    session_id: session_id.clone(),
                    source_kind: MediaSourceKind::SystemAudio,
                    source_display_name: "Mac system audio".to_owned(),
                })
                .unwrap();
            let system_initial = write_test_caf(&system);
            store
                .accept_media_open(media_receipt(&system, system_initial))
                .unwrap();
            let microphone_observed = append_first_sample(&microphone);
            store
                .accept_first_sample(first_sample_receipt(&microphone, microphone_observed))
                .unwrap();
            let system_observed = append_first_sample(&system);
            store
                .accept_first_sample(first_sample_receipt(&system, system_observed))
                .unwrap();
            system_path = system.absolute_path.clone();

            assert!(
                store
                    .confirm_recording(session_id.clone())
                    .unwrap()
                    .recording_started
            );
            let request = InterruptSessionRequest {
                session_id: session_id.clone(),
                reason: SessionInterruptionReason::CaptureFailed,
            };
            let accepted = store.interrupt_session(request.clone()).unwrap();
            let replayed = store.interrupt_session(request).unwrap();
            assert_eq!(accepted, replayed);
            assert!(accepted.journal_durable);
            assert!(accepted.session_interrupted);
            assert!(!accepted.recording_started);
            assert_eq!(
                store
                    .connection
                    .query_row(
                        "SELECT lifecycle FROM sessions WHERE id = ?1",
                        [&session_id.0],
                        |row| row.get::<_, String>(0),
                    )
                    .unwrap(),
                "interrupted"
            );
        }

        let mut reopened = SessionStore::open(&root).unwrap();
        let findings = reopened.recover_preparations().unwrap();
        assert_eq!(findings.len(), 1);
        assert_eq!(
            findings[0].disposition,
            RecoveryDisposition::InterruptedFirstSample
        );
        assert!(microphone_path.is_file());
        assert!(system_path.is_file());
    }

    #[test]
    fn runtime_library_snapshot_projects_recording_timer_and_required_sources() {
        let temp = TempDir::new().unwrap();
        let mut store = open_store(&temp);
        let (prepared, _, _) = prepared_dual_first_samples(&mut store);
        store
            .confirm_recording(prepared.session_id.clone())
            .unwrap();
        let started_at_ms = store
            .connection
            .query_row(
                "SELECT wall_time_ms FROM session_events
                 WHERE session_id = ?1 AND event_kind = 'recording_started'",
                [&prepared.session_id.0],
                |row| row.get::<_, i64>(0),
            )
            .unwrap();

        let snapshot = store
            .runtime_library_snapshot_at(started_at_ms + 5_000)
            .unwrap();
        let current = snapshot.current_session.unwrap();

        assert_eq!(current.session_id, prepared.session_id);
        assert_eq!(current.lifecycle, "recording");
        assert_eq!(current.elapsed_seconds, 5);
        assert!(current.journal_durable);
        assert!(current.media_files_open);
        assert_eq!(current.sources.len(), 2);
        assert!(
            current
                .sources
                .iter()
                .all(|source| source.lifecycle == "capturing")
        );
        assert!(snapshot.saved_sessions.is_empty());

        store
            .interrupt_session(InterruptSessionRequest {
                session_id: prepared.session_id.clone(),
                reason: SessionInterruptionReason::CaptureFailed,
            })
            .unwrap();
        let interrupted = store
            .runtime_library_snapshot_at(started_at_ms + 7_000)
            .unwrap()
            .current_session
            .unwrap();
        assert_eq!(interrupted.lifecycle, "interrupted");
        assert_eq!(
            interrupted.interruption_reason,
            Some(SessionInterruptionReason::CaptureFailed)
        );
        assert!(
            interrupted
                .sources
                .iter()
                .all(|source| source.lifecycle == "failed")
        );
    }

    #[test]
    fn runtime_library_snapshot_exposes_saved_session_without_fixture_state() {
        let temp = TempDir::new().unwrap();
        let mut store = open_store(&temp);
        let (prepared, microphone, system) = prepared_dual_first_samples(&mut store);
        store
            .confirm_recording(prepared.session_id.clone())
            .unwrap();
        for authorization in [&microphone, &system] {
            replace_with_recoverable_pcm_caf(authorization, 960);
            let byte_length = fs::metadata(&authorization.absolute_path).unwrap().len();
            store
                .seal_segment(seal_receipt(authorization, byte_length))
                .unwrap();
        }

        let snapshot = store.runtime_library_snapshot().unwrap();

        assert!(snapshot.current_session.is_none());
        assert_eq!(snapshot.saved_sessions.len(), 1);
        let saved = &snapshot.saved_sessions[0];
        assert_eq!(saved.session_id, prepared.session_id);
        assert_eq!(saved.lifecycle, "ready_for_review");
        assert_eq!(saved.sources.len(), 2);
        assert!(
            saved
                .sources
                .iter()
                .all(|source| source.lifecycle == "sealed")
        );
        assert!(!saved.recovered);
    }
}
