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

#[macro_use]
mod vocabulary;
pub use vocabulary::{
    RecorderEventKind, RetainedRunUse, SessionHealth, SessionInterruptionReason, SessionLifecycle,
    SourceLifecycle, StorageLevel, SuggestionBasis, TrackSourceKind, TranscriptFinality,
    TranscriptionFailureClass, TranscriptionRunState,
};
use vocabulary::{capture_channels, parse_source_kind};
mod error;
pub use error::StoreError;
use error::missing_row;
mod capture;
mod capture_projection;
mod digest;
mod durable;
mod events;
mod injection;
mod journal;
mod media;
mod recovery;
mod schema;
use capture::*;
pub use capture::{
    AuthorizeMediaOpenRequest, FirstSampleEvidence, FirstSampleReceipt, InterruptSessionRequest,
    MediaOpenAuthorization, MediaOpenEvidence, MediaOpenReceipt, RecordingStartedEvidence,
    RequiredSourcePlanEvidence, SealSegmentReceipt, SealedSegmentEvidence,
    SessionInterruptionEvidence,
};
use digest::*;
use durable::*;
use events::*;
use injection::*;
use journal::*;
use media::*;
use recovery::*;
pub use recovery::{RecoveredPlayableSession, RecoveryDisposition, RecoveryFinding};
use schema::*;
mod context;
mod conversation_identity;
mod conversation_titles;
mod sealed_media_identity;
pub use context::{
    CONTEXT_EXCLUSIONS, CONTEXT_SCOPE_SCHEMA, ContextAction, ContextBounds, ContextCondition,
    ContextDetail, ContextFailureReason, ContextMode, ContextPauseReason, ContextRetention,
    ContextScope, ContextScopeRequest, ContextTarget, ContextTargetKind, DisplayTopology,
    ScreenPermission, SessionDeclaration,
};
pub use conversation_titles::{ConversationTitle, TitleSource, imported_title};
use sealed_media_identity::SealedEvidence;
mod context_events;
pub use context_events::{
    AcceptedContextEvent, CONTEXT_EVENT_SCHEMA, ContextDecision, ContextEventReason,
    ContextEventRecord, ContextProposal, ContextRejection, ContextSource, ContextTextBlock,
};
mod capture_policy;
pub use capture_policy::{
    CapturePolicy, SourceDefaults, UNKNOWN_SOURCE_SPEAKER_LABEL, capture_policy, source_defaults,
};
mod import;
mod journal_cost;
mod journal_replacement;
mod library_recovery;
mod storage_reserve;
mod writer;
pub use journal_cost::JournalCost;
mod session_times;
pub use session_times::rfc3339_utc;
mod transcription_operation;
mod transcription_work;
pub use library_recovery::LibraryRecovery;
pub use transcription_operation::{
    SelectionExpectation, TrackSelectionExpectation, TranscriptionOperation, TranscriptionRunPolicy,
};
pub use transcription_work::TranscriptionWork;
mod media_recovery;
mod mixdown;
pub use mixdown::{MixdownAuthorization, MixdownReceipt, ValidatedMixdown};
mod mixdown_activity;
pub use mixdown_activity::MixdownWork;
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
    DecodedAudioError, DigestedSegment, InputSegment, InputSpan, SealedTrackReader,
    TranscriptionInput, transcription_input_digest,
};
mod derived_claims;
pub use derived_claims::{ClaimEvidenceSide, ClaimNavigation, ClaimNavigationTarget};
mod evidence_resolution;
mod meeting_memory;
pub use evidence_resolution::ResolvedEvidence;
mod session_inventory;
pub use session_inventory::{SessionInventory, SessionMarker, SessionMediaEntry, VerifiedMedia};
mod transcript_export;
pub use transcript_export::{SelectedRevisionProvenance, TranscriptExportContext};
mod transcript_review;
pub use transcript_review::{
    SessionSpeaker, SpeakerLabelHistory, SpeakerLabelOrigin, SpeakerLabelRevision,
    TranscriptSearchHit,
};
mod conversation_document;
pub use conversation_document::{ConversationDocument, DocumentScope, TranscriptDocumentSegment};
mod transcript_selection;
mod transcript_speakers;
pub use transcript_speakers::{
    NamedSpeakerTurn, NamedSpeakerTurnHistory, NamedSpeakerTurnRevision, NamedTranscriptSpeaker,
    TranscriptSpeakerAssignment,
};
mod speaker_diarization;
pub use speaker_diarization::{SpeakerDiarization, SpeakerDiarizationTrack};
mod transcripts;
pub use transcript_selection::TranscriptSelectionPolicy;
pub use transcripts::{
    LiveDraftWindow, PlannedTranscriptChunk, RevisionSegmentInput, StoredTranscriptionRun,
    TRANSCRIPT_SCHEMA_VERSION, TranscriptChunk, TranscriptChunkState, TranscriptProvenance,
    TranscriptProvenanceRange, TranscriptRevisionSummary, TranscriptSegmentView,
    TranscriptionFailure, TranscriptionRunHandle, TranscriptionRunIdentity,
    TranscriptionRunSummary,
};

