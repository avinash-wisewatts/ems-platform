#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

docker compose \
    -f "${PROJECT_ROOT}/compose.test.yaml" \
    exec -T timescaledb-test \
    psql \
    -X \
    -v ON_ERROR_STOP=1 \
    -U ems_admin \
    -d ems_test \
    -f - \
< "${SCRIPT_DIR}/assert_energy_routing_identity_by_name.sql"
