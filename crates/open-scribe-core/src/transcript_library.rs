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
use crate::package_import::{PackageImportReceipt, import_portable_package};
use crate::session_export::{
    FileExportReceipt, PortableSummary, SessionExportError, export_source_media, export_track_wav,
    export_validated_mix, write_portable_package, write_session_manifest,
};
use open_scribe_evidence::EvidenceRef;
use open_scribe_store::{
    ContextDetail, ContextEventRecord, ConversationReviewMetadata, NamedTranscriptSpeaker,
    ResolvedEvidence, SessionDeletionInventory, SessionDeletionReceipt, SessionSpeaker,
    SessionStore, StoreError, TranscriptDocumentSegment, TranscriptSearchHit,
    TranscriptSpeakerAssignment,
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

    pub fn named_speakers(
        &self,
        session: &SessionId,
    ) -> Result<Vec<NamedTranscriptSpeaker>, StoreError> {
        self.store.named_transcript_speakers(session)
    }

    pub fn review_metadata(
        &self,
        session: &SessionId,
    ) -> Result<ConversationReviewMetadata, StoreError> {
        self.store.conversation_review_metadata(session)
    }

    pub fn assign_speaker(
        &mut self,
        session: &SessionId,
        revision_id: &str,
        sequence: u32,
        assignment: &TranscriptSpeakerAssignment,
    ) -> Result<Option<String>, StoreError> {
        self.store
            .assign_transcript_speaker(session, revision_id, sequence, assignment)
    }

    pub fn rename_named_speaker(
        &mut self,
        session: &SessionId,
        speaker_id: &str,
        label: &str,
    ) -> Result<(), StoreError> {
        self.store
            .rename_transcript_speaker(session, speaker_id, label)
    }

    /// The scope receipts, declared metadata, and accepted-event count, read-only.
    pub fn context_detail(&self, session: &SessionId) -> Result<ContextDetail, StoreError> {
        self.store.context_detail(session)
    }

    pub fn context_events(
        &self,
        session: &SessionId,
    ) -> Result<Vec<ContextEventRecord>, StoreError> {
        self.store.context_events(session)
    }

    /// Rust derives every citation; callers never choose its identity.
    pub fn cite_context_event(
        &self,
        session: &SessionId,
        event_id: &str,
        block: Option<usize>,
    ) -> Result<EvidenceRef, StoreError> {
        self.store.cite_context_event(session, event_id, block)
    }

    pub fn cite_transcript_segment(
        &self,
        session: &SessionId,
        revision_id: &str,
        sequence: u32,
    ) -> Result<EvidenceRef, StoreError> {
        self.store
            .cite_transcript_segment(session, revision_id, sequence)
    }

    pub fn resolve_evidence(
        &self,
        reference: &EvidenceRef,
    ) -> Result<ResolvedEvidence, StoreError> {
        self.store.resolve_evidence(reference)
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

    /// Rebuilds Final transcripts from chunks an earlier run retained but
    /// could not commit, for one session or the whole library. No model is
    /// loaded; media, failed runs, and selected revisions are untouched.
    pub fn recover_retained_transcripts(
        &mut self,
        session: Option<&SessionId>,
    ) -> Result<Vec<crate::RetainedTranscriptRecovery>, StoreError> {
        crate::recover_retained_transcripts(&mut self.store, session)
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
