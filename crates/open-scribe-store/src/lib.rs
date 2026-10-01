//! Native persistence and recovery boundary for Open Scribe.
//!
//! This crate owns the single SQLite writer and the independently durable
//! per-session recovery journal. It does not own media I/O and cannot authorize
//! `Recording`: a prepared session has durable intent but no open media.

#![forbid(unsafe_code)]

use std::collections::{BTreeMap, BTreeSet};
use std::ffi::OsStr;
use std::fmt;
#[cfg(test)]
use std::fs::OpenOptions;
use std::fs::{self, File};
use std::io::{BufRead, BufReader, Read, Seek, Write};
use std::os::fd::{AsFd, OwnedFd};
use std::path::{Component, Path, PathBuf};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use open_scribe_types::SessionId;
use rusqlite::{Connection, OpenFlags, Transaction, TransactionBehavior, params};
use rustix::fs as fd_fs;
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use uuid::Uuid;

mod context;
mod conversation_identity;
pub use context::{
    CONTEXT_EXCLUSIONS, CONTEXT_SCOPE_SCHEMA, ContextAction, ContextBounds, ContextCondition,
    ContextDetail, ContextFailureReason, ContextMode, ContextPauseReason, ContextRetention,
    ContextScope, ContextScopeRequest, ContextTarget, ContextTargetKind, DisplayTopology,
    ScreenPermission, SessionDeclaration,
};
mod context_events;
pub use context_events::{
    AcceptedContextEvent, CONTEXT_EVENT_SCHEMA, ContextDecision, ContextEventReason,
    ContextEventRecord, ContextProposal, ContextRejection, ContextSource, ContextTextBlock,
};
mod import;
mod journal_replacement;
mod library_recovery;
mod storage_reserve;
pub use library_recovery::LibraryRecovery;
mod media_recovery;
mod mixdown;
pub use mixdown::{MixdownAuthorization, MixdownReceipt, ValidatedMixdown};
mod package_restore;
pub use package_restore::{
    PackageRestoreReceipt, PackageRestoreRequest, RestoredMarker, RestoredSegment, RestoredTrack,
    RestoredTranscript, RestoredTranscriptSegment,
};
mod recorder;
pub use recorder::{RecorderAction, RecorderDetail, RecorderEvent};
mod runtime_snapshot;
mod segment_gaps;
mod session_deletion;
pub use session_deletion::{SessionDeletionInventory, SessionDeletionReceipt};
mod source_failure;
mod timeline;
pub use timeline::{CaptureClock, TimelineSegment};
mod transcript_input;
pub use transcript_input::{
    DigestedSegment, InputSegment, InputSpan, SealedTrackReader, TranscriptionInput,
    transcription_input_digest,
};
mod evidence_resolution;
pub use evidence_resolution::ResolvedEvidence;
mod session_inventory;
pub use session_inventory::{SessionInventory, SessionMarker, SessionMediaEntry, VerifiedMedia};
mod transcript_export;
pub use transcript_export::{SelectedRevisionProvenance, TranscriptExportContext};
mod transcript_review;
pub use transcript_review::{
    SessionSpeaker, SpeakerLabelOrigin, TranscriptDocumentSegment, TranscriptSearchHit,
};
mod transcripts;
pub use transcripts::{
    PlannedTranscriptChunk, RevisionSegmentInput, TRANSCRIPT_SCHEMA_VERSION, TranscriptChunk,
    TranscriptChunkState, TranscriptRevisionSummary, TranscriptSegmentView, TranscriptionFailure,
    TranscriptionRunHandle, TranscriptionRunIdentity, TranscriptionRunSummary,
};

use conversation_identity::validate_request;
pub use conversation_identity::{PrepareSessionRequest, PreparedSessionReceipt, SessionOrigin};
pub use import::{
    CompressedImportMetadata, ImportMediaRequest, ImportPolicy, ImportedMediaEvidence,
    ImportedPlaybackLease, OriginalImportMetadata, import_policy,
};
pub use runtime_snapshot::{
    RuntimeLibrarySnapshot, RuntimePlayableMediaAvailability, RuntimePlayableMediaSnapshot,
    RuntimeSessionSnapshot, RuntimeSourceSnapshot,
};
pub use source_failure::{SourceFailureEvidence, SourceFailureReason, SourceFailureRequest};

