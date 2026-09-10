#!/usr/bin/env bash
set -euo pipefail

script_dir="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
repo_root="$(CDPATH='' cd -- "$script_dir/.." && pwd)"

[[ "$#" -eq 1 ]] || {
	printf 'CAPABILITY_RUNTIME_USAGE: ./script/emit_runtime_capabilities.sh <output-json>\n' >&2
	exit 64
}

output_path="$1"
[[ ! -L "$output_path" ]] || {
	printf 'CAPABILITY_RUNTIME_RED: output path is a symlink\n' >&2
	exit 1
}
output_dir="$(CDPATH='' cd -- "$(dirname -- "$output_path")" && pwd)"
temporary_path="$(mktemp "$output_dir/open-scribe-runtime-capabilities.XXXXXX")"
trap 'rm -f "$temporary_path"' EXIT
registry_path="$repo_root/crates/open-scribe-core/runtime-capabilities.v1.json"
[[ -f "$registry_path" && ! -L "$registry_path" ]] || {
	printf 'CAPABILITY_RUNTIME_RED: Rust capability registry is unavailable or not a regular file\n' >&2
	exit 1
}

cp "$registry_path" "$temporary_path"
"$script_dir/validate_release_input.sh" capability "$temporary_path" >/dev/null
mv "$temporary_path" "$output_path"
printf 'CAPABILITY_RUNTIME_WRITTEN: %s\n' "$output_path"
