//! Coarse transcript review, search, export, and deletion calls for the macOS
//! transcript and library surfaces. Each call returns a complete value; no
//! per-token or per-frame callback crosses the boundary.

use super::*;
use open_scribe_core::{
    NamedSpeakerTurn, SpeakerLabelOrigin, TranscriptAvailability, TranscriptExportError,
    TranscriptExportFormat, TranscriptLibrary,
};
use open_scribe_types::SessionId;
use std::path::Path;

#[derive(Clone, Copy, Debug, Eq, PartialEq, uniffi::Enum)]
pub enum NativeTranscriptAvailability {
    Final,
    Draft,
    Failed,
    Unavailable,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq, uniffi::Enum)]
pub enum NativeTranscriptExportFormat {
    PlainText,
    Markdown,
    WebVtt,
    SubRip,
    TranscriptJson,
}

#[derive(Clone, Debug, Eq, PartialEq, uniffi::Record)]
pub struct NativeTranscriptProvenanceRange {
    pub start_nanoseconds: i64,
    pub end_nanoseconds: i64,
}

/// Stored identity of one readable model revision. Repeating the model is not
/// claimed to produce the same words.
#[derive(Clone, Debug, Eq, PartialEq, uniffi::Record)]
pub struct NativeTranscriptProvenance {
    pub revision_id: String,
    pub track_id: String,
    pub engine: String,
    pub engine_version: String,
    pub model_id: String,
    pub model_sha256: String,
    pub input_digest: String,
    pub run_state: String,
    pub finality: String,
    pub ranges: Vec<NativeTranscriptProvenanceRange>,
}

#[derive(Clone, Debug, Eq, PartialEq, uniffi::Record)]
pub struct NativeTranscriptSegment {
    pub revision_id: String,
    pub track_id: String,
    pub sequence: u32,
    pub start_nanoseconds: i64,
    pub end_nanoseconds: i64,
    pub verbatim_text: String,
    pub effective_text: String,
    pub corrected: bool,
    pub speaker_label: String,
    pub speaker_named_by_user: bool,
    pub named_speaker_id: Option<String>,
    /// `final` for a selected revision, `draft` for provisional text.
    pub finality: String,
}

#[derive(Clone, Debug, Eq, PartialEq, uniffi::Record)]
pub struct NativeNamedTranscriptSpeaker {
    pub id: String,
    pub label: String,
    pub selected_turns: u32,
}

#[derive(Clone, Debug, Eq, PartialEq, uniffi::Record)]
pub struct NativeConversationReviewMetadata {
    pub added_at_ms: i64,
    pub origin: String,
    pub stored_media_bytes: u64,
    pub source_names: Vec<String>,
}

#[derive(Clone, Debug, Eq, PartialEq, uniffi::Enum)]
pub enum NativeTranscriptSpeakerAssignment {
    Existing { speaker_id: String },
    New { label: String },
    Source,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq, uniffi::Enum)]
pub enum NativeSpeakerLabelOrigin {
    SourceDefault,
    Human,
}

#[derive(Clone, Debug, Eq, PartialEq, uniffi::Record)]
pub struct NativeSpeakerLabelRevision {
    pub label: String,
    pub origin: NativeSpeakerLabelOrigin,
    pub created_at_ms: i64,
}

/// `source_default_label` is derived from the source kind. `revisions` holds
/// only stored renames, oldest first. An empty list means no rename is stored.
#[derive(Clone, Debug, Eq, PartialEq, uniffi::Record)]
pub struct NativeSpeakerLabelHistory {
    pub track_id: String,
    pub source_kind: String,
    pub source_default_label: String,
    pub revisions: Vec<NativeSpeakerLabelRevision>,
}

/// One selected passage a person can merge or split.
#[derive(Clone, Debug, Eq, PartialEq, uniffi::Record)]
pub struct NativeNamedSpeakerTurn {
    pub revision_id: String,
    pub sequence: u32,
}

/// One stored assignment. A null speaker is the source name.
#[derive(Clone, Debug, Eq, PartialEq, uniffi::Record)]
pub struct NativeNamedSpeakerTurnRevision {
    pub label: String,
    pub origin: NativeSpeakerLabelOrigin,
    pub speaker_id: Option<String>,
    pub created_at_ms: i64,
}

