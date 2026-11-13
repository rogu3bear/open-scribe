//! Launch recovery of preparations, interruptions and playable capture media.

use super::*;

/// Coarse, content-free result for one source segment made playable after restart.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct RecoveredPlayableSession {
    pub session_id: SessionId,
    pub source_id: String,
    pub track_id: String,
    pub source_kind: MediaSourceKind,
    pub source_display_name: String,
    pub segment_id: String,
    pub relative_path: String,
    pub sample_count: u64,
    pub duration_nanoseconds: u64,
    pub byte_length: u64,
    pub digest_sha256: String,
    pub media_preserved: bool,
    pub ready_for_review: bool,
    pub recording_started: bool,
    pub last_journal_sequence: u64,
}

/// Recovery result for one nonterminal database row or managed directory.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum RecoveryDisposition {
    Prepared,
    ProjectionRepaired,
    MediaOpenPrepared,
    MediaOpenProjectionRepaired,
    MediaOpenAwaitingReceipt,
    FirstSamplePrepared,
    FirstSampleProjectionRepaired,
    SegmentSealedPrepared,
    SegmentSealProjectionRepaired,
    ImportedMediaReady,
    ImportProjectionRepaired,
    ImportFailed,
    SourceFailedRecording,
    SourceFailureProjectionRepaired,
    InterruptedPrepared,
    InterruptedMediaOpen,
    InterruptedFirstSample,
    InterruptedSegmentSealed,
    InterruptionProjectionRepaired,
    PlayableMediaRecovered,
    /// Incomplete running transcription failed closed on launch (no live worker).
    TranscriptRunOrphaned,
    MissingMediaFile,
    InvalidMediaFile,
    MissingDirectory,
    MissingJournal,
    TruncatedJournal,
    MalformedJournal,
    IntegrityMismatch,
    UnsupportedJournalVersion,
    OrphanDirectory,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct RecoveryFinding {
    pub session_id: SessionId,
    pub disposition: RecoveryDisposition,
}

pub(crate) struct PlayableRecoveryCandidate {
    pub(crate) session_id: String,
    pub(crate) source_id: String,
    pub(crate) track_id: String,
    pub(crate) segment_id: String,
    pub(crate) relative_path: String,
    pub(crate) file_device: u64,
    pub(crate) file_inode: u64,
}

pub(crate) fn classify_media_path(path: &Path) -> RecoveryDisposition {
    match fs::symlink_metadata(path) {
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
            RecoveryDisposition::MissingMediaFile
        }
        _ => RecoveryDisposition::InvalidMediaFile,
    }
}

pub(crate) fn finding(session_id: &str, disposition: RecoveryDisposition) -> RecoveryFinding {
    RecoveryFinding {
        session_id: SessionId(session_id.to_owned()),
        disposition,
    }
}

