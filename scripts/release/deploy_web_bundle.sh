#!/usr/bin/env bash
set -Eeuo pipefail

# ============================================================================
# WiseWatts EMS -- Phase 8 frontend bundle placement
#
# Delivers ONE already-built, immutably-tagged web frontend artifact
# (ghcr.io/<owner>/<repo>-web:<git-sha>) to the target host by extracting its
# static bundle into a host directory that compose.yaml bind-mounts
# READ-ONLY into the admin-portal container at /app/src/spa.
#
# BUILD ONCE -> TEST -> PROMOTE THE SAME ARTIFACT  (frontend edition).
#
# Why this script exists separately from deploy_release.sh:
#   The admin-portal image is image-baked -- app/Dockerfile does
#   `COPY src /app/src`, so app/src is NOT a live bind mount. The only way the
#   separately-built React bundle can reach the running admin-portal process
#   is the compose `${EMS_WEB_SPA_PATH:-./web-spa}:/app/src/spa:ro` mount,
#   which this script populates. app/src/main.py registers the same-origin
#   `/app` routes at process start iff `<mount>/index.html` exists, so this
#   script must run BEFORE the admin-portal container is (re)created for a new
#   bundle to be picked up. When the directory is absent/empty the `/app` hook
#   stays inert and the admin portal is byte-for-byte unchanged.
#
# What this script deliberately never does:
#   - run `docker compose ...` or name any compose service
#   - touch the database, migrations, Grafana, telegraf or timescaledb
#   - start a container (it only `docker create`s one to copy a file out)
#   - rebuild anything
#
# Roll forward and roll back are the SAME operation -- only WEB_SPA_IMAGE
# changes. GHCR retains every git-SHA-tagged -web image indefinitely, so any
# previously built frontend commit is a valid target.
#
# Required environment variables:
#   PROJECT_PATH      Absolute path to the deployed repository checkout on the
#                     target host. Used for the default EMS_WEB_SPA_PATH, for
#                     reading an optional EMS_WEB_SPA_PATH override out of the
#                     host root .env, and for the local history record.
#   WEB_SPA_IMAGE     Fully-qualified, immutably-tagged frontend image
#                     reference, e.g. ghcr.io/<owner>/<repo>-web:<git-sha>
#                     (optionally digest-pinned: ...:<sha>@sha256:...).
#
# Optional environment variables:
#   EMS_WEB_SPA_PATH  Host directory bind-mounted into admin-portal at
#                     /app/src/spa. Precedence: this variable, else
#                     EMS_WEB_SPA_PATH in ${PROJECT_PATH}/.env (which is what
#                     compose.yaml itself interpolates), else the default
#                     ${PROJECT_PATH}/web-spa (== compose.yaml's ./web-spa
#                     resolved from the project directory).
#   ENVIRONMENT_NAME  "staging" | "production" -- logging / history only.
#   REGISTRY_USERNAME / REGISTRY_PASSWORD
#                     If BOTH are set, `docker login` before pulling.
#   REGISTRY_HOST     Defaults to ghcr.io
# ============================================================================

: "${PROJECT_PATH:?PROJECT_PATH is required}"
: "${WEB_SPA_IMAGE:?WEB_SPA_IMAGE is required}"

ENVIRONMENT_NAME="${ENVIRONMENT_NAME:-unspecified}"
REGISTRY_HOST="${REGISTRY_HOST:-ghcr.io}"

# Resolve EMS_WEB_SPA_PATH the same way compose.yaml would: an explicit
# environment value wins; otherwise honour an override in the host root .env
# (compose reads that file automatically); otherwise fall back to the default
# that matches compose.yaml's `${EMS_WEB_SPA_PATH:-./web-spa}` when compose is
# invoked from PROJECT_PATH.
if [[ -z "${EMS_WEB_SPA_PATH:-}" && -f "${PROJECT_PATH}/.env" ]]; then
    env_override="$(sed -n 's/^[[:space:]]*EMS_WEB_SPA_PATH[[:space:]]*=[[:space:]]*//p' \
        "${PROJECT_PATH}/.env" | tail -n1)"
    env_override="${env_override%\"}"; env_override="${env_override#\"}"
    env_override="${env_override%\'}"; env_override="${env_override#\'}"
    if [[ -n "${env_override}" ]]; then
        EMS_WEB_SPA_PATH="${env_override}"
    fi
fi
EMS_WEB_SPA_PATH="${EMS_WEB_SPA_PATH:-${PROJECT_PATH}/web-spa}"

