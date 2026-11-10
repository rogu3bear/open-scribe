#!/usr/bin/env bash
set -euo pipefail

# A name leaves its list only when a receipt under this candidate re-verifies.
# Source tests, a copied marker, and a receipt for another build do not count.
# Green does not admit release.
script_dir="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
repo_root="$(CDPATH='' cd -- "$script_dir/.." && pwd -P)"
cd "$repo_root"
# shellcheck source=script/candidate.sh
source "$script_dir/candidate.sh"
qualified_candidate=0
if [[ "$#" != 0 ]]; then
	[[ "$#" == 2 && "$1" == --candidate ]] ||
		candidate_fail 'usage: check_m3_complete.sh [--candidate /absolute/candidate.json]'
	candidate_load "$2"
	candidate_require_checks
	qualified_candidate=1
fi

has_behavior() {
	[[ "$qualified_candidate" == 1 ]] || return 1
	local name="$1" receipt="$candidate_root/m3-$1.json" root log marker
	[[ -f "$receipt" && ! -L "$receipt" ]] || return 1
	jq -e --arg candidate "$candidate_record_digest" --arg name "$name" '
      .schema == 1 and .candidate_sha256 == $candidate and .behavior == $name
      and .result == "M3_BEHAVIOR_GREEN" and .release_admission == false
      and (.proof_root | type == "string")
      and (.log_sha256 | test("^[a-f0-9]{64}$"))' "$receipt" >/dev/null || return 1
	root="$(jq -r '.proof_root' "$receipt")"
	[[ "$root" == "$candidate_root/m3-$name."* && -d "$root" && ! -L "$root" &&
		"$(CDPATH='' cd -- "$root" && pwd -P)" == "$root" ]] || return 1
	log="$root/harness.log"
	[[ -f "$log" && ! -L "$log" && "$(candidate_sha256 "$log")" == "$(jq -r '.log_sha256' "$receipt")" ]] || return 1
	marker="M3_$(printf '%s' "$name" | tr '[:lower:]' '[:upper:]')_GREEN"
	rg -Fxq "$marker" "$log" && rg -Fxq "candidate_record_sha256=$candidate_record_digest" "$log"
}

behaviors=(
	claim_evidence_navigation
	claim_adjudication
	four_display_runtime_matrix
	live_permission_revocation_runtime
	two_hour_context_load
	voiceover_and_keyboard_inspection
	rendered_overlay_review
	snapshot_retention
	macos13_one_frame_stream_run
)
sources=(
	participant_topic_declaration
	explicit_context_scope_with_epochs
	pause_resume_narrow_revoke
	sparse_context_event_acceptance
	local_change_detection
	vision_ocr_reduction
	follow_pointer_dwell
	no_pixel_retention_default
	scope_inspector
	perimeter_overlay
	topology_names
	saved_context_review
	evidence_citation_and_resolution_for_every_kind
	resolution_gated_context_navigation
)
missing=()
proven=()
unqualified=()
qualified_sources=()
for name in "${behaviors[@]}"; do
	if has_behavior "$name"; then proven+=("$name"); else missing+=("$name"); fi
done
for name in "${sources[@]}"; do
	if has_behavior "$name"; then qualified_sources+=("$name"); else unqualified+=("$name"); fi
done
join_items() {
	local IFS=,
	printf '%s' "$*"
}
proven_text="$(join_items ${proven[@]+"${proven[@]}"})"
missing_text="$(join_items ${missing[@]+"${missing[@]}"})"
qualified_source_text="$(join_items ${qualified_sources[@]+"${qualified_sources[@]}"})"
unqualified_text="$(join_items ${unqualified[@]+"${unqualified[@]}"})"
[[ "$qualified_candidate" != 1 ]] || candidate_receipt
if [[ "$qualified_candidate" == 1 && ${#missing[@]} -eq 0 && ${#unqualified[@]} -eq 0 ]]; then
	printf '%s\n' \
		'M3_COMPLETE_GREEN' \
		"candidate_checks_qualified=$qualified_candidate" \
		"qualified_behaviors=$proven_text" \
		"qualified_source=$qualified_source_text" \
		'available_contracts=founding_evidence_types_and_architecture_contract,evidence_ref_v1_validation' \
		"unqualified_source=$unqualified_text" \
		'qualification=candidate_receipts' \
		"missing=$missing_text" \
		'protected=screen_recording_permission_and_real_display_scope_runtime' \
		'release_admission=false' >&2
	exit 0
fi
printf '%s\n' \
	'M3_COMPLETE_HOLD' \
	"candidate_checks_qualified=$qualified_candidate" \
	"qualified_behaviors=$proven_text" \
	"qualified_source=$qualified_source_text" \
	'available_contracts=founding_evidence_types_and_architecture_contract,evidence_ref_v1_validation' \
	"unqualified_source=$unqualified_text" \
	'observed=one_frame_display_and_region_capture_in_the_test_host_with_permission_already_granted' \
	'qualification=none at the M3 completion plane' \
	"missing=$missing_text" \
	'protected=screen_recording_permission_and_real_display_scope_runtime' \
	'next=qualify context on a candidate: four-display matrix, live revocation, two-hour load, rendered overlay and accessibility review; then claim evidence navigation with Milestone 4' \
	'release_admission=false' >&2
exit 1
