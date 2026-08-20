#!/usr/bin/env bash
set -euo pipefail

capability="$1"

printf '%s\n' \
	"NOT_IMPLEMENTED: $capability" \
	"This lane is outside the implemented Milestone 0 native proof." \
	"Implement and prove this lane before changing this script to return success." >&2
exit 64