# A relative override in .env is relative to the compose project directory.
case "${EMS_WEB_SPA_PATH}" in
    /*) : ;;
    *)  EMS_WEB_SPA_PATH="${PROJECT_PATH%/}/${EMS_WEB_SPA_PATH#./}" ;;
esac

echo "============================================================"
echo "WiseWatts EMS -- frontend bundle placement"
echo "============================================================"
echo "Environment:    ${ENVIRONMENT_NAME}"
echo "Project path:   ${PROJECT_PATH}"
echo "Web image:      ${WEB_SPA_IMAGE}"
echo "SPA mount path: ${EMS_WEB_SPA_PATH}"
echo "                (bind-mounted :ro into admin-portal at /app/src/spa)"
echo

mkdir -p "$(dirname "${EMS_WEB_SPA_PATH}")"

# ---------------------------------------------------------------------------
# 1. Pull the exact tested frontend artifact. Never build.
# ---------------------------------------------------------------------------
echo "[1/4] Pulling frontend image..."
if [[ -n "${REGISTRY_USERNAME:-}" && -n "${REGISTRY_PASSWORD:-}" ]]; then
    echo "${REGISTRY_PASSWORD}" | docker login "${REGISTRY_HOST}" \
        --username "${REGISTRY_USERNAME}" \
        --password-stdin
fi
docker pull "${WEB_SPA_IMAGE}"
echo

# ---------------------------------------------------------------------------
# 2. Copy the bundle tarball out of a CREATED (never started) container and
#    unpack it into a staging directory alongside the published one.
# ---------------------------------------------------------------------------
echo "[2/4] Extracting bundle from image..."
staging_dir="$(mktemp -d "${EMS_WEB_SPA_PATH%/}.incoming.XXXXXX")"
tarball="$(mktemp "${TMPDIR:-/tmp}/ems-web-spa.XXXXXX.tgz")"
cid=""
cleanup() {
    [[ -n "${cid}" ]] && docker rm -f "${cid}" >/dev/null 2>&1 || true
    rm -rf "${staging_dir}" "${tarball}"
}
trap cleanup EXIT

cid="$(docker create "${WEB_SPA_IMAGE}")"
docker cp "${cid}:/srv-spa.tgz" "${tarball}"
docker rm -f "${cid}" >/dev/null
cid=""

tar -xzf "${tarball}" -C "${staging_dir}"
rm -f "${tarball}"

if [[ ! -f "${staging_dir}/index.html" ]]; then
    echo "ERROR: extracted bundle contains no index.html -- refusing to publish." >&2
    exit 1
fi
echo "      OK ($(find "${staging_dir}" -type f | wc -l | tr -d ' ') files, entry: index.html)."
echo

# ---------------------------------------------------------------------------
# 3. Atomically swap the published bundle directory (same filesystem ->
#    rename(2) is atomic). The previous bundle is kept for a fast local
#    rollback; the canonical rollback is re-running this script with the
#    prior -web:<git-sha> image.
# ---------------------------------------------------------------------------
echo "[3/4] Publishing bundle -> ${EMS_WEB_SPA_PATH}"
previous_dir="${EMS_WEB_SPA_PATH%/}.previous"
rm -rf "${previous_dir}"
if [[ -e "${EMS_WEB_SPA_PATH}" ]]; then
    mv "${EMS_WEB_SPA_PATH}" "${previous_dir}"
fi
mv "${staging_dir}" "${EMS_WEB_SPA_PATH}"
trap - EXIT
echo "      Published. Previous bundle (if any) retained at:"
echo "        ${previous_dir}"
echo
echo "      NOTE: the admin-portal container must be (re)created to bind the"
echo "      new directory / register the /app routes on first activation:"
echo "        docker compose -f \"${PROJECT_PATH}/compose.yaml\" up -d --no-build --no-deps admin-portal"
echo "      In the normal pipeline deploy_release.sh does this immediately after."
echo

# ---------------------------------------------------------------------------
# 4. Record what was published.
# ---------------------------------------------------------------------------
mkdir -p "${PROJECT_PATH}/.deploy-history"
echo "$(date --iso-8601=seconds)|${ENVIRONMENT_NAME}|web|${WEB_SPA_IMAGE}" \
    >> "${PROJECT_PATH}/.deploy-history/${ENVIRONMENT_NAME}-web.log"

echo "============================================================"
echo "Frontend bundle placement complete: ${ENVIRONMENT_NAME}"
echo "============================================================"
