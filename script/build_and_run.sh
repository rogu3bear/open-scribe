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
	--verify | --logs | --debug | --telemetry | --m1-live-microphone-proof | --m1-dual-source-runtime-proof | --m1-forced-termination-recovery-proof)
		if [[ "$mode" != "run" ]]; then
			printf '%s\n' 'Choose exactly one mode.' >&2
			exit 64
		fi
		mode="$argument"
		;;
	*)
		printf 'usage: %s [--verify|--logs|--debug|--telemetry|--m1-live-microphone-proof|--m1-dual-source-runtime-proof|--m1-forced-termination-recovery-proof]\n' "$0" >&2
		exit 64
		;;
	esac
done

cd "$repo_root"
mkdir -p "$macos_root/.build"
bindings_tmp="$(mktemp -d "$macos_root/.build/uniffi.XXXXXX")"
verify_app_pid=""
proof_root=""
remove_proof_root="false"

cleanup() {
	if [[ -n "$verify_app_pid" ]]; then
		observed_command="$(ps -p "$verify_app_pid" -o comm= 2>/dev/null || true)"
		if [[ "$observed_command" == "$app_binary" ]]; then
			kill "$verify_app_pid" 2>/dev/null || true
			wait "$verify_app_pid" 2>/dev/null || true
		fi
	fi
	if [[ "$remove_proof_root" == "true" && -n "$proof_root" && -d "$proof_root" ]]; then
		rm -rf "$proof_root"
	elif [[ -n "$proof_root" && -d "$proof_root" ]]; then
		printf 'proof_root_retained=%s\n' "$proof_root" >&2
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
--m1-live-microphone-proof | --m1-dual-source-runtime-proof)
	if pgrep -f "^$app_binary([[:space:]]|$)" >/dev/null 2>&1; then
		printf '%s\n' 'M1_LIVE_MICROPHONE_RED: close the existing Open Scribe development app before running the proof' >&2
		exit 1
	fi
	proof_root="$(mktemp -d "$macos_root/.build/m1-live-microphone.XXXXXX")"
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
	[[ "$caf_count" == "2" ]] || {
		printf 'M1_DUAL_SOURCE_RUNTIME_RED: expected two managed CAF source tracks, found %s\n' "$caf_count" >&2
		exit 1
	}
	while IFS= read -r caf_file; do
		caf_bytes="$(stat -f '%z' "$caf_file")"
		[[ "$caf_bytes" -gt 4096 ]] || {
			printf 'M1_DUAL_SOURCE_RUNTIME_RED: managed CAF is unexpectedly small (%s bytes): %s\n' "$caf_bytes" "$caf_file" >&2
			exit 1
		}
		afinfo "$caf_file" >/dev/null
	done < <(find "$proof_root" -type f -name '*.caf' -print | sort)
	[[ "$(sqlite3 "$proof_root/Library.sqlite3" "SELECT COUNT(*) FROM sources WHERE lifecycle = 'sealed';")" == "2" ]] || {
		printf '%s\n' 'M1_DUAL_SOURCE_RUNTIME_RED: both sources were not durably sealed' >&2
		exit 1
	}
	[[ "$(sqlite3 "$proof_root/Library.sqlite3" "SELECT COUNT(*) FROM session_events WHERE event_kind = 'recording_started' AND payload_json LIKE '%microphone%' AND payload_json LIKE '%system_audio%';")" == "1" ]] || {
		printf '%s\n' 'M1_DUAL_SOURCE_RUNTIME_RED: Rust did not durably confirm both required sources in Recording' >&2
		exit 1
	}
	caf_receipts="$(find "$proof_root" -type f -name '*.caf' -print | sort | while IFS= read -r caf_file; do printf '%s:%s:%s;' "$(basename "$(dirname "$caf_file")")" "$(stat -f '%z' "$caf_file")" "$(shasum -a 256 "$caf_file" | awk '{print $1}')"; done)"
	remove_proof_root="true"
	printf '%s\n' \
		'M1_DUAL_SOURCE_RUNTIME_GREEN' \
		"proof=explicit_command,microphone_tcc,screen_and_system_audio_tcc,real_avaudioengine_input,real_screencapturekit_audio,both_durable_first_samples,rust_owned_multi_source_recording,two_managed_cafs,stop_barrier,close_before_seal,rust_independent_digests,independently_playable_cafs,tracks:$caf_receipts" \
		'excludes=source_loss,degraded_continuation,permission_revocation,rotation,disk_pressure,two_hour_capture,transcription,diarization,signing,notarization,distribution,public_release' \
		'media_retained=false'
	;;
