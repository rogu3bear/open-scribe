#!/usr/bin/env bash
set -euo pipefail

script_dir="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
repo_root="$(CDPATH='' cd -- "$script_dir/.." && pwd -P)"
cd "$repo_root"
# shellcheck source=script/candidate.sh
source "$script_dir/candidate.sh"
[[ "$#" -ge 2 && "$1" == --candidate ]] || candidate_fail 'usage: check_m1_injected.sh --candidate /absolute/candidate.json [--case CASE]'
candidate_load "$2"
candidate_require_checks
shift 2
cases=(storage-warning storage-critical storage-exhaustion microphone-loss system-loss application-loss selected-app-exit sleep-wake kill-preparation kill-recording kill-stop kill-seal kill-processing)
if [[ "$#" != 0 ]]; then
	[[ "$#" == 2 && "$1" == --case ]] || candidate_fail 'expected --case CASE'
	selected="$2"
	valid=0
	for scenario in "${cases[@]}"; do [[ "$scenario" != "$selected" ]] || valid=1; done
	# This explicit single case opens real devices; the default matrix never does.
	[[ "$selected" != live-pause-resume ]] || valid=1
	[[ "$valid" == 1 ]] || candidate_fail 'unknown injected case'
	cases=("$selected")
fi
if pgrep -x OpenScribeApp >/dev/null; then
	candidate_fail 'close the development app before an isolated process proof'
fi

