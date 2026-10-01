use super::*;
use crate::drift_stimulus::write_stimulus_wav;
use open_scribe_store::{PackageRestoreRequest, RestoredSegment, RestoredTrack, SessionOrigin};
use sha2::{Digest, Sha256};
use std::fs::{self, File};
use std::io::Write;
use std::path::Path;
use tempfile::TempDir;

const RATE: f64 = 48_000.0;

/// Eight pulses two seconds apart: a short stand-in for the two-hour run.
fn spec() -> StimulusSpec {
    StimulusSpec {
        seed: 20_260_930,
        pulse_count: 8,
        pulse_frames: 12_000,
        period_frames: 96_000,
        lead_in_frames: 24_000,
        chip_frames: 48,
        start_hz: 500.0,
        end_hz: 8_000.0,
        amplitude: 0.25,
    }
}

fn played(spec: &StimulusSpec) -> Vec<f64> {
    let mut samples = vec![0.0; spec.total_frames() as usize];
    for index in 0..spec.pulse_count {
        let start = spec.pulse_start_frame(index) as usize;
        for (offset, sample) in spec.template(index).into_iter().enumerate() {
            samples[start + offset] = sample;
        }
    }
    samples
}

fn write_caf(path: &Path, channels: u32, frames: &[Vec<f64>]) -> (u64, String) {
    let mut file = File::create(path).unwrap();
    file.write_all(b"caff\0\x01\0\0desc").unwrap();
    file.write_all(&32_i64.to_be_bytes()).unwrap();
    file.write_all(&48_000_f64.to_bits().to_be_bytes()).unwrap();
    file.write_all(b"lpcm").unwrap();
    for value in [2_u32, 2 * channels, 1, channels, 16] {
        file.write_all(&value.to_be_bytes()).unwrap();
    }
    file.write_all(b"data").unwrap();
    file.write_all(&(-1_i64).to_be_bytes()).unwrap();
    file.write_all(&0_u32.to_be_bytes()).unwrap();
    let bytes: Vec<u8> = frames
        .iter()
        .flat_map(|frame| {
            frame
                .iter()
                .map(|s| (s * 32_767.0).round().clamp(-32_768.0, 32_767.0) as i16)
        })
        .flat_map(i16::to_le_bytes)
        .collect();
    file.write_all(&bytes).unwrap();
    file.sync_all().unwrap();
    let written = fs::read(path).unwrap();
    (
        written.len() as u64,
        Sha256::digest(&written)
            .iter()
            .map(|byte| format!("{byte:02x}"))
            .collect(),
    )
}

/// One synthetic track: its samples, where it starts on the session
/// timeline, and an optional declared re-anchoring of one segment's native
/// start that does not move the audio.
struct SyntheticTrack {
    kind: &'static str,
    channels: u32,
    start_ns: i64,
    samples: Vec<f64>,
    /// (segment index, declared native-start shift).
    reanchor: Option<(usize, i64)>,
}

fn segment_bounds(length: usize, avoid: &[(usize, usize)]) -> Vec<(usize, usize)> {
    let mut bounds = Vec::new();
    let mut start = 0;
    while start < length {
        let mut end = (start + 4 * 48_000).min(length);
        // Never split a pulse between two segments.
        while let Some((_, pulse_end)) = avoid.iter().find(|(s, e)| *s < end && end < *e) {
            end = (*pulse_end).min(length);
        }
        bounds.push((start, end));
        start = end;
    }
    bounds
}

fn restore(
    tracks: &[SyntheticTrack],
    avoid: &[Vec<(usize, usize)>],
) -> (TempDir, SessionStore, SessionId) {
    let temp = TempDir::new().unwrap();
    let mut restored = Vec::new();
    for (index, track) in tracks.iter().enumerate() {
        let mut segments = Vec::new();
        for (sequence, (start, end)) in segment_bounds(track.samples.len(), &avoid[index])
            .into_iter()
            .enumerate()
        {
            let path = temp.path().join(format!("{}-{sequence}.caf", track.kind));
            let frames: Vec<Vec<f64>> = track.samples[start..end]
                .iter()
                .map(|sample| vec![*sample; track.channels as usize])
                .collect();
            let (byte_length, digest_sha256) = write_caf(&path, track.channels, &frames);
            let shift = match track.reanchor {
                Some((segment, shift)) if sequence >= segment => shift,
                _ => 0,
            };
            segments.push(RestoredSegment {
                source_segment_id: format!("{}-{sequence}", track.kind),
                sequence: sequence as u64,
                start_nanoseconds: track.start_ns
                    + (start as f64 * 1e9 / RATE).round() as i64
                    + shift,
                sample_count: (end - start) as u64,
                channels: track.channels as u16,
                byte_length,
                digest_sha256,
                path,
            });
        }
        restored.push(RestoredTrack {
            source_track_id: format!("track-{}", track.kind),
            source_id: format!("source-{}", track.kind),
            source_kind: track.kind.into(),
            human_speaker_label: None,
            segments,
            transcript: None,
        });
    }
    let mut store = SessionStore::open(temp.path().join("Open Scribe")).unwrap();
    let session = store
        .restore_portable_session(&PackageRestoreRequest {
            title: "Drift fixture".into(),
            origin: SessionOrigin::Capture,
            source_session_id: "drift-fixture".into(),
            source_created_at_ms: 0,
            package_sha256: "a".repeat(64),
            tracks: restored,
            markers: Vec::new(),
        })
        .unwrap()
        .session_id;
    (temp, store, session)
}

