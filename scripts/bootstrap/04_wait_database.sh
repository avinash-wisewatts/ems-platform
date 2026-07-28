#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT="/opt/ems-platform"
SERVICE_NAME="timescaledb"
MAX_ATTEMPTS=30
SLEEP_SECONDS=2

cd "${PROJECT_ROOT}"

echo "Waiting for TimescaleDB readiness..."

CONTAINER_ID="$(
    docker compose ps -q "${SERVICE_NAME}"
)"

if [[ -z "${CONTAINER_ID}" ]]; then
    echo "[FAIL] TimescaleDB container does not exist." >&2
    exit 1
fi

for ((attempt = 1; attempt <= MAX_ATTEMPTS; attempt++)); do
    HEALTH_STATUS="$(
        docker inspect \
            --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' \
            "${CONTAINER_ID}"
    )"

    RUNNING_STATE="$(
        docker inspect \
            --format '{{.State.Running}}' \
            "${CONTAINER_ID}"
    )"

    if [[ "${RUNNING_STATE}" != "true" ]]; then
        echo "[FAIL] TimescaleDB stopped while waiting for readiness." >&2
        docker compose logs --tail=50 "${SERVICE_NAME}"
        exit 1
    fi

    if [[ "${HEALTH_STATUS}" == "healthy" ]]; then
        echo "[PASS] TimescaleDB health check reports healthy."
        exit 0
    fi

    printf 'Attempt %d/%d: health status=%s\n' \
        "${attempt}" \
        "${MAX_ATTEMPTS}" \
        "${HEALTH_STATUS}"

    sleep "${SLEEP_SECONDS}"
done

echo "[FAIL] TimescaleDB did not become healthy in time." >&2
docker compose ps "${SERVICE_NAME}"
docker compose logs --tail=50 "${SERVICE_NAME}"
exit 1
