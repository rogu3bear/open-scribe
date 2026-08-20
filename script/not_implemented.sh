#!/usr/bin/env bash
set -euo pipefail

capability="$1"

printf '%s\n' \
	"NOT_IMPLEMENTED: $capability" \
	"This repository contains a founding scaffold only." \
	"Implement and prove this lane before changing this script to return success." >&2
exit 64
