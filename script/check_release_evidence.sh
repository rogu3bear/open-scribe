#!/usr/bin/env bash
set -euo pipefail

script_dir="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
verifier="$script_dir/verify_release_evidence.sh"
[[ -x "$verifier" && ! -L "$verifier" ]] || {
	printf '%s\n' 'RELEASE_EVIDENCE_CHECK_RED: canonical verifier is unavailable' >&2
	exit 1
}

fixture_root="$(mktemp -d "${TMPDIR:-/tmp}/open-scribe-release-evidence.XXXXXX")"
trap 'rm -rf "$fixture_root"' EXIT
namespace="open-scribe-release-evidence"
now_epoch="1788080400"
producer_sha="$(printf canonical-producer | shasum -a 256 | awk '{print $1}')"

ssh-keygen -q -t ed25519 -N '' -f "$fixture_root/key" >/dev/null
public_key="$(<"$fixture_root/key.pub")"
jq -n --arg key "$public_key" --arg namespace "$namespace" '{
  schema: "open-scribe.release-evidence-policy/v1",
  namespace: $namespace,
  max_age_seconds: 604800,
  admission_complete: true,
  authorities: [{id:"release-reviewer", principal:"release-reviewer", public_key:$key,
    active:true, grants:[{
      kind:"milestone-1-complete",
      producer:{id:"m1-complete", executable_sha256:("PLACEHOLDER")},
      proof_plane:"native-runtime",
      artifact:{kind:"macos-app", identity:"app.open-scribe.dev"},
      runtime:{identity:"macos-15.6.1-arm64-host"},
      denominator:{id:"m1-complete-v1"}
    }]}]
}' >"$fixture_root/policy.json"
jq --arg producer_sha "$producer_sha" \
	'.authorities[0].grants[0].producer.executable_sha256 = $producer_sha' \
	"$fixture_root/policy.json" >"$fixture_root/policy.bound.json"
mv "$fixture_root/policy.bound.json" "$fixture_root/policy.json"
jq -n --arg producer_sha "$producer_sha" --argjson observed_at_epoch 1788080000 '{
  schema:"open-scribe.release-evidence/v1", result:"Passed", kind:"milestone-1-complete",
  candidate:{source_sha:("a"*40), source_tree:("b"*40)},
  producer:{id:"m1-complete", executable_sha256:$producer_sha},
  authority:{id:"release-reviewer"},
  artifact:{kind:"macos-app", identity:"app.open-scribe.dev", sha256:("c"*64)},
  runtime:{identity:"macos-15.6.1-arm64-host", executable_sha256:("d"*64)},
  denominator:{id:"m1-complete-v1", sha256:("e"*64)},
  proof_plane:"native-runtime", observed_at_epoch:$observed_at_epoch
}' >"$fixture_root/receipt.json"
ssh-keygen -Y sign -q -f "$fixture_root/key" -n "$namespace" "$fixture_root/receipt.json"

sign_receipt() {
	rm -f "$fixture_root/receipt.json.sig"
	ssh-keygen -Y sign -q -f "$fixture_root/key" -n "$namespace" "$fixture_root/receipt.json"
}

verify() {
	"$verifier" "$fixture_root/policy.json" "$fixture_root/receipt.json" \
		"$fixture_root/receipt.json.sig" milestone-1-complete \
		"$(printf 'a%.0s' {1..40})" "$(printf 'b%.0s' {1..40})" \
		"$producer_sha" native-runtime "$(printf 'c%.0s' {1..64})" \
		"$(printf 'd%.0s' {1..64})" "$(printf 'e%.0s' {1..64})" "$now_epoch"
}

verify >/dev/null

cp "$fixture_root/policy.json" "$fixture_root/policy.good.json"
jq '.admission_complete = false' "$fixture_root/policy.good.json" >"$fixture_root/policy.json"
if verify >/dev/null 2>&1; then
	printf '%s\n' 'RELEASE_EVIDENCE_CHECK_RED: admission-incomplete policy was accepted' >&2
	exit 1
fi
mv "$fixture_root/policy.good.json" "$fixture_root/policy.json"

