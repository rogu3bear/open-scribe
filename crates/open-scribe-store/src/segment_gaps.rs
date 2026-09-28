//! Recovery at the reservation/open/first-sample boundaries. Unadmitted bytes
//! are preserved, never promoted to verified audio or silently deleted.
use super::library_recovery::isolated_disposition;
use super::*;

type UnstartedSegment = (String, String, String);

impl SessionStore {
    /// Turns journaled-but-unstarted successors into explicit gaps, then
    /// finalizes sessions whose sources have all sealed. Each session is handled
    /// on its own; `blocked` sessions keep their earlier finding untouched.
    pub(super) fn recover_unstarted_successors(
        &mut self,
        blocked: &BTreeSet<String>,
    ) -> Result<Vec<RecoveryFinding>, StoreError> {
        let candidates = {
            let mut query = self.connection.prepare(
                "SELECT segments.session_id, segments.id, segments.track_id, segments.relative_path
                 FROM segments JOIN sessions ON sessions.id = segments.session_id
                 WHERE sessions.lifecycle IN ('recording', 'interrupted', 'preparing', 'finalizing', 'paused')
                   AND segments.lifecycle IN ('opening', 'open')
                   AND segments.original_start IS NULL
                   AND (segments.sequence > 0 OR EXISTS(
                        SELECT 1 FROM session_events resumed
                        WHERE resumed.session_id = segments.session_id
                          AND resumed.event_kind = 'resume_requested'))",
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
        let mut by_session = BTreeMap::<String, Vec<UnstartedSegment>>::new();
        for (session, segment, track, path) in candidates {
            if blocked.contains(&session) {
                continue;
            }
            by_session
                .entry(session)
                .or_default()
                .push((segment, track, path));
        }
        let mut findings = Vec::new();
        let mut blocked = blocked.clone();
        for (session, segments) in by_session {
            if let Err(error) = self.project_session_gaps(&session, &segments) {
                findings.push(finding(&session, isolated_disposition(error)?));
                blocked.insert(session);
            }
        }
        findings.extend(self.finalize_sealed_timeline_recovery(&blocked)?);
        Ok(findings)
    }

    fn project_session_gaps(
        &mut self,
        session: &str,
        segments: &[UnstartedSegment],
    ) -> Result<(), StoreError> {
        let records = match validate_journal(
            &self.session_directory(session)?.join(JOURNAL_NAME),
            session,
        )? {
            JournalValidation::Valid(records) => records,
            _ => {
                return Err(StoreError::IntegrityMismatch(
                    "gap recovery journal is invalid",
                ));
            }
        };
        for (segment, track, path) in segments {
            if journal_record_for_segment(&records, "first_sample_captured", segment)?.is_some() {
                return Err(StoreError::IntegrityMismatch(
                    "accepted first sample was not projected",
                ));
            }
            let record = if let Some(record) =
                journal_record_for_segment(&records, "segment_capture_gap", segment)?
            {
                record.clone()
            } else {
                self.append_session_journal(
                    session,
                    "segment_capture_gap",
                    Some(path),
                    json!({
                        "segment_id": segment, "track_id": track, "relative_path": path,
                        "reason": "terminated_before_first_sample", "media_preserved": true,
                    }),
                )?
            };
            let (sequence, prior) = next_database_event(&self.connection, session)?;
            let digest = event_digest(
                session,
                sequence,
                "segment_capture_gap",
                &record.body.payload,
                prior.as_deref(),
            )?;
            let tx = self.connection.transaction()?;
            tx.execute(
                "UPDATE segments SET lifecycle = 'gap', recovery_state = 'gap' WHERE id = ?1",
                [segment],
            )?;
            tx.execute("UPDATE tracks SET lifecycle = 'sealed' WHERE id = ?1 AND NOT EXISTS(
                SELECT 1 FROM segments WHERE track_id = ?1 AND lifecycle IN ('opening', 'open', 'capturing'))", [track])?;
            tx.execute("UPDATE sources SET lifecycle = 'sealed' WHERE id = (SELECT source_id FROM tracks WHERE id = ?1 AND lifecycle = 'sealed')", [track])?;
            tx.execute("UPDATE required_sources SET lifecycle = 'sealed' WHERE session_id = ?1 AND kind IN(
                SELECT kind FROM sources WHERE session_id = ?1 AND lifecycle = 'sealed')", [session])?;
            tx.execute(
                "UPDATE sessions SET health = 'degraded' WHERE id = ?1",
                [session],
            )?;
            insert_event_with_id(
                &tx,
                &record.body.event_id,
                session,
                sequence,
                "segment_capture_gap",
                record.body.wall_time_milliseconds,
                &record.body.payload,
                prior.as_deref(),
                &digest,
            )?;
            tx.commit()?;
        }
        Ok(())
    }

    fn finalize_sealed_timeline_recovery(
        &mut self,
        blocked: &BTreeSet<String>,
    ) -> Result<Vec<RecoveryFinding>, StoreError> {
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
        let mut findings = Vec::new();
        for session in sessions {
            if blocked.contains(&session) {
                continue;
            }
            let disposition = match self.finalize_session_timeline(&session) {
                Ok(true) => RecoveryDisposition::PlayableMediaRecovered,
                Ok(false) => continue,
                Err(error) => isolated_disposition(error)?,
            };
            findings.push(finding(&session, disposition));
        }
        Ok(findings)
    }

    /// Finalizes one fully sealed session. `has_gaps` and health come from the
    /// gap segments that recovery actually projected: a session that quit while
    /// paused with every source sealed is whole and stays healthy.
    fn finalize_session_timeline(&mut self, session: &str) -> Result<bool, StoreError> {
        let records = match validate_journal(
            &self.session_directory(session)?.join(JOURNAL_NAME),
            session,
        )? {
            JournalValidation::Valid(records) => records,
            _ => {
                return Err(StoreError::IntegrityMismatch(
                    "timeline recovery journal is invalid",
                ));
            }
        };
        let (sources, _handles) =
            self.validate_sealed_recovery_companions(session, &records, true)?;
        if self
            .evidenced_source_kinds(session)?
            .iter()
            .any(|kind| !sources.contains(kind))
        {
            return Ok(false);
        }
        let has_gaps: bool = self.connection.query_row(
            "SELECT EXISTS(SELECT 1 FROM segments WHERE session_id = ?1 AND lifecycle = 'gap')",
            [session],
            |r| r.get(0),
        )?;
        let record = if let Some(record) = records
            .iter()
            .find(|r| r.body.event_kind == "timeline_recovered")
        {
            record.clone()
        } else {
            self.append_session_journal(
                session,
                "timeline_recovered",
                None,
                json!({"media_preserved": true, "has_gaps": has_gaps}),
            )?
        };
        // Older records predate the field and were only written for gapped sessions.
        let journaled_gaps = record
            .body
            .payload
            .get("has_gaps")
            .and_then(Value::as_bool)
            .unwrap_or(true);
        let (sequence, prior) = next_database_event(&self.connection, session)?;
        let digest = event_digest(
            session,
            sequence,
            "timeline_recovered",
            &record.body.payload,
            prior.as_deref(),
        )?;
        let tx = self.connection.transaction()?;
        tx.execute(
            "UPDATE sessions
             SET lifecycle = 'ready_for_review',
                 health = CASE
                     WHEN ?3 OR lifecycle = 'interrupted' OR health = 'degraded' THEN 'degraded'
                     ELSE health
                 END,
                 media_files_open = 0,
                 updated_at_ms = ?2
             WHERE id = ?1",
            params![session, record.body.wall_time_milliseconds, journaled_gaps],
        )?;
        insert_event_with_id(
            &tx,
            &record.body.event_id,
            session,
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
        Ok(true)
    }
}
