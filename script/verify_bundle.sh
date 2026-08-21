#!/usr/bin/env bash
set -euo pipefail

script_dir="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
exec "$script_dir/not_implemented.sh" "macOS bundle, signing, and notarization verification"
