#!/usr/bin/env bash
set -euo pipefail

printf '%s\n' \
	'M3_COMPLETE_HOLD' \
	'available_contracts=founding_evidence_types_and_architecture_contract,evidence_ref_v1_validation' \
	'qualification=none at the M3 completion plane' \
	'missing=explicit_context_scope,sparse_context_reduction,evidence_resolution_and_lineage,claim_adjudication,multi_display_runtime' \
	'protected=screen_recording_permission_and_real_display_scope_runtime' \
	'next=implement and qualify bounded context and navigable evidence lineage' >&2
exit 1
