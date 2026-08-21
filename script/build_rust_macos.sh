#!/usr/bin/env bash
set -euo pipefail

script_dir="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
repo_root="$(CDPATH='' cd -- "$script_dir/.." && pwd)"
target_triple="aarch64-apple-darwin"
deployment_target="13.0"

if [[ "$#" -ne 1 || "$1" != /* ]]; then
	printf 'usage: %s <absolute-cargo-target-directory>\n' "$0" >&2
	exit 64
fi

cargo_target_dir="$1"
export CARGO_TARGET_DIR="$cargo_target_dir"
export MACOSX_DEPLOYMENT_TARGET="$deployment_target"

cd "$repo_root"
cargo build --locked \
	--target "$target_triple" \
	-p open-scribe-uniffi

library="$cargo_target_dir/$target_triple/debug/libopen_scribe_uniffi.a"
[[ -f "$library" ]] || {
	printf 'RUST_MACOS_BUILD_RED: expected static library is missing: %s\n' "$library" >&2
	exit 1
}

printf '%s\n' "$library"
