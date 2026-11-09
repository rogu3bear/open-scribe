//! Durable record that voice clustering did not run.
//!
//! Known capture topology is stored as `topology` and is not rediscovered.
//! Imported and other unknown audio stays `unresolved`. The only clustering
//! state this migration accepts is `unavailable`. Nothing here renames a
//! speaker, edits transcript text, changes a selection, or touches media.

use super::transcript_review::{SOURCE_CLUSTER, default_speaker_label, require_reviewable_session};
use super::{SessionStore, StoreError, wall_time_milliseconds};
use open_scribe_types::SessionId;
use rusqlite::{OptionalExtension, Transaction, params};
use std::collections::BTreeMap;
use uuid::Uuid;

pub(super) const SPEAKER_DIARIZATION_MIGRATION_VERSION: i64 = 20;

/// Same words as `open-scribe-diarize`. Any other algorithm, clustering
/// state, or reason is refused so a caller cannot store a calibrated split.
const ALGORITHM_ID: &str = "topology-before-clustering-v1";
const CLUSTERING_UNAVAILABLE: &str = "unavailable";
const UNAVAILABLE_REASON: &str = "no calibrated diarization model";

/// One track the caller has already classified. The store checks the
/// disposition against the track's stored source and snapshots the label.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct SpeakerDiarizationTrackInput {
    pub track_id: String,
    pub disposition: String,
}

/// The label review was showing when this decision was recorded.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct SpeakerDiarizationTrack {
    pub track_id: String,
    pub source_kind: String,
    pub disposition: String,
    pub label: String,
    pub label_origin: String,
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
    transaction.execute(
        "INSERT OR IGNORE INTO schema_migrations(version, applied_at_ms) VALUES(?1, ?2)",
        params![
            SPEAKER_DIARIZATION_MIGRATION_VERSION,
            wall_time_milliseconds()
        ],
    )?;
    Ok(())
}

struct CurrentSpeaker {
    track_id: String,
    source_kind: String,
    label: String,
    label_origin: String,
}

fn required_disposition(source_kind: &str) -> &'static str {
    match source_kind {
        "microphone" | "application_audio" | "system_audio" => "topology",
        _ => "unresolved",
    }
}

fn current_speakers(
    transaction: &Transaction<'_>,
    session_id: &str,
) -> Result<Vec<CurrentSpeaker>, StoreError> {
    let mut statement = transaction.prepare(
        "SELECT tracks.id, sources.kind,
                (SELECT adjudications.label FROM speaker_adjudications AS adjudications
                 WHERE adjudications.session_id = tracks.session_id
                   AND adjudications.track_id = tracks.id
                   AND adjudications.cluster = ?2
                 ORDER BY adjudications.created_at_ms DESC, adjudications.rowid DESC
                 LIMIT 1)
         FROM tracks
         JOIN sources ON sources.id = tracks.source_id
         WHERE tracks.session_id = ?1
         ORDER BY tracks.id",
    )?;
    let rows = statement
        .query_map(params![session_id, SOURCE_CLUSTER], |row| {
            Ok((
                row.get::<_, String>(0)?,
                row.get::<_, String>(1)?,
                row.get::<_, Option<String>>(2)?,
            ))
        })?
        .collect::<Result<Vec<_>, _>>()?;
    Ok(rows
        .into_iter()
        .map(|(track_id, source_kind, human)| {
            let (label, label_origin) = match human {
                Some(label) => (label, "human".to_owned()),
                None => (
                    default_speaker_label(&source_kind).to_owned(),
                    "source_default".to_owned(),
                ),
            };
            CurrentSpeaker {
                track_id,
                source_kind,
                label,
                label_origin,
            }
        })
        .collect())
}

fn decided_tracks(
    speakers: &[CurrentSpeaker],
    decisions: &[SpeakerDiarizationTrackInput],
) -> Result<Vec<SpeakerDiarizationTrack>, StoreError> {
    let mut supplied: BTreeMap<&str, &str> = BTreeMap::new();
    for decision in decisions {
        if decision.track_id.is_empty()
            || supplied
                .insert(decision.track_id.as_str(), decision.disposition.as_str())
                .is_some()
        {
            return Err(StoreError::InvalidRequest(
                "diarization tracks do not match the session",
            ));
        }
    }
    if supplied.len() != speakers.len()
        || speakers
            .iter()
            .any(|speaker| !supplied.contains_key(speaker.track_id.as_str()))
    {
        return Err(StoreError::InvalidRequest(
            "diarization tracks do not match the session",
        ));
    }
    let mut tracks = Vec::with_capacity(speakers.len());
    for speaker in speakers {
        let disposition = supplied[speaker.track_id.as_str()];
        if disposition != required_disposition(&speaker.source_kind) {
            return Err(StoreError::InvalidRequest(
                "diarization disposition does not match the audio source",
            ));
        }
        tracks.push(SpeakerDiarizationTrack {
            track_id: speaker.track_id.clone(),
            source_kind: speaker.source_kind.clone(),
            disposition: disposition.to_owned(),
            label: speaker.label.clone(),
            label_origin: speaker.label_origin.clone(),
        });
    }
    Ok(tracks)
}

