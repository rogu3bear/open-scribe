use std::fs::File;
use std::io::Write;
use std::path::{Path, PathBuf};

use rusqlite::Connection;
use sha2::{Digest, Sha256};
use tempfile::TempDir;

use super::*;
use crate::{
    CAF_HEADER, DATABASE_NAME, ImportMediaRequest, JOURNAL_NAME, RecoveryDisposition,
    RuntimeTranscriptState, SESSIONS_DIRECTORY,
};

pub(crate) const SECOND: i64 = 1_000_000_000;

pub(crate) fn write_caf(path: &Path, frames: u64, sample: impl Fn(u64) -> i16) {
    let mut file = File::create(path).unwrap();
    file.write_all(CAF_HEADER).unwrap();
    file.write_all(b"desc").unwrap();
    file.write_all(&32_i64.to_be_bytes()).unwrap();
    file.write_all(&48_000_f64.to_bits().to_be_bytes()).unwrap();
    file.write_all(b"lpcm").unwrap();
    for value in [2_u32, 2, 1, 1, 16] {
        file.write_all(&value.to_be_bytes()).unwrap();
    }
    file.write_all(b"data").unwrap();
    file.write_all(&(-1_i64).to_be_bytes()).unwrap();
    file.write_all(&0_u32.to_be_bytes()).unwrap();
    let bytes: Vec<u8> = (0..frames)
        .flat_map(|frame| sample(frame).to_le_bytes())
        .collect();
    file.write_all(&bytes).unwrap();
    file.sync_all().unwrap();
}

pub(crate) fn sample(frame: u64) -> i16 {
    ((frame % 997) as i16 - 498) * 31
}

pub(crate) struct Fixture {
    _temp: TempDir,
    pub(crate) root: PathBuf,
    pub(crate) store: SessionStore,
    pub(crate) session: SessionId,
    pub(crate) track: String,
    pub(crate) media: PathBuf,
}

pub(crate) fn imported_fixture(frames: u64) -> Fixture {
    let temp = TempDir::new().unwrap();
    let source = temp.path().join("source.caf");
    write_caf(&source, frames, sample);
    let root = temp.path().join("Open Scribe");
    let mut store = SessionStore::open(&root).unwrap();
    let evidence = store
        .import_recoverable_caf(ImportMediaRequest {
            title: "Transcript fixture".into(),
            source_path: source,
        })
        .unwrap();
    let track = store
        .transcription_tracks(&evidence.session_id)
        .unwrap()
        .remove(0);
    let media = root
        .join(SESSIONS_DIRECTORY)
        .join(&evidence.session_id.0)
        .join(&evidence.relative_path);
    Fixture {
        _temp: temp,
        root,
        store,
        session: evidence.session_id,
        track,
        media,
    }
}

pub(crate) fn identity(fixture: &Fixture, options_digest: &str) -> TranscriptionRunIdentity {
    let input = fixture
        .store
        .transcription_input(&fixture.session, &fixture.track)
        .unwrap();
    TranscriptionRunIdentity {
        session_id: fixture.session.clone(),
        track_id: fixture.track.clone(),
        input_digest: input.input_digest,
        engine: "fixture-engine".into(),
        engine_version: "1".into(),
        model_id: "fixture-model".into(),
        model_sha256: "a".repeat(64),
        options_digest: options_digest.into(),
        reconciliation_version: "overlap-midpoint-v1".into(),
    }
}

pub(crate) fn plan() -> Vec<PlannedTranscriptChunk> {
    vec![
        PlannedTranscriptChunk {
            span_index: 0,
            start_nanoseconds: 0,
            end_nanoseconds: 2 * SECOND,
        },
        PlannedTranscriptChunk {
            span_index: 0,
            start_nanoseconds: SECOND,
            end_nanoseconds: 3 * SECOND,
        },
    ]
}

pub(crate) fn hypothesis(text: &str) -> String {
    serde_json::json!({"language": "en", "segments": [{"start_ms": 100, "end_ms": 900, "text": text}]})
        .to_string()
}

fn segment(chunk: &TranscriptChunk, offset: i64, text: &str) -> RevisionSegmentInput {
    RevisionSegmentInput {
        start_nanoseconds: chunk.start_nanoseconds + offset,
        end_nanoseconds: chunk.start_nanoseconds + offset + SECOND / 2,
        text: text.into(),
        mean_probability: Some(0.8),
        no_speech_probability: None,
        chunk_identity: chunk.identity.clone(),
    }
}

