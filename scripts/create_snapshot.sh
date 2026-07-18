#!/usr/bin/env bash
set -euo pipefail

SNAPSHOT_DATE=$(date +%Y%m%d)
OUTPUT="$HOME/ems-platform-snapshot-${SNAPSHOT_DATE}.tar.gz"

echo "Creating sanitized snapshot..."
echo "Output: $OUTPUT"

cd /opt

tar -czf "$OUTPUT" \
    --exclude='ems-platform/.git' \
    --exclude='ems-platform/postgres/data' \
    --exclude='ems-platform/grafana/data' \
    --exclude='ems-platform/logs' \
    --exclude='ems-platform/**/.env' \
    --exclude='ems-platform/**/.env.*' \
    --exclude='ems-platform/**/__pycache__' \
    --exclude='ems-platform/**/*.pyc' \
    ems-platform

echo
echo "Snapshot created successfully:"
ls -lh "$OUTPUT"
