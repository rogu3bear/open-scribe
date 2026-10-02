#!/usr/bin/env bash
set -euo pipefail

# Inert admission/storage fixtures; never launches or builds the app.
script_dir="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
fixture="$(mktemp -d "${TMPDIR:-/tmp}/open-scribe-operator-test.XXXXXX")"
fixture="$(CDPATH='' cd -- "$fixture" && pwd -P)"
trap 'rm -rf "$fixture"' EXIT
repo_root="$fixture"
cd "$fixture"
git init -q
printf '/candidate/\n/library/\n/evidence/\n/notes.json\n/log\n/script/\n' >.gitignore
mkdir script evidence
cp "$script_dir/candidate.sh" "$script_dir/m1_operator_snapshot.rb" script/
printf 'committed fixture\n' >source.txt
git add .gitignore source.txt
git -c user.name='Operator fixture' -c user.email='fixture@example.invalid' \
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
printf 'source checks\n' >"$candidate_root/source-checks.log"
printf 'native checks\n' >"$candidate_root/native-checks.log"
jq -n --arg candidate "$(candidate_sha256 "$candidate_record")" \
	--arg source "$(candidate_sha256 "$candidate_root/source-checks.log")" \
	--arg native "$(candidate_sha256 "$candidate_root/native-checks.log")" \
	'{schema: 1, candidate_sha256: $candidate, result: "CONTRIBUTOR_CHECKS_GREEN", logs: {source: $source, native: $native}}' >"$candidate_root/checks.json"
mkdir -p library/Sessions/fixture/audio/track
media="$fixture/library/Sessions/fixture/audio/track/000000-0.caf"
printf 'inert sealed bytes\n' >"$media"
printf '{"fixture":"not production capture"}\n' >library/Sessions/fixture/recovery.jsonl
for table in sessions required_sources sources tracks session_events markers imports recovery_runs; do
	sqlite3 library/Library.sqlite3 "CREATE TABLE $table (id TEXT PRIMARY KEY);"
done
sqlite3 library/Library.sqlite3 'CREATE TABLE segments (session_id TEXT, relative_path TEXT, seal_state TEXT, digest TEXT, byte_length INTEGER);'
sqlite3 library/Library.sqlite3 "INSERT INTO segments VALUES ('fixture','audio/track/000000-0.caf','sealed','$(candidate_sha256 "$media")',$(stat -f %z "$media"));"
jq -n '{observer: "Fixture", observation_source: "operator", action: "Inert test", visible_state: "No app launched", recovery_outcome: "Not exercised"}' >notes.json
snapshot() {
	ruby script/m1_operator_snapshot.rb --candidate "$candidate_record" --library "$fixture/library" \
		--step fixture --phase after --notes "$fixture/notes.json" --output "$fixture/evidence/$1"
}
snapshot valid
jq -e '.result == "OPERATOR_OBSERVATION" and .human_acceptance == false and (.journals | length) == 1 and (.evidence_errors | length) == 0 and .media[0].matches_rust_receipt == true' \
	evidence/valid/observation.json >/dev/null
cmp library/Sessions/fixture/recovery.jsonl evidence/valid/journal-0.jsonl
original="$(candidate_sha256 evidence/valid/observation.json)"
if snapshot valid >log 2>&1; then exit 1; fi
[[ "$(candidate_sha256 evidence/valid/observation.json)" == "$original" ]]
printf 'changed source\n' >>source.txt
if snapshot dirty >log 2>&1; then exit 1; fi
[[ ! -e evidence/dirty ]]
rg -q 'committed source and a clean working tree are required' log
printf 'committed fixture\n' >source.txt
printf 'changed app\n' >>"$app_binary"
if snapshot foreign >log 2>&1; then exit 1; fi
[[ ! -e evidence/foreign ]]
rg -q 'artifact digest differs: executable' log
printf 'executable\n' >"$app_binary"
printf 'changed sealed media\n' >>"$media"
if snapshot drift >log 2>&1; then exit 1; fi
jq -e '(.evidence_errors | length) == 1 and .media[0].matches_rust_receipt == false and .human_acceptance == false' evidence/drift/observation.json >/dev/null
rm "$media"
if snapshot missing >log 2>&1; then exit 1; fi
jq -e '(.evidence_errors | length) == 1 and (.media | length) == 0 and .human_acceptance == false' evidence/missing/observation.json >/dev/null
printf '%s\n' 'M1_OPERATOR_SNAPSHOT_TEST_GREEN cases=6' \
	'proof=inert_snapshot,canonical_journal_retained,existing_evidence_preserved,dirty_source_and_changed_app_rejected_before_write,sealed_media_drift_and_loss_retained_as_failure' \
	'excludes=app_build,app_runtime,visible_state,human_matrix,two_hour_drift,m1_completion'
