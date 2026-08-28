#!/usr/bin/env bash
set -euo pipefail

script_dir="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"

if [[ "$#" -eq 1 && "$1" == "--scaffold" ]]; then
	exec "$script_dir/check_scaffold.sh"
fi

if [[ "$#" -eq 1 && "$1" == "--m0-native" ]]; then
	exec "$script_dir/check_m0_native.sh"
fi

if [[ "$#" -eq 1 && "$1" == "--m0" ]]; then
	exec "$script_dir/check_m0.sh"
fi

if [[ "$#" -eq 1 && "$1" == "--state-fixtures" ]]; then
	exec "$script_dir/check_state_fixtures.sh"
fi

if [[ "$#" -eq 1 && "$1" == "--m1-xcode-fixture" ]]; then
	exec "$script_dir/check_m1_xcode_fixture.sh"
fi

if [[ "$#" -eq 1 && "$1" == "--m1-storage" ]]; then
	exec "$script_dir/check_m1_storage.sh"
fi

if [[ "$#" -eq 1 && "$1" == "--m1-media-open" ]]; then
	exec "$script_dir/check_m1_media_open.sh"
fi

if [[ "$#" -eq 1 && "$1" == "--m1-microphone-foundation" ]]; then
	exec "$script_dir/check_m1_microphone_foundation.sh"
fi

if [[ "$#" -eq 1 && "$1" == "--m1-segment-sealing" ]]; then
	exec "$script_dir/check_m1_segment_sealing.sh"
fi

if [[ "$#" -eq 1 && "$1" == "--m1-interruption-state" ]]; then
	exec "$script_dir/check_m1_interruption_state.sh"
fi

if [[ "$#" -eq 1 && "$1" == "--m1-live-microphone" ]]; then
	exec "$script_dir/build_and_run.sh" --m1-dual-source-runtime-proof
fi

if [[ "$#" -eq 1 && "$1" == "--m1-dual-source-runtime" ]]; then
	exec "$script_dir/build_and_run.sh" --m1-dual-source-runtime-proof
fi

if [[ "$#" -eq 1 && "$1" == "--m1-forced-termination-recovery" ]]; then
	exec "$script_dir/check_m1_forced_termination_recovery.sh"
fi

if [[ "$#" -eq 1 && "$1" == "--release-prepare" ]]; then
	exec "$script_dir/check_release_prepare.sh"
fi

printf '%s\n' \
	"NOT_IMPLEMENTED: full repository check" \
	"Use './script/check.sh --scaffold' for founding structure, './script/check.sh --m0-native' for the bounded native proof, './script/check.sh --m0' for complete Milestone 0, './script/check.sh --state-fixtures' for deterministic post-M0 state truth, './script/check.sh --m1-xcode-fixture' for the pre-capture Xcode checkpoint, './script/check.sh --m1-storage' for durable session preparation, './script/check.sh --m1-media-open' for the pre-capture media-writer protocol and native macOS 13 build metadata, './script/check.sh --m1-microphone-foundation' for the deterministic first-sample and production-shaped microphone-adapter boundary, './script/check.sh --m1-segment-sealing' for closed synthetic CAF integrity evidence, './script/check.sh --m1-interruption-state' for durable post-preparation failure state and restart discovery, './script/check.sh --m1-dual-source-runtime' for explicit real-device microphone plus system-audio capture and independent playable-CAF proof, './script/check.sh --m1-forced-termination-recovery' for real dual-source external-kill recovery and native playback proof, or './script/check.sh --release-prepare' for the read-only release-preparation contract." \
	"Neither receipt proves source-loss handling, degraded continuation, permission revocation, long-session synchronization, transcription, website deployment, signing, distribution, or release." >&2
exit 64