for field in artifact_identity artifact_kind runtime_identity denominator_id authority producer_id; do
	cp "$fixture_root/receipt.json" "$fixture_root/receipt.good.json"
	case "$field" in
	artifact_identity) jq '.artifact.identity = "substituted.app"' "$fixture_root/receipt.good.json" >"$fixture_root/receipt.json" ;;
	artifact_kind) jq '.artifact.kind = "substituted-kind"' "$fixture_root/receipt.good.json" >"$fixture_root/receipt.json" ;;
	runtime_identity) jq '.runtime.identity = "substituted-runtime"' "$fixture_root/receipt.good.json" >"$fixture_root/receipt.json" ;;
	denominator_id) jq '.denominator.id = "substituted-denominator"' "$fixture_root/receipt.good.json" >"$fixture_root/receipt.json" ;;
	authority) jq '.authority.id = "unknown-authority"' "$fixture_root/receipt.good.json" >"$fixture_root/receipt.json" ;;
	producer_id) jq '.producer.id = "unknown-producer"' "$fixture_root/receipt.good.json" >"$fixture_root/receipt.json" ;;
	esac
	sign_receipt
	if verify >/dev/null 2>&1; then
		printf 'RELEASE_EVIDENCE_CHECK_RED: policy-unbound %s was accepted\n' "$field" >&2
		exit 1
	fi
	mv "$fixture_root/receipt.good.json" "$fixture_root/receipt.json"
	sign_receipt
done

cp "$fixture_root/receipt.json" "$fixture_root/receipt.good.json"
printf '\n' >>"$fixture_root/receipt.json"
if verify >/dev/null 2>&1; then
	printf '%s\n' 'RELEASE_EVIDENCE_CHECK_RED: raw-byte tamper was accepted' >&2
	exit 1
fi
mv "$fixture_root/receipt.good.json" "$fixture_root/receipt.json"

cp "$fixture_root/receipt.json" "$fixture_root/receipt.good.json"
jq '.candidate.source_sha = ("f" * 40)' "$fixture_root/receipt.good.json" >"$fixture_root/receipt.json"
sign_receipt
if verify >/dev/null 2>&1; then
	printf '%s\n' 'RELEASE_EVIDENCE_CHECK_RED: tampered candidate was accepted' >&2
	exit 1
fi
mv "$fixture_root/receipt.good.json" "$fixture_root/receipt.json"
sign_receipt

cp "$fixture_root/receipt.json" "$fixture_root/receipt.good.json"
jq '.candidate.source_tree = ("f" * 40)' "$fixture_root/receipt.good.json" >"$fixture_root/receipt.json"
sign_receipt
if verify >/dev/null 2>&1; then
	printf '%s\n' 'RELEASE_EVIDENCE_CHECK_RED: tampered source tree was accepted' >&2
	exit 1
fi
mv "$fixture_root/receipt.good.json" "$fixture_root/receipt.json"
sign_receipt

for field in producer proof_plane artifact runtime denominator freshness; do
	cp "$fixture_root/receipt.json" "$fixture_root/receipt.good.json"
	case "$field" in
	producer) jq '.producer.executable_sha256 = ("f" * 64)' "$fixture_root/receipt.good.json" >"$fixture_root/receipt.json" ;;
	proof_plane) jq '.proof_plane = "source"' "$fixture_root/receipt.good.json" >"$fixture_root/receipt.json" ;;
	artifact) jq '.artifact.sha256 = ("f" * 64)' "$fixture_root/receipt.good.json" >"$fixture_root/receipt.json" ;;
	runtime) jq '.runtime.executable_sha256 = ("f" * 64)' "$fixture_root/receipt.good.json" >"$fixture_root/receipt.json" ;;
	denominator) jq '.denominator.sha256 = ("f" * 64)' "$fixture_root/receipt.good.json" >"$fixture_root/receipt.json" ;;
	freshness) jq '.observed_at_epoch = 1' "$fixture_root/receipt.good.json" >"$fixture_root/receipt.json" ;;
	esac
	sign_receipt
	if verify >/dev/null 2>&1; then
		printf 'RELEASE_EVIDENCE_CHECK_RED: invalid %s binding was accepted\n' "$field" >&2
		exit 1
	fi
	mv "$fixture_root/receipt.good.json" "$fixture_root/receipt.json"
	sign_receipt
done