const SCHEMA_VERSION: i64 = 4;
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

    const fn capture_channels(self) -> u16 {
        match self {
            Self::Microphone => 1,
            Self::ApplicationAudio | Self::SystemAudio => 2,
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
    /// The last capture source lost its operating-system permission.
    PermissionRevoked,
}

impl SessionInterruptionReason {
    const fn as_str(self) -> &'static str {
        match self {
            Self::CaptureStartFailed => "capture_start_failed",
            Self::CaptureFailed => "capture_failed",
            Self::FirstSampleRejected => "first_sample_rejected",
            Self::StopWithoutDurableSample => "stop_without_durable_sample",
            Self::SegmentSealFailed => "segment_seal_failed",
            Self::PermissionRevoked => "permission_revoked",
        }
    }

    fn from_str(value: &str) -> Result<Self, StoreError> {
        match value {
            "capture_start_failed" => Ok(Self::CaptureStartFailed),
            "capture_failed" => Ok(Self::CaptureFailed),
            "first_sample_rejected" => Ok(Self::FirstSampleRejected),
            "stop_without_durable_sample" => Ok(Self::StopWithoutDurableSample),
            "segment_seal_failed" => Ok(Self::SegmentSealFailed),
            "permission_revoked" => Ok(Self::PermissionRevoked),
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
    pub source_id: String,
    pub track_id: String,
    pub source_kind: MediaSourceKind,
    pub source_display_name: String,
    pub segment_id: String,
    pub relative_path: String,
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
    ImportedMediaReady,
    ImportProjectionRepaired,
    ImportFailed,
    SourceFailedRecording,
    SourceFailureProjectionRepaired,
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

#[derive(Clone, Copy, Eq, PartialEq)]
enum JournalReplacementFailurePoint {
    TemporaryWrite,
    TemporarySync,
    Rename,
    DirectorySync,
}

#[derive(Debug)]
pub enum StoreError {
    InvalidManagedRoot(&'static str),
    InvalidRequest(&'static str),
    ImportSizeLimit,
    ImportDurationLimit,
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
            Self::ImportSizeLimit => write!(formatter, "import source exceeds the size limit"),
            Self::ImportDurationLimit => {
                write!(formatter, "import source exceeds the duration limit")
            }
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
    channels: u16,
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
    file: File,
    byte_length: u64,
    device: u64,
    inode: u64,
    digest_sha256: Option<String>,
    recoverable_sample_count: Option<u64>,
    channels: Option<u16>,
}

struct CafInspection {
    channels: u16,
    sample_count: Option<u64>,
    /// Byte offset of the first interleaved frame.
    audio_offset: u64,
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
    digest_memo: std::cell::RefCell<library_recovery::DigestMemo>,
}

impl SessionStore {
    /// Opens or creates the managed root, configures SQLite, and applies schema v1.
    pub fn open(managed_root: impl AsRef<Path>) -> Result<Self, StoreError> {
        let managed_root = managed_root.as_ref().to_path_buf();
        validate_or_create_managed_root(&managed_root)?;
        import::cleanup_stale_playback_snapshot_placeholders(&managed_root)?;

        let sessions_root = managed_root.join(SESSIONS_DIRECTORY);
        create_directory_if_missing(&sessions_root)?;
        reconcile_stale_journal_replacements(&sessions_root)?;

        let database_path = managed_root.join(DATABASE_NAME);
        let flags = OpenFlags::SQLITE_OPEN_READ_WRITE
            | OpenFlags::SQLITE_OPEN_CREATE
            | OpenFlags::SQLITE_OPEN_NO_MUTEX;
        let mut connection = Connection::open_with_flags(database_path, flags)?;
        configure_connection(&mut connection)?;
        apply_schema(&mut connection)?;

        Ok(Self {
            managed_root,
            sessions_root,
            connection,
            digest_memo: std::cell::RefCell::default(),
        })
    }

    #[must_use]
    pub fn managed_root(&self) -> &Path {
        &self.managed_root
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
            if matches!(lifecycle.as_str(), "preparing" | "recording" | "finalizing") {
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
        if !matches!(lifecycle.as_str(), "preparing" | "recording" | "finalizing") {
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

    /// Validates every sealed segment against its accepted evidence and returns
    /// the source kinds they cover. Each file closes once checked: a long session
    /// holds more segments than a process may keep open, and every later lease
    /// re-validates the same evidence.
    fn validate_sealed_recovery_companions(
        &self,
        session_id: &str,
        records: &[JournalRecord],
    ) -> Result<BTreeSet<String>, StoreError> {
        let rows = {
            let mut statement = self.connection.prepare(
                "SELECT sources.kind, sources.id, tracks.id, segments.id,
                        segments.relative_path, segments.sample_count,
                        segments.byte_length, segments.digest,
                        segments.file_device, segments.file_inode,
                        segments.seal_state, segments.open_token,
                        segments.writer_generation, segments.channels
                 FROM sources
                 JOIN tracks ON tracks.session_id = sources.session_id
                            AND tracks.source_id = sources.id
                 JOIN segments ON segments.session_id = sources.session_id
                              AND segments.track_id = tracks.id
                 WHERE sources.session_id = ?1
                   AND segments.lifecycle = 'sealed'
                 ORDER BY sources.kind, segments.sequence, segments.id",
            )?;
            let mapped = statement.query_map([session_id], |row| {
                Ok((
                    row.get::<_, String>(0)?,
                    row.get::<_, String>(1)?,
                    row.get::<_, String>(2)?,
                    row.get::<_, String>(3)?,
                    row.get::<_, String>(4)?,
                    row.get::<_, i64>(5)? as u64,
                    row.get::<_, i64>(6)? as u64,
                    row.get::<_, String>(7)?,
                    row.get::<_, i64>(8)? as u64,
                    row.get::<_, i64>(9)? as u64,
                    row.get::<_, String>(10)?,
                    row.get::<_, Option<String>>(11)?,
                    row.get::<_, i64>(12)? as u64,
                    row.get::<_, i64>(13)? as u16,
                ))
            })?;
            mapped.collect::<Result<Vec<_>, _>>()?
        };

        let mut source_kinds = BTreeSet::new();
        for (
            source_kind,
            source_id,
            track_id,
            segment_id,
            relative_path,
            sample_count,
            byte_length,
            digest_sha256,
            file_device,
            file_inode,
            seal_state,
            open_token,
            writer_generation,
            channels,
        ) in rows
        {
            MediaSourceKind::from_str(&source_kind)?;
            if seal_state != "sealed" {
                return Err(StoreError::IntegrityMismatch(
                    "sealed recovery companion lacks accepted seal state",
                ));
            }
            let accepted = journal_record_for_segment(records, "segment_sealed", &segment_id)?
                .or(journal_record_for_segment(
                    records,
                    "playable_media_recovered",
                    &segment_id,
                )?)
                .ok_or(StoreError::IntegrityMismatch(
                    "sealed recovery companion lacks accepted journal evidence",
                ))?;
            let payload = &accepted.body.payload;
            if accepted.body.relative_path.as_deref() != Some(relative_path.as_str())
                || payload_string(payload, "source_id")? != source_id.as_str()
                || payload_string(payload, "track_id")? != track_id.as_str()
                || payload_string(payload, "segment_id")? != segment_id.as_str()
                || payload_string(payload, "relative_path")? != relative_path.as_str()
                || payload_u64(payload, "sample_count")? != sample_count
                || payload_u64(payload, "final_byte_length")? != byte_length
                || payload_string(payload, "digest_sha256")? != digest_sha256.as_str()
                || payload_u64(payload, "file_device")? != file_device
                || payload_u64(payload, "file_inode")? != file_inode
            {
                return Err(StoreError::IntegrityMismatch(
                    "sealed recovery companion changed accepted evidence",
                ));
            }
            match accepted.body.event_kind.as_str() {
                "segment_sealed" => {
                    if payload_string(payload, "open_token")? != open_token.as_deref().unwrap_or("")
                        || payload_u64(payload, "writer_generation")? != writer_generation
                        || payload_u64(payload, "final_sample_host_time")? == 0
                    {
                        return Err(StoreError::IntegrityMismatch(
                            "sealed recovery companion changed writer evidence",
                        ));
                    }
                }
                "playable_media_recovered" => {
                    if payload_u64(payload, "truncated_bytes")? != 0 {
                        return Err(StoreError::IntegrityMismatch(
                            "sealed recovery companion changed recovery evidence",
                        ));
                    }
                }
                _ => {
                    return Err(StoreError::IntegrityMismatch(
                        "sealed recovery companion has unsupported journal evidence",
                    ));
                }
            }
            let validated = self.validate_media_file(
                session_id,
                &relative_path,
                MediaLengthRequirement::Exact(byte_length),
                true,
            )?;
            if validated.device != file_device
                || validated.inode != file_inode
                || validated.recoverable_sample_count != Some(sample_count)
                || validated.channels != Some(channels)
                || validated.digest_sha256.as_deref() != Some(digest_sha256.as_str())
            {
                return Err(StoreError::IntegrityMismatch(
                    "sealed recovery companion changed after acceptance",
                ));
            }
            source_kinds.insert(source_kind);
        }
        Ok(source_kinds)
    }

    /// Every reviewable recovered segment with its own validation result, so
    /// launch recovery can set one damaged session aside from the rest.
    fn recovered_playable_rows(
        &self,
    ) -> Result<Vec<library_recovery::RecoveredPlayableRow>, StoreError> {
        let rows = {
            let mut statement = self.connection.prepare(&format!(
                "SELECT sessions.id, sources.id, tracks.id, sources.kind,
                        sources.display_name, segments.id, segments.relative_path,
                        segments.sample_count, segments.byte_length, segments.digest,
                        segments.file_device, segments.file_inode,
                        MAX(session_events.sequence), segments.channels
                 FROM sessions
                 JOIN segments ON segments.session_id = sessions.id
                 JOIN tracks ON tracks.id = segments.track_id
                            AND tracks.session_id = segments.session_id
                 JOIN sources ON sources.id = tracks.source_id
                             AND sources.session_id = tracks.session_id
                 JOIN session_events ON session_events.session_id = sessions.id
                 WHERE sessions.lifecycle = 'ready_for_review'
                   AND segments.lifecycle = 'sealed'
                   AND {}
                 GROUP BY sessions.id, segments.id
                 ORDER BY sessions.updated_at_ms DESC, sources.kind,
                          segments.sequence, segments.id",
                library_recovery::RECOVERED_SESSION_EVIDENCE_SQL
            ))?;
            let mapped = statement.query_map([], |row| {
                Ok((
                    row.get::<_, String>(0)?,
                    row.get::<_, String>(1)?,
                    row.get::<_, String>(2)?,
                    row.get::<_, String>(3)?,
                    row.get::<_, String>(4)?,
                    row.get::<_, String>(5)?,
                    row.get::<_, String>(6)?,
                    row.get::<_, i64>(7)? as u64,
                    row.get::<_, i64>(8)? as u64,
                    row.get::<_, String>(9)?,
                    row.get::<_, i64>(10)? as u64,
                    row.get::<_, i64>(11)? as u64,
                    row.get::<_, i64>(12)? as u64,
                    row.get::<_, i64>(13)? as u16,
                ))
            })?;
            mapped.collect::<Result<Vec<_>, _>>()?
        };

        Ok(rows
            .into_iter()
            .map(
                |(
                    session_id,
                    source_id,
                    track_id,
                    source_kind,
                    source_display_name,
                    segment_id,
                    relative_path,
                    sample_count,
                    byte_length,
                    digest_sha256,
                    file_device,
                    file_inode,
                    last_journal_sequence,
                    channels,
                )| {
                    let session = session_id.clone();
                    let row = (move || -> Result<RecoveredPlayableSession, StoreError> {
                        let validated = self.validate_media_file(
                            &session_id,
                            &relative_path,
                            MediaLengthRequirement::Exact(byte_length),
                            true,
                        )?;
                        if validated.device != file_device
                            || validated.inode != file_inode
                            || validated.recoverable_sample_count != Some(sample_count)
                            || validated.channels != Some(channels)
                            || validated.digest_sha256.as_deref() != Some(digest_sha256.as_str())
                        {
                            return Err(StoreError::IntegrityMismatch(
                                "recovered playable media changed after acceptance",
                            ));
                        }
                        Ok(RecoveredPlayableSession {
                            session_id: SessionId(session_id.clone()),
                            source_id,
                            track_id,
                            source_kind: MediaSourceKind::from_str(&source_kind)?,
                            source_display_name,
                            segment_id,
                            relative_path: relative_path.clone(),
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
                    })();
                    (session, row)
                },
            )
            .collect())
    }

    fn authorize_media_open_inner(
        &mut self,
        request: AuthorizeMediaOpenRequest,
        failure: Option<MediaFailurePoint>,
    ) -> Result<MediaOpenAuthorization, StoreError> {
        self.require_storage_headroom(&request.session_id.0)?;
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
        let channels = request.source_kind.capture_channels();
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
            channels,
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
        let (session_lifecycle, journal_durable, media_files_open): (String, bool, bool) =
            self.connection.query_row(
                "SELECT lifecycle, journal_durable, media_files_open
                 FROM sessions WHERE id = ?1",
                [&stored.session_id],
                |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?)),
            )?;
        if !matches!(
            session_lifecycle.as_str(),
            "preparing" | "recording" | "finalizing"
        ) || !journal_durable
            || !media_files_open
        {
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
        self.project_first_sample(&receipt.session_id.0, &payload, &journal_record)?;
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

    /// The required-source plan for the current capture span. A source that
    /// failed during Recording leaves the plan for later spans; its captured
    /// media stays journaled and playable.
    fn required_source_kinds(&self, session_id: &str) -> Result<Vec<MediaSourceKind>, StoreError> {
        let mut statement = self.connection.prepare(
            "SELECT kind FROM required_sources
             WHERE session_id = ?1 AND lifecycle != 'failed' ORDER BY kind",
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
            session_nanoseconds: payload
                .get("session_nanoseconds")
                .or_else(|| payload.get("first_sample_session_nanoseconds"))
                .and_then(Value::as_i64)
                .unwrap_or(0),
            wall_time_milliseconds: wall_time_milliseconds(),
            relative_path: relative_path.map(str::to_owned),
            payload,
            prior_digest: Some(previous.record_digest.clone()),
        };
        let record = JournalRecord {
            record_digest: digest_json(&body)?,
            body,
        };
        atomic_replace_journal_with_record(&journal_path, &session_directory, &record, None)?;
        Ok(record)
    }

    /// Appends records in one journal replacement, chained in order. Only for
    /// a session no other writer can reach until the batch is projected.
    fn append_session_journal_batch(
        &self,
        session_id: &str,
        entries: Vec<(&str, Option<String>, Value)>,
    ) -> Result<Vec<JournalRecord>, StoreError> {
        let session_directory = self.session_directory(session_id)?;
        let journal_path = session_directory.join(JOURNAL_NAME);
        let mut previous = match validate_journal(&journal_path, session_id)? {
            JournalValidation::Valid(mut records) if !records.is_empty() => {
                records.pop().expect("validated non-empty journal")
            }
            _ => {
                return Err(StoreError::IntegrityMismatch(
                    "session journal is not a valid append target",
                ));
            }
        };
        let mut records = Vec::with_capacity(entries.len());
        for (event_kind, relative_path, payload) in entries {
            let body = JournalBody {
                version: JOURNAL_VERSION,
                sequence: previous.body.sequence + 1,
                event_id: Uuid::now_v7().to_string(),
                session_id: session_id.to_owned(),
                event_kind: event_kind.to_owned(),
                session_nanoseconds: payload
                    .get("session_nanoseconds")
                    .and_then(Value::as_i64)
                    .unwrap_or(0),
                wall_time_milliseconds: wall_time_milliseconds(),
                relative_path,
                payload,
                prior_digest: Some(previous.record_digest.clone()),
            };
            let record = JournalRecord {
                record_digest: digest_json(&body)?,
                body,
            };
            previous = record.clone();
            records.push(record);
        }
        atomic_replace_journal_with_records(&journal_path, &session_directory, &records, None)?;
        Ok(records)
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
        let channels = payload_u64(payload, "channels")?;
        if channels != 1 && channels != 2 {
            return Err(StoreError::IntegrityMismatch(
                "unsupported source channel layout",
            ));
        }
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
                lifecycle, original_start, mapped_start_ns, media_format, channels,
                sample_count, byte_length, digest, seal_state, recovery_state,
                open_token, writer_generation, file_device, file_inode
             ) VALUES (?1, ?2, ?3, ?4, ?10, ?5, 'opening', NULL, ?6, ?7, ?11,
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
                payload
                    .get("segment_sequence")
                    .and_then(Value::as_i64)
                    .unwrap_or(0),
                channels as i64,
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
            "UPDATE sources SET lifecycle = 'open' WHERE session_id = ?1 AND lifecycle = 'opening'
             AND id = (SELECT source_id FROM tracks WHERE id = (SELECT track_id FROM segments WHERE id = ?2))",
            params![session_id, segment_id],
        )?;
        transaction.execute(
            "UPDATE tracks SET lifecycle = 'open' WHERE session_id = ?1 AND lifecycle = 'opening'
             AND id = (SELECT track_id FROM segments WHERE id = ?2)",
            params![session_id, segment_id],
        )?;
        transaction.execute(
            "UPDATE required_sources SET lifecycle = 'open'
             WHERE session_id = ?1 AND lifecycle != 'capturing'
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
                  AND required.lifecycle != 'failed'
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
                 mapped_start_ns = ?4, sample_count = NULL
             WHERE id = ?1 AND session_id = ?3 AND lifecycle = 'open'",
            params![
                segment_id,
                first_sample_host_time as i64,
                session_id,
                payload_i64(payload, "first_sample_session_nanoseconds")?
            ],
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
        let continuing: bool = transaction.query_row(
            "SELECT EXISTS(SELECT 1 FROM segments WHERE track_id = ?1 AND lifecycle IN ('opening', 'open', 'capturing'))",
            [track_id], |row| row.get(0),
        )?;
        if !continuing {
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
        }
        if payload
            .get("measured_drift_nanoseconds")
            .and_then(Value::as_i64)
            .is_some_and(|drift| drift.unsigned_abs() > 50_000_000)
        {
            transaction.execute(
                "UPDATE sessions SET health = 'degraded' WHERE id = ?1",
                [session_id],
            )?;
        }
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
             WHERE id = ?1 AND lifecycle IN ('preparing', 'recording', 'finalizing')",
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
             WHERE id = ?1 AND lifecycle IN ('preparing', 'recording', 'finalizing')",
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
        playable_source_kinds: &BTreeSet<String>,
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
        let incomplete_sources = {
            let mut statement = transaction
                .prepare("SELECT kind, lifecycle FROM required_sources WHERE session_id = ?1")?;
            let rows = statement.query_map([session_id], |row| {
                Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?))
            })?;
            rows.collect::<Result<Vec<_>, _>>()?
                .into_iter()
                .filter(|(kind, lifecycle)| {
                    lifecycle != "sealed" && !playable_source_kinds.contains(kind)
                })
                .count()
        };
        if incomplete_segments != 0 || incomplete_sources != 0 {
            return Err(StoreError::InvalidState(
                "session recovery is missing a required playable source",
            ));
        }
        let session_changed = transaction.execute(
            "UPDATE sessions
             SET lifecycle = 'ready_for_review',
                 health = CASE
                     WHEN lifecycle = 'interrupted' OR health = 'degraded' THEN 'degraded'
                     ELSE health
                 END,
                 media_files_open = 0,
                 updated_at_ms = ?2
             WHERE id = ?1 AND lifecycle IN (
                       'preparing', 'recording', 'finalizing', 'interrupted', 'ready_for_review'
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
                        segments.relative_path, segments.media_format, segments.channels, segments.lifecycle,
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
                        channels: row.get::<_, i64>(5)? as u16,
                        lifecycle: row.get(6)?,
                        open_token: row.get(7)?,
                        writer_generation: row.get::<_, i64>(8)? as u64,
                        byte_length: row.get::<_, Option<i64>>(9)?.map(|value| value as u64),
                        file_device: row.get::<_, Option<i64>>(10)?.map(|value| value as u64),
                        file_inode: row.get::<_, Option<i64>>(11)?.map(|value| value as u64),
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
        let media_identity = (stat.st_dev as u64, stat.st_ino as u64, byte_length);
        let digest_sha256 = if !calculate_digest {
            None
        } else if let Some(known) = self.digest_memo.borrow().recall(media_identity) {
            Some(known)
        } else {
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
            let digest = format!("{:x}", hasher.finalize());
            self.digest_memo
                .borrow_mut()
                .record(media_identity, &digest);
            Some(digest)
        };
        file.rewind()?;
        let inspection = inspect_pcm_caf(&mut file, byte_length)?;
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
            file,
            byte_length,
            device: stat.st_dev as u64,
            inode: stat.st_ino as u64,
            digest_sha256,
            recoverable_sample_count: inspection.as_ref().and_then(|value| value.sample_count),
            channels: inspection.map(|value| value.channels),
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
                 WHERE lifecycle IN ('preparing', 'recording', 'paused', 'finalizing', 'interrupted') ORDER BY id",
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
        {
            // Reviewed and deleted sessions keep their directories; a directory
            // is an orphan only when no session row names it.
            let mut statement = self.connection.prepare("SELECT id FROM sessions")?;
            for id in statement.query_map([], |row| row.get::<_, String>(0))? {
                directory_sessions.remove(&id?);
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
                    let disposition = match self.recover_journaled_session(
                        &session_id,
                        journal_durable,
                        &records,
                    ) {
                        Ok(disposition) => disposition,
                        Err(error) => library_recovery::isolated_disposition(error)?,
                    };
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
        if interruptions.len() != 1
            || !library_recovery::recovery_records_only(
                &records[interruptions[0].body.sequence as usize..],
            )
        {
            return Ok(RecoveryDisposition::IntegrityMismatch);
        }
        let interruption = interruptions[0];
        SessionInterruptionReason::from_str(payload_string(&interruption.body.payload, "reason")?)?;
        let lifecycle: String = self.connection.query_row(
            "SELECT lifecycle FROM sessions WHERE id = ?1",
            [session_id],
            |row| row.get(0),
        )?;
        if matches!(lifecycle.as_str(), "preparing" | "recording" | "finalizing") {
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
            | RecoveryDisposition::SegmentSealProjectionRepaired
            | RecoveryDisposition::SourceFailedRecording
            | RecoveryDisposition::SourceFailureProjectionRepaired => {
                RecoveryDisposition::InterruptedSegmentSealed
            }
            other => other,
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

fn configure_connection(connection: &mut Connection) -> Result<(), StoreError> {
    connection.busy_timeout(Duration::from_secs(5))?;
    // A deferred transaction that reads and then writes fails at once, without
    // the busy timeout, when another store (a playback lease, the launch scan)
    // holds the WAL write lock. Taking it at BEGIN lets every writer wait.
    connection.set_transaction_behavior(TransactionBehavior::Immediate);
    connection.pragma_update(None, "foreign_keys", true)?;
    // Deleted rows are overwritten in place so session deletion leaves no
    // recoverable text in freed database pages.
    connection.pragma_update(None, "secure_delete", true)?;
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
            channels INTEGER NOT NULL DEFAULT 1 CHECK (channels IN (1, 2)),
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
        (
            "channels",
            "INTEGER NOT NULL DEFAULT 1 CHECK (channels IN (1, 2))",
        ),
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
    transaction.execute(
        "INSERT OR IGNORE INTO schema_migrations (version, applied_at_ms) VALUES (4, ?1)",
        [applied_at],
    )?;
    transcripts::apply_transcript_schema(&transaction)?;
    transaction.execute(
        "INSERT OR IGNORE INTO schema_migrations (version, applied_at_ms) VALUES (?1, ?2)",
        params![transcripts::TRANSCRIPT_MIGRATION_VERSION, applied_at],
    )?;
    transcript_review::apply_review_schema(&transaction)?;
    transaction.execute(
        "INSERT OR IGNORE INTO schema_migrations (version, applied_at_ms) VALUES (?1, ?2)",
        params![transcript_review::REVIEW_MIGRATION_VERSION, applied_at],
    )?;
    session_deletion::apply_deletion_schema(&transaction)?;
    transaction.execute(
        "INSERT OR IGNORE INTO schema_migrations (version, applied_at_ms) VALUES (?1, ?2)",
        params![session_deletion::DELETION_MIGRATION_VERSION, applied_at],
    )?;
    context::apply_context_schema(&transaction)?;
    transaction.execute(
        "INSERT OR IGNORE INTO schema_migrations (version, applied_at_ms) VALUES (?1, ?2)",
        params![context::CONTEXT_MIGRATION_VERSION, applied_at],
    )?;
    package_restore::apply_restore_schema(&transaction)?;
    transaction.execute(
        "INSERT OR IGNORE INTO schema_migrations (version, applied_at_ms) VALUES (?1, ?2)",
        params![package_restore::RESTORE_MIGRATION_VERSION, applied_at],
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
         ) VALUES (?1, ?2, ?3, ?4, ?5, ?10, ?6, ?7, ?8, ?9)",
        params![
            event_id,
            SCHEMA_VERSION,
            session_id,
            sequence as i64,
            event_kind,
            wall_time_ms,
            serde_json::to_string(payload)?,
            prior_digest,
            digest,
            payload
                .get("session_nanoseconds")
                .or_else(|| payload.get("first_sample_session_nanoseconds"))
                .and_then(Value::as_i64)
                .unwrap_or(0)
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

fn atomic_replace_journal_with_record(
    journal_path: &Path,
    session_directory: &Path,
    record: &JournalRecord,
    failure: Option<JournalReplacementFailurePoint>,
) -> Result<(), StoreError> {
    atomic_replace_journal_with_records(
        journal_path,
        session_directory,
        std::slice::from_ref(record),
        failure,
    )
}

fn atomic_replace_journal_with_records(
    journal_path: &Path,
    session_directory: &Path,
    records: &[JournalRecord],
    failure: Option<JournalReplacementFailurePoint>,
) -> Result<(), StoreError> {
    let metadata = fs::symlink_metadata(journal_path)?;
    if metadata.file_type().is_symlink() || !metadata.is_file() {
        return Err(StoreError::IntegrityMismatch(
            "session journal is not a regular append target",
        ));
    }
    let existing = fs::read(journal_path)?;
    if existing.is_empty() || !existing.ends_with(b"\n") {
        return Err(StoreError::IntegrityMismatch(
            "session journal is not a complete append target",
        ));
    }
    let temporary_name = format!(".open-scribe-journal-{}.tmp", Uuid::now_v7());
    let _live = journal_replacement::LiveReplacement::begin(temporary_name.clone());
    let temporary_path = session_directory.join(&temporary_name);
    let result = (|| {
        let mut temporary = journal_replacement::create_temporary(&temporary_path)?;
        temporary.write_all(&existing)?;
        for record in records {
            append_journal_record(&mut temporary, record)?;
        }
        interrupt_journal_replace_if(failure, JournalReplacementFailurePoint::TemporaryWrite)?;
        temporary.sync_all()?;
        interrupt_journal_replace_if(failure, JournalReplacementFailurePoint::TemporarySync)?;
        fs::rename(&temporary_path, journal_path)?;
        interrupt_journal_replace_if(failure, JournalReplacementFailurePoint::Rename)?;
        sync_directory(session_directory)?;
        interrupt_journal_replace_if(failure, JournalReplacementFailurePoint::DirectorySync)?;
        Ok(())
    })();
    if result.is_err() {
        let _ = fs::remove_file(&temporary_path);
    }
    result
}

fn interrupt_journal_replace_if(
    actual: Option<JournalReplacementFailurePoint>,
    expected: JournalReplacementFailurePoint,
) -> Result<(), StoreError> {
    if actual == Some(expected) {
        Err(StoreError::InjectedInterruption)
    } else {
        Ok(())
    }
}

fn inspect_pcm_caf(file: &mut File, byte_length: u64) -> Result<Option<CafInspection>, StoreError> {
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

fn reconcile_stale_journal_replacements(sessions_root: &Path) -> Result<(), StoreError> {
    struct ReconciliationPlan {
        session_directory: PathBuf,
        journal_path: PathBuf,
        adoption: Option<PathBuf>,
        discard: Vec<PathBuf>,
    }

    let mut plans = Vec::new();
    for session_entry in fs::read_dir(sessions_root)? {
        let session_entry = session_entry?;
        let session_metadata = session_entry.metadata()?;
        if !session_metadata.is_dir() || session_entry.file_type()?.is_symlink() {
            continue;
        }
        let session_id = session_entry.file_name().to_string_lossy().into_owned();
        if Uuid::parse_str(&session_id).is_err() {
            continue;
        }
        let session_directory = session_entry.path();
        let mut candidates = Vec::new();
        for candidate_entry in fs::read_dir(&session_directory)? {
            let candidate_entry = candidate_entry?;
            let candidate_name = candidate_entry.file_name().to_string_lossy().into_owned();
            let Some(candidate_id) = candidate_name
                .strip_prefix(".open-scribe-journal-")
                .and_then(|value| value.strip_suffix(".tmp"))
            else {
                continue;
            };
            if Uuid::parse_str(candidate_id).is_err()
                || journal_replacement::is_live(&candidate_name)
            {
                continue;
            }
            let candidate_path = candidate_entry.path();
            // A replacement that vanished since the listing was renamed or
            // removed by the append (or sweep) that owned it.
            let candidate_metadata = match fs::symlink_metadata(&candidate_path) {
                Ok(metadata) => metadata,
                Err(error) if error.kind() == std::io::ErrorKind::NotFound => continue,
                Err(error) => return Err(error.into()),
            };
            if candidate_metadata.file_type().is_symlink() || !candidate_metadata.is_file() {
                return Err(StoreError::IntegrityMismatch(
                    "stale journal replacement is not a regular file",
                ));
            }
            candidates.push(candidate_path);
        }
        if candidates.is_empty() {
            continue;
        }

        let journal_path = session_directory.join(JOURNAL_NAME);
        let authoritative = match validate_journal(&journal_path, &session_id)? {
            JournalValidation::Valid(records) => records,
            _ => {
                return Err(StoreError::IntegrityMismatch(
                    "stale journal replacement has no valid authoritative journal",
                ));
            }
        };
        let mut strict_extensions = Vec::new();
        let mut discard = Vec::new();
        for candidate_path in candidates {
            let validation = match validate_journal(&candidate_path, &session_id) {
                Err(StoreError::Io(error)) if error.kind() == std::io::ErrorKind::NotFound => {
                    continue;
                }
                other => other?,
            };
            match validation {
                JournalValidation::Valid(candidate)
                    if journal_is_strict_extension(&authoritative, &candidate) =>
                {
                    strict_extensions.push(candidate_path);
                }
                JournalValidation::Truncated | JournalValidation::Malformed => {
                    discard.push(candidate_path);
                }
                JournalValidation::Valid(_)
                | JournalValidation::IntegrityMismatch
                | JournalValidation::UnsupportedVersion => {
                    return Err(StoreError::IntegrityMismatch(
                        "stale journal replacement diverges from authoritative history",
                    ));
                }
            }
        }
        if strict_extensions.len() > 1 {
            return Err(StoreError::IntegrityMismatch(
                "multiple valid journal replacements are ambiguous",
            ));
        }
        plans.push(ReconciliationPlan {
            session_directory,
            journal_path,
            adoption: strict_extensions.pop(),
            discard,
        });
    }

    for plan in plans {
        if let Some(adoption) = plan.adoption {
            journal_replacement::ignore_missing(fs::rename(adoption, &plan.journal_path))?;
            sync_directory(&plan.session_directory)?;
        }
        if !plan.discard.is_empty() {
            for candidate in plan.discard {
                journal_replacement::ignore_missing(fs::remove_file(candidate))?;
            }
            sync_directory(&plan.session_directory)?;
        }
    }
    Ok(())
}

fn journal_is_strict_extension(
    authoritative: &[JournalRecord],
    candidate: &[JournalRecord],
) -> bool {
    candidate.len() == authoritative.len() + 1
        && candidate.starts_with(authoritative)
        && candidate.last().is_some_and(|record| {
            record.body.prior_digest
                == authoritative
                    .last()
                    .map(|previous| previous.record_digest.clone())
        })
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

    fn write_synced_journal(path: &Path, records: &[JournalRecord]) {
        let mut file = OpenOptions::new()
            .create_new(true)
            .write(true)
            .open(path)
            .unwrap();
        for record in records {
            append_journal_record(&mut file, record).unwrap();
        }
        file.sync_all().unwrap();
    }

    #[test]
    fn schema_v4_applies_required_durability_settings_tables_and_media_columns() {
        let temp = TempDir::new().unwrap();
        let store = open_store(&temp);

        let journal_mode: String = store
            .connection
            .query_row("PRAGMA journal_mode", [], |row| row.get(0))
            .unwrap();
        assert_eq!(journal_mode, "wal");
        assert_eq!(database_value(&store, "PRAGMA synchronous"), 2);
        assert_eq!(database_value(&store, "PRAGMA foreign_keys"), 1);
        assert_eq!(database_value(&store, "PRAGMA secure_delete"), 1);

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
            "transcription_runs",
            "transcript_chunks",
            "transcript_revisions",
            "transcript_segments",
            "transcript_selections",
            "transcript_corrections",
            "speaker_adjudications",
            "transcript_search",
            "session_deletion_intents",
            "context_scopes",
            "context_events",
            "session_declarations",
            "session_restorations",
        ] {
            assert!(names.contains(required), "missing table {required}");
        }
        assert_eq!(
            database_value(&store, "SELECT MAX(version) FROM schema_migrations"),
            9
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
            "channels",
        ] {
            assert!(
                segment_columns.contains(required),
                "missing segment column {required}"
            );
        }
    }

    #[test]
    fn schema_v4_migrates_prior_mono_segments_without_changing_their_layout() {
        let temp = TempDir::new().unwrap();
        let mut store = open_store(&temp);
        let prepared = store.prepare_session(request()).unwrap();
        let authorization = store
            .authorize_media_open(AuthorizeMediaOpenRequest {
                session_id: prepared.session_id,
                source_kind: MediaSourceKind::Microphone,
                source_display_name: "Legacy microphone".to_owned(),
            })
            .unwrap();
        let database_path = store.managed_root().join(DATABASE_NAME);
        drop(store);
        let connection = Connection::open(&database_path).unwrap();
        connection
            .execute_batch("ALTER TABLE segments DROP COLUMN channels;")
            .unwrap();
        connection
            .execute("DELETE FROM schema_migrations WHERE version = 4", [])
            .unwrap();
        drop(connection);
        let store = SessionStore::open(temp.path().join("Open Scribe")).unwrap();
        let channels: i64 = store
            .connection
            .query_row(
                "SELECT channels FROM segments WHERE id = ?1",
                [&authorization.segment_id],
                |row| row.get(0),
            )
            .unwrap();
        assert_eq!(channels, 1);
        assert_eq!(
            database_value(&store, "SELECT MAX(version) FROM schema_migrations"),
            9
        );
    }

    #[test]
    fn preparation_is_durable_but_never_permits_recording() {
        let temp = TempDir::new().unwrap();
        let mut store = open_store(&temp);
        let receipt = store.prepare_session(request()).unwrap();

        assert!(Uuid::parse_str(&receipt.session_id.0).is_ok());
        assert_eq!(receipt.schema_version, 4);
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
    fn journal_replacement_interruption_never_exposes_a_torn_recovery_record() {
        for failure in [
            JournalReplacementFailurePoint::TemporaryWrite,
            JournalReplacementFailurePoint::TemporarySync,
            JournalReplacementFailurePoint::Rename,
            JournalReplacementFailurePoint::DirectorySync,
        ] {
            let temp = TempDir::new().unwrap();
            let mut store = open_store(&temp);
            let receipt = store.prepare_session(request()).unwrap();
            let session_directory = store.session_directory(&receipt.session_id.0).unwrap();
            let journal_path = session_directory.join(JOURNAL_NAME);
            let JournalValidation::Valid(records) =
                validate_journal(&journal_path, &receipt.session_id.0).unwrap()
            else {
                panic!("expected valid journal before recovery append");
            };
            let previous = records.last().unwrap();
            let body = JournalBody {
                version: JOURNAL_VERSION,
                sequence: previous.body.sequence + 1,
                event_id: Uuid::now_v7().to_string(),
                session_id: receipt.session_id.0.clone(),
                event_kind: "playable_media_recovered".to_owned(),
                session_nanoseconds: 0,
                wall_time_milliseconds: wall_time_milliseconds(),
                relative_path: Some("audio/recovery.caf".to_owned()),
                payload: json!({ "segment_id": Uuid::now_v7().to_string() }),
                prior_digest: Some(previous.record_digest.clone()),
            };
            let replacement = JournalRecord {
                record_digest: digest_json(&body).unwrap(),
                body,
            };

            assert!(matches!(
                atomic_replace_journal_with_record(
                    &journal_path,
                    &session_directory,
                    &replacement,
                    Some(failure),
                ),
                Err(StoreError::InjectedInterruption)
            ));
            let JournalValidation::Valid(restarted) =
                validate_journal(&journal_path, &receipt.session_id.0).unwrap()
            else {
                panic!("journal replacement exposed a torn recovery record");
            };
            let replacement_visible = matches!(
                failure,
                JournalReplacementFailurePoint::Rename
                    | JournalReplacementFailurePoint::DirectorySync
            );
            assert_eq!(
                restarted.len(),
                records.len() + usize::from(replacement_visible)
            );
            if replacement_visible {
                assert_eq!(
                    restarted.last().unwrap().body.event_kind,
                    "playable_media_recovered"
                );
            }
        }
    }

    #[test]
    fn store_open_reconciles_only_regular_uuid_scoped_journal_residue() {
        let temp = TempDir::new().unwrap();
        let managed_root = temp.path().join("Open Scribe");
        let mut store = SessionStore::open(&managed_root).unwrap();
        let receipt = store.prepare_session(request()).unwrap();
        let session_directory = store.session_directory(&receipt.session_id.0).unwrap();
        let stale = session_directory.join(format!(".open-scribe-journal-{}.tmp", Uuid::now_v7()));
        fs::write(&stale, b"partial replacement bytes").unwrap();
        drop(store);

        let reopened = SessionStore::open(&managed_root).unwrap();
        assert!(!stale.exists());
        assert!(matches!(
            validate_journal(
                &reopened
                    .session_directory(&receipt.session_id.0)
                    .unwrap()
                    .join(JOURNAL_NAME),
                &receipt.session_id.0,
            )
            .unwrap(),
            JournalValidation::Valid(_)
        ));
    }

    #[test]
    fn store_open_adopts_synced_source_failure_extension_before_projection_recovery() {
        let temp = TempDir::new().unwrap();
        let managed_root = temp.path().join("Open Scribe");
        let session_id;
        let stale;
        {
            let mut store = SessionStore::open(&managed_root).unwrap();
            let (prepared, _, system) = prepared_dual_first_samples(&mut store);
            session_id = prepared.session_id.clone();
            store.confirm_recording(session_id.clone()).unwrap();

            replace_with_recoverable_pcm_caf(&system, 960);
            let system_byte_length = fs::metadata(&system.absolute_path).unwrap().len();
            store
                .seal_segment(seal_receipt(&system, system_byte_length))
                .unwrap();

            let session_directory = store.session_directory(&session_id.0).unwrap();
            let journal_path = session_directory.join(JOURNAL_NAME);
            let JournalValidation::Valid(records) =
                validate_journal(&journal_path, &session_id.0).unwrap()
            else {
                panic!("expected valid journal before simulated process exit");
            };
            let previous = records.last().unwrap();
            let body = JournalBody {
                version: JOURNAL_VERSION,
                sequence: previous.body.sequence + 1,
                event_id: Uuid::now_v7().to_string(),
                session_id: session_id.0.clone(),
                event_kind: "source_failed".to_owned(),
                session_nanoseconds: 0,
                wall_time_milliseconds: wall_time_milliseconds(),
                relative_path: None,
                payload: json!({
                    "source_kind": "system_audio",
                    "reason": "capture_failed",
                    "recording_continues": true,
                }),
                prior_digest: Some(previous.record_digest.clone()),
            };
            let replacement = JournalRecord {
                record_digest: digest_json(&body).unwrap(),
                body,
            };
            stale = session_directory.join(format!(".open-scribe-journal-{}.tmp", Uuid::now_v7()));
            let mut temporary = OpenOptions::new()
                .create_new(true)
                .write(true)
                .open(&stale)
                .unwrap();
            temporary
                .write_all(&fs::read(&journal_path).unwrap())
                .unwrap();
            append_journal_record(&mut temporary, &replacement).unwrap();
            temporary.sync_all().unwrap();
        }

        let mut reopened = SessionStore::open(&managed_root).unwrap();
        assert!(!stale.exists());
        assert_eq!(
            reopened.recover_preparations().unwrap(),
            vec![RecoveryFinding {
                session_id: session_id.clone(),
                disposition: RecoveryDisposition::SourceFailureProjectionRepaired,
            }]
        );
        let current = reopened
            .runtime_library_snapshot()
            .unwrap()
            .current_session
            .unwrap();
        assert_eq!(current.lifecycle, "recording");
        assert_eq!(current.health, "degraded");
        assert_eq!(
            current
                .sources
                .iter()
                .find(|source| source.kind == MediaSourceKind::SystemAudio)
                .unwrap()
                .lifecycle,
            "failed"
        );
        assert_eq!(
            current
                .sources
                .iter()
                .find(|source| source.kind == MediaSourceKind::Microphone)
                .unwrap()
                .lifecycle,
            "capturing"
        );
        drop(reopened);

        let mut converged = SessionStore::open(&managed_root).unwrap();
        assert_eq!(
            converged.recover_preparations().unwrap(),
            vec![RecoveryFinding {
                session_id,
                disposition: RecoveryDisposition::SourceFailedRecording,
            }]
        );
    }

    #[test]
    fn store_open_preserves_valid_divergent_journal_replacement() {
        let temp = TempDir::new().unwrap();
        let managed_root = temp.path().join("Open Scribe");
        let mut store = SessionStore::open(&managed_root).unwrap();
        let receipt = store.prepare_session(request()).unwrap();
        let session_directory = store.session_directory(&receipt.session_id.0).unwrap();
        let journal_path = session_directory.join(JOURNAL_NAME);
        let JournalValidation::Valid(records) =
            validate_journal(&journal_path, &receipt.session_id.0).unwrap()
        else {
            panic!("expected valid authoritative journal");
        };
        let mut divergent = records.clone();
        let divergent_tail = divergent.last_mut().unwrap();
        divergent_tail.body.event_id = Uuid::now_v7().to_string();
        divergent_tail.record_digest = digest_json(&divergent_tail.body).unwrap();
        let stale = session_directory.join(format!(".open-scribe-journal-{}.tmp", Uuid::now_v7()));
        let mut temporary = OpenOptions::new()
            .create_new(true)
            .write(true)
            .open(&stale)
            .unwrap();
        for record in &divergent {
            append_journal_record(&mut temporary, record).unwrap();
        }
        temporary.sync_all().unwrap();
        drop(store);

        assert!(matches!(
            SessionStore::open(&managed_root),
            Err(StoreError::IntegrityMismatch(
                "stale journal replacement diverges from authoritative history"
            ))
        ));
        assert!(stale.is_file());
    }

    #[test]
    fn store_open_preserves_competing_valid_journal_extensions_without_adopting_either() {
        let temp = TempDir::new().unwrap();
        let managed_root = temp.path().join("Open Scribe");
        let mut store = SessionStore::open(&managed_root).unwrap();
        let receipt = store.prepare_session(request()).unwrap();
        let session_directory = store.session_directory(&receipt.session_id.0).unwrap();
        let journal_path = session_directory.join(JOURNAL_NAME);
        let authoritative_bytes = fs::read(&journal_path).unwrap();
        let JournalValidation::Valid(authoritative) =
            validate_journal(&journal_path, &receipt.session_id.0).unwrap()
        else {
            panic!("expected valid authoritative journal");
        };
        let previous = authoritative.last().unwrap();
        let mut residues = Vec::new();
        for reason in ["capture_failed", "permission_revoked"] {
            let body = JournalBody {
                version: JOURNAL_VERSION,
                sequence: previous.body.sequence + 1,
                event_id: Uuid::now_v7().to_string(),
                session_id: receipt.session_id.0.clone(),
                event_kind: "source_failed".to_owned(),
                session_nanoseconds: 0,
                wall_time_milliseconds: wall_time_milliseconds(),
                relative_path: None,
                payload: json!({
                    "source_kind": "system_audio",
                    "reason": reason,
                    "recording_continues": true,
                }),
                prior_digest: Some(previous.record_digest.clone()),
            };
            let mut candidate = authoritative.clone();
            candidate.push(JournalRecord {
                record_digest: digest_json(&body).unwrap(),
                body,
            });
            let residue =
                session_directory.join(format!(".open-scribe-journal-{}.tmp", Uuid::now_v7()));
            write_synced_journal(&residue, &candidate);
            residues.push(residue);
        }
        drop(store);

        assert!(matches!(
            SessionStore::open(&managed_root),
            Err(StoreError::IntegrityMismatch(
                "multiple valid journal replacements are ambiguous"
            ))
        ));
        assert_eq!(fs::read(&journal_path).unwrap(), authoritative_bytes);
        assert!(residues.iter().all(|path| path.is_file()));
    }

    #[test]
    fn store_open_preserves_valid_n_plus_one_and_n_plus_two_residue_chain() {
        let temp = TempDir::new().unwrap();
        let managed_root = temp.path().join("Open Scribe");
        let mut store = SessionStore::open(&managed_root).unwrap();
        let receipt = store.prepare_session(request()).unwrap();
        let session_directory = store.session_directory(&receipt.session_id.0).unwrap();
        let journal_path = session_directory.join(JOURNAL_NAME);
        let authoritative_bytes = fs::read(&journal_path).unwrap();
        let JournalValidation::Valid(authoritative) =
            validate_journal(&journal_path, &receipt.session_id.0).unwrap()
        else {
            panic!("expected valid authoritative journal");
        };
        let previous = authoritative.last().unwrap();
        let first_body = JournalBody {
            version: JOURNAL_VERSION,
            sequence: previous.body.sequence + 1,
            event_id: Uuid::now_v7().to_string(),
            session_id: receipt.session_id.0.clone(),
            event_kind: "source_failed".to_owned(),
            session_nanoseconds: 0,
            wall_time_milliseconds: wall_time_milliseconds(),
            relative_path: None,
            payload: json!({
                "source_kind": "system_audio",
                "reason": "capture_failed",
                "recording_continues": true,
            }),
            prior_digest: Some(previous.record_digest.clone()),
        };
        let first = JournalRecord {
            record_digest: digest_json(&first_body).unwrap(),
            body: first_body,
        };
        let second_body = JournalBody {
            version: JOURNAL_VERSION,
            sequence: first.body.sequence + 1,
            event_id: Uuid::now_v7().to_string(),
            session_id: receipt.session_id.0.clone(),
            event_kind: "session_interrupted".to_owned(),
            session_nanoseconds: 0,
            wall_time_milliseconds: wall_time_milliseconds(),
            relative_path: None,
            payload: json!({ "reason": "capture_failed" }),
            prior_digest: Some(first.record_digest.clone()),
        };
        let second = JournalRecord {
            record_digest: digest_json(&second_body).unwrap(),
            body: second_body,
        };
        let n_plus_one =
            session_directory.join(format!(".open-scribe-journal-{}.tmp", Uuid::now_v7()));
        let n_plus_two =
            session_directory.join(format!(".open-scribe-journal-{}.tmp", Uuid::now_v7()));
        let mut first_candidate = authoritative.clone();
        first_candidate.push(first.clone());
        write_synced_journal(&n_plus_one, &first_candidate);
        first_candidate.push(second);
        write_synced_journal(&n_plus_two, &first_candidate);
        drop(store);

        assert!(matches!(
            SessionStore::open(&managed_root),
            Err(StoreError::IntegrityMismatch(
                "stale journal replacement diverges from authoritative history"
            ))
        ));
        assert_eq!(fs::read(&journal_path).unwrap(), authoritative_bytes);
        assert!(n_plus_one.is_file());
        assert!(n_plus_two.is_file());
    }

    #[test]
    fn store_open_withholds_all_reconciliation_when_any_session_fails_admission() {
        let temp = TempDir::new().unwrap();
        let managed_root = temp.path().join("Open Scribe");
        let mut store = SessionStore::open(&managed_root).unwrap();

        let adoptable = store.prepare_session(request()).unwrap();
        let adoptable_directory = store.session_directory(&adoptable.session_id.0).unwrap();
        let adoptable_journal = adoptable_directory.join(JOURNAL_NAME);
        let adoptable_bytes = fs::read(&adoptable_journal).unwrap();
        let JournalValidation::Valid(mut adoptable_records) =
            validate_journal(&adoptable_journal, &adoptable.session_id.0).unwrap()
        else {
            panic!("expected valid adoptable journal");
        };
        let previous = adoptable_records.last().unwrap();
        let body = JournalBody {
            version: JOURNAL_VERSION,
            sequence: previous.body.sequence + 1,
            event_id: Uuid::now_v7().to_string(),
            session_id: adoptable.session_id.0.clone(),
            event_kind: "session_interrupted".to_owned(),
            session_nanoseconds: 0,
            wall_time_milliseconds: wall_time_milliseconds(),
            relative_path: None,
            payload: json!({ "reason": "capture_failed" }),
            prior_digest: Some(previous.record_digest.clone()),
        };
        adoptable_records.push(JournalRecord {
            record_digest: digest_json(&body).unwrap(),
            body,
        });
        let adoptable_residue =
            adoptable_directory.join(format!(".open-scribe-journal-{}.tmp", Uuid::now_v7()));
        write_synced_journal(&adoptable_residue, &adoptable_records);

        let disposable = store.prepare_session(request()).unwrap();
        let disposable_directory = store.session_directory(&disposable.session_id.0).unwrap();
        let disposable_residue =
            disposable_directory.join(format!(".open-scribe-journal-{}.tmp", Uuid::now_v7()));
        fs::write(&disposable_residue, b"partial replacement bytes").unwrap();

        let rejected = store.prepare_session(request()).unwrap();
        let rejected_directory = store.session_directory(&rejected.session_id.0).unwrap();
        let rejected_residue =
            rejected_directory.join(format!(".open-scribe-journal-{}.tmp", Uuid::now_v7()));
        fs::create_dir(&rejected_residue).unwrap();
        drop(store);

        assert!(matches!(
            SessionStore::open(&managed_root),
            Err(StoreError::IntegrityMismatch(
                "stale journal replacement is not a regular file"
            ))
        ));
        assert_eq!(fs::read(&adoptable_journal).unwrap(), adoptable_bytes);
        assert!(adoptable_residue.is_file());
        assert!(disposable_residue.is_file());
        assert!(rejected_residue.is_dir());
    }

    #[test]
    fn store_open_preserves_integrity_mismatch_and_unsupported_version_residue() {
        fn integrity_mismatch(mut records: Vec<JournalRecord>) -> Vec<JournalRecord> {
            records.last_mut().unwrap().record_digest = "not-the-body-digest".to_owned();
            records
        }
        fn unsupported_version(mut records: Vec<JournalRecord>) -> Vec<JournalRecord> {
            let tail = records.last_mut().unwrap();
            tail.body.version = JOURNAL_VERSION + 1;
            tail.record_digest = digest_json(&tail.body).unwrap();
            records
        }

        for mutation in [
            integrity_mismatch as fn(Vec<JournalRecord>) -> Vec<JournalRecord>,
            unsupported_version,
        ] {
            let temp = TempDir::new().unwrap();
            let managed_root = temp.path().join("Open Scribe");
            let mut store = SessionStore::open(&managed_root).unwrap();
            let receipt = store.prepare_session(request()).unwrap();
            let session_directory = store.session_directory(&receipt.session_id.0).unwrap();
            let journal_path = session_directory.join(JOURNAL_NAME);
            let JournalValidation::Valid(records) =
                validate_journal(&journal_path, &receipt.session_id.0).unwrap()
            else {
                panic!("expected valid authoritative journal");
            };
            let residue =
                session_directory.join(format!(".open-scribe-journal-{}.tmp", Uuid::now_v7()));
            write_synced_journal(&residue, &mutation(records));
            drop(store);

            assert!(matches!(
                SessionStore::open(&managed_root),
                Err(StoreError::IntegrityMismatch(
                    "stale journal replacement diverges from authoritative history"
                ))
            ));
            assert!(residue.is_file());
        }
    }

    #[test]
    fn store_open_preserves_nonregular_journal_residue_and_fails_closed() {
        let temp = TempDir::new().unwrap();
        let managed_root = temp.path().join("Open Scribe");
        let mut store = SessionStore::open(&managed_root).unwrap();
        let receipt = store.prepare_session(request()).unwrap();
        let session_directory = store.session_directory(&receipt.session_id.0).unwrap();
        let residue =
            session_directory.join(format!(".open-scribe-journal-{}.tmp", Uuid::now_v7()));
        fs::create_dir(&residue).unwrap();
        drop(store);

        assert!(matches!(
            SessionStore::open(&managed_root),
            Err(StoreError::IntegrityMismatch(
                "stale journal replacement is not a regular file"
            ))
        ));
        assert!(residue.is_dir());
    }

    #[test]
    fn store_open_preserves_symlinked_journal_residue_and_fails_closed() {
        let temp = TempDir::new().unwrap();
        let managed_root = temp.path().join("Open Scribe");
        let mut store = SessionStore::open(&managed_root).unwrap();
        let receipt = store.prepare_session(request()).unwrap();
        let session_directory = store.session_directory(&receipt.session_id.0).unwrap();
        let outside = temp.path().join("outside-journal-residue");
        fs::write(&outside, b"preserve me").unwrap();
        let stale = session_directory.join(format!(".open-scribe-journal-{}.tmp", Uuid::now_v7()));
        symlink(&outside, &stale).unwrap();
        drop(store);

        assert!(matches!(
            SessionStore::open(&managed_root),
            Err(StoreError::IntegrityMismatch(
                "stale journal replacement is not a regular file"
            ))
        ));
        assert!(
            fs::symlink_metadata(&stale)
                .unwrap()
                .file_type()
                .is_symlink()
        );
        assert_eq!(fs::read(&outside).unwrap(), b"preserve me");
    }

    #[test]
    fn store_open_preserves_journal_residue_when_authoritative_journal_is_invalid() {
        let temp = TempDir::new().unwrap();
        let managed_root = temp.path().join("Open Scribe");
        let mut store = SessionStore::open(&managed_root).unwrap();
        let receipt = store.prepare_session(request()).unwrap();
        let session_directory = store.session_directory(&receipt.session_id.0).unwrap();
        let journal_path = session_directory.join(JOURNAL_NAME);
        let stale = session_directory.join(format!(".open-scribe-journal-{}.tmp", Uuid::now_v7()));
        fs::write(&stale, b"preserve for diagnosis").unwrap();
        let mut journal_bytes = fs::read(&journal_path).unwrap();
        journal_bytes.pop();
        fs::write(&journal_path, journal_bytes).unwrap();
        drop(store);

        assert!(matches!(
            SessionStore::open(&managed_root),
            Err(StoreError::IntegrityMismatch(
                "stale journal replacement has no valid authoritative journal"
            ))
        ));
        assert_eq!(fs::read(&stale).unwrap(), b"preserve for diagnosis");
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

    mod media_lifecycle_tests;
    use media_lifecycle_tests::{
        append_first_sample, first_sample_receipt, media_receipt, prepared_dual_first_samples,
        replace_with_recoverable_pcm_caf, seal_receipt, write_test_caf,
    };

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
    fn one_failed_source_keeps_the_other_source_recording_with_degraded_health() {
        let temp = TempDir::new().unwrap();
        let mut store = open_store(&temp);
        let (prepared, _, system) = prepared_dual_first_samples(&mut store);
        store
            .confirm_recording(prepared.session_id.clone())
            .unwrap();

        replace_with_recoverable_pcm_caf(&system, 960);
        let system_byte_length = fs::metadata(&system.absolute_path).unwrap().len();
        store
            .seal_segment(seal_receipt(&system, system_byte_length))
            .unwrap();

        let request = SourceFailureRequest {
            session_id: prepared.session_id.clone(),
            source_kind: MediaSourceKind::SystemAudio,
            reason: SourceFailureReason::CaptureFailed,
        };
        let evidence = store.record_source_failure(request.clone()).unwrap();
        assert_eq!(store.record_source_failure(request).unwrap(), evidence);

        assert!(evidence.journal_durable);
        assert!(evidence.source_failed);
        assert!(evidence.session_degraded);
        assert!(!evidence.session_interrupted);
        assert!(evidence.recording_continues);

        let current = store
            .runtime_library_snapshot()
            .unwrap()
            .current_session
            .unwrap();
        assert_eq!(current.lifecycle, "recording");
        assert_eq!(current.health, "degraded");
        assert_eq!(
            current
                .sources
                .iter()
                .find(|source| source.kind == MediaSourceKind::SystemAudio)
                .unwrap()
                .lifecycle,
            "failed"
        );
        assert_eq!(
            current
                .sources
                .iter()
                .find(|source| source.kind == MediaSourceKind::Microphone)
                .unwrap()
                .lifecycle,
            "capturing"
        );

        store
            .connection
            .execute(
                "DELETE FROM session_events
                 WHERE session_id = ?1 AND event_kind = 'source_failed'",
                [&prepared.session_id.0],
            )
            .unwrap();
        store
            .connection
            .execute(
                "UPDATE required_sources SET lifecycle = 'sealed'
                 WHERE session_id = ?1 AND kind = 'system_audio'",
                [&prepared.session_id.0],
            )
            .unwrap();
        store
            .connection
            .execute(
                "UPDATE sources SET lifecycle = 'sealed'
                 WHERE session_id = ?1 AND kind = 'system_audio'",
                [&prepared.session_id.0],
            )
            .unwrap();
        store
            .connection
            .execute(
                "UPDATE sessions SET health = 'healthy' WHERE id = ?1",
                [&prepared.session_id.0],
            )
            .unwrap();
        drop(store);

        let mut reopened = open_store(&temp);
        let findings = reopened.recover_preparations().unwrap();
        assert_eq!(findings.len(), 1);
        assert_eq!(
            findings[0].disposition,
            RecoveryDisposition::SourceFailureProjectionRepaired
        );
        let recovered = reopened
            .runtime_library_snapshot()
            .unwrap()
            .current_session
            .unwrap();
        assert_eq!(recovered.lifecycle, "recording");
        assert_eq!(recovered.health, "degraded");
    }

    #[test]
    fn source_failure_followed_by_recovery_preserves_degraded_identity_truth() {
        let temp = TempDir::new().unwrap();
        let root = temp.path().join("Open Scribe");
        let session_id;
        {
            let mut store = SessionStore::open(&root).unwrap();
            let (prepared, microphone, system) = prepared_dual_first_samples(&mut store);
            session_id = prepared.session_id.clone();
            store.confirm_recording(session_id.clone()).unwrap();

            replace_with_recoverable_pcm_caf(&system, 48_000);
            let system_byte_length = fs::metadata(&system.absolute_path).unwrap().len();
            let mut system_seal = seal_receipt(&system, system_byte_length);
            system_seal.sample_count = 48_000;
            store.seal_segment(system_seal).unwrap();
            store
                .record_source_failure(SourceFailureRequest {
                    session_id: session_id.clone(),
                    source_kind: MediaSourceKind::SystemAudio,
                    reason: SourceFailureReason::CaptureFailed,
                })
                .unwrap();

            replace_with_recoverable_pcm_caf(&microphone, 96_000);
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
        assert_eq!(
            recovered
                .iter()
                .map(|item| item.source_kind)
                .collect::<Vec<_>>(),
            [MediaSourceKind::Microphone, MediaSourceKind::SystemAudio]
        );
        assert!(recovered.iter().all(|item| !item.source_id.is_empty()));
        assert!(recovered.iter().all(|item| !item.track_id.is_empty()));
        assert_eq!(
            database_value(
                &reopened,
                "SELECT COUNT(*) FROM session_events WHERE event_kind = 'source_failed'",
            ),
            1
        );
        let snapshot = reopened
            .runtime_library_snapshot()
            .unwrap()
            .saved_sessions
            .remove(0);
        assert_eq!(snapshot.health, "degraded");
        assert_eq!(snapshot.elapsed_seconds, 2);
        assert_eq!(
            snapshot
                .sources
                .iter()
                .find(|source| source.kind == MediaSourceKind::Microphone)
                .unwrap()
                .lifecycle,
            "sealed"
        );
        assert_eq!(
            snapshot
                .sources
                .iter()
                .find(|source| source.kind == MediaSourceKind::SystemAudio)
                .unwrap()
                .lifecycle,
            "failed"
        );
    }

    #[test]
    fn recovery_rejects_cross_session_track_edges_as_required_media() {
        let temp = TempDir::new().unwrap();
        let root = temp.path().join("Open Scribe");
        let session_id;
        {
            let mut store = SessionStore::open(&root).unwrap();
            let (prepared, microphone, system) = prepared_dual_first_samples(&mut store);
            session_id = prepared.session_id.clone();
            store.confirm_recording(session_id.clone()).unwrap();

            replace_with_recoverable_pcm_caf(&system, 48_000);
            let system_byte_length = fs::metadata(&system.absolute_path).unwrap().len();
            let mut system_seal = seal_receipt(&system, system_byte_length);
            system_seal.sample_count = 48_000;
            store.seal_segment(system_seal).unwrap();
            store
                .record_source_failure(SourceFailureRequest {
                    session_id: session_id.clone(),
                    source_kind: MediaSourceKind::SystemAudio,
                    reason: SourceFailureReason::CaptureFailed,
                })
                .unwrap();

            replace_with_recoverable_pcm_caf(&microphone, 96_000);
            let other_session = store.prepare_session(request()).unwrap().session_id;
            store
                .connection
                .execute(
                    "UPDATE tracks SET session_id = ?2 WHERE id = ?1",
                    params![system.track_id, other_session.0],
                )
                .unwrap();
            store
                .interrupt_session(InterruptSessionRequest {
                    session_id: session_id.clone(),
                    reason: SessionInterruptionReason::CaptureFailed,
                })
                .unwrap();
        }

        let mut reopened = SessionStore::open(&root).unwrap();
        let recovery = reopened.recover_library().unwrap();
        assert_eq!(
            recovery
                .findings
                .iter()
                .find(|finding| finding.session_id == session_id)
                .map(|finding| finding.disposition),
            Some(RecoveryDisposition::IntegrityMismatch),
            "the session missing a playable source is its own finding"
        );
        assert!(recovery.playable.is_empty());
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
        assert_eq!(
            database_value(
                &reopened,
                "SELECT COUNT(*) FROM recovery_runs WHERE disposition = 'playable_media_recovered'",
            ),
            0
        );
        let journal_path = reopened
            .session_directory(&session_id.0)
            .unwrap()
            .join(JOURNAL_NAME);
        let JournalValidation::Valid(records) =
            validate_journal(&journal_path, &session_id.0).unwrap()
        else {
            panic!("expected valid recovery journal");
        };
        assert_eq!(
            records
                .iter()
                .filter(|record| record.body.event_kind == "playable_media_recovered")
                .count(),
            0
        );
    }

    mod runtime_library_snapshot_tests;
}
