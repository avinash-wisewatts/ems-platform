#!/usr/bin/env bash
set -euo pipefail

REPOSITORY_ROOT="/opt/ems-platform"
COMPOSE_FILE="${REPOSITORY_ROOT}/compose.test.yaml"
SERVICE="timescaledb-test"
DATABASE="ems_test"
DATABASE_USER="ems_admin"
ASSERTION_FILE="$(
    realpath \
        "${REPOSITORY_ROOT}/scripts/test/"\
"assert_independent_asset_inventory.sql"
)"

cd "$REPOSITORY_ROOT"

identity="$(
    docker compose -f "$COMPOSE_FILE" \
        exec -T "$SERVICE" \
        psql -X \
            -U "$DATABASE_USER" \
            -d "$DATABASE" \
            -tAc \
            "SELECT current_database() || '|' || current_user;"
)"

printf 'Confirmed target: %s\n' "$identity"
test "$identity" = "${DATABASE}|${DATABASE_USER}"

docker compose -f "$COMPOSE_FILE" \
    exec -T "$SERVICE" \
    psql -X \
        -U "$DATABASE_USER" \
        -d "$DATABASE" \
        -v ON_ERROR_STOP=1 \
    < "$ASSERTION_FILE"
