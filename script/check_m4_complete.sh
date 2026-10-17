#!/usr/bin/env bash
set -euo pipefail

script_dir="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
repo_root="$(CDPATH='' cd -- "$script_dir/.." && pwd -P)"
cd "$repo_root"
# shellcheck source=script/candidate.sh
source "$script_dir/candidate.sh"
qualified_candidate=0
qualified_modes=()
if [[ "$#" != 0 ]]; then
	[[ "$#" == 2 && "$1" == --candidate ]] ||
		candidate_fail 'usage: check_m4_complete.sh [--candidate /absolute/candidate.json]'
	candidate_load "$2"
	candidate_require_checks
	qualified_candidate=1
fi

has_local_only() {
	[[ "$qualified_candidate" == 1 ]] || return 1
	local mode="$1" receipt="$candidate_root/m4-local-only-$1.json" root key path
	[[ -f "$receipt" && ! -L "$receipt" ]] || return 1
	jq -e --arg candidate "$candidate_record_digest" --arg mode "$mode" '
      .schema == 1 and .candidate_sha256 == $candidate and .mode == $mode
      and .result == "M4_LOCAL_ONLY_GREEN" and .release_admission == false
      and .qualification_scope == "development_candidate_only"
      and (.proof_root | type == "string")
      and (.report_sha256 | test("^[a-f0-9]{64}$"))
      and ([.inputs.model_sha256,.inputs.speech_sha256,.logs.stdout,.logs.stderr,.logs.unified]
        | all(type == "string" and test("^[a-f0-9]{64}$")))' "$receipt" >/dev/null || return 1
	root="$(jq -r '.proof_root' "$receipt")"
	[[ "$root" == "$candidate_root/m4-local-only-$mode."* && -d "$root" && ! -L "$root" &&
		"$(CDPATH='' cd -- "$root" && pwd -P)" == "$root" ]] || return 1
	for key in stdout stderr unified; do
		path="$root/$key.log"
		[[ -f "$path" && ! -L "$path" &&
			"$(candidate_sha256 "$path")" == "$(jq -r --arg key "$key" '.logs[$key]' "$receipt")" ]] || return 1
	done
	path="$root/local-only-verified.json"
	[[ -f "$path" && ! -L "$path" &&
		"$(candidate_sha256 "$path")" == "$(jq -r '.report_sha256' "$receipt")" ]] || return 1
	candidate_local_only_report_valid "$path" "$mode" "$(jq -r '.inputs.speech_sha256' "$receipt")"
}
for mode in synthetic live-context; do
	if has_local_only "$mode"; then qualified_modes+=("$mode"); fi
done
missing_prefix='candidate_bound_local_only_run,'
if ((${#qualified_modes[@]} > 0)); then missing_prefix=''; fi
[[ "$qualified_candidate" != 1 ]] || candidate_receipt
qualified_text="$(
	IFS=,
	printf '%s' "${qualified_modes[*]-}"
)"
printf '%s\n' \
	'M4_COMPLETE_HOLD' \
	"candidate_checks_qualified=$qualified_candidate" \
	"qualified_local_only_modes=$qualified_text" \
	'available_contracts=provider_policy_and_release_architecture_contracts' \
	'available_source=two_phase_deletion,manifest_rendered_capability_status,adr_0015_routes_csp_and_headers,development_sandbox_without_network_entitlement,identifier_only_app_logs,local_only_workflow_proof' \
	"observed_on_candidate=${qualified_text:-none}" \
	'qualification=none at the M4 completion plane' \
	"missing=${missing_prefix}provider_category_authorization,system_trash_deletion_runtime,secret_handling,crash_report_content_check,capability_true_website_equality,local_intelligence,structured_memory" \
	'protected=provider_credentials,production_deployment' \
	'next=qualify every missing boundary on the candidate; local-only mode does not admit release or optional context it did not exercise' >&2
exit 1
