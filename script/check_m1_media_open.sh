#!/usr/bin/env bash
set -euo pipefail

script_dir="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
repo_root="$(CDPATH='' cd -- "$script_dir/.." && pwd)"
cd "$repo_root"

cargo clippy --locked \
	-p open-scribe-store \
	-p open-scribe-core \
	-p open-scribe-uniffi \
	--all-targets -- -D warnings
cargo test --locked \
	-p open-scribe-store \
	-p open-scribe-core \
	-p open-scribe-uniffi

# Coarse boundary receipts may carry final or first-sample counters. Reject
# media payload/buffer types and live telemetry surfaces, not bounded metadata.
if rg -ni '\b(pcm|cmsamplebuffer|avaudiopcmbuffer|audio_buffer|video_frame|waveform|meter|pointer)\b' \
	crates/open-scribe-uniffi/src; then
	printf '%s\n' 'M1_MEDIA_OPEN_RED: hot-path media or telemetry crossed UniFFI' >&2
	exit 1
fi

"$script_dir/check_apple_toolchain.sh"
proof_root="$(mktemp -d "$repo_root/apps/macos/.build/m1-media-check.XXXXXX")"
trap 'rm -rf "$proof_root"' EXIT
rust_target_dir="$proof_root/rust"
rust_library="$(bash "$script_dir/build_rust_macos.sh" "$rust_target_dir")"
CARGO_TARGET_DIR="$rust_target_dir" cargo run --locked -p open-scribe-uniffi \
	--features bindgen \
	--bin uniffi-bindgen \
	-- generate \
	--library "$rust_library" \
	--language swift \
	--out-dir "$proof_root"
xcrun swift-format format --in-place "$proof_root/OpenScribeCore.swift"
xcrun clang-format -i "$proof_root/OpenScribeFFI.h"
cmp "$proof_root/OpenScribeCore.swift" \
	apps/macos/Sources/OpenScribeApp/Generated/OpenScribeCore.swift
cmp "$proof_root/OpenScribeFFI.h" \
	apps/macos/Sources/OpenScribeFFI/include/OpenScribeFFI.h

library_search_path="$(dirname "$rust_library")"
xcode_log="$proof_root/xcodebuild.log"
if ! xcodebuild \
	-project apps/macos/OpenScribe.xcodeproj \
	-scheme OpenScribeApp \
	-configuration Debug \
	-derivedDataPath "$proof_root/xcode" \
	ARCHS=arm64 \
	ONLY_ACTIVE_ARCH=YES \
	LIBRARY_SEARCH_PATHS="$library_search_path" \
	MACOSX_DEPLOYMENT_TARGET=13.0 \
	CODE_SIGNING_ALLOWED=NO \
	test \
	-only-testing:OpenScribeAppTests/MediaOpenProtocolTests 2>&1 | tee "$xcode_log"; then
	printf '%s\n' 'M1_MEDIA_OPEN_RED: clean Xcode test failed' >&2
	exit 1
fi
if rg -ni "built for newer ['\"]macOS['\"] version|object file.*newer.*macOS" "$xcode_log"; then
	printf '%s\n' 'M1_MEDIA_OPEN_RED: Xcode linked an object built for a newer macOS version' >&2
	exit 1
fi
app_binary="$proof_root/xcode/Build/Products/Debug/OpenScribeApp.app/Contents/MacOS/OpenScribeApp"
bash "$script_dir/check_macos_artifact_floor.sh" "$rust_library" "$app_binary"
printf '%s\n' \
	'M1_MACOS_BUILD_FLOOR_GREEN' \
	'proof=explicit_aarch64_apple_darwin_target,forced_macos_13_rust_environment,clean_rust_staticlib,clean_xcode_derived_data,arm64_archive_member_audit,arm64_linked_app_audit,maximum_macos_13_build_metadata,no_newer_object_linker_warning' \
	'excludes=macos_13_runtime_execution,capture,permissions,recording,recovery,signing,notarization,distribution,release'

"$script_dir/check_m1_storage.sh"
git diff --check

printf '%s\n' \
	'M1_MEDIA_OPEN_GREEN' \
	'proof=rust_authorized_managed_caf_path,create_new_swift_writer,real_48khz_mono_pcm_caf,retained_writer_after_acceptance,coarse_uniffi_only,independent_rust_path_header_identity_validation,stale_token_rejection,symlink_and_traversal_rejection,journal_before_projection,deterministic_media_interruption_recovery,idempotent_receipt,no_recording_transition,fresh_bindings,clean_arm64_macos13_native_build,xcode_media_tests,m1_storage_regression,m0_regression,diff_hygiene' \
	'excludes=live_microphone_capture,system_audio_capture,capture_permissions,live_first_sample_capture_evidence,multiple_required_sources,segment_sealing,real_forced_process_termination,playback,playable_recovery,disk_pressure,route_changes,recording,signing,notarization,distribution,release'
