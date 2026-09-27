//! Recovery at the reservation/open/first-sample boundaries. Unadmitted bytes
//! are preserved, never promoted to verified audio or silently deleted.
use super::*;

impl SessionStore {
    pub(super) fn recover_unstarted_successors(&mut self) -> Result<(), StoreError> {
        let candidates = {
            let mut query = self.connection.prepare(
                "SELECT segments.session_id, segments.id, segments.track_id, segments.relative_path
                 FROM segments JOIN sessions ON sessions.id = segments.session_id
                 WHERE sessions.lifecycle IN ('recording', 'interrupted', 'preparing', 'finalizing', 'paused')
                   AND segments.sequence > 0 AND segments.lifecycle IN ('opening', 'open')
                   AND segments.original_start IS NULL",
            )?;
            query
                .query_map([], |r| {
                    Ok((
                        r.get::<_, String>(0)?,
                        r.get::<_, String>(1)?,
                        r.get::<_, String>(2)?,
                        r.get::<_, String>(3)?,
                    ))
                })?
                .collect::<Result<Vec<_>, _>>()?
        };
        for (session, segment, track, path) in candidates {
            let records = match validate_journal(
                &self.session_directory(&session)?.join(JOURNAL_NAME),
                &session,
            )? {
                JournalValidation::Valid(records) => records,
                _ => {
                    return Err(StoreError::IntegrityMismatch(
                        "gap recovery journal is invalid",
                    ));
                }
            };
            if journal_record_for_segment(&records, "first_sample_captured", &segment)?.is_some() {
                return Err(StoreError::IntegrityMismatch(
                    "accepted first sample was not projected",
                ));
            }
            let record = if let Some(record) =
                journal_record_for_segment(&records, "segment_capture_gap", &segment)?
            {
                record.clone()
            } else {
                self.append_session_journal(
                    &session,
                    "segment_capture_gap",
                    Some(&path),
                    json!({
                        "segment_id": segment, "track_id": track, "relative_path": path,
                        "reason": "terminated_before_first_sample", "media_preserved": true,
                    }),
                )?
            };
            let (sequence, prior) = next_database_event(&self.connection, &session)?;
            let digest = event_digest(
                &session,
                sequence,
                "segment_capture_gap",
                &record.body.payload,
                prior.as_deref(),
            )?;
            let tx = self.connection.transaction()?;
            tx.execute(
                "UPDATE segments SET lifecycle = 'gap', recovery_state = 'gap' WHERE id = ?1",
                [&segment],
            )?;
            tx.execute("UPDATE tracks SET lifecycle = 'sealed' WHERE id = ?1 AND NOT EXISTS(
                SELECT 1 FROM segments WHERE track_id = ?1 AND lifecycle IN ('opening', 'open', 'capturing'))", [&track])?;
            tx.execute("UPDATE sources SET lifecycle = 'sealed' WHERE id = (SELECT source_id FROM tracks WHERE id = ?1 AND lifecycle = 'sealed')", [&track])?;
            tx.execute("UPDATE required_sources SET lifecycle = 'sealed' WHERE session_id = ?1 AND kind IN(
                SELECT kind FROM sources WHERE session_id = ?1 AND lifecycle = 'sealed')", [&session])?;
            tx.execute(
                "UPDATE sessions SET health = 'degraded' WHERE id = ?1",
                [&session],
            )?;
            insert_event_with_id(
                &tx,
                &record.body.event_id,
                &session,
                sequence,
                "segment_capture_gap",
                record.body.wall_time_milliseconds,
                &record.body.payload,
                prior.as_deref(),
                &digest,
            )?;
            tx.commit()?;
        }
        self.finalize_sealed_timeline_recovery()
    }

    fn finalize_sealed_timeline_recovery(&mut self) -> Result<(), StoreError> {
        let sessions = {
            let mut query = self.connection.prepare(
                "SELECT id FROM sessions WHERE lifecycle IN ('recording', 'interrupted', 'paused', 'finalizing', 'preparing')
                 AND EXISTS(SELECT 1 FROM segments WHERE session_id = sessions.id AND lifecycle IN ('gap', 'sealed'))
                 AND NOT EXISTS(SELECT 1 FROM segments WHERE session_id = sessions.id AND lifecycle IN ('opening', 'open', 'capturing'))"
            )?;
            query
                .query_map([], |r| r.get::<_, String>(0))?
                .collect::<Result<Vec<_>, _>>()?
        };
        for session in sessions {
            let records = match validate_journal(
                &self.session_directory(&session)?.join(JOURNAL_NAME),
                &session,
            )? {
                JournalValidation::Valid(records) => records,
                _ => {
                    return Err(StoreError::IntegrityMismatch(
                        "timeline recovery journal is invalid",
                    ));
                }
            };
            let (sources, _handles) =
                self.validate_sealed_recovery_companions(&session, &records, true)?;
            if self
                .required_source_kinds(&session)?
                .iter()
                .any(|kind| !sources.contains(kind.as_str()))
            {
                continue;
            }
            let record = if let Some(record) = records
                .iter()
                .find(|r| r.body.event_kind == "timeline_recovered")
            {
                record.clone()
            } else {
                self.append_session_journal(
                    &session,
                    "timeline_recovered",
                    None,
                    json!({"media_preserved": true, "has_gaps": true}),
                )?
            };
            let (sequence, prior) = next_database_event(&self.connection, &session)?;
            let digest = event_digest(
                &session,
                sequence,
                "timeline_recovered",
                &record.body.payload,
                prior.as_deref(),
            )?;
            let tx = self.connection.transaction()?;
            tx.execute("UPDATE sessions SET lifecycle = 'ready_for_review', health = 'degraded', media_files_open = 0, updated_at_ms = ?2 WHERE id = ?1",
                params![session, record.body.wall_time_milliseconds])?;
            insert_event_with_id(
                &tx,
                &record.body.event_id,
                &session,
                sequence,
                "timeline_recovered",
                record.body.wall_time_milliseconds,
                &record.body.payload,
                prior.as_deref(),
                &digest,
            )?;
            tx.execute("INSERT INTO recovery_runs(id, schema_version, session_id, disposition, created_at_ms) VALUES(?1, ?2, ?3, 'timeline_recovered', ?4)",
                params![Uuid::now_v7().to_string(), SCHEMA_VERSION, session, record.body.wall_time_milliseconds])?;
            tx.commit()?;
        }
        Ok(())
    }
}
