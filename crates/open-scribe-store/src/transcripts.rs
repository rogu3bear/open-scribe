//! Derived final-transcript storage (ADR 0009).
//!
//! Verbatim machine output is interpretation over sealed media, never media
//! authority. Every chunk commits on its own; a complete chunk, a finished
//! run, a revision, and its segments are immutable. Retry and replacement
//! create new runs, and a session track's selected revision changes only when
//! a replacement has completed. Rows cascade from their session so a future
//! deletion removes all derived text with it; the search projection in
//! `transcript_review` has no foreign keys and is cleared explicitly.

use super::transcript_review::reindex_session_search;
use super::{SessionStore, StoreError, wall_time_milliseconds};
use open_scribe_types::SessionId;
use rusqlite::{OptionalExtension, Transaction, params};
use sha2::{Digest, Sha256};
use uuid::Uuid;

pub const TRANSCRIPT_SCHEMA_VERSION: i64 = 1;
pub(super) const TRANSCRIPT_MIGRATION_VERSION: i64 = 5;

pub(super) fn apply_transcript_schema(transaction: &Transaction<'_>) -> Result<(), StoreError> {
    transaction.execute_batch(
        "CREATE TABLE IF NOT EXISTS transcription_runs (
            id TEXT PRIMARY KEY,
            schema_version INTEGER NOT NULL,
            session_id TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
            track_id TEXT NOT NULL,
            identity TEXT NOT NULL,
            input_digest TEXT NOT NULL,
            engine TEXT NOT NULL,
            engine_version TEXT NOT NULL,
            model_id TEXT NOT NULL,
            model_sha256 TEXT NOT NULL,
            options_digest TEXT NOT NULL,
            reconciliation_version TEXT NOT NULL,
            state TEXT NOT NULL CHECK (state IN ('running', 'complete', 'failed', 'cancelled')),
            failure_class TEXT,
            created_at_ms INTEGER NOT NULL,
            updated_at_ms INTEGER NOT NULL
        );
        CREATE INDEX IF NOT EXISTS transcription_runs_by_track
            ON transcription_runs(session_id, track_id, state);
        CREATE TABLE IF NOT EXISTS transcript_chunks (
            run_id TEXT NOT NULL REFERENCES transcription_runs(id) ON DELETE CASCADE,
            sequence INTEGER NOT NULL,
            identity TEXT NOT NULL,
            span_index INTEGER NOT NULL,
            start_ns INTEGER NOT NULL,
            end_ns INTEGER NOT NULL,
            state TEXT NOT NULL CHECK (state IN ('pending', 'running', 'complete', 'failed')),
            language TEXT,
            hypothesis_json TEXT,
            reused_from_run TEXT,
            failure_class TEXT,
            updated_at_ms INTEGER NOT NULL,
            PRIMARY KEY (run_id, sequence),
            CHECK (end_ns > start_ns),
            CHECK ((state = 'complete') = (hypothesis_json IS NOT NULL))
        );
        CREATE INDEX IF NOT EXISTS transcript_chunks_by_identity
            ON transcript_chunks(identity, state);
        CREATE TABLE IF NOT EXISTS transcript_revisions (
            id TEXT PRIMARY KEY,
            schema_version INTEGER NOT NULL,
            session_id TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
            track_id TEXT NOT NULL,
            run_id TEXT NOT NULL UNIQUE REFERENCES transcription_runs(id) ON DELETE CASCADE,
            kind TEXT NOT NULL CHECK (kind = 'verbatim'),
            finality TEXT NOT NULL CHECK (finality = 'final'),
            reconciliation_version TEXT NOT NULL,
            rejections_json TEXT NOT NULL,
            discontinuities_json TEXT NOT NULL,
            created_at_ms INTEGER NOT NULL
        );
        CREATE TABLE IF NOT EXISTS transcript_segments (
            revision_id TEXT NOT NULL REFERENCES transcript_revisions(id) ON DELETE CASCADE,
            sequence INTEGER NOT NULL,
            start_ns INTEGER NOT NULL,
            end_ns INTEGER NOT NULL,
            text TEXT NOT NULL,
            mean_probability REAL,
            no_speech_probability REAL,
            chunk_identity TEXT NOT NULL,
            PRIMARY KEY (revision_id, sequence),
            CHECK (end_ns >= start_ns)
        );
        CREATE TABLE IF NOT EXISTS transcript_selections (
            session_id TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
            track_id TEXT NOT NULL,
            revision_id TEXT NOT NULL REFERENCES transcript_revisions(id) ON DELETE CASCADE,
            selected_at_ms INTEGER NOT NULL,
            PRIMARY KEY (session_id, track_id)
        );
        CREATE TRIGGER IF NOT EXISTS transcript_revisions_immutable
            BEFORE UPDATE ON transcript_revisions
            BEGIN SELECT RAISE(ABORT, 'transcript revisions are immutable'); END;
        CREATE TRIGGER IF NOT EXISTS transcript_segments_immutable
            BEFORE UPDATE ON transcript_segments
            BEGIN SELECT RAISE(ABORT, 'transcript segments are immutable'); END;
        CREATE TRIGGER IF NOT EXISTS transcript_chunks_complete_immutable
            BEFORE UPDATE ON transcript_chunks WHEN OLD.state = 'complete'
            BEGIN SELECT RAISE(ABORT, 'complete transcript chunks are immutable'); END;
        CREATE TRIGGER IF NOT EXISTS transcription_runs_finished_immutable
            BEFORE UPDATE ON transcription_runs WHEN OLD.state <> 'running'
            BEGIN SELECT RAISE(ABORT, 'finished transcription runs are immutable'); END;",
    )?;
    Ok(())
}

