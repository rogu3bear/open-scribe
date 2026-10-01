//! The two-hour synchronization stimulus (ADR 0005; M1 operator session).
//!
//! Every pulse is a linear broadband chirp whose sign follows its own
//! pseudo-random chip code, so a pulse identifies its index wherever it is
//! found. The stimulus is fully determined by its spec: the analyzer
//! regenerates each pulse rather than trusting a played file, and the WAV's
//! SHA-256 binds the file that was played to that spec.

use crate::export::write_atomically_with;
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use std::fmt;
use std::io::{self, Write};
use std::path::Path;

pub const DRIFT_STIMULUS_SCHEMA: &str = "open-scribe.drift-stimulus/v1";
pub const STIMULUS_SAMPLE_RATE: u32 = 48_000;
const GENERATOR: &str = "open-scribe-core coded broadband chirp";
const GENERATOR_VERSION: u64 = 1;
/// The operator procedure requires a unique pulse at least every 30 seconds.
const MAX_PERIOD_FRAMES: u32 = 30 * STIMULUS_SAMPLE_RATE;
const EDGE_FRAMES: u32 = 240;
const MAX_STIMULUS_SECONDS: u32 = 4 * 60 * 60;

#[derive(Debug)]
pub enum DriftError {
    /// A spec, session, or report input is unusable; content-free.
    Invalid(&'static str),
    Store(open_scribe_store::StoreError),
    Io(io::Error),
}

impl fmt::Display for DriftError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Invalid(reason) => write!(f, "drift measurement input is invalid: {reason}"),
            Self::Store(error) => write!(f, "{error}"),
            Self::Io(error) => write!(f, "drift measurement I/O failed: {error}"),
        }
    }
}

impl std::error::Error for DriftError {}

impl From<open_scribe_store::StoreError> for DriftError {
    fn from(error: open_scribe_store::StoreError) -> Self {
        Self::Store(error)
    }
}

impl From<io::Error> for DriftError {
    fn from(error: io::Error) -> Self {
        Self::Io(error)
    }
}

/// Everything that determines the stimulus samples.
#[derive(Clone, Debug, PartialEq)]
pub struct StimulusSpec {
    pub seed: u64,
    pub pulse_count: u32,
    pub pulse_frames: u32,
    pub period_frames: u32,
    pub lead_in_frames: u32,
    pub chip_frames: u32,
    pub start_hz: f64,
    pub end_hz: f64,
    pub amplitude: f64,
}

impl StimulusSpec {
    /// The production stimulus: a 250 ms pulse every 20 seconds after a
    /// 5-second lead-in, as many as end within `seconds`.
    pub fn covering(seed: u64, seconds: u32) -> Result<Self, DriftError> {
        let mut spec = Self {
            seed,
            pulse_count: 1,
            pulse_frames: STIMULUS_SAMPLE_RATE / 4,
            period_frames: 20 * STIMULUS_SAMPLE_RATE,
            lead_in_frames: 5 * STIMULUS_SAMPLE_RATE,
            chip_frames: STIMULUS_SAMPLE_RATE / 1_000,
            start_hz: 500.0,
            end_hz: 8_000.0,
            amplitude: 0.25,
        };
        let total = u64::from(seconds.min(MAX_STIMULUS_SECONDS)) * u64::from(STIMULUS_SAMPLE_RATE);
        let usable = total
            .checked_sub(u64::from(spec.lead_in_frames) + u64::from(spec.pulse_frames))
            .ok_or(DriftError::Invalid(
                "the stimulus is shorter than one pulse",
            ))?;
        spec.pulse_count = u32::try_from(usable / u64::from(spec.period_frames) + 1)
            .map_err(|_| DriftError::Invalid("the stimulus is too long"))?;
        spec.validate()?;
        Ok(spec)
    }

    pub fn validate(&self) -> Result<(), DriftError> {
        let nyquist = f64::from(STIMULUS_SAMPLE_RATE) / 2.0;
        let valid = self.pulse_count > 0
            && self.chip_frames > 0
            && self.pulse_frames >= 2 * EDGE_FRAMES
            && self.pulse_frames.is_multiple_of(self.chip_frames)
            && self.period_frames > self.pulse_frames
            && self.period_frames <= MAX_PERIOD_FRAMES
            && self.start_hz > 0.0
            && self.end_hz > self.start_hz
            && self.end_hz < nyquist
            && self.amplitude > 0.0
            && self.amplitude <= 0.5
            && self.total_frames()
                <= u64::from(MAX_STIMULUS_SECONDS) * u64::from(STIMULUS_SAMPLE_RATE);
        if valid {
            Ok(())
        } else {
            Err(DriftError::Invalid("the stimulus spec is out of range"))
        }
    }

