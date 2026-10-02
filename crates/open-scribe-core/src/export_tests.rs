use super::*;
use crate::transcription::tests::{BurstRecognizer, Imported, SECOND, imported, run};
use open_scribe_asr::RecognizerError;
use sha2::{Digest, Sha256};
use std::collections::BTreeSet;
use tempfile::TempDir;

const EXPORTED_AT_MS: i64 = 1_790_000_000_000;

fn transcribed(seconds: u64) -> (Imported, String) {
    let mut imported = imported(seconds);
    let outcome = run(&mut imported, &mut BurstRecognizer::new(&"a".repeat(64))).unwrap();
    (imported, outcome.revision_id)
}

fn collect(imported: &Imported) -> TranscriptExport {
    TranscriptExport::collect(&imported.store, &imported.session, EXPORTED_AT_MS).unwrap()
}

fn keys(value: &Value) -> BTreeSet<String> {
    value.as_object().unwrap().keys().cloned().collect()
}

fn schema_keys(schema: &Value, field: &str) -> BTreeSet<String> {
    match field {
        "required" => schema["required"]
            .as_array()
            .unwrap()
            .iter()
            .map(|key| key.as_str().unwrap().to_owned())
            .collect(),
        _ => keys(&schema["properties"]),
    }
}

/// Every required key is present and nothing outside the declared
/// properties appears, for the envelope, each track, and each segment.
fn assert_matches_schema(document: &Value) {
    let schema: Value = serde_json::from_str(TRANSCRIPT_V1_SCHEMA_JSON).unwrap();
    let levels = [
        (&schema, vec![document]),
        (
            &schema["properties"]["tracks"]["items"],
            document["tracks"].as_array().unwrap().iter().collect(),
        ),
        (
            &schema["properties"]["segments"]["items"],
            document["segments"].as_array().unwrap().iter().collect(),
        ),
    ];
    for (level, values) in levels {
        for value in values {
            let present = keys(value);
            assert!(
                schema_keys(level, "required").is_subset(&present),
                "{value}"
            );
            assert!(
                present.is_subset(&schema_keys(level, "properties")),
                "{value}"
            );
        }
    }
    let evidence_required = schema_keys(
        &schema["properties"]["segments"]["items"]["properties"]["evidence_ref"],
        "required",
    );
    for segment in document["segments"].as_array().unwrap() {
        assert!(evidence_required.is_subset(&keys(&segment["evidence_ref"])));
    }
}

fn cue_times(rendered: &str, separator: char) -> Vec<(String, String)> {
    rendered
        .lines()
        .filter(|line| line.contains(" --> "))
        .map(|line| {
            let (start, end) = line.split_once(" --> ").unwrap();
            for stamp in [start, end] {
                assert_eq!(stamp.len(), 12, "{line}");
                assert_eq!(stamp.chars().nth(8), Some(separator), "{line}");
            }
            (start.to_owned(), end.to_owned())
        })
        .collect()
}

