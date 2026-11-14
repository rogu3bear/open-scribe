//! SQLite connection policy and the ordered schema migrations.

use super::*;

pub(crate) const SCHEMA_VERSION: i64 = 4;

pub(crate) fn configure_connection(connection: &mut Connection) -> Result<(), StoreError> {
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

/// One idempotent schema step and the migration versions it records. Every
/// step runs on each open; its versions are recorded after it succeeds.
struct Migration {
    versions: &'static [i64],
    apply: fn(&Transaction<'_>) -> Result<(), StoreError>,
}

/// Every schema step, in the order it runs. Version numbers are stored in
/// `schema_migrations` and cited by docs/data-format: a new step takes the
/// next unused number. Order is part of the schema: the selection-epoch
/// triggers (10, 15) attach to review tables (6), and the review step reads
/// whether its own version was already recorded.
const MIGRATIONS: &[Migration] = &[
    Migration {
        versions: &[1, 2, 3, 4],
        apply: apply_base_schema,
    },
    // 19 admits `draft` and `superseded` beside `final` in older libraries.
    Migration {
        versions: &[5, 19],
        apply: transcripts::apply_transcript_schema,
    },
    Migration {
        versions: &[transcript_review::REVIEW_MIGRATION_VERSION],
        apply: transcript_review::apply_review_schema,
    },
    Migration {
        versions: &[7],
        apply: session_deletion::apply_deletion_schema,
    },
    Migration {
        versions: &[8],
        apply: context::apply_context_schema,
    },
    Migration {
        versions: &[9],
        apply: package_restore::apply_restore_schema,
    },
    Migration {
        versions: &[10],
        apply: transcript_selection::apply_schema,
    },
    Migration {
        versions: &[11, 16],
        apply: transcription_work::apply_schema,
    },
    Migration {
        versions: &[12],
        apply: session_times::apply_schema,
    },
    Migration {
        versions: &[13],
        apply: transcription_operation::apply_schema,
    },
    Migration {
        versions: &[14],
        apply: library_recovery::apply_schema,
    },
    Migration {
        versions: &[15],
        apply: transcript_speakers::apply_schema,
    },
    Migration {
        versions: &[17],
        apply: derived_claims::apply_schema,
    },
    Migration {
        versions: &[18],
        apply: meeting_memory::apply_schema,
    },
    Migration {
        versions: &[20],
        apply: speaker_diarization::apply_schema,
    },
    Migration {
        versions: &[21],
        apply: conversation_titles::apply_schema,
    },
];

/// Every table holding a session's rows, in the order confirmed deletion
/// empties them: derived and human-review rows first, then evidence rows in
/// foreign-key order. The session row survives as a tombstone, so its ON
/// DELETE CASCADE never fires, and `deletion_receipts` outlives the session.
/// A new session-scoped table belongs here.
pub(crate) const SESSION_OWNED_TABLES: &[&str] = &[
    "meeting_memory_delta_operations",
    "meeting_memory_delta_receipts",
    "meeting_memory_projection",
    "derived_claim_revisions",
    "transcript_search",
    "speaker_adjudications",
    // Removing people explicitly cascades their append-only names and turn
    // assignments in the same transaction.
    "transcript_named_speakers",
    "transcript_corrections",
    "transcript_selections",
    "transcript_selection_epochs",
    "transcription_runs",
    "transcription_intent",
    "segments",
    "conversation_titles",
    // Diarization tracks reference media tracks without cascade.
    "speaker_diarization_tracks",
    "speaker_diarization_runs",
    "tracks",
    "sources",
    "required_sources",
    "context_events",
    "context_scopes",
    "session_declarations",
    "markers",
    "imports",
    "session_events",
    "recovery_runs",
    "session_restorations",
    "session_metadata_times",
    "session_deletion_intents",
];

pub(crate) fn apply_schema(connection: &mut Connection) -> Result<(), StoreError> {
    // Rebuilding a table needs foreign keys off, which SQLite ignores inside
    // a transaction, so this one step runs before the schema transaction.
    transcripts::migrate_legacy_revision_finality(connection)?;
    let transaction = connection.transaction()?;
    transaction.execute_batch(
        "CREATE TABLE IF NOT EXISTS schema_migrations (
            version INTEGER PRIMARY KEY,
            applied_at_ms INTEGER NOT NULL
        );",
    )?;
    let applied_at = wall_time_milliseconds();
    for migration in MIGRATIONS {
        (migration.apply)(&transaction)?;
        for version in migration.versions {
            transaction.execute(
                "INSERT OR IGNORE INTO schema_migrations (version, applied_at_ms) VALUES (?1, ?2)",
                params![version, applied_at],
            )?;
        }
    }
    transaction.commit()?;
    Ok(())
}

/// Base schema v4: sessions, sources, tracks, segments, events, markers,
/// imports, deletion receipts and recovery runs. Columns added after v1 are
/// added in place to an older library.
fn apply_base_schema(tx: &Transaction<'_>) -> Result<(), StoreError> {
    tx.execute_batch(
        "CREATE TABLE IF NOT EXISTS sessions (
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
        let mut statement = tx.prepare("PRAGMA table_info(segments)")?;
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
            tx.execute_batch(&format!(
                "ALTER TABLE segments ADD COLUMN {name} {declaration};"
            ))?;
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::MIGRATIONS;

    #[test]
    fn migration_versions_are_each_recorded_once() {
        let mut versions: Vec<i64> = MIGRATIONS
            .iter()
            .flat_map(|migration| migration.versions.iter().copied())
            .collect();
        versions.sort_unstable();
        assert_eq!(versions, (1..=21).collect::<Vec<_>>());
    }
}
