#!/usr/bin/env bash
set -Eeuo pipefail

# =============================================================================
# scripts/apply_migrations.sh environment scope, end to end, on a scratch
# database (ems_scope_test) in the disposable test container. Three fixture
# migrations: 900 and 902 apply everywhere, 901 is scoped to staging|test.
#
#   1. DEPLOY_ENVIRONMENT unset, or an invalid scope file: refused, no change.
#   2. production: APPLY 900 / 902, SKIP-ENV 901, no ledger row or table for 901.
#   3. production again, and --status: idempotent, nothing pending.
#   4. staging: APPLY 901.
#   5. production after that: hard failure (901 recorded in the ledger).
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
COMPOSE_FILE="${PROJECT_ROOT}/compose.test.yaml"
SCRATCH_DB="ems_scope_test"
FIXTURES="scripts/test/fixtures/migration_scope"

work="$(mktemp -d)"
cleanup() {
    rm -rf "${work}"
    psql_admin -d ems_test -c "DROP DATABASE IF EXISTS ${SCRATCH_DB} WITH (FORCE)" > /dev/null || true
}
trap cleanup EXIT

psql_admin() {
    docker compose -f "${COMPOSE_FILE}" exec -T timescaledb-test psql -X -v ON_ERROR_STOP=1 -U ems_admin "$@"
}

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

runner() {
    # $1 = DEPLOY_ENVIRONMENT ('' for unset), $2 = scope file, rest = runner args
    local environment="$1" scope="$2"
    shift 2
    env -u DEPLOY_ENVIRONMENT -u ENVIRONMENT_NAME ${environment:+DEPLOY_ENVIRONMENT="${environment}"} \
        COMPOSE_FILE="${COMPOSE_FILE}" DB_CONTAINER="timescaledb-test" \
        DB_NAME="${SCRATCH_DB}" DB_USER="ems_admin" \
        MIGRATION_MANIFEST="${work}/manifest.csv" MIGRATION_SCOPE="${scope}" \
        "${PROJECT_ROOT}/scripts/apply_migrations.sh" "$@"
}

ledger_ids() {
    psql_admin -d "${SCRATCH_DB}" -tAc "SELECT string_agg(migration_id, ',' ORDER BY migration_id) FROM admin.schema_migrations"
}

table_exists() {
    [[ "$(psql_admin -d "${SCRATCH_DB}" -tAc "SELECT to_regclass('public.$1') IS NOT NULL")" == "t" ]]
}

# Scratch database with only the migration ledger, copied from ems_test.
psql_admin -d ems_test -c "DROP DATABASE IF EXISTS ${SCRATCH_DB} WITH (FORCE)" -c "CREATE DATABASE ${SCRATCH_DB}" > /dev/null
psql_admin -d "${SCRATCH_DB}" -c "CREATE SCHEMA admin" > /dev/null
docker compose -f "${COMPOSE_FILE}" exec -T timescaledb-test \
    pg_dump -U ems_admin --schema-only --no-owner --no-privileges --table=admin.schema_migrations ems_test \
    | psql_admin -d "${SCRATCH_DB}" -q > /dev/null

{
    echo "source_file,target_category,target_path,notes"
    for name in 900_scope_fixture_all 901_scope_fixture_staging_only 902_scope_fixture_all; do
        echo "${name}.sql,migration,${FIXTURES}/${name}.sql,fixture"
    done
} > "${work}/manifest.csv"
printf 'migration_id,environments,reason\n901_scope_fixture_staging_only,staging|test,fixture\n' > "${work}/scope.csv"

# 1. Refusals before any change.
if runner "" "${work}/scope.csv" > "${work}/out" 2>&1; then fail "runner ran without DEPLOY_ENVIRONMENT"; fi
grep -q "DEPLOY_ENVIRONMENT must be" "${work}/out" || fail "missing DEPLOY_ENVIRONMENT message"
if runner "nowhere" "${work}/scope.csv" > "${work}/out" 2>&1; then fail "runner accepted an unknown environment"; fi