/// Source name plus every stored assignment for one selected passage,
/// oldest first. A passage nobody has named has an empty `revisions` list.
#[derive(Clone, Debug, Eq, PartialEq, uniffi::Record)]
pub struct NativeNamedSpeakerTurnHistory {
    pub revision_id: String,
    pub sequence: u32,
    pub track_id: String,
    pub source_default_label: String,
    pub revisions: Vec<NativeNamedSpeakerTurnRevision>,
}

#[derive(Clone, Debug, Eq, PartialEq, uniffi::Record)]
pub struct NativeSessionSpeaker {
    pub track_id: String,
    pub source_kind: String,
    pub label: String,
    pub named_by_user: bool,
}

#[derive(Clone, Debug, Eq, PartialEq, uniffi::Record)]
pub struct NativeSpeakerDiarizationTrack {
    pub track_id: String,
    pub source_kind: String,
    pub disposition: String,
    pub label: String,
    pub label_origin: String,
}

/// Voice clustering is `unavailable` until a calibrated model exists.
/// `topology` keeps a known audio source; `unresolved` keeps an unknown one.
#[derive(Clone, Debug, Eq, PartialEq, uniffi::Record)]
pub struct NativeSpeakerDiarization {
    pub run_id: String,
    pub algorithm_id: String,
    pub clustering_state: String,
    pub reason: String,
    pub inserted: bool,
    pub tracks: Vec<NativeSpeakerDiarizationTrack>,
}

#[derive(Clone, Debug, Eq, PartialEq, uniffi::Record)]
pub struct NativeTranscriptSearchHit {
    pub session_id: String,
    pub session_title: String,
    pub revision_id: String,
    pub track_id: String,
    pub sequence: u32,
    pub start_nanoseconds: i64,
    pub end_nanoseconds: i64,
    pub effective_text: String,
}

#[derive(Clone, Debug, Eq, PartialEq, uniffi::Record)]
pub struct NativeTranscriptExportReceipt {
    pub availability: NativeTranscriptAvailability,
    pub byte_length: u64,
    pub segment_count: u32,
}

#[derive(Clone, Debug, Eq, PartialEq, uniffi::Record)]
pub struct NativeSessionDeletionInventory {
    pub session_id: String,
    pub title: String,
    pub directory_path: String,
    pub media_files: u32,
    pub media_bytes: u64,
    pub transcript_revisions: u32,
    pub human_corrections: u32,
    pub speaker_names: u32,
    pub markers: u32,
    pub context_events: u32,
    pub export_files: u32,
    pub export_bytes: u64,
}

/// One Final transcript rebuilt from retained chunks without a model.
#[derive(Clone, Debug, Eq, PartialEq, uniffi::Record)]
pub struct NativeRetainedTranscriptRecovery {
    pub session_id: String,
    pub track_id: String,
    pub run_id: String,
    pub revision_id: String,
    pub reused_chunks: u32,
    pub segment_count: u32,
}

#[derive(Clone, Debug, Eq, PartialEq, uniffi::Record)]
pub struct NativeSessionDeletionReceipt {
    pub receipt_id: String,
    pub wal_checkpointed: bool,
}

#[derive(uniffi::Object)]
pub struct NativeTranscriptLibrary {
    library: Mutex<TranscriptLibrary>,
}

#[uniffi::export]
impl NativeTranscriptLibrary {
    #[uniffi::constructor]
    pub fn open(managed_root: String) -> Result<Arc<Self>, NativeStorageError> {
        let library = TranscriptLibrary::open(managed_root).map_err(map_storage_error)?;
        Ok(Arc::new(Self {
            library: Mutex::new(library),
        }))
    }

    pub fn availability(
        &self,
        session_id: String,
    ) -> Result<NativeTranscriptAvailability, NativeStorageError> {
        self.library()?
            .availability(&SessionId(session_id))
            .map(map_availability)
            .map_err(map_export_error)
    }

