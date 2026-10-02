//! Cross-track drift over a saved two-source capture (ADR 0005: at most
//! 100 ms over two hours; the M1 operator session's measurement procedure).
//!
//! Both sealed tracks are decoded independently. Each pulse of the coded
//! stimulus is found in each track by normalized cross-correlation, and its
//! sample is mapped to the session timeline through its own segment's
//! persisted native start plus `sample / 48 kHz`, so gaps are never
//! concatenated away and nothing is resampled. `offset = microphone -
//! computer`; `drift = offset - first offset` removes the fixed acoustic
//! latency. Every detection, rejected or not, stays in the report.

use crate::drift_stimulus::{DriftError, STIMULUS_SAMPLE_RATE, StimulusSpec, stimulus_sha256};
use open_scribe_store::{SealedTrackReader, SessionStore, TimelineSegment};
use open_scribe_types::SessionId;
use serde_json::{Value, json};

pub const DRIFT_REPORT_SCHEMA: &str = "open-scribe.drift-measurement/v1";
const DETECTOR_VERSION: u64 = 1;
const SECOND: i64 = 1_000_000_000;
pub const TWO_HOURS_NANOSECONDS: i64 = 7_200 * SECOND;
/// Where the first pulse is searched for, from each track's first sample.
const FIRST_SEARCH_NANOSECONDS: i64 = 180 * SECOND;
/// Half-width of the window around each predicted pulse.
const WINDOW_NANOSECONDS: i64 = SECOND / 2;
const MIN_CORRELATION: f64 = 0.1;
const MIN_PEAK_RATIO: f64 = 1.5;
/// Peaks closer than two chips are the same arrival.
const PEAK_EXCLUSION_FRAMES: usize = 96;
const LIMIT_NANOSECONDS: i64 = 100_000_000;
const BLOCK: usize = 1 << 16;

#[derive(Clone, Copy, Debug)]
pub struct DriftOptions {
    pub required_coverage_nanoseconds: i64,
}

impl Default for DriftOptions {
    fn default() -> Self {
        Self {
            required_coverage_nanoseconds: TWO_HOURS_NANOSECONDS,
        }
    }
}

/// The measured report and whether it passes.
#[derive(Clone, Debug)]
pub struct DriftReport {
    pub passed: bool,
    pub reasons: Vec<&'static str>,
    pub document: Value,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum Status {
    Detected,
    Ambiguous,
    Missing,
}

impl Status {
    const fn label(self) -> &'static str {
        match self {
            Self::Detected => "detected",
            Self::Ambiguous => "ambiguous",
            Self::Missing => "missing",
        }
    }
}

#[derive(Clone, Copy, Debug)]
struct Detection {
    status: Status,
    session_nanoseconds: Option<i64>,
    correlation: f64,
    peak_ratio: f64,
}

impl Detection {
    const MISSING: Self = Self {
        status: Status::Missing,
        session_nanoseconds: None,
        correlation: 0.0,
        peak_ratio: 0.0,
    };

    fn json(&self) -> Value {
        json!({
            "status": self.status.label(),
            "session_ns": self.session_nanoseconds,
            "correlation": round(self.correlation),
            "peak_ratio": round(self.peak_ratio),
        })
    }
}

struct PlacedSegment {
    span: usize,
    first_frame: u64,
    frames: u64,
    native_start: i64,
    segment_id: String,
    digest_sha256: String,
}

struct Track {
    role: &'static str,
    track_id: String,
    source_kind: String,
    reader: SealedTrackReader,
    span_frames: Vec<u64>,
    segments: Vec<PlacedSegment>,
    last: Option<(u32, i64)>,
}

impl Track {
    fn open(
        store: &SessionStore,
        session: &SessionId,
        role: &'static str,
        (track_id, source_kind): (&str, &str),
        timeline: &[TimelineSegment],
    ) -> Result<Self, DriftError> {
        let input = store.transcription_input(session, track_id)?;
        let reader = store.open_transcription_input(&input)?;
        let mut segments = Vec::new();
        let mut span_frames = Vec::new();
        for (span, placed) in input.spans.iter().enumerate() {
            let mut first_frame = 0;
            for segment in &placed.segments {
                let native_start = timeline
                    .iter()
                    .find(|entry| entry.segment_id == segment.segment_id)
                    .map(|entry| entry.native_start_nanoseconds)
                    .ok_or(DriftError::Invalid("a segment is not on the timeline"))?;
                segments.push(PlacedSegment {
                    span,
                    first_frame,
                    frames: segment.frames,
                    native_start,
                    segment_id: segment.segment_id.clone(),
                    digest_sha256: segment.digest_sha256.clone(),
                });
                first_frame += segment.frames;
            }
            span_frames.push(first_frame);
        }
        if segments.is_empty() {
            return Err(DriftError::Invalid("a track has no sealed media"));
        }
        Ok(Self {
            role,
            track_id: track_id.to_owned(),
            source_kind: source_kind.to_owned(),
            reader,
            span_frames,
            segments,
            last: None,
        })
    }