pub(crate) fn complete_all(
    fixture: &mut Fixture,
    handle: &TranscriptionRunHandle,
    words: [&str; 2],
) -> String {
    for (chunk, word) in handle.chunks.iter().zip(words) {
        if chunk.state != TranscriptChunkState::Complete {
            fixture
                .store
                .complete_transcript_chunk(&handle.run_id, chunk.sequence, "en", &hypothesis(word))
                .unwrap();
        }
    }
    let segments = [
        segment(&handle.chunks[0], SECOND / 10, words[0]),
        segment(&handle.chunks[1], SECOND, words[1]),
    ];
    fixture
        .store
        .commit_transcript_revision(&handle.run_id, &segments, "{}", "[]")
        .unwrap()
}

fn file_digest(path: &Path) -> String {
    Sha256::digest(std::fs::read(path).unwrap())
        .iter()
        .map(|byte| format!("{byte:02x}"))
        .collect()
}

#[test]
fn background_completion_does_not_replace_a_newer_human_selection() {
    let mut fixture = imported_fixture(144_000);
    let first_identity = identity(&fixture, "first");
    let first = fixture
        .store
        .begin_transcription_run(&first_identity, &plan())
        .unwrap();
    let reviewed = complete_all(&mut fixture, &first, ["reviewed alpha", "reviewed bravo"]);
    let replacement_identity = identity(&fixture, "replacement");
    let replacement = fixture
        .store
        .begin_transcription_run(&replacement_identity, &plan())
        .unwrap();
    // Human explicitly reselects the reviewed document while derived work runs.
    fixture
        .store
        .select_transcript_revision(&fixture.session, &fixture.track, &reviewed)
        .unwrap();
    let completed = complete_all(&mut fixture, &replacement, ["raw replacement", "raw tail"]);
    let revisions = fixture
        .store
        .transcript_revisions(&fixture.session)
        .unwrap();
    assert!(
        revisions
            .iter()
            .find(|revision| revision.revision_id == reviewed)
            .unwrap()
            .selected
    );
    assert!(
        !revisions
            .iter()
            .find(|revision| revision.revision_id == completed)
            .unwrap()
            .selected
    );
}

#[test]
fn cancellation_wins_selection_even_when_a_completed_revision_crosses_the_stop_boundary() {
    let mut fixture = imported_fixture(144_000);
    let run = fixture
        .store
        .begin_transcription_run(&identity(&fixture, "cancel-commit"), &plan())
        .unwrap();
    fixture
        .store
        .cancel_transcription(&fixture.session)
        .unwrap();
    let revision = complete_all(&mut fixture, &run, ["alpha", "bravo"]);
    let history = fixture
        .store
        .transcript_revisions(&fixture.session)
        .unwrap();
    assert!(
        history
            .iter()
            .any(|r| r.revision_id == revision && !r.selected)
    );
    assert!(
        fixture
            .store
            .transcript_document(&fixture.session)
            .unwrap()
            .is_empty()
    );
    assert!(
        fixture
            .store
            .search_transcripts("alpha", Some(&fixture.session), 10)
            .unwrap()
            .is_empty()
    );
    assert_eq!(
        fixture.store.transcription_outcomes().unwrap(),
        [(
            fixture.session.0.clone(),
            open_scribe_types::WorkOutcome::UserCancelled,
            None
        )]
    );
}

#[test]
fn sealed_input_reads_exact_samples_and_rejects_changed_media() {
    let fixture = imported_fixture(144_000);
    let input = fixture
        .store
        .transcription_input(&fixture.session, &fixture.track)
        .unwrap();
    assert_eq!(input.channels, 1);
    assert_eq!(input.spans.len(), 1);
    assert_eq!(
        (input.spans[0].start_nanoseconds, input.spans[0].frames),
        (0, 144_000)
    );
    assert_eq!(
        input,
        fixture
            .store
            .transcription_input(&fixture.session, &fixture.track)
            .unwrap()
    );

    let reader = fixture.store.open_transcription_input(&input).unwrap();
    let frames = reader.read_frames(0, 47_990, 48_010).unwrap();
    assert_eq!(frames, (47_990..48_010).map(sample).collect::<Vec<_>>());
    assert!(reader.read_frames(0, 143_999, 144_001).is_err());
    assert!(reader.read_frames(1, 0, 1).is_err());
    drop(reader);

    let mut bytes = std::fs::read(&fixture.media).unwrap();
    let last = bytes.len() - 1;
    bytes[last] ^= 0x01;
    std::fs::write(&fixture.media, bytes).unwrap();
    assert!(fixture.store.open_transcription_input(&input).is_err());
}

