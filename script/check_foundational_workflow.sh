#!/usr/bin/env bash
set -euo pipefail

# Default proof is synthetic. --live requires explicit microphone, system-audio,
# and audible-playback authorization; it records 35 seconds after startup.
# The proof root is this run's own temporary state: it is removed after a green
# run unless --retain is given, and kept for diagnosis after a failure. Roots
# left by earlier runs are reported, never deleted.
script_dir="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
repo_root="$(CDPATH='' cd -- "$script_dir/.." && pwd -P)"
cd "$repo_root"
# shellcheck source=script/candidate.sh
source "$script_dir/candidate.sh"
usage='usage: check_foundational_workflow.sh --candidate /absolute/path/candidate.json [--synthetic|--live] [--retain]'
[[ "$#" -ge 2 && "$1" == --candidate ]] || candidate_fail "$usage"
candidate_load "$2"
candidate_require_checks
shift 2
mode='--synthetic'
retain=0
for argument in "$@"; do
	case "$argument" in
	--synthetic | --live) mode="$argument" ;;
	--retain) retain=1 ;;
	*)
		printf '%s\n' "$usage" >&2
		exit 64
		;;
	esac
done
capture_flag='--foundation-synthetic-capture-root'
recovery_flag='--foundation-synthetic-recovery-root'
if [[ "$mode" == '--live' ]]; then
	capture_flag='--m1-forced-termination-capture-root'
	recovery_flag='--foundation-live-recovery-root'