impl SessionStore {
    /// Validates every sealed segment against its accepted evidence and returns
    /// the source kinds they cover. Each file closes once checked: a long session
    /// holds more segments than a process may keep open, and every later lease
    /// re-validates the same evidence.
    pub(crate) fn validate_sealed_recovery_companions(
        &self,
        session_id: &str,
        records: &[JournalRecord],
    ) -> Result<BTreeSet<String>, StoreError> {
        let rows = {
            let mut statement = self.connection.prepare(
                "SELECT sources.kind, sources.id, tracks.id, segments.id,
                        segments.relative_path, segments.sample_count,
                        segments.byte_length, segments.digest,
                        segments.file_device, segments.file_inode,
                        segments.seal_state, segments.open_token,
                        segments.writer_generation, segments.channels
                 FROM sources
                 JOIN tracks ON tracks.session_id = sources.session_id
                            AND tracks.source_id = sources.id
                 JOIN segments ON segments.session_id = sources.session_id
                              AND segments.track_id = tracks.id
                 WHERE sources.session_id = ?1
                   AND segments.lifecycle = 'sealed'
                 ORDER BY sources.kind, segments.sequence, segments.id",
            )?;
            let mapped = statement.query_map([session_id], |row| {
                Ok((
                    row.get::<_, String>(0)?,
                    row.get::<_, String>(1)?,
                    row.get::<_, String>(2)?,
                    row.get::<_, String>(3)?,
                    row.get::<_, String>(4)?,
                    row.get::<_, i64>(5)? as u64,
                    row.get::<_, i64>(6)? as u64,
                    row.get::<_, String>(7)?,
                    row.get::<_, i64>(8)? as u64,
                    row.get::<_, i64>(9)? as u64,
                    row.get::<_, String>(10)?,
                    row.get::<_, Option<String>>(11)?,
                    row.get::<_, i64>(12)? as u64,
                    row.get::<_, i64>(13)? as u16,
                ))
            })?;
            mapped.collect::<Result<Vec<_>, _>>()?
        };

        let mut source_kinds = BTreeSet::new();
        for (
            source_kind,
            source_id,
            track_id,
            segment_id,
            relative_path,
            sample_count,
            byte_length,
            digest_sha256,
            file_device,
            file_inode,
            seal_state,
            open_token,
            writer_generation,
            channels,
        ) in rows
        {
            parse_source_kind(&source_kind)?;
            if seal_state != "sealed" {
                return Err(StoreError::IntegrityMismatch(
                    "sealed recovery companion lacks accepted seal state",
                ));
            }
            let accepted = journal_record_for_segment(records, "segment_sealed", &segment_id)?
                .or(journal_record_for_segment(
                    records,
                    "playable_media_recovered",
                    &segment_id,
                )?)
                .ok_or(StoreError::IntegrityMismatch(
                    "sealed recovery companion lacks accepted journal evidence",
                ))?;
            let payload = &accepted.body.payload;
            if accepted.body.relative_path.as_deref() != Some(relative_path.as_str())
                || payload_string(payload, "source_id")? != source_id.as_str()
                || payload_string(payload, "track_id")? != track_id.as_str()
                || payload_string(payload, "segment_id")? != segment_id.as_str()
                || payload_string(payload, "relative_path")? != relative_path.as_str()
                || payload_u64(payload, "sample_count")? != sample_count
                || payload_u64(payload, "final_byte_length")? != byte_length
                || payload_string(payload, "digest_sha256")? != digest_sha256.as_str()
                || payload_u64(payload, "file_device")? != file_device
                || payload_u64(payload, "file_inode")? != file_inode
            {
                return Err(StoreError::IntegrityMismatch(
                    "sealed recovery companion changed accepted evidence",
                ));
            }
            match accepted.body.event_kind.as_str() {
                "segment_sealed" => {
                    if payload_string(payload, "open_token")? != open_token.as_deref().unwrap_or("")
                        || payload_u64(payload, "writer_generation")? != writer_generation
                        || payload_u64(payload, "final_sample_host_time")? == 0
                    {
                        return Err(StoreError::IntegrityMismatch(
                            "sealed recovery companion changed writer evidence",
                        ));
                    }
                }
                "playable_media_recovered" => {
                    if payload_u64(payload, "truncated_bytes")? != 0 {
                        return Err(StoreError::IntegrityMismatch(
                            "sealed recovery companion changed recovery evidence",
                        ));
                    }
                }
                _ => {
                    return Err(StoreError::IntegrityMismatch(
                        "sealed recovery companion has unsupported journal evidence",
                    ));
                }
            }
            let validated = self.validate_media_file(
                session_id,
                &relative_path,
                MediaLengthRequirement::Exact(byte_length),
                true,
            )?;
            if !validated.matches_sealed(&SealedEvidence {
                device: file_device,
                inode: file_inode,
                byte_length,
                digest: &digest_sha256,
                sample_count,
                channels: Some(channels),
            }) {
                return Err(StoreError::IntegrityMismatch(
                    "sealed recovery companion changed after acceptance",
                ));
            }
            source_kinds.insert(source_kind);
        }
        Ok(source_kinds)
    }

