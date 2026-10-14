#!/usr/bin/env bash
# ============================================================================
# Migration 301 -- telemetry.device_telemetry_state upserts lock rows in
# device_id order in both writers (job 1000 vs job 1060 deadlock fix).
#
# Multi-session test. A blocker session updates (and so locks) the middle row
# of 40 fixture device rows and holds it until released. A worker session
# runs a device_telemetry_state upsert over all 40 devices and blocks on that
# row. While it waits, a probe session reads the fixture rows FOR UPDATE SKIP
# LOCKED: the rows it cannot get (minus the blocker's row) are exactly the
# rows the worker has already locked. A writer that locks in ascending
# device_id holds exactly the 19 rows below the middle one.
#
# The statements under test are taken from the installed procedure bodies
# (pg_proc.prosrc), so the test runs exactly what the jobs run. The pre-fix
# statements are taken from the migration 221 / 007 files.
#
# Covered:
#   C-BODY    installed bodies are the migration 301 bodies (md5) and each
#             device_telemetry_state upsert has ORDER BY directly before
#             ON CONFLICT.
#   L-1000    job 1000's installed upsert, input in shuffled physical order,
#             HashAggregate forced (enable_sort=off, as on production):
#             locks rows 1..19 only (ascending).
#   L-1060    job 1060's installed upsert, input in DESCENDING physical
#             order: locks rows 1..19 only (ascending).
#   R-1060    reproduction: job 1060's pre-fix upsert (migration 007), same
#             descending input: locks rows 21..40 (input order, not sorted).
#   R-1000    reproduction: job 1000's pre-fix upsert (migration 221), same
#             input and plan settings: not the ascending prefix (hash order).
#   D-OLD     reproduction of the production deadlock: pre-fix job 1060
#             upsert (descending) and installed job 1000 upsert (ascending)
#             both blocked on the middle row; on release exactly one of them
#             fails with 40P01.
#   D-FIXED   same setup with both installed upserts: no deadlock, both
#             complete (the second waits for the first, then finishes).
#   P-1060    end to end: CALL telemetry.load_device_raw_receipt_state_
#             incremental over 40 fixture devices / raw messages while the
#             middle row is held: locks rows 1..19 only, then completes with
#             SUCCESS and updates all 40 rows.
#
# Not covered end to end: CALL telemetry.load_normalized_points_incremental
# (needs a full mapping / capture-policy fixture); L-1000 runs its installed
# statement text, and C-BODY proves that text is the procedure's.
#
# Fixture: 40 device_telemetry_state rows for fixed md5-derived UUIDs, a
# flag table and a helper function, all removed on exit. P-1060's devices
# and raw messages are created inside its own transaction and rolled back.
# Every worker transaction rolls back.
# ============================================================================
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
WORK="$(mktemp -d)"

db() {
    docker compose -f "${PROJECT_ROOT}/compose.test.yaml" exec -T timescaledb-test \
        psql -X -q -v ON_ERROR_STOP=1 -U ems_admin -d ems_test "$@"
}

cleanup() {
    local pids
    pids="$(jobs -p)"
    [[ -n "${pids}" ]] && kill ${pids} 2>/dev/null || true
    db >/dev/null 2>&1 <<'SQL' || true
DELETE FROM telemetry.device_telemetry_state
WHERE device_id IN (SELECT md5('dts-lock-order-' || n)::uuid FROM generate_series(1, 40) AS n);
DROP FUNCTION IF EXISTS public.dts_lock_order_ids();
DROP TABLE IF EXISTS public.dts_lock_order_flag;
SQL
    rm -rf "${WORK}"
}
trap cleanup EXIT

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

printf '%s\n' '=== device_telemetry_state upsert lock order assertions (migration 301) ==='

# ---------------------------------------------------------------------------
# Fixture
# ---------------------------------------------------------------------------
db <<'SQL'
CREATE TABLE public.dts_lock_order_flag (k text PRIMARY KEY);

CREATE FUNCTION public.dts_lock_order_ids()
RETURNS TABLE (id uuid, rn integer)
LANGUAGE sql STABLE
AS $f$
    SELECT f.id, (row_number() OVER (ORDER BY f.id))::integer
    FROM (SELECT md5('dts-lock-order-' || n)::uuid AS id FROM generate_series(1, 40) AS n) AS f
