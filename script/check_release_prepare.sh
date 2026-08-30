#!/usr/bin/env bash
set -euo pipefail

script_dir="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
repo_root="$(CDPATH='' cd -- "$script_dir/.." && pwd)"
cd "$repo_root"

fail() {
	printf 'RELEASE_PREPARE_CHECK_RED: %s\n' "$1" >&2
	exit 1
}

for helper in \
	"$script_dir/check_release_input_validation.sh" \
	"$script_dir/check_release_evidence.sh" \
	"$script_dir/check_verify_bundle.sh" \
	"$script_dir/release.sh" \
	"$script_dir/validate_release_input.sh" \
	"$script_dir/verify_release_evidence.sh"; do
	[[ -f "$helper" && ! -L "$helper" && -x "$helper" ]] ||
		fail "release helper is unavailable or not a regular executable: $helper"
done

before_status="$(git --no-optional-locks status --porcelain=v1 --untracked-files=all)"
before_index="$(stat -f '%m:%z' .git/index 2>/dev/null || printf 'absent')"

if rg -n '^[[:space:]]*(cargo|rustc|swiftc|xcodebuild|codesign|notarytool|hdiutil|gh|curl|wrangler|mv|cp|rm|install|tee|touch|mkdir|rmdir|ln|eval|source|bash|sh)([[:space:]]|$)' \
	"$script_dir/release.sh" >/dev/null; then
	fail "read-only prepare contains a compiler, artifact, network, provider, or publication command"
fi
if rg -n '^[[:space:]]*git([[:space:]]+--[^[:space:]]+)*[[:space:]]+(add|am|apply|branch|checkout|clean|commit|fetch|merge|mv|pull|push|rebase|reset|restore|revert|rm|stash|switch|tag|update-ref|worktree)([[:space:]]|$)' \
	"$script_dir/release.sh" >/dev/null; then
	fail "read-only prepare contains a Git mutation command"
fi

"$script_dir/check_release_input_validation.sh"
"$script_dir/check_release_evidence.sh"
"$script_dir/check_verify_bundle.sh"

invalid_output="$("$script_dir/release.sh" prepare invalid 2>&1 || true)"
rg -q '^RELEASE_PREPARE_USAGE:' <<<"$invalid_output" ||
	fail "invalid semantic versions do not fail with stable usage output"

set +e
prepare_output="$("$script_dir/release.sh" prepare 0.1.0 2>&1)"
prepare_status=$?
set -e

[[ "$prepare_status" -eq 1 ]] || fail "an incomplete candidate did not stop on readiness blockers"
for required in \
	'^RELEASE_PREPARE_HOLD$' \
	'^candidate_version=0\.1\.0$' \
	'^source_sha=[0-9a-f]{40}$' \
	'^blocker=milestone_0_evidence_admission\|' \
	'^blocker=milestone_1_evidence_admission\|' \
	'^blocker=milestone_2_evidence_admission\|' \
	'^blocker=milestone_3_evidence_admission\|' \
	'^blocker=milestone_4_evidence_admission\|' \
	'^blocker=evidence_authentication_policy\|' \
	'^blocker=legal_sources_unadopted\|' \
	'^blocker=legal_adoption\|' \
	'^blocker=security_adoption\|' \
	'^blocker=p0_ledger_open\|' \
	'^blocker=supply_chain_manifest_open\|' \
	'^blocker=signing_policy\|' \
	'^blocker=release_transaction_plan\|' \
	'^blocker=non_secret_qualification\|' \
	'^next=resolve every blocker'; do
	rg -q "$required" <<<"$prepare_output" ||
		fail "readiness output is missing: $required"
done

receipt_fixture="$(mktemp -d "${TMPDIR:-/tmp}/open-scribe-release-receipts.XXXXXX")"
fixture_sha="$(git rev-parse HEAD)"
fixture_tree="$(git rev-parse 'HEAD^{tree}')"
for milestone in 0 1 2 3 4; do
	jq -n \
		--arg gate_id "M${milestone}_COMPLETE_GREEN" \
		--arg source_sha "$fixture_sha" \
		--arg source_tree "$fixture_tree" \
		'{
          schema: "open-scribe.milestone-receipt/v1",
          result: "Passed",
          gate_id: $gate_id,
          source_sha: $source_sha,
          source_tree: $source_tree,
          artifact_sha256: ("a" * 64),
          observed_at: "2026-08-30T00:00:00Z"
        }' >"$receipt_fixture/m${milestone}-complete.v1.json"
