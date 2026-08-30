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
validator="$script_dir/validate_release_input.sh"
[[ -f "$validator" && ! -L "$validator" && -x "$validator" ]] || {
	printf 'RELEASE_PREPARE_ERROR: release-input validator is unavailable or not a regular executable\n' >&2
	exit 2
}
evidence_verifier="$script_dir/verify_release_evidence.sh"
evidence_policy="docs/release/evidence-policy.v1.json"
[[ -f "$evidence_verifier" && ! -L "$evidence_verifier" && -x "$evidence_verifier" ]] || {
	printf 'RELEASE_PREPARE_ERROR: release-evidence verifier is unavailable or not a regular executable\n' >&2
	exit 2
}

source_sha="$(git rev-parse HEAD)"
source_tree="$(git rev-parse 'HEAD^{tree}')"
blockers=()
receipt_root="${OPEN_SCRIBE_RELEASE_RECEIPTS_DIR:-$repo_root/var/release-receipts/$source_sha}"

if [[ "$receipt_root" != /* ]]; then
	printf 'RELEASE_PREPARE_ERROR: receipt root must be absolute\n' >&2
	exit 2
fi
case "$receipt_root" in
"$repo_root"/*)
	receipt_relative="${receipt_root#"$repo_root"/}"
	if ! git --no-optional-locks check-ignore -q -- "$receipt_relative"; then
		printf 'RELEASE_PREPARE_ERROR: in-repository receipt root must be ignored\n' >&2
		exit 2
	fi
	;;
esac
if [[ -e "$receipt_root" ]]; then
	if [[ ! -d "$receipt_root" || -L "$receipt_root" ]]; then
		printf 'RELEASE_PREPARE_ERROR: receipt root is not a real directory\n' >&2
		exit 2
	fi
	receipt_root="$(CDPATH='' cd -- "$receipt_root" && pwd -P)"
fi

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
	validation_output="$("$validator" "$kind" "$path" 2>&1)"
	validation_status=$?
	set -e
	case "$validation_status" in
	0) ;;
	1) hold "$open_id" "$validation_output" ;;
	*) hold "$invalid_id" "$validation_output" ;;
	esac
}

validate_adoption_receipt() {
	local kind="$1"
	local receipt_path="$receipt_root/${kind}-adoption.v1.json"
	shift
	if [[ ! -f "$receipt_path" || -L "$receipt_path" ]]; then
		hold "${kind}_adoption" "$receipt_path is absent or not a regular file"
		return
	fi
	if ! jq -e "$@" "$receipt_path" >/dev/null; then
		hold "${kind}_adoption_invalid" \
			"$receipt_path does not bind the current checked sources"
	fi
}

if [[ -n "$(git --no-optional-locks status --porcelain=v1 --untracked-files=all)" ]]; then
	hold source_tree_clean "tracked or untracked working-tree changes are present"
fi

if [[ ! -f Cargo.toml || -L Cargo.toml ]]; then
	hold workspace_manifest "Cargo.toml is absent or not a regular file"
else
	workspace_version="$(sed -n 's/^version = "\([^"]*\)"/\1/p' Cargo.toml | head -n 1)"
	if [[ "$workspace_version" != "$candidate_version" ]]; then
		hold version_allocation "workspace version $workspace_version does not equal candidate $candidate_version"
	fi
fi

[[ -f script/check_m0.sh && ! -L script/check_m0.sh && -x script/check_m0.sh ]] ||
	hold milestone_0_gate_unavailable "Milestone 0 gate is unavailable or not a regular executable"
for milestone in 0 1 2 3 4; do
	if [[ "$milestone" -gt 0 ]]; then
		gate="script/check_m${milestone}_complete.sh"
		[[ -f "$gate" && ! -L "$gate" && -x "$gate" ]] ||
			hold "milestone_${milestone}_gate_unavailable" \
				"$gate is unavailable or not a regular executable"
	fi
	hold "milestone_${milestone}_evidence_admission" \
		"no authenticated canonical verifier currently admits M${milestone} completion for release preparation"
done
if [[ ! -f "$evidence_policy" || -L "$evidence_policy" ]] ||
	! jq -e '
      .schema == "open-scribe.release-evidence-policy/v1"
      and .namespace == "open-scribe-release-evidence"
      and (.max_age_seconds | type == "number" and . > 0)
      and .admission_complete == true
      and (.authorities | type == "array" and length > 0)
      and (.authorities | any(.active == true))' "$evidence_policy" >/dev/null 2>&1; then
	hold evidence_authentication_policy \
		"authenticated evidence admission is intentionally inactive; historical and unsigned receipts remain advisory"
fi

if [[ ! -f docs/legal/privacy.md || -L docs/legal/privacy.md ||
	! -f docs/legal/terms.md || -L docs/legal/terms.md ]]; then
	hold legal_sources "privacy and terms sources are absent or not regular files"
else
	privacy_sha="$(shasum -a 256 docs/legal/privacy.md | awk '{print $1}')"
	terms_sha="$(shasum -a 256 docs/legal/terms.md | awk '{print $1}')"
	if rg -qi 'draft|before release|intended' docs/legal/privacy.md docs/legal/terms.md; then
		hold legal_sources_unadopted "privacy and terms sources remain explicit drafts"
	fi
	# shellcheck disable=SC2016 # jq variables are intentionally resolved by jq, not the shell.
	validate_adoption_receipt legal \
		--arg privacy_sha "$privacy_sha" \
		--arg terms_sha "$terms_sha" \
		'.schema == "open-scribe.legal-adoption/v1"
         and .privacy_sha256 == $privacy_sha
         and .terms_sha256 == $terms_sha
         and (.approver | type == "string" and length > 0)
         and (.adopted_at | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T"))'
fi
if [[ ! -f SECURITY.md || -L SECURITY.md ]]; then
	hold security_source "SECURITY.md is absent or not a regular file"
else
	security_sha="$(shasum -a 256 SECURITY.md | awk '{print $1}')"
	# shellcheck disable=SC2016 # jq variables are intentionally resolved by jq, not the shell.
	validate_adoption_receipt security \
		--arg security_sha "$security_sha" \
		'.schema == "open-scribe.security-adoption/v1"
         and .security_policy_sha256 == $security_sha
         and (.private_channel | type == "string" and length > 0)
         and (.approver | type == "string" and length > 0)
         and (.verified_at | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T"))'
fi

p0_input="$receipt_root/p0-ledger.v1.json"
if [[ ! -f "$p0_input" || -L "$p0_input" ]]; then
	p0_input="docs/release/p0-ledger.v1.json"
fi
validate_release_input p0 "$p0_input" \
	p0_ledger p0_ledger_invalid p0_ledger_open
if jq -e '.status == "closed"' "$p0_input" >/dev/null 2>&1 &&
	! jq -e \
		--arg version "$candidate_version" \
		--arg source_sha "$source_sha" \
		--arg source_tree "$source_tree" \
		'.candidate.version == $version
         and .candidate.source_sha == $source_sha
         and .candidate.source_tree == $source_tree' "$p0_input" >/dev/null; then
	hold p0_candidate_mismatch "closed P0 ledger does not bind the current candidate"
fi
validate_release_input capability docs/capabilities/manifest.v1.json \
	capability_claim_manifest capability_claim_manifest_invalid capability_claim_manifest_open
if [[ ! -f script/emit_runtime_capabilities.sh || -L script/emit_runtime_capabilities.sh ||
	! -x script/emit_runtime_capabilities.sh ]]; then
	hold capability_runtime_registry \
		"the Rust compile-time registry and emitted runtime-manifest equality gate are absent"
else
	runtime_registry="crates/open-scribe-core/runtime-capabilities.v1.json"
	if ! rg -q 'include_str!.*runtime-capabilities\.v1\.json' \
		crates/open-scribe-core/src/lib.rs; then
		hold capability_runtime_linkage \
			"Rust core no longer embeds the checked capability registry"
	elif ! rg -q 'RUNTIME_CAPABILITY_MANIFEST_JSON' \
		crates/open-scribe-core/src/bin/emit_runtime_capabilities.rs; then
		hold capability_runtime_emitter_linkage \
			"artifact emitter no longer writes the embedded capability registry"
	elif ! "$validator" capability "$runtime_registry" >/dev/null 2>&1; then
		hold capability_runtime_manifest_invalid "Rust compile-time capability registry is invalid"
	elif ! diff -u \
		<(jq -S . docs/capabilities/manifest.v1.json) \
		<(jq -S . "$runtime_registry") >/dev/null; then
		hold capability_runtime_mismatch \
			"checked claims differ from the Rust-emitted runtime capability manifest"
	fi
fi
validate_release_input supply-chain docs/supply-chain/components.v1.json \
	supply_chain_manifest supply_chain_manifest_invalid supply_chain_manifest_open
if [[ -f docs/supply-chain/components.v1.json && ! -L docs/supply-chain/components.v1.json &&
	-f Cargo.lock && ! -L Cargo.lock ]]; then
	actual_lock_sha="$(shasum -a 256 Cargo.lock | awk '{print $1}')"
	manifest_lock_sha="$(jq -r '.cargo_lock_sha256 // ""' docs/supply-chain/components.v1.json)"
	if [[ "$manifest_lock_sha" != "$actual_lock_sha" ]]; then
		hold supply_chain_lock_mismatch "component inventory does not bind the current Cargo.lock"
	fi
	if ! diff -u \
		<(awk '
		  function emit() {
		    if (name != "" && version != "") {
		      source_identity = source
		      if (source_identity == "") source_identity = "workspace:" name
		      print "cargo:" name "@" version "|" source_identity
		    }
		  }
		  /^\[\[package\]\]$/ { emit(); name = ""; version = ""; source = ""; next }
		  /^name = "/ { name = $0; sub(/^name = "/, "", name); sub(/"$/, "", name); next }
		  /^version = "/ {
		    version = $0
		    sub(/^version = "/, "", version)
		    sub(/"$/, "", version)
		    next
		  }
		  /^source = "/ { source = $0; sub(/^source = "/, "", source); sub(/"$/, "", source); next }
		  END { emit() }
		' Cargo.lock | sort) \
		<(jq -r '.components[] | select(.id | startswith("cargo:")) | .id' docs/supply-chain/components.v1.json | sort) >/dev/null; then
		hold supply_chain_graph_mismatch \
			"component inventory does not equal the current locked Cargo package graph"
	fi
elif [[ ! -f Cargo.lock || -L Cargo.lock ]]; then
	hold cargo_lock "Cargo.lock is absent or not a regular file"
fi
validate_release_input model docs/models/manifest.v1.json \
	model_manifest model_manifest_invalid model_manifest_open
if [[ ! -f "docs/release/$candidate_version.md" || -L "docs/release/$candidate_version.md" ]]; then
	hold release_notes "docs/release/$candidate_version.md is absent or not a regular file"
fi

if [[ ! -f script/verify_bundle.sh || -L script/verify_bundle.sh || ! -x script/verify_bundle.sh ]]; then
	hold artifact_verification "script/verify_bundle.sh is missing or non-executable"
elif rg -q 'not_implemented\.sh' script/verify_bundle.sh; then
	hold artifact_verification "script/verify_bundle.sh remains a not-implemented stub"
fi
if [[ ! -f docs/release/signing-policy.v1.json || -L docs/release/signing-policy.v1.json ]]; then
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
if [[ ! -f THIRD_PARTY_NOTICES.md || -L THIRD_PARTY_NOTICES.md ]]; then
	hold third_party_notices "THIRD_PARTY_NOTICES.md is absent or not a regular file"
else
	notices_sha="$(shasum -a 256 THIRD_PARTY_NOTICES.md | awk '{print $1}')"
	supply_chain_sha="$(shasum -a 256 docs/supply-chain/components.v1.json | awk '{print $1}')"
	# shellcheck disable=SC2016 # jq variables are intentionally resolved by jq, not the shell.
	validate_adoption_receipt third_party \
		--arg notices_sha "$notices_sha" \
		--arg supply_chain_sha "$supply_chain_sha" \
		'.schema == "open-scribe.third-party-adoption/v1"
         and .notices_sha256 == $notices_sha
         and .supply_chain_sha256 == $supply_chain_sha
         and (.reviewer | type == "string" and length > 0)
         and (.reviewed_at | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T"))'
fi

hold release_transaction_plan \
	"the semantic non-Cargo inventory, SPDX, deterministic notices, and unsigned content-addressed plan verifier is not implemented"
hold non_secret_qualification \
	"the canonical exact-candidate non-secret qualification verifier is not implemented"

if ((${#blockers[@]} > 0)); then
	printf '%s\n' \
		'RELEASE_PREPARE_HOLD' \
		"candidate_version=$candidate_version" \
		"source_sha=$source_sha" \
		"source_tree=$source_tree" \
		"receipt_root=$receipt_root" \
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
	"receipt_root=$receipt_root" \
	'proof=all_local_non_secret_release_inputs_present' \
	'excludes=signing,notarization,packaging,publication,deployment,canonical_readback,public_release' \
	'next=run every exact-tree non-secret milestone and release-input verifier'
