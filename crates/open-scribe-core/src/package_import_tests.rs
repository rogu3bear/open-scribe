use crate::package_import::import_portable_package;
use crate::session_export::{SessionExportError, write_portable_package};
use crate::transcribe_track;
use crate::transcription::tests::{BurstRecognizer, imported, write_burst_caf};
use open_scribe_asr::{DecodeOptions, Language};
use open_scribe_evidence::{EvidenceRef, ResolutionState};
use open_scribe_store::{
    DigestedSegment, PackageRestoreRequest, RestoredMarker, RestoredSegment, RestoredTrack,
    SessionOrigin, SessionStore, StoreError, transcription_input_digest,
};
use open_scribe_types::SessionId;
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use std::fs;
use std::path::Path;
use std::sync::atomic::AtomicBool;
use tempfile::TempDir;

const SECOND: i64 = 1_000_000_000;

fn transcribe(store: &mut SessionStore, session: &SessionId, track: &str) {
    transcribe_track(
        store,
        &mut BurstRecognizer::new("model"),
        &DecodeOptions::final_pass(Language::English),
        session,
        track,
        &AtomicBool::new(false),
        &mut |_| {},
    )
    .unwrap();
}

/// Corrects the first segment and names the first track's speaker.
fn review(store: &mut SessionStore, session: &SessionId) {
    let first = store.transcript_document(session).unwrap().remove(0);
    store
        .correct_transcript_segment(
            session,
            &first.revision_id,
            first.sequence,
            Some("Corrected words"),
        )
        .unwrap();
    store
        .rename_speaker(session, &first.track_id, Some("Grace"))
        .unwrap();
}

fn read(package: &Path, name: &str) -> Value {
    serde_json::from_slice(&fs::read(package.join(name)).unwrap()).unwrap()
}

/// Everything ADR 0010 requires a round trip to preserve, without local
/// identities, paths, or export times.
fn semantics(package: &Path) -> Value {
    let session = read(package, "session.json");
    let transcript = read(package, "transcript.json");
    let tracks: Vec<Value> = session["tracks"]
        .as_array()
        .unwrap()
        .iter()
        .map(|track| {
            json!({
                "source_kind": track["source_kind"],
                "speaker": track["speaker"],
                "segments": track["segments"].as_array().unwrap().iter().map(|segment| json!([
                    segment["sequence"], segment["media_format"], segment["start_ns"],
                    segment["sample_count"], segment["channels"], segment["byte_length"],
                    segment["sha256"],
                ])).collect::<Vec<_>>(),
            })
        })
        .collect();
    let transcript_tracks: Vec<Value> = transcript["tracks"]
        .as_array()
        .unwrap()
        .iter()
        .map(|track| {
            let revision = &track["revision"];
            json!({
                "source_kind": track["source_kind"],
                "finality": track["finality"],
                "speaker": track["speaker"],
                "model": revision.is_object().then(|| json!([
                    revision["engine"], revision["engine_version"], revision["model_id"],
                    revision["model_sha256"], revision["language"],
                ])),
                "input_matches": revision.is_null() || revision["input_digest"] == track["input_digest"],
            })
        })
        .collect();
    let segments: Vec<Value> = transcript["segments"]
        .as_array()
        .unwrap()
        .iter()
        .map(|segment| {
            json!([
                segment["sequence"],
                segment["start_ns"],
                segment["end_ns"],
                segment["finality"],
                segment["verbatim_text"],
                segment["effective_text"],
                segment["correction"],
                segment["speaker"],
                segment["evidence_ref"]["kind"],
                segment["evidence_ref"]["content_digest"],
            ])
        })
        .collect();
    json!({
        "title": session["session"]["title"],
        "origin": session["session"]["origin"],
        "duration_ns": session["duration_ns"],
        "tracks": tracks,
        "markers": session["markers"].as_array().unwrap().iter()
            .map(|marker| json!([marker["at_ns"], marker["label"]])).collect::<Vec<_>>(),
        "availability": [session["transcript"]["availability"], transcript["availability"]],
        "transcript_tracks": transcript_tracks,
        "segments": segments,
    })
}

