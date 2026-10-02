#!/usr/bin/env bash
set -euo pipefail

script_dir="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
repo_root="$(CDPATH='' cd -- "$script_dir/.." && pwd -P)"
cd "$repo_root"
# shellcheck source=script/candidate.sh
source "$script_dir/candidate.sh"
[[ "$#" == 1 && "$1" == /* ]] || candidate_fail 'usage: build_candidate.sh /absolute/new-directory/candidate.json'
candidate_record="$1"
[[ ! -e "$candidate_record" ]] || candidate_fail 'candidate record already exists; do not overwrite proof'
candidate_source
source_sha="$candidate_sha"
source_tree="$candidate_tree"
mkdir -p "$(dirname "$candidate_record")"
candidate_paths
[[ ! -e "$derived_data" && ! -e "$rust_target_dir" ]] || candidate_fail 'candidate build directories must be new'
if pgrep -x OpenScribeApp >/dev/null; then
	candidate_fail 'close the development app before building a candidate'
fi

build_native() {
	# Fresh candidate targets cannot reuse compiler incremental sessions.
	# Preserve final artifacts and proof; avoid retaining disposable session caches.
	export CARGO_INCREMENTAL=0
	"$script_dir/check_apple_toolchain.sh"
	rust_library="$(bash "$script_dir/build_rust_macos.sh" "$rust_target_dir")"
	CARGO_TARGET_DIR="$rust_target_dir" cargo run --locked -p open-scribe-uniffi \
		--features bindgen --bin uniffi-bindgen -- generate \
		--library "$rust_library" --language swift --out-dir "$candidate_root/bindings"
	xcrun swift-format format --in-place "$candidate_root/bindings/OpenScribeCore.swift"
	xcrun clang-format -i "$candidate_root/bindings/OpenScribeFFI.h"
	cmp "$candidate_root/bindings/OpenScribeCore.swift" apps/macos/Sources/OpenScribeApp/Generated/OpenScribeCore.swift
	cmp "$candidate_root/bindings/OpenScribeFFI.h" apps/macos/Sources/OpenScribeFFI/include/OpenScribeFFI.h
	ruby "$script_dir/check_macos_build_configuration.rb" "$rust_target_dir"
	xcodebuild -project apps/macos/OpenScribe.xcodeproj -scheme OpenScribeApp \
		-configuration Debug -derivedDataPath "$derived_data" \
		ARCHS=arm64 ONLY_ACTIVE_ARCH=YES LIBRARY_SEARCH_PATHS="$(dirname "$rust_library")" \
		MACOSX_DEPLOYMENT_TARGET=13.0 CODE_SIGNING_ALLOWED=NO build-for-testing
}
build_native 2>&1 | tee "$candidate_root/build.log"
if rg -n '/Sources/.*warning:|built for newer .macOS. version|object file.*newer.*macOS' "$candidate_root/build.log"; then
	candidate_fail 'project Swift warning or newer-macOS linker warning'
fi
# The Debug executable is a stub; audit the implementation in the same pass.
bash "$script_dir/check_macos_artifact_floor.sh" "$rust_library" "$app_binary" \
	"$app_bundle/Contents/MacOS/OpenScribeApp.debug.dylib"
candidate_source
[[ "$candidate_sha" == "$source_sha" && "$candidate_tree" == "$source_tree" ]] || candidate_fail 'source changed during build'
shopt -s nullglob
test_runs=("$derived_data"/Build/Products/*.xctestrun)
[[ "${#test_runs[@]}" == 1 ]] || candidate_fail 'expected exactly one built Xcode test run'
artifacts="$({
	for key in executable debug_dylib info_plist rust_library test_binary xctestrun build_log; do
		case "$key" in
		executable) path="$app_binary" ;;
		debug_dylib) path="$app_bundle/Contents/MacOS/OpenScribeApp.debug.dylib" ;;
		info_plist) path="$app_bundle/Contents/Info.plist" ;;
		rust_library) path="$rust_library" ;;
		test_binary) path="$app_bundle/Contents/PlugIns/OpenScribeAppTests.xctest/Contents/MacOS/OpenScribeAppTests" ;;
		xctestrun) path="${test_runs[0]}" ;;
		build_log) path="$candidate_root/build.log" ;;
		esac
		[[ -f "$path" && ! -L "$path" ]] || candidate_fail "missing built artifact: $key"
		jq -n --arg key "$key" --arg path "$path" --arg sha256 "$(candidate_sha256 "$path")" \
			'{key: $key, value: {path: $path, sha256: $sha256}}'
	done
} | jq -s 'from_entries')"
(
	set -o noclobber
	jq -n --arg repo "$repo_root" --arg sha "$candidate_sha" --arg tree "$candidate_tree" \
		--argjson artifacts "$artifacts" \
		'{schema: 1, repository: $repo, sha: $sha, tree: $tree, artifacts: $artifacts}' >"$candidate_record"
)
candidate_load "$candidate_record"
candidate_receipt
printf '%s\n' 'CANDIDATE_BUILD_GREEN' \
	'proof=committed_source,fresh_rust_staticlib,fresh_bindings,single_xcode_build_for_testing,no_project_swift_warnings,macos13_floor,artifact_digests' \
	'excludes=tests,runtime,capture,permissions,signing,release'
