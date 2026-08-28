#!/usr/bin/env bash
set -euo pipefail

script_dir="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
repo_root="$(CDPATH='' cd -- "$script_dir/.." && pwd)"
cd "$repo_root"

"$script_dir/check_m1_segment_sealing.sh"

proof_root="$(mktemp -d "$repo_root/apps/macos/.build/m1-interruption-state.XXXXXX")"
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
	-only-testing:OpenScribeAppTests/LiveMicrophoneRecordingControllerTests 2>&1 | tee "$xcode_log"; then
	printf '%s\n' 'M1_INTERRUPTION_STATE_RED: live-controller interruption proof failed' >&2
	exit 1
fi
if rg -n '/Sources/.*warning:' "$xcode_log"; then
	printf '%s\n' 'M1_INTERRUPTION_STATE_RED: project source emitted a Swift warning' >&2
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
candidate_base="$(git merge-base HEAD main 2>/dev/null || true)"
if [[ -z "$candidate_base" || "$candidate_base" == "$(git rev-parse HEAD)" ]]; then
	candidate_base="$(git rev-parse HEAD^)"
fi
git diff --check "$candidate_base" HEAD
git diff --check

printf '%s\n' \
	'M1_INTERRUPTION_STATE_GREEN' \
	'proof=typed_content_free_interruption_reasons,journal_before_projection,sqlite_interrupted_projection,idempotent_replay,changed_reason_rejection,restart_projection_repair,interrupted_first_sample_discovery,media_bytes_unchanged,coarse_uniffi_round_trip,post_preparation_controller_failure_reporting,no_recording_transition,fresh_bindings,clean_arm64_macos13_xcode_test,segment_sealing_regression,candidate_range_and_worktree_diff_hygiene' \
	'excludes=playable_interrupted_media_recovery,forced_process_termination,recording_transition,required_source_coordination,system_or_application_audio,multiple_required_sources,finalization,rotation,pause,source_loss,two_hour_capture,playback,transcription,diarization,signing,notarization,distribution,deployment,public_release'
