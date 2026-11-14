//! Durable record that voice clustering did not run.
//!
//! Known capture topology is stored as `topology` and is not rediscovered.
//! Imported and other unknown audio stays `unresolved`. The only clustering
//! state this migration accepts is `unavailable`. Nothing here renames a
//! speaker, edits transcript text, changes a selection, or touches media.

use super::transcript_review::{SpeakerLabelOrigin, require_reviewable_session, speaker_labels};
use super::{SessionStore, StoreError, TrackSourceKind, wall_time_milliseconds};
use open_scribe_diarize::{
    ALGORITHM_ID, CLUSTERING_UNAVAILABLE, SpeakerDisposition, UNAVAILABLE_REASON,
    disposition_for_source_kind,
};
use open_scribe_types::SessionId;
use rusqlite::{OptionalExtension, Transaction, params};
use uuid::Uuid;

/// The label review was showing when this decision was recorded.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct SpeakerDiarizationTrack {
    pub track_id: String,
    pub source_kind: TrackSourceKind,
    pub disposition: SpeakerDisposition,
    pub label: String,
    pub label_origin: SpeakerLabelOrigin,
}

/// One idempotent diarization decision for a reviewable session.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct SpeakerDiarization {
    pub run_id: String,
    pub algorithm_id: String,
    pub clustering_state: String,
    pub reason: String,
    pub inserted: bool,
    pub tracks: Vec<SpeakerDiarizationTrack>,
}

pub(super) fn apply_schema(transaction: &Transaction<'_>) -> Result<(), StoreError> {
    transaction.execute_batch(
        "CREATE TABLE IF NOT EXISTS speaker_diarization_runs (
            id TEXT PRIMARY KEY,
            session_id TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
            algorithm_id TEXT NOT NULL
                CHECK (algorithm_id = 'topology-before-clustering-v1'),
            clustering_state TEXT NOT NULL
                CHECK (clustering_state = 'unavailable'),
            reason TEXT NOT NULL
                CHECK (reason = 'no calibrated diarization model'),
            created_at_ms INTEGER NOT NULL
        );
        CREATE INDEX IF NOT EXISTS speaker_diarization_runs_by_session
            ON speaker_diarization_runs(session_id, created_at_ms);
        CREATE TABLE IF NOT EXISTS speaker_diarization_tracks (
            id TEXT PRIMARY KEY,
            run_id TEXT NOT NULL REFERENCES speaker_diarization_runs(id) ON DELETE CASCADE,
            session_id TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
            track_id TEXT NOT NULL REFERENCES tracks(id),
            source_kind TEXT NOT NULL,
            disposition TEXT NOT NULL
                CHECK (disposition IN ('topology', 'unresolved')),
            label TEXT NOT NULL,
            label_origin TEXT NOT NULL
                CHECK (label_origin IN ('human', 'source_default'))
        );
        CREATE INDEX IF NOT EXISTS speaker_diarization_tracks_by_run
            ON speaker_diarization_tracks(run_id, track_id);
        CREATE TRIGGER IF NOT EXISTS speaker_diarization_runs_append_only
            BEFORE UPDATE ON speaker_diarization_runs
            BEGIN SELECT RAISE(ABORT, 'diarization runs are append-only'); END;
        CREATE TRIGGER IF NOT EXISTS speaker_diarization_tracks_append_only
            BEFORE UPDATE ON speaker_diarization_tracks
            BEGIN SELECT RAISE(ABORT, 'diarization tracks are append-only'); END;",
    )?;
    Ok(())
}

/// The decision for the session's tracks as they are now: each source kind's
/// disposition and the label review shows.
fn current_tracks(
    transaction: &Transaction<'_>,
    session_id: &str,
) -> Result<Vec<SpeakerDiarizationTrack>, StoreError> {
    Ok(speaker_labels(transaction, session_id)?
        .into_iter()
        .map(|speaker| SpeakerDiarizationTrack {
            disposition: disposition_for_source_kind(speaker.source_kind.as_str()).disposition,
            track_id: speaker.track_id,
            source_kind: speaker.source_kind,
            label: speaker.label,
            label_origin: speaker.origin,
        })
        .collect())
}

