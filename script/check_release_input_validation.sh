#!/usr/bin/env bash
set -euo pipefail

script_dir="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
repo_root="$(CDPATH='' cd -- "$script_dir/.." && pwd)"
fixture_root="$(mktemp -d "${TMPDIR:-/tmp}/open-scribe-release-inputs.XXXXXX")"
trap 'rm -rf "$fixture_root"' EXIT

fail() {
	printf 'RELEASE_INPUT_CHECK_RED: %s\n' "$1" >&2
	exit 1
}

write_fixture() {
	local name="$1"
	local body="$2"
	printf '%s\n' "$body" >"$fixture_root/$name.json"
}

jq \
	'.status = "closed"
     | .candidate = {
         version: "0.1.0",
         source_sha: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
         source_tree: "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
       }
     | .entries |= map(
         .state = "Passed"
         | .receipt = {
             id: ("receipt-" + .id),
             result: "Passed",
             source_sha: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
             source_tree: "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
             artifact_sha256: "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc",
             observed_at: "2026-08-27T00:00:00Z"
           }
       )' "$repo_root/docs/release/p0-ledger.v1.json" >"$fixture_root/p0_closed.json"
cp "$repo_root/docs/release/p0-ledger.v1.json" "$fixture_root/p0_open.json"
write_fixture capability_valid '{"schema":"open-scribe.capabilities/v1","capabilities":[{"id":"native-shell","maturity":"Fixture","platform":"macOS 13 arm64","permissions":[],"network":"none","inputs":[],"outputs":["fixture state"],"terminology":"Development fixture","proof_receipt":"M0_COMPLETE_GREEN"}]}'
write_fixture model_empty '{"schema":"open-scribe.models/v1","bundled_large_weights":false,"models":[]}'
write_fixture supply_open '{"schema":"open-scribe.components/v1","status":"open","cargo_lock_sha256":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","components":[{"id":"cargo:serde@1.0.0","kind":"rust","source":"registry","license":"MIT OR Apache-2.0","obligation":"Pending review","included_targets":[],"binary_path":null,"sha256":null,"review_state":"Pending"}]}'
write_fixture malformed '{"schema":"wrong","entries":[]}'
write_fixture incomplete_p0 '{"schema":"open-scribe.release-p0-ledger/v1","status":"closed","candidate":{"version":"0.1.0","source_sha":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","source_tree":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"},"entries":[{"id":"explicit-capture-authority","state":"Passed","owner":"owner","environment":"artifact","artifact_test":"gate","receipt":{"id":"receipt","result":"Passed","source_sha":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","source_tree":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","artifact_sha256":"cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc","observed_at":"2026-08-27T00:00:00Z"}}]}'
write_fixture contradictory_model '{"schema":"open-scribe.models/v1","bundled_large_weights":false,"models":[{"id":"bad","purpose":"asr","source":"source","revision":"revision","license":"MIT","redistribution":"allowed","engine":"engine","format":"format","compatibility":"compatibility","resources":{},"download_origins":[],"prompt_compatibility":"","calibration_compatibility":"","sha256":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","byte_length":1,"bundled":true}]}'
write_fixture ungrounded_capability '{"schema":"open-scribe.capabilities/v1","capabilities":[{"id":"invented","maturity":"Available","platform":"macOS","permissions":[],"network":"none","inputs":[],"outputs":[],"terminology":"Invented","proof_receipt":"TRUST_ME"}]}'

"$script_dir/validate_release_input.sh" p0 "$fixture_root/p0_closed.json" >/dev/null ||
	fail "closed P0 ledger was rejected"

set +e
open_output="$("$script_dir/validate_release_input.sh" p0 "$fixture_root/p0_open.json" 2>&1)"
open_status=$?
malformed_output="$("$script_dir/validate_release_input.sh" p0 "$fixture_root/malformed.json" 2>&1)"
malformed_status=$?
incomplete_output="$("$script_dir/validate_release_input.sh" p0 "$fixture_root/incomplete_p0.json" 2>&1)"
incomplete_status=$?
contradictory_model_output="$("$script_dir/validate_release_input.sh" model "$fixture_root/contradictory_model.json" 2>&1)"
contradictory_model_status=$?
ungrounded_capability_output="$("$script_dir/validate_release_input.sh" capability "$fixture_root/ungrounded_capability.json" 2>&1)"
ungrounded_capability_status=$?
set -e

[[ "$open_status" -eq 1 ]] || fail "open P0 ledger did not return hold status"
rg -q '^RELEASE_INPUT_HOLD: p0:' <<<"$open_output" || fail "open P0 output is unstable"
[[ "$malformed_status" -eq 2 ]] || fail "malformed P0 ledger did not return invalid status"
rg -q '^RELEASE_INPUT_INVALID: p0:' <<<"$malformed_output" || fail "invalid P0 output is unstable"
[[ "$incomplete_status" -eq 2 ]] || fail "incomplete canonical P0 set was accepted"
rg -q '^RELEASE_INPUT_INVALID: p0:' <<<"$incomplete_output" || fail "incomplete P0 output is unstable"
[[ "$contradictory_model_status" -eq 2 ]] || fail "contradictory bundled-model policy was accepted"
rg -q '^RELEASE_INPUT_INVALID: model:' <<<"$contradictory_model_output" ||
	fail "contradictory-model output is unstable"
[[ "$ungrounded_capability_status" -eq 2 ]] || fail "ungrounded capability proof was accepted"
rg -q '^RELEASE_INPUT_INVALID: capability:' <<<"$ungrounded_capability_output" ||
	fail "ungrounded-capability output is unstable"

"$script_dir/validate_release_input.sh" capability "$fixture_root/capability_valid.json" >/dev/null ||
	fail "valid capability manifest was rejected"
"$script_dir/validate_release_input.sh" model "$fixture_root/model_empty.json" >/dev/null ||
	fail "empty default model manifest was rejected"

set +e
supply_output="$("$script_dir/validate_release_input.sh" supply-chain "$fixture_root/supply_open.json" 2>&1)"
supply_status=$?
set -e
[[ "$supply_status" -eq 1 ]] || fail "open supply-chain inventory did not return hold status"
rg -q '^RELEASE_INPUT_HOLD: supply-chain:' <<<"$supply_output" ||
	fail "open supply-chain output is unstable"

printf '%s\n' \
	'RELEASE_INPUT_CHECK_GREEN' \
	'proof=schema_identity,canonical_p0_completeness,candidate_bound_closed_receipts,owner_environment_test_fields,allowed_states,capability_proof_vocabulary,contradictory_model_rejection,open_supply_chain_semantics,empty_default_model_catalog' \
	'excludes=milestone_receipts,legal_adoption,runtime_capability_equality,license_review,artifact_verification,release'
