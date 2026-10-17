use super::*;
use crate::transcripts::tests::{
    Fixture, complete_all, identity, imported_fixture, plan, sample, write_caf,
};
use crate::{ImportMediaRequest, SESSIONS_DIRECTORY};
use sha2::{Digest, Sha256};
use std::path::Path;

/// Discover the current schema denominator, including newly added owners.
/// A tombstone does not trigger ON DELETE CASCADE on the surviving session.
fn session_tables(store: &SessionStore) -> Vec<String> {
    store
        .connection
        .prepare(
            "SELECT name FROM sqlite_schema WHERE type = 'table'
         AND EXISTS(SELECT 1 FROM pragma_table_info(sqlite_schema.name) WHERE name = 'session_id')
         ORDER BY name",
        )
        .unwrap()
        .query_map([], |row| row.get(0))
        .unwrap()
        .collect::<Result<_, _>>()
        .unwrap()
}

fn reviewed_fixture() -> (Fixture, String) {
    let mut fixture = imported_fixture(144_000);
    let run = fixture
        .store
        .begin_transcription_run(&identity(&fixture, "options-a"), &plan())
        .unwrap();
    let revision = complete_all(&mut fixture, &run, ["alpha", "bravo"]);
    let (session, track) = (fixture.session.clone(), fixture.track.clone());
    fixture
        .store
        .correct_transcript_segment(&session, &revision, 1, Some("Bravo two"))
        .unwrap();
    fixture
        .store
        .rename_speaker(&session, &track, Some("Dana"))
        .unwrap();
    (fixture, revision)
}

fn rows(store: &SessionStore, table: &str, session: &SessionId) -> i64 {
    store
        .connection
        .query_row(
            &format!("SELECT COUNT(*) FROM {table} WHERE session_id = ?1"),
            [&session.0],
            |row| row.get(0),
        )
        .unwrap()
}

fn session_directory(fixture: &Fixture, session: &SessionId) -> PathBuf {
    fixture.root.join(SESSIONS_DIRECTORY).join(&session.0)
}

/// Stands in for the macOS adapter's move to Trash.
fn move_to_trash(fixture: &Fixture, session: &SessionId) -> PathBuf {
    let trash = fixture.root.parent().unwrap().join("Trash");
    fs::create_dir_all(&trash).unwrap();
    let destination = trash.join(&session.0);
    fs::rename(session_directory(fixture, session), &destination).unwrap();
    destination
}

fn digest(path: &Path) -> String {
    Sha256::digest(fs::read(path).unwrap())
        .iter()
        .map(|byte| format!("{byte:02x}"))
        .collect()
}

fn import_second(fixture: &mut Fixture) -> SessionId {
    let source = fixture.root.parent().unwrap().join("second.caf");
    write_caf(&source, 48_000, sample);
    fixture
        .store
        .import_recoverable_caf(ImportMediaRequest {
            title: "Kept".into(),
            source_path: source,
        })
        .unwrap()
        .session_id
}

