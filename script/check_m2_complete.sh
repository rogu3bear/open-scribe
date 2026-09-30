#!/usr/bin/env bash
set -euo pipefail

printf '%s\n' \
	'M2_COMPLETE_HOLD' \
	'partial_source_surfaces=durable_conversation_library,recovered_and_imported_media_identity,safe_playback,final_transcription_pipeline_without_engine,model_catalog_verification' \
	'unqualified_source=speaker_correction,search,transcript_audio_synchronization_for_capture_timelines,transcript_text_exports' \
	'qualification=none at the M2 completion plane' \
	'missing=local_transcription_engine,live_draft_transcript,speaker_diarization,imported_audio_seek,imported_m4a_transcription,audio_exports,session_manifest,portable_package' \
	'next=integrate a local engine, then qualify transcript, speaker review, search, sync, and export without weakening durable media authority' >&2
exit 1
