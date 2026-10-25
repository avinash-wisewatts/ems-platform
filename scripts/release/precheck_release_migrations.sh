#!/usr/bin/env bash
set -Eeuo pipefail

# =============================================================================
# Host-side pending-migration precheck, run by deploy-production.yml and
# rollback.yml BEFORE scripts/release/deploy_release.sh.
#
# The workflows run the copy of this script (and of check_pending_migrations.sh)
# from origin/staging, not from the host checkout or the target commit: the
# host checkout is the release currently deployed, and a rollback target may
# predate the migration environment scope. Nothing is checked out here; the
# target commit's files are read with `git show`, and the ledger with one
# read-only query.
#
# Environment:
#   PROJECT_PATH         host repository checkout
#   RELEASE_GIT_SHA      target commit (already fetched)
#   ENVIRONMENT_NAME     staging | production
#   EXPECTED_MIGRATIONS  operator-declared list (e.g. 311) or none
#   CHECK_REF            ref holding the current scope and check script
#                        (default origin/staging)
# =============================================================================

: "${PROJECT_PATH:?PROJECT_PATH is required}"
: "${RELEASE_GIT_SHA:?RELEASE_GIT_SHA is required}"
: "${ENVIRONMENT_NAME:?ENVIRONMENT_NAME is required}"
: "${EXPECTED_MIGRATIONS:?EXPECTED_MIGRATIONS is required (use none for a release with no migrations)}"
CHECK_REF="${CHECK_REF:-origin/staging}"
DB_CONTAINER="${DB_CONTAINER:-timescaledb}"
DB_NAME="${DB_NAME:-ems}"
DB_USER="${DB_USER:-ems_admin}"

cd "${PROJECT_PATH}"

work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT

git show "${RELEASE_GIT_SHA}:postgres/restructure_manifest.csv" > "${work}/manifest.csv"

scope="none"
if git cat-file -e "${RELEASE_GIT_SHA}:postgres/migration_environment_scope.csv" 2>/dev/null; then
    git show "${RELEASE_GIT_SHA}:postgres/migration_environment_scope.csv" > "${work}/scope.csv"
    scope="${work}/scope.csv"
fi

scope_aware="no"
if git show "${RELEASE_GIT_SHA}:scripts/apply_migrations.sh" | grep -q "SKIP-ENV"; then
    scope_aware="yes"
fi

git show "${CHECK_REF}:postgres/migration_environment_scope.csv" > "${work}/deny_scope.csv"
git show "${CHECK_REF}:scripts/release/check_pending_migrations.sh" > "${work}/check_pending_migrations.sh"

docker compose exec -T "${DB_CONTAINER}" \
    psql -X -A -t -v ON_ERROR_STOP=1 -U "${DB_USER}" -d "${DB_NAME}" \
    -c "SET default_transaction_read_only = on" \
    -c "SELECT migration_id FROM admin.schema_migrations ORDER BY migration_id" </dev/null \
    | grep -v '^SET$' > "${work}/ledger.txt"

echo "Pending-migration precheck for ${ENVIRONMENT_NAME} at ${RELEASE_GIT_SHA} (check script and deny scope from ${CHECK_REF})"
bash "${work}/check_pending_migrations.sh" \
    --environment "${ENVIRONMENT_NAME}" \
    --manifest "${work}/manifest.csv" \
    --scope "${scope}" \
    --scope-aware "${scope_aware}" \
    --deny-scope "${work}/deny_scope.csv" \
    --ledger "${work}/ledger.txt" \
    --expected "${EXPECTED_MIGRATIONS}"
