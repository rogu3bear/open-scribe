#!/usr/bin/env bash
set -euo pipefail

script_dir="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
repo_root="$(CDPATH='' cd -- "$script_dir/.." && pwd -P)"
cd "$repo_root"
# shellcheck source=script/candidate.sh
source "$script_dir/candidate.sh"
qualified_candidate=0
if [[ "$#" != 0 ]]; then
	[[ "$#" == 2 && "$1" == --candidate ]] || candidate_fail 'usage: check.sh --m1-complete [--candidate /absolute/candidate.json]'
	candidate_load "$2"
	candidate_require_checks
	qualified_candidate=1
fi

has_case() {
	[[ "$qualified_candidate" == 1 ]] || return 1
	local scenario="$1" receipt="$candidate_root/m1-injected-$1.json" root log marker
	[[ -f "$receipt" && ! -L "$receipt" ]] || return 1
	jq -e --arg candidate "$candidate_record_digest" --arg scenario "$scenario" \
		'.schema == 1 and .candidate_sha256 == $candidate and .scenario == $scenario
		and .result == "M1_INJECTED_CASE_GREEN" and (.proof_root | type == "string")
		and (.log_sha256 | test("^[a-f0-9]{64}$"))' "$receipt" >/dev/null || return 1
	root="$(jq -r '.proof_root' "$receipt")"
	[[ "$root" == "$candidate_root/m1-$scenario."* && -d "$root" && ! -L "$root" ]] || return 1
	log="$root/harness.log"
	[[ -f "$log" && ! -L "$log" && "$(candidate_sha256 "$log")" == "$(jq -r '.log_sha256' "$receipt")" ]] || return 1
	marker="M1_INJECTED_$(printf '%s' "$scenario" | tr '[:lower:]-' '[:upper:]_')_GREEN"
	rg -Fxq "$marker" "$log" && rg -Fxq "candidate_record_sha256=$candidate_record_digest" "$log"
}

cases=(storage-warning storage-critical storage-exhaustion microphone-loss system-loss application-loss selected-app-exit sleep-wake kill-preparation kill-recording kill-stop kill-seal kill-processing live-pause-resume)
missing=()
proven=()
for scenario in "${cases[@]}"; do
	if has_case "$scenario"; then proven+=("$scenario"); else missing+=("$scenario"); fi
done
# A short or injected session never discharges PRD 11.4's two-hour measurement.
missing+=(two_hour_synchronization)
implementation=()
if ! has_case storage-warning; then implementation+=(durable_markers validated_mixdown); fi
if ! has_case storage-warning || ! has_case storage-critical || ! has_case storage-exhaustion; then
	implementation+=(disk_pressure_policy)
fi
join_items() {
	local IFS=,
	printf '%s' "$*"
}

[[ "$qualified_candidate" != 1 ]] || candidate_receipt
printf '%s\n' \
	'M1_COMPLETE_HOLD' \
	"candidate_checks_qualified=$qualified_candidate" \
	"qualified_cases=$(join_items ${proven[@]+"${proven[@]}"})" \
	"missing_implementation_proof=$(join_items ${implementation[@]+"${implementation[@]}"})" \
	"missing_automated=$(join_items "${missing[@]}")" \
	'implemented_platform_adapters=application_scoped_selection,native_channel_layout_fidelity;source_exists_but_human_matrix_is_unqualified' \
	'missing_human=permission_grant_deny_revoke_restore_on_macos13_and_current,physical_routes_sample_rates_displays_source_loss_and_sleep_wake,application_scope_isolation,device_channel_layout_matrix,rendered_accessibility,perceptual_playback' \
	'protected=real_microphone_and_screen_system_audio_permissions,extended_recording,physical_device_changes' \
	'next=qualify every missing automated check on one candidate; then complete the supported-platform human matrix' >&2
exit 1
