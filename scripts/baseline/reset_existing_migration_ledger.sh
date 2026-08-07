#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

COMPOSE_FILE="${COMPOSE_FILE:-${PROJECT_ROOT}/compose.yaml}"
DB_CONTAINER="${DB_CONTAINER:-timescaledb}"
DB_NAME="${DB_NAME:-ems}"
DB_USER="${DB_USER:-ems_admin}"
BASELINE_RELATIVE="postgres/migrations/001_ems_platform_baseline_20260807.sql"
BASELINE_FILE="${PROJECT_ROOT}/${BASELINE_RELATIVE}"
MODE="${1:-}"

if [[ "${MODE}" != "--execute" ]]; then
    echo "Usage: $0 --execute" >&2
    echo "This command replaces the existing migration ledger with baseline 001." >&2
    exit 2
fi

identity="$(docker compose -f "${COMPOSE_FILE}" exec -T "${DB_CONTAINER}" psql -X -U "${DB_USER}" -d "${DB_NAME}" -tAc "SELECT current_database() || '|' || current_user")"
if [[ "${identity}" != "${DB_NAME}|${DB_USER}" ]]; then
    echo "ERROR: unexpected database identity ${identity}" >&2
    exit 1
fi

latest="$(docker compose -f "${COMPOSE_FILE}" exec -T "${DB_CONTAINER}" psql -X -U "${DB_USER}" -d "${DB_NAME}" -tAc "SELECT migration_id FROM admin.schema_migrations ORDER BY applied_at DESC, migration_id DESC LIMIT 1")"
if [[ "${latest}" != "179_simplify_device_lifecycle_statuses" ]]; then
    echo "ERROR: expected latest pre-baseline migration 179_simplify_device_lifecycle_statuses; found ${latest:-<none>}." >&2
    exit 1
fi

checksum="$(sha256sum "${BASELINE_FILE}" | awk '{print $1}')"
backup="${PROJECT_ROOT}/postgres/archive/prebaseline_20260807/migration-ledger-before-baseline-$(date +%Y%m%d-%H%M%S).csv"
mkdir -p "$(dirname "${backup}")"

docker compose -f "${COMPOSE_FILE}" exec -T "${DB_CONTAINER}" \
    psql -X -U "${DB_USER}" -d "${DB_NAME}" --csv \
    -c "SELECT * FROM admin.schema_migrations ORDER BY applied_at, migration_id" \
    > "${backup}"

checksum_sql="${checksum//\'/\'\'}"
file_sql="${BASELINE_RELATIVE//\'/\'\'}"

# The database schema is already at the baseline state. Only the ledger is
# replaced, transactionally, after the explicit precondition above.
docker compose -f "${COMPOSE_FILE}" exec -T "${DB_CONTAINER}" \
    psql -X -v ON_ERROR_STOP=1 -U "${DB_USER}" -d "${DB_NAME}" <<SQL
BEGIN;
LOCK TABLE admin.schema_migrations IN ACCESS EXCLUSIVE MODE;
TRUNCATE TABLE admin.schema_migrations;
INSERT INTO admin.schema_migrations (
    migration_id,
    file_path,
    checksum_sha256,
    execution_ms,
    application_mode
)
VALUES (
    '001_ems_platform_baseline_20260807',
    '${file_sql}',
    '${checksum_sql}',
    0,
    'baseline'
);
COMMIT;
SQL

echo "PASS: migration ledger reset to baseline 001"
echo "Previous ledger: ${backup}"