/// Everything that determines a run's output. Chunk identities derive from
/// it, so a changed model, media, or option can never reuse a checkpoint.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct TranscriptionRunIdentity {
    pub session_id: SessionId,
    pub track_id: String,
    pub input_digest: String,
    pub engine: String,
    pub engine_version: String,
    pub model_id: String,
    pub model_sha256: String,
    pub options_digest: String,
    pub reconciliation_version: String,
}

impl TranscriptionRunIdentity {
    pub(super) fn digest(&self) -> String {
        digest_fields(
            b"open-scribe.transcription-run/v1",
            &[
                &self.session_id.0,
                &self.track_id,
                &self.input_digest,
                &self.engine,
                &self.engine_version,
                &self.model_id,
                &self.model_sha256,
                &self.options_digest,
                &self.reconciliation_version,
            ],
        )
    }

    /// Deterministic chunk ID from session, track input, model, engine,
    /// options, and session range. Reconciliation does not affect chunks.
    pub fn chunk_identity(&self, span_index: u32, start: i64, end: i64) -> String {
        digest_fields(
            b"open-scribe.transcript-chunk/v1",
            &[
                &self.session_id.0,
                &self.track_id,
                &self.input_digest,
                &self.engine,
                &self.engine_version,
                &self.model_sha256,
                &self.options_digest,
                &span_index.to_string(),
                &start.to_string(),
                &end.to_string(),
            ],
        )
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct PlannedTranscriptChunk {
    pub span_index: u32,
    pub start_nanoseconds: i64,
    pub end_nanoseconds: i64,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum TranscriptChunkState {
    Pending,
    Running,
    Complete,
    Failed,
}

impl TranscriptChunkState {
    fn parse(value: &str) -> Result<Self, StoreError> {
        match value {
            "pending" => Ok(Self::Pending),
            "running" => Ok(Self::Running),
            "complete" => Ok(Self::Complete),
            "failed" => Ok(Self::Failed),
            _ => Err(StoreError::IntegrityMismatch(
                "unknown transcript chunk state",
            )),
        }
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct TranscriptChunk {
    pub sequence: u32,
    pub identity: String,
    pub span_index: u32,
    pub start_nanoseconds: i64,
    pub end_nanoseconds: i64,
    pub state: TranscriptChunkState,
    pub language: Option<String>,
    pub hypothesis_json: Option<String>,
    pub reused_from_run: Option<String>,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct TranscriptionRunHandle {
    pub run_id: String,
    pub resumed: bool,
    pub chunks: Vec<TranscriptChunk>,
}

/// Content-free reason a run stopped without a revision.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum TranscriptionFailure {
    Cancelled,
    ModelUnavailable,
    EngineError,
    ResourceExhausted,
    InvalidResult,
    InputUnavailable,
}

impl TranscriptionFailure {
    pub const fn class(self) -> &'static str {
        match self {
            Self::Cancelled => "cancelled",
            Self::ModelUnavailable => "model_unavailable",
            Self::EngineError => "engine_error",
            Self::ResourceExhausted => "resource_exhausted",
            Self::InvalidResult => "invalid_result",
            Self::InputUnavailable => "input_unavailable",
        }
    }
}

#[derive(Clone, Debug, PartialEq)]
pub struct RevisionSegmentInput {
    pub start_nanoseconds: i64,
    pub end_nanoseconds: i64,
    pub text: String,
    pub mean_probability: Option<f32>,
    pub no_speech_probability: Option<f32>,
    pub chunk_identity: String,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct TranscriptionRunSummary {
    pub run_id: String,
    pub track_id: String,
    pub state: String,
    pub failure_class: Option<String>,
    pub model_id: String,
    pub engine_version: String,
    pub completed_chunks: u32,
    pub total_chunks: u32,
    pub created_at_ms: i64,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct TranscriptRevisionSummary {
    pub revision_id: String,
    pub run_id: String,
    pub track_id: String,
    pub model_id: String,
    pub engine: String,
    pub engine_version: String,
    pub selected: bool,
    pub segment_count: u32,
    pub created_at_ms: i64,
}

#[derive(Clone, Debug, PartialEq)]
pub struct TranscriptSegmentView {
    pub revision_id: String,
    pub track_id: String,
    pub sequence: u32,
    pub start_nanoseconds: i64,
    pub end_nanoseconds: i64,
    pub text: String,
}

impl SessionStore {
    /// Resumes an interrupted run with the same identity, or starts a new run
    /// that reuses complete chunks whose full identity already exists.
    pub fn begin_transcription_run(
        &mut self,
        identity: &TranscriptionRunIdentity,
        plan: &[PlannedTranscriptChunk],
    ) -> Result<TranscriptionRunHandle, StoreError> {
        let current = self.transcription_input(&identity.session_id, &identity.track_id)?;
        if current.input_digest != identity.input_digest {
            return Err(StoreError::IntegrityMismatch(
                "transcription input differs from the sealed track",
            ));
        }
        if plan.is_empty()
            || plan
                .iter()
                .any(|chunk| chunk.end_nanoseconds <= chunk.start_nanoseconds)
            || plan.windows(2).any(|pair| {
                (pair[1].span_index, pair[1].start_nanoseconds)
                    <= (pair[0].span_index, pair[0].start_nanoseconds)
            })
        {
            return Err(StoreError::InvalidRequest(
                "transcript chunk plan is invalid",
            ));
        }
        let identities: Vec<String> = plan
            .iter()
            .map(|chunk| {
                identity.chunk_identity(
                    chunk.span_index,
                    chunk.start_nanoseconds,
                    chunk.end_nanoseconds,
                )
            })
            .collect();
        let run_identity = identity.digest();
        let now = wall_time_milliseconds();
        let transaction = self.connection.transaction()?;
        let interrupted: Option<String> = transaction
            .query_row(
                "SELECT id FROM transcription_runs
                 WHERE session_id = ?1 AND track_id = ?2 AND identity = ?3 AND state = 'running'",
                params![identity.session_id.0, identity.track_id, run_identity],
                |row| row.get(0),
            )
            .optional()?;
        let (run_id, resumed) = if let Some(run_id) = interrupted {
            let stored: Vec<String> = transaction
                .prepare(
                    "SELECT identity FROM transcript_chunks WHERE run_id = ?1 ORDER BY sequence",
                )?
                .query_map([&run_id], |row| row.get(0))?
                .collect::<Result<_, _>>()?;
            if stored != identities {
                return Err(StoreError::IntegrityMismatch(
                    "interrupted transcription run has a different chunk plan",
                ));
            }
            transaction.execute(
                "UPDATE transcript_chunks SET state = 'pending', updated_at_ms = ?2
                 WHERE run_id = ?1 AND state = 'running'",
                params![run_id, now],
            )?;
            (run_id, true)
        } else {
            transaction.execute(
                "UPDATE transcription_runs
                 SET state = 'cancelled', failure_class = 'superseded', updated_at_ms = ?3
                 WHERE session_id = ?1 AND track_id = ?2 AND state = 'running'",
                params![identity.session_id.0, identity.track_id, now],
            )?;
            let run_id = Uuid::now_v7().to_string();
            transaction.execute(
                "INSERT INTO transcription_runs(
                    id, schema_version, session_id, track_id, identity, input_digest, engine,
                    engine_version, model_id, model_sha256, options_digest, reconciliation_version,
                    state, created_at_ms, updated_at_ms)
                 VALUES(?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, 'running', ?13, ?13)",
                params![
                    run_id,
                    TRANSCRIPT_SCHEMA_VERSION,
                    identity.session_id.0,
                    identity.track_id,
                    run_identity,
                    identity.input_digest,
                    identity.engine,
                    identity.engine_version,
                    identity.model_id,
                    identity.model_sha256,
                    identity.options_digest,
                    identity.reconciliation_version,
                    now
                ],
            )?;
            for (sequence, (chunk, chunk_identity)) in plan.iter().zip(&identities).enumerate() {
                let reusable: Option<(String, String, String)> = transaction
                    .query_row(
                        "SELECT transcript_chunks.run_id, transcript_chunks.language,
                                transcript_chunks.hypothesis_json
                         FROM transcript_chunks
                         JOIN transcription_runs ON transcription_runs.id = transcript_chunks.run_id
                         WHERE transcript_chunks.identity = ?1 AND transcript_chunks.state = 'complete'
                           AND transcription_runs.session_id = ?2
                         ORDER BY transcription_runs.created_at_ms LIMIT 1",
                        params![chunk_identity, identity.session_id.0],
                        |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?)),
                    )
                    .optional()?;
                let (state, language, hypothesis, reused_from) = match reusable {
                    Some((source, language, hypothesis)) => {
                        ("complete", Some(language), Some(hypothesis), Some(source))
                    }
                    None => ("pending", None, None, None),
                };
                transaction.execute(
                    "INSERT INTO transcript_chunks(
                        run_id, sequence, identity, span_index, start_ns, end_ns, state,
                        language, hypothesis_json, reused_from_run, updated_at_ms)
                     VALUES(?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11)",
                    params![
                        run_id,
                        sequence as i64,
                        chunk_identity,
                        chunk.span_index,
                        chunk.start_nanoseconds,
                        chunk.end_nanoseconds,
                        state,
                        language,
                        hypothesis,
                        reused_from,
                        now
                    ],
                )?;
            }
            (run_id, false)
        };
        let chunks = load_chunks(&transaction, &run_id)?;
        transaction.commit()?;
        Ok(TranscriptionRunHandle {
            run_id,
            resumed,
            chunks,
        })
    }

    pub fn mark_transcript_chunk_running(
        &mut self,
        run_id: &str,
        sequence: u32,
    ) -> Result<(), StoreError> {
        self.update_open_chunk(
            run_id,
            sequence,
            "UPDATE transcript_chunks SET state = 'running', updated_at_ms = ?3
             WHERE run_id = ?1 AND sequence = ?2 AND state = 'pending'",
            None,
        )
    }

    /// Commits one chunk's verbatim hypothesis before the next chunk starts.
    pub fn complete_transcript_chunk(
        &mut self,
        run_id: &str,
        sequence: u32,
        language: &str,
        hypothesis_json: &str,
    ) -> Result<(), StoreError> {
        serde_json::from_str::<serde_json::Value>(hypothesis_json)?;
        self.update_open_chunk(
            run_id,
            sequence,
            "UPDATE transcript_chunks
             SET state = 'complete', language = ?4, hypothesis_json = ?5, updated_at_ms = ?3
             WHERE run_id = ?1 AND sequence = ?2 AND state IN ('pending', 'running')",
            Some((language, hypothesis_json)),
        )
    }

    fn update_open_chunk(
        &mut self,
        run_id: &str,
        sequence: u32,
        statement: &str,
        result: Option<(&str, &str)>,
    ) -> Result<(), StoreError> {
        let transaction = self.connection.transaction()?;
        require_running(&transaction, run_id)?;
        let now = wall_time_milliseconds();
        let changed = match result {
            Some((language, hypothesis)) => transaction.execute(
                statement,
                params![run_id, sequence, now, language, hypothesis],
            )?,
            None => transaction.execute(statement, params![run_id, sequence, now])?,
        };
        if changed != 1 {
            return Err(StoreError::InvalidState("transcript chunk is not open"));
        }
        transaction.commit()?;
        Ok(())
    }

    /// Ends a run without a revision. Complete chunks and any selected
    /// revision remain untouched.
    pub fn fail_transcription_run(
        &mut self,
        run_id: &str,
        failed_sequence: Option<u32>,
        failure: TranscriptionFailure,
    ) -> Result<(), StoreError> {
        let transaction = self.connection.transaction()?;
        require_running(&transaction, run_id)?;
        let now = wall_time_milliseconds();
        if let Some(sequence) = failed_sequence {
            transaction.execute(
                "UPDATE transcript_chunks SET state = 'failed', failure_class = ?3, updated_at_ms = ?4
                 WHERE run_id = ?1 AND sequence = ?2 AND state IN ('pending', 'running')",
                params![run_id, sequence, failure.class(), now],
            )?;
        }
        transaction.execute(
            "UPDATE transcript_chunks SET state = 'pending', updated_at_ms = ?2
             WHERE run_id = ?1 AND state = 'running'",
            params![run_id, now],
        )?;
        let state = if failure == TranscriptionFailure::Cancelled {
            "cancelled"
        } else {
            "failed"
        };
        transaction.execute(
            "UPDATE transcription_runs SET state = ?2, failure_class = ?3, updated_at_ms = ?4
             WHERE id = ?1",
            params![run_id, state, failure.class(), now],
        )?;
        transaction.commit()?;
        Ok(())
    }

    /// Atomically creates the immutable verbatim revision, completes the
    /// run, and selects the revision for its track.
    pub fn commit_transcript_revision(
        &mut self,
        run_id: &str,
        segments: &[RevisionSegmentInput],
        rejections_json: &str,
        discontinuities_json: &str,
    ) -> Result<String, StoreError> {
        serde_json::from_str::<serde_json::Value>(rejections_json)?;
        serde_json::from_str::<serde_json::Value>(discontinuities_json)?;
        let transaction = self.connection.transaction()?;
        let (session_id, track_id, reconciliation_version) = require_running(&transaction, run_id)?;
        let chunks = load_chunks(&transaction, run_id)?;
        if chunks
            .iter()
            .any(|chunk| chunk.state != TranscriptChunkState::Complete)
        {
            return Err(StoreError::InvalidState(
                "transcription run has incomplete chunks",
            ));
        }
        for pair in segments.windows(2) {
            if pair[1].start_nanoseconds < pair[0].start_nanoseconds {
                return Err(StoreError::InvalidRequest(
                    "revision segments are out of order",
                ));
            }
        }
        for segment in segments {
            let Some(chunk) = chunks
                .iter()
                .find(|chunk| chunk.identity == segment.chunk_identity)
            else {
                return Err(StoreError::InvalidRequest(
                    "revision segment cites a foreign chunk",
                ));
            };
            if segment.end_nanoseconds < segment.start_nanoseconds
                || segment.start_nanoseconds < chunk.start_nanoseconds
                || segment.end_nanoseconds > chunk.end_nanoseconds
                || segment.text.trim().is_empty()
            {
                return Err(StoreError::InvalidRequest(
                    "revision segment is outside its chunk",
                ));
            }
        }
        let now = wall_time_milliseconds();
        let revision_id = Uuid::now_v7().to_string();
        transaction.execute(
            "INSERT INTO transcript_revisions(
                id, schema_version, session_id, track_id, run_id, kind, finality,
                reconciliation_version, rejections_json, discontinuities_json, created_at_ms)
             VALUES(?1, ?2, ?3, ?4, ?5, 'verbatim', 'final', ?6, ?7, ?8, ?9)",
            params![
                revision_id,
                TRANSCRIPT_SCHEMA_VERSION,
                session_id,
                track_id,
                run_id,
                reconciliation_version,
                rejections_json,
                discontinuities_json,
                now
            ],
        )?;
        for (sequence, segment) in segments.iter().enumerate() {
            transaction.execute(
                "INSERT INTO transcript_segments(
                    revision_id, sequence, start_ns, end_ns, text, mean_probability,
                    no_speech_probability, chunk_identity)
                 VALUES(?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)",
                params![
                    revision_id,
                    sequence as i64,
                    segment.start_nanoseconds,
                    segment.end_nanoseconds,
                    segment.text,
                    segment.mean_probability,
                    segment.no_speech_probability,
                    segment.chunk_identity
                ],
            )?;
        }
        transaction.execute(
            "UPDATE transcription_runs SET state = 'complete', updated_at_ms = ?2 WHERE id = ?1",
            params![run_id, now],
        )?;
        select_revision(&transaction, &session_id, &track_id, &revision_id, now)?;
        reindex_session_search(&transaction, &session_id)?;
        transaction.commit()?;
        Ok(revision_id)
    }

