#!/usr/bin/env bash
set -euo pipefail

printf '%s\n' \
	'M4_COMPLETE_HOLD' \
	'available_contracts=provider_policy_and_release_architecture_contracts' \
	'unqualified_source=two_phase_deletion,manifest_rendered_capability_status,adr_0015_routes_csp_and_headers,development_sandbox_without_network_entitlement,identifier_only_app_logs,local_only_workflow_proof' \
	'observed=ip_denied_local_workflow_on_the_development_build,content_free_stdout_stderr_and_public_unified_log,no_networking_api_in_source' \
	'qualification=none at the M4 completion plane' \
	'missing=candidate_bound_local_only_run,provider_category_authorization,system_trash_deletion_runtime,secret_handling,crash_report_content_check,capability_true_website_equality,local_intelligence,structured_memory' \
	'protected=provider_credentials,production_deployment' \
	'next=bind the local-only proof to a candidate; then providers, secrets, and meeting memory once local intelligence exists' >&2
exit 1
