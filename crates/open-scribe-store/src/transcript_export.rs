//! Durable facts a transcript export must disclose (ADR 0010): session
//! identity, which tracks are Final, the model run behind each selected
//! revision, and the sealed-media digest each revision was produced from.
//! Rendering lives in the core; this module only reads.

use super::{MEDIA_SAMPLE_RATE_HZ, SessionStore, StoreError};
use open_scribe_types::SessionId;
use rusqlite::{OptionalExtension, params};

/// Provenance of one track's selected Final revision.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct SelectedRevisionProvenance {
    pub track_id: String,
    pub revision_id: String,
    pub run_id: String,
    pub engine: String,
    pub engine_version: String,
    pub model_id: String,
    pub model_sha256: String,
    /// Digest of the sealed track input the run transcribed.
    pub input_digest: String,
    /// Most frequent language among the run's complete chunks.
    pub language: Option<String>,
    pub created_at_ms: i64,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct TranscriptExportContext {
    pub session_id: SessionId,
    pub title: String,
    pub created_at_ms: i64,
    /// Sealed PCM tracks that can carry a transcript.
    pub transcribable_tracks: Vec<String>,
    /// Current sealed-input digest per transcribable track.
    pub track_input_digests: Vec<(String, String)>,
    pub selected: Vec<SelectedRevisionProvenance>,
    /// Transcribable tracks without a selection whose latest run failed.
    pub failed_tracks: Vec<String>,
    /// Session-timeline end of the latest sealed sample on any track.
    pub duration_nanoseconds: i64,
}

impl SessionStore {
    pub fn transcript_export_context(
        &self,
        session: &SessionId,
    ) -> Result<TranscriptExportContext, StoreError> {
        let (title, created_at_ms): (String, i64) = self
            .connection
            .query_row(
                "SELECT title, created_at_ms FROM sessions
                 WHERE id = ?1 AND lifecycle = 'ready_for_review'",
                [&session.0],
                |row| Ok((row.get(0)?, row.get(1)?)),
            )
            .map_err(|error| match error {
                rusqlite::Error::QueryReturnedNoRows => {
                    StoreError::InvalidState("session is not saved for review")
                }
                other => StoreError::Sqlite(other),
            })?;
        let transcribable_tracks = self.transcription_tracks(session)?;
        let mut track_input_digests = Vec::with_capacity(transcribable_tracks.len());
        let mut duration_nanoseconds = 0_i64;
        for track in &transcribable_tracks {
            let input = self.transcription_input(session, track)?;
            for span in &input.spans {
                let frames = i64::try_from(span.frames).map_err(|_| {
                    StoreError::IntegrityMismatch("track frame count exceeds the timeline")
                })?;
                let end = frames
                    .checked_mul(1_000_000_000)
                    .map(|nanoseconds| nanoseconds / i64::from(MEDIA_SAMPLE_RATE_HZ))
                    .and_then(|length| span.start_nanoseconds.checked_add(length))
                    .ok_or(StoreError::IntegrityMismatch(
                        "track duration exceeds the timeline",
                    ))?;
                duration_nanoseconds = duration_nanoseconds.max(end);
            }
            track_input_digests.push((track.clone(), input.input_digest));
        }

        let mut statement = self.connection.prepare(
            "SELECT selections.track_id, revisions.id, runs.id, runs.engine, runs.engine_version,
                    runs.model_id, runs.model_sha256, runs.input_digest, revisions.created_at_ms,
                    (SELECT chunks.language FROM transcript_chunks AS chunks
                     WHERE chunks.run_id = runs.id AND chunks.state = 'complete'
                       AND chunks.language IS NOT NULL
                     GROUP BY chunks.language
                     ORDER BY COUNT(*) DESC, chunks.language LIMIT 1)
             FROM transcript_selections AS selections
             JOIN transcript_revisions AS revisions ON revisions.id = selections.revision_id
             JOIN transcription_runs AS runs ON runs.id = revisions.run_id
             WHERE selections.session_id = ?1
             ORDER BY selections.track_id",
        )?;
        let selected: Vec<SelectedRevisionProvenance> = statement
            .query_map([&session.0], |row| {
                Ok(SelectedRevisionProvenance {
                    track_id: row.get(0)?,
                    revision_id: row.get(1)?,
                    run_id: row.get(2)?,
                    engine: row.get(3)?,
                    engine_version: row.get(4)?,
                    model_id: row.get(5)?,
                    model_sha256: row.get(6)?,
                    input_digest: row.get(7)?,
                    created_at_ms: row.get(8)?,
                    language: row.get(9)?,
                })
            })?
            .collect::<Result<_, _>>()?;

        let mut failed_tracks = Vec::new();
        for track in &transcribable_tracks {
            if selected.iter().any(|revision| &revision.track_id == track) {
                continue;
            }
            let latest: Option<String> = self
                .connection
                .query_row(
                    "SELECT state FROM transcription_runs
                     WHERE session_id = ?1 AND track_id = ?2
                     ORDER BY created_at_ms DESC, id DESC LIMIT 1",
                    params![session.0, track],
                    |row| row.get(0),
                )
                .optional()?;
            if latest.as_deref() == Some("failed") {
                failed_tracks.push(track.clone());
            }
        }

        Ok(TranscriptExportContext {
            session_id: session.clone(),
            title,
            created_at_ms,
            transcribable_tracks,
            track_input_digests,
            selected,
            failed_tracks,
            duration_nanoseconds,
        })
    }
}
