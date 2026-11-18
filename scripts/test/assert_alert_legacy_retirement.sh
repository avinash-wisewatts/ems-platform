#!/usr/bin/env bash
#
# ============================================================================
# Migration 320 (ADR-024 §17-§20) -- legacy Energy Attention alert
# retirement, executed for real against the disposable ems_test database.
#
# Every phase runs the REAL postgres/migrations/320_alert_legacy_retirement.sql
# inside one transaction that is always rolled back, on top of a setup that
# recreates the pre-migration-321 shape with legacy rows and a registered
# legacy job (assert_alert_legacy_retirement_setup.sql).
#
#   A. abort-on-unknown: an extra row that is not a legacy Energy Attention
#      row (a different condition) must make migration 320 raise "Migration 320
#      aborted" -- the transaction then changes nothing.
#   B. happy path: legacy job removed, legacy procedures dropped, every
#      legacy alert / candidate deleted, per-state counts recorded in
#      admin.migration_outcomes (assert_alert_legacy_retirement_checks.sql).
#   C. idempotency: running the migration body a second time in the same
#      transaction succeeds and deletes nothing more.
# ============================================================================

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
MIGRATION="${PROJECT_ROOT}/postgres/migrations/320_alert_legacy_retirement.sql"
SETUP="${SCRIPT_DIR}/assert_alert_legacy_retirement_setup.sql"
CHECKS="${SCRIPT_DIR}/assert_alert_legacy_retirement_checks.sql"

run_psql() {
    docker compose \
        -f "${PROJECT_ROOT}/compose.test.yaml" \
        exec -T timescaledb-test \
        psql -X -q -v ON_ERROR_STOP=1 -U ems_admin -d ems_test -f -
}

echo "[A] migration 320 aborts on a row it cannot classify..."
set +e
output_a="$(
    {
        echo "BEGIN;"
        cat "${SETUP}"
        cat <<'SQL'
INSERT INTO analytics.alerts
    (organization_id, site_id, condition_key, metric, state, triggered_at, trigger_value, last_evaluated_at)
VALUES ('00000000-0000-0000-0000-00000000a320', '00000000-0000-0000-0000-00000000b320',
        'SOMETHING_ELSE:1', 'OTHER', 'ACTIVE', now(), 1, now());
SQL
        cat "${MIGRATION}"
        echo "ROLLBACK;"
    } | run_psql 2>&1
)"
status_a=$?
set -e
if [[ ${status_a} -eq 0 ]] || ! grep -q "Migration 320 aborted" <<<"${output_a}"; then
    echo "${output_a}"
    echo "[FAIL] migration 320 did not abort on an unclassifiable row" >&2
    exit 1
fi
echo "[PASS] migration 320 aborted on an unclassifiable row (nothing committed)"

echo "[B+C] migration 320 retires the evaluator and deletes legacy rows only; second run is a no-op..."
{
    echo "BEGIN;"
    cat "${SETUP}"
    cat "${MIGRATION}"
    cat "${CHECKS}"
    # C: run the body again -- must succeed and delete nothing.
    cat "${MIGRATION}"
    cat <<'SQL'
DO $c$
DECLARE v JSONB;
BEGIN
    SELECT outcome INTO v FROM admin.migration_outcomes
    WHERE migration_id = '320_alert_legacy_retirement' ORDER BY outcome_id DESC LIMIT 1;
    IF (v ->> 'alerts_deleted')::INT <> 0 OR (v ->> 'candidates_deleted')::INT <> 0 THEN
        RAISE EXCEPTION 'FAIL: second migration 320 run deleted rows: %', v;
    END IF;
    RAISE NOTICE 'PASS: second migration 320 run is a no-op';
END;
$c$;
ROLLBACK;
SQL
} | run_psql

echo "[PASS] migration 320 legacy retirement assertions"
