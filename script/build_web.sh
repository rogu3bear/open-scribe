#!/usr/bin/env bash
set -euo pipefail

script_dir="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
exec "$script_dir/not_implemented.sh" "Leptos and Cloudflare website build"
