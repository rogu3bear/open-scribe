#!/usr/bin/env bash
set -euo pipefail

deployment_target="13.0"
expected_arch="arm64"

if [[ "$#" -ne 2 ]]; then
	printf 'usage: %s <static-library> <app-binary>\n' "$0" >&2
	exit 64
fi

static_library="$1"
app_binary="$2"

for tool in ar file lipo rg vtool; do
	command -v "$tool" >/dev/null || {
		printf 'MACOS_ARTIFACT_FLOOR_RED: required tool is unavailable: %s\n' "$tool" >&2
		exit 1
	}
done

version_is_at_most() {
	awk -v actual="$1" -v maximum="$2" '
		BEGIN {
			split(actual, actual_parts, ".")
			split(maximum, maximum_parts, ".")
			for (part_index = 1; part_index <= 3; part_index += 1) {
				actual_part = actual_parts[part_index] + 0
				maximum_part = maximum_parts[part_index] + 0
				if (actual_part < maximum_part) exit 0
				if (actual_part > maximum_part) exit 1
			}
			exit 0
		}
	'
}

audit_macho() {
	local artifact="$1"
	local label="$2"
	local architectures
	local build_metadata
	local platforms
	local minimum_versions

	architectures="$(lipo -archs "$artifact" 2>/dev/null)" || {
		printf 'MACOS_ARTIFACT_FLOOR_RED: %s is not inspectable Mach-O code\n' "$label" >&2
		exit 1
	}
	[[ "$architectures" == "$expected_arch" ]] || {
		printf 'MACOS_ARTIFACT_FLOOR_RED: %s has architectures %s; expected %s\n' \
			"$label" "$architectures" "$expected_arch" >&2
		exit 1
	}

	build_metadata="$(vtool -show-build "$artifact" 2>/dev/null)" || {
		printf 'MACOS_ARTIFACT_FLOOR_RED: %s has no readable build-version metadata\n' "$label" >&2
		exit 1
	}
	platforms="$(awk '$1 == "platform" { print $2 }' <<<"$build_metadata")"
	minimum_versions="$(awk '$1 == "minos" { print $2 }' <<<"$build_metadata")"

	[[ -n "$platforms" && -n "$minimum_versions" ]] || {
		printf 'MACOS_ARTIFACT_FLOOR_RED: %s lacks platform or minimum-version metadata\n' "$label" >&2
		exit 1
	}
	while IFS= read -r platform; do
		[[ "$platform" == "MACOS" || "$platform" == "1" ]] || {
			printf 'MACOS_ARTIFACT_FLOOR_RED: %s targets unexpected platform %s\n' \
				"$label" "$platform" >&2
			exit 1
		}
	done <<<"$platforms"
	while IFS= read -r minimum_version; do
		version_is_at_most "$minimum_version" "$deployment_target" || {
			printf 'MACOS_ARTIFACT_FLOOR_RED: %s requires macOS %s; floor is %s\n' \
				"$label" "$minimum_version" "$deployment_target" >&2
			exit 1
		}
	done <<<"$minimum_versions"
}

[[ -f "$static_library" && -f "$app_binary" ]] || {
	printf '%s\n' 'MACOS_ARTIFACT_FLOOR_RED: static library or app binary is missing' >&2
	exit 1
}

inspection_root="$(mktemp -d "${TMPDIR:-/tmp}/open-scribe-macos-floor.XXXXXX")"
trap 'rm -rf "$inspection_root"' EXIT
(
	cd "$inspection_root"
	ar -x "$static_library"
)

shopt -s nullglob
archive_members=("$inspection_root"/*)
[[ "${#archive_members[@]}" -gt 0 ]] || {
	printf '%s\n' 'MACOS_ARTIFACT_FLOOR_RED: static library contains no members' >&2
	exit 1
}

mach_o_count=0
for archive_member in "${archive_members[@]}"; do
	if file -b "$archive_member" | rg -q '^Mach-O 64-bit object arm64'; then
		audit_macho "$archive_member" "$(basename "$static_library"):$(basename "$archive_member")"
		mach_o_count=$((mach_o_count + 1))
	fi
done
[[ "$mach_o_count" -gt 0 ]] || {
	printf '%s\n' 'MACOS_ARTIFACT_FLOOR_RED: static library contains no arm64 Mach-O members' >&2
	exit 1
}

audit_macho "$app_binary" "$(basename "$app_binary")"

printf '%s\n' \
	'MACOS_ARTIFACT_FLOOR_GREEN' \
	"architecture=$expected_arch" \
	"maximum_macos=$deployment_target" \
	"archive_macho_members=$mach_o_count"
