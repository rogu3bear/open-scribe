use std::path::{Path, PathBuf};

use sha2::{Digest, Sha256};
use tempfile::TempDir;

use super::*;
use crate::transcripts::tests::{SECOND, sample, write_caf};
use crate::{SESSIONS_DIRECTORY, SessionInventory};

const SOURCE_SESSION: &str = "0190aaaa-0000-7000-8000-000000000001";

struct Package {
    _temp: TempDir,
    root: PathBuf,
    store: SessionStore,
    request: PackageRestoreRequest,
}

fn media(directory: &Path, name: &str, frames: u64) -> (PathBuf, u64, String) {
    let path = directory.join(name);
    write_caf(&path, frames, sample);
    let bytes = fs::read(&path).unwrap();
    (path, bytes.len() as u64, hex(&Sha256::digest(&bytes)))
}

fn segment(directory: &Path, id: &str, sequence: u64, start: i64, frames: u64) -> RestoredSegment {
    let (path, byte_length, digest_sha256) = media(directory, &format!("{id}.caf"), frames);
    RestoredSegment {
        source_segment_id: id.into(),
        sequence,
        start_nanoseconds: start,
        sample_count: frames,
        channels: 1,
        byte_length,
        digest_sha256,
        path,
    }
}

/// The digest a source store would have given this track's input.
fn source_digest(track_id: &str, segments: &[RestoredSegment]) -> String {
    let mut placements: Vec<DigestedSegment> = segments
        .iter()
        .map(|segment| DigestedSegment {
            segment_id: segment.source_segment_id.clone(),
            digest_sha256: segment.digest_sha256.clone(),
            start_nanoseconds: segment.start_nanoseconds,
            gap_nanoseconds: 0,
            frames: segment.sample_count,
        })
        .collect();
    fill_gaps(&mut placements).unwrap();
    transcription_input_digest(SOURCE_SESSION, track_id, false, &placements)
}

fn transcript(input_digest: String, texts: &[(&str, Option<&str>)]) -> RestoredTranscript {
    RestoredTranscript {
        source_revision_id: "source-revision".into(),
        source_run_id: "source-run".into(),
        input_digest,
        engine: "whisper.cpp".into(),
        engine_version: "1.7.6".into(),
        model_id: "ggml-base.en".into(),
        model_sha256: "b".repeat(64),
        language: Some("en".into()),
        segments: texts
            .iter()
            .enumerate()
            .map(|(index, (text, correction))| RestoredTranscriptSegment {
                start_nanoseconds: index as i64 * SECOND,
                end_nanoseconds: index as i64 * SECOND + SECOND / 2,
                verbatim_text: (*text).into(),
                correction: correction.map(str::to_owned),
            })
            .collect(),
    }
}

/// A two-track capture: the microphone has a gap between its segments.
fn capture_package() -> Package {
    let temp = TempDir::new().unwrap();
    let files = temp.path().join("package");
    fs::create_dir(&files).unwrap();
    let microphone = vec![
        segment(&files, "mic-0", 0, 0, 96_000),
        segment(&files, "mic-1", 1, 5 * SECOND, 48_000),
    ];
    let system = vec![segment(&files, "sys-0", 0, SECOND, 144_000)];
    let request = PackageRestoreRequest {
        title: "Planning call".into(),
        origin: SessionOrigin::Capture,
        source_session_id: SOURCE_SESSION.into(),
        source_created_at_ms: 1_700_000_000_000,
        package_sha256: "c".repeat(64),
        tracks: vec![
            RestoredTrack {
                source_track_id: "track-mic".into(),
                source_id: "source-mic".into(),
                source_kind: "microphone".into(),
                human_speaker_label: Some("Ada".into()),
                transcript: Some(transcript(
                    source_digest("track-mic", &microphone),
                    &[
                        ("hello there", None),
                        ("recording safe", Some("recording is safe")),
                    ],
                )),
                segments: microphone,
            },
            RestoredTrack {
                source_track_id: "track-sys".into(),
                source_id: "source-sys".into(),
                source_kind: "system_audio".into(),
                human_speaker_label: None,
                transcript: None,
                segments: system,
            },
        ],
        markers: vec![RestoredMarker {
            at_nanoseconds: 2 * SECOND,
            label: "Decision".into(),
        }],
    };
    let root = temp.path().join("Open Scribe");
    let store = SessionStore::open(&root).unwrap();
    Package {
        _temp: temp,
        root,
        store,
        request,
    }
}

