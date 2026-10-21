//! Offscreen codec-proof endpoint: use the actual store validator without ASR.
//! The marker is required before opening a library, including for invalid input.
use open_scribe_store::SessionStore;
use open_scribe_types::SessionId;
use std::{error::Error, path::PathBuf};

fn main() -> Result<(), Box<dyn Error>> {
    let args = std::env::args().skip(1).collect::<Vec<_>>();
    if args.len() != 3 {
        return Err("expected isolated Library, session ID and companion path".into());
    }
    let root = PathBuf::from(&args[0]);
    if !root.is_absolute() || root.file_name().is_none_or(|name| name != "Library") {
        return Err("codec proof requires an absolute isolated Library".into());
    }
    let parent = root.parent().ok_or("missing proof directory")?;
    if std::fs::read(parent.join(".codec-proof"))? != b"open-scribe-synthetic-codec-proof\n" {
        return Err("codec proof ownership marker missing".into());
    }
    if root.canonicalize()? != root || parent.canonicalize()? != parent {
        return Err("codec proof paths must not be redirected".into());
    }
    let store = SessionStore::open(&root)?;
    let session = SessionId(args[1].clone());
    let tracks = store.transcription_tracks(&session)?;
    if tracks.len() != 1 {
        return Err("expected exactly one imported track".into());
    }
    let input = store.transcription_input(&session, &tracks[0])?;
    let reader = store.open_decoded_transcription_input(&input, &PathBuf::from(&args[2]))?;
    let first = reader.read_frames(0, 0, 1)?;
    if first.len() != usize::from(input.channels) {
        return Err("validated companion contains no first frame".into());
    }
    println!(
        "RUST_COMPANION_GREEN channels={} frames={}",
        input.channels, input.spans[0].frames
    );
    Ok(())
}