done
jq \
	--arg source_sha "0000000000000000000000000000000000000000" \
	--arg source_tree "1111111111111111111111111111111111111111" \
	'.status = "closed"
     | .candidate = {version: "0.1.0", source_sha: $source_sha, source_tree: $source_tree}
     | .entries |= map(
       .state = "Passed"
       | .receipt = {
         id: ("fixture-" + .id),
         result: "Passed",
         source_sha: $source_sha,
         source_tree: $source_tree,
         artifact_sha256: ("b" * 64),
         observed_at: "2026-08-30T00:00:00Z"
       }
     )' docs/release/p0-ledger.v1.json >"$receipt_fixture/p0-ledger.v1.json"
set +e
receipt_output="$(OPEN_SCRIBE_RELEASE_RECEIPTS_DIR="$receipt_fixture" \
	"$script_dir/release.sh" prepare 0.1.0 2>&1)"
receipt_status=$?
set -e
[[ "$receipt_status" -eq 1 ]] || fail "receipt fixture unexpectedly made the candidate ready"
for milestone in 0 1 2 3 4; do
	rg -q "^blocker=milestone_${milestone}_evidence_admission\\|" <<<"$receipt_output" ||
		fail "hand-authored milestone receipt bypassed the M${milestone} evidence-admission hold"
done
rg -q '^blocker=evidence_authentication_policy\|' <<<"$receipt_output" ||
	fail "hand-authored receipts bypassed the provenance/authentication hold"
rg -q '^blocker=p0_candidate_mismatch\|' <<<"$receipt_output" ||
	fail "stale closed P0 ledger was not rejected against the current candidate"

for forbidden in \
	'^blocker=model_manifest\|' \
	'^blocker=p0_ledger\|docs/release/p0-ledger.v1.json is absent' \
	'^blocker=capability_claim_manifest\|' \
	'^blocker=capability_runtime_registry\|' \
	'^blocker=capability_runtime_mismatch\|' \
	'^blocker=milestone_[0-4]_gate_unavailable\|' \
	'^blocker=release_notes\|' \
	'^blocker=supply_chain_graph_mismatch\|' \
	'^blocker=artifact_verification\|'; do
	if rg -q "$forbidden" <<<"$prepare_output"; then
		fail "readiness output retained resolved or superseded blocker: $forbidden"
	fi
done

rg -q 'include_str!.*runtime-capabilities\.v1\.json' \
	crates/open-scribe-core/src/lib.rs || fail "Rust core no longer embeds the checked registry"
rg -q 'RUNTIME_CAPABILITY_MANIFEST_JSON' \
	crates/open-scribe-core/src/bin/emit_runtime_capabilities.rs ||
	fail "artifact emitter no longer writes the embedded registry"

after_status="$(git --no-optional-locks status --porcelain=v1 --untracked-files=all)"
after_index="$(stat -f '%m:%z' .git/index 2>/dev/null || printf 'absent')"
[[ "$before_status" == "$after_status" ]] || fail "prepare mutated the working tree"
[[ "$before_index" == "$after_index" ]] || fail "prepare mutated the Git index"

printf '%s\n' \
	'RELEASE_PREPARE_CHECK_GREEN' \
	"fixture_residue=$receipt_fixture" \
	'proof=release_input_schemas,open_input_semantics,authenticated_evidence_contract,bundle_verifier_rejection_contract,stable_semver_rejection,exact_source_binding,forged_milestone_receipt_rejection,stale_p0_candidate_rejection,fail_closed_milestone_gate_availability,capability_registry_linkage_and_source_equality,legal_security_p0_holds,complete_source_qualified_locked_component_set,candidate_release_notes,current_source_direct_mutator_vocabulary_absent,observed_worktree_and_index_unchanged' \
	'excludes=milestone_completion,version_allocation,signed_artifact_success,notarization,packaging,publication,deployment,public_release'
