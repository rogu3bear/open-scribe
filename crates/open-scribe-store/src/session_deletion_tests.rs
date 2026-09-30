use super::*;
use crate::transcripts::tests::{
    Fixture, complete_all, identity, imported_fixture, plan, sample, write_caf,
};
use crate::{ImportMediaRequest, SESSIONS_DIRECTORY};
use sha2::{Digest, Sha256};
use std::path::Path;

const SESSION_TABLES: [&str; 16] = [
    "sources",
    "required_sources",
    "tracks",
    "segments",
    "session_events",
    "markers",
    "imports",
    "recovery_runs",
    "transcription_runs",
    "transcript_revisions",
    "transcript_selections",
    "transcript_corrections",
    "speaker_adjudications",
    "transcript_search",
    "session_deletion_intents",
    "deletion_receipts",
];

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

    for table in SESSION_TABLES {
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
