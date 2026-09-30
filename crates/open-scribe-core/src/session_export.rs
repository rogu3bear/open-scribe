//! Session manifest v1, audio exports, and the portable package (ADR 0010).
//! Every media byte leaves through a lease whose full bytes were rehashed
//! against the sealed digest, and every file lands through a staged write
//! that is synchronized before it is renamed into place. Export never
//! changes session state.

use crate::export::{
    EXPORTER_NAME, EXPORTER_VERSION, TranscriptAvailability, TranscriptExport,
    TranscriptExportError, TranscriptExportFormat, now_milliseconds, rfc3339_utc,
    write_atomically_with,
};
use open_scribe_store::{
    SessionInventory, SessionStore, SpeakerLabelOrigin, StoreError, VerifiedMedia,
};
use open_scribe_types::SessionId;
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use std::collections::BTreeSet;
use std::fmt;
use std::fs::{self, File, OpenOptions};
use std::io::{self, Read, Write};
use std::os::unix::fs::{FileExt, OpenOptionsExt};
use std::path::{Component, Path, PathBuf};

pub const SESSION_MANIFEST_V1_SCHEMA_JSON: &str =
    include_str!("../../../docs/data-format/session-manifest.v1.schema.json");
pub const PORTABLE_V1_SCHEMA_JSON: &str =
    include_str!("../../../docs/data-format/portable.v1.schema.json");
const MEDIA_SAMPLE_RATE_HZ: u32 = 48_000;
/// A manifest larger than this is not read.
const MAX_MANIFEST_BYTES: u64 = 16 << 20;
/// No single package entry may exceed this.
const MAX_ENTRY_BYTES: u64 = 8 << 30;

#[derive(Debug)]
pub enum SessionExportError {
    Store(StoreError),
    Transcript(TranscriptExportError),
    Unavailable(&'static str),
    InvalidDestination(&'static str),
    /// A portable package failed a check; the reason is content-free.
    InvalidPackage(&'static str),
    Io(io::Error),
}

impl fmt::Display for SessionExportError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Store(error) => write!(f, "{error}"),
            Self::Transcript(error) => write!(f, "{error}"),
            Self::Unavailable(reason) => write!(f, "export unavailable: {reason}"),
            Self::InvalidDestination(reason) => write!(f, "invalid export destination: {reason}"),
            Self::InvalidPackage(reason) => write!(f, "invalid portable package: {reason}"),
            Self::Io(error) => write!(f, "export failed: {error}"),
        }
    }
}

impl std::error::Error for SessionExportError {}

impl From<StoreError> for SessionExportError {
    fn from(error: StoreError) -> Self {
        Self::Store(error)
    }
}

impl From<io::Error> for SessionExportError {
    fn from(error: io::Error) -> Self {
        Self::Io(error)
    }
}

