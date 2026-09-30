//! Opening a portable package as a new conversation (ADR 0010 round trip).
//!
//! The package is untrusted. It is verified in full; its session manifest
//! and transcript are read again and bound to the manifest's digests; every
//! media entry must be a declared source file of the stated length and
//! digest. Only then does the store restore it, rehashing each file as it is
//! copied, under new local identities that keep the source session ID.

use crate::export::TRANSCRIPT_V1_SCHEMA_JSON;
use crate::session_export::{
    SESSION_MANIFEST_V1_SCHEMA_JSON, SessionExportError, normalized_relative, open_regular,
    schema_id, verify_package,
};
use open_scribe_store::{
    PackageRestoreRequest, RestoredMarker, RestoredSegment, RestoredTrack, RestoredTranscript,
    RestoredTranscriptSegment, SessionOrigin, SessionStore,
};
use open_scribe_types::SessionId;
use serde_json::Value;
use sha2::{Digest, Sha256};
use std::collections::BTreeMap;
use std::io::Read;
use std::path::Path;

/// Neither document may exceed this.
const MAX_DOCUMENT_BYTES: u64 = 64 << 20;
const PCM_MEDIA_FORMAT: &str = "caf-pcm-s16le";

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct PackageImportReceipt {
    pub session_id: SessionId,
    pub source_session_id: String,
    pub title: String,
    pub media_files: u32,
    pub transcript_tracks: u32,
    pub markers: u32,
}

/// One declared file: role, length, and digest.
type Declared = BTreeMap<String, (String, u64, String)>;

pub fn import_portable_package(
    store: &mut SessionStore,
    package: &Path,
) -> Result<PackageImportReceipt, SessionExportError> {
    let verified = verify_package(package)?;
    let mut declared = Declared::new();
    for file in verified.manifest["files"].as_array().into_iter().flatten() {
        declared.insert(
            text(file, "path")?.to_owned(),
            (
                text(file, "role")?.to_owned(),
                unsigned(file, "byte_length")?,
                text(file, "sha256")?.to_owned(),
            ),
        );
    }
    let session = read_document(package, &declared, "session.json", "session_manifest")?;
    let transcript = read_document(package, &declared, "transcript.json", "transcript")?;
    if session["schema"] != schema_id(SESSION_MANIFEST_V1_SCHEMA_JSON).as_str()
        || session["schema_version"] != 1
        || transcript["schema"] != schema_id(TRANSCRIPT_V1_SCHEMA_JSON).as_str()
        || transcript["schema_version"] != 1
    {
        return Err(invalid("unsupported session or transcript schema"));
    }
    let source_session_id = verified.summary.source_session_id.clone();
    if session["session"]["id"] != source_session_id.as_str()
        || transcript["session"]["id"] != source_session_id.as_str()
    {
        return Err(invalid("documents name different sessions"));
    }
    let origin = match session["session"]["origin"].as_str() {
        Some("capture") => SessionOrigin::Capture,
        Some("import") => SessionOrigin::Import,
        _ => return Err(invalid("session origin is not recognized")),
    };
    let mut tracks = Vec::new();
    for track in array(&session, "tracks")? {
        let track_id = text(track, "track_id")?;
        let mut segments = Vec::new();
        for segment in array(track, "segments")? {
            if text(segment, "media_format")? != PCM_MEDIA_FORMAT {
                return Err(SessionExportError::Unavailable(
                    "a package holding a compressed import cannot be opened yet",
                ));
            }
            let relative_path = format!("media/{}", text(segment, "relative_path")?);
            let byte_length = unsigned(segment, "byte_length")?;
            let digest_sha256 = text(segment, "sha256")?.to_owned();
            if declared.get(&relative_path)
                != Some(&(
                    "source_media".to_owned(),
                    byte_length,
                    digest_sha256.clone(),
                ))
            {
                return Err(invalid("a media file is not declared as listed"));
            }
            segments.push(RestoredSegment {
                source_segment_id: text(segment, "segment_id")?.to_owned(),
                sequence: unsigned(segment, "sequence")?,
                start_nanoseconds: signed(segment, "start_ns")?,
                sample_count: unsigned(segment, "sample_count")?,
                channels: u16::try_from(unsigned(segment, "channels")?)
                    .map_err(|_| invalid("a channel count is invalid"))?,
                byte_length,
                digest_sha256,
                path: package.join(normalized_relative(&relative_path)?),
            });
        }
        let speaker = &track["speaker"];
        tracks.push(RestoredTrack {
            source_track_id: track_id.to_owned(),
            source_id: text(track, "source_id")?.to_owned(),
            source_kind: text(track, "source_kind")?.to_owned(),
            human_speaker_label: match speaker["named_by_user"].as_bool() {
                Some(true) => Some(text(speaker, "label")?.to_owned()),
                Some(false) => None,
                None => return Err(invalid("a speaker is malformed")),
            },
            transcript: restored_transcript(&transcript, track_id)?,
            segments,
        });
    }
    let mut markers = Vec::new();
    for marker in array(&session, "markers")? {
        markers.push(RestoredMarker {
            at_nanoseconds: signed(marker, "at_ns")?,
            label: text(marker, "label")?.to_owned(),
        });
    }
    let title = text(&session["session"], "title")?.to_owned();
    let receipt = store.restore_portable_session(&PackageRestoreRequest {
        title: title.clone(),
        origin,
        source_session_id: source_session_id.clone(),
        source_created_at_ms: signed(&session["session"], "created_at_ms")?,
        package_sha256: verified.manifest_sha256,
        tracks,
        markers,
    })?;
    Ok(PackageImportReceipt {
        session_id: receipt.session_id,
        source_session_id,
        title,
        media_files: receipt.media_files,
        transcript_tracks: receipt.transcript_tracks,
        markers: receipt.markers,
    })
}

