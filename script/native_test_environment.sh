#!/usr/bin/env bash
# Sourced by every native test consumer. The app refuses a test host lacking
# this explicit isolated root; the test scheme also marks its launch intent.
native_test_environment() {
	local isolated_root
	isolated_root="$(mktemp -d "${TMPDIR:-/tmp}/open-scribe-test-host.XXXXXX")"
	isolated_root="$(CDPATH='' cd -- "$isolated_root" && pwd -P)"
	export TEST_RUNNER_OPEN_SCRIBE_TEST_HOST=1
	export TEST_RUNNER_OPEN_SCRIBE_PROOF_ROOT="$isolated_root"
	TEST_RUNNER_OPEN_SCRIBE_PROOF_PREFERENCES="OpenScribe.Proof.$(basename "$isolated_root")"
	export TEST_RUNNER_OPEN_SCRIBE_PROOF_PREFERENCES
	# Scene/component checks never inherit an opt-in real screen sampling test.
	export TEST_RUNNER_OPEN_SCRIBE_CONTEXT_LIVE_CAPTURE=0
	printf 'NATIVE_TEST_ISOLATION: root=%s preferences=%s\n' \
		"$isolated_root" "$TEST_RUNNER_OPEN_SCRIBE_PROOF_PREFERENCES"
}
