//! Source media is 48 kHz signed 16-bit PCM; Whisper consumes 16 kHz mono
//! f32. Conversion reads sealed samples and never writes source media.

use std::sync::OnceLock;

pub const SOURCE_SAMPLE_RATE_HZ: u32 = 48_000;
pub const MODEL_SAMPLE_RATE_HZ: u32 = 16_000;
pub const DECIMATION_FACTOR: usize = 3;

const TAPS: usize = 127;
const HALF: usize = TAPS / 2;
const CUTOFF_HZ: f64 = 7_200.0;

fn taps() -> &'static [f32; TAPS] {
    static TAPS_CELL: OnceLock<[f32; TAPS]> = OnceLock::new();
    TAPS_CELL.get_or_init(|| {
        // Blackman-windowed sinc low-pass, normalized to unity DC gain.
        let cutoff = CUTOFF_HZ / f64::from(SOURCE_SAMPLE_RATE_HZ);
        let mut raw = [0.0_f64; TAPS];
        for (index, tap) in raw.iter_mut().enumerate() {
            let n = index as f64 - HALF as f64;
            let sinc = if n == 0.0 {
                2.0 * cutoff
            } else {
                (2.0 * std::f64::consts::PI * cutoff * n).sin() / (std::f64::consts::PI * n)
            };
            let phase = 2.0 * std::f64::consts::PI * index as f64 / (TAPS - 1) as f64;
            let window = 0.42 - 0.5 * phase.cos() + 0.08 * (2.0 * phase).cos();
            *tap = sinc * window;
        }
        let sum: f64 = raw.iter().sum();
        let mut out = [0.0_f32; TAPS];
        for (target, value) in out.iter_mut().zip(raw) {
            *target = (value / sum) as f32;
        }
        out
    })
}

/// Converts one contiguous span of interleaved 48 kHz samples into 16 kHz
/// mono. Output sample `j` is centered on source frame `3j`; frames outside
/// the span are treated as silence, so any output range can be produced
/// independently and identically.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct Decimator {
    span_frames: u64,
}

impl Decimator {
    pub fn new(span_frames: u64) -> Self {
        Self { span_frames }
    }

    /// Number of 16 kHz samples the span yields.
    pub fn output_len(self) -> u64 {
        self.span_frames.div_ceil(DECIMATION_FACTOR as u64)
    }

    /// Source frames needed to produce outputs `[start, end)`, clamped to the span.
    pub fn source_window(self, start: u64, end: u64) -> (u64, u64) {
        let first = (start * DECIMATION_FACTOR as u64).saturating_sub(HALF as u64);
        let last = (end.saturating_sub(1) * DECIMATION_FACTOR as u64 + HALF as u64 + 1)
            .min(self.span_frames);
        (first.min(last), last)
    }

    /// `interleaved` must hold exactly the frames of `source_window(start, end)`.
    pub fn convert(
        self,
        interleaved: &[i16],
        channels: u16,
        start: u64,
        end: u64,
    ) -> Result<Vec<f32>, &'static str> {
        if channels == 0 {
            return Err("channel count is zero");
        }
        let (first, last) = self.source_window(start, end);
        let channels = usize::from(channels);
        if interleaved.len() != (last - first) as usize * channels {
            return Err("source window length does not match the requested range");
        }
        let scale = 1.0 / (32_768.0 * channels as f32);
        let mono: Vec<f32> = interleaved
            .chunks_exact(channels)
            .map(|frame| frame.iter().map(|&sample| f32::from(sample)).sum::<f32>() * scale)
            .collect();
        let taps = taps();
        let mut output = Vec::with_capacity(end.saturating_sub(start) as usize);
        for index in start..end {
            let center = index as i64 * DECIMATION_FACTOR as i64;
            let mut acc = 0.0_f32;
            for (tap_index, tap) in taps.iter().enumerate() {
                let frame = center + tap_index as i64 - HALF as i64;
                if frame >= first as i64 && frame < last as i64 {
                    acc += tap * mono[(frame - first as i64) as usize];
                }
            }
            output.push(acc);
        }
        Ok(output)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn tone(frequency: f64, frames: usize, channels: usize) -> Vec<i16> {
        (0..frames)
            .flat_map(|frame| {
                let value = (2.0 * std::f64::consts::PI * frequency * frame as f64
                    / f64::from(SOURCE_SAMPLE_RATE_HZ))
                .sin()
                    * 16_000.0;
                std::iter::repeat_n(value as i16, channels)
            })
            .collect()
    }

    fn rms(samples: &[f32]) -> f32 {
        (samples.iter().map(|value| value * value).sum::<f32>() / samples.len() as f32).sqrt()
    }

    fn convert_all(samples: &[i16], channels: u16) -> Vec<f32> {
        let frames = (samples.len() / usize::from(channels)) as u64;
        let decimator = Decimator::new(frames);
        decimator
            .convert(samples, channels, 0, decimator.output_len())
            .unwrap()
    }

    #[test]
    fn speech_band_passes_and_aliasing_band_is_attenuated() {
        let passband = convert_all(&tone(1_000.0, 48_000, 1), 1);
        assert_eq!(passband.len(), 16_000);
        let expected = 16_000.0 / 32_768.0 / std::f32::consts::SQRT_2;
        let middle = &passband[1_000..15_000];
        assert!(
            (rms(middle) - expected).abs() < 0.01 * expected,
            "{}",
            rms(middle)
        );

        let aliasing = convert_all(&tone(12_000.0, 48_000, 1), 1);
        assert!(rms(&aliasing[1_000..15_000]) < 0.001 * expected);
    }

    #[test]
    fn stereo_is_averaged_and_ranges_match_whole_span_conversion() {
        let stereo = tone(440.0, 9_000, 2);
        let whole = convert_all(&stereo, 2);
        let mono = convert_all(&tone(440.0, 9_000, 1), 1);
        assert_eq!(whole, mono);

        let decimator = Decimator::new(9_000);
        let (first, last) = decimator.source_window(700, 1_900);
        let window = &stereo[first as usize * 2..last as usize * 2];
        assert_eq!(
            decimator.convert(window, 2, 700, 1_900).unwrap(),
            whole[700..1_900]
        );
        assert!(decimator.convert(&window[2..], 2, 700, 1_900).is_err());
    }
}