struct Fixture {
    _temp: TempDir,
    store: SessionStore,
    session: SessionId,
    /// Expected `microphone - computer` per pulse, in nanoseconds.
    expected_offsets: Vec<i64>,
}

const COMPUTER_START_NS: i64 = 1_000_000_000;
const MICROPHONE_START_NS: i64 = 1_200_000_000;
const PLAYBACK_LEAD_FRAMES: usize = 48_000;
const LATENCY_FRAMES: usize = 144; // 3 ms speaker-to-microphone

/// A capture where the microphone hears the stimulus 3 ms late, drifts a
/// further 12 frames (0.25 ms) per pulse, carries an echo and noise, and
/// one microphone segment declares a shifted native start.
fn capture(reanchor_ns: i64, silence_pulse: Option<u32>) -> Fixture {
    let spec = spec();
    let stimulus = played(&spec);
    let computer_len = PLAYBACK_LEAD_FRAMES + stimulus.len() + 48_000;
    let mut computer = vec![0.0; computer_len];
    computer[PLAYBACK_LEAD_FRAMES..PLAYBACK_LEAD_FRAMES + stimulus.len()]
        .iter_mut()
        .zip(&stimulus)
        .for_each(|(slot, sample)| *slot = 0.9 * sample);
    let computer_pulses: Vec<(usize, usize)> = (0..spec.pulse_count)
        .map(|i| {
            let start = PLAYBACK_LEAD_FRAMES + spec.pulse_start_frame(i) as usize;
            (start, start + spec.pulse_frames as usize)
        })
        .collect();

    // The microphone starts 0.2 s later on the session timeline.
    let mic_offset_frames =
        ((MICROPHONE_START_NS - COMPUTER_START_NS) as f64 * RATE / 1e9) as usize;
    let mut microphone = vec![0.0; computer_len];
    let mut noise_state = 12_345_u64;
    for sample in &mut microphone {
        noise_state = noise_state
            .wrapping_mul(6_364_136_223_846_793_005)
            .wrapping_add(1);
        *sample = ((noise_state >> 33) as f64 / f64::from(1_u32 << 31) - 0.5) * 0.02;
    }
    let mut mic_pulses = Vec::new();
    for index in 0..spec.pulse_count {
        if silence_pulse == Some(index) {
            continue;
        }
        let at = computer_pulses[index as usize].0 + LATENCY_FRAMES + 12 * index as usize
            - mic_offset_frames;
        for (offset, sample) in spec.template(index).into_iter().enumerate() {
            microphone[at + offset] += 0.3 * sample;
            microphone[at + offset + 336] += 0.1 * sample; // 7 ms echo
        }
        mic_pulses.push((at, at + spec.pulse_frames as usize + 336));
    }
    let tracks = [
        SyntheticTrack {
            kind: "microphone",
            channels: 1,
            start_ns: MICROPHONE_START_NS,
            samples: microphone,
            reanchor: (reanchor_ns != 0).then_some((2, reanchor_ns)),
        },
        SyntheticTrack {
            kind: "system_audio",
            channels: 2,
            start_ns: COMPUTER_START_NS,
            samples: computer,
            reanchor: None,
        },
    ];
    let (temp, store, session) = restore(&tracks, &[mic_pulses.clone(), computer_pulses.clone()]);
    // Pulses in microphone segments from index 2 on carry the declared shift.
    let mic_bounds = segment_bounds(computer_len, &mic_pulses);
    let shifted_from = mic_bounds.get(2).map_or(usize::MAX, |(start, _)| *start);
    let expected_offsets = (0..spec.pulse_count)
        .map(|index| {
            let at = computer_pulses[index as usize].0 + LATENCY_FRAMES + 12 * index as usize
                - mic_offset_frames;
            let extra = (LATENCY_FRAMES + 12 * index as usize) as f64 * 1e9 / RATE;
            extra.round() as i64 + if at >= shifted_from { reanchor_ns } else { 0 }
        })
        .collect();
    Fixture {
        _temp: temp,
        store,
        session,
        expected_offsets,
    }
}

fn short() -> DriftOptions {
    DriftOptions {
        required_coverage_nanoseconds: 14 * SECOND,
    }
}

fn measure(fixture: &Fixture, options: DriftOptions) -> DriftReport {
    let spec = spec();
    let digest = stimulus_sha256(&spec).unwrap();
    measure_drift(&fixture.store, &fixture.session, &spec, &digest, options).unwrap()
}