#[test]
fn interrupted_runs_resume_from_committed_chunks_and_revisions_are_immutable() {
    let mut fixture = imported_fixture(144_000);
    let media_before = file_digest(&fixture.media);
    let identity = identity(&fixture, "options-a");
    let handle = fixture
        .store
        .begin_transcription_run(&identity, &plan())
        .unwrap();
    assert!(!handle.resumed);
    assert!(
        handle
            .chunks
            .iter()
            .all(|chunk| chunk.state == TranscriptChunkState::Pending)
    );
    fixture
        .store
        .mark_transcript_chunk_running(&handle.run_id, 0)
        .unwrap();
    fixture
        .store
        .complete_transcript_chunk(&handle.run_id, 0, "en", &hypothesis("alpha"))
        .unwrap();
    fixture
        .store
        .mark_transcript_chunk_running(&handle.run_id, 1)
        .unwrap();

    // The process dies mid-inference; a later identical request resumes.
    let root = fixture.root.clone();
    fixture.store = SessionStore::open(&root).unwrap();
    let resumed = fixture
        .store
        .begin_transcription_run(&identity, &plan())
        .unwrap();
    assert!(resumed.resumed);
    assert_eq!(resumed.run_id, handle.run_id);
    assert_eq!(resumed.chunks[0].state, TranscriptChunkState::Complete);
    assert_eq!(resumed.chunks[1].state, TranscriptChunkState::Pending);
    assert!(
        fixture
            .store
            .complete_transcript_chunk(&handle.run_id, 0, "en", &hypothesis("replaced"))
            .is_err()
    );

    let revision = complete_all(&mut fixture, &resumed, ["alpha", "bravo"]);
    let selected = fixture.store.selected_transcript(&fixture.session).unwrap();
    assert_eq!(
        selected
            .iter()
            .map(|segment| segment.text.as_str())
            .collect::<Vec<_>>(),
        ["alpha", "bravo"]
    );
    assert_eq!(selected[1].start_nanoseconds, 2 * SECOND);
    assert!(
        fixture
            .store
            .connection
            .execute("UPDATE transcript_segments SET text = 'edited'", [])
            .is_err()
    );
    assert!(
        fixture
            .store
            .connection
            .execute("UPDATE transcript_revisions SET finality = 'final'", [])
            .is_err()
    );
    assert!(
        fixture
            .store
            .connection
            .execute("UPDATE transcription_runs SET state = 'running'", [])
            .is_err()
    );
    assert!(
        fixture
            .store
            .begin_transcription_run(&identity, &plan())
            .is_ok()
    );
    assert_eq!(
        fixture
            .store
            .transcript_revision_segments(&revision)
            .unwrap()
            .len(),
        2
    );
    assert_eq!(file_digest(&fixture.media), media_before);
}

#[test]
fn failed_runs_keep_their_evidence_and_retries_reuse_only_matching_chunks() {
    let mut fixture = imported_fixture(144_000);
    let identity = identity(&fixture, "options-a");
    let failed = fixture
        .store
        .begin_transcription_run(&identity, &plan())
        .unwrap();
    fixture
        .store
        .complete_transcript_chunk(&failed.run_id, 0, "en", &hypothesis("alpha"))
        .unwrap();
    fixture
        .store
        .fail_transcription_run(&failed.run_id, Some(1), TranscriptionFailure::EngineError)
        .unwrap();
    assert!(
        fixture
            .store
            .selected_transcript(&fixture.session)
            .unwrap()
            .is_empty()
    );
    assert!(
        fixture
            .store
            .complete_transcript_chunk(&failed.run_id, 1, "en", &hypothesis("late"))
            .is_err()
    );

    let retry = fixture
        .store
        .begin_transcription_run(&identity, &plan())
        .unwrap();
    assert!(!retry.resumed);
    assert_ne!(retry.run_id, failed.run_id);
    assert_eq!(retry.chunks[0].state, TranscriptChunkState::Complete);
    assert_eq!(
        retry.chunks[0].reused_from_run.as_deref(),
        Some(failed.run_id.as_str())
    );
    assert_eq!(retry.chunks[1].state, TranscriptChunkState::Pending);
    complete_all(&mut fixture, &retry, ["alpha", "bravo"]);

    let runs = fixture.store.transcription_runs(&fixture.session).unwrap();
    assert_eq!(runs[0].state, "failed");
    assert_eq!(runs[0].failure_class.as_deref(), Some("engine_error"));
    assert_eq!((runs[0].completed_chunks, runs[0].total_chunks), (1, 2));
    assert_eq!(runs[1].state, "complete");

    let other_options = super::TranscriptionRunIdentity {
        options_digest: "options-b".into(),
        ..identity
    };
    let fresh = fixture
        .store
        .begin_transcription_run(&other_options, &plan())
        .unwrap();
    assert!(
        fresh
            .chunks
            .iter()
            .all(|chunk| chunk.state == TranscriptChunkState::Pending)
    );
}

