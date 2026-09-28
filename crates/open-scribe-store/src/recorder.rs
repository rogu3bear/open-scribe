//! Journal-owned recorder controls. All time positions use the capture clock;
//! platform adapters supply observations, never durable lifecycle decisions.
use super::*;

#[derive(Clone, Debug)]
pub enum RecorderAction {
    BeginPause,
    CompletePause {
        host_time: u64,
    },
    PrepareResume,
    AnchorResume {
        host_time: u64,
    },
    FinishPaused,
    Marker {
        host_time: u64,
        label: String,
    },
    SelectAudio {
        kind: Option<MediaSourceKind>,
        identity: String,
        display_name: String,
    },
    ObserveStorage {
        available_bytes: u64,
    },
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct RecorderEvent {
    pub id: String,
    pub kind: String,
    pub session_nanoseconds: i64,
    pub label: String,
}

#[derive(Clone, Debug)]
pub struct RecorderDetail {
    pub lifecycle: String,
    pub captured_nanoseconds: i64,
    pub storage_level: String,
    pub events: Vec<RecorderEvent>,
}

// One persisted policy owner. Reserve is available for sealing/recovery and is
// never spent opening another source segment under critical pressure.
const RESERVE_BYTES: u64 = 512 * 1024 * 1024;
const WARNING_BYTES: u64 = 1024 * 1024 * 1024;

impl SessionStore {
    pub fn recorder_action(
        &mut self,
        session: SessionId,
        action: RecorderAction,
    ) -> Result<RecorderDetail, StoreError> {
        let state = self.recorder_detail(&session)?;
        let phase = state.lifecycle.as_str();
        let (kind, payload) = match action {
            RecorderAction::BeginPause => {
                if phase != "recording" {
                    return Err(StoreError::InvalidState("pause requires Recording"));
                }
                ("pause_requested", json!({}))
            }
            RecorderAction::CompletePause { host_time } => {
                if phase != "finalizing" || self.has_active_segments(&session.0)? {
                    return Err(StoreError::InvalidState(
                        "pause awaits drained, sealed sources",
                    ));
                }
                self.map_capture_time(&session.0, host_time)?;
                let last_sample: i64 = self.connection.query_row(
                    "SELECT COALESCE(MAX(json_extract(payload_json, '$.final_sample_host_time')), 0)
                     FROM session_events WHERE session_id = ?1 AND event_kind = 'segment_sealed'",
                    [&session.0], |row| row.get(0),
                )?;
                if i128::from(host_time) < i128::from(last_sample) {
                    return Err(StoreError::InvalidRequest("pause precedes drained media"));
                }
                (
                    "capture_paused",
                    json!({"host_time": host_time, "session_nanoseconds": state.captured_nanoseconds}),
                )
            }
            RecorderAction::PrepareResume => {
                if phase != "paused" {
                    return Err(StoreError::InvalidState("resume requires Paused"));
                }
                self.require_storage_headroom(&session.0)?;
                (
                    "resume_requested",
                    json!({"session_nanoseconds": state.captured_nanoseconds}),
                )
            }
            RecorderAction::AnchorResume { host_time } => {
                if phase != "preparing"
                    || self
                        .latest_capture_boundary(&session.0)?
                        .as_ref()
                        .map(|(kind, _)| kind.as_str())
                        != Some("resume_requested")
                {
                    return Err(StoreError::InvalidState("resume was not requested"));
                }
                let pause = self
                    .latest_recorder_payload(&session.0, "capture_paused")?
                    .ok_or(StoreError::InvalidState("pause boundary is missing"))?;
                if host_time <= payload_u64(&pause, "host_time")? {
                    return Err(StoreError::InvalidRequest(
                        "resume host clock precedes pause",
                    ));
                }
                self.map_capture_time(&session.0, host_time)?;
                (
                    "capture_resumed",
                    json!({"host_time": host_time, "session_nanoseconds": payload_i64(&pause, "session_nanoseconds")?}),
                )
            }
            RecorderAction::FinishPaused => {
                if phase != "paused" || self.has_active_segments(&session.0)? {
                    return Err(StoreError::InvalidState(
                        "paused finalization requires sealed sources",
                    ));
                }
                (
                    "paused_session_finalized",
                    json!({"session_nanoseconds": state.captured_nanoseconds}),
                )
            }
            RecorderAction::Marker { host_time, label } => {
                if !matches!(phase, "recording" | "paused")
                    || label.len() > 512
                    || label.contains('\0')
                {
                    return Err(StoreError::InvalidRequest(
                        "marker requires capture or pause and a bounded label",
                    ));
                }
                let position = if phase == "paused" {
                    state.captured_nanoseconds
                } else {
                    self.map_capture_time(&session.0, host_time)?
                };
                (
                    "marker_added",
                    json!({"marker_id": Uuid::now_v7().to_string(), "label": label, "host_time": host_time, "session_nanoseconds": position.max(0)}),
                )
            }
            RecorderAction::SelectAudio {
                kind,
                identity,
                display_name,
            } => {
                if !matches!(phase, "preparing" | "paused")
                    || self.has_active_segments(&session.0)?
                {
                    return Err(StoreError::InvalidState(
                        "source changes require an idle boundary",
                    ));
                }
                if identity.is_empty()
                    || identity.len() > 512
                    || display_name.is_empty()
                    || display_name.len() > 512
                    || kind == Some(MediaSourceKind::Microphone)
                {
                    return Err(StoreError::InvalidRequest("invalid selected audio scope"));
                }
                // A scope change is never identity-continuous: every planned
                // non-microphone source ends and the selected kind, if any, is
                // added for the next span (ADR 0005, source and failure behavior).
                let ended: Vec<String> = {
                    let mut query = self.connection.prepare(
                        "SELECT kind FROM required_sources
                         WHERE session_id = ?1 AND kind != 'microphone' ORDER BY kind",
                    )?;
                    query
                        .query_map([&session.0], |row| row.get::<_, String>(0))?
                        .collect::<Result<_, _>>()?
                };
                let added: Vec<&str> = kind.map(MediaSourceKind::as_str).into_iter().collect();
                (
                    "source_scope_selected",
                    json!({"audio_kind": kind.map(MediaSourceKind::as_str), "identity": identity, "label": display_name, "session_nanoseconds": state.captured_nanoseconds, "ended": ended, "added": added}),
                )
            }
            RecorderAction::ObserveStorage { available_bytes } => {
                let sources = self.required_source_kinds(&session.0)?.len() as u64;
                let preflight_bytes = RESERVE_BYTES + sources * 48_000 * 2 * 300;
                let critical = available_bytes < RESERVE_BYTES
                    || (matches!(phase, "preparing" | "paused")
                        && available_bytes < preflight_bytes);
                let level = if critical {
                    "critical"
                } else if available_bytes < WARNING_BYTES {
                    "warning"
                } else {
                    "normal"
                };
                if self
                    .latest_recorder_payload(&session.0, "storage_observed")?
                    .as_ref()
                    .and_then(|p| p.get("level"))
                    .and_then(Value::as_str)
                    == Some(level)
                {
                    return Ok(state);
                }
                (
                    "storage_observed",
                    json!({"level": level, "available_bytes": available_bytes, "reserve_bytes": RESERVE_BYTES, "warning_bytes": WARNING_BYTES, "preflight_bytes": preflight_bytes, "session_nanoseconds": state.captured_nanoseconds}),
                )
            }
        };
        let record = self.append_session_journal(&session.0, kind, None, payload)?;
        self.project_recorder_event(&session.0, &record, true)?;
        self.recorder_detail(&session)
    }