impl From<TranscriptExportError> for SessionExportError {
    fn from(error: TranscriptExportError) -> Self {
        match error {
            TranscriptExportError::InvalidDestination(reason) => Self::InvalidDestination(reason),
            TranscriptExportError::Io(error) => Self::Io(error),
            other => Self::Transcript(other),
        }
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct FileExportReceipt {
    pub byte_length: u64,
    pub sha256: String,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct PortableSummary {
    pub source_session_id: String,
    pub title: String,
    pub files: u32,
    pub byte_length: u64,
}

pub(crate) fn schema_id(schema_json: &str) -> String {
    serde_json::from_str::<Value>(schema_json)
        .ok()
        .and_then(|schema| schema.get("$id")?.as_str().map(str::to_owned))
        .expect("checked schema declares its $id")
}

fn availability_label(availability: TranscriptAvailability) -> &'static str {
    match availability {
        TranscriptAvailability::Final => "final",
        TranscriptAvailability::Draft => "draft",
        TranscriptAvailability::Failed => "failed",
        TranscriptAvailability::Unavailable => "unavailable",
    }
}

/// The session manifest document for one saved session.
pub fn render_session_manifest(
    store: &SessionStore,
    session: &SessionId,
    exported_at_ms: i64,
) -> Result<Value, SessionExportError> {
    let inventory = store.session_inventory(session)?;
    let transcript = TranscriptExport::collect(store, session, exported_at_ms)?;
    Ok(manifest_document(&inventory, &transcript, exported_at_ms))
}

fn manifest_document(
    inventory: &SessionInventory,
    transcript: &TranscriptExport,
    exported_at_ms: i64,
) -> Value {
    let mut duration = 0_i64;
    let mut tracks: Vec<Value> = Vec::new();
    for entry in &inventory.media {
        let length = i64::try_from(
            u128::from(entry.sample_count) * 1_000_000_000 / u128::from(MEDIA_SAMPLE_RATE_HZ),
        )
        .unwrap_or(i64::MAX);
        duration = duration.max(entry.start_nanoseconds.saturating_add(length));
        let segment = json!({
            "segment_id": entry.segment_id,
            "sequence": entry.sequence,
            "relative_path": entry.relative_path,
            "media_format": entry.media_format,
            "start_ns": entry.start_nanoseconds.max(0),
            "sample_count": entry.sample_count,
            "channels": entry.channels,
            "byte_length": entry.byte_length,
            "sha256": entry.digest_sha256,
        });
        if let Some(track) = tracks
            .iter_mut()
            .find(|track| track["track_id"] == entry.track_id.as_str())
        {
            track["segments"]
                .as_array_mut()
                .expect("segments is an array")
                .push(segment);
            continue;
        }
        let speaker = transcript
            .speakers
            .iter()
            .find(|speaker| speaker.track_id == entry.track_id);
        tracks.push(json!({
            "track_id": entry.track_id,
            "source_id": entry.source_id,
            "source_kind": entry.source_kind,
            "speaker": {
                "label": speaker.map_or(entry.source_kind.as_str(), |speaker| speaker.label.as_str()),
                "named_by_user": speaker.is_some_and(|speaker| speaker.origin == SpeakerLabelOrigin::Human),
            },
            "segments": [segment],
        }));
    }
    let revisions: Vec<Value> = transcript
        .context
        .selected
        .iter()
        .map(|selected| {
            json!({
                "track_id": selected.track_id,
                "revision_id": selected.revision_id,
                "finality": "final",
            })
        })
        .collect();
    json!({
        "schema": schema_id(SESSION_MANIFEST_V1_SCHEMA_JSON),
        "schema_version": 1,
        "exporter": {"name": EXPORTER_NAME, "version": EXPORTER_VERSION},
        "session": {
            "id": inventory.session_id.0,
            "title": inventory.title,
            "origin": inventory.origin,
            "created_at_ms": inventory.created_at_ms,
            "lifecycle": inventory.lifecycle,
        },
        "exported_at": rfc3339_utc(exported_at_ms),
        "timeline_unit": "nanoseconds",
        "duration_ns": duration,
        "tracks": tracks,
        "markers": inventory.markers.iter().map(|marker| json!({
            "marker_id": marker.marker_id,
            "at_ns": marker.at_nanoseconds.max(0),
            "label": marker.label,
        })).collect::<Vec<_>>(),
        "transcript": {
            "availability": availability_label(transcript.availability()),
            "revisions": revisions,
        },
    })
}

pub fn write_session_manifest(
    store: &SessionStore,
    session: &SessionId,
    destination: &Path,
) -> Result<FileExportReceipt, SessionExportError> {
    let document = render_session_manifest(store, session, now_milliseconds())?;
    let bytes = serde_json::to_vec_pretty(&document).map_err(TranscriptExportError::Json)?;
    write_atomically_with(destination, |file| file.write_all(&bytes))?;
    Ok(FileExportReceipt {
        byte_length: bytes.len() as u64,
        sha256: hex(&Sha256::digest(&bytes)),
    })
}

/// Copies the validated AAC mix.
pub fn export_validated_mix(
    store: &SessionStore,
    session: &SessionId,
    destination: &Path,
) -> Result<FileExportReceipt, SessionExportError> {
    let unavailable = || SessionExportError::Unavailable("the session has no validated mix");
    if store.session_inventory(session)?.mixdown.is_none() {
        return Err(unavailable());
    }
    let media = store
        .open_verified_mixdown(session)?
        .ok_or_else(unavailable)?;
    copy_verified(&media, destination)
}

/// Copies an imported session's managed original (CAF or M4A).
pub fn export_source_media(
    store: &SessionStore,
    session: &SessionId,
    destination: &Path,
) -> Result<FileExportReceipt, SessionExportError> {
    let inventory = store.session_inventory(session)?;
    if inventory.origin != "import" {
        return Err(SessionExportError::Unavailable(
            "only an imported session has one original file",
        ));
    }
    let [entry] = inventory.media.as_slice() else {
        return Err(SessionExportError::Unavailable(
            "the import has no single original",
        ));
    };
    let media = store.open_verified_media(session, entry)?;
    copy_verified(&media, destination)
}

/// One PCM track as 48 kHz 16-bit WAV on the session timeline: silence fills
/// the time before and between its sealed segments, so the file lines up
/// with the session and with other exported tracks.
pub fn export_track_wav(
    store: &SessionStore,
    session: &SessionId,
    track_id: &str,
    destination: &Path,
) -> Result<FileExportReceipt, SessionExportError> {
    let input = store.transcription_input(session, track_id)?;
    if input.compressed {
        return Err(SessionExportError::Unavailable(
            "a compressed import has no PCM track; export the original instead",
        ));
    }
    let reader = store.open_transcription_input(&input)?;
    let channels = u64::from(input.channels);
    let frame_at = |nanoseconds: i64| {
        u64::try_from(
            i128::from(nanoseconds.max(0)) * i128::from(MEDIA_SAMPLE_RATE_HZ) / 1_000_000_000,
        )
        .unwrap_or(u64::MAX)
    };
    let total_frames = input
        .spans
        .iter()
        .map(|span| frame_at(span.start_nanoseconds) + span.frames)
        .max()
        .unwrap_or(0);
    let data_bytes = total_frames
        .checked_mul(channels * 2)
        .filter(|bytes| *bytes <= u64::from(u32::MAX) - 36)
        .ok_or(SessionExportError::Unavailable(
            "the track is too long for one WAV file",
        ))?;
    let mut hasher = Sha256::new();
    write_atomically_with(destination, |file| {
        let mut out = HashingWriter {
            inner: file,
            hasher: &mut hasher,
        };
        out.write_all(&wav_header(input.channels, data_bytes as u32))?;
        let mut written = 0_u64;
        let silence = vec![0_u8; 1 << 16];
        let pad = |out: &mut HashingWriter<'_>, frames: u64| -> io::Result<()> {
            let mut remaining = frames * channels * 2;
            while remaining > 0 {
                let chunk = remaining.min(silence.len() as u64) as usize;
                out.write_all(&silence[..chunk])?;
                remaining -= chunk as u64;
            }
            Ok(())
        };
        for (index, span) in input.spans.iter().enumerate() {
            let start = frame_at(span.start_nanoseconds).max(written);
            pad(&mut out, start - written)?;
            let mut frame = 0_u64;
            while frame < span.frames {
                let end = (frame + 48_000).min(span.frames);
                let samples = reader
                    .read_frames(index, frame, end)
                    .map_err(|error| io::Error::other(error.to_string()))?;
                let bytes: Vec<u8> = samples
                    .iter()
                    .flat_map(|sample| sample.to_le_bytes())
                    .collect();
                out.write_all(&bytes)?;
                frame = end;
            }
            written = start + span.frames;
        }
        pad(&mut out, total_frames.saturating_sub(written))
    })?;
    Ok(FileExportReceipt {
        byte_length: 44 + data_bytes,
        sha256: hex(&hasher.finalize()),
    })
}

fn wav_header(channels: u16, data_bytes: u32) -> [u8; 44] {
    let mut header = [0_u8; 44];
    let block_align = channels * 2;
    let byte_rate = MEDIA_SAMPLE_RATE_HZ * u32::from(block_align);
    header[0..4].copy_from_slice(b"RIFF");
    header[4..8].copy_from_slice(&(36 + data_bytes).to_le_bytes());
    header[8..16].copy_from_slice(b"WAVEfmt ");
    header[16..20].copy_from_slice(&16_u32.to_le_bytes());
    header[20..22].copy_from_slice(&1_u16.to_le_bytes());
    header[22..24].copy_from_slice(&channels.to_le_bytes());
    header[24..28].copy_from_slice(&MEDIA_SAMPLE_RATE_HZ.to_le_bytes());
    header[28..32].copy_from_slice(&byte_rate.to_le_bytes());
    header[32..34].copy_from_slice(&block_align.to_le_bytes());
    header[34..36].copy_from_slice(&16_u16.to_le_bytes());
    header[36..40].copy_from_slice(b"data");
    header[40..44].copy_from_slice(&data_bytes.to_le_bytes());
    header
}

struct HashingWriter<'a> {
    inner: &'a mut File,
    hasher: &'a mut Sha256,
}

