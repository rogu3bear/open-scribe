use super::*;

impl SessionStore {
    pub(super) fn recover_valid_journal(
        &mut self,
        session_id: &str,
        journal_durable: bool,
        records: &[JournalRecord],
    ) -> Result<RecoveryDisposition, StoreError> {
        let repaired_directory = if journal_durable {
            false
        } else {
            self.repair_directory_projection(session_id, records)?;
            true
        };
        self.reconcile_clock(session_id, records)?;
        self.reconcile_recorder_events(session_id, records)?;
        // Reserve all journaled successors before replaying seals, so a seal
        // cannot accidentally finalize a source while its successor is missing
        // only from the SQLite projection.
        for record in records
            .iter()
            .filter(|r| r.body.event_kind == "segment_open_intent")
        {
            let id = payload_string(&record.body.payload, "segment_id")?;
            let exists: bool = self.connection.query_row(
                "SELECT EXISTS(SELECT 1 FROM segments WHERE id = ?1 AND session_id = ?2)",
                params![id, session_id],
                |row| row.get(0),
            )?;
            if !exists {
                self.project_media_authorization(session_id, &record.body.payload, record)?;
            }
        }
        let mut disposition = if repaired_directory {
            RecoveryDisposition::ProjectionRepaired
        } else {
            RecoveryDisposition::Prepared
        };
        for record in records
            .iter()
            .filter(|r| r.body.event_kind == "segment_open_intent")
        {
            disposition = self.recover_segment_journal(session_id, records, record)?;
            if matches!(
                disposition,
                RecoveryDisposition::IntegrityMismatch | RecoveryDisposition::InvalidMediaFile
            ) {
                return Ok(disposition);
            }
        }
        Ok(disposition)
    }

