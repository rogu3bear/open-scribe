#!/usr/bin/env bash
set -euo pipefail

script_dir="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
repo_root="$(CDPATH='' cd -- "$script_dir/.." && pwd)"
cd "$repo_root"

fail() {
	printf 'RELEASE_PREPARE_CHECK_RED: %s\n' "$1" >&2
	exit 1
}

before_status="$(git status --porcelain=v1 --untracked-files=all)"

invalid_output="$("$script_dir/release.sh" prepare invalid 2>&1 || true)"
rg -q '^RELEASE_PREPARE_USAGE:' <<<"$invalid_output" ||
	fail "invalid semantic versions do not fail with stable usage output"

set +e
prepare_output="$("$script_dir/release.sh" prepare 0.1.0 2>&1)"
prepare_status=$?
set -e

[[ "$prepare_status" -eq 1 ]] || fail "an incomplete candidate did not stop on readiness blockers"
for required in \
	'^RELEASE_PREPARE_HOLD$' \
	'^candidate_version=0\.1\.0$' \
	'^source_sha=[0-9a-f]{40}$' \
	'^blocker=.*milestone_1_complete_receipt' \
	'^blocker=.*milestone_2_complete_receipt' \
	'^blocker=.*milestone_3_complete_receipt' \
	'^blocker=.*milestone_4_complete_receipt' \
	'^blocker=.*legal_adoption' \
	'^blocker=.*private_security_channel' \
	'^blocker=.*p0_ledger' \
	'^blocker=.*release_notes' \
	'^next=resolve every blocker'; do
	rg -q "$required" <<<"$prepare_output" ||
		fail "readiness output is missing: $required"
done

after_status="$(git status --porcelain=v1 --untracked-files=all)"
[[ "$before_status" == "$after_status" ]] || fail "prepare mutated the working tree"

printf '%s\n' \
	'RELEASE_PREPARE_CHECK_GREEN' \
	'proof=stable_semver_rejection,exact_source_binding,complete_predecessor_holds,legal_security_p0_holds,release_notes_hold,read_only_prepare' \
	'excludes=milestone_completion,version_allocation,signing,notarization,packaging,publication,deployment,public_release'
