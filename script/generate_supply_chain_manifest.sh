#!/usr/bin/env bash
set -euo pipefail

script_dir="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
repo_root="$(CDPATH='' cd -- "$script_dir/.." && pwd)"
output_path="$repo_root/docs/supply-chain/components.v1.json"
temporary_path="$(mktemp "${TMPDIR:-/tmp}/open-scribe-components.XXXXXX")"
trap 'rm -f "$temporary_path"' EXIT

cd "$repo_root"
metadata_json="$(cargo metadata --locked --format-version 1)"
lock_sha="$(shasum -a 256 Cargo.lock | awk '{print $1}')"
lock_packages_json="$(awk '
  function emit() {
    if (name != "" && version != "") {
      printf "%s\t%s\t%s\n", name, version, source
    }
  }
  /^\[\[package\]\]$/ { emit(); name = ""; version = ""; source = ""; next }
  /^name = "/ { name = $0; sub(/^name = "/, "", name); sub(/"$/, "", name); next }
  /^version = "/ { version = $0; sub(/^version = "/, "", version); sub(/"$/, "", version); next }
  /^source = "/ { source = $0; sub(/^source = "/, "", source); sub(/"$/, "", source); next }
  END { emit() }
' Cargo.lock | jq -Rn '[inputs | split("\t") | {name: .[0], version: .[1], source: .[2]}]')"

jq -S \
	--arg lock_sha "$lock_sha" \
	--argjson locked "$lock_packages_json" \
	'{
      schema: "open-scribe.components/v1",
      status: "open",
      cargo_lock_sha256: $lock_sha,
      scope: "complete Cargo.lock package set; shipped-target and license-obligation review remains pending",
      components: [
        $locked[] as $locked_package |
        ([.packages[] | select(
          .name == $locked_package.name
          and .version == $locked_package.version
          and ((.source // "") == $locked_package.source)
        )] | first) as $metadata_package |
        (if $locked_package.source == "" then
          ("workspace:" + $locked_package.name)
        else $locked_package.source end) as $source_identity |
        {
          id: ("cargo:" + $locked_package.name + "@" + $locked_package.version + "|" + $source_identity),
          kind: (if $locked_package.source == "" then "workspace-rust" else "rust" end),
          source: $source_identity,
          license: ($metadata_package.license // "UNKNOWN"),
          obligation: (if $locked_package.source == "" then
            "MIT repository license"
          else "Pending review" end),
          included_targets: [],
          binary_path: null,
          sha256: null,
          review_state: (if $locked_package.source == "" then "Admitted" else "Pending" end)
        }
      ] | sort_by(.id)
    }' <<<"$metadata_json" >"$temporary_path"

if [[ "${1:-}" == "--check" ]]; then
	cmp -s "$temporary_path" "$output_path" || {
		printf 'SUPPLY_CHAIN_MANIFEST_RED: generated manifest differs from %s\n' "$output_path" >&2
		exit 1
	}
	printf 'SUPPLY_CHAIN_MANIFEST_CURRENT: %s\n' "$output_path"
	exit 0
fi

[[ "$#" -eq 0 ]] || {
	printf 'SUPPLY_CHAIN_MANIFEST_USAGE: ./script/generate_supply_chain_manifest.sh [--check]\n' >&2
	exit 64
}

mv "$temporary_path" "$output_path"
printf 'SUPPLY_CHAIN_MANIFEST_WRITTEN: %s\n' "$output_path"
