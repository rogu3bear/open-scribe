use open_scribe_types::SessionId;
use rusqlite::params;
use serde_json::{Value, json};
use uuid::Uuid;

use super::{
    JOURNAL_NAME, JournalRecord, JournalValidation, MediaSourceKind, RecoveryDisposition,
    SessionStore, StoreError, event_digest, insert_event_with_id, next_database_event,
    payload_string, validate_journal,
};

/// Bounded reason for durably retiring one capture source while another continues.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum SourceFailureReason {
    CaptureFailed,
}

impl SourceFailureReason {
    const fn as_str(self) -> &'static str {
        match self {
            Self::CaptureFailed => "capture_failed",
        }
    }

    fn from_str(value: &str) -> Result<Self, StoreError> {
        match value {
            "capture_failed" => Ok(Self::CaptureFailed),
            _ => Err(StoreError::IntegrityMismatch(
                "source failure reason is unsupported",
            )),
        }
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct SourceFailureRequest {
    pub session_id: SessionId,
    pub source_kind: MediaSourceKind,
    pub reason: SourceFailureReason,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct SourceFailureEvidence {
    pub session_id: SessionId,
    pub source_kind: MediaSourceKind,
    pub reason: SourceFailureReason,
    pub journal_durable: bool,
    pub source_failed: bool,
    pub session_degraded: bool,
    pub session_interrupted: bool,
    pub recording_continues: bool,
    pub last_journal_sequence: u64,
}

impl SessionStore {
    /// Records one already-sealed source failure while another durable source continues.
    pub fn record_source_failure(
        &mut self,
        request: SourceFailureRequest,
    ) -> Result<SourceFailureEvidence, StoreError> {
        if Uuid::parse_str(&request.session_id.0).is_err() {
            return Err(StoreError::InvalidRequest("session ID is not a UUID"));
        }
        let (session_lifecycle, source_lifecycle): (String, String) = self
            .connection
            .query_row(
                "SELECT sessions.lifecycle, required.lifecycle
                 FROM sessions
                 JOIN required_sources required ON required.session_id = sessions.id
                 WHERE sessions.id = ?1 AND required.kind = ?2",
                params![request.session_id.0, request.source_kind.as_str()],
                |row| Ok((row.get(0)?, row.get(1)?)),
            )
            .map_err(|error| match error {
                rusqlite::Error::QueryReturnedNoRows => {
                    StoreError::InvalidState("required source does not exist")
                }
                other => StoreError::Sqlite(other),
            })?;
        let journal_path = self
            .session_directory(&request.session_id.0)?
            .join(JOURNAL_NAME);
        let records = match validate_journal(&journal_path, &request.session_id.0)? {
            JournalValidation::Valid(records) => records,
            _ => return Err(StoreError::IntegrityMismatch("session journal is invalid")),
        };
        let accepted = records
            .iter()
            .filter(|record| record.body.event_kind == "source_failed")
            .filter_map(|record| {
                let source_kind = payload_string(&record.body.payload, "source_kind").ok()?;
                (source_kind == request.source_kind.as_str()).then_some(record)
            })
            .collect::<Vec<_>>();
        if accepted.len() > 1 {
            return Err(StoreError::IntegrityMismatch(
                "source failure was journaled more than once",
            ));
        }
        if let Some(accepted) = accepted.first() {
            let accepted_reason =
                SourceFailureReason::from_str(payload_string(&accepted.body.payload, "reason")?)?;
            if accepted_reason != request.reason {
                return Err(StoreError::IntegrityMismatch(
                    "repeated source failure changed accepted evidence",
                ));
            }
            if source_lifecycle == "sealed" && session_lifecycle == "recording" {
                self.project_source_failure(
                    &request.session_id.0,
                    &accepted.body.payload,
                    accepted,
                )?;
            } else if source_lifecycle != "failed"
                || !matches!(session_lifecycle.as_str(), "recording" | "interrupted")
            {
                return Err(StoreError::InvalidState(
                    "source failure projection is not replayable",
                ));
            }
            return Ok(source_failure_evidence(request, accepted.body.sequence));
        }
        if session_lifecycle != "recording" || source_lifecycle != "sealed" {
            return Err(StoreError::InvalidState(
                "source must be sealed during Recording before failure is accepted",
            ));
        }
        let continuing_sources: i64 = self.connection.query_row(
            "SELECT COUNT(*) FROM required_sources
             WHERE session_id = ?1 AND kind != ?2 AND lifecycle = 'capturing'",
            params![request.session_id.0, request.source_kind.as_str()],
            |row| row.get(0),
        )?;
        if continuing_sources == 0 {
            return Err(StoreError::InvalidState(
                "no durable source remains to continue Recording",
            ));
        }

        let payload = json!({
            "source_kind": request.source_kind.as_str(),
            "reason": request.reason.as_str(),
            "recording_continues": true,
        });
        let journal_record = self.append_session_journal(
            &request.session_id.0,
            "source_failed",
            None,
            payload.clone(),
        )?;
        self.project_source_failure(&request.session_id.0, &payload, &journal_record)?;

        Ok(source_failure_evidence(
            request,
            journal_record.body.sequence,
        ))
    }

    fn project_source_failure(
        &mut self,
        session_id: &str,
        payload: &Value,
        journal_record: &JournalRecord,
    ) -> Result<(), StoreError> {
        let source_kind = payload_string(payload, "source_kind")?;
        MediaSourceKind::from_str(source_kind)?;
        SourceFailureReason::from_str(payload_string(payload, "reason")?)?;
        if payload.get("recording_continues").and_then(Value::as_bool) != Some(true) {
            return Err(StoreError::IntegrityMismatch(
                "source failure continuation evidence is invalid",
            ));
        }
        let (event_sequence, prior_digest) = next_database_event(&self.connection, session_id)?;
        let digest = event_digest(
            session_id,
            event_sequence,
            "source_failed",
            payload,
            prior_digest.as_deref(),
        )?;
        let transaction = self.connection.transaction()?;
        let source_changed = transaction.execute(
            "UPDATE sources SET lifecycle = 'failed'
             WHERE session_id = ?1 AND kind = ?2 AND lifecycle = 'sealed'",
            params![session_id, source_kind],
        )?;
        let required_changed = transaction.execute(
            "UPDATE required_sources SET lifecycle = 'failed'
             WHERE session_id = ?1 AND kind = ?2 AND lifecycle = 'sealed'",
            params![session_id, source_kind],
        )?;
        let session_changed = transaction.execute(
            "UPDATE sessions SET health = 'degraded', updated_at_ms = ?2
             WHERE id = ?1 AND lifecycle = 'recording'",
            params![session_id, journal_record.body.wall_time_milliseconds],
        )?;
        if source_changed != 1 || required_changed != 1 || session_changed != 1 {
            return Err(StoreError::InvalidState(
                "source failure projection is not awaiting evidence",
            ));
        }
        let continuing_sources: i64 = transaction.query_row(
            "SELECT COUNT(*) FROM required_sources
             WHERE session_id = ?1 AND lifecycle = 'capturing'",
            [session_id],
            |row| row.get(0),
        )?;
        if continuing_sources == 0 {
            return Err(StoreError::InvalidState(
                "source failure projection has no continuing source",
            ));
        }
        insert_event_with_id(
            &transaction,
            &journal_record.body.event_id,
            session_id,
            event_sequence,
            "source_failed",
            journal_record.body.wall_time_milliseconds,
            payload,
            prior_digest.as_deref(),
            &digest,
        )?;
        transaction.commit()?;
        Ok(())
    }

    pub(super) fn reconcile_source_failures(
        &mut self,
        session_id: &str,
        records: &[JournalRecord],
        base: RecoveryDisposition,
    ) -> Result<RecoveryDisposition, StoreError> {
        let failures = records
            .iter()
            .filter(|record| record.body.event_kind == "source_failed")
            .collect::<Vec<_>>();
        if failures.is_empty() {
            return Ok(base);
        }
        let last_failure = failures.last().expect("non-empty source failures");
        let trailing = &records[last_failure.body.sequence as usize..];
        if trailing.len() > 1
            || trailing
                .first()
                .is_some_and(|record| record.body.event_kind != "session_interrupted")
        {
            return Ok(RecoveryDisposition::IntegrityMismatch);
        }

        let required_source_count: i64 = self.connection.query_row(
            "SELECT COUNT(*) FROM required_sources WHERE session_id = ?1",
            [session_id],
            |row| row.get(0),
        )?;
        if failures.len() >= usize::try_from(required_source_count).unwrap_or(0) {
            return Ok(RecoveryDisposition::IntegrityMismatch);
        }

        let mut seen = std::collections::BTreeSet::new();
        let mut unprojected = None;
        for (index, failure) in failures.iter().enumerate() {
            let source_kind =
                MediaSourceKind::from_str(payload_string(&failure.body.payload, "source_kind")?)?;
            SourceFailureReason::from_str(payload_string(&failure.body.payload, "reason")?)?;
            if failure
                .body
                .payload
                .get("recording_continues")
                .and_then(Value::as_bool)
                != Some(true)
                || !seen.insert(source_kind.as_str())
            {
                return Ok(RecoveryDisposition::IntegrityMismatch);
            }
            let (session_lifecycle, session_health, source_lifecycle, required_lifecycle): (
                String,
                String,
                String,
                String,
            ) = self.connection.query_row(
                "SELECT sessions.lifecycle, sessions.health, sources.lifecycle,
                            required.lifecycle
                     FROM sessions
                     JOIN required_sources required ON required.session_id = sessions.id
                     JOIN sources ON sources.session_id = sessions.id
                                 AND sources.kind = required.kind
                     WHERE sessions.id = ?1 AND required.kind = ?2",
                params![session_id, source_kind.as_str()],
                |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?, row.get(3)?)),
            )?;
            let event_projected: bool = self.connection.query_row(
                "SELECT EXISTS(
                   SELECT 1 FROM session_events
                   WHERE session_id = ?1 AND id = ?2 AND event_kind = 'source_failed'
                 )",
                params![session_id, failure.body.event_id],
                |row| row.get(0),
            )?;
            if event_projected {
                if !matches!(session_lifecycle.as_str(), "recording" | "interrupted")
                    || session_health != "degraded"
                    || source_lifecycle != "failed"
                    || required_lifecycle != "failed"
                {
                    return Ok(RecoveryDisposition::IntegrityMismatch);
                }
                continue;
            }
            if index + 1 != failures.len()
                || unprojected.is_some()
                || session_lifecycle != "recording"
                || source_lifecycle != "sealed"
                || required_lifecycle != "sealed"
            {
                return Ok(RecoveryDisposition::IntegrityMismatch);
            }
            unprojected = Some(*failure);
        }
        if let Some(failure) = unprojected {
            self.project_source_failure(session_id, &failure.body.payload, failure)?;
        }
        Ok(if unprojected.is_some() {
            RecoveryDisposition::SourceFailureProjectionRepaired
        } else {
            RecoveryDisposition::SourceFailedRecording
        })
    }
}

