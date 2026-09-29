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
candidate_record=""
# shellcheck source=script/candidate.sh
source "$script_dir/candidate.sh"

while [[ "$#" -gt 0 ]]; do
	argument="$1"
	case "$argument" in
	--candidate)
		[[ "$#" -ge 2 && -z "$candidate_record" ]] || candidate_fail 'one candidate record is required'
		candidate_record="$2"
		shift
		;;
	--verify | --verify-recording | --logs | --debug | --telemetry | --m1-live-microphone-proof | --m1-dual-source-runtime-proof | --m1-forced-termination-recovery-proof)
		if [[ "$mode" != "run" ]]; then
			printf '%s\n' 'Choose exactly one mode.' >&2
			exit 64
		fi
		mode="$argument"
		;;
	*)
		printf 'usage: %s [--verify|--verify-recording|--logs|--debug|--telemetry|--m1-live-microphone-proof|--m1-dual-source-runtime-proof|--m1-forced-termination-recovery-proof] [--candidate /absolute/path/candidate.json]\n' "$0" >&2
		exit 64
		;;
	esac
	shift
done

cd "$repo_root"
case "$mode" in
--verify-recording | --m1-live-microphone-proof | --m1-dual-source-runtime-proof | --m1-forced-termination-recovery-proof)
	[[ -n "$candidate_record" ]] || candidate_fail 'this gate requires --candidate /absolute/path/candidate.json; it never rebuilds'
	;;
esac
if [[ -n "$candidate_record" ]]; then
	candidate_load "$candidate_record"
	if [[ "$mode" != --verify ]]; then candidate_require_checks; fi
	if pgrep -x OpenScribeApp >/dev/null; then
		candidate_fail 'close the existing development app before consuming a candidate'
	fi
fi
mkdir -p "$macos_root/.build"
bindings_tmp=""
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
	if [[ -n "$bindings_tmp" ]]; then rm -rf "$bindings_tmp"; fi
}
trap cleanup EXIT

if [[ -z "$candidate_record" ]]; then
	bindings_tmp="$(mktemp -d "$macos_root/.build/uniffi.XXXXXX")"
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
fi

app_bundle="$derived_data/Build/Products/Debug/OpenScribeApp.app"
app_binary="$app_bundle/Contents/MacOS/$app_name"
pid_file="$macos_root/.build/$app_name.pid"

artifact_digests() {
	local artifact
	for artifact in "$app_binary" "$app_bundle/Contents/MacOS/$app_name.debug.dylib" "$app_bundle/Contents/Info.plist"; do
		[[ -f "$artifact" ]] || {
			printf 'M1_ARTIFACT_RED: required Debug app artifact is missing: %s\n' "$artifact" >&2
			return 1
		}
		printf '%s:%s;' "${artifact#"$app_bundle"/}" "$(shasum -a 256 "$artifact" | cut -d ' ' -f 1)"
	done
}

if [[ -z "$candidate_record" && -f "$pid_file" ]]; then
	prior_pid="$(<"$pid_file")"
	if [[ "$prior_pid" =~ ^[0-9]+$ ]]; then
		prior_command="$(ps -p "$prior_pid" -o comm= 2>/dev/null || true)"
		if [[ "$prior_command" == "$app_binary" ]]; then
			kill "$prior_pid"
		fi
	fi
	rm -f "$pid_file"
fi

