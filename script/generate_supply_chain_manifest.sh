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

jq -S \
	--arg lock_sha "$lock_sha" \
	'{
      schema: "open-scribe.components/v1",
      status: "open",
      cargo_lock_sha256: $lock_sha,
      scope: "complete Cargo dependency graph; shipped-target and license-obligation review remains pending",
      components: [
        .packages[] |
        {
          id: ("cargo:" + .name + "@" + .version),
          kind: (if .source == null then "workspace-rust" else "rust" end),
          source: (if .source == null then ("workspace:" + .name) else .source end),
          license: (.license // "UNKNOWN"),
          obligation: (if .source == null then "MIT repository license" else "Pending review" end),
          included_targets: [],
          binary_path: null,
          sha256: null,
          review_state: (if .source == null then "Admitted" else "Pending" end)
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
