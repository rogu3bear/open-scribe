#!/usr/bin/env bash
set -euo pipefail

printf '%s\n' \
	'M2_COMPLETE_HOLD' \
	'partial_source_surfaces=durable_conversation_library,recovered_and_imported_media_identity,safe_playback' \
	'qualification=none at the M2 completion plane' \
	'missing=local_transcription,speaker_diarization,speaker_correction,search,transcript_audio_synchronization,export' \
	'next=implement and qualify the local transcript and speaker-review milestone without weakening durable media authority' >&2
exit 1
