#!/usr/bin/env bash
set -euo pipefail

# Runs one qualified candidate's local-only workflow as a direct child of
# a sandbox profile that refuses every IP connection, listener, and bind.
# Then it checks that the workflow completed, that no IP socket appeared in
# once-a-second samples, and that no diagnostic surface contains session
# content. Sampling establishes absence only at the sampled instants, not a
# count of connection attempts. Sandbox refusal and static symbol/source
# checks are separate evidence; denial-log behavior is not assumed.
# Local inputs: OPEN_SCRIBE_LOCAL_PROOF_MODEL (the pinned speech model file)
# and OPEN_SCRIBE_LOCAL_PROOF_SPEECH_CAF (a 48 kHz spoken CAF whose words
# include "recording safe").
# Default mode is synthetic and omits screen context. --live-context is a
# separate explicitly authorized screen-capture check, never an implicit retry.

script_dir="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
repo_root="$(CDPATH='' cd -- "$script_dir/.." && pwd)"
cd "$repo_root"
# shellcheck source=script/candidate.sh
source "$script_dir/candidate.sh"
[[ "$#" -ge 2 && "$1" == --candidate ]] ||
	candidate_fail 'usage: check_m4_local_only.sh --candidate /absolute/candidate.json [--synthetic|--live-context]'
candidate_load "$2"
candidate_require_checks
shift 2
mode=synthetic
if [[ "$#" != 0 ]]; then
	[[ "$#" == 1 && ("$1" == --synthetic || "$1" == --live-context) ]] ||
		candidate_fail 'expected --synthetic or --live-context'
	[[ "$1" != --live-context ]] || mode=live-context
fi
app="$app_binary"
rust_lib="$rust_library"
profile='(version 1)(allow default)(deny network-outbound (remote ip))(deny network-inbound (local ip))(deny network-bind (local ip))'
sentinels=(
	LocalOnlyTitleSentinel7f3a LocalOnlyParticipantSentinel51c2 LocalOnlyTopicSentinel88d0
	LocalOnlyContextSentinele41d LocalOnlyCorrectionSentinel2b6e "recording safe"
)

hold() {
	printf 'M4_LOCAL_ONLY_HOLD reason=%s\n' "$1" >&2
	exit 1
}
fail() {
	printf 'M4_LOCAL_ONLY_RED reason=%s\n' "$1" >&2
	exit 1
}

