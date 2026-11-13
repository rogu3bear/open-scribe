#!/usr/bin/env bash
set -euo pipefail

script_dir="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
repo_root="$(CDPATH='' cd -- "$script_dir/.." && pwd -P)"
cd "$repo_root"
# shellcheck source=script/candidate.sh
source "$script_dir/candidate.sh"
qualified_candidate=0
qualified_modes=()
if [[ "$#" != 0 ]]; then
	[[ "$#" == 2 && "$1" == --candidate ]] ||
		candidate_fail 'usage: check_m4_complete.sh [--candidate /absolute/candidate.json]'
	candidate_load "$2"
	candidate_require_checks
	qualified_candidate=1
fi

has_local_only() {
	[[ "$qualified_candidate" == 1 ]] || return 1
	local mode="$1" receipt="$candidate_root/m4-local-only-$1.json" root key path
	[[ -f "$receipt" && ! -L "$receipt" ]] || return 1
	jq -e --arg candidate "$candidate_record_digest" --arg mode "$mode" '
      .schema == 1 and .candidate_sha256 == $candidate and .mode == $mode
      and .result == "M4_LOCAL_ONLY_GREEN" and .release_admission == false
      and .qualification_scope == "development_candidate_only"
      and (.proof_root | type == "string")
      and (.report_sha256 | test("^[a-f0-9]{64}$"))
      and ([.inputs.model_sha256,.inputs.speech_sha256,.logs.stdout,.logs.stderr,.logs.unified]
        | all(type == "string" and test("^[a-f0-9]{64}$")))' "$receipt" >/dev/null || return 1
	root="$(jq -r '.proof_root' "$receipt")"
	[[ "$root" == "$candidate_root/m4-local-only-$mode."* && -d "$root" && ! -L "$root" &&
		"$(CDPATH='' cd -- "$root" && pwd -P)" == "$root" ]] || return 1
	for key in stdout stderr unified; do
		path="$root/$key.log"
		[[ -f "$path" && ! -L "$path" &&
			"$(candidate_sha256 "$path")" == "$(jq -r --arg key "$key" '.logs[$key]' "$receipt")" ]] || return 1
	done
	path="$root/local-only-verified.json"
	[[ -f "$path" && ! -L "$path" &&
		"$(candidate_sha256 "$path")" == "$(jq -r '.report_sha256' "$receipt")" ]] || return 1
	candidate_local_only_report_valid "$path" "$mode" "$(jq -r '.inputs.speech_sha256' "$receipt")"
}
# Re-read committed source in this checkout. A copied script whose repo has no
# diagnostics export proof keeps both names. This is not a candidate receipt.
source_has_markers() {
	local path="$1"
	shift
	[[ -f "$path" && ! -L "$path" ]] || return 1
	local marker
	for marker in "$@"; do
		rg -F -q -- "$marker" "$path" || return 1
	done
}
diagnostics_source_qualified=0
if source_has_markers \
	"$repo_root/apps/macos/Tests/OpenScribeAppTests/DiagnosticsReportTests.swift" \
	'testHostedDiagnosticsExportOmitsConversationContent' \
	'sk-live-example-secret' \
	'crash_report=content_free' \
	'credential' \
	'Export Diagnostics…' \
	'performClick' \
	'AppTelemetry.captureProof' &&
	source_has_markers \
		"$repo_root/apps/macos/Sources/OpenScribeApp/Views/SettingsView.swift" \
		'func exportDiagnostics' \
		'currentReport()' \
		'Export Diagnostics…' &&
	source_has_markers \
		"$repo_root/apps/macos/Sources/OpenScribeApp/Support/DiagnosticsReport.swift" \
		'crash_report=content_free' \
		'crash_report_refused='; then
	diagnostics_source_qualified=1
