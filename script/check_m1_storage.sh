#!/usr/bin/env bash
set -euo pipefail

script_dir="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
repo_root="$(CDPATH='' cd -- "$script_dir/.." && pwd)"
cd "$repo_root"

cargo clippy --locked -p open-scribe-store --all-targets -- -D warnings
cargo test --locked -p open-scribe-store
cargo check --locked \
	--target wasm32-unknown-unknown \
	-p open-scribe-types \
	-p open-scribe-domain \
	-p open-scribe-evidence
"$script_dir/check_state_fixtures.sh"
"$script_dir/check_m1_xcode_fixture.sh"
"$script_dir/check_m0.sh"
git diff --check

printf '%s\n' \
	'M1_STORAGE_PREPARATION_GREEN' \
	'proof=sqlite_schema_v2,wal_full_sync,foreign_keys,single_owned_writer,uuidv7_session_intent,bounded_chained_journal,durable_directory_sync,deterministic_interruption_injection,restart_projection_repair,repeated_recovery_convergence,truncated_and_tampered_journal_rejection,symlink_rejection,no_recording_without_media,shared_wasm,state_fixtures,xcode_fixture,m0_regression,diff_hygiene' \
	'excludes=swift_media_writer,real_forced_process_termination,capture,recording,permissions,finalization,playable_recovery,disk_pressure,trash,import,transcription,context,intelligence,signing,notarization,distribution,release'