$f$;

INSERT INTO telemetry.device_telemetry_state (device_id, latest_received_timestamp, updated_at)
SELECT id, TIMESTAMPTZ '2000-01-01 00:00:00+00', now()
FROM public.dts_lock_order_ids();
SQL

# ---------------------------------------------------------------------------
# C-BODY
# ---------------------------------------------------------------------------
db <<'SQL'
DO $c$
DECLARE
    v_norm text;
    v_raw text;
BEGIN
    SELECT replace(prosrc, E'\r', '') INTO v_norm FROM pg_proc
    WHERE oid = 'telemetry.load_normalized_points_incremental(interval,interval)'::regprocedure;
    SELECT replace(prosrc, E'\r', '') INTO v_raw FROM pg_proc
    WHERE oid = 'telemetry.load_device_raw_receipt_state_incremental(interval)'::regprocedure;

    IF md5(v_norm) <> 'f1b39ab20a2cd3a4059147d0bb1bef8e' OR md5(v_raw) <> '7e2112edee424957ea00289ce449a622' THEN
        RAISE EXCEPTION 'C-BODY FAILED: installed loader bodies are not the migration 301 bodies (% / %)', md5(v_norm), md5(v_raw);
    END IF;
    IF position(E'    GROUP BY b.device_id\n    ORDER BY b.device_id\n    ON CONFLICT (device_id) DO UPDATE' IN v_norm) = 0
       OR position(E'    FROM tmp_raw_receipt_batch\n    ORDER BY device_id\n    ON CONFLICT (device_id) DO UPDATE\n    SET latest_received_timestamp' IN v_raw) = 0 THEN
        RAISE EXCEPTION 'C-BODY FAILED: a device_telemetry_state upsert lacks ORDER BY before ON CONFLICT';
    END IF;
    RAISE NOTICE 'C-BODY passed: both installed device_telemetry_state upserts are ordered by device_id.';
END;
$c$;
SQL

# ---------------------------------------------------------------------------
# Session SQL
# ---------------------------------------------------------------------------
old_statement() {
    # $1 = migration file, $2 = procedure whose body holds the statement
    awk -v proc="PROCEDURE telemetry.$2" '
        index($0, proc) { p = 1 }
        p && /INSERT INTO telemetry.device_telemetry_state/ { s = 1 }
        s { print }
        s && /;[[:space:]]*$/ { exit }
    ' "${PROJECT_ROOT}/postgres/migrations/$1" | tr -d '\r'
}

OLD_1000="$(old_statement 221_normalization_selected_elements_pk_join.sql load_normalized_points_incremental)"
OLD_1060="$(old_statement 007_site_frequency_normalization_recovery.sql load_device_raw_receipt_state_incremental)"
[[ "${OLD_1000}" == *"GROUP BY b.device_id"* && "${OLD_1000}" != *"ORDER BY"* ]] || fail "could not extract the migration 221 statement"
[[ "${OLD_1060}" == *"FROM tmp_raw_receipt_batch"* && "${OLD_1060}" != *"ORDER BY"* ]] || fail "could not extract the migration 007 statement"

blocker_sql() {
    sed "s/__LABEL__/$1/g" <<'SQL'
SET application_name = 'dts_blocker___LABEL__';
BEGIN;
UPDATE telemetry.device_telemetry_state SET updated_at = now()
WHERE device_id = (SELECT id FROM public.dts_lock_order_ids() WHERE rn = 20);
DO $b$
BEGIN
    WHILE NOT EXISTS (SELECT 1 FROM public.dts_lock_order_flag WHERE k = '__LABEL__') LOOP
        PERFORM pg_sleep(0.05);
    END LOOP;
END;
$b$;
COMMIT;
SQL
}

