#!/usr/bin/env bash
set -euo pipefail

script_dir="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
repo_root="$(CDPATH='' cd -- "$script_dir/.." && pwd)"
cd "$repo_root"

"$script_dir/check_m1_microphone_foundation.sh"

proof_root="$(mktemp -d "$repo_root/apps/macos/.build/m1-segment-sealing.XXXXXX")"
trap 'rm -rf "$proof_root"' EXIT
rust_library="$(bash "$script_dir/build_rust_macos.sh" "$proof_root/rust")"
CARGO_TARGET_DIR="$proof_root/rust" cargo run --locked -p open-scribe-uniffi \
	--features bindgen \
	--bin uniffi-bindgen \
	-- generate \
	--library "$rust_library" \
	--language swift \
	--out-dir "$proof_root/bindings"
xcrun swift-format format --in-place "$proof_root/bindings/OpenScribeCore.swift"
xcrun clang-format -i "$proof_root/bindings/OpenScribeFFI.h"
cmp "$proof_root/bindings/OpenScribeCore.swift" \
	apps/macos/Sources/OpenScribeApp/Generated/OpenScribeCore.swift
cmp "$proof_root/bindings/OpenScribeFFI.h" \
	apps/macos/Sources/OpenScribeFFI/include/OpenScribeFFI.h

xcode_log="$proof_root/xcodebuild.log"
if ! xcodebuild \
	-project apps/macos/OpenScribe.xcodeproj \
	-scheme OpenScribeApp \
	-configuration Debug \
	-derivedDataPath "$proof_root/xcode" \
	ARCHS=arm64 \
	ONLY_ACTIVE_ARCH=YES \
	LIBRARY_SEARCH_PATHS="$(dirname "$rust_library")" \
	MACOSX_DEPLOYMENT_TARGET=13.0 \
	CODE_SIGNING_ALLOWED=NO \
	test \
	-only-testing:OpenScribeAppTests/MediaOpenProtocolTests 2>&1 | tee "$xcode_log"; then
	printf '%s\n' 'M1_SEGMENT_SEALING_RED: Swift-to-Rust segment-seal proof failed' >&2
	exit 1
fi
if rg -n '/Sources/.*warning:' "$xcode_log"; then
	printf '%s\n' 'M1_SEGMENT_SEALING_RED: project source emitted a Swift warning' >&2
	exit 1
fi

cargo clippy --locked \
	-p open-scribe-store \
	-p open-scribe-core \
	-p open-scribe-uniffi \
	--all-targets -- -D warnings
cargo test --locked \
	-p open-scribe-store \
	-p open-scribe-core \
	-p open-scribe-uniffi
git diff --check

printf '%s\n' \
	'M1_SEGMENT_SEALING_GREEN' \
	'proof=swift_closes_managed_caf_before_receipt,writer_reported_final_counters,exact_file_length,stable_file_identity,caf_header,independent_rust_sha256,segment_local_source_and_track_projection,parallel_projection_preservation,journal_before_projection,idempotent_replay,seal_interruption_recovery,coarse_uniffi_round_trip,no_recording_transition,fresh_bindings,clean_arm64_macos13_xcode_test,microphone_foundation_regression,diff_hygiene' \
	'excludes=live_permission_prompt,live_microphone_runtime_capture,system_audio_capture,multiple_required_source_runtime,recording_transition,active_session_or_playable_recovery,thirty_second_rotation,pause_or_route_sealing,two_hour_capture,playback,disk_pressure,signing,notarization,distribution,deployment,public_release'
