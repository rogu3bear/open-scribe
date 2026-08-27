#!/usr/bin/env bash
set -euo pipefail

script_dir="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
repo_root="$(CDPATH='' cd -- "$script_dir/.." && pwd)"
signing_policy="$repo_root/docs/release/signing-policy.v1.json"

usage() {
	printf '%s\n' \
		'BUNDLE_VERIFY_USAGE: ./script/verify_bundle.sh <Open Scribe.app>' \
		'BUNDLE_VERIFY_USAGE: ./script/verify_bundle.sh <Open-Scribe-<semver>-arm64.dmg> <previously-verified-Open Scribe.app>' >&2
	exit 64
}

[[ "$#" -eq 1 || "$#" -eq 2 ]] || usage
artifact="$1"
[[ -e "$artifact" && ! -L "$artifact" ]] || {
	printf 'BUNDLE_VERIFY_INVALID: artifact is missing or is a symlink: %s\n' "$artifact" >&2
	exit 2
}
artifact="$(CDPATH='' cd -- "$(dirname -- "$artifact")" && pwd)/$(basename -- "$artifact")"
mounted_path=""
verification_root="$(mktemp -d "${TMPDIR:-/tmp}/open-scribe-bundle-verification.XXXXXX")"

command -v jq >/dev/null 2>&1 || {
	printf 'BUNDLE_VERIFY_RED: required verifier is unavailable: jq\n' >&2
	rm -rf "$verification_root"
	exit 1
}

[[ -f "$signing_policy" && ! -L "$signing_policy" ]] ||
	{
		printf 'BUNDLE_VERIFY_RED: approved signing policy is unavailable\n' >&2
		rm -rf "$verification_root"
		exit 1
	}
approved_team_id="$(jq -r '.team_id // ""' "$signing_policy")"
approved_common_name="$(jq -r '.developer_id_common_name // ""' "$signing_policy")"
approved_certificate_sha="$(jq -r '.certificate_sha256 // ""' "$signing_policy")"
approved_sparkle_key="$(jq -r '.sparkle_public_key // ""' "$signing_policy")"
if ! jq -e \
	'.schema == "open-scribe.signing-policy/v1"
     and (.team_id | test("^[A-Z0-9]{10}$"))
     and (.developer_id_common_name | type == "string" and length > 0)
     and (.certificate_sha256 | test("^[0-9a-f]{64}$"))
     and (.sparkle_public_key | type == "string" and length > 0)' \
	"$signing_policy" >/dev/null; then
	printf 'BUNDLE_VERIFY_RED: approved signing policy is invalid\n' >&2
	rm -rf "$verification_root"
	exit 1
fi

cleanup_mount() {
	if [[ -n "$mounted_path" ]]; then
		hdiutil detach "$mounted_path" >/dev/null 2>&1 || true
		rmdir "$mounted_path" >/dev/null 2>&1 || true
		mounted_path=""
	fi
}

cleanup_all() {
	cleanup_mount
	rm -rf "$verification_root"
}
trap cleanup_all EXIT

fail() {
	printf 'BUNDLE_VERIFY_RED: %s\n' "$1" >&2
	exit 1
}

require_tool() {
	command -v "$1" >/dev/null 2>&1 || fail "required verifier is unavailable: $1"
}

verify_signing_authority() {
	local signed_path="$1"
	local label="$2"
	local details
	local authority
	local team
	local timestamp
	local certificate_prefix="$verification_root/${label//[^A-Za-z0-9]/-}-certificate-"
	local certificate_sha

	details="$(codesign -d --verbose=4 "$signed_path" 2>&1)"
	authority="$(sed -n 's/^Authority=//p' <<<"$details" | head -n 1)"
	team="$(sed -n 's/^TeamIdentifier=//p' <<<"$details" | head -n 1)"
	timestamp="$(sed -n 's/^Timestamp=//p' <<<"$details" | head -n 1)"
	[[ "$authority" == "Developer ID Application: $approved_common_name ($approved_team_id)" ]] ||
		fail "$label signer is not the approved Developer ID Application authority"
	[[ "$team" == "$approved_team_id" ]] || fail "$label team does not match signing policy"
	[[ -n "$timestamp" && "$timestamp" != "none" ]] || fail "$label lacks a secure signing timestamp"
	codesign -d --extract-certificates "$certificate_prefix" "$signed_path" >/dev/null 2>&1 ||
		fail "$label signing certificate could not be extracted"
	[[ -f "${certificate_prefix}0" ]] || fail "$label leaf signing certificate is absent"
	certificate_sha="$(shasum -a 256 "${certificate_prefix}0" | awk '{print $1}')"
	[[ "$certificate_sha" == "$approved_certificate_sha" ]] ||
		fail "$label certificate does not match signing policy"
}

