//! Maps chunk hypotheses onto authoritative session time and removes the
//! duplicates that overlapping windows produce. The media timeline, not the
//! recognizer, decides where text belongs.

use crate::recognizer::Hypothesis;

pub const RECONCILIATION_VERSION: &str = "overlap-midpoint-v1";

/// Segments may end this far past their chunk before they are rejected as
/// materially outside input coverage; smaller overruns are clamped.
const COVERAGE_TOLERANCE_NANOSECONDS: i64 = 1_000_000_000;
/// Identical text this close across a chunk cut is one utterance.
const DUPLICATE_WINDOW_NANOSECONDS: i64 = 2_000_000_000;

pub struct ChunkHypothesis<'a> {
    pub chunk_id: &'a str,
    pub span_index: u32,
    pub start_nanoseconds: i64,
    pub end_nanoseconds: i64,
    pub hypothesis: &'a Hypothesis,
}

#[derive(Clone, Debug, PartialEq)]
pub struct ReconciledSegment {
    pub chunk_id: String,
    pub start_nanoseconds: i64,
    pub end_nanoseconds: i64,
    pub text: String,
    pub mean_probability: Option<f32>,
    pub no_speech_probability: Option<f32>,
}

/// Content-free counts of recognizer output that could not be placed.
#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub struct Rejections {
    pub empty: u32,
    pub inverted: u32,
    pub outside_coverage: u32,
    pub overlap_duplicates: u32,
}

