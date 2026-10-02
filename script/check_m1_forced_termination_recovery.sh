#!/usr/bin/env bash
set -euo pipefail

script_dir="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
repo_root="$(CDPATH='' cd -- "$script_dir/.." && pwd)"
cd "$repo_root"

# Source, clippy, fresh bindings, floor/warning checks and every prerequisite
# Swift suite now run once in check_candidate.sh. Require its exact receipt.
# shellcheck source=script/candidate.sh
source "$script_dir/candidate.sh"
[[ "$#" == 2 && "$1" == --candidate ]] || candidate_fail 'usage: check_m1_forced_termination_recovery.sh --candidate /absolute/path/candidate.json'
candidate_load "$2"
candidate_require_checks
"$script_dir/build_and_run.sh" --m1-forced-termination-recovery-proof --candidate "$candidate_record"

candidate_base="$(git merge-base HEAD main 2>/dev/null || true)"
if [[ -z "$candidate_base" || "$candidate_base" == "$(git rev-parse HEAD)" ]]; then
	candidate_base="$(git rev-parse HEAD^)"
fi
git diff --check "$candidate_base" HEAD
git diff --check
candidate_receipt

printf '%s\n' \
	'M1_FORCED_TERMINATION_RECOVERY_GATE_GREEN' \
	'proof=interruption_state_regression,recovery_planning_before_mutation,journal_first_projection_repair,strict_unclosed_pcm_caf_validation,content_free_durable_recovery_receipt,ready_for_review_projection,persistent_recovered_conversation,native_playback_controller,real_microphone_first_sample,real_system_audio_first_sample,rust_owned_multi_source_recording,thirty_second_rotation,external_sigkill,relaunch_scan,atomic_two_track_recovery,independent_playable_media_decode,unchanged_media_digests,idempotent_relaunch,fresh_bindings,clean_arm64_macos13_tests,candidate_range_and_worktree_diff_hygiene' \
	'excludes=source_loss,degraded_continuation,permission_revocation,application_selection,audible_output,disk_pressure,two_hour_capture,transcription,diarization,signing,notarization,distribution,deployment,public_release'
