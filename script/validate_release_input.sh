#!/usr/bin/env bash
set -euo pipefail

usage() {
	printf 'RELEASE_INPUT_USAGE: validate_release_input.sh <p0|capability|model|supply-chain> <json-path>\n' >&2
	exit 64
}

[[ "$#" -eq 2 ]] || usage
kind="$1"
input_path="$2"
[[ -f "$input_path" && ! -L "$input_path" ]] || {
	printf 'RELEASE_INPUT_INVALID: %s: missing or non-regular input\n' "$kind" >&2
	exit 2
}

invalid() {
	printf 'RELEASE_INPUT_INVALID: %s: %s\n' "$kind" "$1" >&2
	exit 2
}

hold() {
	printf 'RELEASE_INPUT_HOLD: %s: %s\n' "$kind" "$1" >&2
	exit 1
}

case "$kind" in
p0)
	jq -e \
		--argjson canonical_ids '[
          "content-free-logs",
          "deletion",
          "evidence-interpretation-separation",
          "explicit-capture-authority",
          "forced-termination-recovery",
          "legal-security-adoption",
          "local-only-network-denial",
          "media-durability-and-long-session-sync",
          "permission-revocation",
          "provider-category-scope",
          "recording-state-truth",
          "required-source-identity",
          "security-of-secrets",
          "update-integrity",
          "website-binary-capability-equality"
        ]' \
		'.schema == "open-scribe.release-p0-ledger/v1"
         and (.status == "open" or .status == "closed")
         and (.candidate | type == "object")
         and (.candidate.version == null or (.candidate.version | test("^[0-9]+\\.[0-9]+\\.[0-9]+$")))
         and (.candidate.source_sha == null or (.candidate.source_sha | test("^[0-9a-f]{40}$")))
         and (.candidate.source_tree == null or (.candidate.source_tree | test("^[0-9a-f]{40}$")))
         and (.entries | type == "array" and length > 0)
         and (.entries | all(
           (.id | type == "string" and length > 0)
           and (.state == "Passed" or .state == "Failed" or .state == "Open" or .state == "Unknown")
           and (.owner | type == "string" and length > 0)
           and (.environment | type == "string" and length > 0)
           and (.artifact_test | type == "string" and length > 0)
           and (
             .receipt == null or (
               (.receipt | type == "object")
               and (.receipt.id | type == "string" and length > 0)
               and (.receipt.result == "Passed" or .receipt.result == "Failed")
               and (.receipt.source_sha | test("^[0-9a-f]{40}$"))
               and (.receipt.source_tree | test("^[0-9a-f]{40}$"))
               and (.receipt.artifact_sha256 == null or (.receipt.artifact_sha256 | test("^[0-9a-f]{64}$")))
               and (.receipt.observed_at | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(Z|[+-][0-9]{2}:[0-9]{2})$"))
             )
           )
         ))
         and (([.entries[] | .id] | sort) == ($canonical_ids | sort))' "$input_path" >/dev/null 2>&1 ||
		invalid "candidate binding, canonical P0 set, owner, environment, test, receipt, or state is invalid"
	if ! jq -e \
		--arg source_sha "$(jq -r '.candidate.source_sha // ""' "$input_path")" \
		--arg source_tree "$(jq -r '.candidate.source_tree // ""' "$input_path")" \
		'.status == "closed"
         and (.candidate.version | test("^[0-9]+\\.[0-9]+\\.[0-9]+$"))
         and (.candidate.source_sha | test("^[0-9a-f]{40}$"))
         and (.candidate.source_tree | test("^[0-9a-f]{40}$"))
         and (.entries | all(
           .state == "Passed"
           and .receipt.result == "Passed"
           and .receipt.source_sha == $source_sha
           and .receipt.source_tree == $source_tree
           and (.receipt.artifact_sha256 | test("^[0-9a-f]{64}$"))
         ))' "$input_path" >/dev/null; then
		hold "ledger contains unresolved P0 entries"
	fi
	;;
capability)
	jq -e \
		'.schema == "open-scribe.capabilities/v1"
         and (.capabilities | type == "array" and length > 0)
         and (.capabilities | all(
           (.id | type == "string" and length > 0)
           and (.maturity == "Unavailable" or .maturity == "Fixture" or .maturity == "Available")
           and (.platform | type == "string" and length > 0)
           and (.permissions | type == "array")
           and (.network | type == "string" and length > 0)
           and (.inputs | type == "array")
           and (.outputs | type == "array")
           and (.terminology | type == "string" and length > 0)
           and (.proof_receipt | test("^(M0_COMPLETE_GREEN|M1_LIVE_MICROPHONE_GREEN|M[1-4]_COMPLETE_GREEN)$"))
         ))
         and (([.capabilities[] | .id] | length) == ([.capabilities[] | .id] | unique | length))' "$input_path" >/dev/null 2>&1 ||
		invalid "schema, capability fields, maturity, or unique IDs are invalid"
	;;
model)
	jq -e \
		'.schema == "open-scribe.models/v1"
         and .bundled_large_weights == false
         and (.models | type == "array")
         and (.models | all(
           (.id | type == "string" and length > 0)
           and (.purpose | type == "string" and length > 0)
           and (.source | type == "string" and length > 0)
           and (.revision | type == "string" and length > 0)
           and (.license | type == "string" and length > 0)
           and (.redistribution | type == "string" and length > 0)
           and (.engine | type == "string" and length > 0)
           and (.format | type == "string" and length > 0)
           and (.compatibility | type == "string" and length > 0)
           and (.resources | type == "object")
           and (.download_origins | type == "array")
           and (.prompt_compatibility | type == "string")
           and (.calibration_compatibility | type == "string")
           and (.sha256 | test("^[0-9a-f]{64}$"))
           and (.byte_length | type == "number" and . > 0)
           and .bundled == false
         ))
         and (([.models[] | .id] | length) == ([.models[] | .id] | unique | length))' "$input_path" >/dev/null 2>&1 ||
		invalid "schema, default bundle policy, model fields, or unique IDs are invalid"
	;;
supply-chain)
	jq -e \
		'.schema == "open-scribe.components/v1"
         and (.status == "open" or .status == "closed")
         and (.cargo_lock_sha256 | test("^[0-9a-f]{64}$"))
         and (.components | type == "array" and length > 0)
         and (.components | all(
           (.id | type == "string" and length > 0)
           and (.kind | type == "string" and length > 0)
           and (.source | type == "string" and length > 0)
           and (.license | type == "string" and length > 0)
           and (.obligation | type == "string" and length > 0)
           and (.included_targets | type == "array")
           and (.binary_path == null or (.binary_path | type == "string" and length > 0))
           and (.sha256 == null or (.sha256 | test("^[0-9a-f]{64}$")))
           and (.review_state == "Pending" or .review_state == "Admitted" or .review_state == "Rejected")
         ))
         and (([.components[] | .id] | length) == ([.components[] | .id] | unique | length))' "$input_path" >/dev/null 2>&1 ||
		invalid "schema, lock hash, component fields, review state, or unique IDs are invalid"
	if ! jq -e \
		'.status == "closed"
         and (.components | all(
           .review_state == "Admitted"
           and .obligation != "Pending review"
           and (.included_targets | length > 0)
         ))' "$input_path" >/dev/null; then
		hold "component inventory contains unresolved review entries"
	fi
	;;
*) usage ;;
esac

printf 'RELEASE_INPUT_PASS: %s: %s\n' "$kind" "$input_path"
