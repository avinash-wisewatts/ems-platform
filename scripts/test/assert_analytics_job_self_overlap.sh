#!/usr/bin/env bash
set -Eeuo pipefail

# ============================================================================
# Cross-session regression test for migration 208 (Phase 2 Foundation,
# Phase 0b): the self-overlap guard on the analytical-tier jobs.
#
# Proves finding P-C1 is closed: if a run of one of these jobs is still in
# flight (it overran its schedule interval), the next invocation of the SAME
# job cannot process concurrently -- it takes the SKIPPED_LOCKED path,
# advances no state, writes nothing to the target, does not double-apply
# analytics.demand_state, and does not deadlock.
#
# Method (deterministic, no fixed sleeps): a background psql session opens a
# transaction and takes pg_advisory_xact_lock() on the job's own identity
# (the exact hashtextextended('<proc>', 0) key the wrapper uses), simulating
# an in-flight run. We poll pg_locks until that advisory lock is visible from
# another backend, then CALL the job in the foreground session and assert it
# came back SKIPPED_LOCKED. The background session is then released.
# ============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
COMPOSE_FILE="${PROJECT_ROOT}/compose.test.yaml"

psql_c() {
    docker compose -f "${COMPOSE_FILE}" exec -T timescaledb-test \
        psql -X -q -t -A -v ON_ERROR_STOP=1 -U ems_admin -d ems_test -c "$1"
}
psql_f() {
    docker compose -f "${COMPOSE_FILE}" exec -T timescaledb-test \
        psql -X -v ON_ERROR_STOP=1 -U ems_admin -d ems_test -f -
}

BG_PIDS=()
cleanup() {
    for p in "${BG_PIDS[@]:-}"; do
        kill "${p}" >/dev/null 2>&1 || true
        wait "${p}" 2>/dev/null || true
    done
}
trap cleanup EXIT

# Hold the advisory xact lock for <proc> in a background session for <secs>.
hold_lock_bg() {
    local proc="$1" secs="$2"
    docker compose -f "${COMPOSE_FILE}" exec -T timescaledb-test \
        psql -X -q -v ON_ERROR_STOP=1 -U ems_admin -d ems_test <<SQL >/dev/null 2>&1 &
BEGIN;
SELECT pg_advisory_xact_lock(hashtextextended('${proc}', 0));
SELECT pg_sleep(${secs});
ROLLBACK;
SQL
    BG_PIDS+=("$!")
}

wait_for_foreign_advisory_lock() {
    local tries=0
    while : ; do
        local n
        n="$(psql_c "SELECT count(*) FROM pg_locks WHERE locktype='advisory' AND granted AND pid <> pg_backend_pid();")"
        if [[ "${n}" =~ ^[0-9]+$ ]] && (( n >= 1 )); then
            return 0
        fi
        tries=$((tries + 1))
        if (( tries > 100 )); then
            echo "ERROR: background advisory lock never became visible" >&2
            exit 1
        fi
        sleep 0.1
    done
}

echo "[self-overlap] energy_consumption_1min ..."
psql_c "UPDATE telemetry.pipeline_state SET last_status='NEVER_RUN', last_started_at=NULL, last_completed_at=NULL, last_error=NULL WHERE pipeline_name='energy_consumption_1min';" >/dev/null
BASE_ROWS="$(psql_c "SELECT count(*) FROM analytics.energy_consumption_1min;")"

hold_lock_bg "analytics.run_energy_consumption_1min_job" 30
wait_for_foreign_advisory_lock

psql_f <<'SQL'
DO $$
DECLARE
    v_status       TEXT;
    v_started      TIMESTAMPTZ;
    v_rows_before  BIGINT;
    v_rows_after   BIGINT;
BEGIN
    SELECT count(*) INTO v_rows_before FROM analytics.energy_consumption_1min;

    CALL analytics.run_energy_consumption_1min_job(999208, '{"lookback":"30 minutes"}'::jsonb);

    SELECT last_status, last_started_at INTO v_status, v_started
    FROM telemetry.pipeline_state WHERE pipeline_name = 'energy_consumption_1min';
    SELECT count(*) INTO v_rows_after FROM analytics.energy_consumption_1min;

    IF v_status IS DISTINCT FROM 'SKIPPED_LOCKED' THEN
        RAISE EXCEPTION 'FAILED: concurrent run should be SKIPPED_LOCKED, got %', v_status;
    END IF;
    IF v_started IS NOT NULL THEN
        RAISE EXCEPTION 'FAILED: SKIPPED_LOCKED run advanced last_started_at to %', v_started;
    END IF;
    IF v_rows_after IS DISTINCT FROM v_rows_before THEN
        RAISE EXCEPTION 'FAILED: SKIPPED_LOCKED run wrote % target rows', v_rows_after - v_rows_before;
    END IF;
    RAISE NOTICE 'PASS: energy_consumption_1min concurrent invocation -> SKIPPED_LOCKED, no state advance, no target writes.';
END $$;
SQL

cleanup
BG_PIDS=()

echo "[self-overlap] demand_intervals (demand_state must not be double-applied) ..."
psql_c "UPDATE telemetry.pipeline_state SET last_status='NEVER_RUN', last_started_at=NULL, last_completed_at=NULL, last_error=NULL WHERE pipeline_name='demand_intervals';" >/dev/null
DS_BEFORE="$(psql_c "SELECT COALESCE(md5(string_agg(t::text, ',' ORDER BY t::text)), 'EMPTY') FROM analytics.demand_state t;")"

hold_lock_bg "analytics.run_demand_calculation_job" 30
wait_for_foreign_advisory_lock

psql_f <<SQL
DO \$\$
DECLARE
    v_status TEXT;
    v_ds_now TEXT;
BEGIN
    CALL analytics.run_demand_calculation_job(999208, '{"lookback":"3 hours"}'::jsonb);

    SELECT last_status INTO v_status FROM telemetry.pipeline_state WHERE pipeline_name = 'demand_intervals';
    SELECT COALESCE(md5(string_agg(t::text, ',' ORDER BY t::text)), 'EMPTY') INTO v_ds_now FROM analytics.demand_state t;

    IF v_status IS DISTINCT FROM 'SKIPPED_LOCKED' THEN
        RAISE EXCEPTION 'FAILED: concurrent demand run should be SKIPPED_LOCKED, got %', v_status;
    END IF;
    IF v_ds_now IS DISTINCT FROM '${DS_BEFORE}' THEN
        RAISE EXCEPTION 'FAILED: SKIPPED_LOCKED demand run mutated analytics.demand_state';
    END IF;
    RAISE NOTICE 'PASS: demand concurrent invocation -> SKIPPED_LOCKED, analytics.demand_state unchanged (no double-apply).';
END \$\$;
SQL

echo "Analytics job self-overlap assertions passed."
