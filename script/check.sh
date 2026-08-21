#!/usr/bin/env bash
set -euo pipefail

script_dir="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"

if [[ "$#" -eq 1 && "$1" == "--scaffold" ]]; then
	exec "$script_dir/check_scaffold.sh"
fi

if [[ "$#" -eq 1 && "$1" == "--m0-native" ]]; then
	exec "$script_dir/check_m0_native.sh"
fi

if [[ "$#" -eq 1 && "$1" == "--m0" ]]; then
	exec "$script_dir/check_m0.sh"
fi

if [[ "$#" -eq 1 && "$1" == "--state-fixtures" ]]; then
	exec "$script_dir/check_state_fixtures.sh"
fi

if [[ "$#" -eq 1 && "$1" == "--m1-xcode-fixture" ]]; then
	exec "$script_dir/check_m1_xcode_fixture.sh"
fi

if [[ "$#" -eq 1 && "$1" == "--m1-storage" ]]; then
	exec "$script_dir/check_m1_storage.sh"
fi

if [[ "$#" -eq 1 && "$1" == "--m1-media-open" ]]; then
	exec "$script_dir/check_m1_media_open.sh"
fi

printf '%s\n' \
	"NOT_IMPLEMENTED: full repository check" \
	"Use './script/check.sh --scaffold' for founding structure, './script/check.sh --m0-native' for the bounded native proof, './script/check.sh --m0' for complete Milestone 0, './script/check.sh --state-fixtures' for deterministic post-M0 state truth, './script/check.sh --m1-xcode-fixture' for the pre-capture Xcode checkpoint, './script/check.sh --m1-storage' for durable session preparation, or './script/check.sh --m1-media-open' for the pre-capture media-writer protocol and native macOS 13 build metadata." \
	"Neither receipt proves the website, capture, recovery, deployment, signing, or release." >&2
exit 64
