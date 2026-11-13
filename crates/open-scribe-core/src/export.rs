//! Transcript exports (ADR 0010): plain text, Markdown, WebVTT, SubRip, and
//! `transcript/v1` JSON rendered from the store's selected Final revisions.
//!
//! Export never promotes state. The header or envelope states availability,
//! model identity, speaker provenance, and human corrections; JSON carries the
//! immutable verbatim text beside the effective correction and an evidence
//! reference per segment. Files are staged beside the destination, synced,
//! and renamed, so a failure never leaves an apparently complete export.

use open_scribe_evidence::{EVIDENCE_REF_SCHEMA, EvidenceKind, EvidenceRef};
pub(crate) use open_scribe_store::rfc3339_utc;
use open_scribe_store::{
    DocumentScope, SessionSpeaker, SessionStore, SpeakerLabelOrigin, StoreError,
    TranscriptDocumentSegment, TranscriptExportContext, UNKNOWN_SOURCE_SPEAKER_LABEL,
};
use open_scribe_types::SessionId;
use serde_json::{Value, json};
use std::fmt::{self, Write as _};
use std::fs::{self, File, OpenOptions};
use std::io::Write as _;
use std::path::{Path, PathBuf};
use std::sync::OnceLock;
use std::time::{SystemTime, UNIX_EPOCH};

/// The checked schema is the version authority; the exporter reads its `$id`.
pub const TRANSCRIPT_V1_SCHEMA_JSON: &str =
    include_str!("../../../docs/data-format/transcript.v1.schema.json");
pub(crate) const EXPORTER_NAME: &str = "open-scribe-core";
pub(crate) const EXPORTER_VERSION: &str = env!("CARGO_PKG_VERSION");
const NANOSECONDS_PER_MILLISECOND: i64 = 1_000_000;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum TranscriptExportFormat {
    PlainText,
    Markdown,
    WebVtt,
    SubRip,
    TranscriptJson,
}

impl TranscriptExportFormat {
    #[must_use]
    pub const fn file_extension(self) -> &'static str {
        match self {
            Self::PlainText => "txt",
            Self::Markdown => "md",
            Self::WebVtt => "vtt",
            Self::SubRip => "srt",
            Self::TranscriptJson => "json",
        }
    }
}

/// ADR 0009's aggregate transcript states. Partial Final coverage is Draft.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum TranscriptAvailability {
    Final,
    Draft,
    Failed,
    Unavailable,
}

impl TranscriptAvailability {
    /// Availability from which tracks have a selected Final revision.
    #[must_use]
    pub fn of(context: &TranscriptExportContext) -> Self {
        if context.selected.is_empty() {
            if context.failed_tracks.is_empty() {
                Self::Unavailable
            } else {
                Self::Failed
            }
        } else if context.transcribable_tracks.iter().all(|track| {
            context
                .selected
                .iter()
                .any(|revision| &revision.track_id == track)
        }) {
            Self::Final
        } else {
            Self::Draft
        }
    }

    const fn code(self) -> &'static str {
        match self {
            Self::Final => "final",
            Self::Draft => "draft",
            Self::Failed => "failed",
            Self::Unavailable => "unavailable",
        }
    }

    const fn title(self) -> &'static str {
        match self {
            Self::Final => "Final",
            Self::Draft => "Draft (not every track is Final)",
            Self::Failed => "Failed",
            Self::Unavailable => "Unavailable",
        }
    }
}

#[derive(Debug)]
pub enum TranscriptExportError {
    Store(StoreError),
    Io(std::io::Error),
    Json(serde_json::Error),
    InvalidDestination(&'static str),
    InvalidEvidence(open_scribe_evidence::EvidenceRefError),
}

impl fmt::Display for TranscriptExportError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Store(error) => write!(formatter, "{error}"),
            Self::Io(error) => write!(formatter, "export I/O failed: {error}"),
            Self::Json(error) => write!(formatter, "export encoding failed: {error}"),
            Self::InvalidDestination(reason) => {
                write!(formatter, "invalid export destination: {reason}")
            }
            Self::InvalidEvidence(error) => write!(formatter, "{error}"),
        }
    }
}

