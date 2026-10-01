#!/usr/bin/env bash
set -euo pipefail

# Stages the real-model and local-only proof inputs in a durable directory:
# the pinned speech model from its manifest origin, verified by length and
# SHA-256, and the spoken samples the tests document, regenerated with `say`
# and `afconvert`. It writes `env.sh` for the variables those proofs read.
# This is an explicit developer fetch; the app itself never downloads.

script_dir="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
repo_root="$(CDPATH='' cd -- "$script_dir/.." && pwd -P)"
[[ "$#" == 1 && "$1" == /* ]] || {
	printf '%s\n' 'usage: stage_proof_inputs.sh /absolute/durable/directory' >&2
	exit 64
}
directory="$1"
mkdir -p "$directory"
model_id='whisper-small.en-q5_1'
entry="$(jq -ce --arg id "$model_id" '.models[] | select(.id == $id)' "$repo_root/docs/models/manifest.v1.json")"
file_name="$(jq -r '.file_name' <<<"$entry")"
origin="$(jq -r '.download_origins[0]' <<<"$entry")"
expected_sha256="$(jq -r '.sha256' <<<"$entry")"
expected_bytes="$(jq -r '.byte_length' <<<"$entry")"
model="$directory/$file_name"

model_matches() {
	[[ -f "$1" && ! -L "$1" && "$(stat -f '%z' "$1")" == "$expected_bytes" &&
	"$(shasum -a 256 "$1" | cut -d ' ' -f 1)" == "$expected_sha256" ]]
}
if ! model_matches "$model"; then
	partial="$model.partial"
	rm -f -- "$partial"
	curl --fail --location --proto '=https' --tlsv1.2 --silent --show-error --output "$partial" "$origin"
	model_matches "$partial" || {
		rm -f -- "$partial"
		printf '%s\n' 'PROOF_INPUTS_RED: the downloaded model does not match its manifest' >&2
		exit 1
	}
	mv -- "$partial" "$model"
fi

sentence='Open Scribe keeps the recording safe before it writes a transcript.'
say -v Samantha -o "$directory/speech.wav" --file-format=WAVE --data-format=LEF32@16000 "$sentence"
say -v Samantha -o "$directory/speech48.caf" --file-format=caff --data-format=LEI16@48000 "$sentence"
rm -f -- "$directory/speech-stereo.m4a"
afconvert -f m4af -d aac@48000 -c 2 "$directory/speech48.caf" "$directory/speech-stereo.m4a"

{
	printf 'export OPEN_SCRIBE_WHISPER_MODEL=%q\n' "$model"
	printf 'export OPEN_SCRIBE_WHISPER_SPEECH_WAV=%q\n' "$directory/speech.wav"
	printf 'export OPEN_SCRIBE_WHISPER_SPEECH_CAF=%q\n' "$directory/speech48.caf"
	printf 'export OPEN_SCRIBE_WHISPER_SPEECH_M4A=%q\n' "$directory/speech-stereo.m4a"
	printf 'export TEST_RUNNER_OPEN_SCRIBE_WHISPER_MODEL=%q\n' "$model"
	printf 'export TEST_RUNNER_OPEN_SCRIBE_WHISPER_SPEECH_CAF=%q\n' "$directory/speech48.caf"
	printf 'export TEST_RUNNER_OPEN_SCRIBE_WHISPER_SPEECH_M4A=%q\n' "$directory/speech-stereo.m4a"
	printf 'export OPEN_SCRIBE_LOCAL_PROOF_MODEL=%q\n' "$model"
	printf 'export OPEN_SCRIBE_LOCAL_PROOF_SPEECH_CAF=%q\n' "$directory/speech48.caf"
} >"$directory/env.sh"
printf 'PROOF_INPUTS_READY\nmodel_sha256=%s\nenv=%s\n' "$expected_sha256" "$directory/env.sh"