fn source_failure_evidence(request: SourceFailureRequest, sequence: u64) -> SourceFailureEvidence {
    SourceFailureEvidence {
        session_id: request.session_id,
        source_kind: request.source_kind,
        reason: request.reason,
        journal_durable: true,
        source_failed: true,
        session_degraded: true,
        session_interrupted: false,
        recording_continues: true,
        last_journal_sequence: sequence,
    }
}

#[cfg(test)]
mod tests {
    use std::fs::{self, OpenOptions};
    use std::io::Write;

    use tempfile::TempDir;

    use super::*;
    use crate::{
        AuthorizeMediaOpenRequest, FirstSampleReceipt, MediaOpenAuthorization, MediaOpenReceipt,
        PrepareSessionRequest, SealSegmentReceipt, SessionOrigin,
    };

    #[test]
    fn three_required_sources_accept_two_failures_and_keep_one_recording() {
        let temp = TempDir::new().unwrap();
        let mut store = SessionStore::open(temp.path().join("Open Scribe")).unwrap();
        let (session_id, microphone, application, system) = prepared_three_sources(&mut store);

        let first = fail_source(&mut store, &system);
        assert_eq!(
            store
                .record_source_failure(SourceFailureRequest {
                    session_id: session_id.clone(),
                    source_kind: MediaSourceKind::SystemAudio,
                    reason: SourceFailureReason::CaptureFailed,
                })
                .unwrap(),
            first
        );
        let second = fail_source(&mut store, &application);
        assert_eq!(
            store
                .record_source_failure(SourceFailureRequest {
                    session_id: session_id.clone(),
                    source_kind: MediaSourceKind::ApplicationAudio,
                    reason: SourceFailureReason::CaptureFailed,
                })
                .unwrap(),
            second
        );

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
                .map(|source| (source.kind, source.lifecycle.as_str()))
                .collect::<Vec<_>>(),
            [
                (MediaSourceKind::ApplicationAudio, "failed"),
                (MediaSourceKind::Microphone, "capturing"),
                (MediaSourceKind::SystemAudio, "failed"),
            ]
        );
        assert!(microphone.absolute_path.is_file());
        assert_eq!(source_failure_event_count(&store, &session_id.0), 2);
    }

    #[test]
    fn restart_accepts_two_projected_failures_for_three_required_sources() {
        let temp = TempDir::new().unwrap();
        let root = temp.path().join("Open Scribe");
        let session_id;
        {
            let mut store = SessionStore::open(&root).unwrap();
            let (prepared, _, application, system) = prepared_three_sources(&mut store);
            session_id = prepared;
            fail_source(&mut store, &system);
            fail_source(&mut store, &application);
        }

        let mut reopened = SessionStore::open(&root).unwrap();
        assert_eq!(
            reopened.recover_preparations().unwrap()[0].disposition,
            RecoveryDisposition::SourceFailedRecording
        );
        assert_eq!(
            reopened.recover_preparations().unwrap()[0].disposition,
            RecoveryDisposition::SourceFailedRecording
        );
        assert_eq!(source_failure_event_count(&reopened, &session_id.0), 2);
    }

    #[test]
    fn restart_repairs_only_the_journaled_second_source_failure() {
        let temp = TempDir::new().unwrap();
        let root = temp.path().join("Open Scribe");
        let session_id;
        {
            let mut store = SessionStore::open(&root).unwrap();
            let (prepared, _, application, system) = prepared_three_sources(&mut store);
            session_id = prepared;
            fail_source(&mut store, &system);
            seal_source(&mut store, &application);
            store
                .append_session_journal(
                    &session_id.0,
                    "source_failed",
                    None,
                    json!({
                        "source_kind": MediaSourceKind::ApplicationAudio.as_str(),
                        "reason": SourceFailureReason::CaptureFailed.as_str(),
                        "recording_continues": true,
                    }),
                )
                .unwrap();
        }

        let mut reopened = SessionStore::open(&root).unwrap();
        assert_eq!(
            reopened.recover_preparations().unwrap()[0].disposition,
            RecoveryDisposition::SourceFailureProjectionRepaired
        );
        assert_eq!(
            reopened.recover_preparations().unwrap()[0].disposition,
            RecoveryDisposition::SourceFailedRecording
        );
        assert_eq!(source_failure_event_count(&reopened, &session_id.0), 2);
    }

    fn prepared_three_sources(
        store: &mut SessionStore,
    ) -> (
        SessionId,
        MediaOpenAuthorization,
        MediaOpenAuthorization,
        MediaOpenAuthorization,
    ) {
        let prepared = store
            .prepare_session_with_required_sources(
                PrepareSessionRequest {
                    title: "Three-source recording".to_owned(),
                    origin: SessionOrigin::Capture,
                },
                vec![
                    MediaSourceKind::Microphone,
                    MediaSourceKind::ApplicationAudio,
                    MediaSourceKind::SystemAudio,
                ],
            )
            .unwrap();
        let microphone = open_source(store, &prepared.session_id, MediaSourceKind::Microphone);
        let application = open_source(
            store,
            &prepared.session_id,
            MediaSourceKind::ApplicationAudio,
        );
        let system = open_source(store, &prepared.session_id, MediaSourceKind::SystemAudio);
        accept_first_sample(store, &microphone);
        accept_first_sample(store, &application);
        accept_first_sample(store, &system);
        store
            .confirm_recording(prepared.session_id.clone())
            .unwrap();
        (prepared.session_id, microphone, application, system)
    }

    fn open_source(
        store: &mut SessionStore,
        session_id: &SessionId,
        kind: MediaSourceKind,
    ) -> MediaOpenAuthorization {
        let authorization = store
            .authorize_media_open(AuthorizeMediaOpenRequest {
                session_id: session_id.clone(),
                source_kind: kind,
                source_display_name: format!("{kind:?}"),
            })
            .unwrap();
        let mut file = OpenOptions::new()
            .create_new(true)
            .write(true)
            .open(&authorization.absolute_path)
            .unwrap();
        file.write_all(b"caff\0\x01\0\0deterministic-test-media")
            .unwrap();
        file.sync_all().unwrap();
        let initial_byte_length = file.metadata().unwrap().len();
        drop(file);
        store
            .accept_media_open(MediaOpenReceipt {
                session_id: authorization.session_id.clone(),
                track_id: authorization.track_id.clone(),
                segment_id: authorization.segment_id.clone(),
                open_token: authorization.open_token.clone(),
                writer_generation: authorization.writer_generation,
                relative_path: authorization.relative_path.clone(),
                media_format: authorization.media_format.clone(),
                sample_rate_hz: authorization.sample_rate_hz,
                channels: authorization.channels,
                initial_byte_length,
            })
            .unwrap();
        authorization
    }

    fn accept_first_sample(store: &mut SessionStore, authorization: &MediaOpenAuthorization) {
        let mut file = OpenOptions::new()
            .append(true)
            .open(&authorization.absolute_path)
            .unwrap();
        file.write_all(b"first-captured-sample").unwrap();
        file.sync_all().unwrap();
        let observed_byte_length = file.metadata().unwrap().len();
        drop(file);
        store
            .accept_first_sample(FirstSampleReceipt {
                session_id: authorization.session_id.clone(),
                track_id: authorization.track_id.clone(),
                segment_id: authorization.segment_id.clone(),
                open_token: authorization.open_token.clone(),
                writer_generation: authorization.writer_generation,
                relative_path: authorization.relative_path.clone(),
                first_sample_host_time: 42_000,
                first_sample_frame_count: 480,
                observed_byte_length,
            })
            .unwrap();
    }

    fn fail_source(
        store: &mut SessionStore,
        authorization: &MediaOpenAuthorization,
    ) -> SourceFailureEvidence {
        seal_source(store, authorization);
        store
            .record_source_failure(SourceFailureRequest {
                session_id: authorization.session_id.clone(),
                source_kind: source_kind(authorization, store),
                reason: SourceFailureReason::CaptureFailed,
            })
            .unwrap()
    }

    fn source_kind(
        authorization: &MediaOpenAuthorization,
        store: &SessionStore,
    ) -> MediaSourceKind {
        let kind: String = store
            .connection
            .query_row(
                "SELECT sources.kind FROM tracks
                 JOIN sources ON sources.id = tracks.source_id
                 WHERE tracks.id = ?1",
                [&authorization.track_id],
                |row| row.get(0),
            )
            .unwrap();
        MediaSourceKind::from_str(&kind).unwrap()
    }

    fn seal_source(store: &mut SessionStore, authorization: &MediaOpenAuthorization) {
        replace_with_recoverable_pcm_caf(authorization, 960);
        let final_byte_length = fs::metadata(&authorization.absolute_path).unwrap().len();
        store
            .seal_segment(SealSegmentReceipt {
                session_id: authorization.session_id.clone(),
                track_id: authorization.track_id.clone(),
                segment_id: authorization.segment_id.clone(),
                open_token: authorization.open_token.clone(),
                writer_generation: authorization.writer_generation,
                relative_path: authorization.relative_path.clone(),
                final_sample_host_time: 52_000,
                sample_count: 960,
                final_byte_length,
            })
            .unwrap();
    }

    fn replace_with_recoverable_pcm_caf(authorization: &MediaOpenAuthorization, sample_count: u64) {
        let mut file = OpenOptions::new()
            .write(true)
            .truncate(true)
            .open(&authorization.absolute_path)
            .unwrap();
        file.write_all(super::super::CAF_HEADER).unwrap();
        file.write_all(b"desc").unwrap();
        file.write_all(&32_i64.to_be_bytes()).unwrap();
        file.write_all(&48_000_f64.to_bits().to_be_bytes()).unwrap();
        file.write_all(b"lpcm").unwrap();
        file.write_all(&2_u32.to_be_bytes()).unwrap();
        file.write_all(&2_u32.to_be_bytes()).unwrap();
        file.write_all(&1_u32.to_be_bytes()).unwrap();
        file.write_all(&1_u32.to_be_bytes()).unwrap();
        file.write_all(&16_u32.to_be_bytes()).unwrap();
        file.write_all(b"data").unwrap();
        file.write_all(&(-1_i64).to_be_bytes()).unwrap();
        file.write_all(&0_u32.to_be_bytes()).unwrap();
        file.write_all(&vec![0_u8; sample_count as usize * 2])
            .unwrap();
        file.sync_all().unwrap();
    }

    fn source_failure_event_count(store: &SessionStore, session_id: &str) -> i64 {
        store
            .connection
            .query_row(
                "SELECT COUNT(*) FROM session_events
                 WHERE session_id = ?1 AND event_kind = 'source_failed'",
                [session_id],
                |row| row.get(0),
            )
            .unwrap()
    }
}