fi
[[ "$app_binary" == /* && -x "$app_binary" ]] || exit 64
if pgrep -x OpenScribeApp >/dev/null; then
	printf '%s\n' 'FOUNDATION_HOLD: close the running app before this isolated process proof.' >&2
	exit 1
fi
temporary_root="${TMPDIR:-/tmp}"
temporary_root="${temporary_root%/}"
shopt -s nullglob
prior_roots=("$temporary_root"/open-scribe-foundation.*)
shopt -u nullglob
printf 'prior_proof_roots=%s (not owned by this run; left in place)\n' "${#prior_roots[@]}"
for prior_root in ${prior_roots[@]+"${prior_roots[@]}"}; do
	printf 'prior_proof_root=%s\n' "$prior_root"
done
proof_root="$(mktemp -d "$temporary_root/open-scribe-foundation.XXXXXX")"
capture_pid=""
recovery_pid=""
succeeded=0
cleanup() {
	for pid in "$capture_pid" "$recovery_pid"; do
		if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
			kill "$pid" 2>/dev/null || true
			wait "$pid" 2>/dev/null || true
		fi
	done
	if ((succeeded == 1 && retain == 0)) && [[ "$proof_root" == "$temporary_root"/open-scribe-foundation.* ]]; then
		rm -rf -- "$proof_root"
		printf 'proof_root_removed=%s\n' "$proof_root"
	elif ((succeeded == 1)); then
		printf 'proof_root_retained=%s\n' "$proof_root"
	else
		printf 'proof_root_retained_for_diagnosis=%s\n' "$proof_root" >&2
	fi
}
trap cleanup EXIT
# Stock macOS bash 3.2 does not exit on a failing [[ ]] under set -e, so every
# proof condition fails explicitly.
fail_proof() {
	if [[ -f "$proof_root/proof-error" ]]; then
		cat "$proof_root/proof-error" >&2
	fi
	printf 'FOUNDATION_RED: %s\n' "$1" >&2
	exit 1
}
# A Debug build's executable is a stub shared across builds; its debug dylib
# carries the compiled app. Info.plist binds the bundle identity and usage
# declarations. All three are bound before the run and rechecked after.
artifact_digests() {
	local artifact
	for artifact in "$app_binary" "$(dirname "$app_binary")/OpenScribeApp.debug.dylib" "$(dirname "$(dirname "$app_binary")")/Info.plist"; do
		[[ -f "$artifact" ]] || fail_proof "required Debug app artifact is missing: $artifact"
		printf 'artifact_sha256=%s %s\n' "$(shasum -a 256 "$artifact" | cut -d ' ' -f 1)" "$(basename "$artifact")"
	done
}
artifacts_before="$(artifact_digests)"
"$app_binary" "$capture_flag" "$proof_root" >"$proof_root/capture.log" 2>&1 &
capture_pid=$!
for _ in {1..600}; do
	if [[ "$mode" == '--live' && -f "$proof_root/Library.sqlite3" ]]; then
		recording="$(sqlite3 -readonly "$proof_root/Library.sqlite3" "SELECT COUNT(*) FROM sessions WHERE lifecycle = 'recording' AND media_files_open = 1;" 2>/dev/null || true)"
		if [[ "$recording" == 1 ]]; then
			printf '%s\n' 'LIVE_CAPTURE_DURABLE: recording for 35 seconds before external termination.'
			sleep 35
			printf '%s\n' 'live' >"$proof_root/capture-ready"
		fi
	fi
	[[ -f "$proof_root/capture-ready" || -f "$proof_root/proof-error" ]] && break
	kill -0 "$capture_pid" 2>/dev/null || break
	sleep 0.1
done
[[ -f "$proof_root/capture-ready" && ! -f "$proof_root/proof-error" ]] ||
	fail_proof 'capture did not reach its durable proof point.'
kill -KILL "$capture_pid"
wait "$capture_pid" 2>/dev/null || true
capture_pid=""
find "$proof_root/Sessions" -name '*.caf' -print0 | sort -z | xargs -0 shasum -a 256 >"$proof_root/media-before.sha256"
"$app_binary" "$recovery_flag" "$proof_root" >"$proof_root/recovery.log" 2>&1 &
recovery_pid=$!
for _ in {1..300}; do
	[[ -f "$proof_root/recovery-verified.json" || -f "$proof_root/proof-error" ]] && break
	kill -0 "$recovery_pid" 2>/dev/null || break
	sleep 0.1
done
[[ -f "$proof_root/recovery-verified.json" && ! -f "$proof_root/proof-error" ]] ||
	fail_proof 'recovery did not verify.'
wait "$recovery_pid"
recovery_pid=""
shasum -a 256 -c "$proof_root/media-before.sha256"
[[ "$(artifact_digests)" == "$artifacts_before" ]] ||
	fail_proof 'the app artifact changed during the proof.'
receipt_digest="$(shasum -a 256 "$proof_root/recovery-verified.json" | cut -d ' ' -f 1)"
candidate_require_checks
candidate_receipt
cat "$proof_root/recovery-verified.json"
if [[ "$mode" == '--live' ]]; then
	printf '\n%s\n' 'FOUNDATION_LIVE_GREEN: two real sources, 30-second segments, SIGKILL, unchanged media, shared native playback.'
	printf '%s\n' 'Not proof of long-session drift, failure matrix, signing, release, or M1 completion.'
	printf '%s\n' \
		'proof=exact_app_binary,real_microphone_and_system_audio,thirty_second_segments,sigkill_termination,unchanged_media_digests,shared_native_playback,recovery_receipt' \
		'excludes=long_session_drift,failure_matrix,source_loss,application_selection,m1_completion,signing,release'
else
	printf '\n%s\n' 'FOUNDATION_SYNTHETIC_GREEN: two tracks, 30-second segments, SIGKILL, unchanged media, synchronized PCM recovery.'
	printf '%s\n' 'Not proof of microphone/system capture, audible playback, long-session drift, or M1 completion.'
	printf '%s\n' \
		'proof=exact_app_binary,synthetic_two_track_capture,thirty_second_segments,sigkill_termination,unchanged_media_digests,synchronized_pcm_recovery,recovery_receipt' \
		'excludes=real_capture,permissions,audible_output,long_session_drift,source_loss,m1_completion,signing,release'
fi
printf 'app_binary=%s\n%s\n' "$app_binary" "$artifacts_before"
printf 'recovery_receipt_sha256=%s\n' "$receipt_digest"
while read -r digest media_path; do
	printf 'media_sha256=%s %s\n' "$digest" "${media_path#"$proof_root"/}"
done <"$proof_root/media-before.sha256"
succeeded=1
