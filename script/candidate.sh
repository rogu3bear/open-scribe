#!/usr/bin/env bash
# Shared local build identity. This file is sourced; records are JSON, never
# executable shell input. A record proves a build, not permission or release.
repo_root="${repo_root:?source candidate.sh from a bound repository}"

candidate_fail() {
	printf 'CANDIDATE_RED: %s\n' "$1" >&2
	exit 1
}

candidate_sha256() {
	shasum -a 256 "$1" | cut -d ' ' -f 1
}

candidate_source() {
	[[ -z "$(git status --porcelain=v1 --untracked-files=all)" ]] ||
		candidate_fail 'committed source and a clean working tree are required'
	candidate_sha="$(git rev-parse HEAD)"
	candidate_tree="$(git rev-parse 'HEAD^{tree}')"
}

candidate_paths() {
	candidate_root="$(CDPATH='' cd -- "$(dirname -- "$candidate_record")" && pwd -P)"
	derived_data="$candidate_root/xcode"
	app_bundle="$derived_data/Build/Products/Debug/OpenScribeApp.app"
	app_binary="$app_bundle/Contents/MacOS/OpenScribeApp"
	rust_target_dir="$candidate_root/rust"
	rust_library="$rust_target_dir/aarch64-apple-darwin/debug/libopen_scribe_uniffi.a"
}

candidate_assert() {
	[[ "$(candidate_sha256 "$candidate_record")" == "$candidate_record_digest" ]] ||
		candidate_fail 'candidate record changed during proof'
	candidate_source
	jq -e --arg repo "$repo_root" --arg sha "$candidate_sha" --arg tree "$candidate_tree" \
		'.schema == 1 and .repository == $repo and .sha == $sha and .tree == $tree
		and (.artifacts | type == "object") and (.artifacts | length == 7)
		and ([.artifacts[] | .path | type == "string"] | all)
		and ([.artifacts[] | .sha256 | test("^[a-f0-9]{64}$")] | all)' \
		"$candidate_record" >/dev/null || candidate_fail 'malformed record or source identity differs'
	local key path expected
	for key in executable debug_dylib info_plist rust_library test_binary xctestrun build_log; do
		path="$(jq -er --arg key "$key" '.artifacts[$key].path' "$candidate_record")" ||
			candidate_fail "missing artifact: $key"
		case "$key" in
		executable) expected="$app_binary" ;;
		debug_dylib) expected="$app_bundle/Contents/MacOS/OpenScribeApp.debug.dylib" ;;
		info_plist) expected="$app_bundle/Contents/Info.plist" ;;
		rust_library) expected="$rust_library" ;;
		test_binary) expected="$app_bundle/Contents/PlugIns/OpenScribeAppTests.xctest/Contents/MacOS/OpenScribeAppTests" ;;
		xctestrun) expected="$path" ;;
		build_log) expected="$candidate_root/build.log" ;;
		esac
		# Xcode includes its SDK in the test-run name; bind the exact observed
		# file while keeping it in this candidate's Products directory.
		if [[ "$key" == xctestrun ]]; then
			[[ "$(dirname "$path")" == "$derived_data/Build/Products" && "$path" == *.xctestrun ]] ||
				candidate_fail 'test run is outside candidate Products'
			expected="$path"
		fi
		[[ "$path" == "$expected" && -f "$path" && ! -L "$path" ]] ||
			candidate_fail "missing, redirected, or misplaced artifact: $key"
		[[ "$(candidate_sha256 "$path")" == "$(jq -r --arg key "$key" '.artifacts[$key].sha256' "$candidate_record")" ]] ||
			candidate_fail "artifact digest differs: $key"
	done
}

candidate_load() {
	candidate_record="${1:?candidate record required}"
	[[ "$candidate_record" == /* && -f "$candidate_record" && ! -L "$candidate_record" ]] ||
		candidate_fail 'supply an absolute path to a regular candidate JSON record'
	candidate_paths
	candidate_record_digest="$(candidate_sha256 "$candidate_record")"
	candidate_assert
	# Consumed by build_and_run.sh's test-without-building invocation.
	# shellcheck disable=SC2034
	xctestrun="$(jq -r '.artifacts.xctestrun.path' "$candidate_record")"
}

candidate_require_checks() {
	local checks="$candidate_root/checks.json" key path
	[[ -f "$checks" && ! -L "$checks" ]] || candidate_fail 'run the canonical contributor candidate gate first'
	jq -e --arg digest "$candidate_record_digest" \
		'.schema == 1 and .candidate_sha256 == $digest and .result == "CONTRIBUTOR_CHECKS_GREEN"' \
		"$checks" >/dev/null || candidate_fail 'contributor checks do not qualify this record'
	for key in source native; do
		path="$candidate_root/$key-checks.log"
		[[ -f "$path" && ! -L "$path" && "$(candidate_sha256 "$path")" == "$(jq -r --arg key "$key" '.logs[$key]' "$checks")" ]] ||
			candidate_fail "contributor check log differs: $key"
	done
}

candidate_receipt() {
	candidate_assert
	printf 'candidate_record=%s\ncandidate_record_sha256=%s\ncommit=%s\ntree=%s\n' \
		"$candidate_record" "$candidate_record_digest" "$candidate_sha" "$candidate_tree"
	jq -r '.artifacts | to_entries[] | "artifact_sha256=\(.value.sha256) \(.key)"' "$candidate_record"
}
