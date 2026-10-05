#!/usr/bin/env bash
# Replace the one local Open Scribe install and clear its privacy decisions
# so the next microphone or screen capture asks again. This is not a signed
# release and does not publish anything.
set -euo pipefail

export PATH="/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:${PATH:-}"

script_dir="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
repo_root="$(CDPATH='' cd -- "$script_dir/.." && pwd)"
bundle_id="app.open-scribe.dev"
destination="/Applications/Open Scribe.app"
lsregister="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
default_source="$repo_root/apps/macos/.build/xcode/Build/Products/Debug/OpenScribeApp.app"

usage() {
	printf '%s\n' "usage: $0 [/absolute/path/OpenScribeApp.app]" >&2
	exit 64
}

[[ "$#" -le 1 ]] || usage
source_app="${1:-$default_source}"
[[ "$source_app" == /* && -d "$source_app" && ! -L "$source_app" ]] || usage
[[ -x "$source_app/Contents/MacOS/OpenScribeApp" ]] || {
	printf 'INSTALL_RED: built app is missing its executable: %s\n' "$source_app" >&2
	exit 1
}

quit_app() {
	if ! pgrep -x OpenScribeApp >/dev/null; then
		return 0
	fi
	osascript -e "tell application id \"$bundle_id\" to quit" >/dev/null 2>&1 || true
	local _attempt
	for _attempt in 1 2 3 4 5 6 7 8 9 10; do
		pgrep -x OpenScribeApp >/dev/null || return 0
		sleep 0.3
	done
	pkill -x OpenScribeApp || true
	sleep 0.4
	if pgrep -x OpenScribeApp >/dev/null; then
		printf 'INSTALL_RED: Open Scribe is still running\n' >&2
		exit 1
	fi
}

registered_copies() {
	"$lsregister" -dump | awk '
		/^path:/ {
			path = $0
			sub(/^path:[[:space:]]+/, "", path)
			sub(/ \(.*/, "", path)
		}
		/^identifier:[[:space:]]+app\.open-scribe\.dev[[:space:]]*$/ { print path }
	' | sort -u
}

quit_app
tccutil reset All "$bundle_id"
printf 'PRIVACY_RESET service=All bundle=%s\n' "$bundle_id"

while IFS= read -r path; do
	[[ -n "$path" ]] || continue
	"$lsregister" -u "$path" || true
done < <(registered_copies)

rm -rf "$destination"
ditto "$source_app" "$destination"
# The packaging directory is not a second install.
rm -rf "$repo_root/dist/Open Scribe.app"
"$lsregister" -f "$destination"

printf 'INSTALLED %s\n' "$destination"
printf 'REGISTERED\n'
registered_copies
open "$destination"
