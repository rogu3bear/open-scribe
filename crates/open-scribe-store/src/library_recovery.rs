//! Library-wide recovery for one launch. Every nonterminal session is recovered
//! on its own: an evidence problem in one session becomes that session's
//! finding and never blocks the sessions beside it. Storage failures still abort.
use super::*;

/// One launch's recovery result: at most one finding per session plus the
/// playable media recovery promoted or confirmed.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct LibraryRecovery {
    pub findings: Vec<RecoveryFinding>,
    pub playable: Vec<RecoveredPlayableSession>,
}

/// One evidence rule for "playable recovered", shared by the launch listing and
/// the playback lease: the session's projected recovery event and its recovery
/// run agree, whichever recovery produced them (promoted capturing media or a
/// finalized sealed timeline). Expects `sessions` in scope.
pub(super) const RECOVERED_SESSION_EVIDENCE_SQL: &str = "(EXISTS (
        SELECT 1 FROM session_events recovery_events
        WHERE recovery_events.session_id = sessions.id
          AND recovery_events.event_kind IN ('playable_media_recovered', 'timeline_recovered')
    ) AND EXISTS (
        SELECT 1 FROM recovery_runs
        WHERE recovery_runs.session_id = sessions.id
          AND recovery_runs.disposition IN ('playable_media_recovered', 'timeline_recovered')
    ))";

/// A media file's identity for one launch: device, inode, and byte length.
pub(super) type MediaIdentity = (u64, u64, u64);

/// One reviewable recovered segment's session and its own validation result.
pub(super) type RecoveredPlayableRow = (String, Result<RecoveredPlayableSession, StoreError>);

/// Media digests computed by this store. Every full hash is counted. While a
/// launch recovery pass runs, digests are memoized by file identity so the
/// replay, the sealed-companion check, and the listing hash each segment once;
/// outside the pass (a playback lease hours later) every caller hashes afresh.
#[derive(Default)]
pub(super) struct DigestMemo {
    computations: u64,
    launch: Option<BTreeMap<MediaIdentity, String>>,
}

impl DigestMemo {
    pub(super) fn begin_launch(&mut self) {
        self.launch = Some(BTreeMap::new());
    }

    pub(super) fn end_launch(&mut self) {
        self.launch = None;
    }

    pub(super) fn recall(&self, identity: MediaIdentity) -> Option<String> {
        self.launch.as_ref()?.get(&identity).cloned()
    }

    pub(super) fn record(&mut self, identity: MediaIdentity, digest: &str) {
        self.computations += 1;
        if let Some(launch) = self.launch.as_mut() {
            launch.insert(identity, digest.to_owned());
        }
    }

    pub(super) fn computations(&self) -> u64 {
        self.computations
    }
}

impl SessionStore {
    /// Test seam: full media digests computed since this store was opened.
    #[must_use]
    pub fn digest_computations(&self) -> u64 {
        self.digest_memo.borrow().computations()
    }
}

impl RecoveryDisposition {
    /// The session's journal or directory cannot be trusted. Later stages leave
    /// its media untouched instead of promoting or finalizing it. A missing or
    /// invalid media file is not in this set: an authorized successor that never
    /// opened is an ordinary crash point that gap recovery resolves, and accepted
    /// media is re-validated against its sealed evidence before any promotion.
    pub(super) fn blocks_recovery(self) -> bool {
        matches!(
            self,
            Self::MissingDirectory
                | Self::MissingJournal
                | Self::TruncatedJournal
                | Self::MalformedJournal
                | Self::IntegrityMismatch
                | Self::UnsupportedJournalVersion
                | Self::OrphanDirectory
        )
    }
}

/// Errors that describe one session's evidence become that session's finding.
/// SQLite failures and I/O errors other than a missing file still abort the launch.
pub(super) fn isolated_disposition(error: StoreError) -> Result<RecoveryDisposition, StoreError> {
    match error {
        StoreError::IntegrityMismatch(_)
        | StoreError::InvalidState(_)
        | StoreError::InvalidRequest(_)
        | StoreError::Json(_)
        | StoreError::JournalRecordTooLarge => Ok(RecoveryDisposition::IntegrityMismatch),
        StoreError::Io(error) if error.kind() == std::io::ErrorKind::NotFound => {
            Ok(RecoveryDisposition::MissingMediaFile)
        }
        other => Err(other),
    }
}

