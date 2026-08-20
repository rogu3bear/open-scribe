#!/usr/bin/env bash
set -euo pipefail

script_dir="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"

if [[ "$#" -eq 1 && "$1" == "--scaffold" ]]; then
	exec "$script_dir/check_scaffold.sh"
fi

if [[ "$#" -eq 1 && "$1" == "--m0-native" ]]; then
	exec "$script_dir/check_m0_native.sh"
fi

printf '%s\n' \
	"NOT_IMPLEMENTED: full repository check" \
	"Use './script/check.sh --scaffold' for founding structure or './script/check.sh --m0-native' for the bounded native proof." \
	"Neither receipt proves the website, capture, recovery, deployment, signing, or release." >&2
exit 64