model_source="${OPEN_SCRIBE_LOCAL_PROOF_MODEL:-}"
speech_source="${OPEN_SCRIBE_LOCAL_PROOF_SPEECH_CAF:-}"
[[ "$model_source" == /* && -f "$model_source" && ! -L "$model_source" ]] ||
	hold "OPEN_SCRIBE_LOCAL_PROOF_MODEL_requires_absolute_regular_file"
[[ "$speech_source" == /* && -f "$speech_source" && ! -L "$speech_source" ]] ||
	hold "OPEN_SCRIBE_LOCAL_PROOF_SPEECH_CAF_requires_absolute_regular_file"
model_digest="$(candidate_sha256 "$model_source")"
speech_digest="$(candidate_sha256 "$speech_source")"
receipt="$candidate_root/m4-local-only-$mode.json"
[[ ! -e "$receipt" && ! -L "$receipt" ]] || hold "receipt_already_exists:$receipt"
if pgrep -x OpenScribeApp >/dev/null; then
	hold "another_open_scribe_process_is_running"
fi

# Distinguish policy denial from an unavailable external host. Neither control
# sends content: connect must deny even a closed loopback port; bind must deny
# before any listener is created. Other failures are not denial evidence.
sandbox-exec -p "$profile" /usr/bin/ruby -rsocket -e '
  [:connect, :bind].each do |operation|
    socket = Socket.new(Socket::AF_INET, Socket::SOCK_STREAM, 0)
    begin
      address = Socket.sockaddr_in(operation == :connect ? 9 : 0, "127.0.0.1")
      socket.public_send(operation, address)
      abort "IP_DENIAL_CONTROL_RED: #{operation} was allowed"
    rescue Errno::EPERM, Errno::EACCES
      # The kernel refused this operation, independent of network reachability.
    ensure
      socket.close
    end
  end
  puts "IP_DENIAL_CONTROL_GREEN"
' || fail "sandbox_profile_did_not_prove_ip_denial"

# Static: no Open Scribe code uses networking. Socket imports may come only
# from Rust std's precompiled object, which is linked whole.
owners="$(nm -A "$rust_lib" 2>/dev/null | grep -E ' U _(connect|connectx|getaddrinfo|socket|bind|sendto|sendmsg)$' |
	awk -F: '{print $2}' | sort -u | grep -v '^std-' || true)"
[[ -z "$owners" ]] || fail "network_symbols_outside_rust_std:$owners"
if nm -u "${app}.debug.dylib" "$app" 2>/dev/null | grep -E -q 'URLSession|NSURLConnection|_nw_|CFSocket|CFStream|CFNetwork'; then
	fail "app_imports_foundation_or_network_networking"
fi
if rg -q 'URLSession|NWConnection|NWPathMonitor|import Network|CFSocket|URLRequest|WKWebView' "$repo_root/apps/macos/Sources" ||
	rg -q 'std::net|TcpStream|TcpListener|UdpSocket|ToSocketAddrs' "$repo_root/crates" --glob '*.rs'; then
	fail "networking_api_in_source"
fi

root="$(mktemp -d "$candidate_root/m4-local-only-$mode.XXXXXX")"
root="$(CDPATH='' cd -- "$root" && pwd -P)"
pid=""
cleanup() {
	if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
		kill -KILL "$pid" 2>/dev/null || true
		wait "$pid" 2>/dev/null || true
	fi
	printf 'proof_root_retained=%s\n' "$root"
}
trap cleanup EXIT
launch_flag=--local-only-synthetic-proof-root
[[ "$mode" != live-context ]] || launch_flag=--local-only-proof-root
candidate_assert
start="$(date '+%Y-%m-%d %H:%M:%S')"
OPEN_SCRIBE_LOCAL_PROOF_MODEL="$OPEN_SCRIBE_LOCAL_PROOF_MODEL" \
	OPEN_SCRIBE_LOCAL_PROOF_SPEECH_CAF="$OPEN_SCRIBE_LOCAL_PROOF_SPEECH_CAF" \
	sandbox-exec -p "$profile" "$app" "$launch_flag" "$root" \
	>"$root/stdout.log" 2>"$root/stderr.log" &
pid=$!
proof_pid="$pid"
sockets=0
for _ in $(seq 1 600); do
	kill -0 "$pid" 2>/dev/null || break
	# sandbox-exec execs the app, so the child keeps this PID.
	if lsof -a -p "$pid" -i -n -P 2>/dev/null | grep -q -v '^COMMAND'; then
		sockets=$((sockets + 1))
	fi
	sleep 1
done
if kill -0 "$pid" 2>/dev/null; then
	kill -9 "$pid" 2>/dev/null || true
	wait "$pid" 2>/dev/null || true
	pid=""
	fail "proof_timed_out"
fi
process_status=0
wait "$pid" || process_status=$?
pid=""
[[ "$process_status" == 0 ]] || fail "proof_process_exit:$process_status"

report="$root/local-only-verified.json"
if [[ ! -f "$report" ]]; then
	fail "proof_failed:$(tr -c '[:alnum:]_:.() -' '_' <"$root/proof-error" 2>/dev/null | head -c 300)"
fi
candidate_local_only_report_valid "$report" "$mode" "$speech_digest" ||
	fail "workflow_report_incomplete:$(jq -c . "$report")"
[[ "$(candidate_sha256 "$model_source")" == "$model_digest" &&
"$(candidate_sha256 "$speech_source")" == "$speech_digest" ]] || fail "supplied_inputs_changed"

sleep 2
/usr/bin/log show --start "$start" --info --debug --style compact \
	--predicate "processIdentifier == $proof_pid" >"$root/unified.log" 2>"$root/unified-error.log" ||
	fail "unified_log_unavailable"
[[ "$sockets" == 0 ]] || fail "ip_socket_observed_in_samples:$sockets"

for sentinel in "${sentinels[@]}"; do
	for surface in stdout.log stderr.log unified.log; do
		if grep -Fiq -- "$sentinel" "$root/$surface"; then
			fail "content_in_diagnostics:$surface"
		fi
	done
done
images="$(find "$root/Library" -type f \( -iname '*.png' -o -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.heic' -o -iname '*.tiff' \) | wc -l | tr -d ' ')"
[[ "$images" == 0 ]] || fail "screen_images_retained:$images"
candidate_assert
candidate_require_checks
report_digest="$(candidate_sha256 "$report")"
jq -n --arg candidate "$candidate_record_digest" --arg mode "$mode" \
	--arg root "$root" --arg report "$report_digest" \
	--arg model "$model_digest" --arg speech "$speech_digest" \
	--arg stdout "$(candidate_sha256 "$root/stdout.log")" \
	--arg stderr "$(candidate_sha256 "$root/stderr.log")" \
	--arg unified "$(candidate_sha256 "$root/unified.log")" \
	'{schema:1, candidate_sha256:$candidate, result:"M4_LOCAL_ONLY_GREEN", mode:$mode,
      proof_root:$root, report_sha256:$report,
      inputs:{model_sha256:$model,speech_sha256:$speech},
      logs:{stdout:$stdout,stderr:$stderr,unified:$unified},
      qualification_scope:"development_candidate_only", release_admission:false}' >"$root/receipt.json"
# Atomic no-replace publication preserves any concurrent accepted receipt.
ruby -e 'File.link(ARGV[0], ARGV[1])' "$root/receipt.json" "$receipt" ||
	fail "receipt_publication_refused"
candidate_receipt

printf '%s\n' \
	'M4_LOCAL_ONLY_GREEN' \
	"mode=$mode receipt=$receipt" \
	"report=$(jq -c . "$report")" \
	"unified_log_lines=$(wc -l <"$root/unified.log" | tr -d ' ') ip_socket_samples=0 retained_images=0" \
	'proof=exact_candidate_and_input_binding,no_network_symbols_outside_rust_std,no_networking_api_in_source,ip_denied_process,no_ip_socket_in_one_second_samples,synthetic_recording,declaration,recovery,playback_render,validated_mix,isolated_model_copy,transcription,correction,search,exports,package_verification,package_open_in_a_second_library,two_phase_deletion,content_free_stdout_stderr_unified_log' \
	'context=omitted_in_synthetic_mode;explicit_live_context_requires_its_own_successful_frame_and_event' \
	'excludes=signed_sandbox,system_firewall,live_microphone,crash_reports,providers,system_trash,release'
