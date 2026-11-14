//! The per-session recovery journal: record format, validation, appends and
//! crash-safe replacement.

use super::*;

pub(crate) const JOURNAL_VERSION: u32 = 1;

pub(crate) const MAX_JOURNAL_RECORD_BYTES: usize = 16 * 1024;

pub(crate) const JOURNAL_NAME: &str = "recovery.jsonl";

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
pub(crate) struct JournalBody {
    pub(crate) version: u32,
    pub(crate) sequence: u64,
    pub(crate) event_id: String,
    pub(crate) session_id: String,
    pub(crate) event_kind: String,
    pub(crate) session_nanoseconds: i64,
    pub(crate) wall_time_milliseconds: i64,
    pub(crate) relative_path: Option<String>,
    pub(crate) payload: Value,
    pub(crate) prior_digest: Option<String>,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
pub(crate) struct JournalRecord {
    #[serde(flatten)]
    pub(crate) body: JournalBody,
    pub(crate) record_digest: String,
}

pub(crate) enum JournalValidation {
    Valid(Vec<JournalRecord>),
    Truncated,
    Malformed,
    IntegrityMismatch,
    UnsupportedVersion,
}

pub(crate) fn new_journal_record(session_id: &str, now: i64) -> Result<JournalRecord, StoreError> {
    let body = JournalBody {
        version: JOURNAL_VERSION,
        sequence: 1,
        event_id: Uuid::now_v7().to_string(),
        session_id: session_id.to_owned(),
        event_kind: "session_directory_ready".to_owned(),
        session_nanoseconds: 0,
        wall_time_milliseconds: now,
        relative_path: Some(".".to_owned()),
        payload: json!({ "subdirectories": SESSION_SUBDIRECTORIES }),
        prior_digest: None,
    };
    let record_digest = digest_json(&body)?;
    Ok(JournalRecord {
        body,
        record_digest,
    })
}

pub(crate) fn append_journal_record(
    file: &mut impl Write,
    record: &JournalRecord,
) -> Result<(), StoreError> {
    let encoded = serde_json::to_vec(record)?;
    if encoded.len() > MAX_JOURNAL_RECORD_BYTES {
        return Err(StoreError::JournalRecordTooLarge);
    }
    file.write_all(&encoded)?;
    file.write_all(b"\n")?;
    Ok(())
}

pub(crate) fn atomic_replace_journal_with_record(
    journal_path: &Path,
    session_directory: &Path,
    record: &JournalRecord,
    failure: Option<JournalReplacementFailurePoint>,
    cost: Option<&mut JournalCost>,
) -> Result<(), StoreError> {
    atomic_replace_journal_with_records(
        journal_path,
        session_directory,
        std::slice::from_ref(record),
        failure,
        cost,
    )
}

pub(crate) fn atomic_replace_journal_with_records(
    journal_path: &Path,
    session_directory: &Path,
    records: &[JournalRecord],
    failure: Option<JournalReplacementFailurePoint>,
    cost: Option<&mut JournalCost>,
) -> Result<(), StoreError> {
    let metadata = fs::symlink_metadata(journal_path)?;
    if metadata.file_type().is_symlink() || !metadata.is_file() {
        return Err(StoreError::IntegrityMismatch(
            "session journal is not a regular append target",
        ));
    }
    let existing = fs::read(journal_path)?;
    if existing.is_empty() || !existing.ends_with(b"\n") {
        return Err(StoreError::IntegrityMismatch(
            "session journal is not a complete append target",
        ));
    }
    let temporary_name = journal_replacement::temporary_name();
    let _live = journal_replacement::LiveReplacement::begin(temporary_name.clone());
    let temporary_path = session_directory.join(&temporary_name);
    let mut unmeasured = JournalCost::default();
    let cost = cost.unwrap_or(&mut unmeasured);
    let result = (|| {
        let mut temporary = journal_replacement::create_temporary(&temporary_path)?;
        let mut counted = journal_cost::CountedWriter {
            inner: &mut temporary,
            cost,
        };
        counted.write_all(&existing)?;
        counted.cost.bytes_copied += existing.len() as u64;
        #[cfg(test)]
        if failure == Some(JournalReplacementFailurePoint::PartialWriteNoSpace) {
            let encoded = serde_json::to_vec(&records[0])?;
            counted.write_all(&encoded[..encoded.len() / 2])?;
            return Err(std::io::Error::from_raw_os_error(28).into());
        }
        for record in records {
            append_journal_record(&mut counted, record)?;
        }
        interrupt_journal_replace_if(failure, JournalReplacementFailurePoint::TemporaryWrite)?;
        counted.cost.sync_calls += 1;
        counted.inner.sync_all()?;
        interrupt_journal_replace_if(failure, JournalReplacementFailurePoint::TemporarySync)?;
        fs::rename(&temporary_path, journal_path)?;
        #[cfg(test)]
        if failure == Some(JournalReplacementFailurePoint::AfterRenameNoSpace) {
            return Err(std::io::Error::from_raw_os_error(28).into());
        }
        interrupt_journal_replace_if(failure, JournalReplacementFailurePoint::Rename)?;
        counted.cost.sync_calls += 1;
        sync_directory(session_directory)?;
        interrupt_journal_replace_if(failure, JournalReplacementFailurePoint::DirectorySync)?;
        Ok(())
    })();
    if result.is_err() {
        let _ = fs::remove_file(&temporary_path);
    }
    result
}

pub(crate) fn validate_journal(
    path: &Path,
    expected_session_id: &str,
) -> Result<JournalValidation, StoreError> {
    let metadata = fs::symlink_metadata(path)?;
    if metadata.file_type().is_symlink() || !metadata.is_file() {
        return Ok(JournalValidation::IntegrityMismatch);
    }
    let bytes = fs::read(path)?;
    if bytes.is_empty() || !bytes.ends_with(b"\n") {
        return Ok(JournalValidation::Truncated);
    }

    let mut records = Vec::new();
    let mut expected_sequence = 1_u64;
    let mut prior_digest: Option<String> = None;
    for line in BufReader::new(bytes.as_slice()).split(b'\n') {
        let line = line?;
        if line.is_empty() {
            continue;
        }
        if line.len() > MAX_JOURNAL_RECORD_BYTES {
            return Ok(JournalValidation::Malformed);
        }
        let record: JournalRecord = match serde_json::from_slice(&line) {
            Ok(record) => record,
            Err(_) => return Ok(JournalValidation::Malformed),
        };
        if record.body.version != JOURNAL_VERSION {
            return Ok(JournalValidation::UnsupportedVersion);
        }
        if record.body.sequence != expected_sequence
            || record.body.session_id != expected_session_id
            || record.body.prior_digest != prior_digest
            || record.record_digest != digest_json(&record.body)?
            || !record
                .body
                .relative_path
                .as_deref()
                .is_none_or(valid_relative_path)
        {
            return Ok(JournalValidation::IntegrityMismatch);
        }
        expected_sequence += 1;
        prior_digest = Some(record.record_digest.clone());
        records.push(record);
    }
    Ok(JournalValidation::Valid(records))
}

pub(crate) fn journal_has_directory_ready(records: &[JournalRecord]) -> bool {
    records
        .iter()
        .any(|record| record.body.event_kind == "session_directory_ready")
}

pub(crate) fn journal_record_for_segment<'a>(
    records: &'a [JournalRecord],
    event_kind: &str,
    segment_id: &str,
) -> Result<Option<&'a JournalRecord>, StoreError> {
    for record in records.iter().rev() {
        if record.body.event_kind == event_kind
            && payload_string(&record.body.payload, "segment_id")? == segment_id
        {
            return Ok(Some(record));
        }
    }
    Ok(None)
}

