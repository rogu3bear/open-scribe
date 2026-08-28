#!/usr/bin/env bash
set -euo pipefail

script_dir="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
repo_root="$(CDPATH='' cd -- "$script_dir/.." && pwd)"
cd "$repo_root"

"$script_dir/check_m1_interruption_state.sh"

proof_root="$(mktemp -d "$repo_root/apps/macos/.build/m1-forced-recovery-gate.XXXXXX")"
trap 'rm -rf "$proof_root"' EXIT
rust_library="$(bash "$script_dir/build_rust_macos.sh" "$proof_root/rust")"
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
	-only-testing:OpenScribeAppTests/RecoveredSessionControllerTests 2>&1 | tee "$xcode_log"; then
	printf '%s\n' 'M1_FORCED_TERMINATION_RECOVERY_RED: native recovery controller proof failed' >&2
	exit 1
fi
if rg -n '/Sources/.*warning:' "$xcode_log"; then
	printf '%s\n' 'M1_FORCED_TERMINATION_RECOVERY_RED: project source emitted a Swift warning' >&2
	exit 1
fi

"$script_dir/build_and_run.sh" --m1-forced-termination-recovery-proof

candidate_base="$(git merge-base HEAD main 2>/dev/null || true)"
if [[ -z "$candidate_base" || "$candidate_base" == "$(git rev-parse HEAD)" ]]; then
	candidate_base="$(git rev-parse HEAD^)"
fi
git diff --check "$candidate_base" HEAD
git diff --check

printf '%s\n' \
	'M1_FORCED_TERMINATION_RECOVERY_GATE_GREEN' \
	'proof=interruption_state_regression,recovery_planning_before_mutation,journal_first_projection_repair,strict_unclosed_pcm_caf_validation,content_free_durable_recovery_receipt,ready_for_review_projection,persistent_recovered_conversation,native_playback_controller,real_microphone_first_sample,external_sigkill,relaunch_scan,independent_playable_media_decode,unchanged_media_digest,idempotent_relaunch,fresh_bindings,clean_arm64_macos13_tests,candidate_range_and_worktree_diff_hygiene' \
	'excludes=recording_transition,system_or_application_audio,multiple_required_sources,thirty_second_rotation,source_loss,disk_pressure,two_hour_capture,transcription,diarization,signing,notarization,distribution,deployment,public_release'
