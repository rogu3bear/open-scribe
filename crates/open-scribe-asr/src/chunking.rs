//! Final-transcription chunk planning within one contiguous media span.
//!
//! ADR 0009 targets VAD-aligned 20-28 second chunks with 5 seconds of
//! overlap inside Whisper's 30-second window. Until the Silero VAD authority
//! exists, chunks are fixed 28-second windows; the planner version is part of
//! every run identity, so VAD-aligned plans will never reuse these chunks.

use crate::audio::MODEL_SAMPLE_RATE_HZ;

pub const CHUNK_PLANNER_VERSION: &str = "fixed-window-v1";
pub const CHUNK_WINDOW_SECONDS: u64 = 28;
pub const CHUNK_OVERLAP_SECONDS: u64 = 5;

/// A half-open range of 16 kHz samples within one span.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct ChunkRange {
    pub start: u64,
    pub end: u64,
}

pub fn plan_chunks(span_samples: u64) -> Vec<ChunkRange> {
    let window = CHUNK_WINDOW_SECONDS * u64::from(MODEL_SAMPLE_RATE_HZ);
    let step = (CHUNK_WINDOW_SECONDS - CHUNK_OVERLAP_SECONDS) * u64::from(MODEL_SAMPLE_RATE_HZ);
    let mut chunks = Vec::new();
    let mut start = 0;
    while start < span_samples {
        let end = (start + window).min(span_samples);
        chunks.push(ChunkRange { start, end });
        if end == span_samples {
            break;
        }
        start += step;
    }
    chunks
}

#[cfg(test)]
mod tests {
    use super::*;

    const SECOND: u64 = MODEL_SAMPLE_RATE_HZ as u64;

    #[test]
    fn spans_are_covered_by_overlapping_windows_within_the_model_limit() {
        assert!(plan_chunks(0).is_empty());
        assert_eq!(
            plan_chunks(3 * SECOND),
            [ChunkRange {
                start: 0,
                end: 3 * SECOND
            }]
        );
        assert_eq!(
            plan_chunks(30 * SECOND),
            [
                ChunkRange {
                    start: 0,
                    end: 28 * SECOND
                },
                ChunkRange {
                    start: 23 * SECOND,
                    end: 30 * SECOND
                },
            ]
        );
        let two_hours = plan_chunks(7_200 * SECOND);
        assert_eq!(two_hours.first().unwrap().start, 0);
        assert_eq!(two_hours.last().unwrap().end, 7_200 * SECOND);
        for pair in two_hours.windows(2) {
            assert_eq!(pair[0].end - pair[1].start, CHUNK_OVERLAP_SECONDS * SECOND);
        }
        assert!(
            two_hours
                .iter()
                .all(|chunk| chunk.end - chunk.start <= 28 * SECOND)
        );
    }
}
