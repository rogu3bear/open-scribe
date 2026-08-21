#!/usr/bin/env bash
set -euo pipefail

script_dir="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
repo_root="$(CDPATH='' cd -- "$script_dir/.." && pwd)"
cd "$repo_root"

# The path is resolved from the bound repository root.
# shellcheck disable=SC1091
source "$repo_root/web/toolchain.env"

require_version() {
	local label="$1"
	local actual="$2"
	local expected="$3"
	[[ "$actual" == "$expected" ]] || {
		printf 'WEB_BUILD_RED: %s %s is active; expected %s\n' "$label" "$actual" "$expected" >&2
		exit 1
	}
}

command -v bun >/dev/null 2>&1 || {
	printf 'WEB_BUILD_RED: bun %s is required\n' "$OPEN_SCRIBE_BUN_VERSION" >&2
	exit 1
}
command -v worker-build >/dev/null 2>&1 || {
	printf 'WEB_BUILD_RED: worker-build %s is required\n' "$OPEN_SCRIBE_WORKER_BUILD_VERSION" >&2
	exit 1
}
cargo leptos --version >/dev/null 2>&1 || {
	printf 'WEB_BUILD_RED: cargo-leptos %s is required\n' "$OPEN_SCRIBE_CARGO_LEPTOS_VERSION" >&2
	exit 1
}

require_version "bun" "$(bun --version)" "$OPEN_SCRIBE_BUN_VERSION"
require_version "cargo-leptos" "$(cargo leptos --version | awk '{print $2}')" "$OPEN_SCRIBE_CARGO_LEPTOS_VERSION"
require_version "worker-build" "$(worker-build --version | awk '{print $1}')" "$OPEN_SCRIBE_WORKER_BUILD_VERSION"

cargo leptos build --release --project open-scribe-web
bun web/scripts/hash_assets.mjs

# shellcheck source=/dev/null
source "$repo_root/target/web-asset-hashes.env"
export OPEN_SCRIBE_WEB_JS_HASH OPEN_SCRIBE_WEB_WASM_HASH OPEN_SCRIBE_WEB_CSS_HASH
worker-build web --release --features ssr
bun web/scripts/write_worker_shim.mjs

cargo run --locked --release -p open-scribe-web --features ssr \
	--bin render-web-ssr -- "$repo_root/target/web-ssr/index.html"
cargo test --locked -p open-scribe-web --features ssr ssr_is_useful_without_hydration
bun web/scripts/verify_build.mjs
