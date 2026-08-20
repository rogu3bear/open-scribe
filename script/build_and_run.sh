#!/usr/bin/env bash
set -euo pipefail

script_dir="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
repo_root="$(CDPATH='' cd -- "$script_dir/.." && pwd)"
macos_root="$repo_root/apps/macos"
app_name="OpenScribeApp"
bundle_id="app.open-scribe.dev"
mode="run"

for argument in "$@"; do
	case "$argument" in
	--verify | --logs | --debug | --telemetry)
		if [[ "$mode" != "run" ]]; then
			printf '%s\n' 'Choose exactly one mode.' >&2
			exit 64
		fi
		mode="$argument"
		;;
	*)
		printf 'usage: %s [--verify|--logs|--debug|--telemetry]\n' "$0" >&2
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

binary_dir="$(swift build --package-path "$macos_root" --show-bin-path)"
app_bundle="$repo_root/dist/Open Scribe.app"
app_binary="$app_bundle/Contents/MacOS/$app_name"
pid_file="$macos_root/.build/$app_name.pid"

if [[ -f "$pid_file" ]]; then
	prior_pid="$(<"$pid_file")"
	if [[ "$prior_pid" =~ ^[0-9]+$ ]]; then
		prior_command="$(ps -p "$prior_pid" -o comm= 2>/dev/null || true)"
		if [[ "$prior_command" == "$app_binary" ]]; then
			kill "$prior_pid"
		fi
	fi
	rm -f "$pid_file"
fi

rm -rf "$app_bundle"
mkdir -p "$app_bundle/Contents/MacOS"
mkdir -p "$app_bundle/Contents/Resources"
cp "$binary_dir/OpenScribeApp" "$app_binary"
cp "$macos_root/Support/Info.plist" "$app_bundle/Contents/Info.plist"
chmod +x "$app_binary"

launch_app() {
	if [[ "$#" -gt 0 ]]; then
		/usr/bin/open -n "$app_bundle" --args "$@"
	else
		/usr/bin/open -n "$app_bundle"
	fi
	for _ in {1..20}; do
		app_pid="$(pgrep -n -f "$app_binary" || true)"
		if [[ -n "$app_pid" ]]; then
			printf '%s\n' "$app_pid" >"$pid_file"
			return 0
		fi
		sleep 0.2
	done
	printf '%s\n' 'M0_NATIVE_RED: exact app process was not observed after launch' >&2
	return 1
}

case "$mode" in
run)
	launch_app
	;;
--verify)
	swift test --package-path "$macos_root"
	launch_app --m0-proof-settings
	app_pid="$(<"$pid_file")"
	observed_command="$(ps -p "$app_pid" -o comm=)"
	[[ "$observed_command" == "$app_binary" ]] || {
		printf '%s\n' 'M0_NATIVE_RED: observed process does not match staged app' >&2
		exit 1
	}
	scene_receipt=""
	for _ in {1..20}; do
		scene_receipt="$(/usr/bin/log show \
			--last 1m \
			--info \
			--style compact \
			--predicate "processIdentifier == $app_pid && subsystem == \"$bundle_id\" && category == \"Scenes\"" \
			2>/dev/null)"
		if [[ "$scene_receipt" == *"scene=primary"* && "$scene_receipt" == *"scene=menu-bar"* && "$scene_receipt" == *"scene=settings"* ]]; then
			break
		fi
		sleep 0.2
	done
	[[ "$scene_receipt" == *"scene=primary"* && "$scene_receipt" == *"scene=menu-bar"* && "$scene_receipt" == *"scene=settings"* ]] || {
		printf '%s\n' 'M0_NATIVE_RED: primary, menu-bar, or settings scene telemetry was not observed' >&2
		exit 1
	}
	printf '%s\n' \
		'M0_NATIVE_GREEN' \
		'proof=rust_staticlib,uniffi_regeneration,swift_build,swift_binding_test,development_app_assembly,exact_process_launch,primary_scene_log,menu_bar_scene_log,settings_scene_log' \
		'excludes=capture,persistence,recovery,transcription,diarization,ocr,context,providers,llm,signing,notarization,release'
	;;
--debug)
	exec lldb -- "$app_binary"
	;;
--logs)
	launch_app
	exec /usr/bin/log stream --info --style compact --predicate "process == \"$app_name\""
	;;
--telemetry)
	launch_app
	exec /usr/bin/log stream --info --style compact --predicate "subsystem == \"$bundle_id\""
	;;
esac
