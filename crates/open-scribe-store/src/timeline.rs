//! Durable host-clock meaning and coarse segment boundaries. No media callbacks.
use super::*;

#[cfg(test)]
#[path = "timeline_tests.rs"]
mod tests;

#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize, Deserialize)]
pub struct CaptureClock {
    pub host_anchor: u64,
    pub numerator: u32,
    pub denominator: u32,
}

impl CaptureClock {
    pub fn map(self, host_time: u64) -> Result<i64, StoreError> {
        if self.host_anchor == 0 || self.numerator == 0 || self.denominator == 0 {
            return Err(StoreError::InvalidRequest("invalid native host clock"));
        }
        let ticks = i128::from(host_time) - i128::from(self.host_anchor);
        i64::try_from(ticks * i128::from(self.numerator) / i128::from(self.denominator))
            .map_err(|_| StoreError::InvalidRequest("host timestamp exceeds session timeline"))
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct TimelineSegment {
    pub session_id: SessionId,
    pub source_id: String,
    pub track_id: String,
    pub segment_id: String,
    pub sequence: u64,
    pub start_nanoseconds: i64,
    pub native_start_nanoseconds: i64,
    pub clock_adjustment_nanoseconds: i64,
    pub sample_count: u64,
    pub channels: u16,
    pub gap_nanoseconds: i64,
}

impl SessionStore {
    pub(super) fn annotate_segment_timing(
        &self,
        session: &str,
        first: &Value,
        seal: &mut Value,
    ) -> Result<(), StoreError> {
        if let Some(clock) = self.capture_clock(session)? {
            let start = self.map_resumed_time(
                session,
                clock,
                payload_u64(first, "first_sample_host_time")?,
            )?;
            let end = self.map_resumed_time(
                session,
                clock,
                payload_u64(seal, "final_sample_host_time")?,
            )?;
            let duration = i128::from(payload_u64(seal, "sample_count")?) * 1_000_000_000
                / i128::from(MEDIA_SAMPLE_RATE_HZ);
            let drift =
                i64::try_from(i128::from(end) - i128::from(start) - duration).map_err(|_| {
                    StoreError::IntegrityMismatch("segment drift exceeds timeline range")
                })?;
            seal["session_nanoseconds"] = json!(end);
            seal["measured_drift_nanoseconds"] = json!(drift);
            seal["sample_rate_hz"] = json!(MEDIA_SAMPLE_RATE_HZ);
        }
        Ok(())
    }

    pub fn anchor_capture_clock(
        &mut self,
        session: SessionId,
        clock: CaptureClock,
    ) -> Result<(), StoreError> {
        clock.map(clock.host_anchor)?;
        if let Some(existing) = self.capture_clock(&session.0)? {
            return if existing == clock {
                Ok(())
            } else {
                Err(StoreError::IntegrityMismatch(
                    "capture clock anchor is immutable",
                ))
            };
        }
        let allowed: bool = self.connection.query_row(
            "SELECT lifecycle = 'preparing' AND journal_durable = 1 AND NOT EXISTS(
                SELECT 1 FROM segments WHERE session_id = ?1 AND original_start IS NOT NULL
             ) FROM sessions WHERE id = ?1",
            [&session.0],
            |row| row.get(0),
        )?;
        if !allowed {
            return Err(StoreError::InvalidState("clock must precede capture"));
        }
        let mut payload = serde_json::to_value(clock)?;
        // Persist playback meaning with the clock. Original mapped timestamps
        // and PCM remain immutable; policy 1 bounds any playback-only alignment.
        payload["playback_alignment_version"] = json!(1);
        let record =
            self.append_session_journal(&session.0, "capture_clock_anchored", None, payload)?;
        self.project_clock(&session.0, &record)
    }

    /// Source kinds with capture evidence: at least one segment reached a first
    /// sample. Required-source rows are a plan for one capture span; a kind
    /// planned for a span that never captured (a scope selected while paused,
    /// a source retired before its first sample) imposes no playback
    /// requirement. Every evidenced kind must still validate completely.
    pub(super) fn evidenced_source_kinds(
        &self,
        session: &str,
    ) -> Result<BTreeSet<String>, StoreError> {
        let mut query = self.connection.prepare(
            "SELECT DISTINCT sources.kind FROM segments
             JOIN tracks ON tracks.id = segments.track_id
             JOIN sources ON sources.id = tracks.source_id
             WHERE segments.session_id = ?1 AND segments.original_start IS NOT NULL",
        )?;
        let kinds = query
            .query_map([session], |row| row.get::<_, String>(0))?
            .collect::<Result<BTreeSet<_>, _>>()?;
        Ok(kinds)
    }

    pub(super) fn capture_clock(&self, session: &str) -> Result<Option<CaptureClock>, StoreError> {
        let mut query = self.connection.prepare(
            "SELECT payload_json FROM session_events WHERE session_id = ?1 AND event_kind = 'capture_clock_anchored'"
        )?;
        let mut rows = query.query([session])?;
        rows.next()?
            .map(|row| -> Result<_, StoreError> {
                Ok(serde_json::from_str(&row.get::<_, String>(0)?)?)
            })
            .transpose()
    }

    pub(super) fn map_capture_time(&self, session: &str, host: u64) -> Result<i64, StoreError> {
        // Older captures have no calibrated clock; retain their legacy meaning.
        // They cannot obtain a synchronized playback plan.
        self.capture_clock(session)?
            .map_or(Ok(0), |clock| self.map_resumed_time(session, clock, host))
    }

    pub(super) fn reconcile_clock(
        &mut self,
        session: &str,
        records: &[JournalRecord],
    ) -> Result<(), StoreError> {
        for record in records
            .iter()
            .filter(|r| r.body.event_kind == "capture_clock_anchored")
        {
            let clock: CaptureClock = serde_json::from_value(record.body.payload.clone())?;
            clock.map(clock.host_anchor)?;
            if let Some(existing) = self.capture_clock(session)? {
                if clock != existing {
                    return Err(StoreError::IntegrityMismatch("capture clock changed"));
                }
            } else {
                self.project_clock(session, record)?;
            }
        }
        Ok(())
    }

    fn project_clock(&mut self, session: &str, record: &JournalRecord) -> Result<(), StoreError> {
        let (sequence, prior) = next_database_event(&self.connection, session)?;
        let digest = event_digest(
            session,
            sequence,
            "capture_clock_anchored",
            &record.body.payload,
            prior.as_deref(),
        )?;
        let tx = self.connection.transaction()?;
        insert_event_with_id(
            &tx,
            &record.body.event_id,
            session,
            sequence,
            "capture_clock_anchored",
            record.body.wall_time_milliseconds,
            &record.body.payload,
            prior.as_deref(),
            &digest,
        )?;
        tx.commit()?;
        Ok(())
    }

    /// Reserve one successor before sealing its predecessor. A reservation is
    /// not capture evidence; recovery preserves an empty/missing successor as a gap.
    /// A capturing source may rotate before Recording is confirmed: a timestamp
    /// discontinuity or format change on an early buffer seals like any other
    /// (ADR 0005 segment rules), and the session stays `preparing` until every
    /// required source has durable first-sample evidence.
    pub fn authorize_next_segment(
        &mut self,
        session: SessionId,
        previous: String,
    ) -> Result<MediaOpenAuthorization, StoreError> {
        self.require_storage_headroom(&session.0)?;
        if self.capture_clock(&session.0)?.is_none() {
            return Err(StoreError::InvalidState(
                "rotation requires a calibrated session clock",
            ));
        }
        // A later segment that is an abandoned, never-captured gap does not
        // replace its predecessor; the successor is numbered after it.
        let (source_id, source_kind, display, track_id, sequence, channels): (String, String, String, String, i64, i64) = self.connection.query_row(
            "SELECT sources.id, sources.kind, sources.display_name, tracks.id,
                    (SELECT MAX(sequence) FROM segments track_segments WHERE track_segments.track_id = tracks.id),
                    segments.channels
             FROM segments JOIN tracks ON tracks.id = segments.track_id
             JOIN sources ON sources.id = tracks.source_id JOIN sessions ON sessions.id = segments.session_id
             WHERE segments.id = ?1 AND sessions.id = ?2
               AND ((sessions.lifecycle IN ('preparing', 'recording', 'finalizing') AND sources.lifecycle = 'capturing' AND segments.lifecycle = 'capturing')
                 OR (sessions.lifecycle = 'preparing' AND sources.lifecycle = 'sealed' AND segments.lifecycle = 'sealed'
                    AND EXISTS(SELECT 1 FROM session_events WHERE session_id = ?2 AND event_kind = 'resume_requested')))
               AND NOT EXISTS(SELECT 1 FROM segments later WHERE later.track_id = tracks.id AND later.sequence > segments.sequence
                   AND NOT (later.lifecycle = 'gap' AND later.original_start IS NULL))",
            params![previous, session.0], |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?, row.get(3)?, row.get(4)?, row.get(5)?)),
        ).map_err(|e| match e {
            rusqlite::Error::QueryReturnedNoRows => StoreError::InvalidState("source is not ready for one successor"),
            e => StoreError::Sqlite(e),
        })?;
        let sequence = sequence
            .checked_add(1)
            .ok_or(StoreError::InvalidState("segment sequence exhausted"))?;
        if channels != 1 && channels != 2 {
            return Err(StoreError::IntegrityMismatch(
                "invalid source channel layout",
            ));
        }
        let generation = u64::try_from(
            sequence
                .checked_add(1)
                .ok_or(StoreError::InvalidState("segment generation exhausted"))?,
        )
        .map_err(|_| StoreError::InvalidState("invalid segment generation"))?;
        let segment_id = Uuid::now_v7().to_string();
        let open_token = Uuid::now_v7().to_string();
        let relative_path = format!("audio/{track_id}/{sequence:06}-0.caf");
        let absolute_path = self.session_directory(&session.0)?.join(&relative_path);
        if fs::symlink_metadata(&absolute_path).is_ok() {
            return Err(StoreError::IntegrityMismatch(
                "successor media path already exists",
            ));
        }
        let payload = json!({
            "source_id": source_id, "source_kind": source_kind, "source_display_name": display,
            "track_id": track_id, "segment_id": segment_id, "open_token": open_token,
            "writer_generation": generation, "segment_sequence": sequence,
            "relative_path": relative_path, "media_format": MEDIA_FORMAT_CAF_PCM_S16LE,
            "sample_rate_hz": MEDIA_SAMPLE_RATE_HZ, "channels": channels, "mapped_start_nanoseconds": 0,
        });
        let record = self.append_session_journal(
            &session.0,
            "segment_open_intent",
            Some(&relative_path),
            payload.clone(),
        )?;
        self.project_media_authorization(&session.0, &payload, &record)?;
        self.connection.execute(
            "UPDATE sources SET lifecycle = 'opening' WHERE id = ?1 AND lifecycle = 'sealed'",
            [&source_id],
        )?;
        self.connection.execute(
            "UPDATE tracks SET lifecycle = 'opening' WHERE id = ?1 AND lifecycle = 'sealed'",
            [&track_id],
        )?;
        Ok(MediaOpenAuthorization {
            session_id: session,
            source_id,
            track_id,
            segment_id,
            open_token,
            writer_generation: generation,
            relative_path,
            absolute_path,
            media_format: MEDIA_FORMAT_CAF_PCM_S16LE.to_owned(),
            sample_rate_hz: MEDIA_SAMPLE_RATE_HZ,
            channels: channels as u16,
            mapped_start_nanoseconds: 0,
        })
    }

    /// Durably abandons a reserved-but-unopened successor segment during live
    /// rotation. A rotation reserves and opens the successor before sealing the
    /// predecessor; if a later step fails, this records an explicit gap for the
    /// successor so the predecessor stays the active segment and a later seal can
    /// still finalize the session. The segment must be the latest in its track,
    /// hold no first sample, and belong to a still-capturing source. Idempotent:
    /// a segment already gapped returns success without a second event.
    pub fn abandon_reserved_segment(
        &mut self,
        session: SessionId,
        segment: String,
    ) -> Result<(), StoreError> {
        let (lifecycle, track_id, relative_path, original_start): (
            String,
            String,
            String,
            Option<i64>,
        ) = self
            .connection
            .query_row(
                "SELECT lifecycle, track_id, relative_path, original_start
                 FROM segments WHERE id = ?1 AND session_id = ?2",
                params![segment, session.0],
                |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?, row.get(3)?)),
            )
            .map_err(|error| match error {
                rusqlite::Error::QueryReturnedNoRows => {
                    StoreError::InvalidState("abandoned segment does not exist")
                }
                other => StoreError::Sqlite(other),
            })?;
        if lifecycle == "gap" {
            return Ok(());
        }
        let abandonable: bool = self.connection.query_row(
            "SELECT EXISTS(
               SELECT 1 FROM segments
               JOIN tracks ON tracks.id = segments.track_id
               JOIN sources ON sources.id = tracks.source_id
               JOIN sessions ON sessions.id = segments.session_id
               WHERE segments.id = ?1 AND segments.session_id = ?2
                 AND segments.lifecycle IN ('opening', 'open')
                 AND segments.original_start IS NULL
                 AND sources.lifecycle = 'capturing'
                 AND sessions.lifecycle IN ('recording', 'finalizing')
                 AND NOT EXISTS(
                     SELECT 1 FROM segments later
                     WHERE later.track_id = segments.track_id
                       AND later.sequence > segments.sequence))",
            params![segment, session.0],
            |row| row.get(0),
        )?;
        if original_start.is_some() || !abandonable {
            return Err(StoreError::InvalidState(
                "segment is not an abandonable reserved successor",
            ));
        }
        let record = self.append_session_journal(
            &session.0,
            "segment_capture_gap",
            Some(&relative_path),
            json!({
                "segment_id": segment, "track_id": track_id, "relative_path": relative_path,
                "reason": "reserved_successor_abandoned", "media_preserved": true,
            }),
        )?;
        let (sequence, prior) = next_database_event(&self.connection, &session.0)?;
        let digest = event_digest(
            &session.0,
            sequence,
            "segment_capture_gap",
            &record.body.payload,
            prior.as_deref(),
        )?;
        let now = wall_time_milliseconds();
        let tx = self.connection.transaction()?;
        tx.execute(
            "UPDATE segments SET lifecycle = 'gap', recovery_state = 'gap'
             WHERE id = ?1 AND session_id = ?2",
            params![segment, session.0],
        )?;
        // A successor abandoned after its predecessor sealed leaves the track
        // with no active segment: the source rests on its sealed media, as a
        // seal would leave it, so a source failure can retire it.
        let active: bool = tx.query_row(
            "SELECT EXISTS(SELECT 1 FROM segments
             WHERE track_id = ?1 AND lifecycle IN ('opening', 'open', 'capturing'))",
            [&track_id],
            |row| row.get(0),
        )?;
        if !active {
            tx.execute(
                "UPDATE tracks SET lifecycle = 'sealed'
                 WHERE id = ?1 AND session_id = ?2 AND lifecycle = 'capturing'",
                params![track_id, session.0],
            )?;
            tx.execute(
                "UPDATE sources SET lifecycle = 'sealed'
                 WHERE id = (SELECT source_id FROM tracks WHERE id = ?1)
                   AND session_id = ?2 AND lifecycle = 'capturing'",
                params![track_id, session.0],
            )?;
            tx.execute(
                "UPDATE required_sources SET lifecycle = 'sealed'
                 WHERE session_id = ?1 AND kind = (
                     SELECT sources.kind FROM sources
                     JOIN tracks ON tracks.source_id = sources.id
                     WHERE tracks.id = ?2)",
                params![session.0, track_id],
            )?;
        }
        tx.execute(
            "UPDATE sessions SET media_files_open = EXISTS(
                 SELECT 1 FROM segments
                 WHERE session_id = ?1 AND lifecycle IN ('opening', 'open', 'capturing')
             ), updated_at_ms = ?2 WHERE id = ?1",
            params![session.0, now],
        )?;
        insert_event_with_id(
            &tx,
            &record.body.event_id,
            &session.0,
            sequence,
            "segment_capture_gap",
            record.body.wall_time_milliseconds,
            &record.body.payload,
            prior.as_deref(),
            &digest,
        )?;
        tx.commit()?;
        Ok(())
    }

    /// A shared, signed timeline. Gaps are preserved rather than concatenated away.
    /// Consumers must also obtain validated media leases before scheduling output.
    pub fn playback_timeline(
        &self,
        session: &SessionId,
    ) -> Result<Vec<TimelineSegment>, StoreError> {
        let clock = self
            .capture_clock(&session.0)?
            .ok_or(StoreError::InvalidState(
                "capture has no calibrated timeline",
            ))?;
        let records = match validate_journal(
            &self.session_directory(&session.0)?.join(JOURNAL_NAME),
            &session.0,
        )? {
            JournalValidation::Valid(records) => records,
            _ => return Err(StoreError::IntegrityMismatch("playback journal is invalid")),
        };
        let sources = self.validate_sealed_recovery_companions(&session.0, &records)?;
        let accepted_clock = records
            .iter()
            .find(|r| r.body.event_kind == "capture_clock_anchored")
            .ok_or(StoreError::IntegrityMismatch(
                "timeline clock lacks journal evidence",
            ))?;
        if serde_json::from_value::<CaptureClock>(accepted_clock.body.payload.clone())? != clock {
            return Err(StoreError::IntegrityMismatch(
                "timeline clock changed accepted evidence",
            ));
        }
        let alignment_version = match accepted_clock
            .body
            .payload
            .get("playback_alignment_version")
        {
            None => 0,
            Some(value) => value.as_u64().ok_or(StoreError::IntegrityMismatch(
                "invalid timeline alignment version",
            ))?,
        };
        if alignment_version > 1 {
            return Err(StoreError::InvalidState(
                "unsupported timeline alignment version",
            ));
        }
        if self
            .evidenced_source_kinds(&session.0)?
            .iter()
            .any(|kind| !sources.contains(kind))
        {
            return Err(StoreError::InvalidState(
                "timeline is missing a required source",
            ));
        }
        let mut statement = self.connection.prepare(
            "SELECT sources.id, tracks.id, segments.id, segments.sequence, segments.mapped_start_ns,
                    segments.sample_count, segments.original_start, segments.channels
             FROM sessions JOIN segments ON segments.session_id = sessions.id
             JOIN tracks ON tracks.id = segments.track_id JOIN sources ON sources.id = tracks.source_id
             WHERE sessions.id = ?1 AND sessions.lifecycle = 'ready_for_review' AND segments.lifecycle = 'sealed'
             ORDER BY tracks.id, segments.sequence"
        )?;
        let rows = statement.query_map([&session.0], |row| {
            Ok((
                row.get::<_, String>(0)?,
                row.get::<_, String>(1)?,
                row.get::<_, String>(2)?,
                row.get::<_, i64>(3)?,
                row.get::<_, i64>(4)?,
                row.get::<_, i64>(5)?,
                row.get::<_, i64>(6)?,
                row.get::<_, i64>(7)?,
            ))
        })?;
        let mut ends = BTreeMap::new();
        let mut result = Vec::new();
        for row in rows {
            let (source_id, track_id, segment_id, sequence, start, samples, host, channels) = row?;
            if samples <= 0
                || sequence < 0
                || (channels != 1 && channels != 2)
                || self.map_resumed_time(&session.0, clock, host as u64)? != start
            {
                return Err(StoreError::IntegrityMismatch(
                    "invalid durable timeline segment",
                ));
            }
            let first = journal_record_for_segment(&records, "first_sample_captured", &segment_id)?
                .ok_or(StoreError::IntegrityMismatch(
                    "timeline lacks original timestamp evidence",
                ))?;
            if payload_u64(&first.body.payload, "first_sample_host_time")? != host as u64
                || payload_i64(&first.body.payload, "first_sample_session_nanoseconds")? != start
            {
                return Err(StoreError::IntegrityMismatch(
                    "timeline changed accepted timestamp evidence",
                ));
            }
            let duration = i64::try_from(
                i128::from(samples) * 1_000_000_000 / i128::from(MEDIA_SAMPLE_RATE_HZ),
            )
            .map_err(|_| StoreError::IntegrityMismatch("timeline duration overflow"))?;
            let (playback_start, gap) =
                align_playback_start(start, ends.get(&track_id).copied(), alignment_version)?;
            ends.insert(
                track_id.clone(),
                playback_start
                    .checked_add(duration)
                    .ok_or(StoreError::IntegrityMismatch("timeline end overflow"))?,
            );
            result.push(TimelineSegment {
                session_id: session.clone(),
                source_id,
                track_id,
                segment_id,
                sequence: sequence as u64,
                start_nanoseconds: playback_start,
                native_start_nanoseconds: start,
                clock_adjustment_nanoseconds: playback_start - start,
                sample_count: samples as u64,
                channels: channels as u16,
                gap_nanoseconds: gap,
            });
        }
        if result.is_empty() {
            return Err(StoreError::InvalidState("no sealed timeline media"));
        }
        Ok(result)
    }
}

/// Preserve every sample exactly once without stretching. A small overlap in
/// host-clock placement starts after the preceding PCM; positive gaps remain.
/// Compare against the adjusted end so accumulated correction cannot exceed
/// 50 ms. The plan exposes both original placement and explicit correction.
fn align_playback_start(
    start: i64,
    prior_end: Option<i64>,
    version: u64,
) -> Result<(i64, i64), StoreError> {
    let Some(end) = prior_end else {
        return Ok((start, 0));
    };
    let gap = start
        .checked_sub(end)
        .ok_or(StoreError::IntegrityMismatch("timeline gap overflow"))?;
    let limit = if version == 1 { 50_000_000 } else { 20_834 };
    if gap < -limit {
        return Err(StoreError::IntegrityMismatch(
            "timeline overlap exceeds clock alignment bound",
        ));
    }
    Ok((if version == 1 { start.max(end) } else { start }, gap))
}
