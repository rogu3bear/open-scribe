//! The two-hour synchronization instrument (ADR 0005; M1 operator session).
//!
//! `stimulus` writes the coded stimulus WAV and its record. `analyze`
//! measures a saved capture against that record and writes the report; it
//! never overwrites existing evidence. Exit 0 is GREEN, 1 is RED, 2 is an
//! unusable invocation or input.

use open_scribe_core::{
    DriftOptions, StimulusSpec, TWO_HOURS_NANOSECONDS, measure_drift, write_stimulus_wav,
};
use open_scribe_store::SessionStore;
use open_scribe_types::SessionId;
use std::fs::{self, OpenOptions};
use std::io::Write;
use std::path::PathBuf;
use std::process::ExitCode;

const USAGE: &str = "usage:
  open-scribe-drift stimulus --seed N --seconds S --out NEW_DIRECTORY
  open-scribe-drift analyze --library ROOT --session ID --stimulus STIMULUS_JSON --out NEW_REPORT [--required-coverage-seconds N]";

fn main() -> ExitCode {
    let arguments: Vec<String> = std::env::args().skip(1).collect();
    match run(&arguments) {
        Ok(code) => code,
        Err(message) => {
            eprintln!("DRIFT_INSTRUMENT_RED: {message}\n{USAGE}");
            ExitCode::from(2)
        }
    }
}

fn option<'a>(arguments: &'a [String], name: &str) -> Result<&'a str, String> {
    arguments
        .windows(2)
        .find(|pair| pair[0] == name)
        .map(|pair| pair[1].as_str())
        .ok_or_else(|| format!("{name} is required"))
}

fn run(arguments: &[String]) -> Result<ExitCode, String> {
    match arguments.first().map(String::as_str) {
        Some("stimulus") => {
            let seed: u64 = option(arguments, "--seed")?
                .parse()
                .map_err(|_| "--seed must be an unsigned integer".to_owned())?;
            let seconds: u32 = option(arguments, "--seconds")?
                .parse()
                .map_err(|_| "--seconds must be an unsigned integer".to_owned())?;
            let directory = PathBuf::from(option(arguments, "--out")?);
            let spec = StimulusSpec::covering(seed, seconds).map_err(|error| error.to_string())?;
            fs::create_dir(&directory).map_err(|error| format!("cannot create --out: {error}"))?;
            let digest = write_stimulus_wav(&spec, &directory.join("stimulus.wav"))
                .map_err(|error| error.to_string())?;
            write_new(
                &directory.join("stimulus.json"),
                &serde_json::to_vec_pretty(&spec.to_json(&digest))
                    .map_err(|error| error.to_string())?,
            )?;
            println!(
                "DRIFT_STIMULUS_READY pulses={} frames={} sha256={digest}",
                spec.pulse_count,
                spec.total_frames()
            );
            Ok(ExitCode::SUCCESS)
        }
        Some("analyze") => {
            let record: serde_json::Value = serde_json::from_slice(
                &fs::read(option(arguments, "--stimulus")?)
                    .map_err(|error| format!("cannot read --stimulus: {error}"))?,
            )
            .map_err(|_| "the stimulus record is not JSON".to_owned())?;
            let (spec, played_sha256) =
                StimulusSpec::from_json(&record).map_err(|error| error.to_string())?;
            let required = match option(arguments, "--required-coverage-seconds") {
                Ok(seconds) => seconds
                    .parse::<i64>()
                    .map_err(|_| "--required-coverage-seconds must be an integer".to_owned())?
                    .checked_mul(1_000_000_000)
                    .ok_or("--required-coverage-seconds is too large")?,
                Err(_) => TWO_HOURS_NANOSECONDS,
            };
            let store = SessionStore::open(option(arguments, "--library")?)
                .map_err(|error| error.to_string())?;
            let report = measure_drift(
                &store,
                &SessionId(option(arguments, "--session")?.to_owned()),
                &spec,
                &played_sha256,
                DriftOptions {
                    required_coverage_nanoseconds: required,
                },
            )
            .map_err(|error| error.to_string())?;
            let output = PathBuf::from(option(arguments, "--out")?);
            write_new(
                &output,
                &serde_json::to_vec_pretty(&report.document).map_err(|error| error.to_string())?,
            )?;
            let summary = &report.document["summary"];
            println!(
                "{}\nreasons={}\npulses={}/{} coverage_ns={} max_abs_offset_ns={} max_abs_drift_ns={}\nreport={}",
                report.document["result"].as_str().unwrap_or_default(),
                report.reasons.join(","),
                summary["pulses_detected_in_both"],
                summary["pulses_expected"],
                summary["coverage_ns"],
                summary["max_abs_offset_ns"],
                summary["max_abs_drift_ns"],
                output.display()
            );
            Ok(if report.passed {
                ExitCode::SUCCESS
            } else {
                ExitCode::from(1)
            })
        }
        _ => Err("expected stimulus or analyze".to_owned()),
    }
}

/// Evidence is written once; an existing file is never replaced.
fn write_new(path: &std::path::Path, bytes: &[u8]) -> Result<(), String> {
    let mut file = OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(path)
        .map_err(|error| format!("cannot create {}: {error}", path.display()))?;
    file.write_all(bytes)
        .and_then(|()| file.sync_all())
        .map_err(|error| format!("cannot write {}: {error}", path.display()))
}