    /// Every reviewable recovered segment with its own validation result, so
    /// launch recovery can set one damaged session aside from the rest.
    pub(crate) fn recovered_playable_rows(
        &self,
    ) -> Result<Vec<library_recovery::RecoveredPlayableRow>, StoreError> {
        let rows = {
            let mut statement = self.connection.prepare(&format!(
                "SELECT sessions.id, sources.id, tracks.id, sources.kind,
                        sources.display_name, segments.id, segments.relative_path,
                        segments.sample_count, segments.byte_length, segments.digest,
                        segments.file_device, segments.file_inode,
                        MAX(session_events.sequence), segments.channels
                 FROM sessions
                 JOIN segments ON segments.session_id = sessions.id
                 JOIN tracks ON tracks.id = segments.track_id
                            AND tracks.session_id = segments.session_id
                 JOIN sources ON sources.id = tracks.source_id
                             AND sources.session_id = tracks.session_id
                 JOIN session_events ON session_events.session_id = sessions.id
                 WHERE sessions.lifecycle = 'ready_for_review'
                   AND segments.lifecycle = 'sealed'
                   AND {}
                 GROUP BY sessions.id, segments.id
                 ORDER BY sessions.updated_at_ms DESC, sources.kind,
                          segments.sequence, segments.id",
                library_recovery::RECOVERED_SESSION_EVIDENCE_SQL
            ))?;
            let mapped = statement.query_map([], |row| {
                Ok((
                    row.get::<_, String>(0)?,
                    row.get::<_, String>(1)?,
                    row.get::<_, String>(2)?,
                    row.get::<_, String>(3)?,
                    row.get::<_, String>(4)?,
                    row.get::<_, String>(5)?,
                    row.get::<_, String>(6)?,
                    row.get::<_, i64>(7)? as u64,
                    row.get::<_, i64>(8)? as u64,
                    row.get::<_, String>(9)?,
                    row.get::<_, i64>(10)? as u64,
                    row.get::<_, i64>(11)? as u64,
                    row.get::<_, i64>(12)? as u64,
                    row.get::<_, i64>(13)? as u16,
                ))
            })?;
            mapped.collect::<Result<Vec<_>, _>>()?
        };

        Ok(rows
            .into_iter()
            .map(
                |(
                    session_id,
                    source_id,
                    track_id,
                    source_kind,
                    source_display_name,
                    segment_id,
                    relative_path,
                    sample_count,
                    byte_length,
                    digest_sha256,
                    file_device,
                    file_inode,
                    last_journal_sequence,
                    channels,
                )| {
                    let session = session_id.clone();
                    let row = (move || -> Result<RecoveredPlayableSession, StoreError> {
                        let validated = self.observe_sealed_media_file(
                            &session_id,
                            &relative_path,
                            MediaLengthRequirement::Exact(byte_length),
                            true,
                        )?;
                        if !validated.matches_sealed(&SealedEvidence {
                            device: file_device,
                            inode: file_inode,
                            byte_length,
                            digest: &digest_sha256,
                            sample_count,
                            channels: Some(channels),
                        }) {
                            return Err(StoreError::IntegrityMismatch(
                                "recovered playable media changed after acceptance",
                            ));
                        }
                        if let Some(digest) = validated.digest_sha256.clone() {
                            self.remember_snapshot_digest(validated.identity, digest);
                        }
                        Ok(RecoveredPlayableSession {
                            session_id: SessionId(session_id.clone()),
                            source_id,
                            track_id,
                            source_kind: parse_source_kind(&source_kind)?,
                            source_display_name,
                            segment_id,
                            relative_path: relative_path.clone(),
                            sample_count,
                            duration_nanoseconds: saturating_frames_to_nanoseconds(sample_count),
                            byte_length,
                            digest_sha256,
                            media_preserved: true,
                            ready_for_review: true,
                            recording_started: false,
                            last_journal_sequence,
                        })
                    })();
                    (session, row)
                },
            )
            .collect())
    }

