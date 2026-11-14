//! Database effects of capture journal records, shared by live calls and replay.

use super::*;

impl SessionStore {
    pub(crate) fn project_media_authorization(
        &mut self,
        session_id: &str,
        journal_record: &JournalRecord,
    ) -> Result<(), StoreError> {
        let payload = &journal_record.body.payload;
        let source_id = payload_string(payload, "source_id")?;
        let source_kind = payload_string(payload, "source_kind")?;
        let source_display_name = payload_string(payload, "source_display_name")?;
        let track_id = payload_string(payload, "track_id")?;
        let segment_id = payload_string(payload, "segment_id")?;
        let open_token = payload_string(payload, "open_token")?;
        let writer_generation = payload_u64(payload, "writer_generation")?;
        let relative_path = payload_string(payload, "relative_path")?;
        let media_format = payload_string(payload, "media_format")?;
        let channels = payload_u64(payload, "channels")?;
        if channels != 1 && channels != 2 {
            return Err(StoreError::IntegrityMismatch(
                "unsupported source channel layout",
            ));
        }
        let mapped_start_ns = payload_i64(payload, "mapped_start_nanoseconds")?;
        let transaction = self.connection.transaction()?;
        transaction.execute(
            "INSERT OR IGNORE INTO sources (
                id, schema_version, session_id, kind, display_name, lifecycle
             ) VALUES (?1, ?2, ?3, ?4, ?5, 'opening')",
            params![
                source_id,
                SCHEMA_VERSION,
                session_id,
                source_kind,
                source_display_name
            ],
        )?;
        transaction.execute(
            "UPDATE required_sources SET lifecycle = 'opening'
             WHERE session_id = ?1 AND kind = ?2 AND lifecycle = 'required'",
            params![session_id, source_kind],
        )?;
        transaction.execute(
            "INSERT OR IGNORE INTO tracks (
                id, schema_version, session_id, source_id, kind, lifecycle
             ) VALUES (?1, ?2, ?3, ?4, 'audio', 'opening')",
            params![track_id, SCHEMA_VERSION, session_id, source_id],
        )?;
        transaction.execute(
            "INSERT OR IGNORE INTO segments (
                id, schema_version, session_id, track_id, sequence, relative_path,
                lifecycle, original_start, mapped_start_ns, media_format, channels,
                sample_count, byte_length, digest, seal_state, recovery_state,
                open_token, writer_generation, file_device, file_inode
             ) VALUES (?1, ?2, ?3, ?4, ?10, ?5, 'opening', NULL, ?6, ?7, ?11,
                       NULL, NULL, NULL, 'open', 'not_required', ?8, ?9, NULL, NULL)",
            params![
                segment_id,
                SCHEMA_VERSION,
                session_id,
                track_id,
                relative_path,
                mapped_start_ns,
                media_format,
                open_token,
                writer_generation as i64,
                payload
                    .get("segment_sequence")
                    .and_then(Value::as_i64)
                    .unwrap_or(0),
                channels as i64,
            ],
        )?;
        insert_journaled_event(&transaction, journal_record, "segment_open_intent")?;
        transaction.commit()?;
        Ok(())
    }

    pub(crate) fn project_media_open(
        &mut self,
        session_id: &str,
        journal_record: &JournalRecord,
    ) -> Result<(), StoreError> {
        let payload = &journal_record.body.payload;
        let segment_id = payload_string(payload, "segment_id")?;
        let byte_length = payload_u64(payload, "initial_byte_length")?;
        let file_device = payload_u64(payload, "file_device")?;
        let file_inode = payload_u64(payload, "file_inode")?;
        let now = wall_time_milliseconds();
        let transaction = self.connection.transaction()?;
        let changed = transaction.execute(
            "UPDATE segments
             SET lifecycle = 'open', byte_length = ?2, file_device = ?3, file_inode = ?4
             WHERE id = ?1 AND session_id = ?5 AND lifecycle = 'opening'",
            params![
                segment_id,
                byte_length as i64,
                file_device as i64,
                file_inode as i64,
                session_id
            ],
        )?;
        if changed != 1 {
            return Err(StoreError::InvalidState(
                "segment projection is not awaiting media-open evidence",
            ));
        }
        transaction.execute(
            "UPDATE sources SET lifecycle = 'open' WHERE session_id = ?1 AND lifecycle = 'opening'
             AND id = (SELECT source_id FROM tracks WHERE id = (SELECT track_id FROM segments WHERE id = ?2))",
            params![session_id, segment_id],
        )?;
        transaction.execute(
            "UPDATE tracks SET lifecycle = 'open' WHERE session_id = ?1 AND lifecycle = 'opening'
             AND id = (SELECT track_id FROM segments WHERE id = ?2)",
            params![session_id, segment_id],
        )?;
        transaction.execute(
            "UPDATE required_sources SET lifecycle = 'open'
             WHERE session_id = ?1 AND lifecycle != 'capturing'
               AND kind = (
                 SELECT sources.kind FROM sources
                 JOIN tracks ON tracks.source_id = sources.id
                 JOIN segments ON segments.track_id = tracks.id
                 WHERE segments.id = ?2
               )",
            params![session_id, segment_id],
        )?;
        let all_required_open: bool = transaction.query_row(
            "SELECT NOT EXISTS(
                SELECT 1 FROM required_sources required
                WHERE required.session_id = ?1
                  AND required.lifecycle != 'failed'
                  AND NOT EXISTS(
                    SELECT 1 FROM sources source
                    WHERE source.session_id = required.session_id
                      AND source.kind = required.kind
                      AND source.lifecycle IN ('open', 'capturing')
                  )
             )",
            [session_id],
            |row| row.get(0),
        )?;
        transaction.execute(
            "UPDATE sessions
             SET media_files_open = ?2, updated_at_ms = ?3
             WHERE id = ?1 AND lifecycle = 'preparing' AND journal_durable = 1",
            params![session_id, all_required_open, now],
        )?;
        insert_journaled_event(&transaction, journal_record, "segment_opened")?;
        transaction.commit()?;
        Ok(())
    }

    pub(crate) fn project_first_sample(
        &mut self,
        session_id: &str,
        journal_record: &JournalRecord,
    ) -> Result<(), StoreError> {
        let payload = &journal_record.body.payload;
        let segment_id = payload_string(payload, "segment_id")?;
        let first_sample_host_time = payload_u64(payload, "first_sample_host_time")?;
        let _first_sample_frame_count = payload_u64(payload, "first_sample_frame_count")?;
        let now = wall_time_milliseconds();
        let transaction = self.connection.transaction()?;
        let changed = transaction.execute(
            "UPDATE segments
             SET lifecycle = 'capturing', original_start = ?2,
                 mapped_start_ns = ?4, sample_count = NULL
             WHERE id = ?1 AND session_id = ?3 AND lifecycle = 'open'",
            params![
                segment_id,
                first_sample_host_time as i64,
                session_id,
                payload_i64(payload, "first_sample_session_nanoseconds")?
            ],
        )?;
        if changed != 1 {
            return Err(StoreError::InvalidState(
                "segment projection is not awaiting first-sample evidence",
            ));
        }
        transaction.execute(
            "UPDATE sources SET lifecycle = 'capturing'
             WHERE id = (
               SELECT tracks.source_id FROM tracks
               JOIN segments ON segments.track_id = tracks.id
               WHERE segments.id = ?2
             ) AND session_id = ?1 AND lifecycle = 'open'",
            params![session_id, segment_id],
        )?;
        transaction.execute(
            "UPDATE tracks SET lifecycle = 'capturing'
             WHERE id = (SELECT track_id FROM segments WHERE id = ?2)
               AND session_id = ?1 AND lifecycle = 'open'",
            params![session_id, segment_id],
        )?;
        transaction.execute(
            "UPDATE required_sources SET lifecycle = 'capturing'
             WHERE session_id = ?1
               AND kind = (
                 SELECT sources.kind FROM sources
                 JOIN tracks ON tracks.source_id = sources.id
                 JOIN segments ON segments.track_id = tracks.id
                 WHERE segments.id = ?2
               )",
            params![session_id, segment_id],
        )?;
        transaction.execute(
            "UPDATE sessions SET updated_at_ms = ?2
             WHERE id = ?1 AND lifecycle = 'preparing'
               AND journal_durable = 1 AND media_files_open = 1",
            params![session_id, now],
        )?;
        insert_journaled_event(&transaction, journal_record, "first_sample_captured")?;
        transaction.commit()?;
        Ok(())
    }

    pub(crate) fn project_segment_seal(
        &mut self,
        session_id: &str,
        journal_record: &JournalRecord,
    ) -> Result<(), StoreError> {
        let payload = &journal_record.body.payload;
        let segment_id = payload_string(payload, "segment_id")?;
        let source_id = payload_string(payload, "source_id")?;
        let track_id = payload_string(payload, "track_id")?;
        let sample_count = payload_u64(payload, "sample_count")?;
        let final_byte_length = payload_u64(payload, "final_byte_length")?;
        let digest = payload_string(payload, "digest_sha256")?;
        let now = wall_time_milliseconds();
        let transaction = self.connection.transaction()?;
        let changed = transaction.execute(
            "UPDATE segments
             SET lifecycle = 'sealed', sample_count = ?2, byte_length = ?3,
                 digest = ?4, seal_state = 'sealed'
             WHERE id = ?1 AND session_id = ?5 AND lifecycle = 'capturing'",
            params![
                segment_id,
                sample_count as i64,
                final_byte_length as i64,
                digest,
                session_id,
            ],
        )?;
        if changed != 1 {
            return Err(StoreError::InvalidState(
                "segment projection is not awaiting seal evidence",
            ));
        }
        let continuing: bool = transaction.query_row(
            concat!(
                "SELECT EXISTS(SELECT 1 FROM segments WHERE track_id = ?1 AND lifecycle IN ",
                active_media_sql!(),
                ")"
            ),
            [track_id],
            |row| row.get(0),
        )?;
        if !continuing {
            let source_changed = transaction.execute(
                "UPDATE sources SET lifecycle = 'sealed'
             WHERE id = ?1 AND session_id = ?2 AND lifecycle = 'capturing'",
                params![source_id, session_id],
            )?;
            let track_changed = transaction.execute(
                "UPDATE tracks SET lifecycle = 'sealed'
             WHERE id = ?1 AND session_id = ?2 AND lifecycle = 'capturing'",
                params![track_id, session_id],
            )?;
            if source_changed != 1 || track_changed != 1 {
                return Err(StoreError::InvalidState(
                    "source or track projection is not awaiting seal evidence",
                ));
            }
            transaction.execute(
                "UPDATE required_sources SET lifecycle = 'sealed'
             WHERE session_id = ?1
               AND kind = (SELECT kind FROM sources WHERE id = ?2 AND session_id = ?1)",
                params![session_id, source_id],
            )?;
        }
        if payload
            .get("measured_drift_nanoseconds")
            .and_then(Value::as_i64)
            .is_some_and(|drift| {
                drift.unsigned_abs() > timeline::MAX_SOURCE_DRIFT_NANOSECONDS as u64
            })
        {
            transaction.execute(
                "UPDATE sessions SET health = 'degraded' WHERE id = ?1",
                [session_id],
            )?;
        }
        transaction.execute(
            concat!(
                "UPDATE sessions
             SET media_files_open = EXISTS(
                    SELECT 1 FROM segments
                    WHERE session_id = ?1 AND lifecycle IN ",
                active_media_sql!(),
                "),
                 lifecycle = CASE
                    WHEN lifecycle = 'recording' AND NOT EXISTS(
                        SELECT 1 FROM segments
                        WHERE session_id = ?1 AND lifecycle IN ",
                active_media_sql!(),
                ") THEN 'ready_for_review'
                    ELSE lifecycle
                 END,
                 updated_at_ms = ?2
             WHERE id = ?1 AND lifecycle IN ",
                interruptible_lifecycles_sql!()
            ),
            params![session_id, now],
        )?;
        insert_journaled_event(&transaction, journal_record, "segment_sealed")?;
        transaction.commit()?;
        Ok(())
    }

    pub(crate) fn project_session_interruption(
        &mut self,
        session_id: &str,
        journal_record: &JournalRecord,
    ) -> Result<(), StoreError> {
        let payload = &journal_record.body.payload;
        let reason = payload_string(payload, "reason")?;
        SessionInterruptionReason::parse(reason)?;
        let transaction = self.connection.transaction()?;
        let changed = transaction.execute(
            concat!(
                "UPDATE sessions SET lifecycle = 'interrupted', updated_at_ms = ?2
             WHERE id = ?1 AND lifecycle IN ",
                interruptible_lifecycles_sql!()
            ),
            params![session_id, journal_record.body.wall_time_milliseconds],
        )?;
        if changed != 1 {
            return Err(StoreError::InvalidState(
                "session projection is not awaiting interruption evidence",
            ));
        }
        insert_journaled_event(&transaction, journal_record, "session_interrupted")?;
        transaction.commit()?;
        Ok(())
    }

    pub(crate) fn media_authorization_row(
        &self,
        segment_id: &str,
    ) -> Result<StoredMediaAuthorization, StoreError> {
        self.connection
            .query_row(
                "SELECT segments.session_id, tracks.source_id, segments.track_id,
                        segments.relative_path, segments.media_format, segments.channels, segments.lifecycle,
                        segments.open_token, segments.writer_generation, segments.byte_length,
                        segments.file_device, segments.file_inode
                 FROM segments
                 JOIN tracks ON tracks.id = segments.track_id
                 WHERE segments.id = ?1",
                [segment_id],
                |row| {
                    Ok(StoredMediaAuthorization {
                        session_id: row.get(0)?,
                        source_id: row.get(1)?,
                        track_id: row.get(2)?,
                        relative_path: row.get(3)?,
                        media_format: row.get(4)?,
                        channels: row.get::<_, i64>(5)? as u16,
                        lifecycle: row.get(6)?,
                        open_token: row.get(7)?,
                        writer_generation: row.get::<_, i64>(8)? as u64,
                        byte_length: row.get::<_, Option<i64>>(9)?.map(|value| value as u64),
                        file_device: row.get::<_, Option<i64>>(10)?.map(|value| value as u64),
                        file_inode: row.get::<_, Option<i64>>(11)?.map(|value| value as u64),
                    })
                },
            )
            .map_err(missing_row("media authorization does not exist"))
    }

    pub(crate) fn segment_event_payload(
        &self,
        session_id: &str,
        event_kind: &str,
        segment_id: &str,
        missing_message: &'static str,
    ) -> Result<Value, StoreError> {
        let mut statement = self.connection.prepare(
            "SELECT payload_json FROM session_events
             WHERE session_id = ?1 AND event_kind = ?2
             ORDER BY sequence DESC",
        )?;
        let payloads = statement.query_map(params![session_id, event_kind], |row| {
            row.get::<_, String>(0)
        })?;
        for payload in payloads {
            let payload: Value = serde_json::from_str(&payload?)?;
            if payload_string(&payload, "segment_id")? == segment_id {
                return Ok(payload);
            }
        }
        Err(StoreError::InvalidState(missing_message))
    }
}