impl std::error::Error for TranscriptExportError {}

impl From<StoreError> for TranscriptExportError {
    fn from(error: StoreError) -> Self {
        Self::Store(error)
    }
}

impl From<std::io::Error> for TranscriptExportError {
    fn from(error: std::io::Error) -> Self {
        Self::Io(error)
    }
}

impl From<serde_json::Error> for TranscriptExportError {
    fn from(error: serde_json::Error) -> Self {
        Self::Json(error)
    }
}

/// Everything one export renders: the export facts and the Final-only
/// document.
#[derive(Clone, Debug)]
pub struct TranscriptExport {
    pub context: TranscriptExportContext,
    pub speakers: Vec<SessionSpeaker>,
    pub segments: Vec<TranscriptDocumentSegment>,
    pub exported_at_ms: i64,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct TranscriptExportReceipt {
    pub path: PathBuf,
    pub format: TranscriptExportFormat,
    pub availability: TranscriptAvailability,
    pub byte_length: u64,
    pub segment_count: u32,
}

impl TranscriptExport {
    pub fn collect(
        store: &SessionStore,
        session: &SessionId,
        exported_at_ms: i64,
    ) -> Result<Self, TranscriptExportError> {
        let context = store.transcript_export_context(session)?;
        let document = store.conversation_document(session, DocumentScope::FinalOnly)?;
        Ok(Self {
            context,
            speakers: document.speakers,
            segments: document.segments,
            exported_at_ms,
        })
    }

    #[must_use]
    pub fn availability(&self) -> TranscriptAvailability {
        TranscriptAvailability::of(&self.context)
    }

    pub fn render(&self, format: TranscriptExportFormat) -> Result<String, TranscriptExportError> {
        match format {
            TranscriptExportFormat::PlainText => Ok(self.render_text(false)),
            TranscriptExportFormat::Markdown => Ok(self.render_text(true)),
            TranscriptExportFormat::WebVtt => Ok(self.render_webvtt()),
            TranscriptExportFormat::SubRip => Ok(self.render_subrip()),
            TranscriptExportFormat::TranscriptJson => {
                let mut rendered = serde_json::to_string_pretty(&self.transcript_json()?)?;
                rendered.push('\n');
                Ok(rendered)
            }
        }
    }

    fn speaker(&self, track_id: &str) -> Option<&SessionSpeaker> {
        self.speakers
            .iter()
            .find(|speaker| speaker.track_id == track_id)
    }

    fn speakers_declaration(&self) -> &'static str {
        if self
            .speakers
            .iter()
            .any(|speaker| speaker.origin == SpeakerLabelOrigin::Human)
            || self
                .segments
                .iter()
                .any(|segment| segment.speaker_origin == SpeakerLabelOrigin::Human)
        {
            "user_adjudicated"
        } else if self
            .speakers
            .iter()
            .all(|speaker| speaker.source_kind.capture().is_some())
        {
            "capture_source"
        } else {
            "anonymous"
        }
    }

    fn corrected_count(&self) -> usize {
        self.segments
            .iter()
            .filter(|segment| segment.corrected)
            .count()
    }