/// Exports, opens the package in a second library, re-exports there, and
/// returns both packages' semantics and the second library's session.
fn round_trip(
    store: &SessionStore,
    session: &SessionId,
    parent: &Path,
) -> (Value, Value, SessionId) {
    let first = parent.join("First.openscribe");
    write_portable_package(store, session, &first).unwrap();
    let mut other = SessionStore::open(parent.join("Other Mac")).unwrap();
    let receipt = import_portable_package(&mut other, &first).unwrap();
    assert_eq!(receipt.source_session_id, session.0);
    assert_ne!(receipt.session_id, *session);
    let second = parent.join("Second.openscribe");
    write_portable_package(&other, &receipt.session_id, &second).unwrap();
    assert_eq!(
        read(&second, "session.json")["session"]["id"],
        receipt.session_id.0.as_str()
    );
    (semantics(&first), semantics(&second), receipt.session_id)
}

#[test]
fn an_imported_conversation_survives_a_round_trip_with_its_review() {
    let mut fixture = imported(30);
    transcribe(&mut fixture.store, &fixture.session, &fixture.track);
    review(&mut fixture.store, &fixture.session);
    let parent = fixture.root.parent().unwrap().to_path_buf();
    let (first, second, restored) = round_trip(&fixture.store, &fixture.session, &parent);
    assert_eq!(first["origin"], "import");
    assert_eq!(first["availability"], json!(["final", "final"]));
    assert_eq!(first["segments"][0][5], "Corrected words");
    assert_eq!(first["tracks"][0]["speaker"]["label"], "Grace");
    assert_eq!(first, second);

    // Every reference the second library exports resolves there.
    let other = SessionStore::open(parent.join("Other Mac")).unwrap();
    let transcript = read(&parent.join("Second.openscribe"), "transcript.json");
    for segment in transcript["segments"].as_array().unwrap() {
        let reference = EvidenceRef::parse(&segment["evidence_ref"].to_string()).unwrap();
        assert_eq!(reference.session_id, restored.0);
        assert_eq!(
            other.resolve_evidence(&reference).unwrap().state,
            ResolutionState::Available
        );
    }
}

/// A capture with a gap between two microphone segments, a system-audio
/// track, and a marker, restored into a library as a package would be.
fn captured(temp: &TempDir) -> (SessionStore, SessionId, String) {
    let files = temp.path().join("capture");
    fs::create_dir(&files).unwrap();
    let segment = |name: &str, sequence: u64, start: i64, seconds: u64| {
        let path = files.join(format!("{name}.caf"));
        write_burst_caf(&path, seconds * 48_000);
        let bytes = fs::read(&path).unwrap();
        RestoredSegment {
            source_segment_id: name.into(),
            sequence,
            start_nanoseconds: start,
            sample_count: seconds * 48_000,
            channels: 1,
            byte_length: bytes.len() as u64,
            digest_sha256: Sha256::digest(&bytes)
                .iter()
                .map(|byte| format!("{byte:02x}"))
                .collect(),
            path,
        }
    };
    let track = |id: &str, kind: &str, segments: Vec<RestoredSegment>| RestoredTrack {
        source_track_id: id.into(),
        source_id: format!("source-{id}"),
        source_kind: kind.into(),
        human_speaker_label: None,
        segments,
        transcript: None,
    };
    let mut store = SessionStore::open(temp.path().join("Open Scribe")).unwrap();
    let session = store
        .restore_portable_session(&PackageRestoreRequest {
            title: "Captured call".into(),
            origin: SessionOrigin::Capture,
            source_session_id: "earlier-mac-session".into(),
            source_created_at_ms: 0,
            package_sha256: "e".repeat(64),
            tracks: vec![
                track(
                    "mic",
                    "microphone",
                    vec![
                        segment("mic-0", 0, 0, 12),
                        segment("mic-1", 1, 15 * SECOND, 12),
                    ],
                ),
                track("sys", "system_audio", vec![segment("sys-0", 0, SECOND, 6)]),
            ],
            markers: vec![RestoredMarker {
                at_nanoseconds: 4 * SECOND,
                label: "Action item".into(),
            }],
        })
        .unwrap()
        .session_id;
    let microphone = store.transcription_tracks(&session).unwrap().remove(0);
    (store, session, microphone)
}