/// True when every record is one launch recovery itself appends. A recovery pass
/// cut short (a kill, or an aborting error in a later session) can leave such
/// records after an interruption; later stages reuse them instead of writing
/// them again, so they do not make the interruption untrustworthy.
pub(super) fn recovery_records_only(records: &[JournalRecord]) -> bool {
    records
        .iter()
        .all(|record| match record.body.event_kind.as_str() {
            "segment_capture_gap" => {
                record.body.payload.get("reason").and_then(Value::as_str)
                    == Some("terminated_before_first_sample")
            }
            "playable_media_recovered" | "timeline_recovered" => true,
            _ => false,
        })
}

/// Keeps one finding per session. A blocking finding is never downgraded by a
/// later stage's result.
fn merge_finding(findings: &mut Vec<RecoveryFinding>, next: RecoveryFinding) {
    match findings
        .iter_mut()
        .find(|existing| existing.session_id == next.session_id)
    {
        Some(existing) if existing.disposition.blocks_recovery() => {}
        Some(existing) => existing.disposition = next.disposition,
        None => findings.push(next),
    }
}

fn blocked_sessions(findings: &[RecoveryFinding]) -> BTreeSet<String> {
    findings
        .iter()
        .filter(|finding| finding.disposition.blocks_recovery())
        .map(|finding| finding.session_id.0.clone())
        .collect()
}

impl SessionStore {
    /// Recovers every nonterminal session independently, then lists the
    /// playable media of every reviewable session. Media digests are memoized
    /// for the duration of the pass so each segment is hashed at most once.
    pub fn recover_library(&mut self) -> Result<LibraryRecovery, StoreError> {
        self.digest_memo.borrow_mut().begin_launch();
        let recovery = self.recover_library_pass();
        self.digest_memo.borrow_mut().end_launch();
        recovery
    }

    fn recover_library_pass(&mut self) -> Result<LibraryRecovery, StoreError> {
        self.settle_deletion_intents()?;
        self.settle_package_restorations()?;
        let mut findings = self.recover_preparations()?;
        let blocked = blocked_sessions(&findings);
        for finding in self.recover_abandoned_preparations(&blocked)? {
            merge_finding(&mut findings, finding);
        }
        let blocked = blocked_sessions(&findings);
        for finding in self.recover_unstarted_successors(&blocked)? {
            merge_finding(&mut findings, finding);
        }
        let blocked = blocked_sessions(&findings);
        for finding in self.recover_capturing_media(&blocked)? {
            merge_finding(&mut findings, finding);
        }
        let playable = self.list_recovered_playable(&mut findings)?;
        findings.sort_by(|left, right| left.session_id.0.cmp(&right.session_id.0));
        Ok(LibraryRecovery { findings, playable })
    }

    /// A launch has no surviving capture to finish durable preparation. Mark
    /// only trusted capture intents with no authorized media interrupted; import
    /// jobs and sessions with media retain their own recovery protocols.
    fn recover_abandoned_preparations(
        &mut self,
        blocked: &BTreeSet<String>,
    ) -> Result<Vec<RecoveryFinding>, StoreError> {
        let sessions: Vec<String> = {
            let mut query = self.connection.prepare(
                "SELECT id FROM sessions WHERE origin = 'capture' AND lifecycle = 'preparing'
                 AND journal_durable = 1 AND NOT EXISTS (
                    SELECT 1 FROM segments WHERE segments.session_id = sessions.id
                 ) AND NOT EXISTS (
                    SELECT 1 FROM session_restorations
                    WHERE session_restorations.session_id = sessions.id
                 ) ORDER BY id",
            )?;
            query
                .query_map([], |row| row.get(0))?
                .collect::<Result<_, _>>()?
        };
        let mut findings = Vec::new();
        for id in sessions.into_iter().filter(|id| !blocked.contains(id)) {
            let session_id = SessionId(id);
            let disposition = match self.interrupt_session(InterruptSessionRequest {
                session_id: session_id.clone(),
                reason: SessionInterruptionReason::CaptureStartFailed,
            }) {
                Ok(_) => RecoveryDisposition::InterruptedPrepared,
                Err(error) => isolated_disposition(error)?,
            };
            findings.push(RecoveryFinding {
                session_id,
                disposition,
            });
        }
        Ok(findings)
    }