fn session_count(store: &SessionStore, lifecycle: &str) -> i64 {
    store
        .connection
        .query_row(
            "SELECT COUNT(*) FROM sessions WHERE lifecycle = ?1",
            [lifecycle],
            |row| row.get(0),
        )
        .unwrap()
}

fn session_directories(root: &Path) -> usize {
    fs::read_dir(root.join(SESSIONS_DIRECTORY)).unwrap().count()
}

#[test]
fn a_restored_capture_plays_its_placements_and_keeps_its_transcript() {
    let mut package = capture_package();
    let receipt = package
        .store
        .restore_portable_session(&package.request)
        .unwrap();
    assert_eq!(
        (
            receipt.media_files,
            receipt.transcript_tracks,
            receipt.markers
        ),
        (3, 1, 1)
    );
    let session = receipt.session_id;
    assert_ne!(session.0, SOURCE_SESSION);

    let timeline = package.store.playback_timeline(&session).unwrap();
    let starts: Vec<(u64, i64, i64)> = timeline
        .iter()
        .map(|segment| {
            (
                segment.sample_count,
                segment.start_nanoseconds,
                segment.gap_nanoseconds,
            )
        })
        .collect();
    assert_eq!(
        starts,
        [
            (96_000, 0, 0),
            (48_000, 5 * SECOND, 3 * SECOND),
            (144_000, SECOND, 0)
        ]
    );

    let inventory: SessionInventory = package.store.session_inventory(&session).unwrap();
    assert_eq!(inventory.origin, "capture");
    assert_eq!(inventory.title, "Planning call");
    let digests: Vec<&str> = inventory
        .media
        .iter()
        .map(|entry| entry.digest_sha256.as_str())
        .collect();
    let expected: Vec<&str> = package
        .request
        .tracks
        .iter()
        .flat_map(|track| &track.segments)
        .map(|segment| segment.digest_sha256.as_str())
        .collect();
    assert_eq!(digests, expected);
    for entry in &inventory.media {
        let verified = package.store.open_verified_media(&session, entry).unwrap();
        assert_eq!(verified.byte_length, entry.byte_length);
    }
    assert_eq!(inventory.markers.len(), 1);
    assert_eq!(inventory.markers[0].at_nanoseconds, 2 * SECOND);
    assert_eq!(inventory.markers[0].label, "Decision");

    let document = package.store.transcript_document(&session).unwrap();
    let texts: Vec<(&str, &str, bool, &str)> = document
        .iter()
        .map(|segment| {
            (
                segment.verbatim_text.as_str(),
                segment.effective_text.as_str(),
                segment.corrected,
                segment.speaker_label.as_str(),
            )
        })
        .collect();
    assert_eq!(
        texts,
        [
            ("hello there", "hello there", false, "Ada"),
            ("recording safe", "recording is safe", true, "Ada"),
        ]
    );
    let context = package.store.transcript_export_context(&session).unwrap();
    assert_eq!(context.selected.len(), 1);
    let selected = &context.selected[0];
    assert_eq!(selected.language.as_deref(), Some("en"));
    assert_eq!(selected.model_id, "ggml-base.en");
    let local_input = context
        .track_input_digests
        .iter()
        .find(|(track, _)| *track == selected.track_id)
        .map(|(_, digest)| digest.clone());
    assert_eq!(local_input.as_deref(), Some(selected.input_digest.as_str()));
    assert_eq!(
        package
            .store
            .search_transcripts("safe", None, 10)
            .unwrap()
            .into_iter()
            .map(|hit| hit.effective_text)
            .collect::<Vec<_>>(),
        ["recording is safe"]
    );

    let snapshot = package.store.runtime_library_snapshot().unwrap();
    let saved = snapshot
        .saved_sessions
        .iter()
        .find(|saved| saved.session_id == session)
        .unwrap();
    assert!(saved.has_capture_timeline);
    assert_eq!(saved.lifecycle, "ready_for_review");

    // A relaunch keeps the finished restore and its timeline.
    drop(package.store);
    let mut reopened = SessionStore::open(&package.root).unwrap();
    reopened.recover_library().unwrap();
    assert_eq!(reopened.playback_timeline(&session).unwrap(), timeline);
}

