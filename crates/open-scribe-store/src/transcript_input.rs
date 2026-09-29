//! Read-only access to one sealed audio track for final transcription.
//!
//! Inputs come only from sealed segments of a `ready_for_review` session,
//! through the same identity-bound leases playback uses. Every segment's full
//! bytes are rehashed against its sealed digest before any sample is read, so
//! transcription can never consume unsealed, replaced, or altered media.

use super::import::ImportedPlaybackLease;
use super::{
    MEDIA_FORMAT_CAF_PCM_S16LE, MEDIA_SAMPLE_RATE_HZ, SessionStore, StoreError, inspect_pcm_caf,
};
use open_scribe_types::SessionId;
use sha2::{Digest, Sha256};
use std::os::unix::fs::FileExt;

/// A positive placement gap larger than one 48 kHz frame starts a new span.
const SPAN_GAP_NANOSECONDS: i64 = 1_000_000_000 / MEDIA_SAMPLE_RATE_HZ as i64 + 1;

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct TranscriptionInput {
    pub session_id: SessionId,
    pub track_id: String,
    pub channels: u16,
    /// Digest over the ordered sealed segment identities and placements.
    pub input_digest: String,
    pub spans: Vec<InputSpan>,
}

/// Contiguous sealed media; frames are positioned by sample count.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct InputSpan {
    pub start_nanoseconds: i64,
    pub frames: u64,
    pub segments: Vec<InputSegment>,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct InputSegment {
    pub source_id: String,
    pub segment_id: String,
    pub frames: u64,
    pub digest_sha256: String,
}

struct OpenSegment {
    lease: ImportedPlaybackLease,
    audio_offset: u64,
    first_frame: u64,
    frames: u64,
}

/// Verified descriptors for every segment of one input.
pub struct SealedTrackReader {
    channels: u16,
    spans: Vec<Vec<OpenSegment>>,
}

impl SessionStore {
    /// Sealed PCM tracks of a saved session that transcription may read.
    pub fn transcription_tracks(&self, session: &SessionId) -> Result<Vec<String>, StoreError> {
        let mut statement = self.connection.prepare(
            "SELECT DISTINCT segments.track_id FROM sessions
             JOIN segments ON segments.session_id = sessions.id
             WHERE sessions.id = ?1 AND sessions.lifecycle = 'ready_for_review'
               AND segments.lifecycle = 'sealed' AND segments.seal_state = 'sealed'
               AND segments.media_format = ?2
             ORDER BY segments.track_id",
        )?;
        let tracks = statement
            .query_map(
                rusqlite::params![&session.0, MEDIA_FORMAT_CAF_PCM_S16LE],
                |row| row.get::<_, String>(0),
            )?
            .collect::<Result<Vec<_>, _>>()?;
        Ok(tracks)
    }

    pub fn transcription_input(
        &self,
        session: &SessionId,
        track_id: &str,
    ) -> Result<TranscriptionInput, StoreError> {
        let origin: String = self
            .connection
            .query_row(
                "SELECT origin FROM sessions WHERE id = ?1 AND lifecycle = 'ready_for_review'",
                [&session.0],
                |row| row.get(0),
            )
            .map_err(|error| match error {
                rusqlite::Error::QueryReturnedNoRows => {
                    StoreError::InvalidState("session is not saved for review")
                }
                other => StoreError::Sqlite(other),
            })?;
        let placed = if origin == "import" {
            self.imported_placement(session, track_id)?
        } else {
            self.playback_timeline(session)?
                .into_iter()
                .filter(|segment| segment.track_id == track_id)
                .map(|segment| {
                    (
                        segment.source_id,
                        segment.segment_id,
                        segment.start_nanoseconds,
                        segment.gap_nanoseconds,
                        segment.sample_count,
                        segment.channels,
                    )
                })
                .collect()
        };
        if placed.is_empty() {
            return Err(StoreError::InvalidState("track has no sealed PCM media"));
        }
        let channels = placed[0].5;
        let mut spans: Vec<InputSpan> = Vec::new();
        let mut hasher = Sha256::new();
        hasher.update(b"open-scribe.transcription-input/v1\n");
        hasher.update(session.0.as_bytes());
        hasher.update(b"\n");
        hasher.update(track_id.as_bytes());
        for (source_id, segment_id, start, gap, frames, segment_channels) in placed {
            if segment_channels != channels {
                return Err(StoreError::IntegrityMismatch(
                    "track changed channel count between segments",
                ));
            }
            let digest = self.sealed_segment_digest(session, &segment_id)?;
            let starts_span = spans.is_empty() || gap > SPAN_GAP_NANOSECONDS;
            if starts_span {
                spans.push(InputSpan {
                    start_nanoseconds: start,
                    frames: 0,
                    segments: Vec::new(),
                });
            }
            let span = spans.last_mut().expect("span exists");
            hasher.update(
                format!(
                    "\n{}|{segment_id}|{digest}|{frames}|{}",
                    usize::from(starts_span),
                    span.start_nanoseconds
                )
                .as_bytes(),
            );
            span.frames += frames;
            span.segments.push(InputSegment {
                source_id,
                segment_id,
                frames,
                digest_sha256: digest,
            });
        }
        Ok(TranscriptionInput {
            session_id: session.clone(),
            track_id: track_id.to_owned(),
            channels,
            input_digest: hex(&hasher.finalize()),
            spans,
        })
    }