    #[must_use]
    pub fn pulse_start_frame(&self, index: u32) -> u64 {
        u64::from(self.lead_in_frames) + u64::from(index) * u64::from(self.period_frames)
    }

    #[must_use]
    pub fn total_frames(&self) -> u64 {
        self.pulse_start_frame(self.pulse_count.saturating_sub(1)) + u64::from(self.pulse_frames)
    }

    /// One pulse's samples in `[-amplitude, amplitude]`.
    #[must_use]
    pub fn template(&self, index: u32) -> Vec<f64> {
        let mut state = self.seed ^ (u64::from(index) + 1).wrapping_mul(0x9E37_79B9_7F4A_7C15);
        let chips: Vec<f64> = (0..self.pulse_frames / self.chip_frames)
            .map(|_| {
                if split_mix(&mut state) & 1 == 0 {
                    -1.0
                } else {
                    1.0
                }
            })
            .collect();
        let rate = f64::from(STIMULUS_SAMPLE_RATE);
        let duration = f64::from(self.pulse_frames) / rate;
        let sweep = (self.end_hz - self.start_hz) / (2.0 * duration);
        (0..self.pulse_frames)
            .map(|frame| {
                let time = f64::from(frame) / rate;
                let phase = std::f64::consts::TAU * (self.start_hz * time + sweep * time * time);
                let from_edge = frame.min(self.pulse_frames - 1 - frame);
                let window = if from_edge < EDGE_FRAMES {
                    0.5 - 0.5
                        * (std::f64::consts::PI * f64::from(from_edge) / f64::from(EDGE_FRAMES))
                            .cos()
                } else {
                    1.0
                };
                self.amplitude * window * chips[(frame / self.chip_frames) as usize] * phase.sin()
            })
            .collect()
    }

    #[must_use]
    pub fn to_json(&self, wav_sha256: &str) -> Value {
        json!({
            "schema": DRIFT_STIMULUS_SCHEMA,
            "generator": GENERATOR,
            "generator_version": GENERATOR_VERSION,
            "seed": self.seed.to_string(),
            "sample_rate_hz": STIMULUS_SAMPLE_RATE,
            "pcm_format": "wav-s16le-mono",
            "pulse_count": self.pulse_count,
            "pulse_frames": self.pulse_frames,
            "period_frames": self.period_frames,
            "lead_in_frames": self.lead_in_frames,
            "chip_frames": self.chip_frames,
            "start_hz": self.start_hz,
            "end_hz": self.end_hz,
            "amplitude": self.amplitude,
            "total_frames": self.total_frames(),
            "wav_sha256": wav_sha256,
        })
    }

    /// Reads a stimulus record; returns the spec and the WAV digest it names.
    pub fn from_json(value: &Value) -> Result<(Self, String), DriftError> {
        let invalid = || DriftError::Invalid("the stimulus record is malformed");
        if value["schema"] != DRIFT_STIMULUS_SCHEMA
            || value["generator_version"] != GENERATOR_VERSION
            || value["sample_rate_hz"] != STIMULUS_SAMPLE_RATE
        {
            return Err(DriftError::Invalid(
                "the stimulus record's version is unsupported",
            ));
        }
        let unsigned = |key: &str| {
            value[key]
                .as_u64()
                .and_then(|number| u32::try_from(number).ok())
                .ok_or_else(invalid)
        };
        let float = |key: &str| value[key].as_f64().ok_or_else(invalid);
        let spec = Self {
            seed: value["seed"]
                .as_str()
                .and_then(|seed| seed.parse().ok())
                .ok_or_else(invalid)?,
            pulse_count: unsigned("pulse_count")?,
            pulse_frames: unsigned("pulse_frames")?,
            period_frames: unsigned("period_frames")?,
            lead_in_frames: unsigned("lead_in_frames")?,
            chip_frames: unsigned("chip_frames")?,
            start_hz: float("start_hz")?,
            end_hz: float("end_hz")?,
            amplitude: float("amplitude")?,
        };
        spec.validate()?;
        let digest = value["wav_sha256"]
            .as_str()
            .filter(|digest| digest.len() == 64 && digest.bytes().all(|b| b.is_ascii_hexdigit()))
            .ok_or_else(invalid)?
            .to_owned();
        Ok((spec, digest))
    }
}

