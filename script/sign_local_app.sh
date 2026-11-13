#!/usr/bin/env bash
# Give one local Open Scribe app a stable Developer ID signature so microphone
# permission stays with app.open-scribe.dev across later builds of that same
# identity. This does not notarize, reset privacy, or publish.
set -euo pipefail

export PATH="/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:${PATH:-}"

bundle_id="app.open-scribe.dev"

usage() {
	printf '%s\n' "usage: $0 /absolute/path/to/OpenScribeApp.app" >&2
	exit 64
}

[[ "$#" -eq 1 ]] || usage
app="${1:-}"
[[ "$app" == /* && -d "$app" && ! -L "$app" ]] || usage
[[ -x "$app/Contents/MacOS/OpenScribeApp" ]] || {
	printf 'SIGN_RED: app is missing its executable: %s\n' "$app" >&2
	exit 1
}
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Contents/Info.plist")" == "$bundle_id" ]] || {
	printf '%s\n' 'SIGN_RED: only the ordinary app.open-scribe.dev bundle is signed this way' >&2
	exit 64
}

identity="$(
	/usr/bin/security find-identity -p codesigning -v |
		/usr/bin/sed -n 's/.*"\(Developer ID Application:[^"]*\)".*/\1/p'
)"
identity_count="$(printf '%s\n' "$identity" | /usr/bin/grep -c . || true)"
[[ "$identity_count" -eq 1 ]] || {
	printf 'SIGN_RED: expected one Developer ID Application identity, found %s\n' "$identity_count" >&2
	exit 1
}

sign_item() {
	local item="$1"
	/usr/bin/codesign --force --sign "$identity" --timestamp=none "$item"
}

while IFS= read -r item; do
	[[ -n "$item" && "$item" != "$app" ]] || continue
	sign_item "$item"
done < <(
	/usr/bin/find "$app" -depth \( -name '*.dylib' -o -name '*.xctest' -o -name '*.framework' \) -print
)

/usr/bin/codesign --force --sign "$identity" --identifier "$bundle_id" --timestamp=none "$app"
/usr/bin/codesign --verify --strict --verbose=2 "$app" >/dev/null

details="$(/usr/bin/codesign -dv "$app" 2>&1)"
requirement="$(/usr/bin/codesign -d -r- "$app" 2>&1)"
printf '%s\n' "$details" | /usr/bin/awk '
	BEGIN { identifier = ""; team = ""; flags = "" }
	/^Identifier=/ { identifier = substr($0, 12) }
	/^TeamIdentifier=/ { team = substr($0, 16) }
	/^Signature=/ { signature = substr($0, 11) }
	/^CodeDirectory/ && /flags=/ {
		flags = $0
		sub(/^.*flags=/, "", flags)
		sub(/ .*/, "", flags)
	}
	END {
		printf "SIGNED identifier=%s\n", identifier
		printf "SIGNED team=%s\n", team
		printf "SIGNED signature=%s\n", signature
		printf "SIGNED flags=%s\n", flags
	}
'
printf '%s\n' "$requirement" | /usr/bin/awk '
	/designated =>/ {
		if ($0 ~ /identifier "app\.open-scribe\.dev"/ && $0 ~ /anchor apple generic/ && $0 !~ /cdhash/) {
			print "SIGNED requirement=stable"
		} else {
			print "SIGNED requirement=unexpected"
			exit 1
		}
	}
'
printf '%s\n' 'PRIVACY_RESET=no'
