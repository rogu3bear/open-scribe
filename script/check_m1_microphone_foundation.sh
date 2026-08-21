#!/usr/bin/env bash
set -euo pipefail

script_dir="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
repo_root="$(CDPATH='' cd -- "$script_dir/.." && pwd)"
cd "$repo_root"

"$script_dir/check_m1_media_open.sh"

info_plist="apps/macos/Support/Info.plist"
entitlements="apps/macos/Support/OpenScribe.entitlements"
project="apps/macos/OpenScribe.xcodeproj"

plutil -lint "$info_plist" "$entitlements" >/dev/null
if [[ "$(/usr/libexec/PlistBuddy -c 'Print :com.apple.security.app-sandbox' "$entitlements")" != true ]] ||
	[[ "$(/usr/libexec/PlistBuddy -c 'Print :com.apple.security.device.audio-input' "$entitlements")" != true ]] ||
	[[ "$(/usr/libexec/PlistBuddy -c 'Print :com.apple.security.files.user-selected.read-only' "$entitlements")" != true ]]; then
	printf '%s\n' 'M1_MICROPHONE_FOUNDATION_RED: required least-privilege entitlement is absent' >&2
	exit 1
fi
if [[ "$(plutil -p "$entitlements" | rg -c '=>')" -ne 3 ]]; then
	printf '%s\n' 'M1_MICROPHONE_FOUNDATION_RED: unexpected entitlement entered the development target' >&2
	exit 1
fi
if [[ "$(/usr/libexec/PlistBuddy -c 'Print :NSMicrophoneUsageDescription' "$info_plist")" != "Open Scribe uses the microphone only when you explicitly start a recording that includes it." ]]; then
	printf '%s\n' 'M1_MICROPHONE_FOUNDATION_RED: microphone disclosure drifted' >&2
	exit 1
fi

build_settings="$(xcodebuild \
	-project "$project" \
	-target OpenScribeApp \
	-configuration Debug \
	-showBuildSettings)"
for expected in \
	'CODE_SIGN_ENTITLEMENTS = Support/OpenScribe.entitlements' \
	'ENABLE_APP_SANDBOX = YES' \
	'ENABLE_HARDENED_RUNTIME = YES'; do
	if ! rg -Fq "$expected" <<<"$build_settings"; then
		printf 'M1_MICROPHONE_FOUNDATION_RED: effective Xcode setting absent: %s\n' "$expected" >&2
		exit 1
	fi
done

proof_root="$(mktemp -d "$repo_root/apps/macos/.build/m1-microphone-check.XXXXXX")"
trap 'rm -rf "$proof_root"' EXIT
rust_library="$repo_root/apps/macos/.build/rust-macos13/aarch64-apple-darwin/debug/libopen_scribe_uniffi.a"
if [[ ! -f "$rust_library" ]]; then
	printf '%s\n' 'M1_MICROPHONE_FOUNDATION_RED: exact macOS 13 Rust library is absent' >&2
	exit 1
fi
xcode_log="$proof_root/xcodebuild.log"
if ! xcodebuild \
	-project "$project" \
	-scheme OpenScribeApp \
	-configuration Debug \
	-derivedDataPath "$proof_root/xcode" \
	ARCHS=arm64 \
	ONLY_ACTIVE_ARCH=YES \
	LIBRARY_SEARCH_PATHS="$(dirname "$rust_library")" \
	MACOSX_DEPLOYMENT_TARGET=13.0 \
	CODE_SIGNING_ALLOWED=NO \
	test \
	-only-testing:OpenScribeAppTests/MicrophoneCaptureAdapterTests 2>&1 | tee "$xcode_log"; then
	printf '%s\n' 'M1_MICROPHONE_FOUNDATION_RED: deterministic microphone adapter tests failed' >&2
	exit 1
fi
if rg -n '/Sources/.*warning:' "$xcode_log"; then
	printf '%s\n' 'M1_MICROPHONE_FOUNDATION_RED: project source emitted a Swift warning' >&2
	exit 1
fi

if rg -ni '\b(pcm|cmsamplebuffer|waveform|meter|pointer)\b' crates/open-scribe-uniffi/src; then
	printf '%s\n' 'M1_MICROPHONE_FOUNDATION_RED: hot-path media or telemetry crossed UniFFI' >&2
	exit 1
fi

git diff --check

printf '%s\n' \
	'M1_MICROPHONE_FOUNDATION_GREEN' \
	'proof=managed_caf_writer,swift_owned_bounded_buffer_pool,dedicated_serial_writer_queue,serialized_capture_lifecycle,nonblocking_callback_failure_path,stop_write_barrier,format_conversion_to_48khz_mono,one_shot_first_sample_receipt,rust_journal_before_projection,first_sample_frame_count_event_only,deterministic_first_sample_interruption_recovery,coarse_uniffi_boundary,permission_state_mapping,just_in_time_microphone_disclosure,least_privilege_entitlement_source,effective_xcode_sandbox_and_hardened_runtime_settings,no_recording_transition,fresh_bindings,clean_arm64_macos13_build,microphone_adapter_failure_and_race_tests,no_project_swift_warnings,m1_media_open_regression,m0_regression,diff_hygiene' \
	'excludes=live_permission_prompt,live_microphone_runtime_capture,signed_entitlement_enforcement,system_audio_capture,multiple_required_sources,recording_transition,active_session_recovery,segment_sealing,two_hour_capture,playback,disk_pressure,route_changes,signing,notarization,distribution,deployment,release'
