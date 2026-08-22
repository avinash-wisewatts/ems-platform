#!/usr/bin/env bash
set -Eeuo pipefail

# ============================================================================
# WiseWatts EMS -- controlled release deployment
#
# Purpose:
#   Deploy one already-built, already-tested, immutably-tagged application
#   image to a target environment (staging or production) without ever
#   rebuilding source on the deployment host.
#
# BUILD ONCE -> TEST -> PROMOTE THE SAME ARTIFACT.
#
# This script never:
#   - runs `docker compose up --build`
#   - runs `git pull` (it checks out an exact, known commit instead)
#   - touches services other than the application services it is told to
#     deploy (timescaledb, telegraf, and grafana are never named here and
#     are therefore never restarted or recreated by this script)
#
# Required environment variables:
#   PROJECT_PATH        Absolute path to the deployed repository checkout
#                        on the target host.
#   APP_IMAGE            Fully-qualified, immutably-tagged image reference,
#                        e.g. ghcr.io/<owner>/<repo>-app:<git-sha>
#   RELEASE_GIT_SHA      The exact commit SHA that produced APP_IMAGE. The
#                        host checkout is set to this commit so that
#                        bind-mounted, non-image configuration (compose.yaml
#                        itself, telegraf/config, grafana/provisioning,
#                        grafana/dashboards, postgres/migrations) matches the
#                        same release as the image being deployed.
#   ENVIRONMENT_NAME      "staging" or "production" (used only for logging
#                        and the local deployment history record).
#
# Optional environment variables:
#   COMPOSE_FILE          Defaults to PROJECT_PATH/compose.yaml
#   DB_CONTAINER          Defaults to timescaledb
#   DB_NAME               Defaults to ems
#   DB_USER               Defaults to ems_admin
#   REGISTRY_USERNAME     If set (with REGISTRY_PASSWORD), used to
#                        `docker login` before pulling APP_IMAGE.
#   REGISTRY_PASSWORD
#   REGISTRY_HOST         Defaults to ghcr.io
#   APP_SERVICES          Space-separated compose service names to deploy.
#                        Defaults to "admin-portal live-telemetry".
#
# Safety:
#   Every docker compose invocation names its services explicitly. No
#   invocation in this script omits the service list, so no unrelated
#   service (timescaledb, telegraf, grafana) is ever started, stopped, or
#   recreated by this script.
# ============================================================================

: "${PROJECT_PATH:?PROJECT_PATH is required}"
: "${APP_IMAGE:?APP_IMAGE is required}"
: "${RELEASE_GIT_SHA:?RELEASE_GIT_SHA is required}"
: "${ENVIRONMENT_NAME:?ENVIRONMENT_NAME is required (staging|production)}"

COMPOSE_FILE="${COMPOSE_FILE:-${PROJECT_PATH}/compose.yaml}"
DB_CONTAINER="${DB_CONTAINER:-timescaledb}"
DB_NAME="${DB_NAME:-ems}"
DB_USER="${DB_USER:-ems_admin}"
REGISTRY_HOST="${REGISTRY_HOST:-ghcr.io}"
APP_SERVICES="${APP_SERVICES:-admin-portal live-telemetry}"

# shellcheck disable=SC2206
APP_SERVICES_ARRAY=(${APP_SERVICES})

cd "${PROJECT_PATH}"

echo "============================================================"
echo "WiseWatts EMS release deployment"
echo "============================================================"
echo "Environment:   ${ENVIRONMENT_NAME}"
echo "Project path:  ${PROJECT_PATH}"
echo "Compose file:  ${COMPOSE_FILE}"
echo "Release SHA:   ${RELEASE_GIT_SHA}"
echo "App image:     ${APP_IMAGE}"
echo "App services:  ${APP_SERVICES}"
echo

compose() {
    docker compose -f "${COMPOSE_FILE}" "$@"
}

# ----------------------------------------------------------------------------
# 1. Move the host checkout to the exact release commit.
#
# This never runs `git pull` -- it fetches and checks out one specific,
# known-good SHA so non-image, bind-mounted configuration (compose.yaml,
# telegraf/config, grafana/provisioning, grafana/dashboards,
# postgres/migrations) is guaranteed to match the artifact being deployed.
# ----------------------------------------------------------------------------

echo "[1/6] Checking out release commit ${RELEASE_GIT_SHA}..."
git fetch --quiet origin "${RELEASE_GIT_SHA}"
git checkout --quiet "${RELEASE_GIT_SHA}"
echo "      Checked out: $(git rev-parse HEAD)"
echo

# ----------------------------------------------------------------------------
# 2. Validate configuration before touching anything running.
# ----------------------------------------------------------------------------

echo "[2/6] Validating compose configuration..."
compose config -q
echo "      Compose configuration is valid."
echo

# ----------------------------------------------------------------------------
# 3. Pull the exact tested artifact. Never build.
# ----------------------------------------------------------------------------

echo "[3/6] Pulling application image..."
if [[ -n "${REGISTRY_USERNAME:-}" && -n "${REGISTRY_PASSWORD:-}" ]]; then
    echo "${REGISTRY_PASSWORD}" | docker login "${REGISTRY_HOST}" \
        --username "${REGISTRY_USERNAME}" \
        --password-stdin
fi
docker pull "${APP_IMAGE}"
echo

# ----------------------------------------------------------------------------
# 4. Apply migrations BEFORE the new application code starts.
#
# scripts/apply_migrations.sh is authoritative: checksum-verified,
# transactional, forward-only. It execs into the already-running
# DB_CONTAINER -- it never restarts or recreates the database.
# ----------------------------------------------------------------------------

echo "[4/6] Applying database migrations..."
DB_CONTAINER="${DB_CONTAINER}" DB_NAME="${DB_NAME}" DB_USER="${DB_USER}" \
    COMPOSE_FILE="${COMPOSE_FILE}" \
    ./scripts/apply_migrations.sh
echo

# ----------------------------------------------------------------------------
# 5. Deploy the exact pulled image to only the named application services.
#
# --no-build guarantees this never rebuilds from source. Naming the services
# explicitly guarantees timescaledb/telegraf/grafana are never touched.
# ----------------------------------------------------------------------------

echo "[5/6] Deploying application services..."
APP_IMAGE="${APP_IMAGE}" compose up -d --no-build --no-deps "${APP_SERVICES_ARRAY[@]}"
echo

# ----------------------------------------------------------------------------
# 6. Wait for health, then record the deployment.
# ----------------------------------------------------------------------------

echo "[6/6] Waiting for application services to report healthy..."
container_names=()
for service in "${APP_SERVICES_ARRAY[@]}"; do
    container_names+=("$(compose ps -q "${service}" | xargs -r docker inspect --format '{{.Name}}' | sed 's#^/##')")
done

"${PROJECT_PATH}/scripts/release/health_check.sh" "${container_names[@]}"

mkdir -p "${PROJECT_PATH}/.deploy-history"
{
    echo "$(date --iso-8601=seconds)|${ENVIRONMENT_NAME}|${RELEASE_GIT_SHA}|${APP_IMAGE}"
} >> "${PROJECT_PATH}/.deploy-history/${ENVIRONMENT_NAME}.log"

echo
echo "============================================================"
echo "Deployment complete: ${ENVIRONMENT_NAME} @ ${RELEASE_GIT_SHA}"
echo "============================================================"