    fn start(&self) -> i64 {
        self.segments[0].native_start
    }

    /// The span and frame holding `nanoseconds`, or the next sealed frame
    /// after it when it falls in a gap.
    fn locate(&self, nanoseconds: i64) -> Option<(usize, u64)> {
        for segment in &self.segments {
            if nanoseconds < segment.native_start {
                return Some((segment.span, segment.first_frame));
            }
            let into = frames_in(nanoseconds - segment.native_start);
            if into < segment.frames {
                return Some((segment.span, segment.first_frame + into));
            }
        }
        None
    }

    /// Session time of a (fractional) frame, through its own segment.
    fn session_nanoseconds(&self, span: usize, frame: f64) -> i64 {
        let segment = self
            .segments
            .iter()
            .filter(|segment| segment.span == span)
            .find(|segment| frame < (segment.first_frame + segment.frames) as f64)
            .or_else(|| self.segments.iter().rfind(|segment| segment.span == span))
            .expect("span has a segment");
        let into =
            (frame - segment.first_frame as f64) * SECOND as f64 / f64::from(STIMULUS_SAMPLE_RATE);
        segment.native_start + into.round() as i64
    }

    /// Mean of all channels, scaled to [-1, 1).
    fn read(&self, span: usize, start: u64, end: u64) -> Result<Vec<f64>, DriftError> {
        let channels = usize::from(self.reader.channels().max(1));
        let samples = self.reader.read_frames(span, start, end)?;
        Ok(samples
            .chunks_exact(channels)
            .map(|frame| {
                frame.iter().map(|s| f64::from(*s)).sum::<f64>() / (channels as f64 * 32_768.0)
            })
            .collect())
    }

    /// Searches `[from, to)` session time for one pulse.
    fn search(&self, from: i64, to: i64, template: &Template) -> Result<Detection, DriftError> {
        let mut best = Detection::MISSING;
        for (span, &length) in self.span_frames.iter().enumerate() {
            let Some((start_span, start)) = self.locate(from) else {
                break;
            };
            if start_span > span {
                continue;
            }
            let start = if start_span == span { start } else { 0 };
            let end = match self.locate(to) {
                Some((end_span, end)) if end_span == span => end,
                Some((end_span, _)) if end_span < span => break,
                _ => length,
            };
            let end = (end + template.samples.len() as u64).min(length);
            if end <= start || end - start < template.samples.len() as u64 {
                continue;
            }
            let signal = self.read(span, start, end)?;
            let Some(peak) = template.peak(&signal) else {
                continue;
            };
            if peak.correlation.abs() > best.correlation.abs() {
                best = Detection {
                    status: classify(peak.correlation, peak.peak_ratio),
                    session_nanoseconds: Some(
                        self.session_nanoseconds(span, start as f64 + peak.offset),
                    ),
                    correlation: peak.correlation,
                    peak_ratio: peak.peak_ratio,
                };
            }
        }
        if best.status == Status::Missing {
            best.session_nanoseconds = None;
        }
        Ok(best)
    }
}

fn classify(correlation: f64, ratio: f64) -> Status {
    if correlation.abs() < MIN_CORRELATION {
        Status::Missing
    } else if ratio < MIN_PEAK_RATIO {
        Status::Ambiguous
    } else {
        Status::Detected
    }
}

fn frames_in(nanoseconds: i64) -> u64 {
    u64::try_from(
        i128::from(nanoseconds.max(0)) * i128::from(STIMULUS_SAMPLE_RATE) / i128::from(SECOND),
    )
    .unwrap_or(u64::MAX)
}

fn round(value: f64) -> f64 {
    (value * 10_000.0).round() / 10_000.0
}

