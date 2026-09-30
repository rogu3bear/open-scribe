#!/usr/bin/env bash
set -euo pipefail

# Runs the development app's local-only workflow proof as a direct child of
# a sandbox profile that refuses every IP connection, listener, and bind.
# Then it checks that the workflow completed, that no IP socket appeared in
# once-a-second samples, and that no diagnostic surface contains session
# content. Unprivileged, macOS logs neither sandbox denials nor reports, so
# attempts are bounded by those samples and by the static symbol and
# source checks, not observed directly.
# Local inputs: OPEN_SCRIBE_LOCAL_PROOF_MODEL (the pinned speech model file)
# and OPEN_SCRIBE_LOCAL_PROOF_SPEECH_CAF (a 48 kHz spoken CAF whose words
# include "recording safe").

script_dir="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
repo_root="$(CDPATH='' cd -- "$script_dir/.." && pwd)"
app="$repo_root/apps/macos/.build/xcode/Build/Products/Debug/OpenScribeApp.app/Contents/MacOS/OpenScribeApp"
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

[[ -x "$app" ]] || hold "development_app_not_built next=./script/build_and_run.sh --verify"
rust_lib="$repo_root/apps/macos/.build/rust-macos13/aarch64-apple-darwin/debug/libopen_scribe_uniffi.a"
[[ -f "$rust_lib" ]] || hold "rust_static_library_not_built"
[[ -f "${OPEN_SCRIBE_LOCAL_PROOF_MODEL:-}" ]] || hold "OPEN_SCRIBE_LOCAL_PROOF_MODEL_unset"
[[ -f "${OPEN_SCRIBE_LOCAL_PROOF_SPEECH_CAF:-}" ]] || hold "OPEN_SCRIBE_LOCAL_PROOF_SPEECH_CAF_unset"
if pgrep -x OpenScribeApp >/dev/null; then
	hold "another_open_scribe_process_is_running"
fi

# The profile must itself refuse IP traffic before it can prove anything.
if sandbox-exec -p "$profile" /usr/bin/curl -sS -m 5 -o /dev/null https://1.1.1.1 2>/dev/null; then
	fail "sandbox_profile_allowed_an_ip_connection"
fi

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

root="$(mktemp -d "${TMPDIR:-/tmp}/open-scribe-local-only.XXXXXX")"
trap 'rm -rf "$root"' EXIT
start="$(date '+%Y-%m-%d %H:%M:%S')"
OPEN_SCRIBE_LOCAL_PROOF_MODEL="$OPEN_SCRIBE_LOCAL_PROOF_MODEL" \
	OPEN_SCRIBE_LOCAL_PROOF_SPEECH_CAF="$OPEN_SCRIBE_LOCAL_PROOF_SPEECH_CAF" \
	sandbox-exec -p "$profile" "$app" --local-only-proof-root "$root" \
	>"$root/stdout.log" 2>"$root/stderr.log" &
pid=$!
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
	fail "proof_timed_out"
fi
wait "$pid" || true

report="$root/local-only-verified.json"
if [[ ! -f "$report" ]]; then
	fail "proof_failed:$(tr -c '[:alnum:]_:.() -' '_' <"$root/proof-error" 2>/dev/null | head -c 300)"
fi
jq -e '
	.recovered_segments == 4 and .rendered_frames == 1548000 and .validated_mix_bytes > 0
	and .transcript_segments >= 1 and .correction_search_hits == 1 and .package_files == 7
	and .deleted_sessions == 1 and .declared_participants == 1
	and (.screen_recording_permission != "granted"
		or (.context_events_accepted == 1 and .saved_context_events == 1
			and .context_frame_pixels > 0))
' "$report" >/dev/null || fail "workflow_report_incomplete:$(jq -c . "$report")"

sleep 2
log show --start "$start" --info --debug --style compact \
	--predicate 'process == "OpenScribeApp"' >"$root/unified.log" 2>/dev/null || true
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

printf '%s\n' \
	'M4_LOCAL_ONLY_GREEN' \
	"report=$(jq -c . "$report")" \
	"unified_log_lines=$(wc -l <"$root/unified.log" | tr -d ' ') ip_socket_samples=0 retained_images=0" \
	'proof=no_network_symbols_outside_rust_std,no_networking_api_in_source,ip_denied_process,no_ip_socket_in_one_second_samples,recording,declaration,context_frame_and_event,recovery,playback_render,validated_mix,model_install,transcription,correction,search,exports,package_verification,two_phase_deletion,content_free_stdout_stderr_unified_log' \
	'excludes=candidate_binding,signed_sandbox,system_firewall,live_microphone,crash_reports,providers'