#[test]
fn deletion_states_its_scope_requires_trash_and_removes_every_owned_row() {
    let (mut fixture, _) = reviewed_fixture();
    let session = fixture.session.clone();
    let kept = import_second(&mut fixture);
    let media_digest = digest(&fixture.media);
    let media_length = fs::metadata(&fixture.media).unwrap().len();
    let exports = session_directory(&fixture, &session).join(EXPORTS_DIRECTORY);
    fs::create_dir_all(&exports).unwrap();
    fs::write(exports.join("notes.txt"), b"exported").unwrap();
    fixture.store.cancel_transcription(&session).unwrap();
    assert_eq!(rows(&fixture.store, "transcription_intent", &session), 1);

    let inventory = fixture.store.begin_session_deletion(&session).unwrap();
    assert_eq!(
        inventory,
        SessionDeletionInventory {
            session_id: session.clone(),
            title: "Transcript fixture".into(),
            directory: session_directory(&fixture, &session),
            media_files: 1,
            media_bytes: media_length,
            transcript_revisions: 1,
            human_corrections: 1,
            speaker_names: 1,
            markers: 0,
            context_events: 0,
            export_files: 1,
            export_bytes: 8,
        }
    );

    assert!(matches!(
        fixture.store.complete_session_deletion(&session, None),
        Err(StoreError::InvalidState(_))
    ));
    assert_eq!(rows(&fixture.store, "transcript_revisions", &session), 1);
    assert_eq!(
        fixture
            .store
            .search_transcripts("bravo", None, 10)
            .unwrap()
            .len(),
        1
    );

    let trashed = move_to_trash(&fixture, &session);
    let reference = format!("file://{}", trashed.display());
    let receipt = fixture
        .store
        .complete_session_deletion(&session, Some(&reference))
        .unwrap();
    assert_eq!(receipt.session_id, session);
    assert_eq!(receipt.trash_reference.as_deref(), Some(reference.as_str()));

    let tables = session_tables(&fixture.store);
    assert!(tables.iter().any(|name| name == "transcription_intent"));
    assert!(
        tables
            .iter()
            .any(|name| name == "transcript_selection_epochs")
    );
    assert!(tables.iter().any(|name| name == "session_metadata_times"));
    for table in &tables {
        let expected = i64::from(table == "deletion_receipts");
        assert_eq!(rows(&fixture.store, table, &session), expected, "{table}");
    }
    let (title, lifecycle): (String, String) = fixture
        .store
        .connection
        .query_row(
            "SELECT title, lifecycle FROM sessions WHERE id = ?1",
            [&session.0],
            |row| Ok((row.get(0)?, row.get(1)?)),
        )
        .unwrap();
    assert_eq!((title.as_str(), lifecycle.as_str()), ("", "deleted"));
    assert!(
        fixture
            .store
            .search_transcripts("bravo", None, 10)
            .unwrap()
            .is_empty()
    );
    assert!(fixture.store.transcript_export_context(&session).is_err());
    let snapshot = fixture.store.runtime_library_snapshot().unwrap();
    assert!(
        snapshot
            .saved_sessions
            .iter()
            .all(|saved| saved.session_id != session)
    );
    assert!(
        snapshot
            .saved_sessions
            .iter()
            .any(|saved| saved.session_id == kept)
    );
    assert!(rows(&fixture.store, "segments", &kept) > 0);
    assert_eq!(
        digest(
            &trashed.join(
                fixture
                    .media
                    .strip_prefix(session_directory(&fixture, &session))
                    .unwrap()
            )
        ),
        media_digest,
        "Trash keeps the media recoverable"
    );
    assert!(fixture.store.begin_session_deletion(&session).is_err());
    let reopened = SessionStore::open(&fixture.root).unwrap();
    for table in &tables {
        assert_eq!(
            rows(&reopened, table, &session),
            i64::from(table == "deletion_receipts"),
            "reopen must not recreate {table}",
        );
    }
}

#[test]
fn deletion_confirmation_excludes_background_admission_across_handles() {
    let mut fixture = imported_fixture(48_000);
    let session = fixture.session.clone();
    fixture
        .store
        .request_transcription(
            &session,
            open_scribe_types::TranscriptionIntent::ResumeIncomplete,
        )
        .unwrap();
    fixture.store.begin_session_deletion(&session).unwrap();
    let mut other = SessionStore::open(&fixture.root).unwrap();
    let ready = open_scribe_types::WorkObservations {
        model: open_scribe_types::ModelReadiness::Ready,
        ..Default::default()
    };
    assert!(other.admit_transcription(ready).unwrap().is_none());
    assert!(
        other
            .request_transcription(
                &session,
                open_scribe_types::TranscriptionIntent::ResumeIncomplete
            )
            .is_err()
    );
    fixture.store.abandon_session_deletion(&session).unwrap();
    assert!(other.admit_transcription(ready).unwrap().unwrap().manual);
}

