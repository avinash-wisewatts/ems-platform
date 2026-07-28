#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT="/opt/ems-platform"

cd "${PROJECT_ROOT}"

echo "Running platform verification..."

./scripts/verify/verify_all.sh

echo
echo "[PASS] Platform verification completed."