if [[ -z "$candidate_record" ]]; then
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
fi

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
--verify | --verify-recording)
	test_filters=()
	if [[ "$mode" == "--verify-recording" ]]; then
		# These suites use injected capture backends and file buffers, with no
		# microphone, ScreenCaptureKit stream, or speaker playback.
		test_filters=(
			-only-testing:OpenScribeAppTests/TimelineWorkflowTests
			-only-testing:OpenScribeAppTests/RecorderPauseResumeTests
			-only-testing:OpenScribeAppTests/MicrophoneCaptureAdapterTests
			-only-testing:OpenScribeAppTests/SystemAudioCaptureAdapterTests
			-only-testing:OpenScribeAppTests/LiveMicrophoneRecordingControllerTests
			-only-testing:OpenScribeAppTests/MediaOpenProtocolTests
		)
	fi
	if [[ -n "$candidate_record" ]]; then
		candidate_assert
		xcodebuild test-without-building -xctestrun "$xctestrun" \
			-destination 'platform=macOS,arch=arm64' \
			${test_filters[@]+"${test_filters[@]}"}
		candidate_receipt
	else
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
			${test_filters[@]+"${test_filters[@]}"} \
			test
	fi
	if [[ "$mode" == "--verify-recording" ]]; then
		component_app_digests="$(artifact_digests)"
		printf '%s\n' \
			'RECORDING_COMPONENTS_GREEN' \
			"app_bundle=$app_bundle" \
			"app_digests=$component_app_digests" \
			'proof=fresh_rust_bindings,xcode_app_build,synthetic_capture,writer_drain,source_loss_controller,media_receipts,shared_timeline,segment_rotation,gap_preserving_pcm_playback,product_pause_resume,paused_finalization' \
			'excludes=real_capture,permissions,audible_output,long_sessions,m1_completion,signing,release'
		exit 0
	fi
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
	if [[ -n "$candidate_record" ]]; then candidate_receipt; fi
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
	app_digests_before="$(artifact_digests)"
	[[ -n "$app_digests_before" ]] || {
		printf '%s\n' 'M1_DUAL_SOURCE_RUNTIME_RED: built app identity is unavailable' >&2
		exit 1
	}
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
	database="$proof_root/Library.sqlite3"
	[[ "$(sqlite3 -readonly "$database" 'SELECT COUNT(*) FROM sessions;')" == 1 ]] || {
		printf '%s\n' 'M1_DUAL_SOURCE_RUNTIME_RED: proof did not own exactly one session' >&2
		exit 1
	}
	session_id="$(sqlite3 -readonly "$database" "SELECT id FROM sessions WHERE lifecycle = 'ready_for_review' AND origin = 'capture';")"
	[[ -n "$session_id" ]] || {
		printf '%s\n' 'M1_DUAL_SOURCE_RUNTIME_RED: capture was not durably saved' >&2
		exit 1
	}
	caf_count="$(find "$proof_root/Sessions" -type f -name '*.caf' | wc -l | tr -d ' ')"
	sealed_count="$(sqlite3 -readonly "$database" "SELECT COUNT(*) FROM segments WHERE lifecycle = 'sealed' AND sample_count > 0 AND digest IS NOT NULL;")"
	[[ "$caf_count" -ge 2 && "$sealed_count" == "$caf_count" &&
		"$(sqlite3 -readonly "$database" 'SELECT COUNT(*) FROM segments;')" == "$caf_count" ]] || {
		printf 'M1_DUAL_SOURCE_RUNTIME_RED: CAF files and sealed segment rows disagree (files=%s, sealed=%s)\n' "$caf_count" "$sealed_count" >&2
		exit 1
	}
	[[ "$(sqlite3 "$proof_root/Library.sqlite3" "SELECT COUNT(*) FROM sources WHERE lifecycle = 'sealed';")" == "2" ]] || {
		printf '%s\n' 'M1_DUAL_SOURCE_RUNTIME_RED: both sources were not durably sealed' >&2
		exit 1
	}
	[[ "$(sqlite3 -readonly "$database" "SELECT COUNT(*) FROM (SELECT sources.kind FROM sources JOIN tracks ON tracks.source_id = sources.id JOIN segments ON segments.track_id = tracks.id WHERE segments.lifecycle = 'sealed' AND sources.kind IN ('microphone', 'system_audio') GROUP BY sources.kind HAVING SUM(segments.sample_count) >= 4800);")" == 2 ]] || {
		printf '%s\n' 'M1_DUAL_SOURCE_RUNTIME_RED: both sources lack a sustained saved span' >&2
		exit 1
	}
	[[ "$(sqlite3 "$proof_root/Library.sqlite3" "SELECT COUNT(*) FROM session_events WHERE event_kind = 'recording_started' AND payload_json LIKE '%microphone%' AND payload_json LIKE '%system_audio%';")" == "1" ]] || {
		printf '%s\n' 'M1_DUAL_SOURCE_RUNTIME_RED: Rust did not durably confirm both required sources in Recording' >&2
		exit 1
	}
	caf_receipts=""
	decode_index=0
	while IFS='|' read -r relative_path expected_digest expected_bytes expected_samples expected_channels; do
		caf_file="$proof_root/Sessions/$session_id/$relative_path"
		[[ -f "$caf_file" && ! -L "$caf_file" && "$expected_samples" -gt 0 &&
			("$expected_channels" == 1 || "$expected_channels" == 2) ]] || {
			printf 'M1_DUAL_SOURCE_RUNTIME_RED: invalid saved segment: %s\n' "$relative_path" >&2
			exit 1
		}
		actual_digest="$(shasum -a 256 "$caf_file" | cut -d ' ' -f 1)"
		[[ "$actual_digest" == "$expected_digest" && "$(stat -f '%z' "$caf_file")" == "$expected_bytes" ]] || {
			printf 'M1_DUAL_SOURCE_RUNTIME_RED: Rust media evidence differs from %s\n' "$relative_path" >&2
			exit 1
		}
		afinfo "$caf_file" >/dev/null
		decoded_file="$proof_root/decoded-$decode_index.wav"
		afconvert "$caf_file" "$decoded_file" -f WAVE -d LEI16 >/dev/null
		[[ -f "$decoded_file" && "$(stat -f '%z' "$decoded_file")" -gt 44 ]] || {
			printf 'M1_DUAL_SOURCE_RUNTIME_RED: independent decode failed for %s\n' "$relative_path" >&2
			exit 1
		}
		caf_receipts+="$relative_path:$expected_samples:$expected_channels:$actual_digest;"
		decode_index=$((decode_index + 1))
	done < <(sqlite3 -readonly "$database" "SELECT relative_path || '|' || digest || '|' || byte_length || '|' || sample_count || '|' || channels FROM segments ORDER BY relative_path;")
	[[ "$decode_index" == "$caf_count" && "$(artifact_digests)" == "$app_digests_before" ]] || {
		printf '%s\n' 'M1_DUAL_SOURCE_RUNTIME_RED: decoded segment count or built app identity changed' >&2
		exit 1
	}
	rm -f "$proof_root"/decoded-*.wav
	candidate_require_checks
	candidate_receipt
	printf '%s\n' \
		'M1_DUAL_SOURCE_RUNTIME_GREEN' \
		"app_bundle=$app_bundle" \
		"app_digests=$app_digests_before" \
		"session_id=$session_id" \
		"proof=explicit_command,microphone_tcc,screen_and_system_audio_tcc,real_avaudioengine_input,real_screencapturekit_audio,both_durable_first_samples,rust_owned_multi_source_recording,segment_count:$caf_count,stop_barrier,close_before_seal,rust_matching_media_digests,independently_decodable_cafs,tracks:$caf_receipts" \
		'excludes=forced_termination_recovery,native_playback,source_loss,degraded_continuation,permission_revocation,application_selection,rotation,disk_pressure,two_hour_capture,transcription,diarization,signing,notarization,distribution,public_release' \
		"proof_root=$proof_root" \
		'media_retained=true'
	;;