    fn render_text(&self, markdown: bool) -> String {
        let escape = |text: &str| {
            if markdown {
                escape_markdown(text)
            } else {
                text.to_owned()
            }
        };
        let context = &self.context;
        let mut output = String::new();
        if markdown {
            let _ = writeln!(output, "# {}\n", escape(&context.title));
        } else {
            let _ = writeln!(output, "{}\n", context.title);
        }
        let bullet = if markdown { "- " } else { "" };
        let _ = writeln!(output, "{bullet}Session: {}", context.session_id.0);
        let _ = writeln!(
            output,
            "{bullet}Transcript: {}",
            self.availability().title()
        );
        for revision in &context.selected {
            let speaker = self
                .speaker(&revision.track_id)
                .map_or(UNKNOWN_SOURCE_SPEAKER_LABEL, |speaker| {
                    speaker.label.as_str()
                });
            let _ = writeln!(
                output,
                "{bullet}Model ({}): {} · {} {}",
                escape(speaker),
                escape(&revision.model_id),
                escape(&revision.engine),
                escape(&revision.engine_version)
            );
        }
        let _ = writeln!(
            output,
            "{bullet}Duration: {}",
            clock_seconds(context.duration_nanoseconds)
        );
        let _ = writeln!(
            output,
            "{bullet}Speakers: {}",
            match self.speakers_declaration() {
                "user_adjudicated" => "named by the user",
                "capture_source" => "declared by capture source",
                _ => "anonymous",
            }
        );
        let _ = writeln!(
            output,
            "{bullet}Human corrections: {} of {} segments",
            self.corrected_count(),
            self.segments.len()
        );
        let _ = writeln!(
            output,
            "{bullet}Exported: {}\n",
            rfc3339_utc(self.exported_at_ms)
        );
        for segment in &self.segments {
            let text = escape(&single_line(&segment.effective_text));
            let speaker = escape(&segment.speaker_label);
            let stamp = clock_seconds(segment.start_nanoseconds);
            if markdown {
                let _ = write!(output, "**[{stamp}] {speaker}:** {text}");
                if segment.corrected {
                    output.push_str(" _(corrected)_");
                }
                output.push_str("\n\n");
            } else {
                let _ = write!(output, "[{stamp}] {speaker}: {text}");
                if segment.corrected {
                    output.push_str(" (corrected)");
                }
                output.push('\n');
            }
        }
        output
    }