#[test]
fn every_format_renders_the_selected_final_transcript_with_provenance() {
    let (mut imported, revision) = transcribed(90);
    let (session, track) = (imported.session.clone(), imported.track.clone());
    imported
        .store
        .correct_transcript_segment(&session, &revision, 1, Some("Burst two"))
        .unwrap();
    imported
        .store
        .rename_speaker(&session, &track, Some("Dana"))
        .unwrap();
    let export = collect(&imported);
    assert_eq!(export.availability(), TranscriptAvailability::Final);

    let text = export.render(TranscriptExportFormat::PlainText).unwrap();
    for expected in [
        "Bursts\n",
        "Transcript: Final\n",
        "Model (Dana): burst-model · burst-fixture 1\n",
        "Duration: 00:01:30\n",
        "Speakers: named by the user\n",
        "Human corrections: 1 of 3 segments\n",
        "Exported: 2026-09-21T14:13:20.000Z\n",
        "] Dana: burst\n",
        "] Dana: Burst two (corrected)\n",
    ] {
        assert!(text.contains(expected), "{expected:?} missing from\n{text}");
    }

    let markdown = export.render(TranscriptExportFormat::Markdown).unwrap();
    assert!(markdown.starts_with("# Bursts\n\n- Session: "));
    assert!(markdown.contains(" Dana:** Burst two _(corrected)_\n\n"));
    assert_eq!(text.matches("] Dana: ").count(), 3);

    let vtt = export.render(TranscriptExportFormat::WebVtt).unwrap();
    assert!(vtt.starts_with("WEBVTT\n\nNOTE\n"));
    assert!(vtt.contains("<v Dana>Burst two</v>\n"));
    let vtt_cues = cue_times(&vtt, '.');
    assert_eq!(vtt_cues.len(), 3);
    assert!(vtt_cues.iter().all(|(start, end)| start < end));
    assert!(vtt_cues.windows(2).all(|pair| pair[0].0 <= pair[1].0));

    let srt = export.render(TranscriptExportFormat::SubRip).unwrap();
    assert!(srt.starts_with("1\n00:00:0"));
    assert!(srt.contains("\n2\n00:00:2"));
    assert!(srt.contains("Dana: Burst two\n\n"));
    assert_eq!(cue_times(&srt, ',').len(), 3);

    let json: Value = serde_json::from_str(
        &export
            .render(TranscriptExportFormat::TranscriptJson)
            .unwrap(),
    )
    .unwrap();
    assert_matches_schema(&json);
    assert_eq!(
        json["schema"],
        "https://open-scribe.app/schema/transcript/v1"
    );
    assert_eq!(json["availability"], "final");
    assert_eq!(json["speakers_declaration"], "user_adjudicated");
    assert_eq!(json["duration_ns"], 90 * SECOND);
    assert_eq!(json["session"]["id"], session.0.as_str());
    let tracks = json["tracks"].as_array().unwrap();
    assert_eq!(tracks.len(), 1);
    assert_eq!(tracks[0]["finality"], "final");
    assert_eq!(tracks[0]["revision"]["model_id"], "burst-model");
    assert_eq!(tracks[0]["revision"]["language"], "en");
    assert_eq!(
        tracks[0]["input_digest"],
        tracks[0]["revision"]["input_digest"]
    );
    let segments = json["segments"].as_array().unwrap();
    assert_eq!(segments.len(), 3);
    assert_eq!(segments[1]["verbatim_text"], "burst");
    assert_eq!(segments[1]["effective_text"], "Burst two");
    assert_eq!(segments[1]["correction"]["origin"], "human");
    assert!(segments[0]["correction"].is_null());
    assert_eq!(segments[1]["speaker"]["origin"], "human");
    let reference = EvidenceRef::parse(&segments[1]["evidence_ref"].to_string()).unwrap();
    assert_eq!(reference.revision_id.as_deref(), Some(revision.as_str()));
    assert_eq!(reference.sub_item.as_deref(), Some("1"));
    let verbatim_digest: String = Sha256::digest(b"burst")
        .iter()
        .map(|byte| format!("{byte:02x}"))
        .collect();
    assert_eq!(reference.content_digest, verbatim_digest);
}

#[test]
fn unavailable_and_failed_transcripts_are_disclosed_without_invented_text() {
    let mut imported = imported(10);
    let export = collect(&imported);
    assert_eq!(export.availability(), TranscriptAvailability::Unavailable);
    let text = export.render(TranscriptExportFormat::PlainText).unwrap();
    assert!(text.contains("Transcript: Unavailable\n"));
    assert!(text.contains("Human corrections: 0 of 0 segments\n"));
    assert!(!text.contains("] "));
    let vtt = export.render(TranscriptExportFormat::WebVtt).unwrap();
    assert!(!vtt.contains(" --> "));
    assert!(
        export
            .render(TranscriptExportFormat::SubRip)
            .unwrap()
            .is_empty()
    );
    let json: Value = serde_json::from_str(
        &export
            .render(TranscriptExportFormat::TranscriptJson)
            .unwrap(),
    )
    .unwrap();
    assert_matches_schema(&json);
    assert_eq!(json["tracks"][0]["finality"], "pending");
    assert!(json["tracks"][0]["revision"].is_null());
    assert_eq!(json["speakers_declaration"], "anonymous");
    assert!(json["segments"].as_array().unwrap().is_empty());

    let mut failing =
        BurstRecognizer::failing(&"a".repeat(64), 1, RecognizerError::Engine("fixture"));
    assert!(run(&mut imported, &mut failing).is_err());
    let export = collect(&imported);
    assert_eq!(export.availability(), TranscriptAvailability::Failed);
    let json: Value = serde_json::from_str(
        &export
            .render(TranscriptExportFormat::TranscriptJson)
            .unwrap(),
    )
    .unwrap();
    assert_eq!(json["availability"], "failed");
    assert_eq!(json["tracks"][0]["finality"], "failed");
}

