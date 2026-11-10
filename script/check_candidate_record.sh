#!/usr/bin/env bash
set -euo pipefail

# Exercise admission failures using inert files in a disposable Git repository.
# The identity fixture compiles a tiny pause loop so its executable name can
# be OpenScribeApp. No application, capture device, or pre-existing candidate
# is touched.
script_dir="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
fixture="$(mktemp -d "${TMPDIR:-/tmp}/open-scribe-candidate-test.XXXXXX")"
fixture="$(CDPATH='' cd -- "$fixture" && pwd -P)"
decoy_pid=""
trap '[[ -z "$decoy_pid" ]] || kill "$decoy_pid" 2>/dev/null || true; rm -rf "$fixture"' EXIT
repo_root="$fixture"
cd "$fixture"
git init -q
printf '/candidate/\n/log\n/script/\n' >.gitignore
mkdir script
cp "$script_dir/candidate.sh" "$script_dir/check_m1_complete.sh" "$script_dir/check_m2_complete.sh" \
	"$script_dir/check_m4_complete.sh" script/
printf 'committed input\n' >source.txt
git add .gitignore source.txt
git -c user.name='Candidate fixture' -c user.email='fixture@example.invalid' \
	-c commit.gpgsign=false -c core.hooksPath=/dev/null commit -qm fixture
# shellcheck source=script/candidate.sh
source "$script_dir/candidate.sh"
candidate_record="$fixture/candidate/candidate.json"
mkdir -p "$(dirname "$candidate_record")"
candidate_paths
candidate_source
artifacts='{}'
write_artifact() {
	local key="$1" path="$2"
	if [[ "$key" == info_plist ]]; then
		printf '%s\n' '<?xml version="1.0" encoding="UTF-8"?>' \
			'<plist version="1.0"><dict><key>CFBundleIdentifier</key><string>app.open-scribe.dev.verification</string></dict></plist>' >"$path"
	else
		printf '%s\n' "$key" >"$path"
	fi
}
for key in executable debug_dylib info_plist rust_library test_binary xctestrun build_log; do
	case "$key" in
	executable) path="$app_binary" ;;
	debug_dylib) path="$app_bundle/Contents/MacOS/OpenScribeApp.debug.dylib" ;;
	info_plist) path="$app_bundle/Contents/Info.plist" ;;
	rust_library) path="$rust_library" ;;
	test_binary) path="$app_bundle/Contents/PlugIns/OpenScribeAppTests.xctest/Contents/MacOS/OpenScribeAppTests" ;;
	xctestrun) path="$derived_data/Build/Products/fixture.xctestrun" ;;
	build_log) path="$candidate_root/build.log" ;;
	esac
	mkdir -p "$(dirname "$path")"
	write_artifact "$key" "$path"
	artifacts="$(jq --arg key "$key" --arg path "$path" --arg digest "$(candidate_sha256 "$path")" \
		'. + {($key): {path: $path, sha256: $digest}}' <<<"$artifacts")"
done
jq -n --arg repo "$repo_root" --arg sha "$candidate_sha" --arg tree "$candidate_tree" \
	--argjson artifacts "$artifacts" \
	'{schema: 1, repository: $repo, sha: $sha, tree: $tree, artifacts: $artifacts}' >"$candidate_record"
candidate_load "$candidate_record"
decoy="$fixture/candidate/OpenScribeApp"
clang -x c -o "$decoy" - <<'EOF'
#include <unistd.h>
int main(void) {
  for (;;) pause();
}
EOF
"$decoy" &
decoy_pid=$!
seen=0
for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
	if candidate_executable_running "$decoy"; then
		seen=1
		break
	fi
	sleep 0.05
done
[[ "$seen" == 1 ]] || {
	printf 'CANDIDATE_TEST_RED: exact executable was not observed\n' >&2
	exit 1
}
if candidate_executable_running "$app_binary"; then
	printf 'CANDIDATE_TEST_RED: a different OpenScribeApp counted as the candidate\n' >&2
	exit 1
fi
kill "$decoy_pid"
wait "$decoy_pid" 2>/dev/null || true
decoy_pid=""
printf '%s\n' 'rejected=installed-app-name-is-not-candidate-identity'
record_contents="$(cat "$candidate_record")"
expect_rejection() {
	local label="$1"
	shift
	if ("$@") >"$fixture/log" 2>&1; then
		printf 'CANDIDATE_TEST_RED: accepted %s\n' "$label" >&2
		exit 1
	fi
	rg -q 'CANDIDATE_RED:' "$fixture/log"
	printf 'rejected=%s\n' "$label"
}
for key in executable debug_dylib info_plist rust_library test_binary xctestrun build_log; do
	path="$(jq -r --arg key "$key" '.artifacts[$key].path' "$candidate_record")"
	printf 'changed\n' >>"$path"
	expect_rejection "$key-drift" candidate_load "$candidate_record"
	write_artifact "$key" "$path"
