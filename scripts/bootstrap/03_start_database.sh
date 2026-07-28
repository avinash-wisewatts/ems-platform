#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT="/opt/ems-platform"
SERVICE_NAME="timescaledb"

cd "${PROJECT_ROOT}"

echo "Starting TimescaleDB service..."

if ! docker compose config --services | grep -qx "${SERVICE_NAME}"; then
    echo "[FAIL] Docker Compose service '${SERVICE_NAME}' does not exist." >&2
    exit 1
fi

docker compose up -d "${SERVICE_NAME}"

CONTAINER_ID="$(
    docker compose ps -q "${SERVICE_NAME}"
)"

if [[ -z "${CONTAINER_ID}" ]]; then
    echo "[FAIL] TimescaleDB container was not created." >&2
    exit 1
fi

RUNNING_STATE="$(
    docker inspect \
        --format '{{.State.Running}}' \
        "${CONTAINER_ID}"
)"

if [[ "${RUNNING_STATE}" != "true" ]]; then
    echo "[FAIL] TimescaleDB container is not running." >&2
    docker compose ps "${SERVICE_NAME}"
    exit 1
fi

echo "[PASS] TimescaleDB container is running."
docker compose ps "${SERVICE_NAME}"
