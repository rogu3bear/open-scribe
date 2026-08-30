#!/usr/bin/env bash
set -euo pipefail

usage() {
	printf '%s\n' \
		'RELEASE_CLAIM_STRUCTURE_USAGE: verify_release_claim_structure.sh plan <repo-root> <claim-root> <plan-claim> <version> <source-sha> <source-tree>' \
		'RELEASE_CLAIM_STRUCTURE_USAGE: verify_release_claim_structure.sh commands <repo-root> <policy> <plan-claim> <command-claim> <version> <source-sha> <source-tree> <plan-claim-sha256>' >&2
	exit 64
}

mode="${1:-}"
safe_id='^[A-Za-z0-9._@+:/=-]+$'
safe_relative='^[A-Za-z0-9._/-]+$'
sha1_pattern='^[0-9a-f]{40}$'
sha256_pattern='^[0-9a-f]{64}$'
semver_pattern='^[0-9]+\.[0-9]+\.[0-9]+([+-][0-9A-Za-z.-]+)?$'

command -v lsof >/dev/null 2>&1 || {
	printf '%s\n' 'RELEASE_CLAIM_STRUCTURE_INVALID: lsof is required for descriptor identity observation' >&2
	exit 2
}

snapshot_root="$(mktemp -d "${TMPDIR:-/tmp}/open-scribe-release-claim-structure.XXXXXX")"
trap 'rm -rf "$snapshot_root"' EXIT
chmod 700 "$snapshot_root"
snapshot_sequence=0
snapshot_result=''

invalid() {
	printf 'RELEASE_CLAIM_STRUCTURE_INVALID: %s\n' "$1" >&2
	exit 2
}

snapshot_regular_file() {
	local source="$1"
	local label="$2"
	local before_identity after_identity fd_info open_device open_inode open_type destination
	[[ -f "$source" && ! -L "$source" ]] || invalid "$label is missing, non-regular, or symlinked"
	before_identity="$(stat -f '%d:%i:%HT' "$source")"
	exec 3<"$source"
	fd_info="$(lsof -a -p "$$" -d 3 -F Dift)"
	open_device="$(sed -n 's/^D//p' <<<"$fd_info")"
	open_inode="$(sed -n 's/^i//p' <<<"$fd_info")"
	open_type="$(sed -n 's/^t//p' <<<"$fd_info")"
	after_identity="$(stat -f '%d:%i:%HT' "$source")"
	[[ "$open_device" =~ ^0x[0-9a-fA-F]+$ && "$open_inode" =~ ^[0-9]+$ ]] || {
		exec 3<&-
		invalid "$label descriptor identity is unavailable"
	}
	open_device="$((open_device))"
	[[ "$before_identity" == "$after_identity" && ! -L "$source" && -f "$source" &&
		"$after_identity" == "$open_device:$open_inode:Regular File" && "$open_type" == "REG" ]] || {
		exec 3<&-
		invalid "$label identity changed while opening"
	}
	snapshot_sequence=$((snapshot_sequence + 1))
	destination="$snapshot_root/$snapshot_sequence.snapshot"
	cat <&3 >"$destination"
	exec 3<&-
	chmod 600 "$destination"
	snapshot_result="$destination"
}