    pub(crate) fn project_playable_recovery_session(
        &mut self,
        session_id: &str,
        projections: &[JournalRecord],
        playable_source_kinds: &BTreeSet<String>,
    ) -> Result<(), StoreError> {
        if projections.is_empty() {
            return Err(StoreError::InvalidRequest("recovery projection is empty"));
        }
        let transaction = self.connection.transaction()?;
        let mut updated_at_ms = 0;
        for journal_record in projections {
            let payload = &journal_record.body.payload;
            let source_id = payload_string(payload, "source_id")?;
            let track_id = payload_string(payload, "track_id")?;
            let segment_id = payload_string(payload, "segment_id")?;
            let sample_count = payload_u64(payload, "sample_count")?;
            let final_byte_length = payload_u64(payload, "final_byte_length")?;
            let digest_sha256 = payload_string(payload, "digest_sha256")?;
            let changed = transaction.execute(
                "UPDATE segments
                 SET lifecycle = 'sealed', sample_count = ?2, byte_length = ?3,
                     digest = ?4, seal_state = 'sealed', recovery_state = 'recovered'
                 WHERE id = ?1 AND session_id = ?5 AND lifecycle = 'capturing'",
                params![
                    segment_id,
                    sample_count as i64,
                    final_byte_length as i64,
                    digest_sha256,
                    session_id,
                ],
            )?;
            if changed != 1 {
                return Err(StoreError::InvalidState(
                    "segment projection is not awaiting playable recovery",
                ));
            }
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
                    "source or track projection is not awaiting playable recovery",
                ));
            }
            transaction.execute(
                "UPDATE required_sources SET lifecycle = 'sealed'
                 WHERE session_id = ?1
                   AND kind = (SELECT kind FROM sources WHERE id = ?2 AND session_id = ?1)",
                params![session_id, source_id],
            )?;
            insert_journaled_event(&transaction, journal_record, "playable_media_recovered")?;
            updated_at_ms = updated_at_ms.max(journal_record.body.wall_time_milliseconds);
        }
        transaction.execute(
            "UPDATE required_sources AS required
             SET lifecycle = 'sealed'
             WHERE required.session_id = ?1
               AND EXISTS (
                   SELECT 1 FROM sources
                   JOIN tracks ON tracks.source_id = sources.id
                   JOIN segments ON segments.track_id = tracks.id
                   WHERE sources.session_id = required.session_id
                     AND sources.kind = required.kind
                     AND sources.lifecycle = 'sealed'
                     AND tracks.lifecycle = 'sealed'
                     AND segments.lifecycle = 'sealed'
               )",
            [session_id],
        )?;
        let incomplete_segments: i64 = transaction.query_row(
            concat!(
                "SELECT COUNT(*) FROM segments
             WHERE session_id = ?1 AND lifecycle IN ",
                active_media_sql!()
            ),
            [session_id],
            |row| row.get(0),
        )?;
        let incomplete_sources = {
            let mut statement = transaction
                .prepare("SELECT kind, lifecycle FROM required_sources WHERE session_id = ?1")?;
            let rows = statement.query_map([session_id], |row| {
                Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?))
            })?;
            rows.collect::<Result<Vec<_>, _>>()?
                .into_iter()
                .filter(|(kind, lifecycle)| {
                    lifecycle != "sealed" && !playable_source_kinds.contains(kind)
                })
                .count()
        };
        if incomplete_segments != 0 || incomplete_sources != 0 {
            return Err(StoreError::InvalidState(
                "session recovery is missing a required playable source",
            ));
        }
        let session_changed = transaction.execute(
            "UPDATE sessions
             SET lifecycle = 'ready_for_review',
                 health = CASE
                     WHEN lifecycle = 'interrupted' OR health = 'degraded' THEN 'degraded'
                     ELSE health
                 END,
                 media_files_open = 0,
                 updated_at_ms = ?2
             WHERE id = ?1 AND lifecycle IN (
                       'preparing', 'recording', 'finalizing', 'interrupted', 'ready_for_review'
                   )",
            params![session_id, updated_at_ms],
        )?;
        if session_changed != 1 {
            return Err(StoreError::InvalidState(
                "session projection is not awaiting playable recovery",
            ));
        }
        transaction.execute(
            "INSERT INTO recovery_runs (
                id, schema_version, session_id, disposition, created_at_ms
             ) VALUES (?1, ?2, ?3, 'playable_media_recovered', ?4)",
            params![
                Uuid::now_v7().to_string(),
                SCHEMA_VERSION,
                session_id,
                updated_at_ms,
            ],
        )?;
        transaction.commit()?;
        Ok(())
    }

    /// Replays every session journal the database has not fully projected:
    /// preparation, media, imports, source failures and interruptions.
    pub fn recover_preparations(&mut self) -> Result<Vec<RecoveryFinding>, StoreError> {
        let _writer = self.write_guard()?;
        let mut database_sessions = BTreeMap::new();
        {
            let mut statement = self.connection.prepare(concat!(
                "SELECT id, journal_durable FROM sessions WHERE lifecycle IN ",
                unsaved_lifecycles_sql!(),
                " ORDER BY id"
            ))?;
            let rows = statement.query_map([], |row| {
                Ok((row.get::<_, String>(0)?, row.get::<_, bool>(1)?))
            })?;
            for row in rows {
                let (id, journal_durable) = row?;
                database_sessions.insert(id, journal_durable);
            }
        }

        let mut directory_sessions = BTreeSet::new();
        for entry in fs::read_dir(&self.sessions_root)? {
            let entry = entry?;
            if entry.file_type()?.is_dir() {
                directory_sessions.insert(entry.file_name().to_string_lossy().into_owned());
            }
        }
        {
            // Reviewed and deleted sessions keep their directories; a directory
            // is an orphan only when no session row names it.
            let mut statement = self.connection.prepare("SELECT id FROM sessions")?;
            for id in statement.query_map([], |row| row.get::<_, String>(0))? {
                directory_sessions.remove(&id?);
            }
        }

        let mut findings = Vec::new();
        for (session_id, journal_durable) in database_sessions {
            directory_sessions.remove(&session_id);
            let session_directory = self.sessions_root.join(&session_id);
            match fs::symlink_metadata(&session_directory) {
                Ok(metadata) if metadata.is_dir() && !metadata.file_type().is_symlink() => {}
                Ok(_) => {
                    findings.push(finding(&session_id, RecoveryDisposition::IntegrityMismatch));
                    continue;
                }
                Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
                    findings.push(finding(&session_id, RecoveryDisposition::MissingDirectory));
                    continue;
                }
                Err(error) => return Err(error.into()),
            }

            let journal_path = session_directory.join(JOURNAL_NAME);
            match fs::symlink_metadata(&journal_path) {
                Ok(_) => {}
                Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
                    findings.push(finding(&session_id, RecoveryDisposition::MissingJournal));
                    continue;
                }
                Err(error) => return Err(error.into()),
            }

            match validate_journal(&journal_path, &session_id)? {
                JournalValidation::Valid(records) if journal_has_directory_ready(&records) => {
                    let disposition = match self.recover_journaled_session(
                        &session_id,
                        journal_durable,
                        &records,
                    ) {
                        Ok(disposition) => disposition,
                        Err(error) => library_recovery::isolated_disposition(error)?,
                    };
                    findings.push(finding(&session_id, disposition));
                }
                JournalValidation::Valid(_) => {
                    findings.push(finding(&session_id, RecoveryDisposition::MissingJournal))
                }
                JournalValidation::Truncated => {
                    findings.push(finding(&session_id, RecoveryDisposition::TruncatedJournal))
                }
                JournalValidation::Malformed => {
                    findings.push(finding(&session_id, RecoveryDisposition::MalformedJournal))
                }
                JournalValidation::IntegrityMismatch => {
                    findings.push(finding(&session_id, RecoveryDisposition::IntegrityMismatch))
                }
                JournalValidation::UnsupportedVersion => findings.push(finding(
                    &session_id,
                    RecoveryDisposition::UnsupportedJournalVersion,
                )),
            }
        }

        for session_id in directory_sessions {
            findings.push(finding(&session_id, RecoveryDisposition::OrphanDirectory));
        }
        findings.sort_by(|left, right| left.session_id.0.cmp(&right.session_id.0));
        Ok(findings)
    }

    pub(crate) fn reconcile_interruption(
        &mut self,
        session_id: &str,
        records: &[JournalRecord],
        base: RecoveryDisposition,
    ) -> Result<RecoveryDisposition, StoreError> {
        let interruptions: Vec<_> = records
            .iter()
            .filter(|record| record.body.event_kind == "session_interrupted")
            .collect();
        if interruptions.is_empty() {
            return Ok(base);
        }
        if interruptions.len() != 1
            || !library_recovery::recovery_records_only(
                &records[interruptions[0].body.sequence as usize..],
            )
        {
            return Ok(RecoveryDisposition::IntegrityMismatch);
        }
        let interruption = interruptions[0];
        SessionInterruptionReason::parse(payload_string(&interruption.body.payload, "reason")?)?;
        let lifecycle: SessionLifecycle = self.connection.query_row(
            "SELECT lifecycle FROM sessions WHERE id = ?1",
            [session_id],
            |row| row.get(0),
        )?;
        if lifecycle.is_interruptible() {
            self.project_session_interruption(session_id, interruption)?;
            return Ok(RecoveryDisposition::InterruptionProjectionRepaired);
        }
        if lifecycle != SessionLifecycle::Interrupted {
            return Ok(RecoveryDisposition::IntegrityMismatch);
        }
        Ok(match base {
            RecoveryDisposition::Prepared | RecoveryDisposition::ProjectionRepaired => {
                RecoveryDisposition::InterruptedPrepared
            }
            RecoveryDisposition::MediaOpenPrepared
            | RecoveryDisposition::MediaOpenProjectionRepaired
            | RecoveryDisposition::MediaOpenAwaitingReceipt => {
                RecoveryDisposition::InterruptedMediaOpen
            }
            RecoveryDisposition::FirstSamplePrepared
            | RecoveryDisposition::FirstSampleProjectionRepaired => {
                RecoveryDisposition::InterruptedFirstSample
            }
            RecoveryDisposition::SegmentSealedPrepared
            | RecoveryDisposition::SegmentSealProjectionRepaired
            | RecoveryDisposition::SourceFailedRecording
            | RecoveryDisposition::SourceFailureProjectionRepaired => {
                RecoveryDisposition::InterruptedSegmentSealed
            }
            other => other,
        })
    }

    pub(crate) fn repair_directory_projection(
        &mut self,
        session_id: &str,
        records: &[JournalRecord],
    ) -> Result<(), StoreError> {
        let now = wall_time_milliseconds();
        let journal_record = records.last().expect("validated non-empty journal");
        let event_exists: bool = self.connection.query_row(
            "SELECT EXISTS(
                SELECT 1 FROM session_events
                WHERE session_id = ?1 AND event_kind = 'session_directory_ready'
             )",
            [session_id],
            |row| row.get(0),
        )?;

        let transaction = self.connection.transaction()?;
        if !event_exists {
            let (sequence, prior_digest): (i64, Option<String>) = transaction.query_row(
                "SELECT COALESCE(MAX(sequence), 0) + 1,
                        (SELECT digest FROM session_events
                         WHERE session_id = ?1 ORDER BY sequence DESC LIMIT 1)
                 FROM session_events WHERE session_id = ?1",
                [session_id],
                |row| Ok((row.get(0)?, row.get(1)?)),
            )?;
            let payload = json!({
                "recovered_from_journal_digest": journal_record.record_digest,
            });
            let digest = event_digest(
                session_id,
                sequence as u64,
                "session_directory_ready",
                &payload,
                prior_digest.as_deref(),
            )?;
            insert_event(
                &transaction,
                session_id,
                sequence as u64,
                "session_directory_ready",
                now,
                &payload,
                prior_digest.as_deref(),
                &digest,
            )?;
        }
        transaction.execute(
            "UPDATE sessions SET journal_durable = 1, updated_at_ms = ?2 WHERE id = ?1",
            params![session_id, now],
        )?;
        transaction.execute(
            "INSERT INTO recovery_runs (
                id, schema_version, session_id, disposition, created_at_ms
             ) VALUES (?1, ?2, ?3, 'projection_repaired', ?4)",
            params![Uuid::now_v7().to_string(), SCHEMA_VERSION, session_id, now],
        )?;
        transaction.commit()?;
        Ok(())
    }
}