#[test]
fn replacement_never_displaces_the_selected_revision_until_it_completes() {
    let mut fixture = imported_fixture(144_000);
    let first_identity = identity(&fixture, "options-a");
    let first_run = fixture
        .store
        .begin_transcription_run(&first_identity, &plan())
        .unwrap();
    let first = complete_all(&mut fixture, &first_run, ["alpha", "bravo"]);

    let replacement_identity = TranscriptionRunIdentity {
        model_id: "replacement-model".into(),
        model_sha256: "b".repeat(64),
        ..first_identity
    };
    let cancelled = fixture
        .store
        .begin_transcription_run(&replacement_identity, &plan())
        .unwrap();
    fixture
        .store
        .complete_transcript_chunk(&cancelled.run_id, 0, "en", &hypothesis("charlie"))
        .unwrap();
    fixture
        .store
        .fail_transcription_run(&cancelled.run_id, None, TranscriptionFailure::Cancelled)
        .unwrap();
    let still_selected = fixture.store.selected_transcript(&fixture.session).unwrap();
    assert!(
        still_selected
            .iter()
            .all(|segment| segment.revision_id == first)
    );

    let replacement = fixture
        .store
        .begin_transcription_run(&replacement_identity, &plan())
        .unwrap();
    let second = complete_all(&mut fixture, &replacement, ["charlie", "delta"]);
    let revisions = fixture
        .store
        .transcript_revisions(&fixture.session)
        .unwrap();
    assert_eq!(revisions.len(), 2);
    assert!(!revisions[0].selected && revisions[1].selected);
    assert_eq!(revisions[1].revision_id, second);
    assert_eq!(
        fixture.store.transcript_revision_segments(&first).unwrap()[0].text,
        "alpha"
    );

    fixture
        .store
        .select_transcript_revision(&fixture.session, &fixture.track, &first)
        .unwrap();
    assert_eq!(
        fixture.store.selected_transcript(&fixture.session).unwrap()[0].text,
        "alpha"
    );
    assert!(
        fixture
            .store
            .select_transcript_revision(&fixture.session, "another-track", &first)
            .is_err()
    );
}

#[test]
fn revisions_and_plans_are_validated_against_the_sealed_input() {
    let mut fixture = imported_fixture(144_000);
    let identity = identity(&fixture, "options-a");
    let wrong_input = TranscriptionRunIdentity {
        input_digest: "0".repeat(64),
        ..identity.clone()
    };
    assert!(matches!(
        fixture.store.begin_transcription_run(&wrong_input, &plan()),
        Err(StoreError::IntegrityMismatch(_))
    ));
    let mut unordered = plan();
    unordered.reverse();
    assert!(
        fixture
            .store
            .begin_transcription_run(&identity, &unordered)
            .is_err()
    );
    assert!(
        fixture
            .store
            .begin_transcription_run(&identity, &[])
            .is_err()
    );

    let handle = fixture
        .store
        .begin_transcription_run(&identity, &plan())
        .unwrap();
    let early = [segment(&handle.chunks[0], 0, "alpha")];
    assert!(
        fixture
            .store
            .commit_transcript_revision(&handle.run_id, &early, "{}", "[]")
            .is_err()
    );
    for chunk in &handle.chunks {
        fixture
            .store
            .complete_transcript_chunk(&handle.run_id, chunk.sequence, "en", &hypothesis("x"))
            .unwrap();
    }
    let mut foreign = segment(&handle.chunks[0], 0, "alpha");
    foreign.chunk_identity = "f".repeat(64);
    let outside = segment(&handle.chunks[0], 2 * SECOND, "alpha");
    let blank = segment(&handle.chunks[0], 0, "   ");
    for bad in [foreign, outside, blank] {
        assert!(
            fixture
                .store
                .commit_transcript_revision(&handle.run_id, &[bad], "{}", "[]")
                .is_err()
        );
    }
    assert!(
        fixture
            .store
            .commit_transcript_revision(&handle.run_id, &[], "not json", "[]")
            .is_err()
    );
}