    /// Lists every reviewable recovered session. A session whose accepted media
    /// no longer matches its evidence is left out with its own finding; the
    /// sessions beside it still list and play.
    fn list_recovered_playable(
        &self,
        findings: &mut Vec<RecoveryFinding>,
    ) -> Result<Vec<RecoveredPlayableSession>, StoreError> {
        let mut rejected = BTreeMap::<String, RecoveryDisposition>::new();
        let mut listed = Vec::new();
        for (session_id, row) in self.recovered_playable_rows()? {
            match row {
                Ok(item) => listed.push(item),
                Err(error) => {
                    let disposition = isolated_disposition(error)?;
                    rejected.entry(session_id).or_insert(disposition);
                }
            }
        }
        for (session_id, disposition) in &rejected {
            merge_finding(findings, finding(session_id, *disposition));
        }
        listed.retain(|item| !rejected.contains_key(&item.session_id.0));
        Ok(listed)
    }

    /// Plans every candidate before mutating one, then durably promotes only
    /// independently valid, closed-by-process-exit CAF media to reviewable playback.
    pub fn recover_playable_sessions(
        &mut self,
    ) -> Result<Vec<RecoveredPlayableSession>, StoreError> {
        Ok(self.recover_library()?.playable)
    }

    /// Replays one session's valid journal into the projection.
    pub(super) fn recover_journaled_session(
        &mut self,
        session_id: &str,
        journal_durable: bool,
        records: &[JournalRecord],
    ) -> Result<RecoveryDisposition, StoreError> {
        let base = self.recover_valid_journal(session_id, journal_durable, records)?;
        let imported = self.reconcile_import(session_id, records, base)?;
        let source_failure = self.reconcile_source_failures(session_id, records, imported)?;
        self.reconcile_interruption(session_id, records, source_failure)
    }

    fn recover_capturing_media(
        &mut self,
        blocked: &BTreeSet<String>,
    ) -> Result<Vec<RecoveryFinding>, StoreError> {
        let candidates = {
            let mut statement = self.connection.prepare(
                "SELECT sessions.id, sources.id, tracks.id, segments.id,
                        segments.relative_path, segments.file_device, segments.file_inode
                 FROM sessions
                 JOIN sources ON sources.session_id = sessions.id
                 JOIN tracks ON tracks.session_id = sessions.id AND tracks.source_id = sources.id
                 JOIN segments ON segments.session_id = sessions.id
                              AND segments.track_id = tracks.id
                 WHERE sessions.lifecycle IN (
                           'preparing', 'recording', 'paused', 'finalizing', 'interrupted', 'ready_for_review'
                       )
                   AND segments.lifecycle = 'capturing'
                 ORDER BY sessions.id, segments.sequence",
            )?;
            let rows = statement.query_map([], |row| {
                Ok(PlayableRecoveryCandidate {
                    session_id: row.get(0)?,
                    source_id: row.get(1)?,
                    track_id: row.get(2)?,
                    segment_id: row.get(3)?,
                    relative_path: row.get(4)?,
                    file_device: row.get::<_, i64>(5)? as u64,
                    file_inode: row.get::<_, i64>(6)? as u64,
                })
            })?;
            rows.collect::<Result<Vec<_>, _>>()?
        };

        let mut candidates_by_session = BTreeMap::<String, Vec<_>>::new();
        for candidate in candidates {
            if blocked.contains(&candidate.session_id) {
                continue;
            }
            candidates_by_session
                .entry(candidate.session_id.clone())
                .or_default()
                .push(candidate);
        }

        let mut findings = Vec::new();
        let mut plans_by_session = Vec::new();
        for (session_id, candidates) in candidates_by_session {
            match self.plan_playable_recovery(&session_id, candidates) {
                Ok(plans) if !plans.is_empty() => plans_by_session.push((session_id, plans)),
                Ok(_) => {}
                Err(error) => findings.push(finding(&session_id, isolated_disposition(error)?)),
            }
        }
        for (session_id, plans) in plans_by_session {
            let disposition = match self.promote_playable_recovery(&session_id, plans) {
                Ok(()) => RecoveryDisposition::PlayableMediaRecovered,
                Err(error) => isolated_disposition(error)?,
            };
            findings.push(finding(&session_id, disposition));
        }
        Ok(findings)
    }

