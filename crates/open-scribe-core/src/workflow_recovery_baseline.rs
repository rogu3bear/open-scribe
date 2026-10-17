//! Test-only competent SQLite reference for this one logical fixture. It has
//! durable manual jobs, immutable revisions/corrections, retained hypotheses,
//! transactional admission/completion, and expected-selection CAS. It does
//! not reuse Open Scribe's scheduler, planner, or transcript selection code.
use super::{Reviewed, checkpoint_and_wait};
use rusqlite::{Connection, OptionalExtension, params};
use serde_json::{Value, json};
use std::path::Path;

fn open(root: &Path) -> Connection {
    let connection = Connection::open(root.join("baseline.sqlite3")).unwrap();
    connection
        .execute_batch(
            "PRAGMA journal_mode=WAL; PRAGMA synchronous=FULL;
        PRAGMA foreign_keys=ON;",
        )
        .unwrap();
    connection
}

pub(super) fn seed(root: &Path) {
    crate::transcription::tests::write_burst_caf(&root.join("evidence.caf"), 6 * 48_000);
    open(root)
        .execute_batch(
            "
        CREATE TABLE tracks(id TEXT PRIMARY KEY, selected TEXT, epoch INTEGER NOT NULL);
        CREATE TABLE revisions(id TEXT PRIMARY KEY, track TEXT NOT NULL REFERENCES tracks,
            availability TEXT NOT NULL, text TEXT NOT NULL);
        CREATE TABLE corrections(id TEXT PRIMARY KEY, revision TEXT NOT NULL REFERENCES revisions,
            text TEXT NOT NULL);
        CREATE TABLE runs(id TEXT PRIMARY KEY, track TEXT NOT NULL REFERENCES tracks,
            state TEXT NOT NULL, failure TEXT);
        CREATE TABLE chunks(run TEXT NOT NULL REFERENCES runs, sequence INTEGER NOT NULL,
            complete INTEGER NOT NULL, text TEXT NOT NULL, PRIMARY KEY(run,sequence));
        CREATE TABLE jobs(track TEXT PRIMARY KEY REFERENCES tracks, origin TEXT NOT NULL,
            action TEXT NOT NULL, state TEXT NOT NULL, expected_epoch INTEGER NOT NULL,
            expected_selection TEXT);
        CREATE TRIGGER revisions_immutable BEFORE UPDATE ON revisions BEGIN
            SELECT RAISE(ABORT,'immutable revision'); END;
        CREATE TRIGGER corrections_immutable BEFORE UPDATE ON corrections BEGIN
            SELECT RAISE(ABORT,'immutable correction'); END;
        BEGIN IMMEDIATE;
        INSERT INTO tracks VALUES('A','a-final',1),('B',NULL,0);
        INSERT INTO revisions VALUES('a-final','A','final','Original alpha');
        INSERT INTO corrections VALUES('human-correction','a-final','Reviewed alpha');
        INSERT INTO runs VALUES('a-run','A','complete',NULL),
            ('b-failed','B','failed','storage_error');
        INSERT INTO chunks VALUES('b-failed',0,1,'Retained beta');
        COMMIT;",
        )
        .unwrap();
}

pub(super) fn review(root: &Path) -> Reviewed {
    let connection = open(root);
    let (selection, epoch) = connection
        .query_row("SELECT selected,epoch FROM tracks WHERE id='A'", [], |r| {
            Ok((r.get(0)?, r.get(1)?))
        })
        .unwrap();
    let corrections = connection
        .prepare("SELECT id FROM corrections ORDER BY id")
        .unwrap()
        .query_map([], |r| r.get(0))
        .unwrap()
        .collect::<Result<Vec<String>, _>>()
        .unwrap();
    let effective: String = connection
        .query_row(
            "SELECT COALESCE(
        (SELECT text FROM corrections WHERE revision=r.id ORDER BY rowid DESC LIMIT 1),r.text)
        FROM revisions r JOIN tracks t ON t.selected=r.id WHERE t.id='A'",
            [],
            |r| r.get(0),
        )
        .unwrap();
    // Search uses the effective selected Final document, as in the production
    // fixture. A substring is sufficient for this exact two-word query.
    let hits = connection
        .prepare(
            "SELECT r.id FROM revisions r JOIN tracks t ON t.selected=r.id
        WHERE r.availability='final' AND COALESCE(
          (SELECT text FROM corrections WHERE revision=r.id ORDER BY rowid DESC LIMIT 1),r.text)
          LIKE '%Reviewed alpha%' ORDER BY r.id",
        )
        .unwrap()
        .query_map([], |r| r.get(0))
        .unwrap()
        .collect::<Result<Vec<String>, _>>()
        .unwrap();
    Reviewed {
        selection,
        epoch,
        corrections,
        effective_text: vec![effective],
        search_revisions: hits,
        runs: connection
            .query_row("SELECT count(*) FROM runs WHERE track='A'", [], |r| {
                r.get::<_, i64>(0)
            })
            .unwrap()
            .try_into()
            .unwrap(),
        revisions: connection
            .query_row("SELECT count(*) FROM revisions WHERE track='A'", [], |r| {
                r.get::<_, i64>(0)
            })
            .unwrap()
            .try_into()
            .unwrap(),
    }
}