done
/usr/libexec/PlistBuddy -c 'Set :CFBundleIdentifier app.open-scribe.dev' "$app_bundle/Contents/Info.plist"
jq --arg digest "$(candidate_sha256 "$app_bundle/Contents/Info.plist")" \
	'.artifacts.info_plist.sha256 = $digest' <<<"$record_contents" >"$candidate_record"
expect_rejection production-preferences-domain candidate_load "$candidate_record"
write_artifact info_plist "$app_bundle/Contents/Info.plist"
printf '%s\n' "$record_contents" >"$candidate_record"
candidate_load "$candidate_record"
expect_rejection missing-checks candidate_require_checks
printf 'source checks\n' >"$candidate_root/source-checks.log"
printf 'native checks\n' >"$candidate_root/native-checks.log"
jq -n --arg candidate "$candidate_record_digest" \
	--arg source "$(candidate_sha256 "$candidate_root/source-checks.log")" \
	--arg native "$(candidate_sha256 "$candidate_root/native-checks.log")" \
	'{schema: 1, candidate_sha256: $candidate, result: "CONTRIBUTOR_CHECKS_GREEN", logs: {source: $source, native: $native}}' \
	>"$candidate_root/checks.json"
candidate_require_checks
# Completion consumes exact candidate case receipts, not marker text alone.
check_completion() {
	local result=0
	bash "$fixture/script/check_m1_complete.sh" --candidate "$candidate_record" >"$fixture/log" 2>&1 || result=$?
	[[ "$result" == 1 ]] && rg -Fxq 'M1_COMPLETE_HOLD' "$fixture/log"
}
check_completion
rg -Fxq 'qualified_cases=' "$fixture/log"
case_root="$candidate_root/m1-storage-warning.fixture"
mkdir "$case_root"
case_log="$case_root/harness.log"
case_receipt="$candidate_root/m1-injected-storage-warning.json"
printf 'M1_INJECTED_STORAGE_WARNING_GREEN\ncandidate_record_sha256=%s\n' "$candidate_record_digest" >"$case_log"
jq -n --arg candidate "$candidate_record_digest" --arg root "$case_root" --arg digest "$(candidate_sha256 "$case_log")" \
	'{schema: 1, candidate_sha256: $candidate, scenario: "storage-warning", proof_root: $root,
	 log_sha256: $digest, result: "M1_INJECTED_CASE_GREEN"}' >"$case_receipt"
case_contents="$(cat "$case_receipt")"
check_completion
rg -Fxq 'qualified_cases=storage-warning' "$fixture/log"
rg -Fxq 'missing_implementation_proof=disk_pressure_policy' "$fixture/log"
jq '.candidate_sha256 = "another-build"' <<<"$case_contents" >"$case_receipt"
check_completion
rg -Fxq 'qualified_cases=' "$fixture/log"
printf '%s\n' "$case_contents" >"$case_receipt"
printf 'changed\n' >>"$case_log"
check_completion
rg -Fxq 'qualified_cases=' "$fixture/log"
printf 'candidate_record_sha256=%s\n' "$candidate_record_digest" >"$case_log"
jq --arg digest "$(candidate_sha256 "$case_log")" '.log_sha256 = $digest' <<<"$case_contents" >"$case_receipt"
check_completion
rg -Fxq 'qualified_cases=' "$fixture/log"
printf '%s\n' "$case_contents" >"$case_receipt"
mv "$case_receipt" "$case_receipt.saved"
ln -s "$case_receipt.saved" "$case_receipt"
check_completion
rg -Fxq 'qualified_cases=' "$fixture/log"
printf '%s\n' 'M1_COMPLETE_RECEIPT_TEST_GREEN cases=6'
# Exercise the production M4 consumer with inert reports, not a substitute app.
# A valid bounded receipt removes only the local-only missing prerequisite.
check_local_completion() {
	local expected="$1" result=0
	bash "$fixture/script/check_m4_complete.sh" --candidate "$candidate_record" >"$fixture/log" 2>&1 || result=$?
	[[ "$result" == 1 ]] && rg -Fxq 'M4_COMPLETE_HOLD' "$fixture/log"
	rg -Fxq "qualified_local_only_modes=$expected" "$fixture/log"
	rg -q 'missing=.*provider_category_authorization' "$fixture/log"
	if [[ -z "$expected" ]]; then
		rg -q 'missing=candidate_bound_local_only_run,' "$fixture/log"
	else
		if rg -q 'missing=candidate_bound_local_only_run,' "$fixture/log"; then return 1; fi
	fi
}
check_local_completion ''
local_root="$candidate_root/m4-local-only-synthetic.fixture"
mkdir "$local_root"
for surface in stdout stderr unified; do printf 'inert diagnostic\n' >"$local_root/$surface.log"; done
local_report="$local_root/local-only-verified.json"
speech_digest="$(candidate_sha256 "$local_root/stdout.log")"
jq -n --arg speech "$speech_digest" '{
  recovered_segments:4, rendered_frames:1548000, validated_mix_bytes:1,
  transcript_segments:1, correction_search_hits:1, package_files:7,
  restored_package_media_files:4, restored_timeline_segments:4,
  deleted_sessions:1, declared_participants:1, speech_input_sha256:$speech,
  speech_known_answer:true,
  original_speech_untouched:true, model_scope:"isolated_proof_library",
  context_input:"omitted", screen_capture_performed:false,
  screen_recording_permission:"not_requested", context_events_accepted:0,
  saved_context_events:0, context_frame_pixels:0
}' >"$local_report"
local_receipt="$candidate_root/m4-local-only-synthetic.json"
jq -n --arg candidate "$candidate_record_digest" --arg root "$local_root" \
	--arg report "$(candidate_sha256 "$local_report")" --arg input "$speech_digest" \
	'{schema:1, candidate_sha256:$candidate, result:"M4_LOCAL_ONLY_GREEN", mode:"synthetic",
      proof_root:$root, report_sha256:$report, inputs:{model_sha256:$input,speech_sha256:$input},
      logs:{stdout:$input,stderr:$input,unified:$input},
      qualification_scope:"development_candidate_only",release_admission:false}' >"$local_receipt"
