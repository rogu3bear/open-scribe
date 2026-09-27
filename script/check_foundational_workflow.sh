#!/usr/bin/env bash
set -euo pipefail

# Default proof is synthetic. --live requires explicit microphone, system-audio,
# and audible-playback authorization; it records 35 seconds after startup.
app_binary="${1:?usage: check_foundational_workflow.sh /absolute/path/to/OpenScribeApp}"
mode="${2:---synthetic}"
[[ "$mode" == '--synthetic' || "$mode" == '--live' ]] || exit 64
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
proof_root="$(mktemp -d "${TMPDIR:-/tmp}/open-scribe-foundation.XXXXXX")"
capture_pid=""
recovery_pid=""
cleanup() {
	for pid in "$capture_pid" "$recovery_pid"; do
		if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
			kill "$pid" 2>/dev/null || true
			wait "$pid" 2>/dev/null || true
		fi
	done
	printf 'proof_root_retained=%s\n' "$proof_root"
}
trap cleanup EXIT
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
[[ -f "$proof_root/capture-ready" && ! -f "$proof_root/proof-error" ]]
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
[[ -f "$proof_root/recovery-verified.json" && ! -f "$proof_root/proof-error" ]]
wait "$recovery_pid"
recovery_pid=""
shasum -a 256 -c "$proof_root/media-before.sha256"
cat "$proof_root/recovery-verified.json"
if [[ "$mode" == '--live' ]]; then
	printf '\n%s\n' 'FOUNDATION_LIVE_GREEN: two real sources, 30-second segments, SIGKILL, unchanged media, shared native playback.'
	printf '%s\n' 'Not proof of long-session drift, failure matrix, signing, release, or M1 completion.'
else
	printf '\n%s\n' 'FOUNDATION_SYNTHETIC_GREEN: two tracks, 30-second segments, SIGKILL, unchanged media, synchronized PCM recovery.'
	printf '%s\n' 'Not proof of microphone/system capture, audible playback, long-session drift, or M1 completion.'
fi