pub(super) fn admit_and_wait(root: &Path) {
    let mut connection = open(root);
    let transaction = connection
        .transaction_with_behavior(rusqlite::TransactionBehavior::Immediate)
        .unwrap();
    // Resume admits only unfinished tracks and persists selection expectations.
    // There is no in-memory-only queue and no automatic job to resurrect.
    transaction
        .execute(
            "INSERT INTO jobs
        SELECT t.id,'manual','resume','running',t.epoch,t.selected FROM tracks t
        LEFT JOIN revisions r ON r.id=t.selected
        WHERE COALESCE(r.availability,'none')<>'final'
        ON CONFLICT(track) DO NOTHING",
            [],
        )
        .unwrap();
    assert_eq!(
        transaction
            .query_row("SELECT count(*) FROM jobs", [], |r| r.get::<_, i64>(0))
            .unwrap(),
        1
    );
    transaction.commit().unwrap();
    checkpoint_and_wait(root);
    drop(connection);
}

pub(super) fn resume(root: &Path) -> Value {
    let mut connection = open(root);
    let transaction = connection
        .transaction_with_behavior(rusqlite::TransactionBehavior::Immediate)
        .unwrap();
    transaction
        .execute("UPDATE jobs SET state='queued' WHERE state='running'", [])
        .unwrap();
    // Automatic work is disabled. Only the surviving explicit manual request
    // can enter this model-free retained-output path.
    let job: (String, i64, Option<String>) = transaction
        .query_row(
            "SELECT track,expected_epoch,expected_selection FROM jobs
        WHERE origin='manual' AND action='resume' AND state='queued'",
            [],
            |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)),
        )
        .unwrap();
    let incomplete: i64 = transaction
        .query_row(
            "SELECT count(*) FROM chunks
        WHERE run='b-failed' AND complete=0",
            [],
            |r| r.get(0),
        )
        .unwrap();
    assert_eq!(incomplete, 0);
    let text: Option<String> = transaction
        .query_row(
            "SELECT group_concat(text,' ') FROM (SELECT text FROM chunks
         WHERE run='b-failed' ORDER BY sequence)",
            [],
            |r| r.get(0),
        )
        .unwrap();
    let text = text.expect("complete retained hypotheses, no recognizer fallback");
    transaction
        .execute(
            "INSERT INTO revisions VALUES('b-final',?1,'final',?2)",
            params![job.0, text],
        )
        .unwrap();
    // Selection has an expected-epoch CAS, separate from revision creation.
    // This fixture leaves B's selection unchanged, so exactly one row matches.
    assert_eq!(
        transaction
            .execute(
                "UPDATE tracks SET selected='b-final',epoch=epoch+1
        WHERE id=?1 AND epoch=?2 AND selected IS ?3",
                params![job.0, job.1, job.2]
            )
            .unwrap(),
        1
    );
    transaction
        .execute("UPDATE jobs SET state='complete' WHERE track=?1", [&job.0])
        .unwrap();
    transaction.commit().unwrap();
    let selected: Option<String> = connection
        .query_row(
            "SELECT r.text FROM tracks t
        JOIN revisions r ON r.id=t.selected WHERE t.id='B' AND r.availability='final'",
            [],
            |r| r.get(0),
        )
        .optional()
        .unwrap();
    assert_eq!(selected.as_deref(), Some("Retained beta"));
    let historical: String = connection
        .query_row("SELECT failure FROM runs WHERE id='b-failed'", [], |r| {
            r.get(0)
        })
        .unwrap();
    assert_eq!(historical, "storage_error");
    json!({"manual_origin_preserved":true, "recognized_chunks":0,
        "resumed_tracks":1, "repeated_user_actions":0})
}
