#!/usr/bin/env bash
set -euo pipefail

script_dir="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
repo_root="$(CDPATH='' cd -- "$script_dir/.." && pwd)"

usage() {
	printf '%s\n' \
		'RELEASE_PREPARE_USAGE: ./script/release.sh prepare <semver>' \
		'This stage is read-only. It does not allocate a version, sign, notarize, package, publish, or deploy.' >&2
	exit 64
}

[[ "$#" -eq 2 && "$1" == "prepare" ]] || usage
candidate_version="$2"
[[ "$candidate_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+([+-][0-9A-Za-z.-]+)?$ ]] || usage

cd "$repo_root"
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || {
	printf 'RELEASE_PREPARE_ERROR: repository identity is unavailable\n' >&2
	exit 2
}

source_sha="$(git rev-parse HEAD)"
source_tree="$(git rev-parse 'HEAD^{tree}')"
blockers=()
temporary_runtime_manifest=""

cleanup() {
	if [[ -n "$temporary_runtime_manifest" ]]; then
		rm -f "$temporary_runtime_manifest"
	fi
}
trap cleanup EXIT

hold() {
	blockers+=("$1|$2")
}

validate_release_input() {
	local kind="$1"
	local path="$2"
	local missing_id="$3"
	local invalid_id="$4"
	local open_id="$5"
	local validation_output
	local validation_status
	if [[ ! -f "$path" || -L "$path" ]]; then
		hold "$missing_id" "$path is absent or not a regular file"
		return
	fi
	set +e
	validation_output="$("$script_dir/validate_release_input.sh" "$kind" "$path" 2>&1)"
	validation_status=$?
	set -e
	case "$validation_status" in
	0) ;;
	1) hold "$open_id" "$validation_output" ;;
	*) hold "$invalid_id" "$validation_output" ;;
	esac
}

if [[ -n "$(git status --porcelain=v1 --untracked-files=all)" ]]; then
	hold source_tree_clean "tracked or untracked working-tree changes are present"
fi