    pub fn select_transcript_revision(
        &mut self,
        session: &SessionId,
        track_id: &str,
        revision_id: &str,
    ) -> Result<(), StoreError> {
        let transaction = self.connection.transaction()?;
        let owned: bool = transaction.query_row(
            "SELECT EXISTS(SELECT 1 FROM transcript_revisions
                           WHERE id = ?1 AND session_id = ?2 AND track_id = ?3)",
            params![revision_id, session.0, track_id],
            |row| row.get(0),
        )?;
        if !owned {
            return Err(StoreError::InvalidRequest(
                "revision does not belong to this track",
            ));
        }
        select_revision(
            &transaction,
            &session.0,
            track_id,
            revision_id,
            wall_time_milliseconds(),
        )?;
        reindex_session_search(&transaction, &session.0)?;
        transaction.commit()?;
        Ok(())
    }

    pub fn transcription_runs(
        &self,
        session: &SessionId,
    ) -> Result<Vec<TranscriptionRunSummary>, StoreError> {
        let mut statement = self.connection.prepare(
            "SELECT runs.id, runs.track_id, runs.state, runs.failure_class, runs.model_id,
                    runs.engine_version, runs.created_at_ms,
                    (SELECT COUNT(*) FROM transcript_chunks WHERE run_id = runs.id AND state = 'complete'),
                    (SELECT COUNT(*) FROM transcript_chunks WHERE run_id = runs.id)
             FROM transcription_runs AS runs WHERE runs.session_id = ?1
             ORDER BY runs.created_at_ms, runs.id",
        )?;
        let runs = statement
            .query_map([&session.0], |row| {
                Ok(TranscriptionRunSummary {
                    run_id: row.get(0)?,
                    track_id: row.get(1)?,
                    state: row.get(2)?,
                    failure_class: row.get(3)?,
                    model_id: row.get(4)?,
                    engine_version: row.get(5)?,
                    created_at_ms: row.get(6)?,
                    completed_chunks: row.get(7)?,
                    total_chunks: row.get(8)?,
                })
            })?
            .collect::<Result<_, _>>()?;
        Ok(runs)
    }

    pub fn transcript_revisions(
        &self,
        session: &SessionId,
    ) -> Result<Vec<TranscriptRevisionSummary>, StoreError> {
        let mut statement = self.connection.prepare(
            "SELECT revisions.id, revisions.run_id, revisions.track_id, runs.model_id, runs.engine,
                    runs.engine_version, revisions.created_at_ms,
                    EXISTS(SELECT 1 FROM transcript_selections
                           WHERE transcript_selections.revision_id = revisions.id),
                    (SELECT COUNT(*) FROM transcript_segments WHERE revision_id = revisions.id)
             FROM transcript_revisions AS revisions
             JOIN transcription_runs AS runs ON runs.id = revisions.run_id
             WHERE revisions.session_id = ?1
             ORDER BY revisions.created_at_ms, revisions.id",
        )?;
        let revisions = statement
            .query_map([&session.0], |row| {
                Ok(TranscriptRevisionSummary {
                    revision_id: row.get(0)?,
                    run_id: row.get(1)?,
                    track_id: row.get(2)?,
                    model_id: row.get(3)?,
                    engine: row.get(4)?,
                    engine_version: row.get(5)?,
                    created_at_ms: row.get(6)?,
                    selected: row.get(7)?,
                    segment_count: row.get(8)?,
                })
            })?
            .collect::<Result<_, _>>()?;
        Ok(revisions)
    }

    /// Selected Final text across tracks, ordered on the session timeline.
    pub fn selected_transcript(
        &self,
        session: &SessionId,
    ) -> Result<Vec<TranscriptSegmentView>, StoreError> {
        self.segment_views(
            "SELECT segments.revision_id, revisions.track_id, segments.sequence, segments.start_ns,
                    segments.end_ns, segments.text
             FROM transcript_selections AS selections
             JOIN transcript_revisions AS revisions ON revisions.id = selections.revision_id
             JOIN transcript_segments AS segments ON segments.revision_id = revisions.id
             WHERE selections.session_id = ?1
             ORDER BY segments.start_ns, revisions.track_id, segments.sequence",
            &session.0,
        )
    }

    pub fn transcript_revision_segments(
        &self,
        revision_id: &str,
    ) -> Result<Vec<TranscriptSegmentView>, StoreError> {
        self.segment_views(
            "SELECT segments.revision_id, revisions.track_id, segments.sequence, segments.start_ns,
                    segments.end_ns, segments.text
             FROM transcript_revisions AS revisions
             JOIN transcript_segments AS segments ON segments.revision_id = revisions.id
             WHERE revisions.id = ?1 ORDER BY segments.sequence",
            revision_id,
        )
    }

    fn segment_views(
        &self,
        sql: &str,
        key: &str,
    ) -> Result<Vec<TranscriptSegmentView>, StoreError> {
        let mut statement = self.connection.prepare(sql)?;
        let segments = statement
            .query_map([key], |row| {
                Ok(TranscriptSegmentView {
                    revision_id: row.get(0)?,
                    track_id: row.get(1)?,
                    sequence: row.get(2)?,
                    start_nanoseconds: row.get(3)?,
                    end_nanoseconds: row.get(4)?,
                    text: row.get(5)?,
                })
            })?
            .collect::<Result<_, _>>()?;
        Ok(segments)
    }
}