#[test]
fn a_captured_conversation_survives_a_round_trip_and_transcribes_after_restore() {
    let temp = TempDir::new().unwrap();
    let (mut store, session, microphone) = captured(&temp);
    // A restored capture is ordinary local media: it transcribes in place.
    transcribe(&mut store, &session, &microphone);
    review(&mut store, &session);
    let (first, second, restored) = round_trip(&store, &session, temp.path());
    assert_eq!(first["origin"], "capture");
    assert_eq!(first["markers"], json!([[4 * SECOND, "Action item"]]));
    assert_eq!(first["tracks"][0]["segments"][1][2], 15 * SECOND);
    assert_eq!(first["availability"], json!(["draft", "draft"]));
    assert_eq!(first, second);

    // The second library's timeline and transcript input are its own.
    let other = SessionStore::open(temp.path().join("Other Mac")).unwrap();
    let timeline = other.playback_timeline(&restored).unwrap();
    assert_eq!(timeline.len(), 3);
    assert_eq!(timeline[1].gap_nanoseconds, 3 * SECOND);
    let track = &timeline[0].track_id;
    let placements: Vec<DigestedSegment> = timeline
        .iter()
        .filter(|segment| &segment.track_id == track)
        .map(|segment| DigestedSegment {
            segment_id: segment.segment_id.clone(),
            digest_sha256: other
                .session_inventory(&restored)
                .unwrap()
                .media
                .into_iter()
                .find(|entry| entry.segment_id == segment.segment_id)
                .unwrap()
                .digest_sha256,
            start_nanoseconds: segment.start_nanoseconds,
            gap_nanoseconds: segment.gap_nanoseconds,
            frames: segment.sample_count,
        })
        .collect();
    assert_eq!(
        other
            .transcription_input(&restored, track)
            .unwrap()
            .input_digest,
        transcription_input_digest(&restored.0, track, false, &placements)
    );
}

#[test]
fn a_package_whose_documents_disagree_with_its_media_is_refused() {
    let mut fixture = imported(30);
    transcribe(&mut fixture.store, &fixture.session, &fixture.track);
    let parent = fixture.root.parent().unwrap().to_path_buf();
    let package = parent.join("Source.openscribe");
    write_portable_package(&fixture.store, &fixture.session, &package).unwrap();
    let mut other = SessionStore::open(parent.join("Other Mac")).unwrap();

    // A rewritten transcript no longer matches the manifest digest.
    let transcript = package.join("transcript.json");
    let original = fs::read(&transcript).unwrap();
    let mut edited: Value = serde_json::from_slice(&original).unwrap();
    edited["segments"][0]["verbatim_text"] = "Invented words".into();
    fs::write(&transcript, serde_json::to_vec(&edited).unwrap()).unwrap();
    assert!(matches!(
        import_portable_package(&mut other, &package),
        Err(SessionExportError::InvalidPackage(_))
    ));
    fs::write(&transcript, &original).unwrap();

    // A consistent package whose transcript cites other media is refused
    // by the store before any file is copied.
    let manifest_path = package.join("manifest.json");
    let mut manifest: Value = serde_json::from_slice(&fs::read(&manifest_path).unwrap()).unwrap();
    edited = serde_json::from_slice(&original).unwrap();
    for track in edited["tracks"].as_array_mut().unwrap() {
        track["input_digest"] = "f".repeat(64).into();
        track["revision"]["input_digest"] = "f".repeat(64).into();
    }
    let bytes = serde_json::to_vec(&edited).unwrap();
    fs::write(&transcript, &bytes).unwrap();
    for file in manifest["files"].as_array_mut().unwrap() {
        if file["path"] == "transcript.json" {
            file["byte_length"] = bytes.len().into();
            file["sha256"] = Sha256::digest(&bytes)
                .iter()
                .map(|byte| format!("{byte:02x}"))
                .collect::<String>()
                .into();
        }
    }
    fs::write(&manifest_path, serde_json::to_vec(&manifest).unwrap()).unwrap();
    assert!(matches!(
        import_portable_package(&mut other, &package),
        Err(SessionExportError::Store(StoreError::InvalidRequest(
            "a transcript does not match its media"
        )))
    ));
    assert!(
        fs::read_dir(parent.join("Other Mac/Sessions"))
            .unwrap()
            .next()
            .is_none()
    );
}