workspace_version="$(sed -n 's/^version = "\([^"]*\)"/\1/p' Cargo.toml | head -n 1)"
if [[ "$workspace_version" != "$candidate_version" ]]; then
	hold version_allocation "workspace version $workspace_version does not equal candidate $candidate_version"
fi

[[ -x script/check_m0.sh ]] || hold milestone_0_complete_receipt "Milestone 0 gate is unavailable"
for milestone in 1 2 3 4; do
	gate="script/check_m${milestone}_complete.sh"
	[[ -x "$gate" ]] || hold "milestone_${milestone}_complete_receipt" "$gate is absent"
done

if rg -qi 'draft|before release|intended' docs/legal/privacy.md docs/legal/terms.md; then
	hold legal_adoption "privacy and terms sources remain explicitly unadopted drafts"
fi
if rg -qi 'unresolved|does not yet have a verified private disclosure' SECURITY.md; then
	hold private_security_channel "SECURITY.md records no verified private disclosure channel"
fi

validate_release_input p0 docs/release/p0-ledger.v1.json \
	p0_ledger p0_ledger_invalid p0_ledger_open
validate_release_input capability docs/capabilities/manifest.v1.json \
	capability_claim_manifest capability_claim_manifest_invalid capability_claim_manifest_open
if [[ ! -x script/emit_runtime_capabilities.sh ]]; then
	hold capability_runtime_registry \
		"the Rust compile-time registry and emitted runtime-manifest equality gate are absent"
else
	temporary_runtime_manifest="$(mktemp "${TMPDIR:-/tmp}/open-scribe-runtime-capabilities.XXXXXX")"
	if ! script/emit_runtime_capabilities.sh "$temporary_runtime_manifest"; then
		hold capability_runtime_emission "runtime capability emission failed"
	elif ! "$script_dir/validate_release_input.sh" capability "$temporary_runtime_manifest" >/dev/null 2>&1; then
		hold capability_runtime_manifest_invalid "emitted runtime capability manifest is invalid"
	elif ! diff -u \
		<(jq -S . docs/capabilities/manifest.v1.json) \
		<(jq -S . "$temporary_runtime_manifest") >/dev/null; then
		hold capability_runtime_mismatch \
			"checked claims differ from the Rust-emitted runtime capability manifest"
	fi
fi
validate_release_input supply-chain docs/supply-chain/components.v1.json \
	supply_chain_manifest supply_chain_manifest_invalid supply_chain_manifest_open
if [[ -f docs/supply-chain/components.v1.json ]]; then
	actual_lock_sha="$(shasum -a 256 Cargo.lock | awk '{print $1}')"
	manifest_lock_sha="$(jq -r '.cargo_lock_sha256 // ""' docs/supply-chain/components.v1.json)"
	if [[ "$manifest_lock_sha" != "$actual_lock_sha" ]]; then
		hold supply_chain_lock_mismatch "component inventory does not bind the current Cargo.lock"
	fi
	if ! diff -u \
		<(cargo metadata --locked --format-version 1 | jq -r '.packages[] | "cargo:\(.name)@\(.version)"' | sort) \
		<(jq -r '.components[] | select(.id | startswith("cargo:")) | .id' docs/supply-chain/components.v1.json | sort) >/dev/null; then
		hold supply_chain_graph_mismatch \
			"component inventory does not equal the current locked Cargo package graph"
	fi
fi
validate_release_input model docs/models/manifest.v1.json \
	model_manifest model_manifest_invalid model_manifest_open
[[ -f "docs/release/$candidate_version.md" ]] ||
	hold release_notes "docs/release/$candidate_version.md is absent"

if [[ ! -x script/verify_bundle.sh ]]; then
	hold artifact_verification "script/verify_bundle.sh is missing or non-executable"
elif rg -q 'not_implemented\.sh' script/verify_bundle.sh; then
	hold artifact_verification "script/verify_bundle.sh remains a not-implemented stub"
fi
if [[ ! -f docs/release/signing-policy.v1.json ]]; then
	hold signing_policy \
		"approved Developer ID team, certificate hash, and Sparkle public key are not configured"
elif ! jq -e \
	'.schema == "open-scribe.signing-policy/v1"
     and (.team_id | test("^[A-Z0-9]{10}$"))
     and (.developer_id_common_name | type == "string" and length > 0)
     and (.certificate_sha256 | test("^[0-9a-f]{64}$"))
     and (.sparkle_public_key | type == "string" and length > 0)' \
	docs/release/signing-policy.v1.json >/dev/null; then
	hold signing_policy_invalid "signing policy is malformed"
fi
if [[ -f THIRD_PARTY_NOTICES.md ]] && rg -qi 'not a release inventory|placeholder|future' THIRD_PARTY_NOTICES.md; then
	hold third_party_notices "THIRD_PARTY_NOTICES.md is not an admitted release inventory"
fi

if ((${#blockers[@]} > 0)); then
	printf '%s\n' \
		'RELEASE_PREPARE_HOLD' \
		"candidate_version=$candidate_version" \
		"source_sha=$source_sha" \
		"source_tree=$source_tree" \
		'stage=local_read_only_preparation'
	for blocker in "${blockers[@]}"; do
		printf 'blocker=%s\n' "$blocker"
	done
	printf '%s\n' \
		'proof=repository_identity,source_sha,source_tree,working_tree,version,predecessor_gates,legal_security_sources,release_inputs' \
		'excludes=milestone_execution,version_mutation,signing,notarization,packaging,publication,deployment,canonical_readback,public_release' \
		'next=resolve every blocker against this exact source candidate, then rerun prepare'
	exit 1
fi

printf '%s\n' \
	'RELEASE_PREPARE_READY' \
	"candidate_version=$candidate_version" \
	"source_sha=$source_sha" \
	"source_tree=$source_tree" \
	'proof=all_local_non_secret_release_inputs_present' \
	'excludes=signing,notarization,packaging,publication,deployment,canonical_readback,public_release' \
	'next=run every exact-tree non-secret milestone and release-input verifier'