fi
# The disposable fixture has no provider Settings proof, so the name stays there.
provider_source_qualified=0
if source_has_markers \
	"$repo_root/apps/macos/Tests/OpenScribeAppTests/ProviderAuthorizationTests.swift" \
	'testHostedProviderConfigurationAuthorizesNoCategoryUntilTheUserGrantsOne' \
	'sk-live-example-secret' \
	'Configure provider' \
	'Final transcript' \
	'No outbound request was made.' \
	'Provider configured — no conversation content authorized' \
	'performClick' \
	'assertSecretAbsent' &&
	source_has_markers \
		"$repo_root/apps/macos/Sources/OpenScribeApp/Views/SettingsView.swift" \
		'func prepareReview' \
		'Configure provider' \
		'authorization.configureRemote' \
		'Prepare review' &&
	source_has_markers \
		"$repo_root/apps/macos/Sources/OpenScribeApp/Stores/ProviderAuthorizationModel.swift" \
		'Audio and snapshots are unavailable to remote review.' \
		'func configureRemote(' \
		'func prepare(sessionId:' \
		'materializeContentProviderReview'; then
	provider_source_qualified=1
fi
# Hosted Trash confirm and the interrupted-move launch recovery are one source
# check. Either marker missing restores the runtime name. Not a candidate receipt.
trash_source_qualified=0
if source_has_markers \
	"$repo_root/apps/macos/Tests/OpenScribeAppTests/RecoveredSessionControllerTests.swift" \
	'testHostedDeletionConfirmUsesSystemTrash' \
	'Confirm move to Trash' \
	'performClick' \
	"does not call \`requestDeletion\`" &&
	source_has_markers \
		"$repo_root/apps/macos/Tests/OpenScribeAppTests/TranscriptLibraryModelTests.swift" \
		'testLaunchRecoverySettlesASystemTrashMoveThatStoppedBeforeCompletion' \
		'TranscriptLibraryModel.systemTrash' \
		'recoverOnLaunch' \
		'launch recovery completes without the Trash URL' &&
	source_has_markers \
		"$repo_root/apps/macos/Sources/OpenScribeApp/Stores/TranscriptLibraryModel.swift" \
		'func systemTrash' \
		'trashItem' \
		'completeDeletion'; then
	trash_source_qualified=1
fi
# Disabled local intelligence and stored meeting memory are source checks.
# A copied script whose repo lacks those proofs keeps both names. Neither
# check is a candidate receipt or a claim that a local model exists.
intelligence_source_qualified=0
if source_has_markers \
	"$repo_root/apps/macos/Tests/OpenScribeAppTests/RecoveredSessionControllerTests.swift" \
	'testHostedStructuredMemoryShowsTheStoredDecisionWhileIntelligenceIsOff' \
	'refuseLocalIntelligence' \
	'Intelligence off' \
	'claimsWritten' \
	'ingestMeetingMemoryDelta' &&
	source_has_markers \
		"$repo_root/apps/macos/Sources/OpenScribeApp/Stores/TranscriptLibraryModel.swift" \
		'func refuseLocalIntelligence()' \
		'readout: "Intelligence off"' \
		'claimsWritten: 0' \
		'mode: "disabled"' &&
	source_has_markers \
		"$repo_root/apps/macos/Sources/OpenScribeApp/Views/TranscriptSection.swift" \
		'struct InterpretationSection' \
		'refuseLocalIntelligence()' \
		'label: "Structured memory"'; then
	intelligence_source_qualified=1
fi
memory_source_qualified=0
if source_has_markers \
	"$repo_root/apps/macos/Tests/OpenScribeAppTests/RecoveredSessionControllerTests.swift" \
	'testHostedStructuredMemoryShowsTheStoredDecisionWhileIntelligenceIsOff' \
	'Decisions.' \
	'Loose End' \
	'Structured memory' &&
	source_has_markers \
		"$repo_root/apps/macos/Sources/OpenScribeApp/Stores/TranscriptLibraryModel.swift" \
		'static func text(for claims: [DerivedClaimSummary])' \
		'case "decision": "Decisions"' \
		'case "open_loop", "loose_end": "Open loops"' \
		'This does not create a claim.' &&
	source_has_markers \
		"$repo_root/apps/macos/Sources/OpenScribeApp/Views/TranscriptSection.swift" \
		'StructuredMemory.text(for:' \
		'label: "Structured memory"'; then
	memory_source_qualified=1
