#!/usr/bin/env bash
set -euo pipefail

printf '%s\n' \
	'M2_COMPLETE_HOLD' \
	'partial_source_surfaces=durable_conversation_library,recovered_and_imported_media_identity,safe_playback,model_catalog_verification,chosen_file_model_install_without_in_app_download_or_removal' \
	'unqualified_source=local_whisper_final_transcription,speaker_correction,search,transcript_audio_synchronization_for_capture_timelines,imported_audio_seek,compressed_m4a_transcription_via_decoded_companion,transcript_text_exports,audio_exports,session_manifest,portable_package_writer_and_verifier,portable_package_import_round_trip_for_pcm_sessions' \
	'qualification=none at the M2 completion plane' \
	'missing=live_draft_transcript,speaker_diarization,in_app_model_download_and_removal,compressed_import_package_restore,two_hour_package_round_trip' \
	'next=qualify local transcription, speaker review, search, sync, and export on a candidate; then add live drafts, diarization, in-app model management, and compressed-import package restore' >&2
exit 1
