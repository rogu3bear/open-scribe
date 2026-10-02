use crate::session_export::{
    PORTABLE_V1_SCHEMA_JSON, SESSION_MANIFEST_V1_SCHEMA_JSON, SessionExportError,
    export_source_media, export_track_wav, export_validated_mix, render_session_manifest,
    verify_portable_package, write_portable_package, write_session_manifest,
};
use crate::transcribe_track;
use crate::transcription::tests::{BurstRecognizer, Imported, imported};
use open_scribe_asr::{DecodeOptions, Language};
use serde_json::Value;
use sha2::{Digest, Sha256};
use std::fs;
use std::sync::atomic::AtomicBool;

/// Checks the JSON Schema keywords the checked schemas use: type, required,
/// additionalProperties, properties, items, minItems, const, enum, minimum,
/// and maximum.
fn validate(schema: &Value, value: &Value, path: &str) {
    if let Some(expected) = schema.get("const") {
        assert_eq!(value, expected, "{path}");
    }
    if let Some(allowed) = schema.get("enum").and_then(Value::as_array) {
        assert!(
            allowed.contains(value),
            "{path}: {value} not in {allowed:?}"
        );
    }
    match schema.get("type").and_then(Value::as_str) {
        Some("object") => {
            let object = value
                .as_object()
                .unwrap_or_else(|| panic!("{path} is not an object"));
            for required in schema["required"].as_array().into_iter().flatten() {
                let key = required.as_str().unwrap();
                assert!(object.contains_key(key), "{path} lacks {key}");
            }
            let properties = schema.get("properties").and_then(Value::as_object);
            if schema.get("additionalProperties") == Some(&Value::Bool(false)) {
                for key in object.keys() {
                    assert!(
                        properties.is_some_and(|properties| properties.contains_key(key)),
                        "{path} has undeclared {key}"
                    );
                }
            }
            for (key, child) in properties.into_iter().flatten() {
                if let Some(item) = object.get(key) {
                    validate(child, item, &format!("{path}.{key}"));
                }
            }
        }
        Some("array") => {
            let items = value
                .as_array()
                .unwrap_or_else(|| panic!("{path} is not an array"));
            if let Some(minimum) = schema.get("minItems").and_then(Value::as_u64) {
                assert!(items.len() as u64 >= minimum, "{path} has too few items");
            }
            for (index, item) in items.iter().enumerate() {
                validate(&schema["items"], item, &format!("{path}[{index}]"));
            }
        }
        Some("integer") => {
            let number = value
                .as_i64()
                .unwrap_or_else(|| panic!("{path} is not an integer"));
            if let Some(minimum) = schema.get("minimum").and_then(Value::as_i64) {
                assert!(number >= minimum, "{path} below minimum");
            }
            if let Some(maximum) = schema.get("maximum").and_then(Value::as_i64) {
                assert!(number <= maximum, "{path} above maximum");
            }
        }
        Some("string") => assert!(value.is_string(), "{path} is not a string"),
        Some("boolean") => assert!(value.is_boolean(), "{path} is not a boolean"),
        _ => {}
    }
}

fn transcribed(seconds: u64) -> Imported {
    let mut fixture = imported(seconds);
    let mut recognizer = BurstRecognizer::new("model");
    transcribe_track(
        &mut fixture.store,
        &mut recognizer,
        &DecodeOptions::final_pass(Language::English),
        &fixture.session,
        &fixture.track,
        &AtomicBool::new(false),
        &mut |_| {},
    )
    .unwrap();
    fixture
}

fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|byte| format!("{byte:02x}")).collect()
}

#[test]
fn the_session_manifest_matches_its_schema_and_the_sealed_media() {
    let fixture = transcribed(30);
    let manifest = render_session_manifest(&fixture.store, &fixture.session, 0).unwrap();
    let schema: Value = serde_json::from_str(SESSION_MANIFEST_V1_SCHEMA_JSON).unwrap();
    validate(&schema, &manifest, "manifest");
    assert_eq!(manifest["session"]["origin"], "import");
    assert_eq!(manifest["duration_ns"], 30_000_000_000_i64);
    let segment = &manifest["tracks"][0]["segments"][0];
    let media = fs::read(&fixture.media).unwrap();
    assert_eq!(segment["byte_length"], media.len());
    assert_eq!(segment["sha256"], hex(&Sha256::digest(&media)));
    assert_eq!(segment["sample_count"], 30 * 48_000);
    assert_eq!(manifest["transcript"]["availability"], "final");
    assert_eq!(
        manifest["transcript"]["revisions"]
            .as_array()
            .unwrap()
            .len(),
        1
    );

    let destination = fixture.root.join("../session.json");
    let receipt = write_session_manifest(&fixture.store, &fixture.session, &destination).unwrap();
    let written = fs::read(&destination).unwrap();
    assert_eq!(receipt.byte_length, written.len() as u64);
    assert_eq!(receipt.sha256, hex(&Sha256::digest(&written)));
}