# $1 = label, $2 = 1000|1060 (which temp batch to build), $3 = installed|old
statement_worker_sql() {
    local label="$1" batch="$2" source="$3"
    printf '%s\n' '\set VERBOSITY verbose' \
        "SET application_name = 'dts_${label}';" \
        "SET lock_timeout = '60s';" \
        "SET enable_sort = off;" \
        'BEGIN;'
    if [[ "${batch}" == 1000 ]]; then
        cat <<'SQL'
CREATE TEMP TABLE tmp_normalized_batch ON COMMIT DROP AS
SELECT f.id AS device_id,
       now() - make_interval(secs => k) AS event_time,
       now() - make_interval(secs => k) AS received_at,
       NULL::text AS quality_code,
       1.0::double precision AS numeric_value,
       '1'::text AS raw_value
FROM public.dts_lock_order_ids() AS f
CROSS JOIN generate_series(1, 3) AS k
ORDER BY md5(f.id::text || k::text);
SQL
    else
        cat <<'SQL'
CREATE TEMP TABLE tmp_raw_receipt_batch ON COMMIT DROP AS
SELECT f.id AS device_id, now() AS received_at, now() AS source_timestamp, 0::bigint AS raw_message_id
FROM public.dts_lock_order_ids() AS f
ORDER BY f.id DESC;
SQL
    fi
    if [[ "${source}" == installed ]]; then
        local sig
        if [[ "${batch}" == 1000 ]]; then
            sig='telemetry.load_normalized_points_incremental(interval,interval)'
        else
            sig='telemetry.load_device_raw_receipt_state_incremental(interval)'
        fi
        cat <<SQL
SELECT set_config('dts.stmt', rtrim(substring(s FROM 1 FOR position(';' IN s) - 1)), false) IS NOT NULL AS stmt_set
FROM (SELECT substring(prosrc FROM position('INSERT INTO telemetry.device_telemetry_state' IN prosrc)) AS s
      FROM pg_proc WHERE oid = '${sig}'::regprocedure) AS x \gset
SQL
    else
        printf '%s\n' "SELECT set_config('dts.stmt', rtrim(:'old_stmt', E'; \\n'), false) IS NOT NULL AS stmt_set \\gset"
    fi
    cat <<'SQL'
DO $w$ BEGIN EXECUTE current_setting('dts.stmt'); END; $w$;
SELECT 'WORKER_OK' AS result;
ROLLBACK;
SQL
}

proc_1060_worker_sql() {
    sed "s/__LABEL__/$1/g" <<'SQL'
\set VERBOSITY verbose
SET application_name = 'dts___LABEL__';
SET lock_timeout = '60s';
BEGIN;
-- Same advisory key as the procedure (re-entrant for this session), so the
-- scheduler's own run of job 1060 cannot run this batch concurrently.
SELECT pg_advisory_xact_lock(hashtextextended('telemetry.load_device_raw_receipt_state_incremental', 0)) IS NOT NULL AS locked \gset

WITH o AS (
    INSERT INTO metadata.organizations (name, code) VALUES ('DTS Lock Order Org', 'DTS_LOCK_ORDER_ORG') RETURNING id
), s AS (
    INSERT INTO metadata.sites (organization_id, name, code)
    SELECT id, 'DTS Lock Order Site', 'DTS_LOCK_ORDER_SITE' FROM o RETURNING id, organization_id
), g AS (
    INSERT INTO metadata.gateways (organization_id, site_id, name, external_id)
    SELECT organization_id, id, 'DTS Lock Order GW', 'DTS-LOCK-GW' FROM s RETURNING id, organization_id
), d AS (
    INSERT INTO metadata.devices (id, organization_id, gateway_id, name, external_id)
    SELECT f.id, g.organization_id, g.id, 'dts-' || f.rn, 'DTS-LOCK-' || f.rn
    FROM public.dts_lock_order_ids() AS f, g
    RETURNING id, external_id
)
INSERT INTO metadata.device_identifiers (device_id, identifier_type, identifier_value)
SELECT id, 'MQTT_UID', external_id FROM d;

SELECT set_config('dts.t0', (date_trunc('second', now()) + INTERVAL '100 days')::text, false) IS NOT NULL AS t0_set \gset

INSERT INTO telemetry.raw_messages (received_at, source_protocol, source_topic, payload)
SELECT current_setting('dts.t0')::timestamptz + make_interval(secs => f.rn / 1000.0),
       'MQTT', 'test/dts-lock-order',
       jsonb_build_object('rtdata', jsonb_build_array(jsonb_build_object(
           'uid', 'DTS-LOCK-' || f.rn,
           'ts', extract(epoch FROM current_setting('dts.t0')::timestamptz))))
FROM public.dts_lock_order_ids() AS f
ORDER BY f.id DESC;

UPDATE telemetry.pipeline_state
SET last_received_at = current_setting('dts.t0')::timestamptz - INTERVAL '1 minute'
WHERE pipeline_name = 'raw_receipt_state';

CALL telemetry.load_device_raw_receipt_state_incremental(INTERVAL '2 minutes');

DO $v$
DECLARE
    v_status text;
    v_rows integer;
BEGIN
    SELECT last_status INTO v_status FROM telemetry.pipeline_state WHERE pipeline_name = 'raw_receipt_state';
    SELECT count(*) INTO v_rows
    FROM telemetry.device_telemetry_state AS t
    JOIN public.dts_lock_order_ids() AS f ON f.id = t.device_id
    WHERE t.latest_received_timestamp = current_setting('dts.t0')::timestamptz + make_interval(secs => f.rn / 1000.0);
    IF v_status <> 'SUCCESS' OR v_rows <> 40 THEN
        RAISE EXCEPTION 'P-1060 FAILED: status %, % of 40 device_telemetry_state rows updated', v_status, v_rows;
    END IF;
END;
$v$;
SELECT 'WORKER_OK' AS result;
ROLLBACK;
SQL
}

