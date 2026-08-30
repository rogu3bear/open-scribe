#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
verifier="$repo_root/script/verify_release_claim_structure.sh"
policy="$repo_root/docs/release/non-secret-claim-policy.v1.json"

fail() {
	printf 'RELEASE_CLAIM_STRUCTURE_CHECK_RED: %s\n' "$1" >&2
	exit 1
}

[[ -f "$verifier" && ! -L "$verifier" && -x "$verifier" ]] || fail "canonical structural claim checker is unavailable"
[[ -f "$policy" && ! -L "$policy" ]] || fail "structural claim policy is unavailable"
jq -e '.admission_complete == false and .authorities == []' \
	"$repo_root/docs/release/evidence-policy.v1.json" >/dev/null ||
	fail "tracked evidence policy is no longer inactive with zero authorities"

fixture="$(mktemp -d "${TMPDIR:-/tmp}/open-scribe-release-claim-check.XXXXXX")"
trap 'rm -rf "$fixture"' EXIT
mkdir -p "$fixture/artifacts"
version="0.1.0"
source_sha="1111111111111111111111111111111111111111"
source_tree="2222222222222222222222222222222222222222"

printf '%s\n' '{"schema":"declared-components","components":[]}' >"$fixture/artifacts/non-cargo-components.v1.json"
printf '%s\n' '{"spdxVersion":"SPDX-2.3","packages":[]}' >"$fixture/artifacts/sbom.spdx.json"
printf '%s\n' '# Declared notices reference' >"$fixture/artifacts/THIRD_PARTY_NOTICES.md"

source_inputs="$(jq -cn --arg version "$version" '[
  "Cargo.toml","Cargo.lock","apps/macos/Package.swift",
  "apps/macos/OpenScribe.xcodeproj/project.pbxproj",
  "apps/macos/Support/Info.plist","apps/macos/Support/OpenScribe.entitlements",
  "web/Cargo.toml","web/wrangler.toml","docs/capabilities/manifest.v1.json",
  "docs/models/manifest.v1.json","docs/supply-chain/components.v1.json",
  "docs/legal/privacy.md","docs/legal/terms.md","SECURITY.md",
  ("docs/release/"+$version+".md"),
  "docs/release/non-secret-claim-policy.v1.json"]')"
source_claims='[]'
while IFS= read -r path; do
	hash="$(shasum -a 256 "$repo_root/$path" | awk '{print $1}')"
	id="$(tr '/ ' '--' <<<"$path")"
	source_claims="$(jq -c --arg id "$id" --arg path "$path" --arg hash "$hash" \
		'. + [{id:$id,path:$path,sha256:$hash}]' <<<"$source_claims")"
done < <(jq -r '.[]' <<<"$source_inputs")

artifact_claims='[]'
for entry in \
	"declared-component-list|non-cargo-components.v1.json|application/json" \
	"declared-spdx-document|sbom.spdx.json|application/spdx+json" \
	"declared-notices|THIRD_PARTY_NOTICES.md|text/markdown"; do
	IFS='|' read -r id path media_type <<<"$entry"
	hash="$(shasum -a 256 "$fixture/artifacts/$path" | awk '{print $1}')"
	artifact_claims="$(jq -c --arg id "$id" --arg path "$path" --arg hash "$hash" --arg media_type "$media_type" \
		'. + [{id:$id,path:$path,sha256:$hash,media_type:$media_type}]' <<<"$artifact_claims")"
done

jq -n \
	--arg version "$version" --arg source_sha "$source_sha" --arg source_tree "$source_tree" \
	--argjson source_inputs "$source_claims" --argjson referenced_artifacts "$artifact_claims" '{
      schema:"open-scribe.release-plan-claim/v1",
      classification:"unauthenticated-structural-claim",
      admission_effect:"none",
      candidate:{version:$version,source_sha:$source_sha,source_tree:$source_tree},
      source_inputs:$source_inputs,
      referenced_artifacts:$referenced_artifacts
    }' >"$fixture/release-plan-claim.v1.json"