    /// Leases every segment and verifies its full sealed bytes.
    pub fn open_transcription_input(
        &self,
        input: &TranscriptionInput,
    ) -> Result<SealedTrackReader, StoreError> {
        if self.transcription_input(&input.session_id, &input.track_id)? != *input {
            return Err(StoreError::IntegrityMismatch(
                "transcription input changed since it was planned",
            ));
        }
        let imported = input.spans.len() == 1
            && input.spans[0].segments.len() == 1
            && self.session_origin(&input.session_id)? == "import";
        let mut spans = Vec::with_capacity(input.spans.len());
        for span in &input.spans {
            let mut opened = Vec::with_capacity(span.segments.len());
            let mut first_frame = 0;
            for segment in &span.segments {
                let lease = if imported {
                    self.lease_imported_playback(&input.session_id)?
                } else {
                    self.lease_capture_playback(
                        &input.session_id,
                        &segment.source_id,
                        &input.track_id,
                        &segment.segment_id,
                        true,
                    )?
                };
                let audio_offset = verify_sealed_bytes(&lease, segment, input.channels)?;
                opened.push(OpenSegment {
                    lease,
                    audio_offset,
                    first_frame,
                    frames: segment.frames,
                });
                first_frame += segment.frames;
            }
            spans.push(opened);
        }
        Ok(SealedTrackReader {
            channels: input.channels,
            spans,
        })
    }

    fn imported_placement(
        &self,
        session: &SessionId,
        track_id: &str,
    ) -> Result<Vec<(String, String, i64, i64, u64, u16)>, StoreError> {
        let mut statement = self.connection.prepare(
            "SELECT tracks.source_id, segments.id, segments.sample_count, segments.channels
             FROM segments JOIN tracks ON tracks.id = segments.track_id
                            AND tracks.session_id = segments.session_id
             WHERE segments.session_id = ?1 AND segments.track_id = ?2
               AND segments.lifecycle = 'sealed' AND segments.seal_state = 'sealed'
               AND segments.media_format = ?3",
        )?;
        let rows = statement
            .query_map(
                rusqlite::params![&session.0, track_id, MEDIA_FORMAT_CAF_PCM_S16LE],
                |row| {
                    Ok((
                        row.get::<_, String>(0)?,
                        row.get::<_, String>(1)?,
                        row.get::<_, i64>(2)?,
                        row.get::<_, i64>(3)?,
                    ))
                },
            )?
            .collect::<Result<Vec<_>, _>>()?;
        if rows.len() > 1 {
            return Err(StoreError::IntegrityMismatch(
                "imported track has more than one segment",
            ));
        }
        rows.into_iter()
            .map(|(source_id, segment_id, frames, channels)| {
                let frames = u64::try_from(frames)
                    .ok()
                    .filter(|frames| *frames > 0)
                    .ok_or(StoreError::IntegrityMismatch(
                        "imported sample count is invalid",
                    ))?;
                let channels = u16::try_from(channels)
                    .map_err(|_| StoreError::IntegrityMismatch("imported channels are invalid"))?;
                Ok((source_id, segment_id, 0, 0, frames, channels))
            })
            .collect()
    }

