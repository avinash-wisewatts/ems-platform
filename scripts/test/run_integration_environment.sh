#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

echo "============================================================"
echo "WiseWatts EMS canonical integration test"
echo "============================================================"

echo
echo "[1/14] Resetting disposable test database..."
"${SCRIPT_DIR}/test_database.sh" reset

echo
echo "[2/14] Deploying canonical database..."
"${SCRIPT_DIR}/deploy_test_database.sh"

echo
echo "[3/14] Running canonical baseline assertions..."
"${SCRIPT_DIR}/assert_canonical_database.sh"

echo
echo "[4/14] Baselining historical migrations and applying forward migrations..."
"${SCRIPT_DIR}/apply_test_migrations.sh"

echo
echo "[5/14] Running energy-register semantic assertions..."
"${SCRIPT_DIR}/assert_energy_register_semantics.sh"

echo
echo "[6/14] Running interval-quality rule assertions..."
"${SCRIPT_DIR}/assert_interval_quality_rules.sh"

echo
echo "[7/14] Running site energy-balance assertions..."
"${SCRIPT_DIR}/assert_site_energy_balance.sh"

echo
echo "[8/14] Running asset hierarchy-rollup assertions..."
"${SCRIPT_DIR}/assert_asset_hierarchy_rollups.sh"

echo
echo "[9/14] Running asset meter-coverage assertions..."
"${SCRIPT_DIR}/assert_asset_meter_coverage.sh"

echo
echo "[10/14] Running controlled lifecycle-status assertions..."
"${SCRIPT_DIR}/assert_controlled_lifecycle_statuses.sh"

echo
echo "[11/14] Running shared tenant/site validation assertions..."
"${SCRIPT_DIR}/assert_shared_tenant_site_validation.sh"

echo
echo "[12/14] Running independent organization-creation assertions..."
"${SCRIPT_DIR}/assert_independent_organization_creation.sh"

echo
echo "[13/14] Running demand-capability resolution assertions..."
"${SCRIPT_DIR}/assert_demand_capability_resolution.sh"

echo
echo
echo "[asset-demand regression] Verifying automatic ASSET demand with SITE demand disabled..."
"${SCRIPT_DIR}/assert_asset_demand_automatic_decoupling.sh"

echo
echo "[connectivity-semantics] Running Phase 1A connectivity semantic contract assertions..."
"${SCRIPT_DIR}/assert_connectivity_semantic_contract.sh"

echo
echo "[energy-consumption-semantics] Running Phase 1B energy consumption semantic contract assertions..."
"${SCRIPT_DIR}/assert_energy_consumption_semantic_contract.sh"

echo
echo "[job-schedule-canonical] Running Phase 1C job-schedule canonical contract assertions..."
"${SCRIPT_DIR}/assert_job_schedule_canonical.sh"

echo
echo "[grafana-energy-routing] Running Phase 1D Grafana energy resolution-routing contract assertions..."
"${SCRIPT_DIR}/assert_grafana_energy_routing_daily_tier.sh"

echo
echo "[energy-consumption-per-flow-quality] Running Phase 1E-A per-flow quality persistence contract assertions..."
"${SCRIPT_DIR}/assert_energy_consumption_per_flow_quality_contract.sh"

echo
echo "[energy-consumption-backfill] Running Phase 1E-B historical backfill contract assertions..."
"${SCRIPT_DIR}/assert_energy_consumption_backfill_contract.sh"

echo
echo "[reference-data-completeness-guard] Running reference-data completeness guard assertions..."
"${SCRIPT_DIR}/assert_reference_data_completeness_guard.sh"

echo "[14/14] Verifying migration ledger..."
ledger="$(
    docker compose \
        -f "${PROJECT_ROOT}/compose.test.yaml" \
        exec -T timescaledb-test \
        psql \
        -X \
        -U ems_admin \
        -d ems_test \
        -tAc "
            SELECT to_regclass('admin.schema_migrations');
        "
)"

if [[ "${ledger}" != "admin.schema_migrations" ]]; then
    echo "ERROR: Migration ledger was not created." >&2
    exit 1
fi

echo "Migration ledger verified: ${ledger}"

echo
echo "============================================================"
echo "Canonical integration-test database is ready."
echo "============================================================"