#[test]
fn schema_v4_fixture_migrates_without_rewriting_sealed_evidence() {
    let temp = TempDir::new().unwrap();
    let root = temp.path().join("Open Scribe");
    let session = "01a0ef0d-2600-76c4-8f7e-de8905518c51";
    let track = "01a0ef0d-2610-77cf-88eb-59e1220757d7";
    let fixture_dir = Path::new(env!("CARGO_MANIFEST_DIR")).join("fixtures/schema-v4");
    let session_dir = root.join(SESSIONS_DIRECTORY).join(session);
    std::fs::create_dir_all(session_dir.join("audio").join(track)).unwrap();
    for directory in ["video", "context", "exports"] {
        std::fs::create_dir_all(session_dir.join(directory)).unwrap();
    }
    std::fs::copy(
        fixture_dir.join("recovery.jsonl"),
        session_dir.join(JOURNAL_NAME),
    )
    .unwrap();
    let media = session_dir
        .join("audio")
        .join(track)
        .join("000000-import.caf");
    write_caf(&media, 48_000, |frame| ((frame % 480) as i16 - 240) * 64);
    assert_eq!(
        file_digest(&media),
        "a8c794f178230c3f9e629e1366cf7c6891f1294a3d1eed283df1554fbeaa2587"
    );
    let database = root.join(DATABASE_NAME);
    Connection::open(&database)
        .unwrap()
        .execute_batch(&std::fs::read_to_string(fixture_dir.join("Library.sql")).unwrap())
        .unwrap();

    let evidence_tables = [
        "sessions",
        "sources",
        "required_sources",
        "tracks",
        "segments",
        "session_events",
        "markers",
        "imports",
        "deletion_receipts",
        "recovery_runs",
    ];
    let dump = |connection: &Connection| -> Vec<String> {
        evidence_tables
            .iter()
            .flat_map(|table| {
                let mut statement = connection
                    .prepare(&format!("SELECT * FROM {table} ORDER BY rowid"))
                    .unwrap();
                let columns = statement.column_count();
                statement
                    .query_map([], |row| {
                        let values: Vec<String> = (0..columns)
                            .map(|index| format!("{:?}", row.get_ref(index).unwrap()))
                            .collect();
                        Ok(format!("{table}:{}", values.join("|")))
                    })
                    .unwrap()
                    .map(Result::unwrap)
                    .collect::<Vec<_>>()
            })
            .collect()
    };
    let before = dump(&Connection::open(&database).unwrap());
    assert!(before.iter().any(|row| row.starts_with("segments:")));

    for _ in 0..2 {
        let store = SessionStore::open(&root).unwrap();
        assert_eq!(dump(&store.connection), before);
        let versions: Vec<i64> = store
            .connection
            .prepare("SELECT version FROM schema_migrations ORDER BY version")
            .unwrap()
            .query_map([], |row| row.get(0))
            .unwrap()
            .map(Result::unwrap)
            .collect();
        assert_eq!(versions, (1..=16).collect::<Vec<_>>());
        let derived: i64 = store
            .connection
            .query_row(
                "SELECT (SELECT COUNT(*) FROM transcription_runs)
                      + (SELECT COUNT(*) FROM transcript_revisions)
                      + (SELECT COUNT(*) FROM transcript_selections)
                      + (SELECT COUNT(*) FROM transcript_corrections)
                      + (SELECT COUNT(*) FROM speaker_adjudications)
                      + (SELECT COUNT(*) FROM transcript_named_speakers)
                      + (SELECT COUNT(*) FROM transcript_speaker_names)
                      + (SELECT COUNT(*) FROM transcript_turn_speakers)
                      + (SELECT COUNT(*) FROM transcript_search)",
                [],
                |row| row.get(0),
            )
            .unwrap();
        assert_eq!(derived, 0);
        assert_eq!(
            store
                .transcription_tracks(&SessionId(session.into()))
                .unwrap(),
            [track]
        );
    }
    assert_eq!(
        file_digest(&media),
        "a8c794f178230c3f9e629e1366cf7c6891f1294a3d1eed283df1554fbeaa2587"
    );
}

