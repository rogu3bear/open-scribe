#!/usr/bin/env bash
set -euo pipefail

script_dir="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
repo_root="$(CDPATH='' cd -- "$script_dir/.." && pwd)"
cd "$repo_root"

expected_swift="$(<.swift-version)"
expected_xcode="$(<.xcode-version)"
expected_xcode_build="$(<.xcode-build-version)"

actual_swift="$(swift --version | sed -n 's/.*Apple Swift version \([^ ]*\).*/\1/p' | head -n 1)"
actual_xcode="$(xcodebuild -version | sed -n 's/^Xcode //p')"
actual_xcode_build="$(xcodebuild -version | sed -n 's/^Build version //p')"

[[ "$actual_swift" == "$expected_swift" ]] || {
	printf 'APPLE_TOOLCHAIN_RED: Swift %s is active; expected %s\n' "$actual_swift" "$expected_swift" >&2
	exit 1
}
[[ "$actual_xcode" == "$expected_xcode" ]] || {
	printf 'APPLE_TOOLCHAIN_RED: Xcode %s is active; expected %s\n' "$actual_xcode" "$expected_xcode" >&2
	exit 1
}
[[ "$actual_xcode_build" == "$expected_xcode_build" ]] || {
	printf 'APPLE_TOOLCHAIN_RED: Xcode build %s is active; expected %s\n' "$actual_xcode_build" "$expected_xcode_build" >&2
	exit 1
}

printf '%s\n' \
	'APPLE_TOOLCHAIN_GREEN' \
	"swift=$actual_swift" \
	"xcode=$actual_xcode" \
	"xcode_build=$actual_xcode_build"