    fn sealed_segment_digest(
        &self,
        session: &SessionId,
        segment_id: &str,
    ) -> Result<String, StoreError> {
        self.connection
            .query_row(
                "SELECT digest FROM segments WHERE session_id = ?1 AND id = ?2
                   AND lifecycle = 'sealed' AND seal_state = 'sealed' AND digest IS NOT NULL",
                [&session.0, segment_id],
                |row| row.get(0),
            )
            .map_err(|error| match error {
                rusqlite::Error::QueryReturnedNoRows => {
                    StoreError::IntegrityMismatch("segment has no sealed digest")
                }
                other => StoreError::Sqlite(other),
            })
    }

    fn session_origin(&self, session: &SessionId) -> Result<String, StoreError> {
        Ok(self.connection.query_row(
            "SELECT origin FROM sessions WHERE id = ?1",
            [&session.0],
            |row| row.get(0),
        )?)
    }
}

fn verify_sealed_bytes(
    lease: &ImportedPlaybackLease,
    segment: &InputSegment,
    channels: u16,
) -> Result<u64, StoreError> {
    let mut file = lease.file().try_clone()?;
    let length = file.metadata()?.len();
    let inspection = inspect_pcm_caf(&mut file, length)?.ok_or(StoreError::IntegrityMismatch(
        "sealed segment is not PCM CAF",
    ))?;
    if inspection.channels != channels || inspection.sample_count != Some(segment.frames) {
        return Err(StoreError::IntegrityMismatch(
            "sealed segment format changed since sealing",
        ));
    }
    let mut hasher = Sha256::new();
    let mut offset = 0_u64;
    let mut buffer = vec![0_u8; 1 << 20];
    while offset < length {
        let read = lease.file().read_at(&mut buffer, offset)?;
        if read == 0 {
            break;
        }
        hasher.update(&buffer[..read]);
        offset += read as u64;
    }
    if offset != length || hex(&hasher.finalize()) != segment.digest_sha256 {
        return Err(StoreError::IntegrityMismatch(
            "sealed segment bytes differ from their sealed digest",
        ));
    }
    Ok(inspection.audio_offset)
}

impl SealedTrackReader {
    pub fn channels(&self) -> u16 {
        self.channels
    }

    /// Interleaved samples for frames `[start, end)` of one span.
    pub fn read_frames(&self, span: usize, start: u64, end: u64) -> Result<Vec<i16>, StoreError> {
        let segments = self
            .spans
            .get(span)
            .ok_or(StoreError::InvalidRequest("span is out of range"))?;
        let total = segments
            .last()
            .map_or(0, |last| last.first_frame + last.frames);
        if start > end || end > total {
            return Err(StoreError::InvalidRequest(
                "frame range is outside the span",
            ));
        }
        let bytes_per_frame = 2 * u64::from(self.channels);
        let mut samples = Vec::with_capacity(((end - start) * u64::from(self.channels)) as usize);
        for segment in segments {
            let segment_end = segment.first_frame + segment.frames;
            let from = start.max(segment.first_frame);
            let to = end.min(segment_end);
            if from >= to {
                continue;
            }
            let mut bytes = vec![0_u8; ((to - from) * bytes_per_frame) as usize];
            segment.lease.file().read_exact_at(
                &mut bytes,
                segment.audio_offset + (from - segment.first_frame) * bytes_per_frame,
            )?;
            samples.extend(
                bytes
                    .chunks_exact(2)
                    .map(|pair| i16::from_le_bytes([pair[0], pair[1]])),
            );
        }
        Ok(samples)
    }
}

fn hex(bytes: &[u8]) -> String {
    use std::fmt::Write;
    bytes
        .iter()
        .fold(String::with_capacity(64), |mut out, byte| {
            let _ = write!(out, "{byte:02x}");
            out
        })
}
