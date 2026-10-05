#!/usr/bin/env bash
# Remove the local Open Scribe install and its privacy decisions. Recordings
# in ~/Library/Application Support/Open Scribe are left in place.
set -euo pipefail

export PATH="/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:${PATH:-}"

script_dir="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
repo_root="$(CDPATH='' cd -- "$script_dir/.." && pwd)"
bundle_id="app.open-scribe.dev"
destination="/Applications/Open Scribe.app"
lsregister="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

[[ "$#" -eq 0 ]] || {
	printf '%s\n' "usage: $0" >&2
	exit 64
}

if pgrep -x OpenScribeApp >/dev/null; then
	osascript -e "tell application id \"$bundle_id\" to quit" >/dev/null 2>&1 || true
	attempt=0
	while pgrep -x OpenScribeApp >/dev/null && [[ "$attempt" -lt 10 ]]; do
		sleep 0.3
		attempt=$((attempt + 1))
	done
	if pgrep -x OpenScribeApp >/dev/null; then
		pkill -x OpenScribeApp || true
		sleep 0.4
	fi
fi

tccutil reset All "$bundle_id"
printf 'PRIVACY_RESET service=All bundle=%s\n' "$bundle_id"

"$lsregister" -dump | awk '
	/^path:/ {
		path = $0
		sub(/^path:[[:space:]]+/, "", path)
		sub(/ \(.*/, "", path)
	}
	/^identifier:[[:space:]]+app\.open-scribe\.dev[[:space:]]*$/ { print path }
' | sort -u | while IFS= read -r path; do
	[[ -n "$path" ]] || continue
	"$lsregister" -u "$path" || true
done

rm -rf "$destination"
rm -rf "$repo_root/dist/Open Scribe.app"
printf 'UNINSTALLED %s\n' "$destination"
printf 'PRESERVED %s\n' "$HOME/Library/Application Support/Open Scribe"
