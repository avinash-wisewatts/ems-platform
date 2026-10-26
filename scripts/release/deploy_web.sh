#!/usr/bin/env bash
set -Eeuo pipefail

# ============================================================================
# WiseWatts EMS -- dedicated EMS Web App container deploy / rollback
#
# Runs ONE already-built, immutably-tagged web frontend artifact
# (ghcr.io/<owner>/<repo>-web:<git-sha>[@sha256:...]) as the `ems-web`
# compose service. The admin-portal proxies the authenticated /app/* URL
# space to it when the host root .env sets EMS_WEB_UPSTREAM (see
# compose.yaml / app/src/main.py).
#
# BUILD ONCE -> TEST -> PROMOTE THE SAME ARTIFACT  (frontend container).
#
# Roll forward and roll back are the SAME operation -- only EMS_WEB_IMAGE
# changes. GHCR retains every git-SHA-tagged -web image, so any previously
# built frontend commit is a valid target. If the new container does not
# become healthy, the previously running ems-web image is restored
# automatically (still touching only ems-web) and the script fails.
#
# What this script deliberately never does:
#   - recreate, restart or name any compose service other than ems-web
#     (admin-portal, live-telemetry, timescaledb, telegraf, grafana are never
#     touched -- every compose invocation names ems-web with --no-deps)
#   - git fetch/checkout (a web-only deploy must not move the host's release
#     checkout; it uses the compose.yaml already deployed there)
#   - touch the database, migrations, Grafana, telegraf or energy pipelines
#   - rebuild anything (--no-build)
#   - modify any .env file
#
# Required environment variables:
#   PROJECT_PATH      Absolute path to the deployed repository checkout.
#   EMS_WEB_IMAGE     Fully-qualified frontend image reference tagged with a
#                     40-character Git SHA, ideally digest-pinned:
#                     ghcr.io/<owner>/<repo>-web:<git-sha>@sha256:<digest>
#
# Optional environment variables:
#   ENVIRONMENT_NAME  "staging" | "production" -- logging / history only.
#   COMPOSE_FILE      Defaults to PROJECT_PATH/compose.yaml
#   REGISTRY_USERNAME / REGISTRY_PASSWORD
#                     If BOTH are set, `docker login` before pulling.
#   REGISTRY_HOST     Defaults to ghcr.io
#   HEALTH_CHECK_TIMEOUT_SECONDS  Passed through to health_check.sh (default 120)
# ============================================================================

: "${PROJECT_PATH:?PROJECT_PATH is required}"
: "${EMS_WEB_IMAGE:?EMS_WEB_IMAGE is required}"

ENVIRONMENT_NAME="${ENVIRONMENT_NAME:-unspecified}"
REGISTRY_HOST="${REGISTRY_HOST:-ghcr.io}"
COMPOSE_FILE="${COMPOSE_FILE:-${PROJECT_PATH}/compose.yaml}"
SERVICE="ems-web"
CONTAINER="ems-web"
export HEALTH_CHECK_TIMEOUT_SECONDS="${HEALTH_CHECK_TIMEOUT_SECONDS:-120}"

compose() {
    docker compose -f "${COMPOSE_FILE}" "$@"
}

# <registry>/<repo>-web:<40-hex sha>, optionally @sha256:<64-hex>.
if [[ ! "${EMS_WEB_IMAGE}" =~ ^[^@[:space:]]+-web:([0-9a-f]{40})(@sha256:[0-9a-f]{64})?$ ]]; then
    echo "ERROR: EMS_WEB_IMAGE must be <registry>/<repo>-web:<40-char git sha>[@sha256:<digest>] (got '${EMS_WEB_IMAGE}')." >&2
    exit 1
fi
WEB_GIT_SHA="${BASH_REMATCH[1]}"

echo "============================================================"
echo "WiseWatts EMS -- EMS Web App container deploy"
echo "============================================================"
echo "Environment:  ${ENVIRONMENT_NAME}"
echo "Project path: ${PROJECT_PATH}"
echo "Web image:    ${EMS_WEB_IMAGE}"
echo "Service:      ${SERVICE} (only)"
echo