#[test]
fn launch_fails_incomplete_running_transcription_as_orphaned() {
    let mut fixture = imported_fixture(144_000);
    let identity = identity(&fixture, "options-a");
    let handle = fixture
        .store
        .begin_transcription_run(&identity, &plan())
        .unwrap();
    fixture
        .store
        .complete_transcript_chunk(&handle.run_id, 0, "en", &hypothesis("alpha"))
        .unwrap();
    // Chunk 1 stays pending — Class B incomplete orphan.

    let recovery = fixture.store.recover_library().unwrap();
    assert!(
        recovery.pending_transcript_finalizations.is_empty(),
        "incomplete runs are not Class A"
    );
    assert_eq!(
        fixture.store.transcription_runs(&fixture.session).unwrap()[0].state,
        "running",
        "capture-safety recovery does not gate media on derived maintenance"
    );
    let (_, findings) = fixture.store.recover_orphan_transcription_runs().unwrap();
    let runs = fixture.store.transcription_runs(&fixture.session).unwrap();
    assert_eq!(runs.len(), 1);
    assert_eq!(runs[0].state, "failed");
    assert_eq!(runs[0].failure_class.as_deref(), Some("orphaned"));
    assert_eq!(
        findings
            .iter()
            .find(|finding| finding.session_id == fixture.session)
            .map(|finding| finding.disposition),
        Some(RecoveryDisposition::TranscriptRunOrphaned)
    );

    // Same-identity resume reuses the complete chunk; no hand SQL.
    let retry = fixture
        .store
        .begin_transcription_run(&identity, &plan())
        .unwrap();
    assert!(!retry.resumed);
    assert_eq!(retry.chunks[0].state, TranscriptChunkState::Complete);
    assert_eq!(
        retry.chunks[0].reused_from_run.as_deref(),
        Some(handle.run_id.as_str())
    );
    assert_eq!(retry.chunks[1].state, TranscriptChunkState::Pending);
}

#[test]
fn launch_queues_complete_chunk_running_runs_for_finalize() {
    let mut fixture = imported_fixture(144_000);
    let identity = identity(&fixture, "options-a");
    let handle = fixture
        .store
        .begin_transcription_run(&identity, &plan())
        .unwrap();
    fixture
        .store
        .complete_transcript_chunk(&handle.run_id, 0, "en", &hypothesis("alpha"))
        .unwrap();
    fixture
        .store
        .complete_transcript_chunk(&handle.run_id, 1, "en", &hypothesis("bravo"))
        .unwrap();

    let recovery = fixture.store.recover_library().unwrap();
    assert!(recovery.pending_transcript_finalizations.is_empty());
    let (pending, _) = fixture.store.recover_orphan_transcription_runs().unwrap();
    assert_eq!(pending, vec![handle.run_id.clone()]);
    let runs = fixture.store.transcription_runs(&fixture.session).unwrap();
    assert_eq!(
        runs[0].state, "running",
        "Class A stays running for core finalize"
    );
    assert!(runs[0].failure_class.is_none());
}

#[test]
fn chunk_progress_bumps_run_updated_at() {
    let mut fixture = imported_fixture(144_000);
    let identity = identity(&fixture, "options-a");
    let handle = fixture
        .store
        .begin_transcription_run(&identity, &plan())
        .unwrap();
    let created: i64 = fixture
        .store
        .connection
        .query_row(
            "SELECT created_at_ms FROM transcription_runs WHERE id = ?1",
            [&handle.run_id],
            |row| row.get(0),
        )
        .unwrap();
    let updated_before: i64 = fixture
        .store
        .connection
        .query_row(
            "SELECT updated_at_ms FROM transcription_runs WHERE id = ?1",
            [&handle.run_id],
            |row| row.get(0),
        )
        .unwrap();
    assert_eq!(created, updated_before);
    std::thread::sleep(std::time::Duration::from_millis(2));
    fixture
        .store
        .complete_transcript_chunk(&handle.run_id, 0, "en", &hypothesis("alpha"))
        .unwrap();
    let updated_after: i64 = fixture
        .store
        .connection
        .query_row(
            "SELECT updated_at_ms FROM transcription_runs WHERE id = ?1",
            [&handle.run_id],
            |row| row.get(0),
        )
        .unwrap();
    assert!(updated_after > updated_before);
}

fn complete_every_chunk(fixture: &mut Fixture, handle: &TranscriptionRunHandle) {
    for (chunk, word) in handle.chunks.iter().zip(["alpha", "bravo"]) {
        if chunk.state != TranscriptChunkState::Complete {
            fixture
                .store
                .complete_transcript_chunk(&handle.run_id, chunk.sequence, "en", &hypothesis(word))
                .unwrap();
        }
    }
}

