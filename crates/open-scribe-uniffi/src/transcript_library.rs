//! Coarse transcript review, search, export, and deletion calls for the macOS
//! transcript and library surfaces. Each call returns a complete value; no
//! per-token or per-frame callback crosses the boundary.

use super::*;
use open_scribe_core::{
    SpeakerLabelOrigin, TranscriptAvailability, TranscriptExportError, TranscriptExportFormat,
    TranscriptLibrary,
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
}

#[derive(Clone, Debug, Eq, PartialEq, uniffi::Record)]
pub struct NativeSessionSpeaker {
    pub track_id: String,
    pub source_kind: String,
    pub label: String,
    pub named_by_user: bool,
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
    pub export_files: u32,
    pub export_bytes: u64,
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
    fn library(&self) -> Result<std::sync::MutexGuard<'_, TranscriptLibrary>, NativeStorageError> {
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
