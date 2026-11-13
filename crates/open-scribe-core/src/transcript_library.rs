//! Review, search, export, and deletion over the durable library: the coarse
//! native authority the macOS transcript and library surfaces call.
//!
//! It owns its own store connection beside the recording controller; SQLite
//! WAL and immediate transactions serialize their writes. Nothing here runs
//! speech inference: a transcript exists only when a local run has committed
//! one, and voice clustering stays unavailable until a calibrated model exists.

use crate::export::{
    TranscriptAvailability, TranscriptExportError, TranscriptExportFormat, TranscriptExportReceipt,
    write_transcript_export,
};
use crate::package_import::{PackageImportReceipt, import_portable_package};
use crate::session_export::{
    FileExportReceipt, PortableSummary, SessionExportError, export_source_media, export_track_wav,
    export_validated_mix, write_portable_package, write_session_manifest,
};
use open_scribe_evidence::AdjudicationAction;
use open_scribe_store::{
    ConversationDocument, DocumentScope, SessionDeletionReceipt, SessionLifecycle, SessionStore,
    StoreError, TranscriptSearchHit,
};
use open_scribe_types::SessionId;
use std::path::Path;

pub struct TranscriptLibrary {
    store: SessionStore,
}

impl TranscriptLibrary {
    /// The library store. The platform adapter calls its review, speaker,
    /// evidence and deletion methods directly; this type adds availability,
    /// search syntax, export and memory receipts.
    pub fn store(&self) -> &SessionStore {
        &self.store
    }

    pub fn store_mut(&mut self) -> &mut SessionStore {
        &mut self.store
    }

    pub fn open(managed_root: impl AsRef<Path>) -> Result<Self, StoreError> {
        Ok(Self {
            store: SessionStore::open(managed_root)?,
        })
    }

    pub fn availability(
        &self,
        session: &SessionId,
    ) -> Result<TranscriptAvailability, TranscriptExportError> {
        let context = match self.store.transcript_export_context(session) {
            Ok(context) => context,
            // A live draft is provisional before the session is saved. Export
            // stays refused; the reader still names the open text as Draft.
            Err(StoreError::InvalidState(_))
                if self.store.has_readable_draft(session)?
                    && self.store.session_lifecycle(&session.0)?
                        != SessionLifecycle::ReadyForReview =>
            {
                return Ok(TranscriptAvailability::Draft);
            }
            Err(error) => return Err(error.into()),
        };
        let mut availability = TranscriptAvailability::of(&context);
        if self.store.has_readable_draft(session)?
            && matches!(
                availability,
                TranscriptAvailability::Final | TranscriptAvailability::Unavailable
            )
        {
            availability = TranscriptAvailability::Draft;
        }
        Ok(availability)
    }

    /// The readable document: what the reader and Copy show.
    pub fn document(&self, session: &SessionId) -> Result<ConversationDocument, StoreError> {
        self.store
            .conversation_document(session, DocumentScope::Readable)
    }

    /// Confirms, corrects, or rejects the effective claim. Rust chooses the new
    /// ids. The returned revision id is the one review should show.
    pub fn adjudicate_derived_claim(
        &mut self,
        session: &SessionId,
        claim_id: &str,
        action: AdjudicationAction,
        text: Option<&str>,
    ) -> Result<String, StoreError> {
        self.store
            .adjudicate_derived_claim(session, claim_id, action, text)
            .map(|claim| claim.revision_id)
    }

    /// Stores the proposal, then appends only the operations Rust accepts.
    /// Human adjudication is not replaced. The returned receipt is canonical JSON.
    pub fn ingest_meeting_memory_delta(&mut self, json: &str) -> Result<String, StoreError> {
        let receipt = self.store.ingest_meeting_memory_delta(json)?;
        serde_json::to_string(&receipt).map_err(StoreError::Json)
    }

    /// Effective canonical claims for the review list. Unsupported drafts are omitted.
    pub fn effective_derived_claims(&self, session: &SessionId) -> Result<String, StoreError> {
        let summaries = self.store.effective_derived_claim_summaries(session)?;
        serde_json::to_string(&summaries).map_err(StoreError::Json)
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

    pub fn search(
        &self,
        query: &str,
        session: Option<&SessionId>,
        limit: u32,
    ) -> Result<Vec<TranscriptSearchHit>, StoreError> {
        if let Some(name) = query.trim().strip_prefix("speaker:") {
            return self
                .store
                .search_transcripts_by_speaker(name, session, limit);
        }
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

    /// The reading copy for the clipboard; see [`crate::ConversationText`].
    pub fn conversation_text(
        &self,
        session: &SessionId,
        timestamps: bool,
    ) -> Result<crate::ConversationText, StoreError> {
        crate::conversation_text(&self.store, session, timestamps)
    }

    pub fn complete_deletion(
        &mut self,
        session: &SessionId,
        trash_reference: Option<&str>,
    ) -> Result<SessionDeletionReceipt, StoreError> {
        self.store
            .complete_session_deletion(session, trash_reference)
    }

    /// Which audio exports a saved session can offer.
    pub fn audio_export_options(
        &self,
        session: &SessionId,
    ) -> Result<AudioExportOptions, StoreError> {
        let inventory = self.store.session_inventory(session)?;
        let mut pcm_tracks: Vec<String> = inventory
            .media
            .iter()
            .filter(|entry| entry.media_format == "caf-pcm-s16le")
            .map(|entry| entry.track_id.clone())
            .collect();
        pcm_tracks.dedup();
        let original_extension = (inventory.origin == "import"
            && self.store.retains_imported_original(session)?)
        .then(|| inventory.media.first())
        .flatten()
        .map(|entry| {
            if entry.media_format.starts_with("m4a") {
                "m4a"
            } else {
                "caf"
            }
            .to_owned()
        });
        Ok(AudioExportOptions {
            has_validated_mix: inventory.mixdown.is_some(),
            original_extension,
            pcm_tracks,
        })
    }

    pub fn export_session_manifest(
        &self,
        session: &SessionId,
        destination: &Path,
    ) -> Result<FileExportReceipt, SessionExportError> {
        write_session_manifest(&self.store, session, destination)
    }

    pub fn export_validated_mix(
        &self,
        session: &SessionId,
        destination: &Path,
    ) -> Result<FileExportReceipt, SessionExportError> {
        export_validated_mix(&self.store, session, destination)
    }

    pub fn export_original_media(
        &self,
        session: &SessionId,
        destination: &Path,
    ) -> Result<FileExportReceipt, SessionExportError> {
        export_source_media(&self.store, session, destination)
    }

    pub fn export_track_wav(
        &self,
        session: &SessionId,
        track_id: &str,
        destination: &Path,
    ) -> Result<FileExportReceipt, SessionExportError> {
        export_track_wav(&self.store, session, track_id, destination)
    }

    pub fn export_portable_package(
        &self,
        session: &SessionId,
        destination: &Path,
    ) -> Result<PortableSummary, SessionExportError> {
        write_portable_package(&self.store, session, destination)
    }

    /// Opens a portable package from another Mac as a new conversation.
    pub fn import_portable_package(
        &mut self,
        package: &Path,
    ) -> Result<PackageImportReceipt, SessionExportError> {
        import_portable_package(&mut self.store, package)
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct AudioExportOptions {
    pub has_validated_mix: bool,
    /// An imported session exports its one managed original, whose file
    /// extension this names (`m4a` or `caf`).
    pub original_extension: Option<String>,
    /// Tracks with sealed PCM that can export as timeline-aligned WAV.
    pub pcm_tracks: Vec<String>,
}
