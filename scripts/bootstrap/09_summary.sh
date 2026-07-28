#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT="/opt/ems-platform"

cd "${PROJECT_ROOT}"

echo
echo "==============================================="
echo " WiseWatts EMS Platform Deployment Summary"
echo "==============================================="

docker compose ps

echo
echo "Database:"
docker compose exec -T timescaledb \
psql -U "${POSTGRES_USER}" -d "${POSTGRES_DB}" \
-c "SELECT version();" >/dev/null

echo "  ✓ PostgreSQL reachable"

echo
echo "Bootstrap completed successfully."

echo "==============================================="