pub(crate) fn payload_string<'a>(payload: &'a Value, key: &str) -> Result<&'a str, StoreError> {
    payload
        .get(key)
        .and_then(Value::as_str)
        .ok_or(StoreError::IntegrityMismatch(
            "journal payload is missing a string field",
        ))
}

pub(crate) fn payload_u64(payload: &Value, key: &str) -> Result<u64, StoreError> {
    payload
        .get(key)
        .and_then(Value::as_u64)
        .ok_or(StoreError::IntegrityMismatch(
            "journal payload is missing an unsigned field",
        ))
}

pub(crate) fn payload_i64(payload: &Value, key: &str) -> Result<i64, StoreError> {
    payload
        .get(key)
        .and_then(Value::as_i64)
        .ok_or(StoreError::IntegrityMismatch(
            "journal payload is missing a signed field",
        ))
}

pub(crate) fn reconcile_stale_journal_replacements(sessions_root: &Path) -> Result<(), StoreError> {
    struct ReconciliationPlan {
        session_directory: PathBuf,
        journal_path: PathBuf,
        adoption: Option<PathBuf>,
        discard: Vec<PathBuf>,
    }

    let mut plans = Vec::new();
    for session_entry in fs::read_dir(sessions_root)? {
        let session_entry = session_entry?;
        let session_metadata = session_entry.metadata()?;
        if !session_metadata.is_dir() || session_entry.file_type()?.is_symlink() {
            continue;
        }
        let session_id = session_entry.file_name().to_string_lossy().into_owned();
        if Uuid::parse_str(&session_id).is_err() {
            continue;
        }
        let session_directory = session_entry.path();
        let mut candidates = Vec::new();
        for candidate_entry in fs::read_dir(&session_directory)? {
            let candidate_entry = candidate_entry?;
            let candidate_name = candidate_entry.file_name().to_string_lossy().into_owned();
            let Some(candidate_id) = journal_replacement::temporary_id(&candidate_name) else {
                continue;
            };
            if Uuid::parse_str(candidate_id).is_err()
                || journal_replacement::is_live(&candidate_name)
            {
                continue;
            }
            let candidate_path = candidate_entry.path();
            // A replacement that vanished since the listing was renamed or
            // removed by the append (or sweep) that owned it.
            let candidate_metadata = match fs::symlink_metadata(&candidate_path) {
                Ok(metadata) => metadata,
                Err(error) if error.kind() == std::io::ErrorKind::NotFound => continue,
                Err(error) => return Err(error.into()),
            };
            if candidate_metadata.file_type().is_symlink() || !candidate_metadata.is_file() {
                return Err(StoreError::IntegrityMismatch(
                    "stale journal replacement is not a regular file",
                ));
            }
            candidates.push(candidate_path);
        }
        if candidates.is_empty() {
            continue;
        }

        let journal_path = session_directory.join(JOURNAL_NAME);
        let authoritative = match validate_journal(&journal_path, &session_id)? {
            JournalValidation::Valid(records) => records,
            _ => {
                return Err(StoreError::IntegrityMismatch(
                    "stale journal replacement has no valid authoritative journal",
                ));
            }
        };
        let mut strict_extensions = Vec::new();
        let mut discard = Vec::new();
        for candidate_path in candidates {
            let validation = match validate_journal(&candidate_path, &session_id) {
                Err(StoreError::Io(error)) if error.kind() == std::io::ErrorKind::NotFound => {
                    continue;
                }
                other => other?,
            };
            match validation {
                JournalValidation::Valid(candidate)
                    if journal_is_strict_extension(&authoritative, &candidate) =>
                {
                    strict_extensions.push(candidate_path);
                }
                JournalValidation::Truncated | JournalValidation::Malformed => {
                    discard.push(candidate_path);
                }
                JournalValidation::Valid(_)
                | JournalValidation::IntegrityMismatch
                | JournalValidation::UnsupportedVersion => {
                    return Err(StoreError::IntegrityMismatch(
                        "stale journal replacement diverges from authoritative history",
                    ));
                }
            }
        }
        if strict_extensions.len() > 1 {
            return Err(StoreError::IntegrityMismatch(
                "multiple valid journal replacements are ambiguous",
            ));
        }
        plans.push(ReconciliationPlan {
            session_directory,
            journal_path,
            adoption: strict_extensions.pop(),
            discard,
        });
    }

    for plan in plans {
        if let Some(adoption) = plan.adoption {
            journal_replacement::ignore_missing(fs::rename(adoption, &plan.journal_path))?;
            sync_directory(&plan.session_directory)?;
        }
        if !plan.discard.is_empty() {
            for candidate in plan.discard {
                journal_replacement::ignore_missing(fs::remove_file(candidate))?;
            }
            sync_directory(&plan.session_directory)?;
        }
    }
    Ok(())
}

