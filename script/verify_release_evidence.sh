#!/usr/bin/env bash
set -euo pipefail

usage() {
	printf '%s\n' 'RELEASE_EVIDENCE_USAGE: verify_release_evidence.sh <policy> <receipt> <signature> <kind> <source-sha> <source-tree> <producer-sha256> <proof-plane> <artifact-sha256> <runtime-sha256> <denominator-sha256> <now-epoch>' >&2
	exit 64
}

[[ "$#" -eq 12 ]] || usage
policy_path="$1"
receipt_path="$2"
signature_path="$3"
expected_kind="$4"
expected_source_sha="$5"
expected_source_tree="$6"
expected_producer_sha="$7"
expected_proof_plane="$8"
expected_artifact_sha="$9"
expected_runtime_sha="${10}"
expected_denominator_sha="${11}"
now_epoch="${12}"

safe_id='^[A-Za-z0-9._@+:/=-]+$'
sha1_pattern='^[0-9a-f]{40}$'
sha256_pattern='^[0-9a-f]{64}$'
[[ "$expected_kind" =~ $safe_id ]] || usage
[[ "$expected_proof_plane" =~ $safe_id ]] || usage
[[ "$expected_source_sha" =~ $sha1_pattern ]] || usage
[[ "$expected_source_tree" =~ $sha1_pattern ]] || usage
[[ "$expected_producer_sha" =~ $sha256_pattern ]] || usage
[[ "$expected_artifact_sha" =~ $sha256_pattern ]] || usage
[[ "$expected_runtime_sha" =~ $sha256_pattern ]] || usage
[[ "$expected_denominator_sha" =~ $sha256_pattern ]] || usage
[[ "$now_epoch" =~ ^(0|[1-9][0-9]{0,9})$ && "$now_epoch" -le 4102444800 ]] || usage
command -v lsof >/dev/null 2>&1 || {
	printf '%s\n' 'RELEASE_EVIDENCE_INVALID: lsof is required for descriptor identity binding' >&2
	exit 2
}

snapshot_root="$(mktemp -d "${TMPDIR:-/tmp}/open-scribe-release-evidence-verify.XXXXXX")"
trap 'rm -rf "$snapshot_root"' EXIT
chmod 700 "$snapshot_root"

snapshot_regular_file() {
	local source="$1"
	local destination="$2"
	local before_identity after_identity fd_info open_device open_inode open_type
	[[ -f "$source" && ! -L "$source" ]] || {
		printf 'RELEASE_EVIDENCE_INVALID: missing or non-regular input: %s\n' "$source" >&2
		exit 2
	}
	before_identity="$(stat -f '%d:%i:%HT' "$source")"
	exec 3<"$source"
	fd_info="$(lsof -a -p "$$" -d 3 -F Dift)"
	open_device="$(sed -n 's/^D//p' <<<"$fd_info")"
	open_inode="$(sed -n 's/^i//p' <<<"$fd_info")"
	open_type="$(sed -n 's/^t//p' <<<"$fd_info")"
	after_identity="$(stat -f '%d:%i:%HT' "$source")"
	[[ "$open_device" =~ ^0x[0-9a-fA-F]+$ && "$open_inode" =~ ^[0-9]+$ ]] || {
		exec 3<&-
		printf 'RELEASE_EVIDENCE_INVALID: opened input identity is unavailable: %s\n' "$source" >&2
		exit 2
	}
	open_device="$((open_device))"
	[[ "$before_identity" == "$after_identity" && ! -L "$source" && -f "$source" &&
		"$after_identity" == "$open_device:$open_inode:Regular File" && "$open_type" == "REG" ]] || {
		exec 3<&-
		printf 'RELEASE_EVIDENCE_INVALID: input identity changed while opening: %s\n' "$source" >&2
		exit 2
	}
	cat <&3 >"$destination"
	exec 3<&-
	chmod 600 "$destination"
}

policy="$snapshot_root/policy.json"
receipt="$snapshot_root/receipt.json"
signature="$snapshot_root/receipt.sig"
snapshot_regular_file "$policy_path" "$policy"
snapshot_regular_file "$receipt_path" "$receipt"
snapshot_regular_file "$signature_path" "$signature"

jq -e --arg safe_id "$safe_id" --arg sha256 "$sha256_pattern" '
  .schema == "open-scribe.release-evidence-policy/v1"
  and (.namespace | test("^[A-Za-z0-9._@+-]+$"))
  and (.max_age_seconds | type == "number" and floor == . and . > 0 and . <= 31536000)
  and .admission_complete == true
  and (.authorities | type == "array")
  and (.authorities | all(
    (.id | test("^[A-Za-z0-9._@+-]+$"))
    and (.principal | test("^[A-Za-z0-9._@+-]+$"))
    and (.public_key | test("^ssh-ed25519 [A-Za-z0-9+/=]+( [A-Za-z0-9._@+-]+)?$"))
    and (.active | type == "boolean")
    and (.grants | type == "array" and all(
      (.kind | test($safe_id))
      and (.producer.id | test($safe_id))
      and (.producer.executable_sha256 | test($sha256))
      and (.proof_plane | test($safe_id))
      and (.artifact.kind | test($safe_id))
      and (.artifact.identity | test($safe_id))
      and (.runtime.identity | test($safe_id))
      and (.denominator.id | test($safe_id))
    ))
  ))
  and (([.authorities[].id] | length) == ([.authorities[].id] | unique | length))' \
	"$policy" >/dev/null || {
	printf '%s\n' 'RELEASE_EVIDENCE_HOLD: policy is invalid or admission-incomplete' >&2
	exit 1
}