--m1-forced-termination-recovery-proof)
	if pgrep -f "^$app_binary([[:space:]]|$)" >/dev/null 2>&1; then
		printf '%s\n' 'M1_FORCED_RECOVERY_RED: close the existing Open Scribe development app before running the proof' >&2
		exit 1
	fi
	proof_root="$(mktemp -d "$macos_root/.build/m1-forced-recovery.XXXXXX")"
	launch_app --m1-forced-termination-capture-root "$proof_root"
	app_pid="$(<"$pid_file")"
	verify_app_pid="$app_pid"
	capture_receipt=""
	for _ in {1..120}; do
		capture_receipt="$(/usr/bin/log show \
			--last 5m \
			--info \
			--style compact \
			--predicate "processIdentifier == $app_pid && subsystem == \"$bundle_id\" && category == \"RecoveryProof\"" \
			2>/dev/null)"
		if [[ "$capture_receipt" == *"stage=capture-durable detail=awaiting-external-kill"* ]]; then
			break
		fi
		if [[ "$capture_receipt" == *"stage=capture-failed"* ]]; then
			printf '%s\n' 'M1_FORCED_RECOVERY_RED: microphone capture failed before forced termination' >&2
			exit 1
		fi
		sleep 0.5
	done
	[[ "$capture_receipt" == *"stage=capture-requested detail=explicit-command"* &&
		"$capture_receipt" == *"stage=capture-durable detail=awaiting-external-kill"* ]] || {
		printf '%s\n' 'M1_FORCED_RECOVERY_RED: durable first-sample receipt was not observed' >&2
		exit 1
	}
	caf_count="$(find "$proof_root" -type f -name '*.caf' | wc -l | tr -d ' ')"
	[[ "$caf_count" == "2" ]] || {
		printf 'M1_FORCED_RECOVERY_RED: expected two managed CAF source tracks, found %s\n' "$caf_count" >&2
		exit 1
	}
	kill -KILL "$app_pid"
	wait "$app_pid" 2>/dev/null || true
	for _ in {1..40}; do
		kill -0 "$app_pid" 2>/dev/null || break
		sleep 0.25
	done
	if kill -0 "$app_pid" 2>/dev/null; then
		printf '%s\n' 'M1_FORCED_RECOVERY_RED: capture process survived SIGKILL' >&2
		exit 1
	fi
	verify_app_pid=""
	sleep 1
	digests_before="$proof_root/caf-digests.before"
	find "$proof_root" -type f -name '*.caf' -print | sort | while IFS= read -r caf_file; do
		afinfo "$caf_file" >/dev/null
		shasum -a 256 "$caf_file"
	done >"$digests_before"
	launch_app --m1-forced-termination-recovery-root "$proof_root"
	recovery_pid="$(<"$pid_file")"
	verify_app_pid="$recovery_pid"
	recovery_receipt=""
	for _ in {1..120}; do
		recovery_receipt="$(/usr/bin/log show \
			--last 5m \
			--info \
			--style compact \
			--predicate "processIdentifier == $recovery_pid && subsystem == \"$bundle_id\" && category == \"RecoveryProof\"" \
			2>/dev/null)"
		if [[ "$recovery_receipt" == *"stage=playback-opened detail=native-audio-engine"* ]]; then
			break
		fi
		if [[ "$recovery_receipt" == *"stage=recovery-failed"* ]]; then
			printf '%s\n' 'M1_FORCED_RECOVERY_RED: relaunch could not recover playable media' >&2
			exit 1
		fi
		sleep 0.5
	done
	[[ "$recovery_receipt" == *"stage=recovered"* &&
		"$recovery_receipt" == *"stage=playback-opened detail=native-audio-engine"* ]] || {
		printf '%s\n' 'M1_FORCED_RECOVERY_RED: recovery and native playback receipts were not both observed' >&2
		exit 1
	}
	for _ in {1..40}; do
		kill -0 "$recovery_pid" 2>/dev/null || break
		sleep 0.25
	done
	if kill -0 "$recovery_pid" 2>/dev/null; then
		printf '%s\n' 'M1_FORCED_RECOVERY_RED: recovery proof process did not terminate' >&2
		exit 1
	fi
	verify_app_pid=""
	digests_after="$proof_root/caf-digests.after"
	find "$proof_root" -type f -name '*.caf' -print | sort | while IFS= read -r caf_file; do
		shasum -a 256 "$caf_file"
	done >"$digests_after"
	cmp "$digests_before" "$digests_after" || {
		printf '%s\n' 'M1_FORCED_RECOVERY_RED: recovery changed one or more captured CAF files' >&2
		exit 1
	}
	decode_index=0
	while IFS= read -r caf_file; do
		afinfo "$caf_file" >/dev/null
		decoded_file="$proof_root/recovered-$decode_index.wav"
		afconvert "$caf_file" "$decoded_file" -f WAVE -d LEI16 >/dev/null
		[[ -s "$decoded_file" ]] || {
			printf 'M1_FORCED_RECOVERY_RED: independent decode produced no output for %s\n' "$caf_file" >&2
			exit 1
		}
		decode_index=$((decode_index + 1))
	done < <(find "$proof_root" -type f -name '*.caf' -print | sort)
	[[ "$(sqlite3 "$proof_root/Library.sqlite3" "SELECT lifecycle FROM sessions;")" == "ready_for_review" ]] || {
		printf '%s\n' 'M1_FORCED_RECOVERY_RED: durable session did not reach Ready for Review' >&2
		exit 1
	}
	[[ "$(sqlite3 "$proof_root/Library.sqlite3" "SELECT COUNT(*) FROM recovery_runs WHERE disposition = 'playable_media_recovered';")" == "1" ]] || {
		printf '%s\n' 'M1_FORCED_RECOVERY_RED: durable recovery receipt is missing or duplicated' >&2
		exit 1
	}
	[[ "$(sqlite3 "$proof_root/Library.sqlite3" "SELECT COUNT(*) FROM sources WHERE lifecycle = 'sealed';")" == "2" &&
	"$(sqlite3 "$proof_root/Library.sqlite3" "SELECT COUNT(*) FROM segments WHERE lifecycle = 'sealed' AND recovery_state = 'recovered';")" == "2" &&
	"$(sqlite3 "$proof_root/Library.sqlite3" "SELECT COUNT(*) FROM session_events WHERE event_kind = 'playable_media_recovered';")" == "2" ]] || {
		printf '%s\n' 'M1_FORCED_RECOVERY_RED: recovery did not atomically preserve both required sources' >&2
		exit 1
	}
	launch_app --m1-forced-termination-recovery-root "$proof_root"
	replay_pid="$(<"$pid_file")"
	verify_app_pid="$replay_pid"
	replay_receipt=""
	for _ in {1..80}; do
		replay_receipt="$(/usr/bin/log show \
			--last 5m \
			--info \
			--style compact \
			--predicate "processIdentifier == $replay_pid && subsystem == \"$bundle_id\" && category == \"RecoveryProof\"" \
			2>/dev/null)"
		[[ "$replay_receipt" == *"stage=playback-opened detail=native-audio-engine"* ]] && break
		sleep 0.25
	done
	[[ "$replay_receipt" == *"stage=recovered"* &&
		"$replay_receipt" == *"stage=playback-opened detail=native-audio-engine"* ]] || {
		printf '%s\n' 'M1_FORCED_RECOVERY_RED: repeated relaunch did not retain playable recovery' >&2
		exit 1
	}
	for _ in {1..40}; do
		kill -0 "$replay_pid" 2>/dev/null || break
		sleep 0.25
	done
	if kill -0 "$replay_pid" 2>/dev/null; then
		printf '%s\n' 'M1_FORCED_RECOVERY_RED: idempotence proof process did not terminate' >&2
		exit 1
	fi
	verify_app_pid=""
	[[ "$(sqlite3 "$proof_root/Library.sqlite3" "SELECT COUNT(*) FROM recovery_runs WHERE disposition = 'playable_media_recovered';")" == "1" ]] || {
		printf '%s\n' 'M1_FORCED_RECOVERY_RED: repeated recovery duplicated its durable receipt' >&2
		exit 1
	}
	cmp "$digests_before" <(find "$proof_root" -type f -name '*.caf' -print | sort | while IFS= read -r caf_file; do shasum -a 256 "$caf_file"; done) || {
		printf '%s\n' 'M1_FORCED_RECOVERY_RED: repeated recovery changed one or more captured CAF files' >&2
		exit 1
	}
	[[ "$(sqlite3 "$proof_root/Library.sqlite3" "SELECT COUNT(*) FROM session_events WHERE event_kind = 'playable_media_recovered';")" == "2" ]] || {
		printf '%s\n' 'M1_FORCED_RECOVERY_RED: repeated recovery duplicated source recovery events' >&2
		exit 1
	}
	caf_receipts="$(find "$proof_root" -type f -name '*.caf' -print | sort | while IFS= read -r caf_file; do printf '%s:%s:%s;' "$(basename "$(dirname "$caf_file")")" "$(stat -f '%z' "$caf_file")" "$(shasum -a 256 "$caf_file" | awk '{print $1}')"; done)"
	remove_proof_root="true"
	printf '%s\n' \
		'M1_FORCED_TERMINATION_RECOVERY_GREEN' \
		"proof=explicit_capture_command,real_microphone_first_sample,real_system_audio_first_sample,rust_owned_multi_source_recording,external_sigkill,process_exit,two_unclosed_cafs_playable,relaunch_scan,journal_first_atomic_recovery,ready_for_review,native_playback_open,independent_afinfo,independent_decode,both_media_bytes_unchanged,idempotent_relaunch,persistent_recovered_conversation,tracks:$caf_receipts" \
		'excludes=source_loss,degraded_continuation,permission_revocation,thirty_second_rotation,disk_pressure,two_hour_capture,transcription,diarization,signing,notarization,distribution,deployment,public_release' \
		'media_retained=false'
	;;
esac
