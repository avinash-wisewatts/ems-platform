#!/usr/bin/env bash
set -Eeuo pipefail

# ============================================================================
# WiseWatts EMS -- customer API deploy / rollback (ADR-023)
#
# Runs ONE already-built, immutably-tagged application artifact
# (ghcr.io/<owner>/<repo>-app:<git-sha>[@sha256:...], the same image as
# admin-portal / live-telemetry) as the `customer-api` compose service
# (entrypoint src.customer_main). Roll forward and roll back are the same
# operation -- only EMS_CUSTOMER_API_IMAGE changes. If the new container does
# not become healthy, the previously running image is restored automatically
# (still touching only customer-api) and the script fails.
#
# What this script deliberately never does:
#   - recreate, restart or name any compose service other than customer-api
#     (admin-portal, live-telemetry, ems-web, edge, timescaledb, telegraf,
#     grafana are never touched -- every compose call names customer-api with
#     --no-deps)
#   - git fetch/checkout, run migrations, or edit any .env file
#   - rebuild anything (--no-build)
#
# Preconditions (checked): the deployed compose.yaml defines customer-api;
# ${PROJECT_PATH}/app/customer-api.env exists (its database login is the
# migration-313 role ems_customer_api, enabled by an operator); the image
# contains src/customer_main.py.
#
# Required environment variables:
#   PROJECT_PATH              Absolute path to the deployed repository checkout.
#   EMS_CUSTOMER_API_IMAGE    <registry>/<repo>-app:<40-char git sha>[@sha256:<digest>]
#
# Optional environment variables:
#   ENVIRONMENT_NAME  "staging" | "production" -- logging / history only.
#   COMPOSE_FILE      Defaults to PROJECT_PATH/compose.yaml
#   REGISTRY_USERNAME / REGISTRY_PASSWORD   If BOTH are set, `docker login` first.
#   REGISTRY_HOST     Defaults to ghcr.io
#   HEALTH_CHECK_TIMEOUT_SECONDS  Passed through to health_check.sh (default 120)
# ============================================================================

: "${PROJECT_PATH:?PROJECT_PATH is required}"
: "${EMS_CUSTOMER_API_IMAGE:?EMS_CUSTOMER_API_IMAGE is required}"

ENVIRONMENT_NAME="${ENVIRONMENT_NAME:-unspecified}"
REGISTRY_HOST="${REGISTRY_HOST:-ghcr.io}"
COMPOSE_FILE="${COMPOSE_FILE:-${PROJECT_PATH}/compose.yaml}"
SERVICE="customer-api"
CONTAINER="ems-customer-api"
export HEALTH_CHECK_TIMEOUT_SECONDS="${HEALTH_CHECK_TIMEOUT_SECONDS:-120}"

compose() {
    docker compose -f "${COMPOSE_FILE}" --profile customer "$@"
}

# <registry>/<repo>-app:<40-hex sha>, optionally @sha256:<64-hex>.
if [[ ! "${EMS_CUSTOMER_API_IMAGE}" =~ ^[^@[:space:]]+-app:([0-9a-f]{40})(@sha256:[0-9a-f]{64})?$ ]]; then
    echo "ERROR: EMS_CUSTOMER_API_IMAGE must be <registry>/<repo>-app:<40-char git sha>[@sha256:<digest>] (got '${EMS_CUSTOMER_API_IMAGE}')." >&2
    exit 1
fi

echo "============================================================"
echo "WiseWatts EMS -- customer API deploy"
echo "============================================================"
echo "Environment:  ${ENVIRONMENT_NAME}"
echo "Project path: ${PROJECT_PATH}"
echo "Image:        ${EMS_CUSTOMER_API_IMAGE}"
echo "Service:      ${SERVICE} (only)"
echo

# ---------------------------------------------------------------------------
# 1. Preconditions.
# ---------------------------------------------------------------------------
echo "[1/5] Checking preconditions..."
if ! EMS_CUSTOMER_API_IMAGE="${EMS_CUSTOMER_API_IMAGE}" compose config --services | grep -qx "${SERVICE}"; then
    echo "ERROR: ${COMPOSE_FILE} has no '${SERVICE}' service. Deploy an application release that includes it first." >&2
    exit 1
