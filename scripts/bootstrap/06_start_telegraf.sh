#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT="/opt/ems-platform"
SERVICE_NAME="telegraf"

cd "${PROJECT_ROOT}"

echo "Starting Telegraf service..."

COMPOSE_SERVICES="$(
    docker compose config --services 2>/dev/null || true
)"

if ! grep -qx "${SERVICE_NAME}" <<< "${COMPOSE_SERVICES}"; then
    echo "[FAIL] Docker Compose service '${SERVICE_NAME}' does not exist." >&2
    exit 1
fi

docker compose up -d "${SERVICE_NAME}"

CONTAINER_ID="$(
    docker compose ps -q "${SERVICE_NAME}"
)"

if [[ -z "${CONTAINER_ID}" ]]; then
    echo "[FAIL] Telegraf container was not created." >&2
    exit 1
fi

RUNNING_STATE="$(
    docker inspect \
        --format '{{.State.Running}}' \
        "${CONTAINER_ID}"
)"

if [[ "${RUNNING_STATE}" != "true" ]]; then
    echo "[FAIL] Telegraf container is not running." >&2
    docker compose logs --tail=80 "${SERVICE_NAME}"
    exit 1
fi

sleep 3

if docker compose logs --tail=100 "${SERVICE_NAME}" \
    | grep -Eqi 'error|failed|panic'; then
    echo "[FAIL] Telegraf logs contain startup errors." >&2
    docker compose logs --tail=100 "${SERVICE_NAME}"
    exit 1
fi

echo "[PASS] Telegraf container is running."
docker compose ps "${SERVICE_NAME}"
