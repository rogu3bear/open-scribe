#!/usr/bin/env bash
set -euo pipefail

script_dir="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
repo_root="$(CDPATH='' cd -- "$script_dir/.." && pwd)"
macos_root="$repo_root/apps/macos"
app_name="OpenScribeApp"
bundle_id="app.open-scribe.dev"
xcode_project="$macos_root/OpenScribe.xcodeproj"
derived_data="$macos_root/.build/xcode"
rust_target_dir="$macos_root/.build/rust-macos13"
mode="run"

for argument in "$@"; do
	case "$argument" in
	--verify | --logs | --debug | --telemetry | --m1-live-microphone-proof)
		if [[ "$mode" != "run" ]]; then
			printf '%s\n' 'Choose exactly one mode.' >&2
			exit 64
		fi
		mode="$argument"
		;;
	*)
		printf 'usage: %s [--verify|--logs|--debug|--telemetry|--m1-live-microphone-proof]\n' "$0" >&2
		exit 64
		;;
	esac
done

cd "$repo_root"
mkdir -p "$macos_root/.build"
bindings_tmp="$(mktemp -d "$macos_root/.build/uniffi.XXXXXX")"
verify_app_pid=""

cleanup() {
	if [[ -n "$verify_app_pid" ]]; then
		observed_command="$(ps -p "$verify_app_pid" -o comm= 2>/dev/null || true)"
		if [[ "$observed_command" == "$app_binary" ]]; then
			kill "$verify_app_pid" 2>/dev/null || true
			wait "$verify_app_pid" 2>/dev/null || true
		fi
	fi
	rm -rf "$bindings_tmp"
}
trap cleanup EXIT

rust_library="$(bash "$script_dir/build_rust_macos.sh" "$rust_target_dir")"
CARGO_TARGET_DIR="$rust_target_dir" cargo run --locked -p open-scribe-uniffi \
	--features bindgen \
	--bin uniffi-bindgen \
	-- generate \
	--library "$rust_library" \
	--language swift \
	--out-dir "$bindings_tmp"
xcrun swift-format format --in-place "$bindings_tmp/OpenScribeCore.swift"
xcrun clang-format -i "$bindings_tmp/OpenScribeFFI.h"

cmp "$bindings_tmp/OpenScribeCore.swift" \
	"$macos_root/Sources/OpenScribeApp/Generated/OpenScribeCore.swift" || {
	printf '%s\n' 'M0_NATIVE_RED: generated Swift binding is stale' >&2
	exit 1
}
cmp "$bindings_tmp/OpenScribeFFI.h" \
	"$macos_root/Sources/OpenScribeFFI/include/OpenScribeFFI.h" || {
	printf '%s\n' 'M0_NATIVE_RED: generated C binding is stale' >&2
	exit 1
}

app_bundle="$derived_data/Build/Products/Debug/OpenScribeApp.app"
app_binary="$app_bundle/Contents/MacOS/$app_name"
pid_file="$macos_root/.build/$app_name.pid"

if [[ -f "$pid_file" ]]; then
	prior_pid="$(<"$pid_file")"
	if [[ "$prior_pid" =~ ^[0-9]+$ ]]; then
		prior_command="$(ps -p "$prior_pid" -o comm= 2>/dev/null || true)"
		if [[ "$prior_command" == "$app_binary" ]]; then
			kill "$prior_pid"
		fi
	fi
	rm -f "$pid_file"
fi

xcodebuild \
	-project "$xcode_project" \
	-scheme OpenScribeApp \
	-configuration Debug \
	-derivedDataPath "$derived_data" \
	ARCHS=arm64 \
	ONLY_ACTIVE_ARCH=YES \
	LIBRARY_SEARCH_PATHS="$(dirname "$rust_library")" \
	MACOSX_DEPLOYMENT_TARGET=13.0 \
	CODE_SIGNING_ALLOWED=NO \
	build

launch_app() {
	if [[ "$#" -gt 0 ]]; then
		/usr/bin/open -n "$app_bundle" --args "$@"
	else
		/usr/bin/open -n "$app_bundle"
	fi
	for _ in {1..20}; do
		app_pid="$(pgrep -n -f "$app_binary" || true)"
		if [[ -n "$app_pid" ]]; then
			printf '%s\n' "$app_pid" >"$pid_file"
			return 0
		fi
		sleep 0.2
	done
	printf '%s\n' 'M0_NATIVE_RED: exact app process was not observed after launch' >&2
	return 1
}

case "$mode" in
run)
	launch_app
	;;