/// Measures a saved capture against the stimulus it recorded. `played_sha256`
/// is the digest of the file that was actually played.
pub fn measure_drift(
    store: &SessionStore,
    session: &SessionId,
    spec: &StimulusSpec,
    played_sha256: &str,
    options: DriftOptions,
) -> Result<DriftReport, DriftError> {
    spec.validate()?;
    let inventory = store.session_inventory(session)?;
    if inventory.origin != "capture" {
        return Err(DriftError::Invalid("drift is measured on a capture"));
    }
    let mut tracks: Vec<(String, String)> = Vec::new();
    for entry in &inventory.media {
        if !tracks.iter().any(|(id, _)| *id == entry.track_id) {
            tracks.push((entry.track_id.clone(), entry.source_kind.clone()));
        }
    }
    let pick = |kinds: &[&str]| {
        let matching: Vec<_> = tracks
            .iter()
            .filter(|(_, kind)| kinds.contains(&kind.as_str()))
            .collect();
        match matching.as_slice() {
            [(id, kind)] => Ok((id.as_str(), kind.as_str())),
            _ => Err(DriftError::Invalid(
                "a drift run needs exactly one microphone and one computer-audio track",
            )),
        }
    };
    let microphone_track = pick(&["microphone"])?;
    let computer_track = pick(&["system_audio", "application_audio"])?;
    let timeline = store.playback_timeline(session)?;
    let mut microphone = Track::open(store, session, "microphone", microphone_track, &timeline)?;
    let mut computer = Track::open(store, session, "computer", computer_track, &timeline)?;

    let period = i64::from(spec.period_frames) * SECOND / i64::from(STIMULUS_SAMPLE_RATE);
    let mut pulses = Vec::with_capacity(spec.pulse_count as usize);
    for index in 0..spec.pulse_count {
        let template = Template::new(spec.template(index));
        let mut found = [Detection::MISSING; 2];
        for (slot, track) in [&mut microphone, &mut computer].into_iter().enumerate() {
            let detection = match (index, track.last) {
                (0, _) => track.search(
                    track.start(),
                    track.start() + FIRST_SEARCH_NANOSECONDS,
                    &template,
                )?,
                (_, Some((last_index, last_at))) => {
                    let predicted = last_at + i64::from(index - last_index) * period;
                    track.search(
                        predicted - WINDOW_NANOSECONDS,
                        predicted + WINDOW_NANOSECONDS,
                        &template,
                    )?
                }
                // Without a first pulse there is nothing to predict from.
                (_, None) => Detection::MISSING,
            };
            if detection.status == Status::Detected {
                track.last = detection.session_nanoseconds.map(|at| (index, at));
            }
            found[slot] = detection;
        }
        pulses.push((index, found));
    }

    let both: Vec<(u32, i64, i64)> = pulses
        .iter()
        .filter_map(
            |(index, [mic, computer])| match (mic.status, computer.status) {
                (Status::Detected, Status::Detected) => Some((
                    *index,
                    mic.session_nanoseconds?,
                    computer.session_nanoseconds?,
                )),
                _ => None,
            },
        )
        .collect();
    let first_offset = both.first().map(|(_, mic, computer)| mic - computer);
    let mut max_offset = 0_i64;
    let mut max_drift = 0_i64;
    for (_, mic, computer) in &both {
        let offset = mic - computer;
        max_offset = max_offset.max(offset.abs());
        max_drift = max_drift.max((offset - first_offset.unwrap_or(offset)).abs());
    }
    let coverage = match (both.first(), both.last()) {
        (Some((_, _, first)), Some((_, _, last))) => last - first,
        _ => 0,
    };
    let count = |status: Status| {
        pulses
            .iter()
            .filter(|(_, found)| found.iter().any(|detection| detection.status == status))
            .count()
    };
    let expected_sha256 = stimulus_sha256(spec)?;
    let failed_sources = store
        .recorder_detail(session)?
        .events
        .iter()
        .filter(|event| event.kind == "source_failed")
        .count();

    let mut reasons = Vec::new();
    if expected_sha256 != played_sha256 {
        reasons.push("played_stimulus_differs_from_spec");
    }
    if count(Status::Missing) > 0 {
        reasons.push("pulse_missing");
    }
    if count(Status::Ambiguous) > 0 {
        reasons.push("pulse_ambiguous");
    }
    if coverage < options.required_coverage_nanoseconds {
        reasons.push("coverage_short");
    }
    if max_drift > LIMIT_NANOSECONDS {
        reasons.push("drift_over_limit");
    }
    if max_offset > LIMIT_NANOSECONDS {
        reasons.push("absolute_offset_over_limit");
    }
    if failed_sources > 0 {
        reasons.push("source_failed");
    }

    let detections: Vec<Value> = pulses
        .iter()
        .map(|(index, [mic, computer])| {
            let offset = mic
                .session_nanoseconds
                .zip(computer.session_nanoseconds)
                .filter(|_| mic.status == Status::Detected && computer.status == Status::Detected)
                .map(|(mic, computer)| mic - computer);
            json!({
                "index": index,
                "microphone": mic.json(),
                "computer": computer.json(),
                "offset_ns": offset,
                "drift_ns": offset.zip(first_offset).map(|(offset, first)| offset - first),
            })
        })
        .collect();
    let track_json = |track: &Track| {
        json!({
            "role": track.role,
            "track_id": track.track_id,
            "source_kind": track.source_kind,
            "channel_choice": "mean_of_channels",
            "segments": track.segments.iter().map(|segment| json!({
                "segment_id": segment.segment_id,
                "native_start_ns": segment.native_start,
                "frames": segment.frames,
                "sha256": segment.digest_sha256,
            })).collect::<Vec<_>>(),
        })
    };
    let passed = reasons.is_empty();
    let document = json!({
        "schema": DRIFT_REPORT_SCHEMA,
        "detector_version": DETECTOR_VERSION,
        "session_id": session.0,
        "result": if passed { "M1_TWO_HOUR_DRIFT_GREEN" } else { "M1_TWO_HOUR_DRIFT_RED" },
        "reasons": reasons,
        "stimulus": spec.to_json(played_sha256),
        "stimulus_sha256_expected": expected_sha256,
        "tracks": [track_json(&microphone), track_json(&computer)],
        "method": {
            "mapping": "segment native_start_ns + sample / 48000",
            "correlation": "normalized cross-correlation, absolute value, parabolic sub-sample peak",
            "first_search_ns": FIRST_SEARCH_NANOSECONDS,
            "window_half_width_ns": WINDOW_NANOSECONDS,
            "minimum_correlation": MIN_CORRELATION,
            "minimum_peak_ratio": MIN_PEAK_RATIO,
            "timing_resolution_ns": SECOND / i64::from(STIMULUS_SAMPLE_RATE),
            "limit_ns": LIMIT_NANOSECONDS,
            "required_coverage_ns": options.required_coverage_nanoseconds,
        },
        "summary": {
            "pulses_expected": spec.pulse_count,
            "pulses_detected_in_both": both.len(),
            "pulses_with_a_missing_track": count(Status::Missing),
            "pulses_with_an_ambiguous_track": count(Status::Ambiguous),
            "coverage_ns": coverage,
            "first_offset_ns": first_offset,
            "max_abs_offset_ns": max_offset,
            "max_abs_drift_ns": max_drift,
            "source_failures": failed_sources,
        },
        "detections": detections,
    });
    Ok(DriftReport {
        passed,
        reasons,
        document,
    })
}