    pub fn recorder_detail(&self, session: &SessionId) -> Result<RecorderDetail, StoreError> {
        let lifecycle = self.connection.query_row(
            "SELECT lifecycle FROM sessions WHERE id = ?1",
            [&session.0],
            |r| r.get(0),
        )?;
        let captured_nanoseconds: i64 = self.connection.query_row(
            "SELECT COALESCE(MAX(mapped_start_ns + sample_count * 1000000000 / 48000), 0) FROM segments WHERE session_id = ?1 AND lifecycle = 'sealed'", [&session.0], |r| r.get(0))?;
        let mut statement = self.connection.prepare("SELECT id, event_kind, session_nanoseconds, payload_json FROM session_events WHERE session_id = ?1 AND event_kind IN ('marker_added', 'capture_paused', 'capture_resumed', 'source_scope_selected', 'storage_observed') ORDER BY sequence")?;
        let events = statement
            .query_map([&session.0], |r| {
                Ok((
                    r.get::<_, String>(0)?,
                    r.get::<_, String>(1)?,
                    r.get::<_, i64>(2)?,
                    r.get::<_, String>(3)?,
                ))
            })?
            .map(|r| {
                let (id, kind, session_nanoseconds, payload) = r?;
                let payload: Value = serde_json::from_str(&payload)?;
                let label = payload
                    .get("label")
                    .or_else(|| payload.get("level"))
                    .and_then(Value::as_str)
                    .unwrap_or("")
                    .to_owned();
                Ok(RecorderEvent {
                    id,
                    kind,
                    session_nanoseconds,
                    label,
                })
            })
            .collect::<Result<_, StoreError>>()?;
        let storage_level = self
            .latest_recorder_payload(&session.0, "storage_observed")?
            .as_ref()
            .and_then(|p| p.get("level"))
            .and_then(Value::as_str)
            .unwrap_or("unchecked")
            .to_owned();
        Ok(RecorderDetail {
            lifecycle,
            captured_nanoseconds,
            storage_level,
            events,
        })
    }