plan_output="$("$verifier" plan "$repo_root" "$fixture/artifacts" \
	"$fixture/release-plan-claim.v1.json" "$version" "$source_sha" "$source_tree")"
rg -q '^RELEASE_PLAN_CLAIM_STRUCTURE_OBSERVED:.*admission_effect=none$' <<<"$plan_output" ||
	fail "plan claim did not produce the bounded structural observation"
rg -q 'PASS|READY|COMPLETE' <<<"$plan_output" && fail "plan claim output implied a higher proof plane"

plan_sha="$(shasum -a 256 "$fixture/release-plan-claim.v1.json" | awk '{print $1}')"
policy_sha="$(shasum -a 256 "$policy" | awk '{print $1}')"
command_claims='[]'
while IFS=$'\t' read -r id command path; do
	hash="$(shasum -a 256 "$repo_root/$path" | awk '{print $1}')"
	command_claims="$(jq -c --arg id "$id" --arg command "$command" --arg path "$path" --arg hash "$hash" \
		'. + [{id:$id,command:$command,reference_path:$path,reference_sha256:$hash}]' <<<"$command_claims")"
done < <(jq -r '.commands[] | [.id,.command,.reference_path] | @tsv' "$policy")

jq -n \
	--arg version "$version" --arg source_sha "$source_sha" --arg source_tree "$source_tree" \
	--arg plan_sha "$plan_sha" --arg policy_sha "$policy_sha" --argjson commands "$command_claims" '{
      schema:"open-scribe.non-secret-command-claim/v1",
      classification:"unauthenticated-structural-claim",
      admission_effect:"none",
      candidate:{version:$version,source_sha:$source_sha,source_tree:$source_tree},
      release_plan_claim_sha256:$plan_sha,
      policy_sha256:$policy_sha,
      commands:$commands
    }' >"$fixture/non-secret-command-claim.v1.json"

command_claim_output="$("$verifier" commands "$repo_root" "$policy" \
	"$fixture/release-plan-claim.v1.json" "$fixture/non-secret-command-claim.v1.json" \
	"$version" "$source_sha" "$source_tree" "$plan_sha")"
rg -q '^NON_SECRET_COMMAND_CLAIM_STRUCTURE_OBSERVED:.*admission_effect=none$' <<<"$command_claim_output" ||
	fail "command claim did not produce the bounded structural observation"
rg -q 'PASS|READY|COMPLETE' <<<"$command_claim_output" && fail "command claim output implied a higher proof plane"

jq '.admission_effect = "release"' "$fixture/release-plan-claim.v1.json" >"$fixture/mutant.json"
if "$verifier" plan "$repo_root" "$fixture/artifacts" "$fixture/mutant.json" \
	"$version" "$source_sha" "$source_tree" >/dev/null 2>&1; then
	fail "plan claim with an admission implication was accepted"
fi
jq '.commands[0].reference_sha256 = ("0" * 64)' "$fixture/non-secret-command-claim.v1.json" >"$fixture/mutant.json"
if "$verifier" commands "$repo_root" "$policy" "$fixture/release-plan-claim.v1.json" \
	"$fixture/mutant.json" "$version" "$source_sha" "$source_tree" "$plan_sha" >/dev/null 2>&1; then
	fail "command claim with a false declared reference hash was accepted"
fi
ln -s "$fixture/release-plan-claim.v1.json" "$fixture/plan-symlink.json"
if "$verifier" plan "$repo_root" "$fixture/artifacts" "$fixture/plan-symlink.json" \
	"$version" "$source_sha" "$source_tree" >/dev/null 2>&1; then
	fail "symlinked plan claim was accepted"
fi

printf '%s\n' \
	'RELEASE_CLAIM_STRUCTURE_CHECK_GREEN' \
	'observes=schema,candidate_strings,declared_file_hashes,declared_command_set,final_component_identity,inactive_evidence_policy' \
	'does_not_prove=command_execution,receipt_authentication,inventory_completeness,deterministic_generation,toolchain_identity,notice_semantics,path_containment,admission,release'