    /// An empty plan means the session's capturing media is not independently
    /// recoverable yet; nothing is mutated for it.
    fn plan_playable_recovery(
        &self,
        session_id: &str,
        candidates: Vec<PlayableRecoveryCandidate>,
    ) -> Result<Vec<(Value, ValidatedMediaFile)>, StoreError> {
        let journal_path = self.session_directory(session_id)?.join(JOURNAL_NAME);
        let records = match validate_journal(&journal_path, session_id)? {
            JournalValidation::Valid(records) => records,
            _ => return Ok(Vec::new()),
        };
        let mut plans = Vec::new();
        for candidate in candidates {
            let Some(first_sample) = journal_record_for_segment(
                &records,
                "first_sample_captured",
                &candidate.segment_id,
            )?
            else {
                return Ok(Vec::new());
            };
            let observed_byte_length =
                payload_u64(&first_sample.body.payload, "observed_byte_length")?;
            let Ok(validated) = self.validate_media_file(
                &candidate.session_id,
                &candidate.relative_path,
                MediaLengthRequirement::AtLeast(observed_byte_length),
                true,
            ) else {
                return Ok(Vec::new());
            };
            if validated.device != candidate.file_device || validated.inode != candidate.file_inode
            {
                return Ok(Vec::new());
            }
            let Some(sample_count) = validated.recoverable_sample_count else {
                return Ok(Vec::new());
            };
            let digest_sha256 = validated
                .digest_sha256
                .clone()
                .ok_or(StoreError::IntegrityMismatch("recovery digest is missing"))?;
            let payload = json!({
                "source_id": candidate.source_id,
                "track_id": candidate.track_id,
                "segment_id": candidate.segment_id,
                "relative_path": candidate.relative_path,
                "sample_count": sample_count,
                "final_byte_length": validated.byte_length,
                "digest_sha256": digest_sha256,
                "file_device": validated.device,
                "file_inode": validated.inode,
                "truncated_bytes": 0,
            });
            plans.push((payload, validated));
        }
        Ok(plans)
    }

    fn promote_playable_recovery(
        &mut self,
        session_id: &str,
        plans: Vec<(Value, ValidatedMediaFile)>,
    ) -> Result<(), StoreError> {
        let journal_path = self.session_directory(session_id)?.join(JOURNAL_NAME);
        let records = match validate_journal(&journal_path, session_id)? {
            JournalValidation::Valid(records) => records,
            _ => return Err(StoreError::IntegrityMismatch("session journal changed")),
        };
        let mut playable_source_kinds =
            self.validate_sealed_recovery_companions(session_id, &records)?;
        for (payload, _) in &plans {
            let source_id = payload_string(payload, "source_id")?;
            let source_kind: String = self.connection.query_row(
                "SELECT kind FROM sources WHERE id = ?1 AND session_id = ?2",
                params![source_id, session_id],
                |row| row.get(0),
            )?;
            MediaSourceKind::from_str(&source_kind)?;
            playable_source_kinds.insert(source_kind);
        }
        if self
            .evidenced_source_kinds(session_id)?
            .iter()
            .any(|kind| !playable_source_kinds.contains(kind))
        {
            return Err(StoreError::InvalidState(
                "session recovery is missing a required playable source",
            ));
        }
        let mut projections = Vec::new();
        let mut _recovery_candidate_handles = Vec::new();
        for (payload, validated) in plans {
            _recovery_candidate_handles.push(validated);
            let segment_id = payload_string(&payload, "segment_id")?;
            let relative_path = payload_string(&payload, "relative_path")?;
            let journal_record = if let Some(existing) =
                journal_record_for_segment(&records, "playable_media_recovered", segment_id)?
            {
                if existing.body.payload != payload {
                    return Err(StoreError::IntegrityMismatch(
                        "recovery plan changed accepted evidence",
                    ));
                }
                existing.clone()
            } else {
                self.append_session_journal(
                    session_id,
                    "playable_media_recovered",
                    Some(relative_path),
                    payload.clone(),
                )?
            };
            projections.push(PlayableRecoveryProjection {
                payload,
                journal_record,
            });
        }
        self.project_playable_recovery_session(session_id, &projections, &playable_source_kinds)
    }
}