impl Write for HashingWriter<'_> {
    fn write(&mut self, bytes: &[u8]) -> io::Result<usize> {
        let written = self.inner.write(bytes)?;
        self.hasher.update(&bytes[..written]);
        Ok(written)
    }

    fn flush(&mut self) -> io::Result<()> {
        self.inner.flush()
    }
}

/// Streams verified bytes to a staged destination, rehashing as it copies.
fn copy_verified(
    media: &VerifiedMedia,
    destination: &Path,
) -> Result<FileExportReceipt, SessionExportError> {
    let mut hasher = Sha256::new();
    write_atomically_with(destination, |file| copy_hashing(media, file, &mut hasher))?;
    let digest = hex(&hasher.finalize());
    if digest != media.digest_sha256 {
        let _ = fs::remove_file(destination);
        return Err(SessionExportError::Store(StoreError::IntegrityMismatch(
            "media changed while it was exported",
        )));
    }
    Ok(FileExportReceipt {
        byte_length: media.byte_length,
        sha256: digest,
    })
}

fn copy_hashing(media: &VerifiedMedia, out: &mut File, hasher: &mut Sha256) -> io::Result<()> {
    let mut buffer = vec![0_u8; 1 << 20];
    let mut offset = 0_u64;
    while offset < media.byte_length {
        let read = media.file.read_at(&mut buffer, offset)?;
        if read == 0 {
            return Err(io::Error::new(
                io::ErrorKind::UnexpectedEof,
                "media ended early",
            ));
        }
        hasher.update(&buffer[..read]);
        out.write_all(&buffer[..read])?;
        offset += read as u64;
    }
    Ok(())
}