    fn recover_segment_journal(
        &mut self,
        session_id: &str,
        records: &[JournalRecord],
        authorization_record: &JournalRecord,
    ) -> Result<RecoveryDisposition, StoreError> {
        let segment_id = payload_string(&authorization_record.body.payload, "segment_id")?;
        let channels = payload_u64(&authorization_record.body.payload, "channels")?;
        if channels != 1 && channels != 2 {
            return Ok(RecoveryDisposition::IntegrityMismatch);
        }
        let opened_record = journal_record_for_segment(records, "segment_opened", segment_id)?;
        let first_sample_record =
            journal_record_for_segment(records, "first_sample_captured", segment_id)?;
        let sealed_record = journal_record_for_segment(records, "segment_sealed", segment_id)?;
        let projected: bool = self.connection.query_row(
            "SELECT EXISTS(SELECT 1 FROM segments WHERE id = ?1 AND session_id = ?2)",
            params![segment_id, session_id],
            |row| row.get(0),
        )?;
        if !projected {
            self.project_media_authorization(
                session_id,
                &authorization_record.body.payload,
                authorization_record,
            )?;
        }

        if let Some(opened_record) = opened_record {
            let relative_path = payload_string(&opened_record.body.payload, "relative_path")?;
            let byte_length = payload_u64(&opened_record.body.payload, "initial_byte_length")?;
            let validated = match self.validate_media_file(
                session_id,
                relative_path,
                MediaLengthRequirement::AtLeast(byte_length),
                false,
            ) {
                Ok(validated) => validated,
                Err(_) => {
                    return Ok(classify_media_path(
                        &self.session_directory(session_id)?.join(relative_path),
                    ));
                }
            };
            let expected_device = payload_u64(&opened_record.body.payload, "file_device")?;
            let expected_inode = payload_u64(&opened_record.body.payload, "file_inode")?;
            if validated.device != expected_device
                || validated.inode != expected_inode
                || validated
                    .channels
                    .is_some_and(|actual| actual != channels as u16)
            {
                return Ok(RecoveryDisposition::InvalidMediaFile);
            }
            let lifecycle: String = self.connection.query_row(
                "SELECT lifecycle FROM segments WHERE id = ?1",
                [segment_id],
                |row| row.get(0),
            )?;
            let media_open = lifecycle != "opening";
            if !media_open {
                self.project_media_open(session_id, &opened_record.body.payload, opened_record)?;
            }
            if let Some(sealed_record) = sealed_record {
                let payload = &sealed_record.body.payload;
                if payload_string(payload, "segment_id")? != segment_id
                    || payload_string(payload, "relative_path")? != relative_path
                    || payload_u64(payload, "file_device")? != expected_device
                    || payload_u64(payload, "file_inode")? != expected_inode
                {
                    return Ok(RecoveryDisposition::IntegrityMismatch);
                }
                let final_byte_length = payload_u64(payload, "final_byte_length")?;
                let sealed = match self.validate_media_file(
                    session_id,
                    relative_path,
                    MediaLengthRequirement::Exact(final_byte_length),
                    true,
                ) {
                    Ok(sealed) => sealed,
                    Err(_) => return Ok(RecoveryDisposition::InvalidMediaFile),
                };
                if sealed.digest_sha256.as_deref()
                    != Some(payload_string(payload, "digest_sha256")?)
                    || sealed.channels != Some(channels as u16)
                {
                    return Ok(RecoveryDisposition::IntegrityMismatch);
                }
                let segment_lifecycle: String = self.connection.query_row(
                    "SELECT lifecycle FROM segments WHERE id = ?1 AND session_id = ?2",
                    params![segment_id, session_id],
                    |row| row.get(0),
                )?;
                if segment_lifecycle == "sealed" {
                    return Ok(RecoveryDisposition::SegmentSealedPrepared);
                }
                if segment_lifecycle == "open" {
                    let Some(first) = first_sample_record else {
                        return Ok(RecoveryDisposition::IntegrityMismatch);
                    };
                    self.project_first_sample(session_id, &first.body.payload, first)?;
                } else if segment_lifecycle != "capturing" {
                    return Ok(RecoveryDisposition::IntegrityMismatch);
                }
                self.project_segment_seal(session_id, payload, sealed_record)?;
                return Ok(RecoveryDisposition::SegmentSealProjectionRepaired);
            }
            if let Some(first_sample_record) = first_sample_record {
                let payload = &first_sample_record.body.payload;
                if payload_string(payload, "segment_id")? != segment_id
                    || payload_string(payload, "relative_path")? != relative_path
                    || payload_u64(payload, "file_device")? != expected_device
                    || payload_u64(payload, "file_inode")? != expected_inode
                    || payload_i64(payload, "first_sample_session_nanoseconds")?
                        != self.map_capture_time(
                            session_id,
                            payload_u64(payload, "first_sample_host_time")?,
                        )?
                {
                    return Ok(RecoveryDisposition::IntegrityMismatch);
                }
                let observed_byte_length = payload_u64(payload, "observed_byte_length")?;
                if self
                    .validate_media_file(
                        session_id,
                        relative_path,
                        MediaLengthRequirement::AtLeast(observed_byte_length),
                        false,
                    )
                    .map_or(true, |validated| {
                        validated
                            .channels
                            .is_some_and(|actual| actual != channels as u16)
                    })
                {
                    return Ok(RecoveryDisposition::InvalidMediaFile);
                }
                let segment_lifecycle: String = self.connection.query_row(
                    "SELECT lifecycle FROM segments WHERE id = ?1 AND session_id = ?2",
                    params![segment_id, session_id],
                    |row| row.get(0),
                )?;
                if segment_lifecycle == "capturing" {
                    return Ok(RecoveryDisposition::FirstSamplePrepared);
                }
                if segment_lifecycle == "sealed"
                    && journal_record_for_segment(records, "playable_media_recovered", segment_id)?
                        .is_some()
                {
                    return Ok(RecoveryDisposition::SegmentSealedPrepared);
                }
                if segment_lifecycle != "open" {
                    return Ok(RecoveryDisposition::IntegrityMismatch);
                }
                self.project_first_sample(session_id, payload, first_sample_record)?;
                return Ok(RecoveryDisposition::FirstSampleProjectionRepaired);
            }

            return Ok(if media_open {
                RecoveryDisposition::MediaOpenPrepared
            } else {
                RecoveryDisposition::MediaOpenProjectionRepaired
            });
        }

        let relative_path = payload_string(&authorization_record.body.payload, "relative_path")?;
        let media_path = self.session_directory(session_id)?.join(relative_path);
        let metadata = match fs::symlink_metadata(&media_path) {
            Ok(metadata) => metadata,
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
                return Ok(RecoveryDisposition::MissingMediaFile);
            }
            Err(error) => return Err(error.into()),
        };
        if self
            .validate_media_file(
                session_id,
                relative_path,
                MediaLengthRequirement::Exact(metadata.len()),
                false,
            )
            .is_ok_and(|validated| {
                validated
                    .channels
                    .is_none_or(|actual| actual == channels as u16)
            })
        {
            Ok(RecoveryDisposition::MediaOpenAwaitingReceipt)
        } else {
            Ok(RecoveryDisposition::InvalidMediaFile)
        }
    }
}