#[test]
fn markup_and_cue_syntax_in_corrections_stay_literal() {
    let (mut imported, revision) = transcribed(30);
    let session = imported.session.clone();
    imported
        .store
        .correct_transcript_segment(&session, &revision, 0, Some("<b>&\"-->\n\n*x*"))
        .unwrap();
    let export = collect(&imported);

    let vtt = export.render(TranscriptExportFormat::WebVtt).unwrap();
    assert!(vtt.contains("\n&lt;b&gt;&amp;\"--&gt; *x*\n"), "{vtt}");
    assert!(
        !vtt.contains("<v "),
        "an unknown imported speaker is not prefixed"
    );
    assert_eq!(cue_times(&vtt, '.').len(), 2);

    let markdown = export.render(TranscriptExportFormat::Markdown).unwrap();
    assert!(markdown.contains("Unknown speaker:** \\<b\\>&\"--\\> \\*x\\* _(corrected)_"));
    let srt = export.render(TranscriptExportFormat::SubRip).unwrap();
    assert!(srt.contains("\n<b>&\"--> *x*\n\n"), "{srt}");
    assert!(!srt.contains("Unknown speaker"));
}

#[test]
fn writes_are_atomic_and_invalid_destinations_are_rejected() {
    let (imported, _) = transcribed(30);
    let directory = TempDir::new().unwrap();
    let destination = directory.path().join("Bursts.json");
    std::fs::write(&destination, b"stale").unwrap();
    let receipt = write_transcript_export(
        &imported.store,
        &imported.session,
        TranscriptExportFormat::TranscriptJson,
        &destination,
    )
    .unwrap();
    let written = std::fs::read(&destination).unwrap();
    assert_eq!(receipt.byte_length, written.len() as u64);
    assert_eq!(receipt.segment_count, 2);
    assert_eq!(receipt.availability, TranscriptAvailability::Final);
    assert_matches_schema(&serde_json::from_slice(&written).unwrap());
    let entries: Vec<_> = std::fs::read_dir(directory.path())
        .unwrap()
        .map(|entry| entry.unwrap().file_name())
        .collect();
    assert_eq!(entries, ["Bursts.json"]);

    for invalid in [
        directory.path().join("missing").join("out.txt"),
        directory.path().to_path_buf(),
        directory.path().join(".hidden.txt"),
    ] {
        assert!(matches!(
            write_transcript_export(
                &imported.store,
                &imported.session,
                TranscriptExportFormat::PlainText,
                &invalid,
            ),
            Err(TranscriptExportError::InvalidDestination(_))
        ));
    }
    let unknown = SessionId("01a0ef0d-2600-76c4-8f7e-de8905518c51".into());
    assert!(matches!(
        write_transcript_export(
            &imported.store,
            &unknown,
            TranscriptExportFormat::PlainText,
            &directory.path().join("unknown.txt"),
        ),
        Err(TranscriptExportError::Store(StoreError::InvalidState(_)))
    ));
    assert_eq!(std::fs::read_dir(directory.path()).unwrap().count(), 1);
}

#[test]
fn timestamps_render_in_utc_and_clock_units() {
    assert_eq!(rfc3339_utc(0), "1970-01-01T00:00:00.000Z");
    assert_eq!(rfc3339_utc(951_782_400_000), "2000-02-29T00:00:00.000Z");
    assert_eq!(rfc3339_utc(-1), "1969-12-31T23:59:59.999Z");
    assert_eq!(rfc3339_utc(EXPORTED_AT_MS), "2026-09-21T14:13:20.000Z");
    assert_eq!(clock_seconds(3_725 * SECOND + 999), "01:02:05");
    assert_eq!(clock_milliseconds(3_725_042, ','), "01:02:05,042");
    assert_eq!(clock_milliseconds(59_999, '.'), "00:00:59.999");
    assert_eq!(TranscriptExportFormat::SubRip.file_extension(), "srt");
}