/// The latest recorded run and its tracks.
fn latest_run(
    transaction: &Transaction<'_>,
    session_id: &str,
) -> Result<Option<(String, Vec<SpeakerDiarizationTrack>)>, StoreError> {
    let run_id: Option<String> = transaction
        .query_row(
            "SELECT id FROM speaker_diarization_runs
             WHERE session_id = ?1
             ORDER BY created_at_ms DESC, rowid DESC
             LIMIT 1",
            [session_id],
            |row| row.get(0),
        )
        .optional()?;
    let Some(run_id) = run_id else {
        return Ok(None);
    };
    let mut statement = transaction.prepare(
        "SELECT track_id, source_kind, disposition, label, label_origin
         FROM speaker_diarization_tracks
         WHERE run_id = ?1
         ORDER BY track_id",
    )?;
    let rows = statement
        .query_map([&run_id], |row| {
            Ok((
                row.get::<_, String>(0)?,
                row.get::<_, TrackSourceKind>(1)?,
                row.get::<_, String>(2)?,
                row.get::<_, String>(3)?,
                row.get::<_, String>(4)?,
            ))
        })?
        .collect::<Result<Vec<_>, _>>()?;
    let tracks = rows
        .into_iter()
        .map(
            |(track_id, source_kind, disposition, label, label_origin)| {
                Ok(SpeakerDiarizationTrack {
                    track_id,
                    source_kind,
                    disposition: match disposition.as_str() {
                        "topology" => SpeakerDisposition::Topology,
                        "unresolved" => SpeakerDisposition::Unresolved,
                        _ => {
                            return Err(StoreError::IntegrityMismatch(
                                "diarization disposition is unsupported",
                            ));
                        }
                    },
                    label,
                    label_origin: match label_origin.as_str() {
                        "human" => SpeakerLabelOrigin::Human,
                        "source_default" => SpeakerLabelOrigin::SourceDefault,
                        _ => {
                            return Err(StoreError::IntegrityMismatch(
                                "diarization label origin is unsupported",
                            ));
                        }
                    },
                })
            },
        )
        .collect::<Result<_, StoreError>>()?;
    Ok(Some((run_id, tracks)))
}

/// The stored run when it already records `tracks`.
fn recorded(
    transaction: &Transaction<'_>,
    session_id: &str,
) -> Result<(Vec<SpeakerDiarizationTrack>, Option<String>), StoreError> {
    require_reviewable_session(transaction, session_id)?;
    let tracks = current_tracks(transaction, session_id)?;
    let unchanged = latest_run(transaction, session_id)?
        .filter(|(_, stored)| *stored == tracks)
        .map(|(run_id, _)| run_id);
    Ok((tracks, unchanged))
}

fn decision(
    run_id: String,
    inserted: bool,
    tracks: Vec<SpeakerDiarizationTrack>,
) -> SpeakerDiarization {
    SpeakerDiarization {
        run_id,
        algorithm_id: ALGORITHM_ID.to_owned(),
        clustering_state: CLUSTERING_UNAVAILABLE.to_owned(),
        reason: UNAVAILABLE_REASON.to_owned(),
        inserted,
        tracks,
    }
}

impl SessionStore {
    /// Records that known sources keep their topology and that voice
    /// clustering is unavailable. Reading a session whose dispositions and
    /// labels are already recorded writes nothing; a new run is appended
    /// only when they changed. Media, transcript text, selections, and human
    /// turn names are not written.
    pub fn prepare_speaker_diarization(
        &mut self,
        session: &SessionId,
    ) -> Result<SpeakerDiarization, StoreError> {
        {
            // Deferred, so an unchanged decision never takes the write lock.
            let read = rusqlite::Transaction::new_unchecked(
                &self.connection,
                rusqlite::TransactionBehavior::Deferred,
            )?;
            if let (tracks, Some(run_id)) = recorded(&read, &session.0)? {
                return Ok(decision(run_id, false, tracks));
            }
        }
        let _writer = self.write_guard()?;
        let transaction = self.connection.transaction()?;
        let (tracks, unchanged) = recorded(&transaction, &session.0)?;
        if let Some(run_id) = unchanged {
            return Ok(decision(run_id, false, tracks));
        }
        let run_id = Uuid::now_v7().to_string();
        transaction.execute(
            "INSERT INTO speaker_diarization_runs(
                id, session_id, algorithm_id, clustering_state, reason, created_at_ms)
             VALUES(?1, ?2, ?3, ?4, ?5, ?6)",
            params![
                run_id,
                session.0,
                ALGORITHM_ID,
                CLUSTERING_UNAVAILABLE,
                UNAVAILABLE_REASON,
                wall_time_milliseconds()
            ],
        )?;
        for track in &tracks {
            transaction.execute(
                "INSERT INTO speaker_diarization_tracks(
                    id, run_id, session_id, track_id, source_kind, disposition, label, label_origin)
                 VALUES(?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)",
                params![
                    Uuid::now_v7().to_string(),
                    run_id,
                    session.0,
                    track.track_id,
                    track.source_kind,
                    track.disposition.as_str(),
                    track.label,
                    track.label_origin.as_str()
                ],
            )?;
        }
        transaction.commit()?;
        Ok(decision(run_id, true, tracks))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn topology_is_only_the_known_capture_sources() {
        for kind in TrackSourceKind::ALL {
            let expected = if kind.capture().is_some() {
                SpeakerDisposition::Topology
            } else {
                SpeakerDisposition::Unresolved
            };
            assert_eq!(
                disposition_for_source_kind(kind.as_str()).disposition,
                expected
            );
        }
        assert_eq!(
            disposition_for_source_kind(TrackSourceKind::ImportedAudio.as_str())
                .disposition
                .as_str(),
            "unresolved"
        );
    }
}