printf 'migration_id,environments,reason\n999_not_in_manifest,staging,bad\n' > "${work}/bad_id.csv"
printf 'migration_id,environments,reason\n901_scope_fixture_staging_only,stagin,bad\n' > "${work}/bad_env.csv"
printf 'migration_id,environments,reason\n901_scope_fixture_staging_only,staging,a\n901_scope_fixture_staging_only,test,b\n' > "${work}/dup.csv"
for bad in bad_id bad_env dup; do
    if runner production "${work}/${bad}.csv" > "${work}/out" 2>&1; then fail "runner accepted scope file ${bad}"; fi
done
if runner production "${work}/missing.csv" > "${work}/out" 2>&1; then fail "runner ran without a scope file"; fi
[[ -z "$(ledger_ids)" ]] || fail "a refused run changed the ledger"
echo "PASS: refusals (unset / unknown environment, unknown id, unknown environment, duplicate, missing file) change nothing"

# 2. Production.
runner production "${work}/scope.csv" > "${work}/out" 2>&1 || { cat "${work}/out"; fail "production run failed"; }
grep -q "^APPLIED 900_scope_fixture_all" "${work}/out" || fail "900 not applied"
grep -q "^SKIP-ENV 901_scope_fixture_staging_only (staging|test)" "${work}/out" || fail "901 not SKIP-ENV"
grep -q "^APPLIED 902_scope_fixture_all" "${work}/out" || fail "902 not applied"
[[ "$(ledger_ids)" == "900_scope_fixture_all,902_scope_fixture_all" ]] || fail "ledger is $(ledger_ids)"
table_exists m900_scope_fixture_all && table_exists m902_scope_fixture_all || fail "900 / 902 objects missing"
if table_exists m901_scope_fixture_staging_only; then fail "901 object exists on production"; fi
echo "PASS: production applies 900 / 902, skips 901 with no ledger row and no object"

# 3. Idempotent.
runner production "${work}/scope.csv" > "${work}/out" 2>&1 || fail "production re-run failed"
grep -q "^SKIP  900_scope_fixture_all" "${work}/out" && grep -q "^SKIP-ENV 901" "${work}/out" \
    && grep -q "^SKIP  902_scope_fixture_all" "${work}/out" || fail "re-run not idempotent"
runner production "${work}/scope.csv" --status > "${work}/out" 2>&1 || fail "--status failed"
if grep -q "^PENDING" "${work}/out"; then fail "--status reports a pending migration"; fi
echo "PASS: production re-run and --status: nothing pending"

# 3b. Transition: the previous release's deploy_release.sh calls the runner
#     without DEPLOY_ENVIRONMENT; the workflows export ENVIRONMENT_NAME.
env -u DEPLOY_ENVIRONMENT ENVIRONMENT_NAME=production \
    COMPOSE_FILE="${COMPOSE_FILE}" DB_CONTAINER="timescaledb-test" DB_NAME="${SCRATCH_DB}" DB_USER="ems_admin" \
    MIGRATION_MANIFEST="${work}/manifest.csv" MIGRATION_SCOPE="${work}/scope.csv" \
    "${PROJECT_ROOT}/scripts/apply_migrations.sh" --status > "${work}/out" 2>&1 || { cat "${work}/out"; fail "runner refused ENVIRONMENT_NAME=production"; }
grep -q "^Environment: production" "${work}/out" && grep -q "^SKIP-ENV 901" "${work}/out" || fail "ENVIRONMENT_NAME fallback not used"
env DEPLOY_ENVIRONMENT=staging ENVIRONMENT_NAME=production \
    COMPOSE_FILE="${COMPOSE_FILE}" DB_CONTAINER="timescaledb-test" DB_NAME="${SCRATCH_DB}" DB_USER="ems_admin" \
    MIGRATION_MANIFEST="${work}/manifest.csv" MIGRATION_SCOPE="${work}/scope.csv" \
    "${PROJECT_ROOT}/scripts/apply_migrations.sh" --status > "${work}/out" 2>&1 || fail "--status with both variables failed"