/// Writes `<name>.openscribe`: the session manifest, transcript JSON, every
/// sealed source file, the validated mix when present, and `manifest.json`
/// listing each file's role, length, and SHA-256. The package is built in a
/// hidden sibling, verified, then renamed into place; an existing package at
/// the destination is replaced only after the new one verifies.
pub fn write_portable_package(
    store: &SessionStore,
    session: &SessionId,
    destination: &Path,
) -> Result<PortableSummary, SessionExportError> {
    let name = destination
        .file_name()
        .and_then(|name| name.to_str())
        .filter(|name| !name.starts_with('.') && name.ends_with(".openscribe"))
        .ok_or(SessionExportError::InvalidDestination(
            "a portable package needs a visible name ending in .openscribe",
        ))?;
    let parent = destination
        .parent()
        .filter(|parent| parent.is_dir())
        .ok_or(SessionExportError::InvalidDestination(
            "destination directory does not exist",
        ))?;
    let exported_at_ms = now_milliseconds();
    let inventory = store.session_inventory(session)?;
    let transcript = TranscriptExport::collect(store, session, exported_at_ms)?;
    let staging = parent.join(format!(
        ".{name}.partial-{}-{exported_at_ms}",
        std::process::id()
    ));
    fs::create_dir(&staging)?;
    let result = (|| {
        let mut files = Vec::new();
        let session_manifest =
            serde_json::to_vec_pretty(&manifest_document(&inventory, &transcript, exported_at_ms))
                .map_err(TranscriptExportError::Json)?;
        files.push(write_package_file(
            &staging,
            "session.json",
            "session_manifest",
            "application/json",
            &session_manifest,
        )?);
        let transcript_json = transcript.render(TranscriptExportFormat::TranscriptJson)?;
        files.push(write_package_file(
            &staging,
            "transcript.json",
            "transcript",
            "application/json",
            transcript_json.as_bytes(),
        )?);
        for entry in &inventory.media {
            let media = store.open_verified_media(session, entry)?;
            let path = format!("media/{}", entry.relative_path);
            files.push(copy_package_media(
                &staging,
                &path,
                "source_media",
                media_type(&entry.media_format),
                &media,
            )?);
        }
        let mix = match &inventory.mixdown {
            Some((relative_path, ..)) => store
                .open_verified_mixdown(session)?
                .map(|media| (relative_path, media)),
            None => None,
        };
        if let Some((relative_path, media)) = mix {
            let path = format!("media/{relative_path}");
            files.push(copy_package_media(
                &staging,
                &path,
                "derived_media",
                "audio/mp4",
                &media,
            )?);
        }
        let manifest = json!({
            "schema": schema_id(PORTABLE_V1_SCHEMA_JSON),
            "schema_version": 1,
            "exporter": {"name": EXPORTER_NAME, "version": EXPORTER_VERSION},
            "exported_at": rfc3339_utc(exported_at_ms),
            "source_session_id": inventory.session_id.0,
            "title": inventory.title,
            "files": files,
        });
        let bytes = serde_json::to_vec_pretty(&manifest).map_err(TranscriptExportError::Json)?;
        let mut file = OpenOptions::new()
            .write(true)
            .create_new(true)
            .open(staging.join("manifest.json"))?;
        file.write_all(&bytes)?;
        file.sync_all()?;
        sync_tree(&staging)?;
        let summary = verify_portable_package(&staging)?;
        replace_directory(&staging, destination, parent)?;
        Ok(summary)
    })();
    if result.is_err() {
        let _ = fs::remove_dir_all(&staging);
    }
    result
}

