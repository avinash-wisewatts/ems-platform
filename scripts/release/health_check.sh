#!/usr/bin/env bash
set -Eeuo pipefail

# ============================================================================
# WiseWatts EMS -- post-deploy container health poll
#
# Purpose:
#   Poll one or more compose service containers' Docker healthcheck status
#   until every one reports "healthy", or fail after a timeout.
#
# Usage:
#   ./scripts/release/health_check.sh <container_name> [<container_name> ...]
#
# Environment overrides:
#   HEALTH_CHECK_TIMEOUT_SECONDS=180
#   HEALTH_CHECK_INTERVAL_SECONDS=5
#
# Safety:
#   Read-only. Never starts, stops, or recreates a container.
# ============================================================================

if [[ $# -eq 0 ]]; then
    echo "Usage: $0 <container_name> [<container_name> ...]" >&2
    exit 2
fi

TIMEOUT="${HEALTH_CHECK_TIMEOUT_SECONDS:-180}"
INTERVAL="${HEALTH_CHECK_INTERVAL_SECONDS:-5}"
CONTAINERS=("$@")

elapsed=0

while true; do
    all_healthy=1

    for container in "${CONTAINERS[@]}"; do
        status="$(docker inspect --format '{{.State.Health.Status}}' "${container}" 2>/dev/null || echo "unknown")"

        if [[ "${status}" != "healthy" ]]; then
            all_healthy=0
        fi

        echo "  ${container}: ${status}"
    done

    if [[ "${all_healthy}" -eq 1 ]]; then
        echo "All containers healthy after ${elapsed}s."
        exit 0
    fi

    if (( elapsed >= TIMEOUT )); then
        echo "ERROR: Timed out after ${TIMEOUT}s waiting for containers to become healthy." >&2
        for container in "${CONTAINERS[@]}"; do
            echo "---- ${container} recent logs ----" >&2
            docker logs --tail 50 "${container}" 2>&1 >&2 || true
        done
        exit 1
    fi

    sleep "${INTERVAL}"
    elapsed=$(( elapsed + INTERVAL ))
done