pub(crate) fn journal_is_strict_extension(
    authoritative: &[JournalRecord],
    candidate: &[JournalRecord],
) -> bool {
    candidate.len() == authoritative.len() + 1
        && candidate.starts_with(authoritative)
        && candidate.last().is_some_and(|record| {
            record.body.prior_digest
                == authoritative
                    .last()
                    .map(|previous| previous.record_digest.clone())
        })
}

impl SessionStore {
    pub(crate) fn append_session_journal(
        &self,
        session_id: &str,
        event_kind: &str,
        relative_path: Option<&str>,
        payload: Value,
    ) -> Result<JournalRecord, StoreError> {
        self.append_session_journal_inner(session_id, event_kind, relative_path, payload, None)
    }

    pub(crate) fn append_session_journal_inner(
        &self,
        session_id: &str,
        event_kind: &str,
        relative_path: Option<&str>,
        payload: Value,
        failure: Option<JournalReplacementFailurePoint>,
    ) -> Result<JournalRecord, StoreError> {
        let _writer = self.write_guard()?;
        let begun = std::time::Instant::now();
        let session_directory = self.session_directory(session_id)?;
        let journal_path = session_directory.join(JOURNAL_NAME);
        let prior_bytes = fs::symlink_metadata(&journal_path)?.len();
        let records = match validate_journal(&journal_path, session_id)? {
            JournalValidation::Valid(records) if !records.is_empty() => records,
            _ => {
                return Err(StoreError::IntegrityMismatch(
                    "session journal is not a valid append target",
                ));
            }
        };
        let previous = records.last().expect("validated non-empty journal");
        let body = JournalBody {
            version: JOURNAL_VERSION,
            sequence: previous.body.sequence + 1,
            event_id: Uuid::now_v7().to_string(),
            session_id: session_id.to_owned(),
            event_kind: event_kind.to_owned(),
            session_nanoseconds: payload
                .get("session_nanoseconds")
                .or_else(|| payload.get("first_sample_session_nanoseconds"))
                .and_then(Value::as_i64)
                .unwrap_or(0),
            wall_time_milliseconds: wall_time_milliseconds(),
            relative_path: relative_path.map(str::to_owned),
            payload,
            prior_digest: Some(previous.record_digest.clone()),
        };
        let record = JournalRecord {
            record_digest: digest_json(&body)?,
            body,
        };
        // Never extend the canonical inode: a short write or crash must leave
        // a complete old/new journal, and errors after rename must not replay.
        let mut cost = self.journal_cost.borrow_mut();
        cost.bytes_validated += prior_bytes;
        let result = atomic_replace_journal_with_record(
            &journal_path,
            &session_directory,
            &record,
            failure,
            Some(&mut cost),
        );
        cost.elapsed_nanoseconds += begun.elapsed().as_nanos();
        result?;
        cost.appends += 1;
        Ok(record)
    }