if "$verifier" "$fixture_root/policy.json" "$fixture_root/receipt.json" \
	"$fixture_root/receipt.json.sig" milestone-1-complete \
	"$(printf 'a%.0s' {1..40})" "$(printf 'b%.0s' {1..40})" \
	"$producer_sha" native-runtime "$(printf 'c%.0s' {1..64})" \
	"$(printf 'd%.0s' {1..64})" "$(printf 'e%.0s' {1..64})" \
	18446744073709551616 >/dev/null 2>&1; then
	printf '%s\n' 'RELEASE_EVIDENCE_CHECK_RED: overflowing caller epoch was accepted' >&2
	exit 1
fi

cp "$fixture_root/receipt.json" "$fixture_root/receipt.good.json"
jq '.observed_at_epoch = 1788080801' "$fixture_root/receipt.good.json" >"$fixture_root/receipt.json"
sign_receipt
if verify >/dev/null 2>&1; then
	printf '%s\n' 'RELEASE_EVIDENCE_CHECK_RED: implausibly future receipt was accepted' >&2
	exit 1
fi
mv "$fixture_root/receipt.good.json" "$fixture_root/receipt.json"
sign_receipt

cp "$fixture_root/receipt.json" "$fixture_root/receipt.good.json"
jq '.artifact.sha256 = "not-a-sha256"' "$fixture_root/receipt.good.json" >"$fixture_root/receipt.json"
sign_receipt
if verify >/dev/null 2>&1; then
	printf '%s\n' 'RELEASE_EVIDENCE_CHECK_RED: malformed hash was accepted' >&2
	exit 1
fi
mv "$fixture_root/receipt.good.json" "$fixture_root/receipt.json"
sign_receipt

ln -s "$fixture_root/policy.json" "$fixture_root/policy-link.json"
if "$verifier" "$fixture_root/policy-link.json" "$fixture_root/receipt.json" \
	"$fixture_root/receipt.json.sig" milestone-1-complete \
	"$(printf 'a%.0s' {1..40})" "$(printf 'b%.0s' {1..40})" \
	"$producer_sha" native-runtime "$(printf 'c%.0s' {1..64})" \
	"$(printf 'd%.0s' {1..64})" "$(printf 'e%.0s' {1..64})" "$now_epoch" >/dev/null 2>&1; then
	printf '%s\n' 'RELEASE_EVIDENCE_CHECK_RED: symlinked policy was accepted' >&2
	exit 1
fi

ln -s "$fixture_root/receipt.json" "$fixture_root/receipt-link.json"
if "$verifier" "$fixture_root/policy.json" "$fixture_root/receipt-link.json" \
	"$fixture_root/receipt.json.sig" milestone-1-complete \
	"$(printf 'a%.0s' {1..40})" "$(printf 'b%.0s' {1..40})" \
	"$producer_sha" native-runtime "$(printf 'c%.0s' {1..64})" \
	"$(printf 'd%.0s' {1..64})" "$(printf 'e%.0s' {1..64})" "$now_epoch" >/dev/null 2>&1; then
	printf '%s\n' 'RELEASE_EVIDENCE_CHECK_RED: symlinked receipt was accepted' >&2
	exit 1
fi

ln -s "$fixture_root/receipt.json.sig" "$fixture_root/signature-link.sig"
if "$verifier" "$fixture_root/policy.json" "$fixture_root/receipt.json" \
	"$fixture_root/signature-link.sig" milestone-1-complete \
	"$(printf 'a%.0s' {1..40})" "$(printf 'b%.0s' {1..40})" \
	"$producer_sha" native-runtime "$(printf 'c%.0s' {1..64})" \
	"$(printf 'd%.0s' {1..64})" "$(printf 'e%.0s' {1..64})" "$now_epoch" >/dev/null 2>&1; then
	printf '%s\n' 'RELEASE_EVIDENCE_CHECK_RED: symlinked signature was accepted' >&2
	exit 1
fi

rm "$fixture_root/receipt.json.sig"
if verify >/dev/null 2>&1; then
	printf '%s\n' 'RELEASE_EVIDENCE_CHECK_RED: unsigned receipt was accepted' >&2
	exit 1
fi

printf '%s\n' \
	'RELEASE_EVIDENCE_CHECK_GREEN' \
	'proof=detached_signature,candidate,policy_grant,producer,authority,artifact,runtime,denominator,freshness,proof_plane,raw_tamper,hash_shape,symlink,unsigned_rejection' \
	'excludes=active_production_authority,milestone_completion,release_signing,notarization,publication,release'