fi
# Byte-identical manifests are not enough. Both equality tests must still
# assert that match and that no public label is Available. A copied script
# whose checkout lacks either manifest or either test keeps the name. This
# is not an Available release entry and not a candidate receipt.
equality_source_qualified=0
website_manifest="$repo_root/docs/capabilities/manifest.v1.json"
runtime_manifest="$repo_root/crates/open-scribe-core/runtime-capabilities.v1.json"
if [[ -f "$website_manifest" && ! -L "$website_manifest" &&
	-f "$runtime_manifest" && ! -L "$runtime_manifest" ]] &&
	cmp -s "$website_manifest" "$runtime_manifest" &&
	source_has_markers \
		"$repo_root/crates/open-scribe-core/src/lib.rs" \
		'fn runtime_registry_matches_the_website_claim_manifest' \
		'include_str!("../../../docs/capabilities/manifest.v1.json")' \
		'assert_eq!(website, RUNTIME_CAPABILITY_MANIFEST_JSON)' \
		'pub const RUNTIME_CAPABILITY_MANIFEST_JSON: &str = include_str!("../runtime-capabilities.v1.json")' \
		'claim.public_label != "Available"' \
		'claim.maturity != "Available"' &&
	source_has_markers \
		"$repo_root/web/src/app.rs" \
		'fn website_rows_equal_the_runtime_registry' \
		'include_str!("../../docs/capabilities/manifest.v1.json")' \
		'include_str!("../../crates/open-scribe-core/runtime-capabilities.v1.json")' \
		'assert_eq!(website, runtime)' \
		'assert_eq!(super::capability_rows(), expected)' \
		'*label != "Available"' \
		'fn capability_rows()' \
		'A malformed manifest renders no claims rather than'; then
	equality_source_qualified=1
fi
for mode in synthetic live-context; do
	if has_local_only "$mode"; then qualified_modes+=("$mode"); fi
done
missing_names=()
if ((${#qualified_modes[@]} == 0)); then
	missing_names+=(candidate_bound_local_only_run)
fi
if [[ "$provider_source_qualified" != 1 ]]; then
	missing_names+=(provider_category_authorization)
fi
if [[ "$trash_source_qualified" != 1 ]]; then
	missing_names+=(system_trash_deletion_runtime)
fi
if [[ "$diagnostics_source_qualified" != 1 ]]; then
	missing_names+=(secret_handling crash_report_content_check)
fi
if [[ "$equality_source_qualified" != 1 ]]; then
	missing_names+=(capability_true_website_equality)
fi
if [[ "$intelligence_source_qualified" != 1 ]]; then
	missing_names+=(local_intelligence)
fi
if [[ "$memory_source_qualified" != 1 ]]; then
	missing_names+=(structured_memory)
fi
missing_text="$(
	IFS=,
	printf '%s' "${missing_names[*]-}"
)"
[[ "$qualified_candidate" != 1 ]] || candidate_receipt
qualified_text="$(
	IFS=,
	printf '%s' "${qualified_modes[*]-}"
)"
printf '%s\n' \
	'M4_COMPLETE_HOLD' \
	"candidate_checks_qualified=$qualified_candidate" \
	"qualified_local_only_modes=$qualified_text" \
	'available_contracts=provider_policy_and_release_architecture_contracts' \
	'available_source=two_phase_deletion,manifest_rendered_capability_status,adr_0015_routes_csp_and_headers,explicit_catalog_download_network_client,identifier_only_app_logs,local_only_workflow_proof' \
	"observed_on_candidate=${qualified_text:-none}" \
	'qualification=none at the M4 completion plane' \
	"diagnostics_source_qualified=$diagnostics_source_qualified" \
	'diagnostics_source_plane=committed_source_not_candidate_receipt' \
	"provider_source_qualified=$provider_source_qualified" \
	'provider_source_plane=committed_source_not_candidate_receipt' \
	"trash_source_qualified=$trash_source_qualified" \
	'trash_source_plane=committed_source_not_candidate_receipt' \
	"intelligence_source_qualified=$intelligence_source_qualified" \
	'intelligence_source_plane=committed_source_not_candidate_receipt' \
	"memory_source_qualified=$memory_source_qualified" \
	'memory_source_plane=committed_source_not_candidate_receipt' \
	"equality_source_qualified=$equality_source_qualified" \
	'equality_source_plane=committed_source_not_candidate_receipt' \
	"missing=$missing_text" \
	'protected=provider_credentials,production_deployment' \
	'next=qualify every missing boundary on the candidate; local-only mode does not admit release or optional context it did not exercise' >&2
exit 1