    pub(super) fn latest_recorder_payload(
        &self,
        session: &str,
        kind: &str,
    ) -> Result<Option<Value>, StoreError> {
        let mut query = self.connection.prepare("SELECT payload_json FROM session_events WHERE session_id = ?1 AND event_kind = ?2 ORDER BY sequence DESC LIMIT 1")?;
        let mut rows = query.query(params![session, kind])?;
        rows.next()?
            .map(|r| -> Result<_, StoreError> {
                Ok(serde_json::from_str(&r.get::<_, String>(0)?)?)
            })
            .transpose()
    }

    pub(super) fn has_active_segments(&self, session: &str) -> Result<bool, StoreError> {
        Ok(self.connection.query_row("SELECT EXISTS(SELECT 1 FROM segments WHERE session_id = ?1 AND lifecycle IN ('opening', 'open', 'capturing'))", [session], |r| r.get(0))?)
    }

    fn latest_capture_boundary(
        &self,
        session: &str,
    ) -> Result<Option<(String, Value)>, StoreError> {
        let mut query = self.connection.prepare(
            "SELECT event_kind, payload_json FROM session_events WHERE session_id = ?1
             AND event_kind IN ('capture_paused', 'resume_requested', 'capture_resumed')
             ORDER BY sequence DESC LIMIT 1",
        )?;
        let mut rows = query.query([session])?;
        rows.next()?
            .map(|row| -> Result<_, StoreError> {
                Ok((
                    row.get(0)?,
                    serde_json::from_str(&row.get::<_, String>(1)?)?,
                ))
            })
            .transpose()
    }

    /// Old callbacks and unanchored capture cannot populate a resumed segment.
    /// Historical segments still map through their original capture interval.
    pub(super) fn require_resumed_sample(
        &self,
        session: &str,
        host: u64,
    ) -> Result<(), StoreError> {
        if let Some((kind, payload)) = self.latest_capture_boundary(session)?
            && (kind != "capture_resumed" || host < payload_u64(&payload, "host_time")?)
        {
            return Err(StoreError::InvalidState(
                "sample precedes the resume boundary",
            ));
        }
        Ok(())
    }

    pub(super) fn require_storage_headroom(&self, session: &str) -> Result<(), StoreError> {
        if self
            .latest_recorder_payload(session, "storage_observed")?
            .as_ref()
            .and_then(|p| p.get("level"))
            .and_then(Value::as_str)
            == Some("critical")
        {
            return Err(StoreError::InvalidState(
                "storage reserve prohibits opening media",
            ));
        }
        Ok(())
    }

    pub(super) fn map_resumed_time(
        &self,
        session: &str,
        clock: CaptureClock,
        host: u64,
    ) -> Result<i64, StoreError> {
        let mut query = self.connection.prepare("SELECT payload_json FROM session_events WHERE session_id = ?1 AND event_kind = 'capture_resumed' ORDER BY sequence DESC")?;
        for row in query.query_map([session], |r| r.get::<_, String>(0))? {
            let p: Value = serde_json::from_str(&row?)?;
            let resume = payload_u64(&p, "host_time")?;
            if host >= resume {
                return payload_i64(&p, "session_nanoseconds")?
                    .checked_add(
                        clock
                            .map(host)?
                            .checked_sub(clock.map(resume)?)
                            .ok_or(StoreError::IntegrityMismatch("resume duration overflow"))?,
                    )
                    .ok_or(StoreError::IntegrityMismatch("resume timeline overflow"));
            }
        }
        clock.map(host)
    }