#[test]
fn active_processing_must_finish_before_deletion_is_prepared() {
    let mut fixture = imported_fixture(48_000);
    let session = fixture.session.clone();
    let admitted = fixture
        .store
        .admit_transcription(open_scribe_types::WorkObservations {
            model: open_scribe_types::ModelReadiness::Ready,
            ..Default::default()
        })
        .unwrap()
        .unwrap();
    let mut other = SessionStore::open(&fixture.root).unwrap();
    assert!(other.begin_session_deletion(&session).is_err());
    assert_eq!(rows(&other, "session_deletion_intents", &session), 0);
    fixture.store.cancel_transcription(&session).unwrap();
    assert!(
        other.begin_session_deletion(&session).is_err(),
        "wait for the runner's stop acknowledgment"
    );
    fixture
        .store
        .finish_transcription(
            admitted.admission.as_deref().unwrap(),
            open_scribe_types::WorkOutcome::UserCancelled,
        )
        .unwrap();
    assert!(other.begin_session_deletion(&session).is_ok());
}

#[test]
fn failed_inventory_does_not_leave_a_deletion_intent() {
    let mut fixture = imported_fixture(48_000);
    let session = fixture.session.clone();
    fs::remove_dir(session_directory(&fixture, &session).join(EXPORTS_DIRECTORY)).unwrap();
    fs::write(
        session_directory(&fixture, &session).join(EXPORTS_DIRECTORY),
        b"not a directory",
    )
    .unwrap();
    assert!(fixture.store.begin_session_deletion(&session).is_err());
    assert_eq!(
        rows(&fixture.store, "session_deletion_intents", &session),
        0
    );
}

#[test]
fn stale_commands_cannot_recreate_intent_after_deletion() {
    let mut fixture = imported_fixture(48_000);
    let session = fixture.session.clone();
    fixture.store.begin_session_deletion(&session).unwrap();
    move_to_trash(&fixture, &session);
    fixture
        .store
        .complete_session_deletion(&session, None)
        .unwrap();
    assert!(
        fixture
            .store
            .request_transcription(
                &session,
                open_scribe_types::TranscriptionIntent::ResumeIncomplete
            )
            .is_err()
    );
    let _ = fixture.store.cancel_transcription(&session);
    assert_eq!(rows(&fixture.store, "transcription_intent", &session), 0);
}

#[test]
fn confirmation_freezes_review_and_legacy_checkpoints_without_blocking_orphan_deletion() {
    let (mut fixture, revision) = reviewed_fixture();
    let session = fixture.session.clone();
    let track = fixture.track.clone();
    let run = fixture
        .store
        .begin_transcription_run(&identity(&fixture, "orphan"), &plan())
        .unwrap();
    // Durable running history alone is not evidence of a live admitted worker.
    fixture.store.begin_session_deletion(&session).unwrap();
    let mut other = SessionStore::open(&fixture.root).unwrap();
    assert!(
        other
            .rename_session(&session, "Changed during confirmation")
            .is_err()
    );
    assert!(
        other
            .correct_transcript_segment(&session, &revision, 1, Some("Changed"))
            .is_err()
    );
    assert!(
        other
            .rename_speaker(&session, &track, Some("Changed"))
            .is_err()
    );
    assert!(
        other
            .select_transcript_revision(&session, &track, &revision)
            .is_err()
    );
    assert!(other.mark_transcript_chunk_running(&run.run_id, 0).is_err());
    fixture.store.abandon_session_deletion(&session).unwrap();
    assert!(
        other
            .rename_session(&session, "Allowed after cancellation")
            .is_ok()
    );
    assert!(other.mark_transcript_chunk_running(&run.run_id, 0).is_ok());
}