fi
if [[ ! -f "${PROJECT_PATH}/app/customer-api.env" ]]; then
    echo "ERROR: ${PROJECT_PATH}/app/customer-api.env is missing (see app/customer-api.env.example)." >&2
    exit 1
fi
previous_image="$(docker inspect --format '{{.Config.Image}}' "${CONTAINER}" 2>/dev/null || true)"
echo "      OK. Currently running: ${previous_image:-<none>}"
echo

# ---------------------------------------------------------------------------
# 2. Pull the exact tested artifact. Never build.
# ---------------------------------------------------------------------------
echo "[2/5] Pulling image..."
if [[ -n "${REGISTRY_USERNAME:-}" && -n "${REGISTRY_PASSWORD:-}" ]]; then
    echo "${REGISTRY_PASSWORD}" | docker login "${REGISTRY_HOST}" \
        --username "${REGISTRY_USERNAME}" \
        --password-stdin
fi
docker pull "${EMS_CUSTOMER_API_IMAGE}"
repo_digest="$(docker image inspect --format '{{join .RepoDigests ","}}' "${EMS_CUSTOMER_API_IMAGE}")"
echo

# ---------------------------------------------------------------------------
# 3. Verify the image provides the customer API before anything changes.
# ---------------------------------------------------------------------------
echo "[3/5] Verifying the image..."
docker run --rm --network none --entrypoint test "${EMS_CUSTOMER_API_IMAGE}" \
    -f /app/src/customer_main.py || {
    echo "ERROR: image has no /app/src/customer_main.py (built before the customer API) -- refusing." >&2
    exit 1
}
echo "      Customer API entrypoint present. Digest(s): ${repo_digest}"
echo

# ---------------------------------------------------------------------------
# 4. Recreate ONLY customer-api; restore the previous image if it is not healthy.
# ---------------------------------------------------------------------------
echo "[4/5] Deploying ${SERVICE}..."
EMS_CUSTOMER_API_IMAGE="${EMS_CUSTOMER_API_IMAGE}" compose up -d --no-build --no-deps "${SERVICE}"

if ! "${PROJECT_PATH}/scripts/release/health_check.sh" "${CONTAINER}"; then
    echo "ERROR: ${SERVICE} did not become healthy with ${EMS_CUSTOMER_API_IMAGE}." >&2
    if [[ -n "${previous_image}" && "${previous_image}" != "${EMS_CUSTOMER_API_IMAGE}" ]]; then
        echo "       Restoring the previously running image: ${previous_image}" >&2
        EMS_CUSTOMER_API_IMAGE="${previous_image}" compose up -d --no-build --no-deps "${SERVICE}"
        "${PROJECT_PATH}/scripts/release/health_check.sh" "${CONTAINER}" || true
    fi
    exit 1
fi
echo

# ---------------------------------------------------------------------------
# 5. Record what is now running (and what it replaced, for rollback).
# ---------------------------------------------------------------------------
echo "[5/5] Recording deployment..."
mkdir -p "${PROJECT_PATH}/.deploy-history"
echo "$(date --iso-8601=seconds)|${ENVIRONMENT_NAME}|customer-api|${EMS_CUSTOMER_API_IMAGE}|${repo_digest}|previous=${previous_image:-none}" \
    >> "${PROJECT_PATH}/.deploy-history/${ENVIRONMENT_NAME}-customer-api.log"

echo "============================================================"
echo "Customer API deploy complete: ${ENVIRONMENT_NAME}"
echo "  running:  ${EMS_CUSTOMER_API_IMAGE}"
echo "  replaced: ${previous_image:-<none>}"
echo "  rollback: EMS_CUSTOMER_API_IMAGE='${previous_image:-<previous ref>}' PROJECT_PATH='${PROJECT_PATH}' \\"
echo "              ENVIRONMENT_NAME='${ENVIRONMENT_NAME}' ${PROJECT_PATH}/scripts/release/deploy_customer_api.sh"
echo "============================================================"
