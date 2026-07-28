#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT="/opt/ems-platform"
SERVICE_NAME="grafana"

cd "${PROJECT_ROOT}"

echo "Starting Grafana..."

SERVICES="$(docker compose config --services)"

if ! grep -qx "${SERVICE_NAME}" <<< "${SERVICES}"; then
    echo "[FAIL] Grafana service not found."
    exit 1
fi

docker compose up -d "${SERVICE_NAME}"

CID="$(docker compose ps -q "${SERVICE_NAME}")"

if [[ -z "${CID}" ]]; then
    echo "[FAIL] Grafana container not created."
    exit 1
fi

RUNNING="$(docker inspect --format '{{.State.Running}}' "${CID}")"

if [[ "${RUNNING}" != "true" ]]; then
    echo "[FAIL] Grafana failed to start."
    docker compose logs --tail=100 grafana
    exit 1
fi

echo "[PASS] Grafana container running."

docker compose ps grafana