#[test]
fn retained_candidates_select_the_newest_complete_stale_run_per_unselected_track() {
    let current = "overlap-midpoint-v3";
    let mut fixture = imported_fixture(144_000);
    let stale = identity(&fixture, "options-a");
    assert_ne!(stale.reconciliation_version, current);

    // A stale run whose chunks are all durable is a candidate while it still
    // reports running and after it failed to commit.
    let first = fixture
        .store
        .begin_transcription_run(&stale, &plan())
        .unwrap();
    complete_every_chunk(&mut fixture, &first);
    assert_eq!(
        fixture
            .store
            .retained_transcript_candidates(current)
            .unwrap(),
        vec![first.run_id.clone()]
    );
    fixture
        .store
        .fail_transcription_run(&first.run_id, None, TranscriptionFailure::InvalidResult)
        .unwrap();
    assert_eq!(
        fixture
            .store
            .retained_transcript_candidates(current)
            .unwrap(),
        vec![first.run_id.clone()]
    );
    assert!(
        fixture
            .store
            .retained_transcript_candidates(&stale.reconciliation_version)
            .unwrap()
            .is_empty(),
        "a run under the current version is not stale"
    );

    // Only the newest complete stale run per track is offered.
    std::thread::sleep(std::time::Duration::from_millis(2));
    let second = fixture
        .store
        .begin_transcription_run(&stale, &plan())
        .unwrap();
    assert!(
        second
            .chunks
            .iter()
            .all(|chunk| chunk.state == TranscriptChunkState::Complete)
    );
    fixture
        .store
        .fail_transcription_run(&second.run_id, None, TranscriptionFailure::InvalidResult)
        .unwrap();
    // An incomplete stale run, newer still, never qualifies.
    std::thread::sleep(std::time::Duration::from_millis(2));
    let partial = fixture
        .store
        .begin_transcription_run(&identity(&fixture, "options-b"), &plan())
        .unwrap();
    fixture
        .store
        .complete_transcript_chunk(&partial.run_id, 0, "en", &hypothesis("alpha"))
        .unwrap();
    fixture
        .store
        .fail_transcription_run(&partial.run_id, None, TranscriptionFailure::EngineError)
        .unwrap();
    assert_eq!(
        fixture
            .store
            .retained_transcript_candidates(current)
            .unwrap(),
        vec![second.run_id.clone()]
    );

    // A successor under the current version for the same identity retires
    // the candidate, and a selected revision keeps the track out entirely.
    let successor = fixture
        .store
        .begin_transcription_run(
            &TranscriptionRunIdentity {
                reconciliation_version: current.into(),
                ..stale.clone()
            },
            &plan(),
        )
        .unwrap();
    assert!(
        successor
            .chunks
            .iter()
            .all(|chunk| chunk.reused_from_run.is_some())
    );
    assert!(
        fixture
            .store
            .retained_transcript_candidates(current)
            .unwrap()
            .is_empty()
    );
    complete_all(&mut fixture, &successor, ["alpha", "bravo"]);
    let other = fixture
        .store
        .begin_transcription_run(&identity(&fixture, "options-c"), &plan())
        .unwrap();
    complete_every_chunk(&mut fixture, &other);
    assert!(
        fixture
            .store
            .retained_transcript_candidates(current)
            .unwrap()
            .is_empty()
    );
    let record = fixture
        .store
        .transcription_run_record(&second.run_id)
        .unwrap();
    assert_eq!(record.identity, stale);
    assert_eq!(record.plan, plan());
    assert_eq!(record.state, "failed");
    assert_eq!(record.failure_class.as_deref(), Some("invalid_result"));
    assert_eq!((record.complete_chunks, record.total_chunks), (2, 2));
    assert!(matches!(
        fixture.store.transcription_run_record("missing"),
        Err(StoreError::InvalidState(_))
    ));
}

