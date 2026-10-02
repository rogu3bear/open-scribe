#!/usr/bin/env bash
set -euo pipefail

script_dir="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
repo_root="$(CDPATH='' cd -- "$script_dir/.." && pwd)"
cd "$repo_root"
mode="${1:---all}"
case "$mode" in --all | --coarse | --fixtures | --entitlements) ;; *) exit 64 ;; esac

if [[ "$mode" == --all || "$mode" == --coarse ]]; then
	# rg exit 1 means no match; distinguish a match from an inspection error.
	if rg -ni '\b(pcm|cmsamplebuffer|avaudiopcmbuffer|audio_buffer|video_frame|waveform|meter|pointer)\b' \
		crates/open-scribe-uniffi/src; then
		printf '%s\n' 'NATIVE_CONTRACT_RED: hot-path media or telemetry crossed UniFFI' >&2
		exit 1
	elif [[ "$?" != 1 ]]; then
		exit 1
	fi
fi
if [[ "$mode" == --all || "$mode" == --fixtures ]]; then
	# Imports carry one bounded sample-rate scalar; no prefixed/suffixed alias.
	coarse_status=0
	coarse_matches="$(rg --no-config -n -o \
		'\w*(effective_frame|audio_buffer|video_frame|pointer_sample|meter_value|waveform_value|sample_rate)\w*' \
		crates/open-scribe-uniffi/src apps/macos/Sources/OpenScribeApp/Generated/OpenScribeCore.swift)" || coarse_status=$?
	coarse_violations="$(grep -v ':sample_rate_hz$' <<<"$coarse_matches" || true)"
	if ((coarse_status > 1)) || [[ -n "$coarse_violations" ]]; then
		printf '%s\n' "$coarse_violations" 'STATE_FIXTURES_RED: frame-rate or media payload vocabulary crossed the coarse UniFFI surface' >&2
		exit 1
	fi
fi
if [[ "$mode" == --all || "$mode" == --entitlements ]]; then
	info_plist="apps/macos/Support/Info.plist"
	entitlements="apps/macos/Support/OpenScribe.entitlements"
	plutil -lint "$info_plist" "$entitlements" >/dev/null
	for key in app-sandbox device.audio-input files.user-selected.read-write; do
		[[ "$(/usr/libexec/PlistBuddy -c "Print :com.apple.security.$key" "$entitlements")" == true ]] || exit 1
	done
	[[ "$(plutil -p "$entitlements" | rg -c '=>')" == 3 ]] || exit 1
	[[ "$(/usr/libexec/PlistBuddy -c 'Print :NSMicrophoneUsageDescription' "$info_plist")" == 'Open Scribe uses the microphone only when you explicitly start a recording that includes it.' ]] || exit 1
	build_settings="$(xcodebuild -project apps/macos/OpenScribe.xcodeproj \
		-target OpenScribeApp -configuration Debug -showBuildSettings)"
	for expected in \
		'CODE_SIGN_ENTITLEMENTS = Support/OpenScribe.entitlements' \
		'ENABLE_APP_SANDBOX = YES' 'ENABLE_HARDENED_RUNTIME = YES'; do
		rg -Fq "$expected" <<<"$build_settings" || {
			printf 'NATIVE_CONTRACT_RED: effective Xcode setting absent: %s\n' "$expected" >&2
			exit 1
		}
	done
fi
printf 'NATIVE_CONTRACT_GREEN: %s\n' "$mode"
