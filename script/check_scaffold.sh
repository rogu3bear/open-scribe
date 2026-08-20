#!/usr/bin/env bash
set -euo pipefail

script_dir="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
repo_root="$(CDPATH='' cd -- "$script_dir/.." && pwd)"
cd "$repo_root"

fail() {
	printf 'SCAFFOLD_RED: %s\n' "$1" >&2
	exit 1
}

required_paths=(
	AGENTS.md
	CLAUDE.md
	NORTH_STAR.md
	ANCHOR.md
	LAYERS.md
	ARCHITECTURE.md
	ACTOR.md
	NUANCE.md
	SOUL.md
	README.md
	CONTRIBUTING.md
	SECURITY.md
	LICENSE
	THIRD_PARTY_NOTICES.md
	Cargo.lock
	Cargo.toml
	rust-toolchain.toml
	.github/workflows/m0-native.yml
	apps/macos/README.md
	web/README.md
	docs/product/FOUNDING_PRD.md
	docs/architecture/0001-m0-native-shell-and-uniffi.md
	docs/architecture/0002-m0-proof-toolchain-and-ci.md
	docs/legal/privacy.md
	docs/legal/terms.md
	docs/design/DESIGN.md
	docs/threat-model.md
)

for required_path in "${required_paths[@]}"; do
	[[ -f "$required_path" ]] || fail "missing required path: $required_path"
done

cmp -s AGENTS.md CLAUDE.md || fail "AGENTS.md and CLAUDE.md are not byte-identical"

check_budget() {
	local document="$1"
	local maximum="$2"
	local words
	words="$(wc -w <"$document" | tr -d ' ')"
	((words <= maximum)) || fail "$document exceeds its $maximum-word budget ($words)"
}

check_budget NORTH_STAR.md 300
check_budget ANCHOR.md 350
check_budget LAYERS.md 400
check_budget ARCHITECTURE.md 700
check_budget ACTOR.md 600
check_budget NUANCE.md 500
check_budget SOUL.md 600

(
	cd docs/product
	shasum -a 256 -c FOUNDING_PRD.sha256
) >/dev/null || fail "founding PRD checksum mismatch"

metadata_json="$(cargo metadata --locked --no-deps --format-version 1)"
expected_packages=(
	open-scribe-types
	open-scribe-domain
	open-scribe-evidence
	open-scribe-store
	open-scribe-asr
	open-scribe-diarize
	open-scribe-memory
	open-scribe-models
	open-scribe-core
	open-scribe-uniffi
)

package_count="$(jq '.packages | length' <<<"$metadata_json")"
[[ "$package_count" -eq "${#expected_packages[@]}" ]] ||
	fail "expected ${#expected_packages[@]} Cargo packages, found $package_count"

for package in "${expected_packages[@]}"; do
	jq -e --arg package "$package" '.packages | any(.name == $package)' \
		<<<"$metadata_json" >/dev/null ||
		fail "Cargo metadata is missing $package"
done

shared_manifests=(
	crates/open-scribe-types/Cargo.toml
	crates/open-scribe-domain/Cargo.toml
	crates/open-scribe-evidence/Cargo.toml
)

if rg -n 'open-scribe-(store|asr|diarize|memory|models|core|uniffi)' "${shared_manifests[@]}"; then
	fail "a WASM-safe crate depends on a native crate"
fi

if rg --files crates apps web | rg -n '\.(py|pyc|tsx|jsx)$|(^|/)(package-lock\.json|jobs\.json)$'; then
	fail "retired implementation-stack artifact found"
fi

if rg -n -i '(fastapi|tauri|electron|localhost:[0-9]+)' \
	-g '*.rs' -g '*.swift' -g '*.toml' -g 'package.json' \
	Cargo.toml crates apps web; then
	fail "retired implementation-stack marker found"
fi

cargo fmt --all -- --check
cargo check --workspace --all-targets --locked
cargo test --workspace --locked
cargo check --target wasm32-unknown-unknown \
	--locked \
	-p open-scribe-types \
	-p open-scribe-domain \
	-p open-scribe-evidence

shellcheck script/*.sh
shfmt -d script/*.sh
git diff --check

while IFS= read -r -d '' untracked_path; do
	check_output="$(
		git diff --no-index --check -- /dev/null "$untracked_path" 2>&1 ||
			true
	)"
	[[ -z "$check_output" ]] ||
		fail "untracked whitespace error in $untracked_path: $check_output"
done < <(git ls-files --others --exclude-standard -z)

printf '%s\n' \
	"SCAFFOLD_GREEN" \
	"proof=mirror,budgets,prd_hash,cargo_metadata,native_check,native_test,wasm_check,shell_lint,tracked_and_untracked_diff_hygiene" \
	"excludes=swift_app,uniffi,website,capture,recovery,ml,deploy,signing,release"
