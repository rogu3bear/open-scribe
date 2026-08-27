#!/usr/bin/env bash
set -euo pipefail

script_dir="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
fixture_root="$(mktemp -d "${TMPDIR:-/tmp}/open-scribe-bundle-verify.XXXXXX")"
trap 'rm -rf "$fixture_root"' EXIT

fail() {
	printf 'BUNDLE_VERIFY_CHECK_RED: %s\n' "$1" >&2
	exit 1
}

set +e
usage_output="$("$script_dir/verify_bundle.sh" 2>&1)"
usage_status=$?
missing_output="$("$script_dir/verify_bundle.sh" "$fixture_root/missing.app" 2>&1)"
missing_status=$?
set -e

[[ "$usage_status" -eq 64 ]] || fail "missing argument did not return usage status"
rg -q '^BUNDLE_VERIFY_USAGE:' <<<"$usage_output" || fail "usage output is unstable"
[[ "$missing_status" -eq 2 ]] || fail "missing artifact did not return invalid-input status"
rg -q '^BUNDLE_VERIFY_INVALID:' <<<"$missing_output" || fail "missing-artifact output is unstable"

fake_app="$fixture_root/Open Scribe.app"
mkdir -p "$fake_app/Contents/MacOS"
touch "$fake_app/Contents/MacOS/Open Scribe"
set +e
unconfigured_output="$("$script_dir/verify_bundle.sh" "$fake_app" 2>&1)"
unconfigured_status=$?
set -e
[[ "$unconfigured_status" -eq 1 ]] || fail "unconfigured signing authority did not block verification"
rg -q '^BUNDLE_VERIFY_RED: approved signing policy is unavailable$' <<<"$unconfigured_output" ||
	fail "signing-policy hold output is unstable"

printf '%s\n' \
	'BUNDLE_VERIFY_CHECK_GREEN' \
	'proof=stable_usage,missing_artifact_rejection,missing_signing_authority_rejection,read_only_failure_paths' \
	'excludes=signed_artifact,unsigned_artifact_rejection_after_policy,nested_signature_inventory,notarization,Gatekeeper,clean_machine,update,publication,release'
