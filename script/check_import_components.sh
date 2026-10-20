#!/usr/bin/env bash
set -euo pipefail

script_dir="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
repo_root="$(CDPATH='' cd -- "$script_dir/.." && pwd -P)"
cd "$repo_root"

if [[ "$#" != 1 || "$1" != /* ]]; then
	printf 'usage: bash script/check_import_components.sh /absolute/new-output-directory\n' >&2
	exit 64
fi
output_dir="$1"
# mkdir refuses existing directories and symlinks without replacing evidence.
mkdir "$output_dir"

# This is a command-line component check. It never builds or launches the app,
# a test host, a scene, a picker or a device, and it cannot admit a candidate.
# Callers use normal Disk Guard admission; all dependencies must exist locally.
export CARGO_NET_OFFLINE=true
export CARGO_INCREMENTAL=0
bash "$script_dir/check_apple_toolchain.sh"
rust_target_dir="$output_dir/rust"
rust_library="$(bash "$script_dir/build_rust_macos.sh" "$rust_target_dir")"
CARGO_TARGET_DIR="$rust_target_dir" cargo run --locked --offline -p open-scribe-uniffi \
	--features bindgen --bin uniffi-bindgen -- generate \
	--library "$rust_library" --language swift --out-dir "$output_dir/bindings"
xcrun swift-format format --in-place "$output_dir/bindings/OpenScribeCore.swift"
xcrun clang-format -i "$output_dir/bindings/OpenScribeFFI.h"
cmp "$output_dir/bindings/OpenScribeCore.swift" apps/macos/Sources/OpenScribeApp/Generated/OpenScribeCore.swift
cmp "$output_dir/bindings/OpenScribeFFI.h" apps/macos/Sources/OpenScribeFFI/include/OpenScribeFFI.h

sources=(
	apps/macos/Sources/OpenScribeApp/Generated/OpenScribeCore.swift
	apps/macos/Sources/OpenScribeApp/Support/StructuredNativeIO.swift
	apps/macos/Sources/OpenScribeApp/Media/BoundedAudioImport.swift
	apps/macos/Sources/OpenScribeApp/Media/ImportedMediaAuthorityAdapter.swift
	apps/macos/Sources/OpenScribeApp/Models/TranscriptPlaybackProjection.swift
	apps/macos/Tests/Offscreen/ImportComponents.swift
)
proof_inputs=(
	"${sources[@]}" "$script_dir/check_import_components.sh" "$rust_library"
	apps/macos/Sources/OpenScribeFFI/include/OpenScribeFFI.h
	apps/macos/Sources/OpenScribeFFI/module.modulemap
)
source_head="$(git rev-parse HEAD)"
fingerprint() {
	ruby -rdigest -e 'ARGV.each { |p| puts "#{Digest::SHA256.file(p).hexdigest}  #{p}" }' "${proof_inputs[@]}"
}
fingerprint >"$output_dir/inputs-before.sha256"
xcrun swiftc -warnings-as-errors -swift-version 6 -target arm64-apple-macosx13.0 -parse-as-library \
	-I apps/macos/Sources/OpenScribeFFI -L "$(dirname "$rust_library")" \
	-lc++ -framework Accelerate -framework Metal -framework MetalKit -framework Foundation \
	"${sources[@]}" -o "$output_dir/import-components"
"$output_dir/import-components"
fingerprint >"$output_dir/inputs-after.sha256"
cmp "$output_dir/inputs-before.sha256" "$output_dir/inputs-after.sha256"
[[ "$source_head" == "$(git rev-parse HEAD)" ]]
printf '%s\n' 'IMPORT_COMPONENT_CHECK_GREEN' \
	"source_head=$source_head" \
	"input_manifest_sha256=$(shasum -a 256 "$output_dir/inputs-after.sha256" | cut -d ' ' -f 1)" \
	"executable_sha256=$(shasum -a 256 "$output_dir/import-components" | cut -d ' ' -f 1)" \
	'proof=injected_production_import_adapter,commit_preserving_cancellation,batch_order,partial_failure,pause_resume,capture_hold,clock_arithmetic,overlapping_turns' \
	'excludes=app,test_host,scenes,storage,real_audio,ASR,renderer,UI,permissions,contributor_qualification,signing,release'
