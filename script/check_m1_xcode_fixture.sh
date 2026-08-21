#!/usr/bin/env bash
set -euo pipefail

script_dir="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
repo_root="$(CDPATH='' cd -- "$script_dir/.." && pwd)"
cd "$repo_root"

"$script_dir/check_apple_toolchain.sh"
"$script_dir/check_scaffold.sh"
cargo test --locked -p open-scribe-uniffi
"$script_dir/build_and_run.sh" --verify
git diff --check

printf '%s\n' \
	'M1_XCODE_FIXTURE_GREEN' \
	'proof=pinned_apple_toolchain,scaffold,rust_status_test,generated_binding_consistency,xcode_app_target,xcode_test_host,swift_binding_test,exact_development_app_launch,primary_scene_log,menu_bar_scene_log,settings_scene_log,diff_hygiene' \
	'excludes=capture,permissions,entitlements,persistence,recovery,media,playback,import,transcription,diarization,ocr,context,providers,llm,signing,notarization,distribution,release'
