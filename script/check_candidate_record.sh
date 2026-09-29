#!/usr/bin/env bash
set -euo pipefail

# Exercise admission failures using inert files in a disposable Git repository.
# No compiler, application, capture device, or pre-existing candidate is touched.
script_dir="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
fixture="$(mktemp -d "${TMPDIR:-/tmp}/open-scribe-candidate-test.XXXXXX")"
fixture="$(CDPATH='' cd -- "$fixture" && pwd -P)"
trap 'rm -rf "$fixture"' EXIT
repo_root="$fixture"
cd "$fixture"
git init -q
printf '/candidate/\n/log\n/script/\n' >.gitignore
mkdir script
cp "$script_dir/candidate.sh" "$script_dir/check_m1_complete.sh" script/
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
	printf '%s\n' "$key" >"$path"
	artifacts="$(jq --arg key "$key" --arg path "$path" --arg digest "$(candidate_sha256 "$path")" \
		'. + {($key): {path: $path, sha256: $digest}}' <<<"$artifacts")"
done
jq -n --arg repo "$repo_root" --arg sha "$candidate_sha" --arg tree "$candidate_tree" \
	--argjson artifacts "$artifacts" \
	'{schema: 1, repository: $repo, sha: $sha, tree: $tree, artifacts: $artifacts}' >"$candidate_record"
candidate_load "$candidate_record"
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
	printf '%s\n' "$key" >"$path"
done
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
