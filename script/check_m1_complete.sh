#!/usr/bin/env bash
set -euo pipefail

printf '%s\n' \
	'M1_COMPLETE_HOLD' \
	'available_lower_gate_classes=durable_preparation,media_open,first_sample,segment_sealing,interruption_projection,short_dual_source_capture,forced_termination_recovery' \
	'candidate_binding=required_before any lower receipt can support M1 completion' \
	'missing_implementation=pause_resume,durable_markers,validated_mixdown,disk_pressure_policy,application_scoped_selection,native_channel_layout_fidelity' \
	'foundation_lower_gate=synthetic_and_short_live_shared_timeline_rotation_sigkill_recovery_and_native_playback;exact_artifact_evidence_in_docs/TESTING.md' \
	'missing=source_loss_continuation,permission_revocation,route_change,disk_pressure,two_hour_synchronization,application_scoped_selection' \
	'protected=real_microphone_and_screen_system_audio_permissions,long_session_runtime' \
	'next=complete the remaining ADR 0005-0007 recorder behavior, then run the exact-candidate runtime matrix under explicit TCC and audio-route authority' >&2
exit 1