    fn cues(&self) -> impl Iterator<Item = (i64, i64, Option<&str>, String)> + '_ {
        self.segments.iter().map(|segment| {
            let start = segment.start_nanoseconds.max(0) / NANOSECONDS_PER_MILLISECOND;
            let end = ((segment
                .end_nanoseconds
                .max(0)
                .saturating_add(NANOSECONDS_PER_MILLISECOND - 1))
                / NANOSECONDS_PER_MILLISECOND)
                .max(start + 1);
            let speaker = (segment.speaker_origin == SpeakerLabelOrigin::Human
                || self
                    .speaker(&segment.track_id)
                    .is_some_and(|speaker| speaker.source_kind.capture().is_some()))
            .then_some(segment.speaker_label.as_str());
            (start, end, speaker, single_line(&segment.effective_text))
        })
    }

    fn render_webvtt(&self) -> String {
        let mut output = String::from("WEBVTT\n\n");
        let _ = writeln!(
            output,
            "NOTE\nOpen Scribe transcript: {}. Human corrections: {} of {} segments.\n",
            self.availability().title(),
            self.corrected_count(),
            self.segments.len()
        );
        for (start, end, speaker, text) in self.cues() {
            let _ = writeln!(
                output,
                "{} --> {}",
                clock_milliseconds(start, '.'),
                clock_milliseconds(end, '.')
            );
            match speaker {
                Some(speaker) => {
                    let _ = writeln!(
                        output,
                        "<v {}>{}</v>\n",
                        escape_webvtt(speaker),
                        escape_webvtt(&text)
                    );
                }
                None => {
                    let _ = writeln!(output, "{}\n", escape_webvtt(&text));
                }
            }
        }
        output
    }

    fn render_subrip(&self) -> String {
        let mut output = String::new();
        for (index, (start, end, speaker, text)) in self.cues().enumerate() {
            let _ = writeln!(
                output,
                "{}\n{} --> {}",
                index + 1,
                clock_milliseconds(start, ','),
                clock_milliseconds(end, ',')
            );
            match speaker {
                Some(speaker) => {
                    let _ = writeln!(output, "{speaker}: {text}\n");
                }
                None => {
                    let _ = writeln!(output, "{text}\n");
                }
            }
        }
        output
    }

    fn transcript_json(&self) -> Result<Value, TranscriptExportError> {
        let context = &self.context;
        let speaker_json = |label: &str, origin: SpeakerLabelOrigin| {
            json!({
                "label": label,
                "origin": origin.as_str(),
            })
        };
        let tracks: Vec<Value> = context
            .track_input_digests
            .iter()
            .map(|(track_id, input_digest)| {
                let revision = context
                    .selected
                    .iter()
                    .find(|revision| &revision.track_id == track_id);
                let finality = if revision.is_some() {
                    "final"
                } else if context.failed_tracks.contains(track_id) {
                    "failed"
                } else {
                    "pending"
                };
                let speaker = self.speaker(track_id);
                json!({
                    "track_id": track_id,
                    "source_kind": speaker.map_or("unknown", |speaker| speaker.source_kind.as_str()),
                    "input_digest": input_digest,
                    "finality": finality,
                    "speaker": speaker.map_or_else(
                        || speaker_json(UNKNOWN_SOURCE_SPEAKER_LABEL, SpeakerLabelOrigin::SourceDefault),
                        |speaker| speaker_json(&speaker.label, speaker.origin),
                    ),
                    "revision": revision.map(|revision| json!({
                        "revision_id": revision.revision_id,
                        "run_id": revision.run_id,
                        "engine": revision.engine,
                        "engine_version": revision.engine_version,
                        "model_id": revision.model_id,
                        "model_sha256": revision.model_sha256,
                        "input_digest": revision.input_digest,
                        "language": revision.language,
                    })),
                })
            })
            .collect();
        let mut segments = Vec::with_capacity(self.segments.len());
        for segment in &self.segments {
            let reference = EvidenceRef {
                schema: EVIDENCE_REF_SCHEMA.to_owned(),
                session_id: context.session_id.0.clone(),
                kind: EvidenceKind::TranscriptSegment,
                record_id: segment.revision_id.clone(),
                revision_id: Some(segment.revision_id.clone()),
                start_ns: segment.start_nanoseconds,
                end_ns: segment
                    .end_nanoseconds
                    .max(segment.start_nanoseconds.saturating_add(1)),
                sub_item: Some(segment.sequence.to_string()),
                content_digest: segment.verbatim_sha256.clone(),
                resolver_hint: None,
            };
            reference
                .validate()
                .map_err(TranscriptExportError::InvalidEvidence)?;
            segments.push(json!({
                "revision_id": segment.revision_id,
                "track_id": segment.track_id,
                "sequence": segment.sequence,
                "start_ns": segment.start_nanoseconds,
                "end_ns": segment.end_nanoseconds,
                "finality": "final",
                "verbatim_text": segment.verbatim_text,
                "effective_text": segment.effective_text,
                "correction": segment.corrected.then(|| json!({"origin": "human"})),
                "speaker": speaker_json(&segment.speaker_label, segment.speaker_origin),
                "evidence_ref": serde_json::to_value(&reference)?,
            }));
        }
        Ok(json!({
            "schema": transcript_schema_id(),
            "schema_version": 1,
            "exporter": {"name": EXPORTER_NAME, "version": EXPORTER_VERSION},
            "session": {
                "id": context.session_id.0,
                "title": context.title,
                "created_at_ms": context.created_at_ms,
            },
            "exported_at": rfc3339_utc(self.exported_at_ms),
            "timeline_unit": "nanoseconds",
            "duration_ns": context.duration_nanoseconds.max(0),
            "availability": self.availability().code(),
            "speakers_declaration": self.speakers_declaration(),
            "tracks": tracks,
            "segments": segments,
        }))
    }
}

/// Renders the session's transcript and atomically writes it to
/// `destination`, replacing any existing file there.
pub fn write_transcript_export(
    store: &SessionStore,
    session: &SessionId,
    format: TranscriptExportFormat,
    destination: &Path,
) -> Result<TranscriptExportReceipt, TranscriptExportError> {
    let exported_at_ms = now_milliseconds();
    let export = TranscriptExport::collect(store, session, exported_at_ms)?;
    let rendered = export.render(format)?;
    write_atomically(destination, rendered.as_bytes())?;
    Ok(TranscriptExportReceipt {
        path: destination.to_path_buf(),
        format,
        availability: export.availability(),
        byte_length: rendered.len() as u64,
        segment_count: u32::try_from(export.segments.len()).unwrap_or(u32::MAX),
    })
}