struct StoredRun {
    run_id: String,
    algorithm_id: String,
    clustering_state: String,
    reason: String,
    tracks: Vec<SpeakerDiarizationTrack>,
}

fn latest_run(
    transaction: &Transaction<'_>,
    session_id: &str,
) -> Result<Option<StoredRun>, StoreError> {
    let existing: Option<(String, String, String, String)> = transaction
        .query_row(
            "SELECT id, algorithm_id, clustering_state, reason
             FROM speaker_diarization_runs
             WHERE session_id = ?1
             ORDER BY created_at_ms DESC, rowid DESC
             LIMIT 1",
            [session_id],
            |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?, row.get(3)?)),
        )
        .optional()?;
    let Some((run_id, algorithm_id, clustering_state, reason)) = existing else {
        return Ok(None);
    };
    let mut statement = transaction.prepare(
        "SELECT track_id, source_kind, disposition, label, label_origin
         FROM speaker_diarization_tracks
         WHERE run_id = ?1
         ORDER BY track_id",
    )?;
    let tracks = statement
        .query_map([&run_id], |row| {
            Ok(SpeakerDiarizationTrack {
                track_id: row.get(0)?,
                source_kind: row.get(1)?,
                disposition: row.get(2)?,
                label: row.get(3)?,
                label_origin: row.get(4)?,
            })
        })?
        .collect::<Result<Vec<_>, _>>()?;
    Ok(Some(StoredRun {
        run_id,
        algorithm_id,
        clustering_state,
        reason,
        tracks,
    }))
}

impl SessionStore {
    /// Records the review decision. A second call with the same source
    /// dispositions and labels does not insert another run. Clustering other
    /// than `unavailable` is rejected. Media, transcript text, selections,
    /// and human turn names are not written.
    pub fn record_speaker_diarization(
        &mut self,
        session: &SessionId,
        algorithm_id: &str,
        clustering_state: &str,
        reason: &str,
        decisions: &[SpeakerDiarizationTrackInput],
    ) -> Result<SpeakerDiarization, StoreError> {
        if algorithm_id != ALGORITHM_ID
            || clustering_state != CLUSTERING_UNAVAILABLE
            || reason != UNAVAILABLE_REASON
        {
            return Err(StoreError::InvalidRequest(
                "diarization clustering is not calibrated",
            ));
        }
        let _writer = self.write_guard()?;
        let transaction = self.connection.transaction()?;
        require_reviewable_session(&transaction, &session.0)?;
        let speakers = current_speakers(&transaction, &session.0)?;
        let tracks = decided_tracks(&speakers, decisions)?;
        let existing = latest_run(&transaction, &session.0)?;
        if let Some(existing) = existing
            && existing.algorithm_id == algorithm_id
            && existing.clustering_state == clustering_state
            && existing.reason == reason
            && existing.tracks == tracks
        {
            return Ok(SpeakerDiarization {
                run_id: existing.run_id,
                algorithm_id: existing.algorithm_id,
                clustering_state: existing.clustering_state,
                reason: existing.reason,
                inserted: false,
                tracks,
            });
        }
        let run_id = Uuid::now_v7().to_string();
        let created_at_ms = wall_time_milliseconds();
        transaction.execute(
            "INSERT INTO speaker_diarization_runs(
                id, session_id, algorithm_id, clustering_state, reason, created_at_ms)
             VALUES(?1, ?2, ?3, ?4, ?5, ?6)",
            params![
                run_id,
                session.0,
                algorithm_id,
                clustering_state,
                reason,
                created_at_ms
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
                    track.disposition,
                    track.label,
                    track.label_origin
                ],
            )?;
        }
        transaction.commit()?;
        Ok(SpeakerDiarization {
            run_id,
            algorithm_id: algorithm_id.to_owned(),
            clustering_state: clustering_state.to_owned(),
            reason: reason.to_owned(),
            inserted: true,
            tracks,
        })
    }
}

#[cfg(test)]
mod tests {
    use super::required_disposition;

    #[test]
    fn topology_is_only_the_known_capture_sources() {
        assert_eq!(required_disposition("microphone"), "topology");
        assert_eq!(required_disposition("application_audio"), "topology");
        assert_eq!(required_disposition("system_audio"), "topology");
        assert_eq!(required_disposition("imported_audio"), "unresolved");
        assert_eq!(required_disposition("other"), "unresolved");
    }
}
