#!/usr/bin/env bash
set -euo pipefail

# The two-hour synchronization run (ADR 0005; docs/M1_OPERATOR_SESSION.md).
# Attended only: it plays an audible coded stimulus through the current
# output with afplay (system-audio capture excludes the app's own output)
# while the candidate app records the microphone and system audio, stops at
# its scheduled deadline, and measures cross-track drift in Rust. It never
# records past the deadline, and it never overwrites a receipt.

script_dir="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
repo_root="$(CDPATH='' cd -- "$script_dir/.." && pwd -P)"
cd "$repo_root"
# shellcheck source=script/candidate.sh
source "$script_dir/candidate.sh"
usage='usage: check.sh --m1-two-hour --candidate /absolute/candidate.json --attended [--seconds N]'
[[ "$#" -ge 2 && "$1" == --candidate ]] || candidate_fail "$usage"
candidate_load "$2"
candidate_require_checks
shift 2
attended=0
seconds=7260
while [[ "$#" != 0 ]]; do
	case "$1" in
	--attended) attended=1 && shift ;;
	--seconds) seconds="${2:-}" && shift 2 ;;
	*) candidate_fail "$usage" ;;
	esac
done
[[ "$attended" == 1 ]] ||
	candidate_fail 'this run plays audible chirps and records the microphone; an operator present at the Mac starts it with --attended'
[[ "$seconds" =~ ^[0-9]+$ && "$seconds" -ge 60 && "$seconds" -le 10800 ]] ||
	candidate_fail '--seconds must be between 60 and 10800'
if pgrep -x OpenScribeApp >/dev/null; then
	candidate_fail 'close the development app before the synchronization run'
fi
receipt="$candidate_root/m1-two-hour.json"
[[ ! -e "$receipt" ]] || candidate_fail 'this candidate already has a two-hour receipt; evidence is preserved'

proof_root="$(mktemp -d "$candidate_root/m1-two-hour.XXXXXX")"
app_pid=''
player_pid=''
fail_run() {
	printf 'M1_TWO_HOUR_RED: %s; proof_root=%s\n' "$1" "$proof_root" >&2
	exit 1
}
cleanup() {
	if [[ -n "$player_pid" ]] && kill -0 "$player_pid" 2>/dev/null; then kill "$player_pid" 2>/dev/null || true; fi
	if [[ -n "$app_pid" ]] && kill -0 "$app_pid" 2>/dev/null; then
		# A deadline-bound app stops itself; this only reaps one that failed to.
		kill -TERM "$app_pid" 2>/dev/null || true
	fi
}
trap cleanup EXIT

# The analyzer is built from the candidate's own source.
CARGO_TARGET_DIR="$rust_target_dir" cargo build --locked --quiet -p open-scribe-core --bin open-scribe-drift
drift="$rust_target_dir/debug/open-scribe-drift"
seed="$(od -An -N8 -tu8 /dev/urandom | tr -d ' ')"
"$drift" stimulus --seed "$seed" --seconds "$seconds" --out "$proof_root/stimulus" | tee "$proof_root/stimulus.log"
stimulus="$proof_root/stimulus/stimulus.wav"
[[ "$(candidate_sha256 "$stimulus")" == "$(jq -r '.wav_sha256' "$proof_root/stimulus/stimulus.json")" ]] ||
	fail_run 'the stimulus file differs from its record'

candidate_assert
"$app_binary" --m1-drift-run-root "$proof_root" --m1-drift-run-seconds "$((seconds + 30))" \
	>"$proof_root/app.log" 2>&1 &
app_pid=$!
for _ in $(seq 1 900); do
	[[ ! -f "$proof_root/run.json" ]] || fail_run "capture did not start: $(jq -c . "$proof_root/run.json")"
	[[ ! -f "$proof_root/capture-started.json" ]] || break
	kill -0 "$app_pid" 2>/dev/null || fail_run 'the app exited before capture started'
	sleep 0.1
done
[[ -f "$proof_root/capture-started.json" ]] || fail_run 'capture did not start within 90 seconds'

output_route="$(system_profiler SPAudioDataType -json 2>/dev/null |
	jq -r '[.SPAudioDataType[]?._items[]? | select(.coreaudio_default_audio_output_device == "spaudio_yes") | ._name] | first // "unknown"')"
printf 'output_route=%s\nplayback_started_ms=%s\n' "$output_route" "$(($(date +%s) * 1000))" >>"$proof_root/playback.log"
/usr/bin/afplay "$stimulus" &
player_pid=$!
wait "$player_pid" || fail_run 'the stimulus player failed'
player_pid=''
printf 'playback_stopped_ms=%s\n' "$(($(date +%s) * 1000))" >>"$proof_root/playback.log"

for _ in $(seq 1 6000); do
	kill -0 "$app_pid" 2>/dev/null || break
	sleep 0.1
done
kill -0 "$app_pid" 2>/dev/null && fail_run 'the app did not stop at its deadline'
app_pid=''
[[ -f "$proof_root/run.json" ]] || fail_run 'the app left no run outcome'
jq -e '.result == "saved" and (.session_id | type == "string")' "$proof_root/run.json" >/dev/null ||
	fail_run "the recording was not saved: $(jq -c . "$proof_root/run.json")"
session_id="$(jq -r '.session_id' "$proof_root/run.json")"

status=0
"$drift" analyze --library "$proof_root/Library" --session "$session_id" \
	--stimulus "$proof_root/stimulus/stimulus.json" --out "$proof_root/drift-report.json" |
	tee "$proof_root/analysis.log" || status=$?
[[ -f "$proof_root/drift-report.json" ]] || fail_run 'the analyzer wrote no report'
# The stimulus is regenerable from its record, whose digest stays bound.
rm -- "$stimulus"
trap - EXIT

candidate_assert
result='M1_TWO_HOUR_SYNCHRONIZATION_RED'
[[ "$status" != 0 ]] || result='M1_TWO_HOUR_SYNCHRONIZATION_GREEN'
jq -n --arg candidate "$candidate_record_digest" --arg root "$proof_root" --arg result "$result" \
	--arg report "$(candidate_sha256 "$proof_root/drift-report.json")" \
	--arg analysis "$(candidate_sha256 "$proof_root/analysis.log")" \
	--arg playback "$(candidate_sha256 "$proof_root/playback.log")" \
	--argjson seconds "$seconds" \
	'{schema: 1, candidate_sha256: $candidate, result: $result, seconds: $seconds, proof_root: $root,
	  report_sha256: $report, analysis_log_sha256: $analysis, playback_log_sha256: $playback}' >"$receipt"
candidate_receipt
printf '%s\n' "$result" "report=$proof_root/drift-report.json" \
	'excludes=route_changes,sleep_wake,permission_revocation,human_matrix,signing,release'
[[ "$status" == 0 ]]
