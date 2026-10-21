#!/usr/bin/env bash
set -euo pipefail

script_dir="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
repo_root="$(CDPATH='' cd -- "$script_dir/.." && pwd -P)"
cd "$repo_root"
if [[ "$#" != 1 || "$1" != /* ]]; then
	printf 'usage: bash script/check_imported_audio_round_trip.sh /absolute/new-output-directory\n' >&2
	exit 64
fi
output_dir="$1"
mkdir "$output_dir"
source_head="$(git rev-parse HEAD)"
source_fingerprint() {
	ruby -rdigest -e '
		paths = Dir["crates/**/*.{rs,toml}"] + Dir["apps/macos/Sources/**/*.{swift,h,modulemap}"]
		paths += ["Cargo.toml", "Cargo.lock", ".cargo/config.toml", "rust-toolchain.toml",
		          "apps/macos/Tests/Offscreen/ImportedAudioRoundTrip.swift", ARGV.fetch(0)]
		paths.sort.uniq.each { |p| puts "#{Digest::SHA256.file(p).hexdigest}  #{p}" }
	' "$script_dir/check_imported_audio_round_trip.sh"
}
source_fingerprint >"$output_dir/source-before.sha256"

# Never launches the app or a test host. Only synthesized audio and a fresh,
# marked library are used; no model, device, network or private data is read.
export CARGO_NET_OFFLINE=true
export CARGO_INCREMENTAL=0
bash "$script_dir/check_apple_toolchain.sh"
export CARGO_TARGET_DIR="$output_dir/rust"
rust_library="$(bash "$script_dir/build_rust_macos.sh" "$CARGO_TARGET_DIR")"
cargo build --locked --offline --target aarch64-apple-darwin \
	-p open-scribe-store --example validate_imported_companion
CARGO_TARGET_DIR="$CARGO_TARGET_DIR" cargo run --locked --offline -p open-scribe-uniffi \
	--features bindgen --bin uniffi-bindgen -- generate \
	--library "$rust_library" --language swift --out-dir "$output_dir/bindings"
xcrun swift-format format --in-place "$output_dir/bindings/OpenScribeCore.swift"
xcrun clang-format -i "$output_dir/bindings/OpenScribeFFI.h"
cmp "$output_dir/bindings/OpenScribeCore.swift" apps/macos/Sources/OpenScribeApp/Generated/OpenScribeCore.swift
cmp "$output_dir/bindings/OpenScribeFFI.h" apps/macos/Sources/OpenScribeFFI/include/OpenScribeFFI.h

sources=(
	apps/macos/Sources/OpenScribeApp/Generated/OpenScribeCore.swift
	apps/macos/Sources/OpenScribeApp/Media/BoundedAudioImport.swift
	apps/macos/Sources/OpenScribeApp/Media/PlaybackByteSources.swift
	apps/macos/Sources/OpenScribeApp/Media/TranscriptionCompanionDecoder.swift
	apps/macos/Sources/OpenScribeApp/Models/SpeechFailurePresentation.swift
	apps/macos/Sources/OpenScribeApp/Support/DiagnosticPrivacy.swift
	apps/macos/Tests/Offscreen/ImportedAudioRoundTrip.swift
)
fingerprint() {
	ruby -rdigest -e 'ARGV.each { |p| puts "#{Digest::SHA256.file(p).hexdigest}  #{p}" }' \
		"${sources[@]}" "$script_dir/check_imported_audio_round_trip.sh" \
		crates/open-scribe-store/examples/validate_imported_companion.rs \
		"$rust_library" apps/macos/Sources/OpenScribeFFI/include/OpenScribeFFI.h
}
fingerprint >"$output_dir/inputs-before.sha256"
xcrun swiftc -warnings-as-errors -swift-version 6 -target arm64-apple-macosx13.0 -parse-as-library \
	-I apps/macos/Sources/OpenScribeFFI -L "$(dirname "$rust_library")" \
	-lc++ -framework Accelerate -framework Metal -framework MetalKit -framework Foundation \
	"${sources[@]}" -o "$output_dir/imported-audio-round-trip"
"$output_dir/imported-audio-round-trip" "$output_dir/fixtures" \
	"$CARGO_TARGET_DIR/aarch64-apple-darwin/debug/examples/validate_imported_companion"
mkdir -m 700 "$output_dir/existing-directory"
mkdir -m 700 "$output_dir/existing-directory/Library"
printf '%s\n' 'do not modify existing library' >"$output_dir/existing-directory/Library/sentinel"
sentinel_sha="$(shasum -a 256 "$output_dir/existing-directory/Library/sentinel")"
if "$output_dir/imported-audio-round-trip" "$output_dir/existing-directory" \
	"$CARGO_TARGET_DIR/aarch64-apple-darwin/debug/examples/validate_imported_companion" \
	>"$output_dir/existing-directory-refusal.log" 2>&1; then
	printf 'CODEC_ISOLATION_RED: executable accepted an existing directory\n' >&2
	exit 1
fi
[[ ! -e "$output_dir/existing-directory/.codec-proof" ]]
[[ ! -e "$output_dir/existing-directory/Library/Library.sqlite3" ]]
[[ "$sentinel_sha" == "$(shasum -a 256 "$output_dir/existing-directory/Library/sentinel")" ]]
printf '%s\n' 'CODEC_EXISTING_DIRECTORY_REFUSED_BEFORE_STORAGE'
fingerprint >"$output_dir/inputs-after.sha256"
cmp "$output_dir/inputs-before.sha256" "$output_dir/inputs-after.sha256"
source_fingerprint >"$output_dir/source-after.sha256"
cmp "$output_dir/source-before.sha256" "$output_dir/source-after.sha256"
[[ "$source_head" == "$(git rev-parse HEAD)" ]]
printf '%s\n' 'IMPORTED_AUDIO_COMPONENT_CHECK_GREEN' \
	"source_head=$source_head" \
	'proof=synthetic_Apple_codec,production_import,isolated_Rust_storage,descriptor_decoder,exact_Rust_input_validation' \
	'excludes=app,test_host,scenes,devices,private_audio,ASR,UI,permissions,contributor_qualification,signing,release'