    /// Appends records in one journal replacement, chained in order. Only for
    /// a session no other writer can reach until the batch is projected.
    pub(crate) fn append_session_journal_batch(
        &self,
        session_id: &str,
        entries: Vec<(&str, Option<String>, Value)>,
    ) -> Result<Vec<JournalRecord>, StoreError> {
        let session_directory = self.session_directory(session_id)?;
        let journal_path = session_directory.join(JOURNAL_NAME);
        let mut previous = match validate_journal(&journal_path, session_id)? {
            JournalValidation::Valid(mut records) if !records.is_empty() => {
                records.pop().expect("validated non-empty journal")
            }
            _ => {
                return Err(StoreError::IntegrityMismatch(
                    "session journal is not a valid append target",
                ));
            }
        };
        let mut records = Vec::with_capacity(entries.len());
        for (event_kind, relative_path, payload) in entries {
            let body = JournalBody {
                version: JOURNAL_VERSION,
                sequence: previous.body.sequence + 1,
                event_id: Uuid::now_v7().to_string(),
                session_id: session_id.to_owned(),
                event_kind: event_kind.to_owned(),
                session_nanoseconds: payload
                    .get("session_nanoseconds")
                    .and_then(Value::as_i64)
                    .unwrap_or(0),
                wall_time_milliseconds: wall_time_milliseconds(),
                relative_path,
                payload,
                prior_digest: Some(previous.record_digest.clone()),
            };
            let record = JournalRecord {
                record_digest: digest_json(&body)?,
                body,
            };
            previous = record.clone();
            records.push(record);
        }
        atomic_replace_journal_with_records(
            &journal_path,
            &session_directory,
            &records,
            None,
            None,
        )?;
        Ok(records)
    }

    pub(crate) fn last_journal_sequence(&self, session_id: &str) -> Result<u64, StoreError> {
        let journal_path = self.session_directory(session_id)?.join(JOURNAL_NAME);
        match validate_journal(&journal_path, session_id)? {
            JournalValidation::Valid(records) => records
                .last()
                .map(|record| record.body.sequence)
                .ok_or(StoreError::IntegrityMismatch("session journal is empty")),
            _ => Err(StoreError::IntegrityMismatch("session journal is invalid")),
        }
    }
}