#[test]
fn deletion_reports_a_busy_wal_instead_of_claiming_erasure() {
    let (mut fixture, _) = reviewed_fixture();
    let session = fixture.session.clone();
    fixture.store.begin_session_deletion(&session).unwrap();
    let mut reader = SessionStore::open(&fixture.root).unwrap();
    let read = reader
        .connection
        .transaction_with_behavior(rusqlite::TransactionBehavior::Deferred)
        .unwrap();
    let before: i64 = read
        .query_row(
            "SELECT COUNT(*) FROM transcript_corrections WHERE session_id = ?1",
            [&session.0],
            |row| row.get(0),
        )
        .unwrap();
    assert!(before > 0);
    move_to_trash(&fixture, &session);
    let began = std::time::Instant::now();
    let deletion = fixture.store.complete_session_deletion(&session, None);
    assert!(
        deletion.is_ok(),
        "deletion={deletion:?}, durable_receipts={}, remaining_corrections={}",
        rows(&fixture.store, "deletion_receipts", &session),
        rows(&fixture.store, "transcript_corrections", &session),
    );
    let receipt = deletion.unwrap();
    assert!(!receipt.wal_checkpointed);
    assert_eq!(
        fixture
            .store
            .connection
            .pragma_query_value::<i64, _>(None, "busy_timeout", |row| row.get(0))
            .unwrap(),
        5_000,
        "optional cleanup must restore the writer connection's busy policy",
    );
    assert!(
        began.elapsed() < std::time::Duration::from_secs(1),
        "optional WAL cleanup waited {:?} after durable deletion",
        began.elapsed(),
    );
    assert_eq!(rows(&fixture.store, "transcript_corrections", &session), 0);
    assert_eq!(
        read.query_row::<i64, _, _>(
            "SELECT COUNT(*) FROM transcript_corrections WHERE session_id = ?1",
            [&session.0],
            |row| row.get(0),
        )
        .unwrap(),
        before,
        "the earlier reader still owns its historical snapshot"
    );
    read.commit().unwrap();
}

#[test]
fn abandoned_or_active_deletions_change_nothing() {
    let (mut fixture, _) = reviewed_fixture();
    let session = fixture.session.clone();
    fixture.store.begin_session_deletion(&session).unwrap();
    fixture.store.abandon_session_deletion(&session).unwrap();
    move_to_trash(&fixture, &session);
    assert!(matches!(
        fixture.store.complete_session_deletion(&session, None),
        Err(StoreError::InvalidState(_))
    ));
    assert_eq!(rows(&fixture.store, "transcript_revisions", &session), 1);

    let (mut active, _) = reviewed_fixture();
    let active_session = active.session.clone();
    active
        .store
        .connection
        .execute(
            "UPDATE sessions SET lifecycle = 'recording' WHERE id = ?1",
            [&active_session.0],
        )
        .unwrap();
    assert!(matches!(
        active.store.begin_session_deletion(&active_session),
        Err(StoreError::InvalidState(_))
    ));
    assert!(
        active
            .store
            .begin_session_deletion(&SessionId("missing".into()))
            .is_err()
    );
    for reference in ["", "a\nb"] {
        assert!(matches!(
            active
                .store
                .complete_session_deletion(&active_session, Some(reference)),
            Err(StoreError::InvalidRequest(_))
        ));
    }
}

#[test]
fn launch_recovery_settles_deletions_a_crash_interrupted() {
    let (mut trashed, _) = reviewed_fixture();
    let trashed_session = trashed.session.clone();
    trashed
        .store
        .begin_session_deletion(&trashed_session)
        .unwrap();
    move_to_trash(&trashed, &trashed_session);
    let mut reopened = SessionStore::open(&trashed.root).unwrap();
    reopened.recover_library().unwrap();
    assert_eq!(rows(&reopened, "segments", &trashed_session), 0);
    assert_eq!(rows(&reopened, "deletion_receipts", &trashed_session), 1);
    assert_eq!(
        rows(&reopened, "session_deletion_intents", &trashed_session),
        0
    );

    let (mut untouched, _) = reviewed_fixture();
    let untouched_session = untouched.session.clone();
    untouched
        .store
        .begin_session_deletion(&untouched_session)
        .unwrap();
    let mut reopened = SessionStore::open(&untouched.root).unwrap();
    reopened.recover_library().unwrap();
    assert_eq!(
        rows(&reopened, "session_deletion_intents", &untouched_session),
        0
    );
    assert_eq!(
        rows(&reopened, "transcript_revisions", &untouched_session),
        1
    );
    assert_eq!(rows(&reopened, "deletion_receipts", &untouched_session), 0);
    assert_eq!(
        reopened
            .search_transcripts("bravo", None, 10)
            .unwrap()
            .len(),
        1
    );
}