fn require_running(
    transaction: &Transaction<'_>,
    run_id: &str,
) -> Result<(String, String, String), StoreError> {
    transaction
        .query_row(
            "SELECT session_id, track_id, reconciliation_version FROM transcription_runs
             WHERE id = ?1 AND state = 'running'",
            [run_id],
            |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?)),
        )
        .optional()?
        .ok_or(StoreError::InvalidState("transcription run is not running"))
}

pub(super) fn select_revision(
    transaction: &Transaction<'_>,
    session_id: &str,
    track_id: &str,
    revision_id: &str,
    now: i64,
) -> Result<(), StoreError> {
    transaction.execute(
        "INSERT INTO transcript_selections(session_id, track_id, revision_id, selected_at_ms)
         VALUES(?1, ?2, ?3, ?4)
         ON CONFLICT(session_id, track_id)
         DO UPDATE SET revision_id = excluded.revision_id, selected_at_ms = excluded.selected_at_ms",
        params![session_id, track_id, revision_id, now],
    )?;
    Ok(())
}

fn load_chunks(
    transaction: &Transaction<'_>,
    run_id: &str,
) -> Result<Vec<TranscriptChunk>, StoreError> {
    let mut statement = transaction.prepare(
        "SELECT sequence, identity, span_index, start_ns, end_ns, state, language,
                hypothesis_json, reused_from_run
         FROM transcript_chunks WHERE run_id = ?1 ORDER BY sequence",
    )?;
    let rows = statement
        .query_map([run_id], |row| {
            Ok((
                row.get::<_, u32>(0)?,
                row.get::<_, String>(1)?,
                row.get::<_, u32>(2)?,
                row.get::<_, i64>(3)?,
                row.get::<_, i64>(4)?,
                row.get::<_, String>(5)?,
                row.get::<_, Option<String>>(6)?,
                row.get::<_, Option<String>>(7)?,
                row.get::<_, Option<String>>(8)?,
            ))
        })?
        .collect::<Result<Vec<_>, _>>()?;
    rows.into_iter()
        .map(
            |(sequence, identity, span_index, start, end, state, language, hypothesis, reused)| {
                Ok(TranscriptChunk {
                    sequence,
                    identity,
                    span_index,
                    start_nanoseconds: start,
                    end_nanoseconds: end,
                    state: TranscriptChunkState::parse(&state)?,
                    language,
                    hypothesis_json: hypothesis,
                    reused_from_run: reused,
                })
            },
        )
        .collect()
}

fn digest_fields(domain: &[u8], fields: &[&str]) -> String {
    let mut hasher = Sha256::new();
    hasher.update(domain);
    for field in fields {
        hasher.update(b"\n");
        hasher.update((field.len() as u64).to_be_bytes());
        hasher.update(field.as_bytes());
    }
    hasher
        .finalize()
        .iter()
        .map(|byte| format!("{byte:02x}"))
        .collect()
}

#[cfg(test)]
#[path = "transcripts_tests.rs"]
pub(crate) mod tests;
