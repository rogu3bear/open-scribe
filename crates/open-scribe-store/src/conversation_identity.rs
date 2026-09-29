use std::fs::{self, OpenOptions};

use open_scribe_types::SessionId;
use rusqlite::params;
use serde_json::json;
use uuid::Uuid;

use super::{
    FailurePoint, JOURNAL_NAME, JOURNAL_VERSION, MAX_TITLE_BYTES, MediaSourceKind, SCHEMA_VERSION,
    SESSION_SUBDIRECTORIES, SessionStore, StoreError, append_journal_record, event_digest,
    insert_event, interrupt_if, new_journal_record, normalized_source_kinds,
    require_real_directory, sync_directory, wall_time_milliseconds,
};

/// Origin is persisted independently from user-visible naming.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum SessionOrigin {
    Capture,
    Import,
}

impl SessionOrigin {
    const fn as_str(self) -> &'static str {
        match self {
            Self::Capture => "capture",
            Self::Import => "import",
        }
    }
}

/// Request to create durable intent for one future conversation.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct PrepareSessionRequest {
    pub title: String,
    pub origin: SessionOrigin,
}

/// Coarse evidence returned after the journal and SQLite identity projection agree.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct PreparedSessionReceipt {
    pub session_id: SessionId,
    pub schema_version: u32,
    pub journal_version: u32,
    pub last_journal_sequence: u64,
    pub journal_durable: bool,
    pub database_projected: bool,
    pub media_files_open: bool,
}

impl PreparedSessionReceipt {
    /// Preparation alone is deliberately insufficient to report Recording.
    #[must_use]
    pub const fn permits_recording(&self) -> bool {
        self.journal_durable && self.media_files_open
    }
}

impl SessionStore {
    pub fn prepare_session(
        &mut self,
        request: PrepareSessionRequest,
    ) -> Result<PreparedSessionReceipt, StoreError> {
        self.prepare_session_with_required_sources(request, vec![MediaSourceKind::Microphone])
    }

    pub fn prepare_session_with_required_sources(
        &mut self,
        request: PrepareSessionRequest,
        required_sources: Vec<MediaSourceKind>,
    ) -> Result<PreparedSessionReceipt, StoreError> {
        let required_sources = normalized_source_kinds(required_sources)?;
        let mut receipt = self.prepare_session_inner(request, None)?;
        let planned = self.plan_required_sources(receipt.session_id.clone(), required_sources)?;
        receipt.last_journal_sequence = planned.last_journal_sequence;
        Ok(receipt)
    }

    pub(super) fn prepare_session_inner(
        &mut self,
        request: PrepareSessionRequest,
        failure: Option<FailurePoint>,
    ) -> Result<PreparedSessionReceipt, StoreError> {
        validate_request(&request)?;
        require_real_directory(&self.sessions_root)?;
        if request.origin == SessionOrigin::Capture {
            self.prepare_storage_reserve()?;
        }
        let session_id = Uuid::now_v7().to_string();
        let now = wall_time_milliseconds();

        let intent_payload = json!({ "origin": request.origin.as_str() });
        let intent_digest = event_digest(
            &session_id,
            1,
            "session_create_intent",
            &intent_payload,
            None,
        )?;
        {
            let transaction = self.connection.transaction()?;
            transaction.execute(
                "INSERT INTO sessions (
                    id, schema_version, title, origin, lifecycle, health,
                    journal_durable, media_files_open, created_at_ms, updated_at_ms
                 ) VALUES (?1, ?2, ?3, ?4, 'preparing', 'healthy', 0, 0, ?5, ?5)",
                params![
                    session_id,
                    SCHEMA_VERSION,
                    request.title,
                    request.origin.as_str(),
                    now
                ],
            )?;
            insert_event(
                &transaction,
                &session_id,
                1,
                "session_create_intent",
                now,
                &intent_payload,
                None,
                &intent_digest,
            )?;
            transaction.commit()?;
        }
        interrupt_if(failure, FailurePoint::DatabaseIntent)?;

        let session_directory = self.sessions_root.join(&session_id);
        fs::create_dir(&session_directory)?;
        for subdirectory in SESSION_SUBDIRECTORIES {
            fs::create_dir(session_directory.join(subdirectory))?;
        }
        sync_directory(&session_directory)?;
        sync_directory(&self.sessions_root)?;
        interrupt_if(failure, FailurePoint::SessionDirectory)?;

        let journal_path = session_directory.join(JOURNAL_NAME);
        let mut journal = OpenOptions::new()
            .create_new(true)
            .write(true)
            .open(&journal_path)?;
        let record = new_journal_record(&session_id, now)?;
        append_journal_record(&mut journal, &record)?;
        journal.sync_all()?;
        sync_directory(&session_directory)?;
        interrupt_if(failure, FailurePoint::JournalSync)?;

        let directory_payload = json!({ "relative_path": "." });
        let directory_digest = event_digest(
            &session_id,
            2,
            "session_directory_ready",
            &directory_payload,
            Some(&intent_digest),
        )?;
        {
            let transaction = self.connection.transaction()?;
            insert_event(
                &transaction,
                &session_id,
                2,
                "session_directory_ready",
                now,
                &directory_payload,
                Some(&intent_digest),
                &directory_digest,
            )?;
            transaction.execute(
                "UPDATE sessions
                 SET journal_durable = 1, updated_at_ms = ?2
                 WHERE id = ?1 AND lifecycle = 'preparing'",
                params![session_id, now],
            )?;
            transaction.commit()?;
        }
        interrupt_if(failure, FailurePoint::DatabaseProjection)?;

        Ok(PreparedSessionReceipt {
            session_id: SessionId(session_id),
            schema_version: SCHEMA_VERSION as u32,
            journal_version: JOURNAL_VERSION,
            last_journal_sequence: record.body.sequence,
            journal_durable: true,
            database_projected: true,
            media_files_open: false,
        })
    }
}

pub(super) fn validate_request(request: &PrepareSessionRequest) -> Result<(), StoreError> {
    let title = request.title.trim();
    if title.is_empty() {
        return Err(StoreError::InvalidRequest("title is empty"));
    }
    if request.title.len() > MAX_TITLE_BYTES {
        return Err(StoreError::InvalidRequest("title exceeds byte limit"));
    }
    Ok(())
}
