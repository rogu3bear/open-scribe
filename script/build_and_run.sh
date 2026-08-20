#!/usr/bin/env bash
set -euo pipefail

script_dir="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
repo_root="$(CDPATH='' cd -- "$script_dir/.." && pwd)"
macos_root="$repo_root/apps/macos"
verify=false
show_logs=false

for argument in "$@"; do
	case "$argument" in
	--verify)
		verify=true
		;;
	--logs)
		show_logs=true
		;;
	--debug | --telemetry)
		# M0 is always a debug build and has no telemetry subsystem.
		;;
	*)
		printf 'Unknown argument: %s\n' "$argument" >&2
		exit 64
		;;
	esac
done

cd "$repo_root"
mkdir -p "$macos_root/.build"
bindings_tmp="$(mktemp -d "$macos_root/.build/uniffi.XXXXXX")"
trap 'rm -rf "$bindings_tmp"' EXIT

cargo build --locked -p open-scribe-uniffi
cargo run --locked -p open-scribe-uniffi \
	--features bindgen \
	--bin uniffi-bindgen \
	-- generate \
	--library target/debug/libopen_scribe_uniffi.a \
	--language swift \
	--out-dir "$bindings_tmp"
xcrun swift-format format --in-place "$bindings_tmp/OpenScribeCore.swift"
xcrun clang-format -i "$bindings_tmp/OpenScribeFFI.h"

cmp "$bindings_tmp/OpenScribeCore.swift" \
	"$macos_root/Sources/OpenScribeApp/Generated/OpenScribeCore.swift" || {
	printf '%s\n' 'M0_NATIVE_RED: generated Swift binding is stale' >&2
	exit 1
}
cmp "$bindings_tmp/OpenScribeFFI.h" \
	"$macos_root/Sources/OpenScribeFFI/include/OpenScribeFFI.h" || {
	printf '%s\n' 'M0_NATIVE_RED: generated C binding is stale' >&2
	exit 1
}

swift build --package-path "$macos_root"

if [[ "$verify" == true ]]; then
	swift test --package-path "$macos_root"
fi

binary_dir="$(swift build --package-path "$macos_root" --show-bin-path)"
app_bundle="$macos_root/.build/Open Scribe.app"
app_binary="$app_bundle/Contents/MacOS/OpenScribeApp"

pkill -x OpenScribeApp 2>/dev/null || true
rm -rf "$app_bundle"
mkdir -p "$app_bundle/Contents/MacOS"
mkdir -p "$app_bundle/Contents/Resources"
cp "$binary_dir/OpenScribeApp" "$app_binary"
cp "$macos_root/Support/Info.plist" "$app_bundle/Contents/Info.plist"

open -n "$app_bundle"

if [[ "$verify" == true ]]; then
	launch_observed=false
	for _ in {1..20}; do
		if pgrep -x OpenScribeApp >/dev/null; then
			launch_observed=true
			break
		fi
		sleep 0.2
	done

	if [[ "$launch_observed" != true ]]; then
		printf '%s\n' 'M0_NATIVE_RED: app process was not observed after launch' >&2
		exit 1
	fi

	printf '%s\n' \
		'M0_NATIVE_GREEN' \
		'proof=rust_staticlib,uniffi_regeneration,swift_build,swift_binding_test,development_app_assembly,local_process_launch' \
		'excludes=capture,persistence,recovery,transcription,diarization,ocr,context,providers,llm,signing,notarization,release'
fi

if [[ "$show_logs" == true ]]; then
	printf '%s\n' 'M0 has no runtime logging or telemetry subsystem.'
fi