use conversation_identity::validate_request;
pub use conversation_identity::{
    ConversationReviewMetadata, PrepareSessionRequest, PreparedSessionReceipt, SessionOrigin,
};
pub use import::{
    CompressedImportMetadata, ImportMediaRequest, ImportPolicy, ImportedMediaEvidence,
    ImportedPlaybackLease, OriginalImportMetadata, import_policy,
};
pub use runtime_snapshot::{
    RuntimeLibrarySnapshot, RuntimePlayableMediaAvailability, RuntimePlayableMediaSnapshot,
    RuntimeSessionSnapshot, RuntimeSourceSnapshot, RuntimeTranscriptSnapshot,
    RuntimeTranscriptState,
};
pub use source_failure::{SourceFailureEvidence, SourceFailureReason, SourceFailureRequest};

const MAX_TITLE_BYTES: usize = 512;
const MAX_DISPLAY_NAME_BYTES: usize = 512;
const DATABASE_NAME: &str = "Library.sqlite3";
const SESSIONS_DIRECTORY: &str = "Sessions";
use open_scribe_types::MEDIA_SAMPLE_RATE_HZ;

/// The capture source kinds; one type shared with the fixture domain.
pub use open_scribe_types::SourceKind as MediaSourceKind;

/// Verified sealed digests kept for library polling. A larger library stays
/// on the fast path; the map is still bounded and dies with the process.
const SNAPSHOT_DIGEST_MEMO_CAPACITY: usize = 4096;

pub struct SessionStore {
    managed_root: PathBuf,
    sessions_root: PathBuf,
    connection: Connection,
    digest_memo: std::cell::RefCell<library_recovery::DigestMemo>,
    journal_cost: std::cell::RefCell<JournalCost>,
    // UI polling alone may reuse a verified sealed digest. Every lease,
    // transcript input, export and recovery still validates independently.
    snapshot_digest_memo:
        std::cell::RefCell<BTreeMap<sealed_media_identity::MediaIdentity, String>>,
    #[cfg(test)]
    media_validation_hook: std::cell::RefCell<Option<Box<dyn FnOnce()>>>,
}

impl SessionStore {
    /// Opens or creates the managed root, configures SQLite, and applies every
    /// schema migration.
    pub fn open(managed_root: impl AsRef<Path>) -> Result<Self, StoreError> {
        let managed_root = managed_root.as_ref().to_path_buf();
        validate_or_create_managed_root(&managed_root)?;
        let _writer = writer::WriterGuard::acquire(&managed_root)?;
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
            journal_cost: std::cell::RefCell::default(),
            snapshot_digest_memo: std::cell::RefCell::default(),
            #[cfg(test)]
            media_validation_hook: std::cell::RefCell::default(),
        })
    }

    /// Remembers a digest whose file identity already matched a sealed receipt.
    /// The memory lives only in this store. A new open hashes again, and a
    /// changed file identity misses the entry.
    fn remember_snapshot_digest(
        &self,
        identity: sealed_media_identity::MediaIdentity,
        digest: String,
    ) {
        let mut memo = self.snapshot_digest_memo.borrow_mut();
        if memo.len() >= SNAPSHOT_DIGEST_MEMO_CAPACITY && !memo.contains_key(&identity) {
            memo.pop_first();
        }
        memo.insert(identity, digest);
    }

    #[must_use]
    pub fn managed_root(&self) -> &Path {
        &self.managed_root
    }

    fn write_guard(&self) -> Result<writer::WriterGuard, StoreError> {
        writer::WriterGuard::acquire(&self.managed_root)
    }

    pub fn journal_cost(&self) -> JournalCost {
        *self.journal_cost.borrow()
    }

    fn session_directory(&self, session_id: &str) -> Result<PathBuf, StoreError> {
        let directory = self.sessions_root.join(session_id);
        require_real_directory(&directory)?;
        Ok(directory)
    }
}

