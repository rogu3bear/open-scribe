#!/usr/bin/env bash
set -euo pipefail

script_dir="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
repo_root="$(CDPATH='' cd -- "$script_dir/.." && pwd)"
cd "$repo_root"

cargo fmt --all --check
cargo test --locked -p open-scribe-store runtime_library_snapshot
cargo test --locked \
	-p open-scribe-types \
	-p open-scribe-domain \
	-p open-scribe-core \
	-p open-scribe-uniffi
cargo check --locked --target wasm32-unknown-unknown \
	-p open-scribe-types \
	-p open-scribe-domain \
	-p open-scribe-evidence

if rg -n \
	'effective_frame|audio_buffer|video_frame|pointer_sample|meter_value|waveform_value|sample_rate' \
	crates/open-scribe-uniffi/src apps/macos/Sources/OpenScribeApp/Generated/OpenScribeCore.swift; then
	printf '%s\n' 'STATE_FIXTURES_RED: frame-rate or media payload vocabulary crossed the coarse UniFFI surface' >&2
	exit 1
fi

"$script_dir/build_and_run.sh" --verify
git diff --check

printf '%s\n' \
	'STATE_FIXTURES_GREEN' \
	'proof=rust_fixture_catalog,deterministic_transition_errors,durability_guard,coherent_runtime_library_snapshot,wasm_safe_types_domain_evidence,coarse_uniffi_round_trip,fresh_generated_bindings,swift_fixture_mapping,shared_menu_live_store,reviewed_symbol_fallbacks,ready_starting_non_recording,accessibility_truth,keyboard_inspection,exact_unsigned_app_launch,diff_hygiene' \
	'excludes=real_capture,full_media_journal_io,full_persistence,recovery_execution,transcription,diarization,ocr,context,providers,llm,deployment,signing,notarization,release'