struct Peak {
    /// Fractional frame offset of the best match within the signal.
    offset: f64,
    correlation: f64,
    peak_ratio: f64,
}

/// A pulse template with its spectrum for block correlation.
struct Template {
    samples: Vec<f64>,
    norm: f64,
    spectrum: (Vec<f64>, Vec<f64>),
    fft: Fft,
}

impl Template {
    fn new(samples: Vec<f64>) -> Self {
        let fft = Fft::new(BLOCK);
        let mut re = vec![0.0; BLOCK];
        re[..samples.len()].copy_from_slice(&samples);
        let mut im = vec![0.0; BLOCK];
        fft.transform(&mut re, &mut im, false);
        Self {
            norm: samples.iter().map(|s| s * s).sum::<f64>().sqrt(),
            samples,
            spectrum: (re, im),
            fft,
        }
    }

    /// The normalized cross-correlation peak of this template in `signal`.
    fn peak(&self, signal: &[f64]) -> Option<Peak> {
        let length = self.samples.len();
        if signal.len() < length || self.norm == 0.0 {
            return None;
        }
        let positions = signal.len() - length + 1;
        let mut energy = Vec::with_capacity(signal.len() + 1);
        energy.push(0.0);
        for sample in signal {
            energy.push(energy.last().copied().unwrap_or(0.0) + sample * sample);
        }
        let step = BLOCK - length + 1;
        let mut correlation = vec![0.0; positions];
        let (template_re, template_im) = &self.spectrum;
        for block in (0..positions).step_by(step) {
            let available = (signal.len() - block).min(BLOCK);
            let mut re = vec![0.0; BLOCK];
            re[..available].copy_from_slice(&signal[block..block + available]);
            let mut im = vec![0.0; BLOCK];
            self.fft.transform(&mut re, &mut im, false);
            for bin in 0..BLOCK {
                // Multiply by the conjugate template spectrum.
                let (a, b) = (re[bin], im[bin]);
                let (c, d) = (template_re[bin], -template_im[bin]);
                re[bin] = a * c - b * d;
                im[bin] = a * d + b * c;
            }
            self.fft.transform(&mut re, &mut im, true);
            for lag in 0..step.min(positions - block) {
                let window = energy[block + lag + length] - energy[block + lag];
                correlation[block + lag] = if window > 1e-12 {
                    re[lag] / (self.norm * window.sqrt())
                } else {
                    0.0
                };
            }
        }
        let (best, value) = correlation
            .iter()
            .enumerate()
            .max_by(|(_, a), (_, b)| a.abs().total_cmp(&b.abs()))
            .map(|(index, value)| (index, *value))?;
        let second = correlation
            .iter()
            .enumerate()
            .filter(|(index, _)| index.abs_diff(best) > PEAK_EXCLUSION_FRAMES)
            .map(|(_, value)| value.abs())
            .fold(0.0, f64::max);
        let refine = if best > 0 && best + 1 < positions {
            let (left, middle, right) = (
                correlation[best - 1].abs(),
                correlation[best].abs(),
                correlation[best + 1].abs(),
            );
            let curvature = left - 2.0 * middle + right;
            if curvature < 0.0 {
                (0.5 * (left - right) / curvature).clamp(-0.5, 0.5)
            } else {
                0.0
            }
        } else {
            0.0
        };
        Some(Peak {
            offset: best as f64 + refine,
            correlation: value,
            peak_ratio: if second > 0.0 {
                value.abs() / second
            } else {
                f64::INFINITY
            },
        })
    }
}