    pub fn document(
        &self,
        session_id: String,
    ) -> Result<Vec<NativeTranscriptSegment>, NativeStorageError> {
        let segments = self
            .library()?
            .document(&SessionId(session_id))
            .map_err(map_storage_error)?;
        Ok(segments
            .into_iter()
            .map(|segment| NativeTranscriptSegment {
                revision_id: segment.revision_id,
                track_id: segment.track_id,
                sequence: segment.sequence,
                start_nanoseconds: segment.start_nanoseconds,
                end_nanoseconds: segment.end_nanoseconds,
                verbatim_text: segment.verbatim_text,
                effective_text: segment.effective_text,
                corrected: segment.corrected,
                speaker_label: segment.speaker_label,
                speaker_named_by_user: segment.speaker_origin == SpeakerLabelOrigin::Human,
                named_speaker_id: segment.named_speaker_id,
                finality: segment.finality,
            })
            .collect())
    }

    /// Readable revisions only. The result names the stored engine, model
    /// revision, input digest, run state, and evidence ranges.
    pub fn inspect_provenance(
        &self,
        session_id: String,
    ) -> Result<Vec<NativeTranscriptProvenance>, NativeStorageError> {
        let provenance = self
            .library()?
            .provenance(&SessionId(session_id))
            .map_err(map_storage_error)?;
        Ok(provenance
            .into_iter()
            .map(|item| NativeTranscriptProvenance {
                revision_id: item.revision_id,
                track_id: item.track_id,
                engine: item.engine,
                engine_version: item.engine_version,
                model_id: item.model_id,
                model_sha256: item.model_sha256,
                input_digest: item.input_digest,
                run_state: item.run_state,
                finality: item.finality,
                ranges: item
                    .ranges
                    .into_iter()
                    .map(|range| NativeTranscriptProvenanceRange {
                        start_nanoseconds: range.start_nanoseconds,
                        end_nanoseconds: range.end_nanoseconds,
                    })
                    .collect(),
            })
            .collect())
    }

    pub fn speakers(
        &self,
        session_id: String,
    ) -> Result<Vec<NativeSessionSpeaker>, NativeStorageError> {
        let speakers = self
            .library()?
            .speakers(&SessionId(session_id))
            .map_err(map_storage_error)?;
        Ok(speakers
            .into_iter()
            .map(|speaker| NativeSessionSpeaker {
                track_id: speaker.track_id,
                source_kind: speaker.source_kind,
                label: speaker.label,
                named_by_user: speaker.origin == SpeakerLabelOrigin::Human,
            })
            .collect())
    }

    /// Oldest-first speaker names for each source track. The source default
    /// is always named. A stored empty label is that source name. A track
    /// with no stored rename has an empty revision list.
    pub fn speaker_label_history(
        &self,
        session_id: String,
    ) -> Result<Vec<NativeSpeakerLabelHistory>, NativeStorageError> {
        let histories = self
            .library()?
            .speaker_label_history(&SessionId(session_id))
            .map_err(map_storage_error)?;
        Ok(histories
            .into_iter()
            .map(|history| NativeSpeakerLabelHistory {
                track_id: history.track_id,
                source_kind: history.source_kind,
                source_default_label: history.source_default_label,
                revisions: history
                    .revisions
                    .into_iter()
                    .map(|revision| NativeSpeakerLabelRevision {
                        label: revision.label,
                        origin: match revision.origin {
                            SpeakerLabelOrigin::SourceDefault => {
                                NativeSpeakerLabelOrigin::SourceDefault
                            }
                            SpeakerLabelOrigin::Human => NativeSpeakerLabelOrigin::Human,
                        },
                        created_at_ms: revision.created_at_ms,
                    })
                    .collect(),
            })
            .collect())
    }

    /// Records that known audio sources keep their topology and that voice
    /// clustering is unavailable. A repeated identical decision does not
    /// insert another run. Speaker names, transcript text, and media stay
    /// as they were.
    pub fn prepare_speaker_diarization(
        &self,
        session_id: String,
    ) -> Result<NativeSpeakerDiarization, NativeStorageError> {
        let decision = self
            .library()?
            .prepare_speaker_diarization(&SessionId(session_id))
            .map_err(map_storage_error)?;
        Ok(NativeSpeakerDiarization {
            run_id: decision.run_id,
            algorithm_id: decision.algorithm_id,
            clustering_state: decision.clustering_state,
            reason: decision.reason,
            inserted: decision.inserted,
            tracks: decision
                .tracks
                .into_iter()
                .map(|track| NativeSpeakerDiarizationTrack {
                    track_id: track.track_id,
                    source_kind: track.source_kind,
                    disposition: track.disposition,
                    label: track.label,
                    label_origin: track.label_origin,
                })
                .collect(),
        })
    }