# ---------------------------------------------------------------------------
# Session control
# ---------------------------------------------------------------------------
wait_for() {
    # $1 = application_name, $2 = SQL condition on pg_stat_activity
    local i
    for i in $(seq 1 300); do
        if [[ "$(db -At -c "SELECT count(*) FROM pg_stat_activity WHERE application_name = '$1' AND $2")" == 1 ]]; then
            return 0
        fi
        sleep 0.1
    done
    fail "timed out waiting for session $1 ($2)"
}

wait_blocked_by() {
    # $1 = waiting session, $2 = session expected to block it
    wait_for "$1" "wait_event_type = 'Lock' AND (SELECT b.pid FROM pg_stat_activity AS b WHERE b.application_name = '$2') = ANY (pg_blocking_pids(pid))"
}

start_blocker() {
    blocker_sql "$1" | db > "${WORK}/$1.blocker" 2>&1 &
    BLOCKER_PID=$!
    wait_for "dts_blocker_$1" "wait_event = 'PgSleep'"
}

release() {
    db -c "INSERT INTO public.dts_lock_order_flag (k) VALUES ('$1');"
    wait "${BLOCKER_PID}" || fail "blocker $1 failed: $(cat "${WORK}/$1.blocker")"
}

probe_held_rows() {
    db -At <<'SQL'
BEGIN;
WITH unlocked AS (
    SELECT device_id FROM telemetry.device_telemetry_state
    WHERE device_id IN (SELECT id FROM public.dts_lock_order_ids())
    FOR UPDATE SKIP LOCKED
)
SELECT coalesce(string_agg(f.rn::text, ',' ORDER BY f.rn), '')
FROM public.dts_lock_order_ids() AS f
WHERE f.rn <> 20 AND f.id NOT IN (SELECT device_id FROM unlocked);
ROLLBACK;
SQL
}

ASCENDING="$(seq -s, 1 19)"
DESCENDING_INPUT="$(seq -s, 21 40)"

# $1 = label, $2 = worker SQL file, $3 = expected held rows, $4 = eq|ne
lock_order_case() {
    local label="$1" sql="$2" expected="$3" mode="$4" held rc=0
    start_blocker "${label}"
    db -v old_stmt="${OLD_STMT:-}" < "${sql}" > "${WORK}/${label}.out" 2>&1 &
    local worker=$!
    wait_blocked_by "dts_${label}" "dts_blocker_${label}"
    held="$(probe_held_rows)"
    release "${label}"
    wait "${worker}" || rc=$?
    [[ ${rc} == 0 ]] && grep -q WORKER_OK "${WORK}/${label}.out" \
        || fail "${label}: worker failed: $(cat "${WORK}/${label}.out")"
    if [[ "${mode}" == eq ]]; then
        [[ "${held}" == "${expected}" ]] || fail "${label}: held rows [${held}], expected [${expected}]"
        echo "${label} passed: held rows [${held}] while blocked on row 20."
    else
        [[ -n "${held}" && "${held}" != "${expected}" ]] || fail "${label}: held rows [${held}], expected anything but [${expected}]"
        echo "${label} passed: pre-fix statement held rows [${held}] (not the ascending prefix)."
    fi
}