/// An in-place iterative radix-2 complex FFT of one fixed size.
struct Fft {
    size: usize,
    reversed: Vec<usize>,
    cos: Vec<f64>,
    sin: Vec<f64>,
}

impl Fft {
    fn new(size: usize) -> Self {
        assert!(size.is_power_of_two());
        let bits = size.trailing_zeros();
        let reversed = (0..size)
            .map(|index| index.reverse_bits() >> (usize::BITS - bits))
            .collect();
        let (cos, sin) = (0..size / 2)
            .map(|k| {
                let angle = -std::f64::consts::TAU * k as f64 / size as f64;
                (angle.cos(), angle.sin())
            })
            .unzip();
        Self {
            size,
            reversed,
            cos,
            sin,
        }
    }

    fn transform(&self, re: &mut [f64], im: &mut [f64], inverse: bool) {
        let size = self.size;
        for index in 0..size {
            let target = self.reversed[index];
            if target > index {
                re.swap(index, target);
                im.swap(index, target);
            }
        }
        let direction = if inverse { -1.0 } else { 1.0 };
        let mut half = 1;
        while half < size {
            let stride = size / (2 * half);
            for start in (0..size).step_by(2 * half) {
                for offset in 0..half {
                    let (wr, wi) = (
                        self.cos[offset * stride],
                        direction * self.sin[offset * stride],
                    );
                    let (even, odd) = (start + offset, start + offset + half);
                    let (xr, xi) = (re[odd] * wr - im[odd] * wi, re[odd] * wi + im[odd] * wr);
                    re[odd] = re[even] - xr;
                    im[odd] = im[even] - xi;
                    re[even] += xr;
                    im[even] += xi;
                }
            }
            half *= 2;
        }
        if inverse {
            let scale = 1.0 / size as f64;
            re.iter_mut().for_each(|value| *value *= scale);
            im.iter_mut().for_each(|value| *value *= scale);
        }
    }
}

#[cfg(test)]
#[path = "drift_tests.rs"]
mod tests;
