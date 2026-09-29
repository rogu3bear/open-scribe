//! Review, search, export, and deletion over the durable library: the coarse
//! native authority the macOS transcript and library surfaces call.
//!
//! It owns its own store connection beside the recording controller; SQLite
//! WAL and immediate transactions serialize their writes. Nothing here runs
//! inference: a transcript exists only when a local run has committed one.

use crate::export::{
    TranscriptAvailability, TranscriptExport, TranscriptExportError, TranscriptExportFormat,
    TranscriptExportReceipt, write_transcript_export,
};
use open_scribe_store::{
    SessionDeletionInventory, SessionDeletionReceipt, SessionSpeaker, SessionStore, StoreError,
    TranscriptDocumentSegment, TranscriptSearchHit,
};
use open_scribe_types::SessionId;
use std::path::Path;

pub struct TranscriptLibrary {
    store: SessionStore,
}

impl TranscriptLibrary {
    pub fn open(managed_root: impl AsRef<Path>) -> Result<Self, StoreError> {
        Ok(Self {
            store: SessionStore::open(managed_root)?,
        })
    }

    pub fn availability(
        &self,
        session: &SessionId,
    ) -> Result<TranscriptAvailability, TranscriptExportError> {
        Ok(TranscriptExport::collect(&self.store, session, 0)?.availability())
    }

    pub fn document(
        &self,
        session: &SessionId,
    ) -> Result<Vec<TranscriptDocumentSegment>, StoreError> {
        self.store.transcript_document(session)
    }

    pub fn speakers(&self, session: &SessionId) -> Result<Vec<SessionSpeaker>, StoreError> {
        self.store.session_speakers(session)
    }

    pub fn correct_segment(
        &mut self,
        session: &SessionId,
        revision_id: &str,
        sequence: u32,
        text: Option<&str>,
    ) -> Result<(), StoreError> {
        self.store
            .correct_transcript_segment(session, revision_id, sequence, text)
            .map(|_| ())
    }

    pub fn rename_speaker(
        &mut self,
        session: &SessionId,
        track_id: &str,
        label: Option<&str>,
    ) -> Result<(), StoreError> {
        self.store.rename_speaker(session, track_id, label)
    }

    pub fn search(
        &self,
        query: &str,
        session: Option<&SessionId>,
        limit: u32,
    ) -> Result<Vec<TranscriptSearchHit>, StoreError> {
        self.store.search_transcripts(query, session, limit)
    }

    pub fn export(
        &self,
        session: &SessionId,
        format: TranscriptExportFormat,
        destination: &Path,
    ) -> Result<TranscriptExportReceipt, TranscriptExportError> {
        write_transcript_export(&self.store, session, format, destination)
    }

    pub fn begin_deletion(
        &mut self,
        session: &SessionId,
    ) -> Result<SessionDeletionInventory, StoreError> {
        self.store.begin_session_deletion(session)
    }

    pub fn abandon_deletion(&mut self, session: &SessionId) -> Result<(), StoreError> {
        self.store.abandon_session_deletion(session)
    }

    pub fn complete_deletion(
        &mut self,
        session: &SessionId,
        trash_reference: Option<&str>,
    ) -> Result<SessionDeletionReceipt, StoreError> {
        self.store
            .complete_session_deletion(session, trash_reference)
    }
}
