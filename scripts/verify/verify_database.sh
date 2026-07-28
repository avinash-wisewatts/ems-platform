#!/usr/bin/env bash
#
# ============================================================
# WiseWatts EMS Database Verification
#
# Performs read-only checks against Docker, PostgreSQL,
# TimescaleDB, and required canonical database objects.
# ============================================================

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/config/required_objects.conf"

cd "${PROJECT_DIR}" || {
    echo "[FAIL] Cannot access project directory: ${PROJECT_DIR}"
    exit 1
}

# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

print_header
print_section "Database Foundation"

# ------------------------------------------------------------
# Configuration validation
# ------------------------------------------------------------

if [[ -r "${CONFIG_FILE}" ]]; then
    pass "Required-object configuration is readable"
else
    fail "Required-object configuration is missing: ${CONFIG_FILE}"
    summary
fi

# ------------------------------------------------------------
# Docker service validation
# ------------------------------------------------------------

COMPOSE_SERVICES="$(
    docker compose config --services 2>/dev/null || true
)"

if grep -qx "timescaledb" <<< "${COMPOSE_SERVICES}"; then
    pass "TimescaleDB service exists in Docker Compose"
else
    fail "TimescaleDB service is missing from Docker Compose"
fi

CONTAINER_ID="$(
    docker compose ps -q timescaledb 2>/dev/null || true
)"

if [[ -z "${CONTAINER_ID}" ]]; then
    fail "TimescaleDB container does not exist"
    summary
fi

CONTAINER_STATE="$(
    docker inspect \
        --format '{{.State.Status}}' \
        "${CONTAINER_ID}" 2>/dev/null || true
)"

if [[ "${CONTAINER_STATE}" == "running" ]]; then
    pass "TimescaleDB container is running"
else
    fail "TimescaleDB container state is ${CONTAINER_STATE:-unknown}"
fi

HEALTH_STATUS="$(
    docker inspect \
        --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}not-configured{{end}}' \
        "${CONTAINER_ID}" 2>/dev/null || true
)"

case "${HEALTH_STATUS}" in
    healthy)
        pass "TimescaleDB container health check is healthy"
        ;;
    not-configured)
        warn "TimescaleDB container has no Docker health check"
        ;;
    *)
        fail "TimescaleDB container health is ${HEALTH_STATUS:-unknown}"
        ;;
esac

# ------------------------------------------------------------
# PostgreSQL connectivity
# ------------------------------------------------------------

if psql_query "SELECT 1;" >/dev/null 2>&1; then
    pass "PostgreSQL connection succeeded"
else
    fail "PostgreSQL connection failed"
    summary
fi

DATABASE_NAME="$(
    psql_query "SELECT current_database();" 2>/dev/null || true
)"

if [[ "${DATABASE_NAME}" == "ems" ]]; then
    pass "Connected to expected database: ems"
else
    fail "Connected to unexpected database: ${DATABASE_NAME:-unknown}"
fi

# ------------------------------------------------------------
# TimescaleDB extension
# ------------------------------------------------------------

TIMESCALE_VERSION="$(
    psql_query "
        SELECT extversion
        FROM pg_extension
        WHERE extname = 'timescaledb';
    " 2>/dev/null || true
)"

if [[ -n "${TIMESCALE_VERSION}" ]]; then
    pass "TimescaleDB extension installed: ${TIMESCALE_VERSION}"
else
    fail "TimescaleDB extension is not installed"
fi

# ------------------------------------------------------------
# Declarative required-object checks
# ------------------------------------------------------------

print_section "Required Canonical Objects"

while IFS= read -r line || [[ -n "${line}" ]]; do
    # Trim leading and trailing whitespace.
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"

    [[ -z "${line}" ]] && continue
    [[ "${line}" == \#* ]] && continue

    OBJECT_TYPE="${line%%:*}"
    OBJECT_NAME="${line#*:}"

    # SCHEMA entries contain only a schema name.
    # TABLE, VIEW, and HYPERTABLE entries must use schema.object format.
    if [[ "${OBJECT_TYPE}" == "SCHEMA" ]]; then
        OBJECT_SCHEMA="${OBJECT_NAME}"
        OBJECT_RELATION=""
    elif [[ "${OBJECT_NAME}" == *.* ]]; then
        OBJECT_SCHEMA="${OBJECT_NAME%%.*}"
        OBJECT_RELATION="${OBJECT_NAME#*.}"
    else
        fail "Invalid object definition: ${line}"
        continue
    fi

    case "${OBJECT_TYPE}" in
        SCHEMA)
            EXISTS="$(
                psql_query "
                    SELECT EXISTS (
                        SELECT 1
                        FROM pg_namespace
                        WHERE nspname = '${OBJECT_NAME}'
                    );
                " 2>/dev/null || true
            )"
            ;;

        TABLE)
            EXISTS="$(
                psql_query "
                    SELECT EXISTS (
                        SELECT 1
                        FROM pg_class c
                        JOIN pg_namespace n
                          ON n.oid = c.relnamespace
                        WHERE n.nspname = '${OBJECT_SCHEMA}'
                          AND c.relname = '${OBJECT_RELATION}'
                          AND c.relkind IN ('r', 'p')
                    );
                " 2>/dev/null || true
            )"
            ;;

        VIEW)
            EXISTS="$(
                psql_query "
                    SELECT EXISTS (
                        SELECT 1
                        FROM pg_class c
                        JOIN pg_namespace n
                          ON n.oid = c.relnamespace
                        WHERE n.nspname = '${OBJECT_SCHEMA}'
                          AND c.relname = '${OBJECT_RELATION}'
                          AND c.relkind IN ('v', 'm')
                    );
                " 2>/dev/null || true
            )"
            ;;

        HYPERTABLE)
            EXISTS="$(
                psql_query "
                    SELECT EXISTS (
                        SELECT 1
                        FROM timescaledb_information.hypertables
                        WHERE hypertable_schema = '${OBJECT_SCHEMA}'
                          AND hypertable_name = '${OBJECT_RELATION}'
                    );
                " 2>/dev/null || true
            )"
            ;;

        *)
            fail "Unsupported object type in configuration: ${OBJECT_TYPE}"
            continue
            ;;
    esac

    if [[ "${EXISTS}" == "t" ]]; then
        pass "${OBJECT_TYPE}: ${OBJECT_NAME}"
    else
        fail "${OBJECT_TYPE} missing: ${OBJECT_NAME}"
    fi

done < "${CONFIG_FILE}"

# ------------------------------------------------------------
# Discovery information
# ------------------------------------------------------------

print_section "TimescaleDB Inventory"

HYPERTABLE_COUNT="$(
    psql_query "
        SELECT COUNT(*)
        FROM timescaledb_information.hypertables
        WHERE hypertable_schema = 'telemetry';
    " 2>/dev/null || echo 0
)"

if [[ "${HYPERTABLE_COUNT}" =~ ^[0-9]+$ ]] &&
   (( HYPERTABLE_COUNT > 0 )); then
    pass "Telemetry hypertables discovered: ${HYPERTABLE_COUNT}"
else
    fail "No telemetry hypertables were discovered"
fi

CAGG_COUNT="$(
    psql_query "
        SELECT COUNT(*)
        FROM timescaledb_information.continuous_aggregates;
    " 2>/dev/null || echo 0
)"

if [[ "${CAGG_COUNT}" =~ ^[0-9]+$ ]] &&
   (( CAGG_COUNT > 0 )); then
    pass "Continuous aggregates discovered: ${CAGG_COUNT}"
else
    warn "No continuous aggregates were discovered"
fi

summary