/// `chunks` must be ordered by span and start time, as planned.
pub fn reconcile(chunks: &[ChunkHypothesis<'_>]) -> (Vec<ReconciledSegment>, Rejections) {
    let mut rejections = Rejections::default();
    let mut output: Vec<ReconciledSegment> = Vec::new();
    for (index, chunk) in chunks.iter().enumerate() {
        let previous = index
            .checked_sub(1)
            .map(|prior| &chunks[prior])
            .filter(|prior| prior.span_index == chunk.span_index);
        let next = chunks
            .get(index + 1)
            .filter(|following| following.span_index == chunk.span_index);
        let lower_cut = previous
            .filter(|prior| prior.end_nanoseconds > chunk.start_nanoseconds)
            .map(|prior| midpoint(chunk.start_nanoseconds, prior.end_nanoseconds));
        let upper_cut = next
            .filter(|following| chunk.end_nanoseconds > following.start_nanoseconds)
            .map(|following| midpoint(following.start_nanoseconds, chunk.end_nanoseconds));
        let first_of_chunk = output.len();
        for segment in place(chunk, &mut rejections) {
            let center = midpoint(segment.start_nanoseconds, segment.end_nanoseconds);
            if lower_cut.is_some_and(|cut| center < cut)
                || upper_cut.is_some_and(|cut| center >= cut)
            {
                continue;
            }
            if output.len() == first_of_chunk
                && lower_cut.is_some()
                && output
                    .last()
                    .is_some_and(|last| is_duplicate(last, &segment))
            {
                rejections.overlap_duplicates += 1;
                continue;
            }
            output.push(segment);
        }
    }
    (output, rejections)
}

fn place(chunk: &ChunkHypothesis<'_>, rejections: &mut Rejections) -> Vec<ReconciledSegment> {
    let mut placed = Vec::new();
    for segment in &chunk.hypothesis.segments {
        let text = segment.text.trim();
        if text.is_empty() {
            rejections.empty += 1;
            continue;
        }
        if segment.end_ms < segment.start_ms {
            rejections.inverted += 1;
            continue;
        }
        let start = chunk.start_nanoseconds + i64::from(segment.start_ms) * 1_000_000;
        let end = chunk.start_nanoseconds + i64::from(segment.end_ms) * 1_000_000;
        if start >= chunk.end_nanoseconds
            || end > chunk.end_nanoseconds + COVERAGE_TOLERANCE_NANOSECONDS
        {
            rejections.outside_coverage += 1;
            continue;
        }
        placed.push(ReconciledSegment {
            chunk_id: chunk.chunk_id.to_owned(),
            start_nanoseconds: start,
            end_nanoseconds: end.min(chunk.end_nanoseconds),
            text: text.to_owned(),
            mean_probability: segment.mean_probability,
            no_speech_probability: segment.no_speech_probability,
        });
    }
    placed
}

fn midpoint(start: i64, end: i64) -> i64 {
    start + (end - start) / 2
}

fn is_duplicate(left: &ReconciledSegment, right: &ReconciledSegment) -> bool {
    (right.start_nanoseconds - left.start_nanoseconds).abs() <= DUPLICATE_WINDOW_NANOSECONDS
        && normalized(&left.text) == normalized(&right.text)
}

fn normalized(text: &str) -> String {
    text.chars()
        .filter(|character| character.is_alphanumeric() || character.is_whitespace())
        .flat_map(char::to_lowercase)
        .collect::<String>()
        .split_whitespace()
        .collect::<Vec<_>>()
        .join(" ")
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::recognizer::HypothesisSegment;

    const S: i64 = 1_000_000_000;

    fn hypothesis(segments: &[(u32, u32, &str)]) -> Hypothesis {
        Hypothesis {
            language: "en".into(),
            segments: segments
                .iter()
                .map(|&(start_ms, end_ms, text)| HypothesisSegment {
                    start_ms,
                    end_ms,
                    text: text.into(),
                    mean_probability: Some(0.9),
                    no_speech_probability: Some(0.01),
                })
                .collect(),
        }
    }

    fn texts(segments: &[ReconciledSegment]) -> Vec<&str> {
        segments
            .iter()
            .map(|segment| segment.text.as_str())
            .collect()
    }

    #[test]
    fn overlap_keeps_each_utterance_once_on_its_side_of_the_midpoint() {
        // Chunk 0 covers 0-28 s, chunk 1 covers 23-51 s; the cut is 25.5 s.
        let first = hypothesis(&[
            (1_000, 4_000, "alpha"),
            (22_000, 24_000, "bravo"),
            (26_000, 27_500, "charlie"),
        ]);
        let second = hypothesis(&[
            (0, 1_000, "bravo"),
            (3_000, 4_500, "charlie"),
            (10_000, 12_000, "delta"),
        ]);
        let chunks = [
            ChunkHypothesis {
                chunk_id: "c0",
                span_index: 0,
                start_nanoseconds: 0,
                end_nanoseconds: 28 * S,
                hypothesis: &first,
            },
            ChunkHypothesis {
                chunk_id: "c1",
                span_index: 0,
                start_nanoseconds: 23 * S,
                end_nanoseconds: 51 * S,
                hypothesis: &second,
            },
        ];
        let (segments, rejections) = reconcile(&chunks);
        assert_eq!(texts(&segments), ["alpha", "bravo", "charlie", "delta"]);
        assert_eq!(segments[2].chunk_id, "c1");
        assert_eq!(
            (segments[2].start_nanoseconds, segments[2].end_nanoseconds),
            (26 * S, 27_500_000_000)
        );
        assert_eq!(rejections, Rejections::default());
    }

    #[test]
    fn duplicate_text_straddling_the_cut_is_dropped_once() {
        let first = hypothesis(&[(24_000, 25_400, "Same words.")]);
        let second = hypothesis(&[(2_600, 3_900, "same words")]);
        let chunks = [
            ChunkHypothesis {
                chunk_id: "c0",
                span_index: 0,
                start_nanoseconds: 0,
                end_nanoseconds: 28 * S,
                hypothesis: &first,
            },
            ChunkHypothesis {
                chunk_id: "c1",
                span_index: 0,
                start_nanoseconds: 23 * S,
                end_nanoseconds: 51 * S,
                hypothesis: &second,
            },
        ];
        let (segments, rejections) = reconcile(&chunks);
        assert_eq!(texts(&segments), ["Same words."]);
        assert_eq!(rejections.overlap_duplicates, 1);
    }

    #[test]
    fn invalid_output_is_counted_not_placed_and_spans_never_share_cuts() {
        let first = hypothesis(&[
            (0, 500, "   "),
            (2_000, 1_000, "inverted"),
            (3_000, 30_500, "clamped"),
            (3_000, 28_800, "overrun"),
        ]);
        let second = hypothesis(&[(0, 1_000, "clamped")]);
        let chunks = [
            ChunkHypothesis {
                chunk_id: "c0",
                span_index: 0,
                start_nanoseconds: 0,
                end_nanoseconds: 28 * S,
                hypothesis: &first,
            },
            ChunkHypothesis {
                chunk_id: "c1",
                span_index: 1,
                start_nanoseconds: 100 * S,
                end_nanoseconds: 110 * S,
                hypothesis: &second,
            },
        ];
        let (segments, rejections) = reconcile(&chunks);
        assert_eq!(texts(&segments), ["overrun", "clamped"]);
        assert_eq!(segments[0].end_nanoseconds, 28 * S);
        assert_eq!(segments[1].start_nanoseconds, 100 * S);
        assert_eq!(
            rejections,
            Rejections {
                empty: 1,
                inverted: 1,
                outside_coverage: 1,
                overlap_duplicates: 0
            }
        );
    }
}