safe_repo_file() {
	local repo_root="$1"
	local relative="$2"
	[[ "$relative" =~ $safe_relative && "$relative" != /* && "$relative" != *..* && "$relative" != *//* ]] ||
		invalid "unsafe repository-relative path: $relative"
	printf '%s/%s\n' "$repo_root" "$relative"
}

validate_common_identity() {
	local version="$1"
	local source_sha="$2"
	local source_tree="$3"
	[[ "$version" =~ $semver_pattern ]] || usage
	[[ "$source_sha" =~ $sha1_pattern ]] || usage
	[[ "$source_tree" =~ $sha1_pattern ]] || usage
}

require_non_admitting_policy() {
	local repo_root="$1"
	local evidence_policy
	snapshot_regular_file "$repo_root/docs/release/evidence-policy.v1.json" "tracked evidence policy"
	evidence_policy="$snapshot_result"
	jq -e '
      .schema == "open-scribe.release-evidence-policy/v1"
      and .admission_complete == false
      and .authorities == []' "$evidence_policy" >/dev/null ||
		invalid "tracked evidence policy is not explicitly inactive with zero authorities"
}

validate_plan_claim() {
	local repo_root="$1"
	local claim_root="$2"
	local plan_path="$3"
	local version="$4"
	local source_sha="$5"
	local source_tree="$6"
	local plan expected_paths actual_paths path declared_hash snapshot

	validate_common_identity "$version" "$source_sha" "$source_tree"
	[[ -d "$repo_root" && ! -L "$repo_root" ]] || invalid "repository root is unavailable or symlinked"
	[[ -d "$claim_root" && ! -L "$claim_root" ]] || invalid "claim root is unavailable or symlinked"
	require_non_admitting_policy "$repo_root"
	snapshot_regular_file "$plan_path" "release plan claim"
	plan="$snapshot_result"

	jq -e \
		--arg version "$version" --arg source_sha "$source_sha" --arg source_tree "$source_tree" \
		--arg safe_id "$safe_id" --arg safe_relative "$safe_relative" --arg sha256 "$sha256_pattern" '
      .schema == "open-scribe.release-plan-claim/v1"
      and .classification == "unauthenticated-structural-claim"
      and .admission_effect == "none"
      and .candidate.version == $version
      and .candidate.source_sha == $source_sha
      and .candidate.source_tree == $source_tree
      and (.source_inputs | type == "array" and length == 16 and all(
        (.id | test($safe_id))
        and (.path | test($safe_relative))
        and (.path | startswith("/") | not)
        and (.path | contains("..") | not)
        and (.sha256 | test($sha256))))
      and (([.source_inputs[].id] | length) == ([.source_inputs[].id] | unique | length))
      and (([.source_inputs[].path] | length) == ([.source_inputs[].path] | unique | length))
      and (.referenced_artifacts | type == "array" and length == 3 and all(
        (.id | test($safe_id))
        and (.path | test($safe_relative))
        and (.path | startswith("/") | not)
        and (.path | contains("..") | not)
        and (.sha256 | test($sha256))
        and (.media_type | test("^[A-Za-z0-9.+/-]+$"))))
      and (([.referenced_artifacts[].id] | sort) == ["declared-component-list","declared-notices","declared-spdx-document"])
      and (([.referenced_artifacts[].path] | sort) == ["THIRD_PARTY_NOTICES.md","non-cargo-components.v1.json","sbom.spdx.json"])' \
		"$plan" >/dev/null || invalid "release plan claim structure or candidate declaration is invalid"

	expected_paths="$(jq -cn --arg version "$version" '[
      "Cargo.toml","Cargo.lock","apps/macos/Package.swift",
      "apps/macos/OpenScribe.xcodeproj/project.pbxproj",
      "apps/macos/Support/Info.plist","apps/macos/Support/OpenScribe.entitlements",
      "web/Cargo.toml","web/wrangler.toml","docs/capabilities/manifest.v1.json",
      "docs/models/manifest.v1.json","docs/supply-chain/components.v1.json",
      "docs/legal/privacy.md","docs/legal/terms.md","SECURITY.md",
      ("docs/release/"+$version+".md"),
      "docs/release/non-secret-claim-policy.v1.json"] | sort')"
	actual_paths="$(jq -c '[.source_inputs[].path] | sort' "$plan")"
	[[ "$actual_paths" == "$expected_paths" ]] || invalid "release plan claim source-input set is unexpected"

	while IFS=$'\t' read -r path declared_hash; do
		snapshot_regular_file "$(safe_repo_file "$repo_root" "$path")" "declared source input $path"
		snapshot="$snapshot_result"
		[[ "$(shasum -a 256 "$snapshot" | awk '{print $1}')" == "$declared_hash" ]] ||
			invalid "declared source-input hash differs from current bytes: $path"
	done < <(jq -r '.source_inputs[] | [.path,.sha256] | @tsv' "$plan")

	while IFS=$'\t' read -r path declared_hash; do
		snapshot_regular_file "$claim_root/$path" "declared referenced artifact $path"
		snapshot="$snapshot_result"
		[[ "$(shasum -a 256 "$snapshot" | awk '{print $1}')" == "$declared_hash" ]] ||
			invalid "declared referenced-artifact hash differs from current bytes: $path"
	done < <(jq -r '.referenced_artifacts[] | [.path,.sha256] | @tsv' "$plan")

	printf 'RELEASE_PLAN_CLAIM_STRUCTURE_OBSERVED: version=%s source_sha=%s source_tree=%s claim_sha256=%s admission_effect=none\n' \
		"$version" "$source_sha" "$source_tree" "$(shasum -a 256 "$plan" | awk '{print $1}')"
}

validate_command_claim() {
	local repo_root="$1"
	local policy_path="$2"
	local plan_path="$3"
	local command_claim_path="$4"
	local version="$5"
	local source_sha="$6"
	local source_tree="$7"
	local expected_plan_sha="$8"
	local policy plan command_claim policy_sha actual_plan_sha path declared_hash snapshot

	validate_common_identity "$version" "$source_sha" "$source_tree"
	[[ "$expected_plan_sha" =~ $sha256_pattern ]] || usage
	[[ -d "$repo_root" && ! -L "$repo_root" ]] || invalid "repository root is unavailable or symlinked"
	require_non_admitting_policy "$repo_root"
	snapshot_regular_file "$policy_path" "non-secret claim policy"
	policy="$snapshot_result"
	snapshot_regular_file "$plan_path" "release plan claim"
	plan="$snapshot_result"
	snapshot_regular_file "$command_claim_path" "non-secret command claim"
	command_claim="$snapshot_result"
	policy_sha="$(shasum -a 256 "$policy" | awk '{print $1}')"
	actual_plan_sha="$(shasum -a 256 "$plan" | awk '{print $1}')"
	[[ "$actual_plan_sha" == "$expected_plan_sha" ]] || invalid "release plan claim hash differs from the declared hash"

	jq -e --arg safe_id "$safe_id" --arg safe_relative "$safe_relative" '
      .schema == "open-scribe.non-secret-claim-policy/v1"
      and .classification == "unauthenticated-structural-claim"
      and .admission_effect == "none"
      and (.scope | type == "string" and length > 0)
      and (.commands | type == "array" and length > 0 and all(
        (.id | test($safe_id))
        and (.command | type == "string" and length > 0)
        and (.command | test("[\\n\\r]") | not)
        and (.reference_path | test($safe_relative))
        and (.reference_path | startswith("/") | not)
        and (.reference_path | contains("..") | not)))
      and (([.commands[].id] | length) == ([.commands[].id] | unique | length))
      and (.future_execution_design_requirements | type == "array" and length == 6)' \
		"$policy" >/dev/null || invalid "non-secret claim policy structure is invalid"

	jq -e \
		--arg version "$version" --arg source_sha "$source_sha" --arg source_tree "$source_tree" \
		--arg plan_sha "$expected_plan_sha" --arg policy_sha "$policy_sha" \
		--arg safe_id "$safe_id" --arg sha256 "$sha256_pattern" '
      .schema == "open-scribe.non-secret-command-claim/v1"
      and .classification == "unauthenticated-structural-claim"
      and .admission_effect == "none"
      and .candidate.version == $version
      and .candidate.source_sha == $source_sha
      and .candidate.source_tree == $source_tree
      and .release_plan_claim_sha256 == $plan_sha
      and .policy_sha256 == $policy_sha
      and (.commands | type == "array" and length > 0 and all(
        (.id | test($safe_id))
        and (.command | type == "string" and length > 0)
        and (.reference_path | type == "string" and length > 0)
        and (.reference_sha256 | test($sha256))))
      and (([.commands[].id] | length) == ([.commands[].id] | unique | length))' \
		"$command_claim" >/dev/null || invalid "non-secret command claim structure or candidate declaration is invalid"

	jq -e -s '
      ([.[0].commands[] | {id,command,reference_path}] | sort_by(.id))
      == ([.[1].commands[] | {id,command,reference_path}] | sort_by(.id))' \
		"$policy" "$command_claim" >/dev/null || invalid "non-secret command claim set differs from policy"

	while IFS=$'\t' read -r path declared_hash; do
		snapshot_regular_file "$(safe_repo_file "$repo_root" "$path")" "declared command reference $path"
		snapshot="$snapshot_result"
		[[ "$(shasum -a 256 "$snapshot" | awk '{print $1}')" == "$declared_hash" ]] ||
			invalid "declared command-reference hash differs from current bytes: $path"
	done < <(jq -r '.commands[] | [.reference_path,.reference_sha256] | @tsv' "$command_claim")

	printf 'NON_SECRET_COMMAND_CLAIM_STRUCTURE_OBSERVED: version=%s source_sha=%s source_tree=%s claim_sha256=%s admission_effect=none\n' \
		"$version" "$source_sha" "$source_tree" "$(shasum -a 256 "$command_claim" | awk '{print $1}')"
}

case "$mode" in
plan)
	[[ "$#" -eq 7 ]] || usage
	validate_plan_claim "$2" "$3" "$4" "$5" "$6" "$7"
	;;
commands)
	[[ "$#" -eq 9 ]] || usage
	validate_command_claim "$2" "$3" "$4" "$5" "$6" "$7" "$8" "$9"
	;;
*) usage ;;
esac