#[test]
fn runtime_snapshot_reports_transcript_posture_from_runs_and_selections() {
    let mut fixture = imported_fixture(144_000);
    let posture = |fixture: &Fixture| {
        fixture
            .store
            .runtime_library_snapshot()
            .unwrap()
            .saved_sessions
            .into_iter()
            .find(|session| session.session_id == fixture.session)
            .unwrap()
            .transcript
    };
    let none = posture(&fixture);
    assert_eq!(none.state, RuntimeTranscriptState::None);
    assert_eq!((none.total_tracks, none.final_tracks), (1, 0));

    let handle = fixture
        .store
        .begin_transcription_run(&identity(&fixture, "options-a"), &plan())
        .unwrap();
    fixture
        .store
        .complete_transcript_chunk(&handle.run_id, 0, "en", &hypothesis("alpha"))
        .unwrap();
    let running = posture(&fixture);
    assert_eq!(running.state, RuntimeTranscriptState::Running);
    assert_eq!((running.completed_chunks, running.total_chunks), (1, 2));
    assert!(running.failure_class.is_none());

    fixture
        .store
        .fail_transcription_run(&handle.run_id, Some(1), TranscriptionFailure::EngineError)
        .unwrap();
    let failed = posture(&fixture);
    assert_eq!(failed.state, RuntimeTranscriptState::Failed);
    assert_eq!(failed.failure_class.as_deref(), Some("engine_error"));
    assert_eq!((failed.completed_chunks, failed.total_chunks), (0, 0));

    let stopped = fixture
        .store
        .begin_transcription_run(&identity(&fixture, "options-a"), &plan())
        .unwrap();
    fixture
        .store
        .fail_transcription_run(&stopped.run_id, None, TranscriptionFailure::Cancelled)
        .unwrap();
    let cancelled = posture(&fixture);
    assert_eq!(cancelled.state, RuntimeTranscriptState::Cancelled);
    assert!(cancelled.failure_class.is_none());

    let retry = fixture
        .store
        .begin_transcription_run(&identity(&fixture, "options-a"), &plan())
        .unwrap();
    let revision = complete_all(&mut fixture, &retry, ["alpha", "bravo"]);
    let final_posture = posture(&fixture);
    assert_eq!(final_posture.state, RuntimeTranscriptState::Final);
    assert_eq!(
        (final_posture.total_tracks, final_posture.final_tracks),
        (1, 1)
    );
    assert!(final_posture.failure_class.is_none());
    let revisions = fixture
        .store
        .transcript_revisions(&fixture.session)
        .unwrap();
    assert_eq!(revisions.len(), 1);
    assert_eq!(revisions[0].revision_id, revision);
    assert_eq!(revisions[0].reconciliation_version, "overlap-midpoint-v1");
    let replacement = fixture
        .store
        .begin_transcription_run(&identity(&fixture, "replacement"), &plan())
        .unwrap();
    let during = posture(&fixture);
    assert_eq!(during.state, RuntimeTranscriptState::Final);
    assert_eq!(during.attempt, open_scribe_types::AttemptState::Running);
    fixture
        .store
        .fail_transcription_run(&replacement.run_id, None, TranscriptionFailure::EngineError)
        .unwrap();
    let after = posture(&fixture);
    assert_eq!(after.state, RuntimeTranscriptState::Final);
    assert_eq!(after.attempt, open_scribe_types::AttemptState::Failed);
    assert_eq!(after.attempt_failure.as_deref(), Some("engine_error"));
    assert!(
        !fixture
            .store
            .transcript_document(&fixture.session)
            .unwrap()
            .is_empty()
    );
}

#[test]
fn accepted_capture_preemption_projects_honestly_without_rewriting_engine_history() {
    use open_scribe_types::{
        AttemptState, ModelReadiness, TranscriptionIntent, WorkObservations, WorkOutcome,
    };
    let mut fixture = imported_fixture(144_000);
    let first = fixture
        .store
        .begin_transcription_run(&identity(&fixture, "first"), &plan())
        .unwrap();
    let revision = complete_all(&mut fixture, &first, ["reviewed", "document"]);
    fixture
        .store
        .request_transcription(&fixture.session, TranscriptionIntent::ReprocessAll)
        .unwrap();
    let claim = fixture
        .store
        .admit_transcription(WorkObservations {
            automatic: false,
            model: ModelReadiness::Ready,
            ..Default::default()
        })
        .unwrap()
        .unwrap();
    let replacement = fixture
        .store
        .begin_transcription_run(&identity(&fixture, "replacement"), &plan())
        .unwrap();
    // The recognizer's cancellation channel does not carry the native stop reason.
    fixture
        .store
        .fail_transcription_run(&replacement.run_id, None, TranscriptionFailure::Cancelled)
        .unwrap();
    fixture
        .store
        .finish_transcription(
            claim.admission.as_deref().unwrap(),
            WorkOutcome::CapturePreempted,
        )
        .unwrap();
    let snapshot = fixture
        .store
        .runtime_library_snapshot()
        .unwrap()
        .saved_sessions
        .remove(0)
        .transcript;
    assert_eq!(snapshot.state, RuntimeTranscriptState::Final);
    assert_eq!(snapshot.selected_revision_ids, [revision]);
    assert_eq!(snapshot.attempt, AttemptState::Preempted);
    assert_eq!(
        fixture
            .store
            .transcription_run_record(&replacement.run_id)
            .unwrap()
            .failure_class
            .as_deref(),
        Some("cancelled")
    );
}