pub(crate) fn now_milliseconds() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_or(0, |elapsed| {
            i64::try_from(elapsed.as_millis()).unwrap_or(i64::MAX)
        })
}

fn write_atomically(destination: &Path, bytes: &[u8]) -> Result<(), TranscriptExportError> {
    write_atomically_with(destination, |file| file.write_all(bytes))
}

/// Writes a hidden sibling, synchronizes it, and renames it over `destination`;
/// a failure leaves no partial file behind.
pub fn write_atomically_with(
    destination: &Path,
    write: impl FnOnce(&mut File) -> std::io::Result<()>,
) -> Result<(), TranscriptExportError> {
    let file_name = destination
        .file_name()
        .and_then(|name| name.to_str())
        .filter(|name| !name.starts_with('.'))
        .ok_or(TranscriptExportError::InvalidDestination(
            "destination needs a visible file name",
        ))?;
    let parent = destination
        .parent()
        .filter(|parent| parent.is_dir())
        .ok_or(TranscriptExportError::InvalidDestination(
            "destination directory does not exist",
        ))?;
    if destination.is_dir() {
        return Err(TranscriptExportError::InvalidDestination(
            "destination is a directory",
        ));
    }
    let nonce = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_or(0, |elapsed| elapsed.as_nanos());
    let staging = parent.join(format!(
        ".{file_name}.partial-{}-{nonce}",
        std::process::id()
    ));
    let result = stage_and_rename(&staging, destination, parent, write);
    if result.is_err() {
        let _ = fs::remove_file(&staging);
    }
    result.map_err(TranscriptExportError::Io)
}

fn stage_and_rename(
    staging: &Path,
    destination: &Path,
    parent: &Path,
    write: impl FnOnce(&mut File) -> std::io::Result<()>,
) -> std::io::Result<()> {
    let mut file = OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(staging)?;
    write(&mut file)?;
    file.sync_all()?;
    drop(file);
    fs::rename(staging, destination)?;
    sync_directory(parent)
}

/// Makes a rename or creation inside `directory` durable.
pub(crate) fn sync_directory(directory: &Path) -> std::io::Result<()> {
    File::open(directory)?.sync_all()
}

fn transcript_schema_id() -> &'static str {
    static ID: OnceLock<String> = OnceLock::new();
    ID.get_or_init(|| {
        serde_json::from_str::<Value>(TRANSCRIPT_V1_SCHEMA_JSON)
            .ok()
            .and_then(|schema| schema.get("$id")?.as_str().map(str::to_owned))
            .expect("checked transcript schema declares its $id")
    })
}

pub(crate) fn single_line(text: &str) -> String {
    text.split_whitespace().collect::<Vec<_>>().join(" ")
}

fn escape_markdown(text: &str) -> String {
    let mut escaped = String::with_capacity(text.len());
    for character in text.chars() {
        if matches!(
            character,
            '\\' | '`' | '*' | '_' | '[' | ']' | '<' | '>' | '#' | '|' | '~'
        ) {
            escaped.push('\\');
        }
        escaped.push(character);
    }
    escaped
}

fn escape_webvtt(text: &str) -> String {
    text.replace('&', "&amp;")
        .replace('<', "&lt;")
        .replace('>', "&gt;")
}

fn clock_seconds(nanoseconds: i64) -> String {
    let seconds = nanoseconds.max(0) / 1_000_000_000;
    format!(
        "{:02}:{:02}:{:02}",
        seconds / 3600,
        seconds / 60 % 60,
        seconds % 60
    )
}

fn clock_milliseconds(milliseconds: i64, separator: char) -> String {
    let seconds = milliseconds / 1000;
    format!(
        "{:02}:{:02}:{:02}{separator}{:03}",
        seconds / 3600,
        seconds / 60 % 60,
        seconds % 60,
        milliseconds % 1000
    )
}

#[cfg(test)]
#[path = "export_tests.rs"]
mod tests;