/// A track's selected Final revision, when the package has one. Pending and
/// failed tracks restore without text.
fn restored_transcript(
    transcript: &Value,
    track_id: &str,
) -> Result<Option<RestoredTranscript>, SessionExportError> {
    let Some(track) = array(transcript, "tracks")?
        .iter()
        .find(|track| track["track_id"] == track_id)
    else {
        return Ok(None);
    };
    let revision = &track["revision"];
    if track["finality"] != "final" || revision.is_null() {
        return Ok(None);
    }
    let input_digest = text(track, "input_digest")?;
    if text(revision, "input_digest")? != input_digest {
        return Err(invalid("a revision cites a different input than its track"));
    }
    let revision_id = text(revision, "revision_id")?;
    let mut segments: Vec<(u64, RestoredTranscriptSegment)> = Vec::new();
    for segment in array(transcript, "segments")? {
        if segment["revision_id"] != revision_id {
            continue;
        }
        if segment["track_id"] != track_id || segment["finality"] != "final" {
            return Err(invalid("a transcript segment names another track"));
        }
        segments.push((
            unsigned(segment, "sequence")?,
            RestoredTranscriptSegment {
                start_nanoseconds: signed(segment, "start_ns")?,
                end_nanoseconds: signed(segment, "end_ns")?,
                verbatim_text: text(segment, "verbatim_text")?.to_owned(),
                correction: if segment["correction"].is_null() {
                    None
                } else {
                    Some(text(segment, "effective_text")?.to_owned())
                },
            },
        ));
    }
    segments.sort_by_key(|(sequence, _)| *sequence);
    if segments
        .iter()
        .enumerate()
        .any(|(index, (sequence, _))| *sequence != index as u64)
    {
        return Err(invalid("transcript segments are not contiguous"));
    }
    Ok(Some(RestoredTranscript {
        source_revision_id: revision_id.to_owned(),
        source_run_id: text(revision, "run_id")?.to_owned(),
        input_digest: input_digest.to_owned(),
        engine: text(revision, "engine")?.to_owned(),
        engine_version: text(revision, "engine_version")?.to_owned(),
        model_id: text(revision, "model_id")?.to_owned(),
        model_sha256: text(revision, "model_sha256")?.to_owned(),
        language: match &revision["language"] {
            Value::Null => None,
            Value::String(language) => Some(language.clone()),
            _ => return Err(invalid("a transcript language is malformed")),
        },
        segments: segments.into_iter().map(|(_, segment)| segment).collect(),
    }))
}

/// Reads a declared document again and binds its bytes to the manifest.
fn read_document(
    package: &Path,
    declared: &Declared,
    path: &str,
    role: &str,
) -> Result<Value, SessionExportError> {
    let Some((declared_role, length, digest)) = declared.get(path) else {
        return Err(invalid("a required document is missing"));
    };
    if declared_role != role || *length > MAX_DOCUMENT_BYTES {
        return Err(invalid("a required document is not declared as expected"));
    }
    let mut bytes = Vec::new();
    open_regular(&package.join(path))?
        .take(MAX_DOCUMENT_BYTES)
        .read_to_end(&mut bytes)?;
    if bytes.len() as u64 != *length || hex(&Sha256::digest(&bytes)) != *digest {
        return Err(invalid("a document changed after verification"));
    }
    serde_json::from_slice(&bytes).map_err(|_| invalid("a document is not JSON"))
}

fn invalid(reason: &'static str) -> SessionExportError {
    SessionExportError::InvalidPackage(reason)
}

fn text<'a>(value: &'a Value, key: &str) -> Result<&'a str, SessionExportError> {
    value[key]
        .as_str()
        .ok_or(invalid("a document field is missing or malformed"))
}

fn unsigned(value: &Value, key: &str) -> Result<u64, SessionExportError> {
    value[key]
        .as_u64()
        .ok_or(invalid("a document field is missing or malformed"))
}

fn signed(value: &Value, key: &str) -> Result<i64, SessionExportError> {
    value[key]
        .as_i64()
        .ok_or(invalid("a document field is missing or malformed"))
}

fn array<'a>(value: &'a Value, key: &str) -> Result<&'a Vec<Value>, SessionExportError> {
    value[key]
        .as_array()
        .ok_or(invalid("a document list is missing or malformed"))
}

fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|byte| format!("{byte:02x}")).collect()
}