fn wall_time_milliseconds() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or(Duration::ZERO)
        .as_millis()
        .min(i64::MAX as u128) as i64
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::os::unix::fs::symlink;
    use tempfile::TempDir;

    mod journal_append_tests;

    fn request() -> PrepareSessionRequest {
        PrepareSessionRequest {
            title: "Design review".to_owned(),
            origin: SessionOrigin::Capture,
        }
    }

    fn open_store(temp: &TempDir) -> SessionStore {
        SessionStore::open(temp.path().join("Open Scribe")).unwrap()
    }

    #[test]
    fn a_suggested_title_stands_in_for_the_placeholder_until_a_person_names_it() {
        let temp = TempDir::new().unwrap();
        let mut store = open_store(&temp);
        let placeholder = "Conversation 2026-11-12T19:30:05Z";
        let receipt = store
            .prepare_session(PrepareSessionRequest {
                title: placeholder.to_owned(),
                origin: SessionOrigin::Capture,
            })
            .unwrap();
        let session = &receipt.session_id;
        let snapshot = |store: &SessionStore| {
            store
                .runtime_library_snapshot()
                .unwrap()
                .current_session
                .unwrap()
        };
        let before = snapshot(&store);
        assert_eq!(before.display_title, placeholder);
        assert_eq!(before.title_source, TitleSource::Placeholder);
        assert!(before.created_at_ms > 0);

        assert!(
            store
                .suggest_conversation_title(
                    session,
                    "Mobile beta launch",
                    "test-engine",
                    SuggestionBasis::Draft
                )
                .unwrap()
        );
        let suggested = snapshot(&store);
        assert_eq!(
            suggested.title, placeholder,
            "the stored title is unchanged"
        );
        assert_eq!(suggested.display_title, "Mobile beta launch");
        assert_eq!(suggested.title_source, TitleSource::Suggested);

        assert!(
            store
                .suggest_conversation_title(
                    session,
                    "Beta moves to the 23rd",
                    "test-engine",
                    SuggestionBasis::Final
                )
                .unwrap()
        );
        assert!(
            !store
                .suggest_conversation_title(
                    session,
                    "Draft guess",
                    "test-engine",
                    SuggestionBasis::Draft
                )
                .unwrap(),
            "a draft-based suggestion never replaces a final-based one"
        );
        let resolved = store.conversation_title(session).unwrap();
        assert_eq!(resolved.display_title, "Beta moves to the 23rd");
        assert_eq!(resolved.suggestion_basis, Some(SuggestionBasis::Final));

        store.rename_session(session, "Beta check-in").unwrap();
        assert!(
            !store
                .suggest_conversation_title(
                    session,
                    "Another guess",
                    "test-engine",
                    SuggestionBasis::Final
                )
                .unwrap(),
            "a person's title refuses later suggestions"
        );
        let named = snapshot(&store);
        assert_eq!(named.display_title, "Beta check-in");
        assert_eq!(named.title_source, TitleSource::Person);
        assert!(
            store
                .suggest_conversation_title(session, "", "test-engine", SuggestionBasis::Final)
                .is_err()
        );
    }

    #[test]
    fn rename_session_replaces_only_the_title() {
        let temp = TempDir::new().unwrap();
        let mut store = open_store(&temp);
        let receipt = store.prepare_session(request()).unwrap();
        let before = store
            .runtime_library_snapshot()
            .unwrap()
            .current_session
            .unwrap();
        assert_eq!(before.title, "Design review");
        let updated_before: i64 = store
            .connection
            .query_row(
                "SELECT updated_at_ms FROM sessions WHERE id = ?1",
                [&receipt.session_id.0],
                |row| row.get(0),
            )
            .unwrap();
        std::thread::sleep(std::time::Duration::from_millis(2));

        assert_eq!(
            store
                .rename_session(&receipt.session_id, "  Weekly sync  ")
                .unwrap(),
            "Weekly sync"
        );
        let after = store
            .runtime_library_snapshot()
            .unwrap()
            .current_session
            .unwrap();
        assert_eq!(after.title, "Weekly sync");
        assert_eq!(after.lifecycle, before.lifecycle);
        assert_eq!(after.elapsed_seconds, before.elapsed_seconds);
        let (persisted, updated_after): (String, i64) = store
            .connection
            .query_row(
                "SELECT title, updated_at_ms FROM sessions WHERE id = ?1",
                [&receipt.session_id.0],
                |row| Ok((row.get(0)?, row.get(1)?)),
            )
            .unwrap();
        assert_eq!(persisted, "Weekly sync");
        assert_eq!(
            updated_after, updated_before,
            "renaming is not lifecycle activity"
        );

        let too_long = "x".repeat(MAX_TITLE_BYTES + 1);
        for invalid in ["", "   ", "a\u{7}b", too_long.as_str()] {
            assert!(matches!(
                store.rename_session(&receipt.session_id, invalid),
                Err(StoreError::InvalidRequest(_))
            ));
        }
        assert!(matches!(
            store.rename_session(&SessionId("missing".to_owned()), "Other"),
            Err(StoreError::InvalidState(_))
        ));
        let reopened = SessionStore::open(temp.path().join("Open Scribe")).unwrap();
        assert_eq!(
            reopened
                .runtime_library_snapshot()
                .unwrap()
                .current_session
                .unwrap()
                .title,
            "Weekly sync"
        );
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
            "transcript_named_speakers",
            "transcript_speaker_names",
            "transcript_turn_speakers",
            "speaker_diarization_runs",
            "speaker_diarization_tracks",
            "transcript_search",
            "session_deletion_intents",
            "context_scopes",
            "context_events",
            "session_declarations",
            "session_restorations",
            "derived_claim_revisions",
            "meeting_memory_projection",
            "meeting_memory_delta_receipts",
            "meeting_memory_delta_operations",
        ] {
            assert!(names.contains(required), "missing table {required}");
        }
        assert_eq!(
            database_value(&store, "SELECT MAX(version) FROM schema_migrations"),
            21
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
            21
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
                    None,
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
    mod sealed_identity_tests;
}