    /// `None` restores the verbatim reading.
    pub fn correct_segment(
        &self,
        session_id: String,
        revision_id: String,
        sequence: u32,
        text: Option<String>,
    ) -> Result<(), NativeStorageError> {
        self.library()?
            .correct_segment(
                &SessionId(session_id),
                &revision_id,
                sequence,
                text.as_deref(),
            )
            .map_err(map_storage_error)
    }

    /// `None` restores the source-derived speaker name.
    pub fn rename_speaker(
        &self,
        session_id: String,
        track_id: String,
        label: Option<String>,
    ) -> Result<(), NativeStorageError> {
        self.library()?
            .rename_speaker(&SessionId(session_id), &track_id, label.as_deref())
            .map_err(map_storage_error)
    }

    pub fn review_metadata(
        &self,
        session_id: String,
    ) -> Result<NativeConversationReviewMetadata, NativeStorageError> {
        self.library()?
            .review_metadata(&SessionId(session_id))
            .map(|metadata| NativeConversationReviewMetadata {
                added_at_ms: metadata.added_at_ms,
                origin: metadata.origin,
                stored_media_bytes: metadata.stored_media_bytes,
                source_names: metadata.source_names,
            })
            .map_err(map_storage_error)
    }

    pub fn named_speakers(
        &self,
        session_id: String,
    ) -> Result<Vec<NativeNamedTranscriptSpeaker>, NativeStorageError> {
        self.library()?
            .named_speakers(&SessionId(session_id))
            .map(|speakers| {
                speakers
                    .into_iter()
                    .map(|speaker| NativeNamedTranscriptSpeaker {
                        id: speaker.id,
                        label: speaker.label,
                        selected_turns: speaker.selected_turns,
                    })
                    .collect()
            })
            .map_err(map_storage_error)
    }

    pub fn assign_speaker(
        &self,
        session_id: String,
        revision_id: String,
        sequence: u32,
        assignment: NativeTranscriptSpeakerAssignment,
    ) -> Result<Option<String>, NativeStorageError> {
        use open_scribe_core::TranscriptSpeakerAssignment;
        let assignment = match assignment {
            NativeTranscriptSpeakerAssignment::Existing { speaker_id } => {
                TranscriptSpeakerAssignment::Existing(speaker_id)
            }
            NativeTranscriptSpeakerAssignment::New { label } => {
                TranscriptSpeakerAssignment::New(label)
            }
            NativeTranscriptSpeakerAssignment::Source => TranscriptSpeakerAssignment::Source,
        };
        self.library()?
            .assign_speaker(&SessionId(session_id), &revision_id, sequence, &assignment)
            .map_err(map_storage_error)
    }

    pub fn rename_named_speaker(
        &self,
        session_id: String,
        speaker_id: String,
        label: String,
    ) -> Result<(), NativeStorageError> {
        self.library()?
            .rename_named_speaker(&SessionId(session_id), &speaker_id, &label)
            .map_err(map_storage_error)
    }

    /// Moves every selected passage of `absorb_id` onto `keep_id`. Both
    /// people remain. A second identical call returns zero.
    pub fn merge_named_speakers(
        &self,
        session_id: String,
        keep_id: String,
        absorb_id: String,
    ) -> Result<u32, NativeStorageError> {
        self.library()?
            .merge_named_speakers(&SessionId(session_id), &keep_id, &absorb_id)
            .map_err(map_storage_error)
    }

    /// Moves the named passages to a new person and leaves at least one
    /// selected passage with the original person.
    pub fn split_named_speaker(
        &self,
        session_id: String,
        speaker_id: String,
        turns: Vec<NativeNamedSpeakerTurn>,
        label: String,
    ) -> Result<String, NativeStorageError> {
        let turns = turns
            .into_iter()
            .map(|turn| NamedSpeakerTurn {
                revision_id: turn.revision_id,
                sequence: turn.sequence,
            })
            .collect::<Vec<_>>();
        self.library()?
            .split_named_speaker(&SessionId(session_id), &speaker_id, &turns, &label)
            .map_err(map_storage_error)
    }

