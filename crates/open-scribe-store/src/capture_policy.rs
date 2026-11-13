//! Capture limits and source defaults the store owns. The native app reads
//! them through UniFFI `nativeCapturePolicy()` and keeps no copies.

use super::import::ImportedPlaybackLease;
use super::storage_reserve::{RESERVE_BYTES, WARNING_BYTES};
use super::transcripts::LIVE_DRAFT_WINDOW_MAX_NS;
use super::{MEDIA_SAMPLE_RATE_HZ, MediaSourceKind};

/// Seconds of audio a capture writer puts in one segment before it rotates.
const SEGMENT_SECONDS: u64 = 30;

/// The speaker label of a track whose source kind is not a capture kind,
/// such as imported audio.
pub const UNKNOWN_SOURCE_SPEAKER_LABEL: &str = "Speaker";

/// What a capture source is called until the platform or a person names it.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct SourceDefaults {
    pub display_name: &'static str,
    pub speaker_label: &'static str,
}

#[must_use]
pub const fn source_defaults(kind: MediaSourceKind) -> SourceDefaults {
    // Founding PRD 11.3: the microphone is the local user; computer audio
    // carries the other participants. These are labels, not identities.
    match kind {
        MediaSourceKind::Microphone => SourceDefaults {
            display_name: "Mac microphone",
            speaker_label: "You",
        },
        MediaSourceKind::ApplicationAudio => SourceDefaults {
            display_name: "Selected application audio",
            speaker_label: "Others",
        },
        MediaSourceKind::SystemAudio => SourceDefaults {
            display_name: "Mac system audio",
            speaker_label: "Others",
        },
    }
}

/// The capture values a native adapter must use as given.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct CapturePolicy {
    pub sample_rate_hz: u32,
    pub segment_frame_count: u64,
    /// The longest Draft window `commit_live_draft_window` accepts.
    pub live_draft_window_max_nanoseconds: i64,
    /// Below this free space capture is critical and stops.
    pub storage_reserve_bytes: u64,
    /// Below this free space capture continues with a warning.
    pub storage_warning_bytes: u64,
    pub playback_chunk_bytes: u64,
    pub playback_snapshot_max_bytes: u64,
}

#[must_use]
pub const fn capture_policy() -> CapturePolicy {
    CapturePolicy {
        sample_rate_hz: MEDIA_SAMPLE_RATE_HZ,
        segment_frame_count: SEGMENT_SECONDS * MEDIA_SAMPLE_RATE_HZ as u64,
        live_draft_window_max_nanoseconds: LIVE_DRAFT_WINDOW_MAX_NS,
        storage_reserve_bytes: RESERVE_BYTES,
        storage_warning_bytes: WARNING_BYTES,
        playback_chunk_bytes: ImportedPlaybackLease::chunk_byte_length(),
        playback_snapshot_max_bytes: ImportedPlaybackLease::maximum_snapshot_byte_length(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn capture_policy_keeps_the_values_existing_media_and_scripts_assume() {
        let policy = capture_policy();
        assert_eq!(policy.sample_rate_hz, 48_000);
        assert_eq!(policy.segment_frame_count, 1_440_000);
        assert_eq!(policy.live_draft_window_max_nanoseconds, 12_000_000_000);
        // check_m1_injected.sh fills a 1536 MiB image; the reserve must fit below it.
        assert!(policy.storage_reserve_bytes < 1536 * 1024 * 1024);
        assert!(policy.storage_reserve_bytes < policy.storage_warning_bytes);
        assert_eq!(policy.playback_chunk_bytes, 65_536);
    }

    #[test]
    fn every_capture_kind_has_a_name_and_a_speaker_label() {
        for kind in MediaSourceKind::ALL {
            let defaults = source_defaults(kind);
            assert!(!defaults.display_name.is_empty());
            assert!(!defaults.speaker_label.is_empty());
        }
        assert_eq!(
            source_defaults(MediaSourceKind::Microphone).speaker_label,
            "You"
        );
        assert_eq!(
            source_defaults(MediaSourceKind::SystemAudio).display_name,
            "Mac system audio"
        );
    }
}