local_contents="$(cat "$local_receipt")"
report_contents="$(cat "$local_report")"
check_local_completion synthetic
jq '.candidate_sha256 = "another-build"' <<<"$local_contents" >"$local_receipt"
check_local_completion ''
printf '%s\n' "$local_contents" >"$local_receipt"
printf 'altered diagnostic\n' >>"$local_root/unified.log"
check_local_completion ''
printf 'inert diagnostic\n' >"$local_root/unified.log"
printf ' ' >>"$local_report"
check_local_completion ''
printf '%s\n' "$report_contents" >"$local_report"
jq '.inputs.speech_sha256 = ("0" * 64)' <<<"$local_contents" >"$local_receipt"
check_local_completion ''
jq '.screen_capture_performed = true' <<<"$report_contents" >"$local_report"
jq --arg digest "$(candidate_sha256 "$local_report")" '.report_sha256 = $digest' \
	<<<"$local_contents" >"$local_receipt"
check_local_completion ''
jq '.transcript_segments = "not a count"' <<<"$report_contents" >"$local_report"
jq --arg digest "$(candidate_sha256 "$local_report")" '.report_sha256 = $digest' \
	<<<"$local_contents" >"$local_receipt"
check_local_completion ''
jq '.speech_known_answer = false' <<<"$report_contents" >"$local_report"
jq --arg digest "$(candidate_sha256 "$local_report")" '.report_sha256 = $digest' \
	<<<"$local_contents" >"$local_receipt"