statement_worker_sql L-1000 1000 installed > "${WORK}/L-1000.sql"
statement_worker_sql L-1060 1060 installed > "${WORK}/L-1060.sql"
statement_worker_sql R-1060 1060 old > "${WORK}/R-1060.sql"
statement_worker_sql R-1000 1000 old > "${WORK}/R-1000.sql"
proc_1060_worker_sql P-1060 > "${WORK}/P-1060.sql"

OLD_STMT='' lock_order_case L-1000 "${WORK}/L-1000.sql" "${ASCENDING}" eq
OLD_STMT='' lock_order_case L-1060 "${WORK}/L-1060.sql" "${ASCENDING}" eq
OLD_STMT="${OLD_1060}" lock_order_case R-1060 "${WORK}/R-1060.sql" "${DESCENDING_INPUT}" eq
OLD_STMT="${OLD_1000}" lock_order_case R-1000 "${WORK}/R-1000.sql" "${ASCENDING}" ne
OLD_STMT='' lock_order_case P-1060 "${WORK}/P-1060.sql" "${ASCENDING}" eq

# ---------------------------------------------------------------------------
# D-OLD / D-FIXED: two writers blocked on the middle row, then released.
# ---------------------------------------------------------------------------
# $1 = label, $2 = first worker SQL, $3 = its old_stmt, $4 = second worker SQL,
# $5 = session the second worker waits behind
deadlock_case() {
    local label="$1" rc_a=0 rc_b=0
    start_blocker "${label}"
    db -v old_stmt="$3" < "$2" > "${WORK}/${label}.a" 2>&1 &
    local a=$!
    wait_blocked_by "dts_${label}-A" "dts_blocker_${label}"
    db < "$4" > "${WORK}/${label}.b" 2>&1 &
    local b=$!
    wait_blocked_by "dts_${label}-B" "$5"
    release "${label}"
    wait "${a}" || rc_a=$?
    wait "${b}" || rc_b=$?
    DEADLOCKS="$(cat "${WORK}/${label}.a" "${WORK}/${label}.b" | grep -c '40P01' || true)"
    RC_A=${rc_a}
    RC_B=${rc_b}
}

statement_worker_sql D-OLD-A 1060 old > "${WORK}/D-OLD-A.sql"
statement_worker_sql D-OLD-B 1000 installed > "${WORK}/D-OLD-B.sql"
deadlock_case D-OLD "${WORK}/D-OLD-A.sql" "${OLD_1060}" "${WORK}/D-OLD-B.sql" dts_blocker_D-OLD
if [[ "${DEADLOCKS}" != 1 ]] || (( (RC_A == 0) == (RC_B == 0) )); then
    fail "D-OLD: expected exactly one 40P01 (rc ${RC_A}/${RC_B}): $(cat "${WORK}/D-OLD.a" "${WORK}/D-OLD.b")"
fi
echo "D-OLD passed: pre-fix job 1060 upsert vs job 1000 upsert deadlocked (one 40P01), reproducing production."

statement_worker_sql D-FIXED-A 1060 installed > "${WORK}/D-FIXED-A.sql"
statement_worker_sql D-FIXED-B 1000 installed > "${WORK}/D-FIXED-B.sql"
deadlock_case D-FIXED "${WORK}/D-FIXED-A.sql" "" "${WORK}/D-FIXED-B.sql" dts_D-FIXED-A
if [[ "${DEADLOCKS}" != 0 || ${RC_A} != 0 || ${RC_B} != 0 ]] \
   || ! grep -q WORKER_OK "${WORK}/D-FIXED.a" || ! grep -q WORKER_OK "${WORK}/D-FIXED.b"; then
    fail "D-FIXED: expected both writers to complete (rc ${RC_A}/${RC_B}): $(cat "${WORK}/D-FIXED.a" "${WORK}/D-FIXED.b")"
fi
echo "D-FIXED passed: installed job 1060 and job 1000 upserts both completed, no deadlock."

echo "All migration 301 lock order assertions passed."