    /// Oldest-first assignments for each selected passage. The source name
    /// is always present. A later rename does not rewrite an earlier line.
    pub fn named_speaker_turn_history(
        &self,
        session_id: String,
    ) -> Result<Vec<NativeNamedSpeakerTurnHistory>, NativeStorageError> {
        let histories = self
            .library()?
            .named_speaker_turn_history(&SessionId(session_id))
            .map_err(map_storage_error)?;
        Ok(histories
            .into_iter()
            .map(|history| NativeNamedSpeakerTurnHistory {
                revision_id: history.revision_id,
                sequence: history.sequence,
                track_id: history.track_id,
                source_default_label: history.source_default_label,
                revisions: history
                    .revisions
                    .into_iter()
                    .map(|revision| NativeNamedSpeakerTurnRevision {
                        label: revision.label,
                        origin: match revision.origin {
                            SpeakerLabelOrigin::SourceDefault => {
                                NativeSpeakerLabelOrigin::SourceDefault
                            }
                            SpeakerLabelOrigin::Human => NativeSpeakerLabelOrigin::Human,
                        },
                        speaker_id: revision.speaker_id,
                        created_at_ms: revision.created_at_ms,
                    })
                    .collect(),
            })
            .collect())
    }

    /// Rebuilds Final transcripts from chunks earlier runs retained but could
    /// not commit, without loading a model. `session_id` limits the pass to
    /// one conversation. Media, failed runs, and selected revisions are
    /// untouched.
    pub fn recover_retained_transcripts(
        &self,
        session_id: Option<String>,
    ) -> Result<Vec<NativeRetainedTranscriptRecovery>, NativeStorageError> {
        let session = session_id.map(SessionId);
        self.library()?
            .recover_retained_transcripts(session.as_ref())
            .map(|recovered| {
                recovered
                    .into_iter()
                    .map(|outcome| NativeRetainedTranscriptRecovery {
                        session_id: outcome.session_id.0,
                        track_id: outcome.track_id,
                        run_id: outcome.run_id,
                        revision_id: outcome.revision_id,
                        reused_chunks: outcome.reused_chunks,
                        segment_count: outcome.segment_count,
                    })
                    .collect()
            })
            .map_err(map_storage_error)
    }

    pub fn search(
        &self,
        query: String,
        session_id: Option<String>,
        limit: u32,
    ) -> Result<Vec<NativeTranscriptSearchHit>, NativeStorageError> {
        let session = session_id.map(SessionId);
        let hits = self
            .library()?
            .search(&query, session.as_ref(), limit)
            .map_err(map_storage_error)?;
        Ok(hits
            .into_iter()
            .map(|hit| NativeTranscriptSearchHit {
                session_id: hit.session_id,
                session_title: hit.session_title,
                revision_id: hit.revision_id,
                track_id: hit.track_id,
                sequence: hit.sequence,
                start_nanoseconds: hit.start_nanoseconds,
                end_nanoseconds: hit.end_nanoseconds,
                effective_text: hit.effective_text,
            })
            .collect())
    }

    /// Writes atomically to a destination the user chose; the caller holds
    /// any security-scoped access for the duration of the call.
    pub fn export(
        &self,
        session_id: String,
        format: NativeTranscriptExportFormat,
        destination_path: String,
    ) -> Result<NativeTranscriptExportReceipt, NativeStorageError> {
        let receipt = self
            .library()?
            .export(
                &SessionId(session_id),
                map_export_format(format),
                Path::new(&destination_path),
            )
            .map_err(map_export_error)?;
        Ok(NativeTranscriptExportReceipt {
            availability: map_availability(receipt.availability),
            byte_length: receipt.byte_length,
            segment_count: receipt.segment_count,
        })
    }

