#!/usr/bin/env bash
set -euo pipefail

script_dir="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
repo_root="$(CDPATH='' cd -- "$script_dir/.." && pwd -P)"
cd "$repo_root"
# shellcheck source=script/candidate.sh
source "$script_dir/candidate.sh"
[[ "$#" == 1 && "$1" == /* ]] || candidate_fail 'usage: check.sh --candidate /absolute/new-directory/candidate.json'
candidate_record="$1"
candidate_source
source_sha="$candidate_sha"
source_tree="$candidate_tree"
if [[ -f "$candidate_record" ]]; then
	# A contributor may build first, then qualify that exact build. Never
	# replace its artifacts or reuse another build's source/test receipts.
	candidate_load "$candidate_record"
	[[ ! -e "$candidate_root/source-checks.log" && ! -e "$candidate_root/native-checks.log" && ! -e "$candidate_root/checks.json" ]] ||
		candidate_fail 'qualification evidence already exists; use the runtime consumers or a new candidate directory'
else
	[[ ! -e "$(dirname "$candidate_record")" ]] || candidate_fail 'choose a new candidate directory; existing evidence is preserved'
	mkdir -p "$(dirname "$candidate_record")"
	candidate_paths
fi
source_checks() {
	"$script_dir/check_candidate_record.sh"
	ruby "$script_dir/check_macos_build_configuration_test.rb"
	bash "$script_dir/check_m1_operator_snapshot.sh"
	ruby "$script_dir/check_m1_injected_contract.rb"
	"$script_dir/check_scaffold.sh"
	cargo clippy --locked -p open-scribe-store -p open-scribe-core -p open-scribe-uniffi --all-targets -- -D warnings
	"$script_dir/check_native_contracts.sh"
	"$script_dir/build_web.sh"
	candidate_base="$(git merge-base HEAD main 2>/dev/null || true)"
	if [[ -z "$candidate_base" || "$candidate_base" == "$candidate_sha" ]]; then
		candidate_base="$(git rev-parse HEAD^)"
	fi
	git diff --check "$candidate_base" HEAD
	git diff --check
	printf '%s\n' 'CONTRIBUTOR_SOURCE_GREEN'
}
source_checks 2>&1 | tee "$candidate_root/source-checks.log"
candidate_source
[[ "$candidate_sha" == "$source_sha" && "$candidate_tree" == "$source_tree" ]] || candidate_fail 'source changed during contributor checks'
if [[ ! -f "$candidate_record" ]]; then
	"$script_dir/build_candidate.sh" "$candidate_record"
fi
"$script_dir/build_and_run.sh" --verify --candidate "$candidate_record" 2>&1 | tee "$candidate_root/native-checks.log"
candidate_load "$candidate_record"
jq -n --arg candidate "$candidate_record_digest" \
	--arg source "$(candidate_sha256 "$candidate_root/source-checks.log")" \
	--arg native "$(candidate_sha256 "$candidate_root/native-checks.log")" \
	'{schema: 1, candidate_sha256: $candidate, result: "CONTRIBUTOR_CHECKS_GREEN", logs: {source: $source, native: $native}}' \
	>"$candidate_root/checks.json"
"$script_dir/build_and_run.sh" --verify-recording --candidate "$candidate_record"
"$script_dir/check_foundational_workflow.sh" --candidate "$candidate_record"
candidate_require_checks
candidate_receipt
printf '%s\n' 'CONTRIBUTOR_CANDIDATE_GREEN' \
	'proof=scaffold,clippy,coarse_boundaries,entitlements,web,fresh_bindings,single_native_build,macos13_floor,no_project_swift_warnings,all_swift_tests,scene_launch,recording_components,synthetic_recovery,candidate_range_and_worktree_diff_hygiene' \
	'excludes=live_capture,permission_matrix,audible_output,long_sessions,m1_completion,signing,release'