#[test]
fn a_transcript_that_does_not_cite_its_media_is_refused_before_any_file() {
    let mut package = capture_package();
    let transcript = package.request.tracks[0].transcript.as_mut().unwrap();
    transcript.input_digest = "d".repeat(64);
    let error = package
        .store
        .restore_portable_session(&package.request)
        .unwrap_err();
    assert!(matches!(
        error,
        StoreError::InvalidRequest("a transcript does not match its media")
    ));
    assert_eq!(session_count(&package.store, "deleted"), 0);
    assert_eq!(session_directories(&package.root), 0);

    // A placement change alone also changes the cited input.
    let mut package = capture_package();
    package.request.tracks[0].segments[1].start_nanoseconds += SECOND;
    assert!(
        package
            .store
            .restore_portable_session(&package.request)
            .is_err()
    );
}

#[test]
fn changed_package_media_discards_the_partial_session_and_leaves_a_tombstone() {
    let mut package = capture_package();
    let tampered = &package.request.tracks[1].segments[0].path;
    let mut bytes = fs::read(tampered).unwrap();
    let last = bytes.len() - 1;
    bytes[last] ^= 0x55;
    fs::write(tampered, bytes).unwrap();
    let error = package
        .store
        .restore_portable_session(&package.request)
        .unwrap_err();
    assert!(matches!(error, StoreError::IntegrityMismatch(_)));
    assert_eq!(session_count(&package.store, "deleted"), 1);
    assert_eq!(session_count(&package.store, "ready_for_review"), 0);
    assert_eq!(session_directories(&package.root), 0);
    let leftovers: i64 = package
        .store
        .connection
        .query_row(
            "SELECT (SELECT COUNT(*) FROM segments) + (SELECT COUNT(*) FROM session_events)
                  + (SELECT COUNT(*) FROM session_restorations)",
            [],
            |row| row.get(0),
        )
        .unwrap();
    assert_eq!(leftovers, 0);
}

#[test]
fn a_restore_interrupted_by_a_crash_is_removed_at_launch() {
    let mut package = capture_package();
    let prepared = package
        .store
        .prepare_session_recorded(
            PrepareSessionRequest {
                title: "Interrupted".into(),
                origin: SessionOrigin::Capture,
            },
            None,
            Some(&RestorationIntent {
                source_session_id: SOURCE_SESSION,
                source_created_at_ms: 0,
                package_sha256: &"c".repeat(64),
            }),
        )
        .unwrap();
    assert_eq!(session_directories(&package.root), 1);
    drop(package.store);
    let mut reopened = SessionStore::open(&package.root).unwrap();
    let recovery = reopened.recover_library().unwrap();
    assert!(
        recovery
            .findings
            .iter()
            .all(|finding| finding.session_id != prepared.session_id)
    );
    assert_eq!(session_count(&reopened, "deleted"), 1);
    assert_eq!(session_count(&reopened, "interrupted"), 0);
    assert_eq!(session_directories(&package.root), 0);
}

#[test]
fn a_restored_import_keeps_its_origin_and_plays_its_original() {
    let mut package = capture_package();
    let temp = TempDir::new().unwrap();
    let original = segment(temp.path(), "import-0", 0, 0, 144_000);
    let input = source_digest("track-import", std::slice::from_ref(&original));
    package.request.origin = SessionOrigin::Import;
    package.request.markers.clear();
    package.request.tracks = vec![RestoredTrack {
        source_track_id: "track-import".into(),
        source_id: "source-import".into(),
        source_kind: IMPORT_SOURCE_KIND.into(),
        human_speaker_label: None,
        transcript: Some(transcript(input, &[("imported words", None)])),
        segments: vec![original.clone()],
    }];
    let session = package
        .store
        .restore_portable_session(&package.request)
        .unwrap()
        .session_id;
    let inventory = package.store.session_inventory(&session).unwrap();
    assert_eq!(inventory.origin, "import");
    assert_eq!(inventory.media[0].digest_sha256, original.digest_sha256);
    let lease = package.store.lease_imported_playback(&session).unwrap();
    assert_eq!(lease.digest_sha256(), original.digest_sha256);
    assert_eq!(
        package.store.transcript_document(&session).unwrap().len(),
        1
    );
    let saved = package.store.runtime_library_snapshot().unwrap();
    let saved = saved
        .saved_sessions
        .iter()
        .find(|saved| saved.session_id == session)
        .unwrap();
    assert!(!saved.has_capture_timeline);
    assert!(saved.playable_media.is_some());

    // An import with a marker or a second file is not an import.
    package.request.markers.push(RestoredMarker {
        at_nanoseconds: 0,
        label: String::new(),
    });
    assert!(matches!(
        package.store.restore_portable_session(&package.request),
        Err(StoreError::InvalidRequest(_))
    ));
}