    pub fn begin_deletion(
        &self,
        session_id: String,
    ) -> Result<NativeSessionDeletionInventory, NativeStorageError> {
        let inventory = self
            .library()?
            .begin_deletion(&SessionId(session_id))
            .map_err(map_storage_error)?;
        Ok(NativeSessionDeletionInventory {
            session_id: inventory.session_id.0,
            title: inventory.title,
            directory_path: inventory.directory.to_string_lossy().into_owned(),
            media_files: inventory.media_files,
            media_bytes: inventory.media_bytes,
            transcript_revisions: inventory.transcript_revisions,
            human_corrections: inventory.human_corrections,
            speaker_names: inventory.speaker_names,
            markers: inventory.markers,
            context_events: inventory.context_events,
            export_files: inventory.export_files,
            export_bytes: inventory.export_bytes,
        })
    }

    pub fn abandon_deletion(&self, session_id: String) -> Result<(), NativeStorageError> {
        self.library()?
            .abandon_deletion(&SessionId(session_id))
            .map_err(map_storage_error)
    }

    pub fn complete_deletion(
        &self,
        session_id: String,
        trash_reference: Option<String>,
    ) -> Result<NativeSessionDeletionReceipt, NativeStorageError> {
        let receipt = self
            .library()?
            .complete_deletion(&SessionId(session_id), trash_reference.as_deref())
            .map_err(map_storage_error)?;
        Ok(NativeSessionDeletionReceipt {
            receipt_id: receipt.receipt_id,
            wal_checkpointed: receipt.wal_checkpointed,
        })
    }

    pub fn audio_export_options(
        &self,
        session_id: String,
    ) -> Result<NativeAudioExportOptions, NativeStorageError> {
        let options = self
            .library()?
            .audio_export_options(&SessionId(session_id))
            .map_err(map_storage_error)?;
        Ok(NativeAudioExportOptions {
            has_validated_mix: options.has_validated_mix,
            original_extension: options.original_extension,
            pcm_tracks: options.pcm_tracks,
        })
    }

    pub fn export_session_manifest(
        &self,
        session_id: String,
        destination_path: String,
    ) -> Result<NativeFileExportReceipt, NativeStorageError> {
        self.library()?
            .export_session_manifest(&SessionId(session_id), Path::new(&destination_path))
            .map(map_file_receipt)
            .map_err(map_session_export_error)
    }

    pub fn export_validated_mix(
        &self,
        session_id: String,
        destination_path: String,
    ) -> Result<NativeFileExportReceipt, NativeStorageError> {
        self.library()?
            .export_validated_mix(&SessionId(session_id), Path::new(&destination_path))
            .map(map_file_receipt)
            .map_err(map_session_export_error)
    }

    pub fn export_original_media(
        &self,
        session_id: String,
        destination_path: String,
    ) -> Result<NativeFileExportReceipt, NativeStorageError> {
        self.library()?
            .export_original_media(&SessionId(session_id), Path::new(&destination_path))
            .map(map_file_receipt)
            .map_err(map_session_export_error)
    }

    pub fn export_track_wav(
        &self,
        session_id: String,
        track_id: String,
        destination_path: String,
    ) -> Result<NativeFileExportReceipt, NativeStorageError> {
        self.library()?
            .export_track_wav(
                &SessionId(session_id),
                &track_id,
                Path::new(&destination_path),
            )
            .map(map_file_receipt)
            .map_err(map_session_export_error)
    }

    pub fn export_portable_package(
        &self,
        session_id: String,
        destination_path: String,
    ) -> Result<NativePortableSummary, NativeStorageError> {
        self.library()?
            .export_portable_package(&SessionId(session_id), Path::new(&destination_path))
            .map(map_portable_summary)
            .map_err(map_session_export_error)
    }

    /// Opens a `.openscribe` package from another Mac as a new conversation.
    /// The package is verified in full before anything is copied.
    pub fn import_portable_package(
        &self,
        package_path: String,
    ) -> Result<NativePackageImportReceipt, NativeStorageError> {
        self.library()?
            .import_portable_package(Path::new(&package_path))
            .map(|receipt| NativePackageImportReceipt {
                session_id: receipt.session_id.0,
                source_session_id: receipt.source_session_id,
                title: receipt.title,
                media_files: receipt.media_files,
                transcript_tracks: receipt.transcript_tracks,
                markers: receipt.markers,
            })
            .map_err(map_session_export_error)
    }
}