run_case() {
	local scenario="$1" proof_root="$2" media_root="$2/media" app_pid='' mounted=0
	local phase session journal status
	# shellcheck disable=SC2329 # Invoked by the EXIT trap in this case's subshell.
	cleanup_case() {
		if [[ -n "$app_pid" ]] && kill -0 "$app_pid" 2>/dev/null; then
			kill -KILL "$app_pid" 2>/dev/null || true
			wait "$app_pid" 2>/dev/null || true
		fi
		if [[ "$mounted" == 1 ]]; then
			# The image and its media are retained. Only our mount is detached.
			hdiutil detach "$proof_root/volume" >>"$proof_root/volume.log" 2>&1 || return 1
		fi
	}
	trap cleanup_case EXIT
	fail_case() {
		[[ ! -f "$proof_root/proof-error" ]] || cat "$proof_root/proof-error" >&2
		printf 'M1_INJECTED_RED: %s; proof_root=%s\n' "$1" "$proof_root" >&2
		exit 1
	}
	wait_file() {
		local name="$1" attempt
		for ((attempt = 0; attempt < 600; attempt++)); do
			[[ ! -f "$proof_root/proof-error" ]] || fail_case 'app reported failure'
			[[ ! -f "$proof_root/$name" ]] || return 0
			kill -0 "$app_pid" 2>/dev/null || fail_case "app exited before $name"
			sleep 0.1
		done
		fail_case "timed out waiting for $name"
	}
	wait_exit() {
		local attempt
		for ((attempt = 0; attempt < 200; attempt++)); do
			if ! kill -0 "$app_pid" 2>/dev/null; then
				wait "$app_pid" || fail_case 'app exited unsuccessfully'
				app_pid=''
				return
			fi
			sleep 0.1
		done
		fail_case 'app did not exit'
	}
	snapshot_media() {
		ruby -rjson -rdigest -e 'root, output = ARGV; paths = Dir.glob(File.join(root, "Sessions", "**", "*.caf")).sort; File.write(output, JSON.generate(paths.map { |p| [p, Digest::SHA256.file(p).hexdigest] }.to_h))' \
			"$media_root" "$proof_root/media-before.json"
	}
	launch_recovery() {
		candidate_assert
		OPEN_SCRIBE_M1_PROOF_DIAGNOSTICS=1 "$app_binary" --m1-injected-recovery-root "$proof_root" --m1-proof-media-root "$media_root" \
			>>"$proof_root/recovery-app.log" 2>&1 &
		app_pid=$!
		wait_file recovery.json
		wait_exit
	}
	if [[ "$scenario" == storage-exhaustion ]]; then
		mkdir "$proof_root/volume"
		hdiutil create -size 1536m -fs APFS -type SPARSE -volname OpenScribeM1Proof \
			"$proof_root/pressure.sparseimage" >"$proof_root/volume.log" 2>&1
		hdiutil attach -nobrowse -mountpoint "$proof_root/volume" "$proof_root/pressure.sparseimage" \
			>>"$proof_root/volume.log" 2>&1
		mounted=1
		media_root="$proof_root/volume/media"
	fi
	candidate_assert
	OPEN_SCRIBE_M1_PROOF_DIAGNOSTICS=1 "$app_binary" --m1-injected-proof-root "$proof_root" --m1-proof-media-root "$media_root" \
		--m1-injected-case "$scenario" >"$proof_root/app.log" 2>&1 &
	app_pid=$!
	if [[ "$scenario" == kill-* ]]; then
		wait_file checkpoint.json
		phase="${scenario#kill-}"
		jq -e --arg phase "$phase" --argjson pid "$app_pid" '.phase == $phase and .pid == $pid' \
			"$proof_root/checkpoint.json" >/dev/null || fail_case 'wrong checkpoint/process'
		# The checkpoint file is written immediately before SIGSTOP. Wait for
		# actual stopped state before recording or killing this exact child.
		for _ in {1..100}; do
			status="$(ps -p "$app_pid" -o state=)"
			[[ "$status" != *T* ]] || break
			sleep 0.01
		done
		[[ "$status" == *T* ]] || fail_case 'process never stopped at checkpoint'
		snapshot_media
		sqlite3 -readonly "$media_root/Library.sqlite3" '.dump' >"$proof_root/before-kill.sql"
		kill -KILL "$app_pid"
		status=0
		wait "$app_pid" 2>/dev/null || status=$?
		[[ "$status" == 137 ]] || fail_case 'child did not exit by SIGKILL'
		app_pid=''
	elif [[ "$scenario" == storage-exhaustion ]]; then
		wait_file injection-ready.json
		ruby "$script_dir/m1_fill_volume.rb" "$proof_root/volume" "$proof_root" >"$proof_root/volume-fill.log"
		touch "$proof_root/injection-go"
		wait_file outcome.json
		wait_exit
		session="$(jq -r '.session_id' "$proof_root/outcome.json")"
		cp "$media_root/Sessions/$session/recovery.jsonl" "$proof_root/journal-before-free.jsonl"
		# Reclaim only this run's filler after capture stops. This lets readonly
		# SQLite open SHM if necessary; recovery has not run, and the original
		# journal bytes above prove the failure was logged while the volume was full.
		rm -- "$proof_root/volume/owned-pressure-fill"
		sqlite3 -readonly -json "$media_root/Library.sqlite3" \
			'SELECT id, event_kind, payload_json FROM session_events ORDER BY sequence;' \
			>"$proof_root/events-before-recovery.json"
		snapshot_media
	else
		wait_file outcome.json
		wait_exit
	fi
	if [[ "$scenario" == kill-* || "$scenario" == storage-exhaustion ]]; then
		launch_recovery
		cp "$proof_root/recovery.json" "$proof_root/recovery-first.json"
		mv "$proof_root/recovery.json" "$proof_root/recovery-previous.json"
		session="$(jq -r '.session_id' "$proof_root/recovery-first.json")"
		journal="$media_root/Sessions/$session/recovery.jsonl"
		candidate_sha256 "$journal" >"$proof_root/journal-first.sha256"
		launch_recovery
	fi
	ruby "$script_dir/verify_m1_injected.rb" "$scenario" "$proof_root" "$media_root"
	cleanup_case
	trap - EXIT
	candidate_receipt
	printf 'scenario=%s\nproof_root=%s\n' "$scenario" "$proof_root"
}

for scenario in "${cases[@]}"; do
	receipt="$candidate_root/m1-injected-$scenario.json"
	[[ ! -e "$receipt" ]] || candidate_fail "receipt already exists for $scenario; evidence is preserved"
	proof_root="$(mktemp -d "$candidate_root/m1-$scenario.XXXXXX")"
	(run_case "$scenario" "$proof_root") 2>&1 | tee "$proof_root/harness.log"
	candidate_assert
	jq -n --arg candidate "$candidate_record_digest" --arg scenario "$scenario" --arg root "$proof_root" \
		--arg digest "$(candidate_sha256 "$proof_root/harness.log")" \
		'{schema: 1, candidate_sha256: $candidate, scenario: $scenario, proof_root: $root,
		  log_sha256: $digest, result: "M1_INJECTED_CASE_GREEN"}' >"$receipt"
done
candidate_receipt
printf '%s\n' 'M1_INJECTED_SELECTION_GREEN' \
	'proof=only_the_cases_named_in_this_invocation' \
	'excludes=physical_device_events,tcc,rendered_accessibility,long_session_synchronization,m1_completion'