verify_app() {
	local app_path="$1"
	local info_plist="$app_path/Contents/Info.plist"
	local executable="$app_path/Contents/MacOS/Open Scribe"
	local signature_details
	local bundle_id
	local version
	local build
	local architectures
	local entitlements
	local entitlements_json
	local sparkle_names
	local feed_url
	local public_key
	local app_team
	local code_path
	local code_details
	local code_team
	local code_entitlements
	local code_mode
	local nested_count=0

	[[ -d "$app_path" && ! -L "$app_path" ]] || fail "application is not a real directory"
	[[ -f "$info_plist" && -f "$executable" ]] || fail "application bundle structure is incomplete"

	codesign --verify --deep --strict --verbose=4 "$app_path" >/dev/null 2>&1 ||
		fail "nested or outer code signature verification failed"
	verify_signing_authority "$app_path" application
	signature_details="$(codesign -d --verbose=4 "$app_path" 2>&1)"
	rg -q 'flags=.*runtime' <<<"$signature_details" || fail "Hardened Runtime is absent"
	if rg -q 'Signature=adhoc|TeamIdentifier=not set' <<<"$signature_details"; then
		fail "application is ad hoc signed or lacks a team identity"
	fi
	app_team="$(sed -n 's/^TeamIdentifier=//p' <<<"$signature_details" | head -n 1)"
	[[ -n "$app_team" ]] || fail "application team identity is unreadable"

	bundle_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$info_plist" 2>/dev/null || true)"
	version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$info_plist" 2>/dev/null || true)"
	build="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$info_plist" 2>/dev/null || true)"
	[[ "$bundle_id" == "app.open-scribe" ]] || fail "production bundle identifier is not app.open-scribe"
	[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "bundle version is not release SemVer"
	[[ "$build" =~ ^[1-9][0-9]*$ ]] || fail "bundle build is not a positive decimal"
	feed_url="$(/usr/libexec/PlistBuddy -c 'Print :SUFeedURL' "$info_plist" 2>/dev/null || true)"
	public_key="$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "$info_plist" 2>/dev/null || true)"
	[[ "$feed_url" == "https://open-scribe.app/updates/appcast.xml" ]] ||
		fail "Sparkle feed URL is absent or noncanonical"
	[[ -n "$public_key" ]] || fail "Sparkle public key is absent"
	[[ "$public_key" == "$approved_sparkle_key" ]] ||
		fail "Sparkle public key does not match signing policy"
	for required_key in SUEnableInstallerLauncherService SURequireSignedFeed SUVerifyUpdateBeforeExtraction; do
		[[ "$(/usr/libexec/PlistBuddy -c "Print :$required_key" "$info_plist" 2>/dev/null || true)" == "true" ]] ||
			fail "required Sparkle policy is absent: $required_key"
	done
	[[ "$(/usr/libexec/PlistBuddy -c 'Print :SUSignedFeedFailureExpirationInterval' "$info_plist" 2>/dev/null || true)" == "0" ]] ||
		fail "signed-feed failure expiration is not zero"
	if [[ "$(/usr/libexec/PlistBuddy -c 'Print :SUEnableDownloaderService' "$info_plist" 2>/dev/null || true)" == "true" ]]; then
		fail "Sparkle downloader service must remain disabled"
	fi

	architectures="$(lipo -archs "$executable" 2>/dev/null || true)"
	[[ "$architectures" == "arm64" ]] || fail "application executable is not arm64-only"

	entitlements="$(codesign -d --entitlements :- "$app_path" 2>/dev/null || true)"
	[[ -n "$entitlements" ]] || fail "application entitlements are unreadable"
	entitlements_json="$(plutil -convert json -o - - <<<"$entitlements" 2>/dev/null || true)"
	[[ -n "$entitlements_json" ]] || fail "application entitlements are malformed"
	for required in \
		com.apple.security.app-sandbox \
		com.apple.security.device.audio-input \
		com.apple.security.files.user-selected.read-write \
		com.apple.security.network.client; do
		plutil -extract "$required" raw -o - - <<<"$entitlements" 2>/dev/null | rg -q '^true$' ||
			fail "required production entitlement is absent: $required"
	done
	for forbidden in \
		com.apple.security.get-task-allow \
		com.apple.security.cs.disable-library-validation \
		com.apple.security.cs.allow-unsigned-executable-memory \
		com.apple.security.network.server; do
		if plutil -extract "$forbidden" raw -o - - <<<"$entitlements" >/dev/null 2>&1; then
			fail "forbidden production entitlement is present: $forbidden"
		fi
	done
	sparkle_names="com.apple.security.temporary-exception.mach-lookup.global-name"
	jq -e \
		--arg sparkle_names "$sparkle_names" \
		'keys | sort == ([
          "com.apple.security.app-sandbox",
          "com.apple.security.device.audio-input",
          "com.apple.security.files.user-selected.read-write",
          "com.apple.security.network.client",
          $sparkle_names
        ] | sort)' <<<"$entitlements_json" >/dev/null ||
		fail "production entitlements contain missing or unexpected keys"
	jq -e \
		--arg sparkle_names "$sparkle_names" \
		--arg spks "$bundle_id-spks" \
		--arg spki "$bundle_id-spki" \
		'.[$sparkle_names] | sort == ([$spks, $spki] | sort)' <<<"$entitlements_json" >/dev/null ||
		fail "Sparkle Mach lookup exceptions are missing or broader than required"

	while IFS= read -r -d '' code_path; do
		if ! file -b "$code_path" | rg -q '^Mach-O'; then
			continue
		fi
		case "$code_path" in
		"$app_path/Contents/MacOS/"* | "$app_path/Contents/Frameworks/"* | "$app_path/Contents/XPCServices/"*) ;;
		*) fail "unexpected Mach-O location: $code_path" ;;
		esac
		code_mode="$(stat -f '%Lp' "$code_path")"
		if (((8#$code_mode & 8#022) != 0)); then
			fail "Mach-O is group- or world-writable: $code_path"
		fi
		codesign --verify --strict --verbose=4 "$code_path" >/dev/null 2>&1 ||
			fail "nested Mach-O signature verification failed: $code_path"
		code_details="$(codesign -d --verbose=4 "$code_path" 2>&1)"
		code_team="$(sed -n 's/^TeamIdentifier=//p' <<<"$code_details" | head -n 1)"
		[[ "$code_team" == "$app_team" ]] || fail "nested Mach-O has a different team: $code_path"
		code_entitlements="$(codesign -d --entitlements :- "$code_path" 2>/dev/null || true)"
		for forbidden in \
			com.apple.security.get-task-allow \
			com.apple.security.cs.disable-library-validation \
			com.apple.security.cs.allow-unsigned-executable-memory \
			com.apple.security.network.server; do
			if [[ -n "$code_entitlements" ]] &&
				plutil -extract "$forbidden" raw -o - - <<<"$code_entitlements" >/dev/null 2>&1; then
				fail "nested Mach-O has forbidden entitlement $forbidden: $code_path"
			fi
		done
		nested_count=$((nested_count + 1))
	done < <(find "$app_path/Contents" -type f -print0)
	((nested_count > 0)) || fail "application contains no verifiable Mach-O code"

	xcrun stapler validate "$app_path" >/dev/null 2>&1 || fail "application notarization staple is invalid"
	spctl --assess --type execute --verbose=4 "$app_path" >/dev/null 2>&1 ||
		fail "Gatekeeper rejected the application"

	printf '%s\n' \
		'BUNDLE_APP_GREEN' \
		"path=$app_path" \
		"bundle_id=$bundle_id" \
		"version=$version" \
		"build=$build" \
		"team_id=$app_team" \
		"architecture=$architectures" \
		"nested_macho_count=$nested_count" \
		"sha256=$(shasum -a 256 "$executable" | awk '{print $1}')" \
		'proof=production_identity,arm64,hardened_runtime,nested_signatures,required_and_forbidden_entitlements,stapled_ticket,Gatekeeper' \
		'excludes=clean_machine_launch,capture,recovery,transcription,signature_after_use,update,canonical_download,release'
}

verify_dmg() {
	local dmg_path="$1"
	local reference_app="$2"
	local mount_root
	local app_path
	local image_version
	local contained_version
	local reference_version
	local contained_build
	local reference_build
	local reference_identity
	local contained_identity
	local reference_requirement
	local contained_requirement
	local reference_cdhash
	local contained_cdhash

	[[ -f "$dmg_path" ]] || fail "disk image is not a regular file"
	[[ -d "$reference_app" && ! -L "$reference_app" ]] ||
		fail "previously verified reference application is unavailable"
	verify_app "$reference_app"
	hdiutil verify "$dmg_path" >/dev/null 2>&1 || fail "disk image integrity verification failed"
	codesign --verify --strict --verbose=4 "$dmg_path" >/dev/null 2>&1 ||
		fail "disk image signature verification failed"
	verify_signing_authority "$dmg_path" disk-image
	xcrun stapler validate "$dmg_path" >/dev/null 2>&1 || fail "disk image notarization staple is invalid"
	spctl --assess --type open --context context:primary-signature --verbose=4 "$dmg_path" >/dev/null 2>&1 ||
		fail "Gatekeeper rejected the disk image"

	mount_root="$(mktemp -d "${TMPDIR:-/tmp}/open-scribe-dmg.XXXXXX")"
	mounted_path="$mount_root"
	hdiutil attach -readonly -nobrowse -mountpoint "$mount_root" "$dmg_path" >/dev/null ||
		fail "disk image could not be mounted read-only"
	[[ -L "$mount_root/Applications" ]] || fail "disk image lacks the Applications symlink"
	[[ "$(readlink "$mount_root/Applications")" == "/Applications" ]] ||
		fail "Applications symlink does not target /Applications"
	app_path="$mount_root/Open Scribe.app"
	[[ -d "$app_path" ]] || fail "disk image does not contain Open Scribe.app"
	verify_app "$app_path"
	reference_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$reference_app/Contents/Info.plist")"
	contained_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app_path/Contents/Info.plist")"
	reference_build="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$reference_app/Contents/Info.plist")"
	contained_build="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$app_path/Contents/Info.plist")"
	image_version="$(basename "$dmg_path")"
	image_version="${image_version#Open-Scribe-}"
	image_version="${image_version%-arm64.dmg}"
	[[ "$image_version" == "$reference_version" && "$contained_version" == "$reference_version" ]] ||
		fail "disk image filename, reference app, and contained app versions differ"
	[[ "$contained_build" == "$reference_build" ]] ||
		fail "contained app build differs from the previously verified app"
	reference_identity="$(shasum -a 256 "$reference_app/Contents/MacOS/Open Scribe" | awk '{print $1}')"
	contained_identity="$(shasum -a 256 "$app_path/Contents/MacOS/Open Scribe" | awk '{print $1}')"
	[[ "$contained_identity" == "$reference_identity" ]] ||
		fail "contained executable differs from the previously verified app"
	reference_requirement="$(codesign -dr - "$reference_app" 2>&1)"
	contained_requirement="$(codesign -dr - "$app_path" 2>&1)"
	[[ "$contained_requirement" == "$reference_requirement" ]] ||
		fail "contained app designated requirement differs from the reference app"
	reference_cdhash="$(codesign -d --verbose=4 "$reference_app" 2>&1 | sed -n 's/^CDHash=//p' | head -n 1)"
	contained_cdhash="$(codesign -d --verbose=4 "$app_path" 2>&1 | sed -n 's/^CDHash=//p' | head -n 1)"
	[[ -n "$reference_cdhash" && "$contained_cdhash" == "$reference_cdhash" ]] ||
		fail "contained app code-directory hash differs from the reference app"
	cleanup_mount

	printf '%s\n' \
		'BUNDLE_DMG_GREEN' \
		"path=$dmg_path" \
		"sha256=$(shasum -a 256 "$dmg_path" | awk '{print $1}')" \
		'proof=image_integrity,disk_image_signature,stapled_ticket,Gatekeeper,read_only_mount,Applications_link,contained_app_verification,reference_version_build_executable_requirement_cdhash_equality' \
		'excludes=clean_machine_install,capture,recovery,transcription,update,canonical_download,release'
}

for tool in codesign file find jq lipo plutil readlink spctl stat shasum xcrun rg; do
	require_tool "$tool"
done

case "$artifact" in
*.app)
	[[ "$#" -eq 1 ]] || usage
	verify_app "$artifact"
	;;
*.dmg)
	[[ "$#" -eq 2 ]] || usage
	require_tool hdiutil
	reference_app="$2"
	[[ -e "$reference_app" && ! -L "$reference_app" ]] ||
		fail "previously verified reference application is missing or is a symlink"
	reference_app="$(CDPATH='' cd -- "$(dirname -- "$reference_app")" && pwd)/$(basename -- "$reference_app")"
	verify_dmg "$artifact" "$reference_app"
	;;
*) usage ;;
esac