jq -e \
	--arg kind "$expected_kind" \
	--arg source_sha "$expected_source_sha" \
	--arg source_tree "$expected_source_tree" \
	--arg producer_sha "$expected_producer_sha" \
	--arg proof_plane "$expected_proof_plane" \
	--arg artifact_sha "$expected_artifact_sha" \
	--arg runtime_sha "$expected_runtime_sha" \
	--arg denominator_sha "$expected_denominator_sha" \
	--arg safe_id "$safe_id" \
	--arg sha1 "$sha1_pattern" \
	--arg sha256 "$sha256_pattern" '
  .schema == "open-scribe.release-evidence/v1"
  and .result == "Passed"
  and .kind == $kind
  and (.candidate.source_sha | test($sha1))
  and .candidate.source_sha == $source_sha
  and (.candidate.source_tree | test($sha1))
  and .candidate.source_tree == $source_tree
  and (.producer.id | test($safe_id))
  and (.producer.executable_sha256 | test($sha256))
  and .producer.executable_sha256 == $producer_sha
  and (.authority.id | test($safe_id))
  and (.artifact.kind | test($safe_id))
  and (.artifact.identity | test($safe_id))
  and (.artifact.sha256 | test($sha256))
  and .artifact.sha256 == $artifact_sha
  and (.runtime.identity | test($safe_id))
  and (.runtime.executable_sha256 | test($sha256))
  and .runtime.executable_sha256 == $runtime_sha
  and (.denominator.id | test($safe_id))
  and (.denominator.sha256 | test($sha256))
  and .denominator.sha256 == $denominator_sha
  and .proof_plane == $proof_plane
  and (.observed_at_epoch | type == "number" and floor == . and . >= 0 and . <= 4102444800)' \
	"$receipt" >/dev/null || {
	printf '%s\n' 'RELEASE_EVIDENCE_INVALID: receipt binding is invalid' >&2
	exit 2
}

authority_id="$(jq -r '.authority.id' "$receipt")"
producer_id="$(jq -r '.producer.id' "$receipt")"
artifact_kind="$(jq -r '.artifact.kind' "$receipt")"
artifact_identity="$(jq -r '.artifact.identity' "$receipt")"
runtime_identity="$(jq -r '.runtime.identity' "$receipt")"
denominator_id="$(jq -r '.denominator.id' "$receipt")"
grant_count="$(jq \
	--arg authority "$authority_id" \
	--arg kind "$expected_kind" \
	--arg producer "$producer_id" \
	--arg producer_sha "$expected_producer_sha" \
	--arg plane "$expected_proof_plane" \
	--arg artifact_kind "$artifact_kind" \
	--arg artifact_identity "$artifact_identity" \
	--arg runtime_identity "$runtime_identity" \
	--arg denominator_id "$denominator_id" '
  [.authorities[]
    | select(.id == $authority and .active == true)
    | .grants[]
    | select(
      .kind == $kind
      and .producer.id == $producer
      and .producer.executable_sha256 == $producer_sha
      and .proof_plane == $plane
      and .artifact.kind == $artifact_kind
      and .artifact.identity == $artifact_identity
      and .runtime.identity == $runtime_identity
      and .denominator.id == $denominator_id
    )] | length' "$policy")"
[[ "$grant_count" == "1" ]] || {
	printf '%s\n' 'RELEASE_EVIDENCE_HOLD: no unique policy grant admits these exact evidence semantics' >&2
	exit 1
}

observed_epoch="$(jq -r '.observed_at_epoch' "$receipt")"
max_age="$(jq -r '.max_age_seconds' "$policy")"
if ((observed_epoch > now_epoch + 300 || now_epoch - observed_epoch > max_age)); then
	printf '%s\n' 'RELEASE_EVIDENCE_HOLD: receipt is stale or implausibly future-dated' >&2
	exit 1
fi

namespace="$(jq -r '.namespace' "$policy")"
principal="$(jq -r --arg id "$authority_id" '.authorities[] | select(.id == $id and .active == true) | .principal' "$policy")"
public_key="$(jq -r --arg id "$authority_id" '.authorities[] | select(.id == $id and .active == true) | .public_key' "$policy")"
allowed_signers="$snapshot_root/allowed-signers"
printf '%s namespaces="%s" %s\n' "$principal" "$namespace" "$public_key" >"$allowed_signers"
chmod 600 "$allowed_signers"
ssh-keygen -Y verify -q -f "$allowed_signers" -I "$principal" -n "$namespace" -s "$signature" <"$receipt" || {
	printf '%s\n' 'RELEASE_EVIDENCE_INVALID: detached signature verification failed' >&2
	exit 2
}

printf 'RELEASE_EVIDENCE_PASS: kind=%s authority=%s producer=%s plane=%s artifact=%s runtime=%s denominator=%s\n' \
	"$expected_kind" "$authority_id" "$producer_id" "$expected_proof_plane" \
	"$artifact_identity" "$runtime_identity" "$denominator_id"
