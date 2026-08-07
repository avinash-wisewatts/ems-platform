#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

# After the 2026-08-07 pre-production baseline, the active migration manifest
# contains one immutable baseline migration followed by future migrations 002+.
# A clean test database first receives the canonical deployment, then executes
# the active migration stream normally. No historical ledger simulation is
# required.
COMPOSE_FILE="${PROJECT_ROOT}/compose.test.yaml" \
DB_CONTAINER="timescaledb-test" \
DB_NAME="ems_test" \
DB_USER="ems_admin" \
    "${PROJECT_ROOT}/scripts/apply_migrations.sh"
