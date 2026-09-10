#!/usr/bin/env bash
set -euo pipefail

printf '%s\n' \
	'M1_COMPLETE_HOLD' \
	'available_lower_gate_classes=durable_preparation,media_open,first_sample,segment_sealing,interruption_projection,short_dual_source_capture,forced_termination_recovery' \
	'candidate_binding=required_before any lower receipt can support M1 completion' \
	'missing=source_loss_continuation,permission_revocation,route_change,disk_pressure,two_hour_synchronization,application_scoped_selection' \
	'protected=real_microphone_and_screen_system_audio_permissions,long_session_runtime' \
	'next=run the missing exact-candidate runtime matrix under explicit TCC and audio-route authority' >&2
exit 1