grep -q "^PENDING 901_scope_fixture_staging_only" "${work}/out" || fail "DEPLOY_ENVIRONMENT did not take precedence over ENVIRONMENT_NAME"
echo "PASS: ENVIRONMENT_NAME fallback (previous deploy_release.sh); DEPLOY_ENVIRONMENT takes precedence"

# 4. Staging applies the staging-only migration.
runner staging "${work}/scope.csv" > "${work}/out" 2>&1 || fail "staging run failed"
grep -q "^APPLIED 901_scope_fixture_staging_only" "${work}/out" || fail "901 not applied on staging"
echo "PASS: staging applies 901"

# 5. Fail closed: a scoped-out migration recorded in the ledger.
if runner production "${work}/scope.csv" > "${work}/out" 2>&1; then fail "production accepted a recorded staging-only migration"; fi
grep -q "is scoped to 'staging|test' but is recorded in the production ledger" "${work}/out" || fail "missing fail-closed message"
echo "PASS: production refuses when a staging-only migration is in its ledger"

# 6. Post-deploy gate (scripts/verify/verify_environment_scope.sh), database
#    checks. The test stack has no admin-portal service, so the route check
#    cannot pass here; the assertions below are on the database lines.
gate() {
    # $1 = environment, $2 = database
    env DEPLOY_ENVIRONMENT="$1" COMPOSE_FILE="${COMPOSE_FILE}" DB_CONTAINER="timescaledb-test" \
        DB_NAME="$2" DB_USER="ems_admin" APP_SERVICE="timescaledb-test" \
        "${PROJECT_ROOT}/scripts/verify/verify_environment_scope.sh"
}

if gate production ems_test > "${work}/out" 2>&1; then fail "gate passed on a database that has 309 / 310 / 312 / 313 / 314"; fi
for expected in "[FAIL] 309_report_export_jobs is recorded in the production ledger." \
                "[FAIL] 312_report_export_asset_selection_1m is recorded in the production ledger." \
                "[FAIL] 310_preserved_rtdata_backfill is recorded in the production ledger." \
                "[FAIL] table analytics.report_export_jobs (309_report_export_jobs) exists on production." \
                "[FAIL] function analytics.get_portal_asset_measurements_1m (312_report_export_asset_selection_1m) exists on production." \
                "[FAIL] table telemetry.preserved_rtdata_packets (310_preserved_rtdata_backfill) exists on production."                 "[FAIL] 313_customer_api_role is recorded in the production ledger."                 "[FAIL] role ems_customer_api (313_customer_api_role) exists on production." \
                "[FAIL] 314_customer_session_revocation is recorded in the production ledger." \
                "[FAIL] table admin.portal_sessions (314_customer_session_revocation) exists on production."; do
    grep -qF "${expected}" "${work}/out" || { cat "${work}/out"; fail "gate output lacks: ${expected}"; }
done
echo "PASS: production gate fails on a database with the staging-only migrations and names them"

gate production "${SCRATCH_DB}" > "${work}/out" 2>&1 || true
for expected in "[PASS] 309_report_export_jobs: no ledger row." "[PASS] 310_preserved_rtdata_backfill: no ledger row." \
                "[PASS] 312_report_export_asset_selection_1m: no ledger row." "[PASS] 313_customer_api_role: no ledger row." "[PASS] 314_customer_session_revocation: no ledger row."                 "[PASS] none of the staging-only objects exists."; do
    grep -qF "${expected}" "${work}/out" || { cat "${work}/out"; fail "gate output lacks: ${expected}"; }
done
echo "PASS: production gate's database checks pass on a database without them"

gate staging ems_test > "${work}/out" 2>&1 || fail "gate failed on staging (it must not apply there)"
grep -qF "[PASS] not production: the gate does not apply." "${work}/out" || fail "staging gate message missing"
echo "PASS: the gate does not apply on staging"

echo "Migration environment-scope assertions passed."