check_local_completion ''
printf '%s\n' "$report_contents" >"$local_report"
printf '%s\n' "$local_contents" >"$local_receipt"
mv "$local_report" "$local_report.saved"
ln -s "$local_report.saved" "$local_report"
check_local_completion ''
rm "$local_report"
mv "$local_report.saved" "$local_report"
mv "$local_receipt" "$local_receipt.saved"
ln -s "$local_receipt.saved" "$local_receipt"
check_local_completion ''
printf '%s\n' 'M4_COMPLETE_RECEIPT_TEST_GREEN cases=11'
# M2 admits a name only from a receipt bound to this candidate. The five
# behavior receipts alone stay HOLD while any unqualified source is unbound.
m2_missing_all='live_draft_transcript,speaker_diarization,in_app_model_download_and_removal,compressed_import_package_restore,two_hour_package_round_trip'
m2_source_all='local_whisper_final_transcription,speaker_correction,search,transcript_audio_synchronization_for_capture_timelines,imported_audio_seek,compressed_m4a_transcription_via_decoded_companion,transcript_text_exports,audio_exports,session_manifest,portable_package_writer_and_verifier,portable_package_import_round_trip_for_pcm_sessions'
m2_behaviors=(
	live_draft_transcript
	speaker_diarization
	in_app_model_download_and_removal
	compressed_import_package_restore
	two_hour_package_round_trip
)
m2_sources=(
	local_whisper_final_transcription
	speaker_correction
	search
	transcript_audio_synchronization_for_capture_timelines
	imported_audio_seek
	compressed_m4a_transcription_via_decoded_companion
	transcript_text_exports
	audio_exports
	session_manifest
	portable_package_writer_and_verifier
	portable_package_import_round_trip_for_pcm_sessions
)
m2_marker() {
	printf 'M2_%s_GREEN' "$(printf '%s' "$1" | tr '[:lower:]' '[:upper:]')"
}
write_m2_behavior() {
	local name="$1" root="$candidate_root/m2-$1.fixture" log receipt
	log="$root/harness.log"
	receipt="$candidate_root/m2-$name.json"
	mkdir -p "$root"
	printf '%s\ncandidate_record_sha256=%s\n' "$(m2_marker "$name")" "$candidate_record_digest" >"$log"
	jq -n --arg candidate "$candidate_record_digest" --arg name "$name" --arg root "$root" \
		--arg digest "$(candidate_sha256 "$log")" \
		'{schema:1, candidate_sha256:$candidate, behavior:$name, proof_root:$root,
		  log_sha256:$digest, result:"M2_BEHAVIOR_GREEN", release_admission:false}' >"$receipt"
}
expect_m2() {
	local status="$1" marker="$2" missing="$3" unqualified="$4" behaviors="$5" source="$6" result=0
	if [[ "$status" == no-candidate ]]; then
		bash "$fixture/script/check_m2_complete.sh" >"$fixture/log" 2>&1 || result=$?
		[[ "$result" == 1 ]]
	elif [[ "$status" == hold ]]; then
		bash "$fixture/script/check_m2_complete.sh" --candidate "$candidate_record" >"$fixture/log" 2>&1 || result=$?
		[[ "$result" == 1 ]]
	else
		bash "$fixture/script/check_m2_complete.sh" --candidate "$candidate_record" >"$fixture/log" 2>&1 || result=$?
		[[ "$result" == 0 ]]
	fi
	rg -Fxq "$marker" "$fixture/log"
	rg -Fxq "missing=$missing" "$fixture/log"
	rg -Fxq "unqualified_source=$unqualified" "$fixture/log"
	rg -Fxq "qualified_behaviors=$behaviors" "$fixture/log"
	rg -Fxq "qualified_source=$source" "$fixture/log"
	rg -Fxq 'release_admission=false' "$fixture/log"
}
expect_m2 no-candidate 'M2_COMPLETE_HOLD' "$m2_missing_all" "$m2_source_all" '' ''
expect_m2 hold 'M2_COMPLETE_HOLD' "$m2_missing_all" "$m2_source_all" '' ''
write_m2_behavior live_draft_transcript
live_receipt="$(cat "$candidate_root/m2-live_draft_transcript.json")"
live_log="$(cat "$candidate_root/m2-live_draft_transcript.fixture/harness.log")"
live_root="$candidate_root/m2-live_draft_transcript.fixture"
expect_m2 hold 'M2_COMPLETE_HOLD' \
	'speaker_diarization,in_app_model_download_and_removal,compressed_import_package_restore,two_hour_package_round_trip' \
	"$m2_source_all" live_draft_transcript ''
jq '.candidate_sha256 = "another-build"' <<<"$live_receipt" >"$candidate_root/m2-live_draft_transcript.json"
expect_m2 hold 'M2_COMPLETE_HOLD' "$m2_missing_all" "$m2_source_all" '' ''
printf '%s\n' "$live_receipt" >"$candidate_root/m2-live_draft_transcript.json"
printf 'changed\n' >>"$live_root/harness.log"
expect_m2 hold 'M2_COMPLETE_HOLD' "$m2_missing_all" "$m2_source_all" '' ''
printf 'candidate_record_sha256=%s\n' "$candidate_record_digest" >"$live_root/harness.log"
jq --arg digest "$(candidate_sha256 "$live_root/harness.log")" '.log_sha256 = $digest' \
	<<<"$live_receipt" >"$candidate_root/m2-live_draft_transcript.json"
