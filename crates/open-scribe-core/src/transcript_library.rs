//! Review, search, export, and deletion over the durable library: the coarse
//! native authority the macOS transcript and library surfaces call.
//!
//! It owns its own store connection beside the recording controller; SQLite
//! WAL and immediate transactions serialize their writes. Nothing here runs
//! speech inference: a transcript exists only when a local run has committed
//! one, and voice clustering stays unavailable until a calibrated model exists.

use crate::export::{
    TranscriptAvailability, TranscriptExport, TranscriptExportError, TranscriptExportFormat,
    TranscriptExportReceipt, write_transcript_export,
};
use crate::package_import::{PackageImportReceipt, import_portable_package};
use crate::session_export::{
    FileExportReceipt, PortableSummary, SessionExportError, export_source_media, export_track_wav,
    export_validated_mix, write_portable_package, write_session_manifest,
};
use open_scribe_diarize::disposition_for_source_kind;
use open_scribe_evidence::{AdjudicationAction, DerivedClaim, EvidenceRef};
use open_scribe_store::{
    ClaimNavigation, ContextDetail, ContextEventRecord, ConversationReviewMetadata,
    NamedSpeakerTurn, NamedSpeakerTurnHistory, NamedTranscriptSpeaker, ResolvedEvidence,
    SessionDeletionInventory, SessionDeletionReceipt, SessionSpeaker, SessionStore,
    SpeakerDiarization, SpeakerDiarizationTrackInput, SpeakerLabelHistory, StoreError,
    TranscriptDocumentSegment, TranscriptProvenance, TranscriptSearchHit,
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
        let export = match TranscriptExport::collect(&self.store, session, 0) {
            Ok(export) => export,
            // A live draft is provisional before the session is saved. Export
            // stays refused; the reader still names the open text as Draft.
            Err(TranscriptExportError::Store(StoreError::InvalidState(
                "session is not saved for review",
            ))) if self.store.has_open_transcript_draft(session)? => {
                return Ok(TranscriptAvailability::Draft);
            }
            Err(error) => return Err(error),
        };
        let mut availability = export.availability();
        if self.store.has_open_transcript_draft(session)?
            && matches!(
                availability,
                TranscriptAvailability::Final | TranscriptAvailability::Unavailable
            )
        {
            availability = TranscriptAvailability::Draft;
        }
        Ok(availability)
    }

    pub fn document(
        &self,
        session: &SessionId,
    ) -> Result<Vec<TranscriptDocumentSegment>, StoreError> {
        self.store.readable_transcript(session)
    }

    /// The stored engine, model revision, input scope, run state, and evidence
    /// ranges for the readable transcript. This does not claim that repeating
    /// the model produces the same words.
    pub fn provenance(&self, session: &SessionId) -> Result<Vec<TranscriptProvenance>, StoreError> {
        self.store.transcript_provenance(session)
    }

    pub fn speakers(&self, session: &SessionId) -> Result<Vec<SessionSpeaker>, StoreError> {
        self.store.session_speakers(session)
    }

    /// Oldest-first speaker names for each source track, including the
    /// source-derived name and every stored rename.
    pub fn speaker_label_history(
        &self,
        session: &SessionId,
    ) -> Result<Vec<SpeakerLabelHistory>, StoreError> {
        self.store.speaker_label_history(session)
    }

    /// Records source topology for this review and leaves voice clustering
    /// unavailable. Microphone, application, and system tracks are not
    /// reclustered. Imported and other unknown tracks stay unresolved.
    /// Labels, transcript text, selections, and media bytes are unchanged.
    /// A repeated call with the same decision does not insert another run.
    pub fn prepare_speaker_diarization(
        &mut self,
        session: &SessionId,
    ) -> Result<SpeakerDiarization, StoreError> {
        let speakers = self.store.session_speakers(session)?;
        let decisions = speakers
            .iter()
            .map(|speaker| SpeakerDiarizationTrackInput {
                track_id: speaker.track_id.clone(),
                disposition: disposition_for_source_kind(&speaker.source_kind)
                    .disposition
                    .as_str()
                    .to_owned(),
            })
            .collect::<Vec<_>>();
        self.store.record_speaker_diarization(
            session,
            open_scribe_diarize::ALGORITHM_ID,
            open_scribe_diarize::CLUSTERING_UNAVAILABLE,
            open_scribe_diarize::UNAVAILABLE_REASON,
            &decisions,
        )
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

    /// Moves the absorbed person's selected turns onto the kept person.
    /// Both identities remain. A repeated call returns zero.
    pub fn merge_named_speakers(
        &mut self,
        session: &SessionId,
        keep_id: &str,
        absorb_id: &str,
    ) -> Result<u32, StoreError> {
        self.store.merge_named_speakers(session, keep_id, absorb_id)
    }

    /// Moves a strict subset of one person's selected turns to a new person.
    pub fn split_named_speaker(
        &mut self,
        session: &SessionId,
        speaker_id: &str,
        turns: &[NamedSpeakerTurn],
        label: &str,
    ) -> Result<String, StoreError> {
        self.store
            .split_named_speaker(session, speaker_id, turns, label)
    }

    /// Oldest-first assignments for each selected passage, plus the source name.
    pub fn named_speaker_turn_history(
        &self,
        session: &SessionId,
    ) -> Result<Vec<NamedSpeakerTurnHistory>, StoreError> {
        self.store.named_speaker_turn_history(session)
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

    /// Stores one validated claim revision. The library does not invent its evidence.
    pub fn insert_derived_claim(&mut self, claim: &DerivedClaim) -> Result<(), StoreError> {
        self.store.insert_derived_claim(claim)
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

    /// The effective claim and the evidence a review surface can open.
    pub fn navigate_derived_claim(
        &self,
        session: &SessionId,
        claim_id: &str,
    ) -> Result<ClaimNavigation, StoreError> {
        self.store.navigate_derived_claim(session, claim_id)
    }

    /// The revision a model delta must name. A session with no accepted delta is `"0"`.
    pub fn meeting_memory_revision(&self, session: &SessionId) -> Result<String, StoreError> {
        self.store.meeting_memory_revision(session)
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

    pub fn rename_speaker(
        &mut self,
        session: &SessionId,
        track_id: &str,
        label: Option<&str>,
    ) -> Result<(), StoreError> {
        self.store.rename_speaker(session, track_id, label)
    }

    /// The resolved conversation title and any stored suggestion.
    pub fn conversation_title(
        &self,
        session: &SessionId,
    ) -> Result<open_scribe_store::ConversationTitle, StoreError> {
        self.store.conversation_title(session)
    }

    /// Stores a transcript-derived title; false when a person named it.
    pub fn suggest_conversation_title(
        &mut self,
        session: &SessionId,
        title: &str,
        engine: &str,
        basis: &str,
    ) -> Result<bool, StoreError> {
        self.store
            .suggest_conversation_title(session, title, engine, basis)
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

    /// The reading copy for the clipboard; see [`crate::ConversationText`].
    pub fn conversation_text(
        &self,
        session: &SessionId,
        timestamps: bool,
    ) -> Result<crate::ConversationText, TranscriptExportError> {
        crate::conversation_text(&self.store, session, timestamps)
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
