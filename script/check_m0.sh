#!/usr/bin/env bash
set -euo pipefail

script_dir="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
repo_root="$(CDPATH='' cd -- "$script_dir/.." && pwd)"
cd "$repo_root"

"$script_dir/build_web.sh"
"$script_dir/check_m0_native.sh"
git diff --check

printf '%s\n' \
	'M0_COMPLETE_GREEN' \
	'proof=pinned_toolchains,website_ssr,website_hydration,hashed_assets,worker_bundle,shared_crates_wasm,native_uniffi,native_swift_scenes,exact_checkout_diff_hygiene' \
	'excludes=capture,persistence,recovery,transcription,diarization,ocr,context,providers,llm,cloudflare_deploy,signing,notarization,distribution,release,milestone_1'