--verify)
	xcodebuild \
		-project "$xcode_project" \
		-scheme OpenScribeApp \
		-configuration Debug \
		-derivedDataPath "$derived_data" \
		ARCHS=arm64 \
		ONLY_ACTIVE_ARCH=YES \
		LIBRARY_SEARCH_PATHS="$(dirname "$rust_library")" \
		MACOSX_DEPLOYMENT_TARGET=13.0 \
		CODE_SIGNING_ALLOWED=NO \
		test
	launch_app --m0-proof-settings
	app_pid="$(<"$pid_file")"
	verify_app_pid="$app_pid"
	observed_command="$(ps -p "$app_pid" -o comm=)"
	[[ "$observed_command" == "$app_binary" ]] || {
		printf '%s\n' 'M0_NATIVE_RED: observed process does not match staged app' >&2
		exit 1
	}
	scene_receipt=""
	for _ in {1..20}; do
		scene_receipt="$(/usr/bin/log show \
			--last 1m \
			--info \
			--style compact \
			--predicate "processIdentifier == $app_pid && subsystem == \"$bundle_id\" && category == \"Scenes\"" \
			2>/dev/null)"
		if [[ "$scene_receipt" == *"scene=primary"* && "$scene_receipt" == *"scene=menu-bar"* && "$scene_receipt" == *"scene=settings"* ]]; then
			break
		fi
		sleep 0.2
	done
	[[ "$scene_receipt" == *"scene=primary"* && "$scene_receipt" == *"scene=menu-bar"* && "$scene_receipt" == *"scene=settings"* ]] || {
		printf '%s\n' 'M0_NATIVE_RED: primary, menu-bar, or settings scene telemetry was not observed' >&2
		exit 1
	}
	printf '%s\n' \
		'NATIVE_FIXTURE_XCODE_GREEN' \
		'proof=rust_staticlib,uniffi_regeneration,xcode_app_build,xcode_test_host,swift_binding_test,xcode_owned_development_app,exact_process_launch,primary_scene_log,menu_bar_scene_log,settings_scene_log' \
		'excludes=capture,persistence,recovery,transcription,diarization,ocr,context,providers,llm,signing,notarization,release'
	;;
--debug)
	exec lldb -- "$app_binary"
	;;
--logs)
	launch_app
	exec /usr/bin/log stream --info --style compact --predicate "process == \"$app_name\""
	;;
--telemetry)
	launch_app
	exec /usr/bin/log stream --info --style compact --predicate "subsystem == \"$bundle_id\""
	;;
--m1-live-microphone-proof)
	if pgrep -f "^$app_binary([[:space:]]|$)" >/dev/null 2>&1; then
		printf '%s\n' 'M1_LIVE_MICROPHONE_RED: close the existing Open Scribe development app before running the proof' >&2
		exit 1
	fi
	proof_root="$(mktemp -d "$macos_root/.build/m1-live-microphone.XXXXXX")"
	trap 'rm -rf "$proof_root"' EXIT
	launch_app --m1-live-microphone-proof-root "$proof_root"
	app_pid="$(<"$pid_file")"
	verify_app_pid="$app_pid"
	capture_receipt=""
	for _ in {1..120}; do
		capture_receipt="$(/usr/bin/log show \
			--last 5m \
			--info \
			--style compact \
			--predicate "processIdentifier == $app_pid && subsystem == \"$bundle_id\" && category == \"CaptureProof\"" \
			2>/dev/null)"
		if [[ "$capture_receipt" == *"stage=saved detail=saved"* ]]; then
			break
		fi
		if [[ "$capture_receipt" == *"stage=failed"* ]]; then
			printf '%s\n' 'M1_LIVE_MICROPHONE_RED: the explicit app proof reported capture failure' >&2
			printf '%s\n' "$capture_receipt" >&2
			exit 1
		fi
		sleep 0.5
	done
	[[ "$capture_receipt" == *"stage=requested detail=explicit-command"* &&
		"$capture_receipt" == *"stage=capturing detail=first-sample-durable"* &&
		"$capture_receipt" == *"stage=saved detail=saved"* ]] || {
		printf '%s\n' 'M1_LIVE_MICROPHONE_RED: requested, first-sample, and saved runtime receipts were not all observed' >&2
		exit 1
	}
	caf_count="$(find "$proof_root" -type f -name '*.caf' | wc -l | tr -d ' ')"
	[[ "$caf_count" == "1" ]] || {
		printf 'M1_LIVE_MICROPHONE_RED: expected one managed CAF, found %s\n' "$caf_count" >&2
		exit 1
	}
	caf_file="$(find "$proof_root" -type f -name '*.caf' -print -quit)"
	caf_bytes="$(stat -f '%z' "$caf_file")"
	[[ "$caf_bytes" -gt 4096 ]] || {
		printf 'M1_LIVE_MICROPHONE_RED: managed CAF is unexpectedly small (%s bytes)\n' "$caf_bytes" >&2
		exit 1
	}
	afinfo "$caf_file" >/dev/null
	caf_digest="$(shasum -a 256 "$caf_file" | awk '{print $1}')"
	printf '%s\n' \
		'M1_LIVE_MICROPHONE_GREEN' \
		"proof=explicit_command,microphone_tcc,real_avaudioengine_input,durable_first_sample,managed_caf,stop_barrier,close_before_seal,rust_independent_digest,playable_caf,bytes:$caf_bytes,sha256:$caf_digest" \
		'excludes=recording_transition,system_or_application_audio,multiple_required_sources,active_session_recovery,forced_termination_recovery,rotation,two_hour_capture,transcription,diarization,signing,notarization,distribution,public_release' \
		'media_retained=false'
	;;
esac