/// Writes the full stimulus as 16-bit mono WAV and returns its SHA-256.
pub fn write_stimulus_wav(spec: &StimulusSpec, destination: &Path) -> Result<String, DriftError> {
    spec.validate()?;
    let mut hasher = Sha256::new();
    write_atomically_with(destination, |file| {
        let mut out = io::BufWriter::with_capacity(1 << 20, file);
        stream_stimulus(spec, &mut |bytes| {
            hasher.update(bytes);
            out.write_all(bytes)
        })?;
        out.flush()
    })
    .map_err(|error| match error {
        crate::TranscriptExportError::Io(error) => DriftError::Io(error),
        _ => DriftError::Invalid("the stimulus destination is invalid"),
    })?;
    Ok(hex(&hasher.finalize()))
}

/// The SHA-256 the spec's WAV must have, computed without writing it.
pub fn stimulus_sha256(spec: &StimulusSpec) -> Result<String, DriftError> {
    spec.validate()?;
    let mut hasher = Sha256::new();
    stream_stimulus(spec, &mut |bytes| {
        hasher.update(bytes);
        Ok(())
    })?;
    Ok(hex(&hasher.finalize()))
}

fn stream_stimulus(
    spec: &StimulusSpec,
    sink: &mut dyn FnMut(&[u8]) -> io::Result<()>,
) -> io::Result<()> {
    let data_bytes = u32::try_from(spec.total_frames() * 2)
        .ok()
        .filter(|bytes| *bytes <= u32::MAX - 36)
        .ok_or_else(|| io::Error::other("stimulus exceeds one WAV file"))?;
    let mut header = Vec::with_capacity(44);
    header.extend_from_slice(b"RIFF");
    header.extend_from_slice(&(36 + data_bytes).to_le_bytes());
    header.extend_from_slice(b"WAVEfmt ");
    header.extend_from_slice(&16_u32.to_le_bytes());
    header.extend_from_slice(&1_u16.to_le_bytes());
    header.extend_from_slice(&1_u16.to_le_bytes());
    header.extend_from_slice(&STIMULUS_SAMPLE_RATE.to_le_bytes());
    header.extend_from_slice(&(STIMULUS_SAMPLE_RATE * 2).to_le_bytes());
    header.extend_from_slice(&2_u16.to_le_bytes());
    header.extend_from_slice(&16_u16.to_le_bytes());
    header.extend_from_slice(b"data");
    header.extend_from_slice(&data_bytes.to_le_bytes());
    sink(&header)?;
    let silence = vec![0_u8; 1 << 16];
    let mut written = 0_u64;
    let pad = |sink: &mut dyn FnMut(&[u8]) -> io::Result<()>, frames: u64| {
        let mut remaining = frames * 2;
        while remaining > 0 {
            let chunk = remaining.min(silence.len() as u64) as usize;
            sink(&silence[..chunk])?;
            remaining -= chunk as u64;
        }
        Ok::<(), io::Error>(())
    };
    for index in 0..spec.pulse_count {
        pad(sink, spec.pulse_start_frame(index) - written)?;
        let bytes: Vec<u8> = spec
            .template(index)
            .iter()
            .flat_map(|sample| quantize(*sample).to_le_bytes())
            .collect();
        sink(&bytes)?;
        written = spec.pulse_start_frame(index) + u64::from(spec.pulse_frames);
    }
    Ok(())
}

fn quantize(sample: f64) -> i16 {
    (sample * 32_767.0).round().clamp(-32_768.0, 32_767.0) as i16
}

/// SplitMix64: small, well distributed, and identical everywhere.
fn split_mix(state: &mut u64) -> u64 {
    *state = state.wrapping_add(0x9E37_79B9_7F4A_7C15);
    let mut value = *state;
    value = (value ^ (value >> 30)).wrapping_mul(0xBF58_476D_1CE4_E5B9);
    value = (value ^ (value >> 27)).wrapping_mul(0x94D0_49BB_1331_11EB);
    value ^ (value >> 31)
}

pub(crate) fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|byte| format!("{byte:02x}")).collect()
}
