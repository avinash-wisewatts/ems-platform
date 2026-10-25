#!/usr/bin/env bash
#
# ============================================================
# WiseWatts EMS -- staging-only objects absent (post-deploy gate)
#
# For DEPLOY_ENVIRONMENT=production: every migration that
# postgres/migration_environment_scope.csv scopes away from production
# (309 / 310 / 312) must have no ledger row, none of the objects it creates
# (postgres/migration_environment_scope_objects.csv) may exist, and the
# running admin portal must expose no Reports export route.
#
# Read-only. Any other environment: the gate does not apply and passes
# (staging has these objects by design).
# ============================================================

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
cd "${PROJECT_DIR}" || exit 1

DEPLOY_ENVIRONMENT="${DEPLOY_ENVIRONMENT:-}"
COMPOSE_FILE="${COMPOSE_FILE:-}"
DB_CONTAINER="${DB_CONTAINER:-timescaledb}"
DB_NAME="${DB_NAME:-ems}"
DB_USER="${DB_USER:-ems_admin}"
APP_SERVICE="${APP_SERVICE:-admin-portal}"
SCOPE_FILE="postgres/migration_environment_scope.csv"
OBJECTS_FILE="postgres/migration_environment_scope_objects.csv"

echo "------------------------------------------------------------"
echo "Staging-only objects absent (environment: ${DEPLOY_ENVIRONMENT:-unset})"
echo "------------------------------------------------------------"

if [[ "${DEPLOY_ENVIRONMENT}" != "production" ]]; then
    echo "[PASS] not production: the gate does not apply."
    exit 0
fi

for file in "${SCOPE_FILE}" "${OBJECTS_FILE}"; do
    if [[ ! -f "${file}" ]]; then
        echo "[FAIL] ${file} is missing."
        exit 1
    fi
done

compose() {
    docker compose ${COMPOSE_FILE:+-f "${COMPOSE_FILE}"} "$@"
}

psql_q() {
    compose exec -T "${DB_CONTAINER}" \
        psql -X -A -t -v ON_ERROR_STOP=1 -U "${DB_USER}" -d "${DB_NAME}" \
        -c "SET default_transaction_read_only = on" -c "$1" </dev/null | tail -n 1
}

failed=0
scoped_out=()
while IFS=',' read -r id environments _reason; do
    [[ -z "${id}" || "${id}" == "migration_id" ]] && continue
    [[ "|${environments}|" == *"|production|"* ]] || scoped_out+=("${id}")
done < "${SCOPE_FILE}"

for id in "${scoped_out[@]}"; do
    recorded="$(psql_q "SELECT count(*) FROM admin.schema_migrations WHERE migration_id = '${id}'")"
    if [[ "${recorded}" != "0" ]]; then
        echo "[FAIL] ${id} is recorded in the production ledger."
        failed=1
    else
        echo "[PASS] ${id}: no ledger row."
    fi
done

while IFS=',' read -r id object_type object_name; do
    [[ -z "${id}" || "${id}" == "migration_id" ]] && continue
    schema="${object_name%%.*}"
    name="${object_name#*.}"
    case "${object_type}" in
        table) present="$(psql_q "SELECT to_regclass('${object_name}') IS NOT NULL")" ;;
        function) present="$(psql_q "SELECT EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = '${schema}' AND p.proname = '${name}')")" ;;
        *) echo "[FAIL] ${OBJECTS_FILE}: unknown object type '${object_type}'"; failed=1; continue ;;
    esac
    if [[ "${present}" != "f" ]]; then
        echo "[FAIL] ${object_type} ${object_name} (${id}) exists on production."
        failed=1
    fi
done < "${OBJECTS_FILE}"
[[ "${failed}" -eq 0 ]] && echo "[PASS] none of the staging-only objects exists."

routes="$(compose exec -T "${APP_SERVICE}" python -c \
    "import src.main as m; print(sum('report-export' in getattr(r, 'path', '') for r in m.app.routes))" </dev/null 2>/dev/null | tail -n 1)"
if [[ "${routes}" == "0" ]]; then
    echo "[PASS] the running admin portal exposes no Reports export route."
else
    echo "[FAIL] the running admin portal exposes Reports export routes (count: '${routes:-unknown}')."
    failed=1
fi

exit "${failed}"
