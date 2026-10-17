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
	[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app_bundle/Contents/Info.plist")" == app.open-scribe.dev.verification ]] ||
		candidate_fail 'verification requires an isolated application preferences domain'
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

# One report contract for the producer and completion consumer. It proves a
# bounded development workflow, never authenticated release admission.
candidate_local_only_report_valid() {
	local report="$1" mode="$2" speech_digest="$3"
	jq -e --arg mode "$mode" --arg speech "$speech_digest" '
      ([.validated_mix_bytes,.transcript_segments,.context_frame_pixels]
        | all(type == "number" and . >= 0 and floor == .))
      and .recovered_segments == 4 and .rendered_frames == 1548000 and .validated_mix_bytes > 0
      and .transcript_segments >= 1 and .correction_search_hits == 1 and .package_files == 7
      and .restored_package_media_files == 4 and .restored_timeline_segments == 4
      and .deleted_sessions == 1 and .declared_participants == 1
      and .speech_input_sha256 == $speech and .original_speech_untouched == true
      and .speech_known_answer == true
      and .model_scope == "isolated_proof_library"
      and (if $mode == "synthetic" then
        .context_input == "omitted" and .screen_capture_performed == false
        and .screen_recording_permission == "not_requested"
        and .context_events_accepted == 0 and .saved_context_events == 0
        and .context_frame_pixels == 0
      elif $mode == "live-context" then
        .context_input == "liveIfAuthorized" and .screen_capture_performed == true
        and .screen_recording_permission == "granted"
        and .context_events_accepted == 1 and .saved_context_events == 1
        and .context_frame_pixels > 0
      else false end)' "$report" >/dev/null
}
