#!/usr/bin/env bash
set -euo pipefail

# A name leaves its list only when a receipt under this candidate re-verifies.
# Source tests, a copied marker, and a receipt for another build do not count.
# Green does not admit release.
script_dir="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
repo_root="$(CDPATH='' cd -- "$script_dir/.." && pwd -P)"
cd "$repo_root"
# shellcheck source=script/candidate.sh
source "$script_dir/candidate.sh"
qualified_candidate=0
if [[ "$#" != 0 ]]; then
	[[ "$#" == 2 && "$1" == --candidate ]] ||
		candidate_fail 'usage: check_m2_complete.sh [--candidate /absolute/candidate.json]'
	candidate_load "$2"
	candidate_require_checks
	qualified_candidate=1
fi

has_behavior() {
	[[ "$qualified_candidate" == 1 ]] || return 1
	local name="$1" receipt="$candidate_root/m2-$1.json" root log marker
	[[ -f "$receipt" && ! -L "$receipt" ]] || return 1
	jq -e --arg candidate "$candidate_record_digest" --arg name "$name" '
      .schema == 1 and .candidate_sha256 == $candidate and .behavior == $name
      and .result == "M2_BEHAVIOR_GREEN" and .release_admission == false
      and (.proof_root | type == "string")
      and (.log_sha256 | test("^[a-f0-9]{64}$"))' "$receipt" >/dev/null || return 1
	root="$(jq -r '.proof_root' "$receipt")"
	[[ "$root" == "$candidate_root/m2-$name."* && -d "$root" && ! -L "$root" &&
		"$(CDPATH='' cd -- "$root" && pwd -P)" == "$root" ]] || return 1
	log="$root/harness.log"
	[[ -f "$log" && ! -L "$log" && "$(candidate_sha256 "$log")" == "$(jq -r '.log_sha256' "$receipt")" ]] || return 1
	marker="M2_$(printf '%s' "$name" | tr '[:lower:]' '[:upper:]')_GREEN"
	rg -Fxq "$marker" "$log" && rg -Fxq "candidate_record_sha256=$candidate_record_digest" "$log"
}

behaviors=(
	live_draft_transcript
	speaker_diarization
	in_app_model_download_and_removal
	compressed_import_package_restore
	two_hour_package_round_trip
)
sources=(
	local_whisper_final_transcription
	speaker_correction
	search
	transcript_audio_synchronization_for_capture_timelines
	imported_audio_seek
	compressed_m4a_transcription_via_decoded_companion
	transcript_text_exports
	audio_exports
	session_manifest
	portable_package_writer_and_verifier
	portable_package_import_round_trip_for_pcm_sessions
)
missing=()
proven=()
unqualified=()
qualified_sources=()
for name in "${behaviors[@]}"; do
	if has_behavior "$name"; then proven+=("$name"); else missing+=("$name"); fi
done
for name in "${sources[@]}"; do
	if has_behavior "$name"; then qualified_sources+=("$name"); else unqualified+=("$name"); fi
done
join_items() {
	local IFS=,
	printf '%s' "$*"
}
proven_text="$(join_items ${proven[@]+"${proven[@]}"})"
missing_text="$(join_items ${missing[@]+"${missing[@]}"})"
qualified_source_text="$(join_items ${qualified_sources[@]+"${qualified_sources[@]}"})"
unqualified_text="$(join_items ${unqualified[@]+"${unqualified[@]}"})"
[[ "$qualified_candidate" != 1 ]] || candidate_receipt
if [[ "$qualified_candidate" == 1 && ${#missing[@]} -eq 0 && ${#unqualified[@]} -eq 0 ]]; then
	printf '%s\n' \
		'M2_COMPLETE_GREEN' \
		"candidate_checks_qualified=$qualified_candidate" \
		"qualified_behaviors=$proven_text" \
		"qualified_source=$qualified_source_text" \
		'partial_source_surfaces=durable_conversation_library,recovered_and_imported_media_identity,safe_playback,model_catalog_verification,chosen_file_model_install_without_in_app_download_or_removal' \
		"unqualified_source=$unqualified_text" \
		'qualification=candidate_receipts' \
		"missing=$missing_text" \
		'release_admission=false' >&2
	exit 0
fi
printf '%s\n' \
	'M2_COMPLETE_HOLD' \
	"candidate_checks_qualified=$qualified_candidate" \
	"qualified_behaviors=$proven_text" \
	"qualified_source=$qualified_source_text" \
	'partial_source_surfaces=durable_conversation_library,recovered_and_imported_media_identity,safe_playback,model_catalog_verification,chosen_file_model_install_without_in_app_download_or_removal' \
	"unqualified_source=$unqualified_text" \
	'qualification=none at the M2 completion plane' \
	"missing=$missing_text" \
	'next=bind one candidate receipt to each missing behavior and each unqualified source surface; source tests do not clear a name' \
	'release_admission=false' >&2
exit 1
