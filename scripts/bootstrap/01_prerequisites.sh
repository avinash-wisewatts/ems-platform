#!/usr/bin/env bash
set -euo pipefail

echo "Checking host prerequisites..."

REQUIRED_COMMANDS=(
    docker
    awk
    grep
    sed
    df
    free
)

FAILURES=0

for command_name in "${REQUIRED_COMMANDS[@]}"; do
    if command -v "${command_name}" >/dev/null 2>&1; then
        printf '[PASS] Command available: %s\n' "${command_name}"
    else
        printf '[FAIL] Missing required command: %s\n' "${command_name}" >&2
        FAILURES=$((FAILURES + 1))
    fi
done

if docker compose version >/dev/null 2>&1; then
    echo "[PASS] Docker Compose plugin available"
else
    echo "[FAIL] Docker Compose plugin is unavailable" >&2
    FAILURES=$((FAILURES + 1))
fi

if docker info >/dev/null 2>&1; then
    echo "[PASS] Docker daemon is accessible"
else
    echo "[FAIL] Docker daemon is not accessible by the current user" >&2
    FAILURES=$((FAILURES + 1))
fi

AVAILABLE_DISK_MB="$(
    df -Pm /opt \
    | awk 'NR == 2 {print $4}'
)"

MINIMUM_DISK_MB=2048

if [[ "${AVAILABLE_DISK_MB}" =~ ^[0-9]+$ ]] &&
   (( AVAILABLE_DISK_MB >= MINIMUM_DISK_MB )); then
    echo "[PASS] Free disk space under /opt: ${AVAILABLE_DISK_MB} MB"
else
    echo "[FAIL] Less than ${MINIMUM_DISK_MB} MB free under /opt" >&2
    FAILURES=$((FAILURES + 1))
fi

TOTAL_MEMORY_MB="$(
    free -m \
    | awk '/^Mem:/ {print $2}'
)"

MINIMUM_MEMORY_MB=1800

if [[ "${TOTAL_MEMORY_MB}" =~ ^[0-9]+$ ]] &&
   (( TOTAL_MEMORY_MB >= MINIMUM_MEMORY_MB )); then
    echo "[PASS] Installed memory: ${TOTAL_MEMORY_MB} MB"
else
    echo "[FAIL] Less than ${MINIMUM_MEMORY_MB} MB RAM detected" >&2
    FAILURES=$((FAILURES + 1))
fi

if [[ -f /opt/ems-platform/compose.yaml ]]; then
    echo "[PASS] compose.yaml exists"
else
    echo "[FAIL] compose.yaml is missing" >&2
    FAILURES=$((FAILURES + 1))
fi

if [[ "${FAILURES}" -ne 0 ]]; then
    echo
    echo "Prerequisite validation failed with ${FAILURES} error(s)." >&2
    exit 1
fi

echo
echo "Prerequisite validation passed."
