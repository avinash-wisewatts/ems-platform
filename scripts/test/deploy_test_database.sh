#!/usr/bin/env bash
set -Eeuo pipefail

# =============================================================================
# Deploy the canonical WiseWatts EMS database definition into the disposable
# integration-test database.
#
# Safety guarantees:
#   - Uses compose.test.yaml, never the production compose.yaml.
#   - Uses the timescaledb-test service.
#   - Uses the ems_test database.
#   - Refuses to continue unless the target database identity is exactly
#     ems_test|ems_admin.
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

TEST_COMPOSE_FILE="${PROJECT_ROOT}/compose.test.yaml"
TEST_SERVICE="timescaledb-test"
TEST_DATABASE="ems_test"
TEST_USER="ems_admin"

cd "${PROJECT_ROOT}"

if [[ ! -f "${TEST_COMPOSE_FILE}" ]]; then
    echo "ERROR: Test Compose file not found: ${TEST_COMPOSE_FILE}" >&2
    exit 1
fi

database_identity="$(
    docker compose \
        -f "${TEST_COMPOSE_FILE}" \
        exec -T "${TEST_SERVICE}" \
        psql \
        -X \
        -U "${TEST_USER}" \
        -d "${TEST_DATABASE}" \
        -tAc "
            SELECT current_database() || '|' || current_user;
        "
)"

if [[ "${database_identity}" != "${TEST_DATABASE}|${TEST_USER}" ]]; then
    echo "ERROR: Refusing deployment to unexpected database identity:" >&2
    echo "       ${database_identity}" >&2
    exit 1
fi

echo "Verified disposable target: ${database_identity}"
echo

# Docker Compose honors COMPOSE_FILE when no explicit -f argument is supplied.
# The canonical deployment runner therefore continues to be the single source
# of truth for deployment ordering while targeting the isolated test stack.
COMPOSE_FILE="${TEST_COMPOSE_FILE}" \
DB_CONTAINER="${TEST_SERVICE}" \
DB_NAME="${TEST_DATABASE}" \
DB_USER="${TEST_USER}" \
    "${PROJECT_ROOT}/scripts/deploy_database.sh"