#[test]
fn the_stimulus_is_deterministic_versioned_and_uniquely_coded() {
    let spec = spec();
    assert_eq!(spec.template(3), spec.template(3));
    let other = StimulusSpec {
        seed: 1,
        ..spec.clone()
    };
    assert_ne!(spec.template(3), other.template(3));
    // Distinct pulses do not correlate with each other.
    let template = Template::new(spec.template(0));
    for index in 1..spec.pulse_count {
        let peak = template.peak(&spec.template(index)).unwrap();
        assert!(
            peak.correlation.abs() < 0.2,
            "pulse {index}: {}",
            peak.correlation
        );
    }
    assert!((template.peak(&spec.template(0)).unwrap().correlation - 1.0).abs() < 1e-9);

    let temp = TempDir::new().unwrap();
    let wav = temp.path().join("stimulus.wav");
    let digest = write_stimulus_wav(&spec, &wav).unwrap();
    let bytes = fs::read(&wav).unwrap();
    assert_eq!(bytes.len() as u64, 44 + 2 * spec.total_frames());
    assert_eq!(digest, stimulus_sha256(&spec).unwrap());
    assert_eq!(
        digest,
        Sha256::digest(&bytes)
            .iter()
            .map(|byte| format!("{byte:02x}"))
            .collect::<String>()
    );
    let (parsed, parsed_digest) = StimulusSpec::from_json(&spec.to_json(&digest)).unwrap();
    assert_eq!((parsed, parsed_digest), (spec, digest));

    // The production stimulus pulses every 20 s and crosses two hours.
    let two_hours = StimulusSpec::covering(7, 7_260).unwrap();
    assert_eq!(two_hours.pulse_count, 363);
    assert!(two_hours.pulse_start_frame(362) > 7_200 * 48_000);
    assert!(two_hours.total_frames() <= 7_260 * 48_000);
    assert!(
        StimulusSpec {
            period_frames: 31 * 48_000,
            ..two_hours
        }
        .validate()
        .is_err()
    );
}

#[test]
fn latency_and_drift_are_measured_on_each_segments_native_start() {
    let fixture = capture(2_000_000, None);
    let report = measure(&fixture, short());
    assert!(
        report.passed,
        "{:?} {}",
        report.reasons, report.document["summary"]
    );
    let detections = report.document["detections"].as_array().unwrap();
    assert_eq!(detections.len(), 8);
    for (detection, expected) in detections.iter().zip(&fixture.expected_offsets) {
        let measured = detection["offset_ns"].as_i64().unwrap();
        assert!(
            (measured - expected).abs() <= 25_000,
            "pulse {}: measured {measured}, expected {expected}",
            detection["index"]
        );
    }
    let summary = &report.document["summary"];
    assert_eq!(summary["pulses_detected_in_both"], 8);
    assert!(summary["first_offset_ns"].as_i64().unwrap().abs() < 3_100_000);
    // 7 pulses x 0.25 ms of drift, plus the 2 ms declared re-anchoring.
    let drift = summary["max_abs_drift_ns"].as_i64().unwrap();
    assert!((drift - 3_750_000).abs() <= 25_000, "{drift}");
    assert_eq!(
        report.document["tracks"][1]["channel_choice"],
        "mean_of_channels"
    );
}

#[test]
fn drift_beyond_100_ms_fails_and_names_why() {
    let fixture = capture(150_000_000, None);
    let report = measure(&fixture, short());
    assert!(!report.passed);
    assert!(report.reasons.contains(&"drift_over_limit"));
    assert!(report.reasons.contains(&"absolute_offset_over_limit"));
    assert_eq!(report.document["result"], "M1_TWO_HOUR_DRIFT_RED");
}

#[test]
fn a_missing_pulse_short_coverage_or_another_stimulus_fails() {
    let fixture = capture(0, Some(3));
    let report = measure(&fixture, short());
    assert_eq!(report.reasons, ["pulse_missing"]);
    assert_eq!(
        report.document["detections"][3]["microphone"]["status"],
        "missing"
    );
    assert!(report.document["detections"][3]["offset_ns"].is_null());

    let fixture = capture(0, None);
    let report = measure(&fixture, DriftOptions::default());
    assert_eq!(report.reasons, ["coverage_short"]);

    let report = measure_drift(
        &fixture.store,
        &fixture.session,
        &spec(),
        &"0".repeat(64),
        short(),
    )
    .unwrap();
    assert_eq!(report.reasons, ["played_stimulus_differs_from_spec"]);
}

#[test]
fn a_session_without_one_microphone_and_one_computer_track_is_refused() {
    let spec = spec();
    let stimulus = played(&spec);
    let tracks = [SyntheticTrack {
        kind: "microphone",
        channels: 1,
        start_ns: 0,
        samples: stimulus,
        reanchor: None,
    }];
    let (_temp, store, session) = restore(&tracks, &[Vec::new()]);
    assert!(matches!(
        measure_drift(
            &store,
            &session,
            &spec,
            &stimulus_sha256(&spec).unwrap(),
            short()
        ),
        Err(DriftError::Invalid(_))
    ));
}