#[test]
fn audio_exports_copy_verified_media_and_render_track_wav_on_the_timeline() {
    let fixture = imported(3);
    let parent = fixture.root.parent().unwrap().to_path_buf();
    let original = fs::read(&fixture.media).unwrap();

    let copy = parent.join("Original.caf");
    let receipt = export_source_media(&fixture.store, &fixture.session, &copy).unwrap();
    assert_eq!(fs::read(&copy).unwrap(), original);
    assert_eq!(receipt.sha256, hex(&Sha256::digest(&original)));

    let wav = parent.join("Track.wav");
    let receipt = export_track_wav(&fixture.store, &fixture.session, &fixture.track, &wav).unwrap();
    let bytes = fs::read(&wav).unwrap();
    assert_eq!(&bytes[0..4], b"RIFF");
    assert_eq!(&bytes[8..16], b"WAVEfmt ");
    assert_eq!(u16::from_le_bytes([bytes[22], bytes[23]]), 1, "mono");
    assert_eq!(
        u32::from_le_bytes(bytes[24..28].try_into().unwrap()),
        48_000
    );
    assert_eq!(
        u32::from_le_bytes(bytes[40..44].try_into().unwrap()),
        3 * 48_000 * 2
    );
    // The WAV samples are exactly the sealed CAF's samples.
    assert!(original.ends_with(&bytes[44..]));
    assert_eq!(receipt.byte_length, bytes.len() as u64);
    assert_eq!(receipt.sha256, hex(&Sha256::digest(&bytes)));

    assert!(matches!(
        export_validated_mix(&fixture.store, &fixture.session, &parent.join("Mix.m4a")),
        Err(SessionExportError::Unavailable(_))
    ));
    assert!(matches!(
        export_track_wav(
            &fixture.store,
            &fixture.session,
            &fixture.track,
            &parent.join(".hidden.wav")
        ),
        Err(SessionExportError::InvalidDestination(_))
    ));
}

#[test]
fn a_portable_package_verifies_replaces_atomically_and_refuses_tampering() {
    let fixture = transcribed(3);
    let parent = fixture.root.parent().unwrap().to_path_buf();
    let package = parent.join("Bursts.openscribe");
    let summary = write_portable_package(&fixture.store, &fixture.session, &package).unwrap();
    assert_eq!(summary.source_session_id, fixture.session.0);
    assert_eq!(
        summary.files, 3,
        "session manifest, transcript, one source file"
    );
    let manifest: Value =
        serde_json::from_slice(&fs::read(package.join("manifest.json")).unwrap()).unwrap();
    validate(
        &serde_json::from_str(PORTABLE_V1_SCHEMA_JSON).unwrap(),
        &manifest,
        "portable",
    );
    let transcript: Value =
        serde_json::from_slice(&fs::read(package.join("transcript.json")).unwrap()).unwrap();
    assert_eq!(transcript["availability"], "final");

    // A second export replaces the first and leaves no staging behind.
    write_portable_package(&fixture.store, &fixture.session, &package).unwrap();
    let leftovers: Vec<_> = fs::read_dir(&parent)
        .unwrap()
        .filter_map(Result::ok)
        .filter(|entry| entry.file_name().to_string_lossy().starts_with(".Bursts"))
        .collect();
    assert!(leftovers.is_empty());
    assert!(matches!(
        write_portable_package(&fixture.store, &fixture.session, &parent.join("Bursts.zip")),
        Err(SessionExportError::InvalidDestination(_))
    ));

    let media_path = manifest["files"]
        .as_array()
        .unwrap()
        .iter()
        .find(|file| file["role"] == "source_media")
        .unwrap()["path"]
        .as_str()
        .unwrap()
        .to_owned();
    let tamper = |name: &str, change: &dyn Fn(&std::path::Path)| {
        let copy = parent.join(name);
        copy_tree(&package, &copy);
        change(&copy);
        let refused = verify_portable_package(&copy);
        assert!(
            matches!(refused, Err(SessionExportError::InvalidPackage(_))),
            "{name}: {refused:?}"
        );
    };
    tamper("changed.openscribe", &|copy| {
        let path = copy.join(&media_path);
        let mut bytes = fs::read(&path).unwrap();
        *bytes.last_mut().unwrap() ^= 1;
        fs::write(path, bytes).unwrap();
    });
    tamper("extra.openscribe", &|copy| {
        fs::write(copy.join("notes.txt"), b"x").unwrap()
    });
    tamper("linked.openscribe", &|copy| {
        let path = copy.join("transcript.json");
        fs::remove_file(&path).unwrap();
        std::os::unix::fs::symlink(copy.join("session.json"), path).unwrap();
    });
    let rewrite = |copy: &std::path::Path, edit: &dyn Fn(&mut Value)| {
        let path = copy.join("manifest.json");
        let mut value: Value = serde_json::from_slice(&fs::read(&path).unwrap()).unwrap();
        edit(&mut value);
        fs::write(path, serde_json::to_vec(&value).unwrap()).unwrap();
    };
    tamper("traversal.openscribe", &|copy| {
        rewrite(copy, &|value| {
            value["files"][0]["path"] = "../session.json".into()
        })
    });
    tamper("duplicate.openscribe", &|copy| {
        rewrite(copy, &|value| {
            let first = value["files"][0].clone();
            value["files"].as_array_mut().unwrap().push(first);
        })
    });
    tamper("version.openscribe", &|copy| {
        rewrite(copy, &|value| value["schema_version"] = 2.into())
    });
    verify_portable_package(&package).unwrap();
}

fn copy_tree(from: &std::path::Path, to: &std::path::Path) {
    fs::create_dir_all(to).unwrap();
    for entry in fs::read_dir(from).unwrap() {
        let entry = entry.unwrap();
        let target = to.join(entry.file_name());
        if entry.file_type().unwrap().is_dir() {
            copy_tree(&entry.path(), &target);
        } else {
            fs::copy(entry.path(), target).unwrap();
        }
    }
}