#[derive(Clone, Debug, Eq, PartialEq, uniffi::Record)]
pub struct NativeAudioExportOptions {
    pub has_validated_mix: bool,
    pub original_extension: Option<String>,
    pub pcm_tracks: Vec<String>,
}

#[derive(Clone, Debug, Eq, PartialEq, uniffi::Record)]
pub struct NativeFileExportReceipt {
    pub byte_length: u64,
    pub sha256: String,
}

#[derive(Clone, Debug, Eq, PartialEq, uniffi::Record)]
pub struct NativePortableSummary {
    pub source_session_id: String,
    pub title: String,
    pub files: u32,
    pub byte_length: u64,
}

#[derive(Clone, Debug, Eq, PartialEq, uniffi::Record)]
pub struct NativePackageImportReceipt {
    pub session_id: String,
    pub source_session_id: String,
    pub title: String,
    pub media_files: u32,
    pub transcript_tracks: u32,
    pub markers: u32,
}

/// Checks an untrusted `.openscribe` package without opening a library.
#[uniffi::export]
pub fn verify_portable_package(
    package_path: String,
) -> Result<NativePortableSummary, NativeStorageError> {
    open_scribe_core::verify_portable_package(Path::new(&package_path))
        .map(map_portable_summary)
        .map_err(map_session_export_error)
}

fn map_file_receipt(receipt: open_scribe_core::FileExportReceipt) -> NativeFileExportReceipt {
    NativeFileExportReceipt {
        byte_length: receipt.byte_length,
        sha256: receipt.sha256,
    }
}

fn map_portable_summary(summary: open_scribe_core::PortableSummary) -> NativePortableSummary {
    NativePortableSummary {
        source_session_id: summary.source_session_id,
        title: summary.title,
        files: summary.files,
        byte_length: summary.byte_length,
    }
}

fn map_session_export_error(error: open_scribe_core::SessionExportError) -> NativeStorageError {
    use open_scribe_core::SessionExportError as Error;
    match error {
        Error::Store(error) => map_storage_error(error),
        Error::Transcript(error) => map_export_error(error),
        Error::Unavailable(_) => NativeStorageError::InvalidState,
        Error::InvalidDestination(_) => NativeStorageError::InvalidRequest,
        Error::InvalidPackage(_) => NativeStorageError::IntegrityMismatch,
        Error::Io(_) => NativeStorageError::StorageFailure,
    }
}

impl NativeTranscriptLibrary {
    pub(crate) fn library(
        &self,
    ) -> Result<std::sync::MutexGuard<'_, TranscriptLibrary>, NativeStorageError> {
        self.library
            .lock()
            .map_err(|_| NativeStorageError::InvalidState)
    }
}

fn map_availability(availability: TranscriptAvailability) -> NativeTranscriptAvailability {
    match availability {
        TranscriptAvailability::Final => NativeTranscriptAvailability::Final,
        TranscriptAvailability::Draft => NativeTranscriptAvailability::Draft,
        TranscriptAvailability::Failed => NativeTranscriptAvailability::Failed,
        TranscriptAvailability::Unavailable => NativeTranscriptAvailability::Unavailable,
    }
}

fn map_export_format(format: NativeTranscriptExportFormat) -> TranscriptExportFormat {
    match format {
        NativeTranscriptExportFormat::PlainText => TranscriptExportFormat::PlainText,
        NativeTranscriptExportFormat::Markdown => TranscriptExportFormat::Markdown,
        NativeTranscriptExportFormat::WebVtt => TranscriptExportFormat::WebVtt,
        NativeTranscriptExportFormat::SubRip => TranscriptExportFormat::SubRip,
        NativeTranscriptExportFormat::TranscriptJson => TranscriptExportFormat::TranscriptJson,
    }
}

fn map_export_error(error: TranscriptExportError) -> NativeStorageError {
    match error {
        TranscriptExportError::Store(error) => map_storage_error(error),
        TranscriptExportError::InvalidDestination(_) => NativeStorageError::InvalidRequest,
        TranscriptExportError::InvalidEvidence(_) => NativeStorageError::IntegrityMismatch,
        TranscriptExportError::Io(_) | TranscriptExportError::Json(_) => {
            NativeStorageError::StorageFailure
        }
    }
}