    pub(super) fn reconcile_recorder_events(
        &mut self,
        session: &str,
        records: &[JournalRecord],
    ) -> Result<(), StoreError> {
        for record in records.iter().filter(|r| {
            matches!(
                r.body.event_kind.as_str(),
                "pause_requested"
                    | "capture_paused"
                    | "resume_requested"
                    | "capture_resumed"
                    | "paused_session_finalized"
                    | "marker_added"
                    | "source_scope_selected"
                    | "storage_observed"
            )
        }) {
            // Replay projects the event without moving the lifecycle: the row
            // already holds whatever later actions produced. The one exception
            // is a finished pause, which nothing can follow, so its lifecycle
            // effect is replayed exactly as the live action applied it.
            let apply_lifecycle = record.body.event_kind == "paused_session_finalized";
            self.project_recorder_event(session, record, apply_lifecycle)?;
        }
        Ok(())
    }

    fn project_recorder_event(
        &mut self,
        session: &str,
        record: &JournalRecord,
        apply_lifecycle: bool,
    ) -> Result<(), StoreError> {
        let present: bool = self.connection.query_row(
            "SELECT EXISTS(SELECT 1 FROM session_events WHERE id = ?1)",
            [&record.body.event_id],
            |r| r.get(0),
        )?;
        if present {
            return Ok(());
        }
        let kind = record.body.event_kind.as_str();
        let p = &record.body.payload;
        let (sequence, prior) = next_database_event(&self.connection, session)?;
        let digest = event_digest(session, sequence, kind, p, prior.as_deref())?;
        let tx = self.connection.transaction()?;
        if apply_lifecycle {
            let phase = match kind {
                "pause_requested" => Some("finalizing"),
                "capture_paused" => Some("paused"),
                "resume_requested" => Some("preparing"),
                "paused_session_finalized" => Some("ready_for_review"),
                _ => None,
            };
            if let Some(phase) = phase {
                tx.execute(
                    "UPDATE sessions SET lifecycle = ?2, updated_at_ms = ?3 WHERE id = ?1",
                    params![session, phase, record.body.wall_time_milliseconds],
                )?;
            }
        }
        if kind == "marker_added" {
            tx.execute("INSERT OR IGNORE INTO markers(id, schema_version, session_id, session_nanoseconds, label) VALUES(?1, ?2, ?3, ?4, ?5)", params![payload_string(p, "marker_id")?, SCHEMA_VERSION, session, payload_i64(p, "session_nanoseconds")?, payload_string(p, "label")?])?;
        }
        if kind == "source_scope_selected" {
            // A failed source is already retired; its failure evidence stays projected.
            tx.execute("UPDATE sources SET lifecycle = 'ended' WHERE session_id = ?1 AND kind != 'microphone' AND lifecycle != 'failed'", [session])?;
            tx.execute(
                "DELETE FROM required_sources WHERE session_id = ?1 AND kind != 'microphone'",
                [session],
            )?;
            if let Some(audio_kind) = p.get("audio_kind").and_then(Value::as_str) {
                MediaSourceKind::from_str(audio_kind)?;
                tx.execute("INSERT INTO required_sources(session_id, schema_version, kind, lifecycle) VALUES(?1, ?2, ?3, 'required')", params![session, SCHEMA_VERSION, audio_kind])?;
            }
        }
        if kind == "storage_observed" && p.get("level").and_then(Value::as_str) != Some("normal") {
            tx.execute(
                "UPDATE sessions SET health = 'degraded' WHERE id = ?1",
                [session],
            )?;
        }
        insert_event_with_id(
            &tx,
            &record.body.event_id,
            session,
            sequence,
            kind,
            record.body.wall_time_milliseconds,
            p,
            prior.as_deref(),
            &digest,
        )?;
        tx.commit()?;
        Ok(())
    }
}
