#!/usr/bin/env bash
set -euo pipefail

REPOSITORY_ROOT="/opt/ems-platform"
REPOSITORY_PARENT="$(dirname "$REPOSITORY_ROOT")"
REPOSITORY_NAME="$(basename "$REPOSITORY_ROOT")"
ARCHIVE_ROOT="/home/emsadmin"

LABEL="${1:-repository}"
SAFE_LABEL="$(
    printf '%s' "$LABEL" \
        | tr '[:upper:]' '[:lower:]' \
        | sed -E 's/[^a-z0-9._-]+/-/g; s/^-+//; s/-+$//'
)"

if [[ -z "$SAFE_LABEL" ]]; then
    SAFE_LABEL="repository"
fi

if [[ ! -d "$REPOSITORY_ROOT" ]]; then
    echo "ERROR: Repository does not exist: $REPOSITORY_ROOT" >&2
    exit 1
fi

if [[ ! -d "$ARCHIVE_ROOT" ]]; then
    echo "ERROR: Archive directory does not exist: $ARCHIVE_ROOT" >&2
    exit 1
fi

SNAPSHOT_TIME="$(date +%Y%m%d-%H%M%S)"
OUTPUT="${ARCHIVE_ROOT}/ems-platform-${SAFE_LABEL}-${SNAPSHOT_TIME}.tar.gz"
LISTING_FILE="$(mktemp)"

cleanup() {
    rm -f "$LISTING_FILE"
}
trap cleanup EXIT

echo "Creating sanitized EMS platform snapshot..."
echo "Source: ${REPOSITORY_ROOT}"
echo "Output: ${OUTPUT}"

sudo tar \
    --exclude="${REPOSITORY_NAME}/.git" \
    --exclude="${REPOSITORY_NAME}/postgres/data" \
    --exclude="${REPOSITORY_NAME}/postgres/backups" \
    --exclude="${REPOSITORY_NAME}/postgres/archive" \
    --exclude="${REPOSITORY_NAME}/backups" \
    --exclude="${REPOSITORY_NAME}/grafana/data" \
    --exclude="${REPOSITORY_NAME}/grafana/plugins" \
    --exclude="${REPOSITORY_NAME}/grafana/dashboard-backups" \
    --exclude="${REPOSITORY_NAME}/logs" \
    --exclude="${REPOSITORY_NAME}/telegraf/logs" \
    --exclude='*/.venv' \
    --exclude='*/.venv-*' \
    --exclude='*/venv' \
    --exclude='*/node_modules' \
    --exclude='*/.pytest_cache' \
    --exclude='*/.mypy_cache' \
    --exclude='*/.ruff_cache' \
    --exclude='*/.cache' \
    --exclude='*/__pycache__' \
    --exclude='*/htmlcov' \
    --exclude='*/coverage' \
    --exclude='*/test-results' \
    --exclude='*/playwright-report' \
    --exclude='*/screenshots' \
    --exclude='*/videos' \
    --exclude='*/.env' \
    --exclude='*/.env.*' \
    --exclude='*/secrets' \
    --exclude='*/secrets/*' \
    --exclude='*/credentials' \
    --exclude='*/credentials/*' \
    --exclude='*.key' \
    --exclude='*.p12' \
    --exclude='*.pfx' \
    --exclude='*.jks' \
    --exclude='*.keystore' \
    --exclude='id_rsa' \
    --exclude='id_ed25519' \
    --exclude='service-account*.json' \
    --exclude='credentials*.json' \
    --exclude='docker-compose.override.yml' \
    --exclude='docker-compose.override.yaml' \
    --exclude='*.pyc' \
    --exclude='*.bak' \
    --exclude='*.bak-*' \
    --exclude='*.backup' \
    --exclude='*.before-*' \
    --exclude='*.failed-*' \
    --exclude='*.swp' \
    --exclude='*.tmp' \
    --exclude='*.tar' \
    --exclude='*.tar.gz' \
    --exclude='*/.coverage' \
    --exclude='*.tgz' \
    --exclude='*.zip' \
    -czf "$OUTPUT" \
    -C "$REPOSITORY_PARENT" \
    "$REPOSITORY_NAME"

sudo chown emsadmin:emsadmin "$OUTPUT"
chmod 600 "$OUTPUT"

echo
echo "Verifying snapshot exclusions..."

tar -tzf "$OUTPUT" > "$LISTING_FILE"

FORBIDDEN_PATTERN='(^|/)(\.git|backups|postgres/data|postgres/backups|postgres/archive|grafana/data|grafana/plugins|grafana/dashboard-backups|node_modules|\.venv[^/]*|venv|\.pytest_cache|\.mypy_cache|\.ruff_cache|__pycache__|logs|telegraf/logs)(/|$)'

if grep -Eq "$FORBIDDEN_PATTERN" "$LISTING_FILE"; then
    echo "ERROR: Snapshot contains an excluded runtime path." >&2
    grep -E "$FORBIDDEN_PATTERN" "$LISTING_FILE" | head -20 >&2
    rm -f "$OUTPUT"
    exit 1
fi

SECRET_NAME_PATTERN='(^|/)\.env($|\.)|(^|/)(secrets|credentials)/|\.key$|\.p12$|\.pfx$|\.jks$|\.keystore$|(^|/)id_(rsa|ed25519)$|(^|/)(service-account|credentials)[^/]*\.json$'

if grep -Eiq "$SECRET_NAME_PATTERN" "$LISTING_FILE"; then
    echo "ERROR: Snapshot contains a likely secret-bearing file." >&2
    grep -Ei "$SECRET_NAME_PATTERN" "$LISTING_FILE" | head -20 >&2
    rm -f "$OUTPUT"
    exit 1
fi

echo "Snapshot created and verified successfully:"
ls -lh "$OUTPUT"
echo
echo "$OUTPUT"
