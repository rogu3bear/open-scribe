#!/usr/bin/env bash
set -euo pipefail

printf '%s\n' \
	'M4_COMPLETE_HOLD' \
	'available_contracts=provider_policy_and_release_architecture_contracts' \
	'unqualified_source=two_phase_deletion,manifest_rendered_capability_status,adr_0015_routes_csp_and_headers,development_sandbox_without_network_entitlement,identifier_only_app_logs' \
	'qualification=none at the M4 completion plane' \
	'missing=local_only_network_denial_runtime,provider_category_authorization,deletion_runtime,secret_handling,content_free_diagnostics_check,capability_true_website_equality' \
	'protected=provider_credentials,network_denial_runtime,production_deployment' \
	'next=implement and qualify privacy, provider, deletion, and capability-equality behavior' >&2
exit 1