expect_m2 hold 'M2_COMPLETE_HOLD' "$m2_missing_all" "$m2_source_all" '' ''
printf '%s\n' "$live_log" >"$live_root/harness.log"
printf '%s\n' "$live_receipt" >"$candidate_root/m2-live_draft_transcript.json"
mv "$candidate_root/m2-live_draft_transcript.json" "$candidate_root/m2-live_draft_transcript.json.saved"
ln -s "$candidate_root/m2-live_draft_transcript.json.saved" "$candidate_root/m2-live_draft_transcript.json"
expect_m2 hold 'M2_COMPLETE_HOLD' "$m2_missing_all" "$m2_source_all" '' ''
rm "$candidate_root/m2-live_draft_transcript.json"
mv "$candidate_root/m2-live_draft_transcript.json.saved" "$candidate_root/m2-live_draft_transcript.json"
jq '.release_admission = true' <<<"$live_receipt" >"$candidate_root/m2-live_draft_transcript.json"
expect_m2 hold 'M2_COMPLETE_HOLD' "$m2_missing_all" "$m2_source_all" '' ''
jq '.result = "M2_COMPLETE_GREEN"' <<<"$live_receipt" >"$candidate_root/m2-live_draft_transcript.json"
expect_m2 hold 'M2_COMPLETE_HOLD' "$m2_missing_all" "$m2_source_all" '' ''
printf '%s\n' "$live_receipt" >"$candidate_root/m2-live_draft_transcript.json"
mv "$live_root" "$live_root.saved"
ln -s "$live_root.saved" "$live_root"
expect_m2 hold 'M2_COMPLETE_HOLD' "$m2_missing_all" "$m2_source_all" '' ''
rm "$live_root"
mv "$live_root.saved" "$live_root"
expect_m2 hold 'M2_COMPLETE_HOLD' \
	'speaker_diarization,in_app_model_download_and_removal,compressed_import_package_restore,two_hour_package_round_trip' \
	"$m2_source_all" live_draft_transcript ''
for name in "${m2_behaviors[@]}"; do
	[[ "$name" == live_draft_transcript ]] || write_m2_behavior "$name"
done
expect_m2 hold 'M2_COMPLETE_HOLD' '' "$m2_source_all" "$m2_missing_all" ''
for name in "${m2_sources[@]}"; do
	write_m2_behavior "$name"
done
expect_m2 green 'M2_COMPLETE_GREEN' '' '' "$m2_missing_all" "$m2_source_all"
if rg -Fxq 'M2_COMPLETE_HOLD' "$fixture/log"; then
	printf 'CANDIDATE_TEST_RED: hold survived a complete M2 receipt set\n' >&2
	exit 1
fi
printf 'altered diagnostic\n' >>"$candidate_root/m2-search.fixture/harness.log"
expect_m2 hold 'M2_COMPLETE_HOLD' '' search "$m2_missing_all" \
	'local_whisper_final_transcription,speaker_correction,transcript_audio_synchronization_for_capture_timelines,imported_audio_seek,compressed_m4a_transcription_via_decoded_companion,transcript_text_exports,audio_exports,session_manifest,portable_package_writer_and_verifier,portable_package_import_round_trip_for_pcm_sessions'
rm "$candidate_root/m2-two_hour_package_round_trip.json"
expect_m2 hold 'M2_COMPLETE_HOLD' two_hour_package_round_trip search \
	'live_draft_transcript,speaker_diarization,in_app_model_download_and_removal,compressed_import_package_restore' \
	'local_whisper_final_transcription,speaker_correction,transcript_audio_synchronization_for_capture_timelines,imported_audio_seek,compressed_m4a_transcription_via_decoded_companion,transcript_text_exports,audio_exports,session_manifest,portable_package_writer_and_verifier,portable_package_import_round_trip_for_pcm_sessions'
printf '%s\n' 'M2_COMPLETE_RECEIPT_TEST_GREEN cases=14'
checks_contents="$(cat "$candidate_root/checks.json")"
jq '.candidate_sha256 = "another-build"' <<<"$checks_contents" >"$candidate_root/checks.json"
expect_rejection checks-from-another-build candidate_require_checks
printf '%s\n' "$checks_contents" >"$candidate_root/checks.json"
printf 'changed\n' >>"$candidate_root/native-checks.log"
expect_rejection check-log-drift candidate_require_checks
printf 'changed source\n' >>source.txt
expect_rejection dirty-source candidate_load "$candidate_record"
git add source.txt
expect_rejection staged-source candidate_load "$candidate_record"
git -c user.name='Candidate fixture' -c user.email='fixture@example.invalid' \
	-c commit.gpgsign=false -c core.hooksPath=/dev/null commit -qm successor
expect_rejection different-commit candidate_load "$candidate_record"
printf '{invalid\n' >"$candidate_record"
expect_rejection malformed-record candidate_load "$candidate_record"
printf '%s\n' "$record_contents" >"$candidate_record"
printf '%s\n' 'CANDIDATE_RECORD_TEST_GREEN'