# ---------------------------------------------------------------------------
# 1. Preconditions: the deployed compose.yaml must define ems-web.
# ---------------------------------------------------------------------------
echo "[1/5] Checking the deployed compose configuration..."
if ! EMS_WEB_IMAGE="${EMS_WEB_IMAGE}" compose config --services | grep -qx "${SERVICE}"; then
    echo "ERROR: ${COMPOSE_FILE} has no '${SERVICE}' service. Deploy an application release that" >&2
    echo "       includes it (deploy-staging.yml) before using the web-only deploy path." >&2
    exit 1
fi
previous_image="$(docker inspect --format '{{.Config.Image}}' "${CONTAINER}" 2>/dev/null || true)"
echo "      OK. Currently running: ${previous_image:-<none>}"
echo

# ---------------------------------------------------------------------------
# 2. Pull the exact tested artifact. Never build.
# ---------------------------------------------------------------------------
echo "[2/5] Pulling frontend image..."
if [[ -n "${REGISTRY_USERNAME:-}" && -n "${REGISTRY_PASSWORD:-}" ]]; then
    echo "${REGISTRY_PASSWORD}" | docker login "${REGISTRY_HOST}" \
        --username "${REGISTRY_USERNAME}" \
        --password-stdin
fi
docker pull "${EMS_WEB_IMAGE}"
repo_digest="$(docker image inspect --format '{{join .RepoDigests ","}}' "${EMS_WEB_IMAGE}")"
echo

# ---------------------------------------------------------------------------
# 3. Verify provenance and contents before anything running changes.
# ---------------------------------------------------------------------------
echo "[3/5] Verifying the image..."
label_sha="$(docker image inspect --format '{{index .Config.Labels "org.opencontainers.image.revision"}}' "${EMS_WEB_IMAGE}")"
if [[ -n "${label_sha}" && "${label_sha}" != "<no value>" && "${label_sha}" != "unknown" ]]; then
    if [[ "${label_sha}" != "${WEB_GIT_SHA}" ]]; then
        echo "ERROR: image revision label ${label_sha} does not match its tag ${WEB_GIT_SHA} -- refusing." >&2
        exit 1
    fi
    echo "      Revision label matches tag: ${label_sha}"
else
    echo "      No revision label (image built before provenance labelling); tag ${WEB_GIT_SHA} is authoritative."
fi
docker run --rm --network none --entrypoint test "${EMS_WEB_IMAGE}" \
    -f /usr/share/nginx/html/app/index.html || {
    echo "ERROR: image contains no /usr/share/nginx/html/app/index.html -- refusing." >&2
    exit 1
}
echo "      Bundle entry present. Digest(s): ${repo_digest}"
echo

# ---------------------------------------------------------------------------
# 4. Recreate ONLY ems-web; restore the previous image if it is not healthy.
# ---------------------------------------------------------------------------
echo "[4/5] Deploying ${SERVICE}..."
EMS_WEB_IMAGE="${EMS_WEB_IMAGE}" compose up -d --no-build --no-deps "${SERVICE}"

if ! "${PROJECT_PATH}/scripts/release/health_check.sh" "${CONTAINER}"; then
    echo "ERROR: ${SERVICE} did not become healthy with ${EMS_WEB_IMAGE}." >&2
    if [[ -n "${previous_image}" && "${previous_image}" != "${EMS_WEB_IMAGE}" ]]; then
        echo "       Restoring the previously running image: ${previous_image}" >&2
        EMS_WEB_IMAGE="${previous_image}" compose up -d --no-build --no-deps "${SERVICE}"
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
echo "$(date --iso-8601=seconds)|${ENVIRONMENT_NAME}|web-container|${EMS_WEB_IMAGE}|${repo_digest}|previous=${previous_image:-none}" \
    >> "${PROJECT_PATH}/.deploy-history/${ENVIRONMENT_NAME}-web-container.log"

echo "============================================================"
echo "EMS Web App container deploy complete: ${ENVIRONMENT_NAME}"
echo "  running:  ${EMS_WEB_IMAGE}"
echo "  replaced: ${previous_image:-<none>}"
echo "  rollback: EMS_WEB_IMAGE='${previous_image:-<previous ref>}' PROJECT_PATH='${PROJECT_PATH}' \\"
echo "              ENVIRONMENT_NAME='${ENVIRONMENT_NAME}' ${PROJECT_PATH}/scripts/release/deploy_web.sh"
echo "============================================================"