fn media_type(media_format: &str) -> &'static str {
    if media_format.starts_with("m4a") {
        "audio/mp4"
    } else {
        "audio/x-caf"
    }
}

fn package_path(staging: &Path, path: &str) -> Result<PathBuf, SessionExportError> {
    let relative = normalized_relative(path)?;
    let target = staging.join(&relative);
    if let Some(directory) = target.parent() {
        fs::create_dir_all(directory)?;
    }
    Ok(target)
}

fn write_package_file(
    staging: &Path,
    path: &str,
    role: &str,
    media_type: &str,
    bytes: &[u8],
) -> Result<Value, SessionExportError> {
    let mut file = OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(package_path(staging, path)?)?;
    file.write_all(bytes)?;
    file.sync_all()?;
    Ok(json!({
        "path": path,
        "role": role,
        "media_type": media_type,
        "byte_length": bytes.len(),
        "sha256": hex(&Sha256::digest(bytes)),
    }))
}

fn copy_package_media(
    staging: &Path,
    path: &str,
    role: &str,
    media_type: &str,
    media: &VerifiedMedia,
) -> Result<Value, SessionExportError> {
    let mut file = OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(package_path(staging, path)?)?;
    let mut hasher = Sha256::new();
    copy_hashing(media, &mut file, &mut hasher)?;
    file.sync_all()?;
    let digest = hex(&hasher.finalize());
    if digest != media.digest_sha256 {
        return Err(SessionExportError::Store(StoreError::IntegrityMismatch(
            "media changed while it was packaged",
        )));
    }
    Ok(json!({
        "path": path,
        "role": role,
        "media_type": media_type,
        "byte_length": media.byte_length,
        "sha256": digest,
    }))
}

fn sync_tree(directory: &Path) -> io::Result<()> {
    for entry in fs::read_dir(directory)? {
        let entry = entry?;
        if entry.file_type()?.is_dir() {
            sync_tree(&entry.path())?;
        }
    }
    File::open(directory)?.sync_all()
}

fn replace_directory(staging: &Path, destination: &Path, parent: &Path) -> io::Result<()> {
    if fs::symlink_metadata(destination).is_ok() {
        let retired = parent.join(format!(
            ".{}.replaced-{}",
            destination
                .file_name()
                .and_then(|name| name.to_str())
                .unwrap_or("package"),
            std::process::id()
        ));
        fs::rename(destination, &retired)?;
        fs::rename(staging, destination)?;
        File::open(parent)?.sync_all()?;
        return fs::remove_dir_all(retired);
    }
    fs::rename(staging, destination)?;
    File::open(parent)?.sync_all()
}

/// Checks an untrusted package: schema, normalized unique relative paths
/// with no symlink anywhere, regular files of the declared length and
/// SHA-256, and no undeclared file.
pub fn verify_portable_package(package: &Path) -> Result<PortableSummary, SessionExportError> {
    Ok(verify_package(package)?.summary)
}

/// A verified package's manifest document and its own digest.
pub(crate) struct VerifiedPackage {
    pub manifest: Value,
    pub manifest_sha256: String,
    pub summary: PortableSummary,
}

