#!/usr/bin/env bash
set -Eeuo pipefail

# =============================================================================
# WiseWatts EMS disposable integration-test database
#
# Commands
# --------
#   ./scripts/test/test_database.sh start
#   ./scripts/test/test_database.sh status
#   ./scripts/test/test_database.sh psql
#   ./scripts/test/test_database.sh reset
#   ./scripts/test/test_database.sh stop
#   ./scripts/test/test_database.sh destroy
#
# Safety
# ------
# This script operates only on compose.test.yaml and the test service named
# timescaledb-test. It must never invoke the production compose.yaml implicitly.
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

COMPOSE_FILE="${PROJECT_ROOT}/compose.test.yaml"
SERVICE_NAME="timescaledb-test"
CONTAINER_NAME="ems-timescaledb-test"
DATABASE_NAME="ems_test"
DATABASE_USER="ems_admin"

usage() {
    cat <<USAGE
Usage: $0 {start|status|psql|reset|stop|destroy}
USAGE
}

require_compose_file() {
    if [[ ! -f "${COMPOSE_FILE}" ]]; then
        echo "ERROR: Test Compose file not found: ${COMPOSE_FILE}" >&2
        exit 1
    fi
}

wait_for_database() {
    echo "Waiting for the test database to become healthy..."

    # TimescaleDB's entrypoint briefly runs a temporary bootstrap Postgres
    # instance (to create the timescaledb extension) before restarting into
    # the final process once shared_preload_libraries takes effect. Docker's
    # cached Health.Status can latch "healthy" from a single probe against
    # that temporary instance and will not clear during the brief restart
    # (compose.test.yaml's healthcheck allows 20 consecutive failed probes,
    # 5s apart, before flipping back) -- so re-reading that cached field
    # alone, however many times, cannot detect the race. A freshly-executed
    # pg_isready call, re-run every iteration instead of read from a cached
    # field, closes it: that call reflects the live socket state at the
    # moment it runs, and is required to succeed on two consecutive polls
    # before readiness is trusted, which the temporary instance's brief
    # accepting window cannot satisfy on its own.
    local consecutive_ready=0

    for attempt in $(seq 1 30); do
        health_status="$(
            docker inspect \
                --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}unknown{{end}}' \
                "${CONTAINER_NAME}" 2>/dev/null || true
        )"

        if [[ "${health_status}" == "healthy" ]] \
            && docker exec "${CONTAINER_NAME}" \
                pg_isready -U "${DATABASE_USER}" -d "${DATABASE_NAME}" \
                >/dev/null 2>&1
        then
            consecutive_ready=$((consecutive_ready + 1))

            if [[ "${consecutive_ready}" -ge 2 ]]; then
                echo "Test database is healthy."
                return 0
            fi
        else
            consecutive_ready=0
        fi

        sleep 2
    done

    echo "ERROR: Test database did not become healthy." >&2
    docker compose -f "${COMPOSE_FILE}" logs "${SERVICE_NAME}" || true
    exit 1
}

start_database() {
    docker compose -f "${COMPOSE_FILE}" up -d "${SERVICE_NAME}"
    wait_for_database
}

case "${1:-}" in
    start)
        require_compose_file
        start_database
        ;;

    status)
        require_compose_file
        docker compose -f "${COMPOSE_FILE}" ps
        ;;

    psql)
        require_compose_file
        docker compose -f "${COMPOSE_FILE}" exec "${SERVICE_NAME}" \
            psql \
            -X \
            -U "${DATABASE_USER}" \
            -d "${DATABASE_NAME}"
        ;;

    reset)
        require_compose_file

        echo "Destroying the existing disposable test database..."
        docker compose -f "${COMPOSE_FILE}" down --volumes --remove-orphans

        echo "Creating a fresh disposable test database..."
        start_database
        ;;

    stop)
        require_compose_file
        docker compose -f "${COMPOSE_FILE}" stop "${SERVICE_NAME}"
        ;;

    destroy)
        require_compose_file

        echo "Destroying the disposable test database and its volume..."
        docker compose -f "${COMPOSE_FILE}" down --volumes --remove-orphans
        ;;

    *)
        usage
        exit 2
        ;;
esac