--m1-forced-termination-recovery-proof)
	app_digests_before="$(artifact_digests)"
	[[ -n "$app_digests_before" ]] || {
		printf '%s\n' 'M1_FORCED_RECOVERY_RED: built app identity is unavailable' >&2
		exit 1
	}
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
	[[ "$(sqlite3 -readonly "$proof_root/Library.sqlite3" "SELECT COUNT(*) FROM sessions WHERE lifecycle = 'recording' AND media_files_open = 1;")" == 1 ]] || {
		printf '%s\n' 'M1_FORCED_RECOVERY_RED: dual-source Recording was not durable' >&2
		exit 1
	}
	sleep 35
	[[ "$(ps -p "$app_pid" -o comm= 2>/dev/null)" == "$app_binary" &&
	"$(sqlite3 -readonly "$proof_root/Library.sqlite3" "SELECT COUNT(*) FROM sources WHERE lifecycle = 'capturing' AND kind IN ('microphone', 'system_audio');")" == 2 ]] || {
		printf '%s\n' 'M1_FORCED_RECOVERY_RED: both real sources did not continue through the segmented span' >&2
		exit 1
	}
	caf_count="$(find "$proof_root" -type f -name '*.caf' | wc -l | tr -d ' ')"
	[[ "$caf_count" -ge 4 &&
		"$(sqlite3 -readonly "$proof_root/Library.sqlite3" "SELECT COUNT(*) FROM (SELECT sources.kind FROM sources JOIN tracks ON tracks.source_id = sources.id JOIN segments ON segments.track_id = tracks.id WHERE sources.kind IN ('microphone', 'system_audio') AND segments.original_start IS NOT NULL GROUP BY sources.kind HAVING COUNT(*) >= 2);")" == 2 &&
		"$(sqlite3 -readonly "$proof_root/Library.sqlite3" "SELECT COUNT(DISTINCT sources.kind) FROM sources JOIN tracks ON tracks.source_id = sources.id JOIN segments ON segments.track_id = tracks.id WHERE sources.kind IN ('microphone', 'system_audio') AND segments.lifecycle = 'capturing' AND segments.original_start IS NOT NULL;")" == 2 ]] || {
		printf 'M1_FORCED_RECOVERY_RED: both sources need prior segments and live first-sampled tails before SIGKILL (files=%s)\n' "$caf_count" >&2
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
		[[ -f "$decoded_file" && "$(stat -f '%z' "$decoded_file")" -gt 44 ]] || {
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
	caf_count_after="$(find "$proof_root/Sessions" -type f -name '*.caf' | wc -l | tr -d ' ')"
	[[ "$(sqlite3 "$proof_root/Library.sqlite3" "SELECT COUNT(*) FROM sources WHERE lifecycle = 'sealed';")" == "2" &&
	"$(sqlite3 -readonly "$proof_root/Library.sqlite3" "SELECT COUNT(*) FROM segments WHERE lifecycle = 'sealed' AND sample_count > 0 AND digest IS NOT NULL;")" == "$caf_count_after" &&
	"$(sqlite3 -readonly "$proof_root/Library.sqlite3" "SELECT COUNT(*) FROM (SELECT sources.kind FROM sources JOIN tracks ON tracks.source_id = sources.id JOIN segments ON segments.track_id = tracks.id WHERE sources.kind IN ('microphone', 'system_audio') AND segments.lifecycle = 'sealed' GROUP BY sources.kind HAVING COUNT(*) >= 2 AND SUM(segments.sample_count) >= 1440000);")" == 2 &&
	"$(sqlite3 "$proof_root/Library.sqlite3" "SELECT COUNT(*) FROM segments WHERE lifecycle = 'sealed' AND recovery_state = 'recovered';")" == "2" &&
	"$(sqlite3 "$proof_root/Library.sqlite3" "SELECT COUNT(*) FROM session_events WHERE event_kind = 'playable_media_recovered';")" == "2" &&
	"$(sqlite3 -readonly "$proof_root/Library.sqlite3" "SELECT COUNT(DISTINCT sources.kind) FROM session_events JOIN sources ON sources.id = json_extract(session_events.payload_json, '$.source_id') WHERE session_events.event_kind = 'playable_media_recovered';")" == 2 ]] || {
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
	session_id="$(sqlite3 -readonly "$proof_root/Library.sqlite3" "SELECT id FROM sessions WHERE lifecycle = 'ready_for_review' AND origin = 'capture';")"
	[[ -n "$session_id" ]] || {
		printf '%s\n' 'M1_FORCED_RECOVERY_RED: recovered session identity is missing' >&2
		exit 1
	}
	caf_receipts=""
	receipt_count=0
	while IFS='|' read -r relative_path expected_digest expected_bytes expected_samples expected_channels; do
		caf_file="$proof_root/Sessions/$session_id/$relative_path"
		[[ -f "$caf_file" && ! -L "$caf_file" && "$expected_samples" -gt 0 &&
			("$expected_channels" == 1 || "$expected_channels" == 2) ]] || {
			printf 'M1_FORCED_RECOVERY_RED: invalid recovered segment: %s\n' "$relative_path" >&2
			exit 1
		}
		actual_digest="$(shasum -a 256 "$caf_file" | cut -d ' ' -f 1)"
		[[ "$actual_digest" == "$expected_digest" && "$(stat -f '%z' "$caf_file")" == "$expected_bytes" ]] || {
			printf 'M1_FORCED_RECOVERY_RED: Rust media evidence differs from %s\n' "$relative_path" >&2
			exit 1
		}
		caf_receipts+="$relative_path:$expected_samples:$expected_channels:$actual_digest;"
		receipt_count=$((receipt_count + 1))
	done < <(sqlite3 -readonly "$proof_root/Library.sqlite3" "SELECT relative_path || '|' || digest || '|' || byte_length || '|' || sample_count || '|' || channels FROM segments WHERE lifecycle = 'sealed' ORDER BY relative_path;")
	[[ "$receipt_count" == "$caf_count_after" && "$(artifact_digests)" == "$app_digests_before" ]] || {
		printf '%s\n' 'M1_FORCED_RECOVERY_RED: recovered media count or built app identity changed' >&2
		exit 1
	}
	rm -f "$proof_root"/recovered-*.wav
	candidate_require_checks
	candidate_receipt
	printf '%s\n' \
		'M1_FORCED_TERMINATION_RECOVERY_GREEN' \
		"app_bundle=$app_bundle" \
		"app_digests=$app_digests_before" \
		"session_id=$session_id" \
		"recovery_result=ready_for_review,two_recovered_tails,${caf_count_after}_verified_segments,idempotent_relaunch" \
		"proof=explicit_capture_command,real_microphone_first_sample,real_system_audio_first_sample,rust_owned_multi_source_recording,segmented_two_track_capture,thirty_second_pcm_coverage,external_sigkill,process_exit,relaunch_scan,journal_first_atomic_recovery,ready_for_review,native_playback_open,independent_afinfo,independent_decode,all_media_bytes_unchanged,rust_matching_media_digests,idempotent_relaunch,persistent_recovered_conversation,tracks:$caf_receipts" \
		'excludes=source_loss,degraded_continuation,permission_revocation,application_selection,audible_output,disk_pressure,two_hour_capture,transcription,diarization,signing,notarization,distribution,deployment,public_release' \
		"proof_root=$proof_root" \
		'media_retained=true'
	;;
esac