pub(crate) fn verify_package(package: &Path) -> Result<VerifiedPackage, SessionExportError> {
    let invalid = SessionExportError::InvalidPackage;
    let root = fs::symlink_metadata(package)?;
    if !root.is_dir() {
        return Err(invalid("package is not a directory"));
    }
    let manifest_path = package.join("manifest.json");
    let manifest_file = open_regular(&manifest_path)?;
    if manifest_file.metadata()?.len() > MAX_MANIFEST_BYTES {
        return Err(invalid("manifest is too large"));
    }
    let mut bytes = Vec::new();
    manifest_file
        .take(MAX_MANIFEST_BYTES)
        .read_to_end(&mut bytes)?;
    let manifest: Value =
        serde_json::from_slice(&bytes).map_err(|_| invalid("manifest is not JSON"))?;
    if manifest["schema"] != schema_id(PORTABLE_V1_SCHEMA_JSON).as_str()
        || manifest["schema_version"] != 1
    {
        return Err(invalid("unsupported package schema"));
    }
    let files = manifest["files"]
        .as_array()
        .filter(|files| files.len() >= 2)
        .ok_or(invalid("manifest lists no files"))?;
    let mut declared = BTreeSet::new();
    let mut total = 0_u64;
    for entry in files {
        let path = entry["path"]
            .as_str()
            .ok_or(invalid("file path is missing"))?;
        let relative = normalized_relative(path)?;
        if relative == Path::new("manifest.json") || !declared.insert(relative.clone()) {
            return Err(invalid("a file path is duplicated"));
        }
        if !matches!(
            entry["role"].as_str(),
            Some("session_manifest" | "transcript" | "source_media" | "derived_media")
        ) || entry["media_type"].as_str().is_none()
        {
            return Err(invalid("a file role is not recognized"));
        }
        let length = entry["byte_length"]
            .as_u64()
            .filter(|length| *length <= MAX_ENTRY_BYTES)
            .ok_or(invalid("a file length is invalid"))?;
        let expected = entry["sha256"]
            .as_str()
            .filter(|digest| digest.len() == 64 && digest.bytes().all(|b| b.is_ascii_hexdigit()))
            .ok_or(invalid("a file digest is invalid"))?;
        reject_symlinked_parents(package, &relative)?;
        let file = open_regular(&package.join(&relative))?;
        if file.metadata()?.len() != length {
            return Err(invalid("a file length differs from the manifest"));
        }
        let mut hasher = Sha256::new();
        io::copy(&mut file.take(length), &mut hasher)?;
        if hex(&hasher.finalize()) != expected {
            return Err(invalid("a file digest differs from the manifest"));
        }
        total += length;
    }
    let mut present = BTreeSet::new();
    collect_files(package, Path::new(""), &mut present)?;
    present.remove(Path::new("manifest.json"));
    if present != declared {
        return Err(invalid("the package holds an undeclared or missing file"));
    }
    let summary = PortableSummary {
        source_session_id: manifest["source_session_id"]
            .as_str()
            .ok_or(invalid("source session is missing"))?
            .to_owned(),
        title: manifest["title"].as_str().unwrap_or_default().to_owned(),
        files: files.len() as u32,
        byte_length: total,
    };
    Ok(VerifiedPackage {
        manifest_sha256: hex(&Sha256::digest(&bytes)),
        manifest,
        summary,
    })
}

pub(crate) fn normalized_relative(path: &str) -> Result<PathBuf, SessionExportError> {
    let invalid = || SessionExportError::InvalidPackage("a file path is not a safe relative path");
    if path.is_empty() || path.contains('\\') || path.contains('\0') || path.contains("//") {
        return Err(invalid());
    }
    let relative = Path::new(path);
    if !relative
        .components()
        .all(|component| matches!(component, Component::Normal(_)))
    {
        return Err(invalid());
    }
    Ok(relative.to_path_buf())
}

fn reject_symlinked_parents(package: &Path, relative: &Path) -> Result<(), SessionExportError> {
    let mut current = package.to_path_buf();
    for component in relative.parent().into_iter().flat_map(Path::components) {
        current.push(component);
        if !fs::symlink_metadata(&current)?.is_dir() {
            return Err(SessionExportError::InvalidPackage(
                "a path passes through a non-directory",
            ));
        }
    }
    Ok(())
}

pub(crate) fn open_regular(path: &Path) -> Result<File, SessionExportError> {
    let file = OpenOptions::new()
        .read(true)
        .custom_flags(rustix::fs::OFlags::NOFOLLOW.bits() as i32)
        .open(path)
        .map_err(|_| SessionExportError::InvalidPackage("a listed file is missing or a link"))?;
    if !file.metadata()?.is_file() {
        return Err(SessionExportError::InvalidPackage(
            "a listed file is not a regular file",
        ));
    }
    Ok(file)
}

fn collect_files(
    root: &Path,
    relative: &Path,
    out: &mut BTreeSet<PathBuf>,
) -> Result<(), SessionExportError> {
    for entry in fs::read_dir(root.join(relative))? {
        let entry = entry?;
        let path = relative.join(entry.file_name());
        let kind = entry.file_type()?;
        if kind.is_dir() {
            collect_files(root, &path, out)?;
        } else if kind.is_file() {
            out.insert(path);
        } else {
            return Err(SessionExportError::InvalidPackage(
                "the package holds a link or device",
            ));
        }
    }
    Ok(())
}

fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|byte| format!("{byte:02x}")).collect()
}
