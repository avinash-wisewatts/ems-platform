#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT="/opt/ems-platform"
DEPLOY_SCRIPT="${PROJECT_ROOT}/scripts/deploy_database.sh"

cd "${PROJECT_ROOT}"

echo "Deploying database objects..."

if [[ ! -f "${DEPLOY_SCRIPT}" ]]; then
    echo "[FAIL] Database deployment script is missing: ${DEPLOY_SCRIPT}" >&2
    exit 1
fi

if [[ ! -x "${DEPLOY_SCRIPT}" ]]; then
    echo "Making database deployment script executable..."
    chmod +x "${DEPLOY_SCRIPT}"
fi

if [[ ! -f "${PROJECT_ROOT}/postgres/restructure_manifest.csv" ]]; then
    echo "[FAIL] Deployment manifest is missing." >&2
    exit 1
fi

"${DEPLOY_SCRIPT}"

echo
echo "[PASS] Database deployment completed."
