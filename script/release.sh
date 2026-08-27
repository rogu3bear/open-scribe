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

hold() {
	blockers+=("$1|$2")
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

[[ -f docs/release/p0-ledger.v1.json ]] ||
	hold p0_ledger "docs/release/p0-ledger.v1.json is absent"
[[ -f docs/capabilities/runtime.v1.json ]] ||
	hold capability_runtime_manifest "docs/capabilities/runtime.v1.json is absent"
[[ -f docs/supply-chain/components.v1.json ]] ||
	hold supply_chain_manifest "docs/supply-chain/components.v1.json is absent"
[[ -f docs/models/manifest.v1.json ]] ||
	hold model_manifest "docs/models/manifest.v1.json is absent"
[[ -f "docs/release/$candidate_version.md" ]] ||
	hold release_notes "docs/release/$candidate_version.md is absent"

if [[ -x script/verify_bundle.sh ]] && rg -q 'not_implemented\.sh' script/verify_bundle.sh; then
	hold artifact_verification "script/verify_bundle.sh remains fail-closed"
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
