#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

echo "============================================================"
echo "WiseWatts EMS canonical integration test"
echo "============================================================"

echo
echo "[1/13] Resetting disposable test database..."
"${SCRIPT_DIR}/test_database.sh" reset

echo
echo "[2/13] Deploying canonical database..."
"${SCRIPT_DIR}/deploy_test_database.sh"

echo
echo "[3/13] Running canonical baseline assertions..."
"${SCRIPT_DIR}/assert_canonical_database.sh"

echo
echo "[4/13] Baselining historical migrations and applying forward migrations..."
"${SCRIPT_DIR}/apply_test_migrations.sh"

echo
echo "[5/13] Running energy-register semantic assertions..."
"${SCRIPT_DIR}/assert_energy_register_semantics.sh"

echo
echo "[6/13] Running interval-quality rule assertions..."
"${SCRIPT_DIR}/assert_interval_quality_rules.sh"

echo
echo "[7/13] Running site energy-balance assertions..."
"${SCRIPT_DIR}/assert_site_energy_balance.sh"

echo
echo "[8/13] Running asset hierarchy-rollup assertions..."
"${SCRIPT_DIR}/assert_asset_hierarchy_rollups.sh"

echo
echo "[9/13] Running asset meter-coverage assertions..."
"${SCRIPT_DIR}/assert_asset_meter_coverage.sh"

echo
echo "[10/13] Running controlled lifecycle-status assertions..."
"${SCRIPT_DIR}/assert_controlled_lifecycle_statuses.sh"

echo
echo "[11/13] Running shared tenant/site validation assertions..."
"${SCRIPT_DIR}/assert_shared_tenant_site_validation.sh"

echo
echo "[12/13] Running independent organization-creation assertions..."
"${SCRIPT_DIR}/assert_independent_organization_creation.sh"

echo
echo "[13/13] Verifying migration ledger..."
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
