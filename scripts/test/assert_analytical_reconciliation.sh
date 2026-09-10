#!/usr/bin/env bash
# ============================================================================
# Migration 213 — analytical reconciliation layer contracts.
#
# Part 1 (main heredoc, rollback-only): schema / procedure / job / config
#   contracts, forward-watermark-safety, no-refresh_continuous_aggregate,
#   and behavioural fixtures for the helper-driven and inline-detector tiers.
#   The seven FORWARD-job advisory keys are held for the whole transaction
#   (re-entrant within this session -> our own CALLs proceed) so the
#   TimescaleDB scheduler cannot race the fixtures.
#
# Part 2 (cross-session): a background session holds a forward-job advisory
#   lock; a fresh foreground session runs a reconcile proc and must record
#   outcome='SKIPPED_LOCKED' (proving the shared-lock contract).
# ============================================================================
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
COMPOSE_FILE="${PROJECT_ROOT}/compose.test.yaml"

printf '%s\n' '=== analytical reconciliation assertions (migration 213) ==='

psql_f() {
    docker compose -f "${COMPOSE_FILE}" exec -T timescaledb-test \
        psql -X -v ON_ERROR_STOP=1 -U ems_admin -d ems_test -f -
}

BG_PIDS=()
cleanup() { for p in "${BG_PIDS[@]:-}"; do kill "${p}" >/dev/null 2>&1 || true; wait "${p}" 2>/dev/null || true; done; }
trap cleanup EXIT

hold_lock_bg() {
    local proc="$1" secs="$2"
    docker compose -f "${COMPOSE_FILE}" exec -T timescaledb-test \
        psql -X -q -v ON_ERROR_STOP=1 -U ems_admin -d ems_test <<SQL >/dev/null 2>&1 &
SELECT pg_advisory_lock(hashtextextended('${proc}', 0));
SELECT pg_sleep(${secs});
SELECT pg_advisory_unlock(hashtextextended('${proc}', 0));
SQL
    BG_PIDS+=("$!")
}

# ==========================================================================
# PART 1 — main heredoc
# ==========================================================================
psql_f <<'SQL'
BEGIN;

-- Block the scheduler for the duration (re-entrant for this session's CALLs).
SELECT pg_advisory_xact_lock(hashtextextended('analytics.run_energy_consumption_1min_job', 0));
SELECT pg_advisory_xact_lock(hashtextextended('analytics.run_energy_consumption_5min_job', 0));
SELECT pg_advisory_xact_lock(hashtextextended('analytics.run_energy_consumption_15min_job', 0));
SELECT pg_advisory_xact_lock(hashtextextended('analytics.run_energy_consumption_hourly_job', 0));
SELECT pg_advisory_xact_lock(hashtextextended('analytics.run_energy_consumption_daily_job', 0));
SELECT pg_advisory_xact_lock(hashtextextended('analytics.run_demand_calculation_job', 0));
SELECT pg_advisory_xact_lock(hashtextextended('telemetry.run_environment_daily_job', 0));

-- ======================================================================
-- A. schema: analytics.pipeline_reconciliation_log
-- ======================================================================
DO $t$
DECLARE v_n int;
BEGIN
    IF to_regclass('analytics.pipeline_reconciliation_log') IS NULL THEN
        RAISE EXCEPTION 'A FAILED: analytics.pipeline_reconciliation_log missing';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM timescaledb_information.hypertables
                   WHERE hypertable_schema='analytics' AND hypertable_name='pipeline_reconciliation_log') THEN
        RAISE EXCEPTION 'A FAILED: pipeline_reconciliation_log is not a hypertable';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_indexes WHERE schemaname='analytics'
                   AND tablename='pipeline_reconciliation_log' AND indexname='pipeline_reconciliation_log_pkey'
                   AND indexdef ILIKE '%(run_id, ran_at)%') THEN
        RAISE EXCEPTION 'A FAILED: PK is not (run_id, ran_at)';
    END IF;
    SELECT count(*) INTO v_n FROM pg_indexes WHERE schemaname='analytics'
      AND tablename='pipeline_reconciliation_log'
      AND indexname IN ('ix_pipeline_reconciliation_log_tier_time','ix_pipeline_reconciliation_log_attention');
    IF v_n <> 2 THEN RAISE EXCEPTION 'A FAILED: expected 2 named indexes, found %', v_n; END IF;
    IF NOT EXISTS (SELECT 1 FROM timescaledb_information.jobs
                   WHERE proc_name='policy_retention' AND hypertable_name='pipeline_reconciliation_log'
                     AND (config->>'drop_after')::interval = INTERVAL '180 days') THEN
        RAISE EXCEPTION 'A FAILED: 180-day retention policy not registered';
    END IF;
    IF NOT has_table_privilege('ems_readonly','analytics.pipeline_reconciliation_log','SELECT')
       OR NOT has_table_privilege('grafana_reader','analytics.pipeline_reconciliation_log','SELECT') THEN
        RAISE EXCEPTION 'A FAILED: SELECT not granted to ems_readonly / grafana_reader';
    END IF;
END;
$t$;
\echo 'PASS: A  pipeline_reconciliation_log = hypertable, PK (run_id, ran_at), 2 indexes, 180d retention, read grants'

-- ======================================================================
-- B/C. config.assert_reconciliation_job_config accept/reject
-- ======================================================================
DO $t$
DECLARE v_bad text;
BEGIN
    PERFORM config.assert_reconciliation_job_config(NULL);
    PERFORM config.assert_reconciliation_job_config('{"reconcile_window":"2 days","coarse":"1 hour","n_max":6,"lookback":"3 hours"}'::jsonb);
    FOREACH v_bad IN ARRAY ARRAY[
        '{"unknownkey":"x"}', '{"reconcile_window":"0 seconds"}', '{"reconcile_window":"-1 days"}',
        '{"coarse":"not-an-interval"}', '{"n_max":0}', '{"n_max":-3}', '{"n_max":"abc"}', '["array"]', '"scalar"'
    ] LOOP
        BEGIN
            PERFORM config.assert_reconciliation_job_config(v_bad::jsonb);
            RAISE EXCEPTION 'B FAILED: validator accepted invalid config %', v_bad;
        EXCEPTION WHEN OTHERS THEN
            IF SQLERRM LIKE 'B FAILED%' THEN RAISE; END IF;   -- re-raise our own
        END;
    END LOOP;
END;
$t$;
\echo 'PASS: B  config.assert_reconciliation_job_config accepts the 4 keys, rejects unknown/non-positive/non-object'

-- ======================================================================
-- C. the 7 reconcile procedures: exist, PROCEDURE, DEFINER, owner, pinned
--    search_path, REVOKE FROM PUBLIC; and the hard body contracts
--    (no last_received_at, no run_*_job, no refresh_continuous_aggregate,
--     correct advisory key, correct refresh_* call, record_reconciliation_run).
-- ======================================================================
DO $t$
DECLARE
    v RECORD;
    v_def text;
    v_fail text[] := ARRAY[]::text[];
BEGIN
    FOR v IN
        SELECT * FROM (VALUES
          ('analytics','reconcile_energy_consumption_1min','analytics.run_energy_consumption_1min_job','refresh_energy_consumption_1min('),
          ('analytics','reconcile_energy_consumption_5min','analytics.run_energy_consumption_5min_job','refresh_energy_consumption_5min('),
          ('analytics','reconcile_energy_consumption_15min','analytics.run_energy_consumption_15min_job','refresh_energy_consumption_15min('),
          ('analytics','reconcile_energy_consumption_hourly','analytics.run_energy_consumption_hourly_job','refresh_energy_consumption_hourly('),
          ('analytics','reconcile_energy_consumption_daily','analytics.run_energy_consumption_daily_job','refresh_energy_consumption_daily('),
          ('analytics','reconcile_demand_intervals','analytics.run_demand_calculation_job','refresh_demand_analytics('),
          ('telemetry','reconcile_environment_daily','telemetry.run_environment_daily_job','refresh_environment_daily(')
        ) AS t(sch, prc, fwd, refcall)
    LOOP
        IF NOT EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
                       WHERE n.nspname=v.sch AND p.proname=v.prc AND p.prokind='p'
                         AND p.prosecdef AND pg_get_userbyid(p.proowner)='ems_admin'
                         AND p.proconfig IS NOT NULL) THEN
            v_fail := v_fail || format('%s.%s not a DEFINER ems_admin PROCEDURE with pinned search_path', v.sch, v.prc);
            CONTINUE;
        END IF;
        IF has_function_privilege('public', format('%s.%s(integer,jsonb)', v.sch, v.prc), 'EXECUTE') THEN
            v_fail := v_fail || format('%s.%s EXECUTE not revoked from PUBLIC', v.sch, v.prc);
        END IF;
        v_def := pg_get_functiondef(format('%s.%s(integer,jsonb)', v.sch, v.prc)::regprocedure);
        -- HARD GATE: must never WRITE last_received_at (a SELECT ... INTO read to
        -- derive the reconcile window is expected and allowed).
        IF v_def ~ 'last_received_at[[:space:]]*=' THEN
            v_fail := v_fail || format('%s.%s assigns last_received_at', v.sch, v.prc);
        END IF;
        IF v_def ~* '(INSERT[[:space:]]+INTO|UPDATE|DELETE[[:space:]]+FROM)[[:space:]]+telemetry\.pipeline_state' THEN
            v_fail := v_fail || format('%s.%s runs DML against telemetry.pipeline_state', v.sch, v.prc);
        END IF;
        IF v_def ~* 'refresh_continuous_aggregate' THEN
            v_fail := v_fail || format('%s.%s calls refresh_continuous_aggregate', v.sch, v.prc);
        END IF;
        IF v_def ~ '(run_energy_consumption_[0-9a-z]+_job|run_demand_calculation_job|run_environment_daily_job)\s*\(' THEN
            v_fail := v_fail || format('%s.%s calls a run_*_job forward wrapper', v.sch, v.prc);
        END IF;
        -- advisory key: v_fwd_lock CONSTANT is set to the forward job name and
        -- fed straight into pg_try_advisory_xact_lock(hashtextextended(...)).
        IF position(format(':= %L', v.fwd) IN v_def) = 0
           OR position('pg_try_advisory_xact_lock(hashtextextended(v_fwd_lock, 0))' IN v_def) = 0 THEN
            v_fail := v_fail || format('%s.%s does not take the forward advisory key %s', v.sch, v.prc, v.fwd);
        END IF;
        IF position(v.refcall IN v_def) = 0 THEN
            v_fail := v_fail || format('%s.%s does not call %s', v.sch, v.prc, v.refcall);
        END IF;
        IF position('record_reconciliation_run(' IN v_def) = 0 THEN
            v_fail := v_fail || format('%s.%s does not call record_reconciliation_run', v.sch, v.prc);
        END IF;
    END LOOP;
    -- the read-only helper: no writes, no refresh_, no pipeline_state
    v_def := pg_get_functiondef('analytics.reconcile_energy_deficits(text,timestamptz,timestamptz,interval,integer)'::regprocedure);
    IF v_def ~* '(refresh_continuous_aggregate|refresh_energy_consumption|last_received_at|pipeline_state)'
       OR v_def ~* '\m(insert|update|delete)\M\s' THEN
        v_fail := v_fail || 'reconcile_energy_deficits is not read-only';
    END IF;
    IF array_length(v_fail,1) > 0 THEN
        RAISE EXCEPTION 'C FAILED: %', array_to_string(v_fail, '; ');
    END IF;
END;
$t$;
\echo 'PASS: C  7 reconcile procs: DEFINER/ems_admin/pinned/REVOKE; no last_received_at, no CAGG refresh, no wrapper call, correct advisory key + refresh_* + logger; helper read-only'

-- ======================================================================
-- D. the 7 calculation objects are UNCHANGED (still never write pipeline_state);
--    the complete set of last_received_at writers is exactly the 8 forward
--    wrappers + 5 telemetry loaders (13) -- reconciliation added none.
--    (Migration 230 / Phase 6 added telemetry.run_derived_space_dew_point_1min_job,
--    a watermark-driven FORWARD wrapper on the migration-211
--    run_environment_daily_job pattern; advancing last_received_at is its
--    designed behaviour. The migration-213 reconcile procs still write none.)
-- ======================================================================
DO $t$
DECLARE v_writers text[]; v_expected text[];
BEGIN
    SELECT array_agg(fq ORDER BY fq) INTO v_writers FROM (
        SELECT n.nspname||'.'||p.proname AS fq
        FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
        WHERE p.prokind IN ('f','p') AND n.nspname IN ('analytics','telemetry','config','metadata')
          AND pg_get_functiondef(p.oid) ~ 'last_received_at[[:space:]]*='
    ) s;
    SELECT array_agg(x ORDER BY x) INTO v_expected FROM unnest(ARRAY[
        'analytics.run_demand_calculation_job','analytics.run_energy_consumption_15min_job',
        'analytics.run_energy_consumption_1min_job','analytics.run_energy_consumption_5min_job',
        'analytics.run_energy_consumption_daily_job','analytics.run_energy_consumption_hourly_job',
        'telemetry.capture_raw_message_failures_incremental','telemetry.load_device_raw_receipt_state_incremental',
        'telemetry.load_energy_measurements_incremental','telemetry.load_environment_measurements_incremental',
        'telemetry.load_normalized_points_incremental','telemetry.run_derived_space_dew_point_1min_job',
        'telemetry.run_environment_daily_job']) x;
    IF v_writers IS DISTINCT FROM v_expected THEN
        RAISE EXCEPTION 'D FAILED: the last_received_at writer set changed: %', v_writers;
    END IF;
END;
$t$;
\echo 'PASS: D  last_received_at is written by exactly the 8 forward wrappers + 5 loaders -- reconciliation added no writer'

-- ======================================================================
-- E. the 7 reconcile jobs: registered once, correct schedule/runtime/retry/
--    check_config/config keys.
-- ======================================================================
DO $t$
DECLARE
    v RECORD; j RECORD; v_fail text[] := ARRAY[]::text[]; v_cnt int;
BEGIN
    FOR v IN
        SELECT * FROM (VALUES
          ('analytics','reconcile_energy_consumption_1min',  INTERVAL '1 hour',  INTERVAL '5 minutes',  INTERVAL '15 minutes','2 days','6'),
          ('analytics','reconcile_energy_consumption_5min',  INTERVAL '1 hour',  INTERVAL '5 minutes',  INTERVAL '15 minutes','7 days','6'),
          ('analytics','reconcile_energy_consumption_15min', INTERVAL '6 hours', INTERVAL '10 minutes', INTERVAL '30 minutes','8 days','6'),
          ('analytics','reconcile_energy_consumption_hourly',INTERVAL '12 hours',INTERVAL '10 minutes', INTERVAL '30 minutes','10 days','6'),
          ('analytics','reconcile_energy_consumption_daily', INTERVAL '24 hours',INTERVAL '10 minutes', INTERVAL '30 minutes','21 days','6'),
          ('analytics','reconcile_demand_intervals',         INTERVAL '1 hour',  INTERVAL '10 minutes', INTERVAL '15 minutes','6 hours',NULL),
          ('telemetry','reconcile_environment_daily',        INTERVAL '24 hours',INTERVAL '10 minutes', INTERVAL '30 minutes','35 days','8')
        ) AS t(sch, prc, sched, mrt, rp, rw, nmax)
    LOOP
        SELECT count(*) INTO v_cnt FROM timescaledb_information.jobs
        WHERE proc_schema=v.sch AND proc_name=v.prc;
        IF v_cnt <> 1 THEN v_fail := v_fail || format('%s.%s registered %s times', v.sch, v.prc, v_cnt); CONTINUE; END IF;
        SELECT schedule_interval, max_runtime, max_retries, retry_period, scheduled,
               config->>'reconcile_window' AS rw, config->>'n_max' AS nmax,
               check_schema, check_name
        INTO j FROM timescaledb_information.jobs WHERE proc_schema=v.sch AND proc_name=v.prc;
        IF j.schedule_interval <> v.sched THEN v_fail := v_fail || format('%s schedule %s<>%s', v.prc, j.schedule_interval, v.sched); END IF;
        IF j.max_runtime <> v.mrt THEN v_fail := v_fail || format('%s max_runtime %s<>%s', v.prc, j.max_runtime, v.mrt); END IF;
        IF j.max_retries <> 3 THEN v_fail := v_fail || format('%s max_retries %s<>3', v.prc, j.max_retries); END IF;
        IF j.retry_period <> v.rp THEN v_fail := v_fail || format('%s retry_period %s<>%s', v.prc, j.retry_period, v.rp); END IF;
        IF NOT j.scheduled THEN v_fail := v_fail || format('%s not scheduled', v.prc); END IF;
        IF j.rw IS DISTINCT FROM v.rw THEN v_fail := v_fail || format('%s config.reconcile_window %s<>%s', v.prc, j.rw, v.rw); END IF;
        IF j.nmax IS DISTINCT FROM v.nmax THEN v_fail := v_fail || format('%s config.n_max %s<>%s', v.prc, j.nmax, v.nmax); END IF;
        IF j.check_schema IS DISTINCT FROM 'config' OR j.check_name IS DISTINCT FROM 'assert_reconciliation_job_config' THEN
            v_fail := v_fail || format('%s check_config %s.%s', v.prc, j.check_schema, j.check_name);
        END IF;
    END LOOP;
    IF array_length(v_fail,1) > 0 THEN RAISE EXCEPTION 'E FAILED: %', array_to_string(v_fail,'; '); END IF;
END;
$t$;
\echo 'PASS: E  7 reconcile jobs registered once each with the expected schedule/runtime/retry/check_config/config'

-- ======================================================================
-- F. N2 + forward jobs untouched
-- ======================================================================
DO $t$
BEGIN
    IF (SELECT config->>'reconcile_window' FROM timescaledb_information.jobs
        WHERE proc_schema='analytics' AND proc_name='run_energy_consumption_15min_job') <> '8 days' THEN
        RAISE EXCEPTION 'F FAILED: run_energy_consumption_15min_job reconcile_window not raised to 8 days';
    END IF;
    IF (SELECT config->>'max_catchup_window' FROM timescaledb_information.jobs
        WHERE proc_schema='analytics' AND proc_name='run_demand_calculation_job') <> '6 hours' THEN
        RAISE EXCEPTION 'F FAILED: demand max_catchup_window changed';
    END IF;
    IF (SELECT config->>'reconcile_window' FROM timescaledb_information.jobs
        WHERE proc_schema='analytics' AND proc_name='run_demand_calculation_job') <> '6 hours' THEN
        RAISE EXCEPTION 'F FAILED: demand forward reconcile_window changed (should stay 6 hours)';
    END IF;
    IF (SELECT max_runtime FROM timescaledb_information.jobs
        WHERE proc_schema='analytics' AND proc_name='run_energy_consumption_1min_job') <> INTERVAL '5 minutes' THEN
        RAISE EXCEPTION 'F FAILED: forward 1min job max_runtime changed';
    END IF;
END;
$t$;
\echo 'PASS: F  N2 applied (15min reconcile_window 8d); forward job timing / demand max_catchup_window unchanged'

-- ======================================================================
-- G. behavioural: NO_CHECKPOINT + HEALTHY + watermark isolation
--    (fresh DB -> all 7 pipeline_state.last_received_at are NULL)
-- ======================================================================
DO $t$
DECLARE v RECORD; v_before timestamptz; v_after timestamptz; v_outcome text;
BEGIN
    FOR v IN SELECT * FROM (VALUES
        ('energy_consumption_1min','analytics.reconcile_energy_consumption_1min'),
        ('energy_consumption_5min','analytics.reconcile_energy_consumption_5min'),
        ('energy_consumption_15min','analytics.reconcile_energy_consumption_15min'),
        ('energy_consumption_hourly','analytics.reconcile_energy_consumption_hourly'),
        ('energy_consumption_daily','analytics.reconcile_energy_consumption_daily'),
        ('demand_intervals','analytics.reconcile_demand_intervals'),
        ('environment_daily','telemetry.reconcile_environment_daily')
    ) AS t(pipe, proc)
    LOOP
        SELECT last_received_at INTO v_before FROM telemetry.pipeline_state WHERE pipeline_name = v.pipe;
        EXECUTE format('CALL %s(0, %L::jsonb)', v.proc, '{}');
        SELECT last_received_at INTO v_after FROM telemetry.pipeline_state WHERE pipeline_name = v.pipe;
        IF v_after IS DISTINCT FROM v_before THEN
            RAISE EXCEPTION 'G FAILED: % advanced pipeline_state.last_received_at (% -> %)', v.pipe, v_before, v_after;
        END IF;
        SELECT outcome INTO v_outcome FROM analytics.pipeline_reconciliation_log
        WHERE tier = v.pipe ORDER BY ran_at DESC LIMIT 1;
        IF v_outcome <> 'NO_CHECKPOINT' THEN
            RAISE EXCEPTION 'G FAILED: % first run outcome % (expected NO_CHECKPOINT on fresh DB)', v.pipe, v_outcome;
        END IF;
    END LOOP;
END;
$t$;
\echo 'PASS: G  every reconcile proc: NULL checkpoint -> logs NO_CHECKPOINT, does NOT touch pipeline_state.last_received_at'


-- ======================================================================
-- Behavioural fixtures. One org, two sites (IST + a US zone with DST), a
-- site-scoped 60s capture policy for the IST site, and a 15min-row seeder.
-- Everything is rolled back with the enclosing transaction.
-- ======================================================================
CREATE TEMP TABLE r213 (k text PRIMARY KEY, u uuid) ON COMMIT DROP;

DO $fx$
DECLARE v_org uuid; v_ist uuid; v_ny uuid;
BEGIN
    INSERT INTO metadata.organizations(name, code) VALUES ('R213 Recon Org','R213_RECON_ORG')
    RETURNING id INTO v_org;
    INSERT INTO metadata.sites(organization_id, name, code, timezone)
    VALUES (v_org, 'R213 IST Site', 'R213_IST', 'Asia/Kolkata') RETURNING id INTO v_ist;
    INSERT INTO metadata.sites(organization_id, name, code, timezone)
    VALUES (v_org, 'R213 NY Site', 'R213_NY', 'America/New_York') RETURNING id INTO v_ny;
    INSERT INTO r213(k,u) VALUES ('org', v_org), ('ist', v_ist), ('ny', v_ny),
        ('dev_h', gen_random_uuid()), ('dev_k1', gen_random_uuid()), ('dev_k2', gen_random_uuid()),
        ('dev_k3', gen_random_uuid()), ('dev_l1', gen_random_uuid()), ('dev_l2', gen_random_uuid()),
        ('dev_iso', gen_random_uuid()), ('dev_1m', gen_random_uuid()), ('dev_15m', gen_random_uuid()),
        ('dev_day', gen_random_uuid()), ('dev_env', gen_random_uuid());
    -- site-scoped, long-effective capture policy so resolve_site_capture_bucket
    -- deterministically returns 60s for the IST site regardless of run time.
    INSERT INTO config.telemetry_capture_policies
        (site_id, capture_interval_seconds, late_arrival_tolerance_seconds, is_enabled, effective_from)
    VALUES (v_ist, 60, 900, TRUE, now() - INTERVAL '400 days');
END;
$fx$;

CREATE FUNCTION pg_temp.seed15(p_site_key text, p_dev uuid, p_bucket timestamptz,
                               p_sic bigint, p_calc timestamptz)
RETURNS void LANGUAGE plpgsql AS $h$
BEGIN
    INSERT INTO analytics.energy_consumption_15min
      (bucket_start, organization_id, site_id, device_id, source_interval_count,
       valid_import_intervals, invalid_import_intervals, valid_export_intervals, invalid_export_intervals,
       gap_interval_count, reset_interval_count, rollover_interval_count, invalid_interval_count, calculated_at)
    VALUES (p_bucket,
       (SELECT u FROM r213 WHERE k='org'), (SELECT u FROM r213 WHERE k=p_site_key), p_dev,
       p_sic, p_sic, 0, 0, 0, 0, 0, 0, 0, p_calc);
END;
$h$;

CREATE FUNCTION pg_temp.seed1m(p_site_key text, p_dev uuid, p_bucket timestamptz,
                               p_ssc bigint, p_calc timestamptz)
RETURNS void LANGUAGE plpgsql AS $h$
BEGIN
    INSERT INTO analytics.energy_consumption_1min
      (bucket_start, organization_id, site_id, device_id, source_sample_count,
       import_quality_code, import_is_valid, import_reset_detected, import_rollover_detected,
       export_quality_code, export_is_valid, export_reset_detected, export_rollover_detected,
       gap_detected, calculated_at)
    VALUES (p_bucket,
       (SELECT u FROM r213 WHERE k='org'), (SELECT u FROM r213 WHERE k=p_site_key), p_dev,
       p_ssc, 'GOOD', TRUE, FALSE, FALSE, 'GOOD', TRUE, FALSE, FALSE, FALSE, p_calc);
END;
$h$;

-- ======================================================================
-- H + X. hourly MISSING_CHILD -> refresh_energy_consumption_hourly writes the
--   row with source_interval_count = SUM(parent); outcome REPAIRED; the
--   inspected window is exactly [cp - reconcile_window, cp); the forward
--   checkpoint is untouched; a second org/site device whose hourly row is
--   already correct is NOT rewritten (tenant/scope isolation).
-- ======================================================================
DO $t$
DECLARE
    v_dev   uuid := (SELECT u FROM r213 WHERE k='dev_h');
    v_iso   uuid := (SELECT u FROM r213 WHERE k='dev_iso');
    -- UTC-aligned hour so the 4 quarter-hours fall in ONE date_bin('1 hour', .., UTC) bucket
    v_hr    timestamptz := date_bin('1 hour', now(), TIMESTAMPTZ '2000-01-01 00:00:00+00') - INTERVAL '3 days';
    v_cp    timestamptz := date_bin('1 hour', now(), TIMESTAMPTZ '2000-01-01 00:00:00+00') - INTERVAL '3 days' + INTERVAL '2 hours';
    v_before timestamptz; v_si bigint; v_outcome text; v_ws timestamptz; v_we timestamptz;
    v_iso_calc timestamptz;
    v_iso_ctid tid;   -- physical tuple id: migration 216 makes calculated_at value-aware,
                      -- so calculated_at alone can no longer distinguish "row untouched"
                      -- from "row rewritten with identical values"; ctid changes on ANY
                      -- heap-tuple rewrite (HOT or cold) and does not.
BEGIN
    PERFORM pg_temp.seed15('ist', v_dev, v_hr,                     4, v_hr + INTERVAL '1 min');
    PERFORM pg_temp.seed15('ist', v_dev, v_hr + INTERVAL '15 min', 5, v_hr + INTERVAL '1 min');
    PERFORM pg_temp.seed15('ist', v_dev, v_hr + INTERVAL '30 min', 3, v_hr + INTERVAL '1 min');
    PERFORM pg_temp.seed15('ist', v_dev, v_hr + INTERVAL '45 min', 2, v_hr + INTERVAL '1 min');

    -- an already-correct hourly row for a different device/site in a DIFFERENT
    -- coarse bucket (v_hr - 2h): reconcile repairs only v_hr's bucket, so this
    -- row must be byte-identical afterwards (no cross-bucket recompute).
    PERFORM pg_temp.seed15('ny', v_iso, v_hr - INTERVAL '2 hours', 7, v_hr - INTERVAL '2 hours' + INTERVAL '1 min');
    INSERT INTO analytics.energy_consumption_hourly
      (bucket_start, organization_id, site_id, device_id, source_interval_count,
       valid_import_intervals, invalid_import_intervals, valid_export_intervals, invalid_export_intervals,
       gap_interval_count, reset_interval_count, rollover_interval_count, invalid_interval_count, calculated_at)
    VALUES (v_hr - INTERVAL '2 hours', (SELECT u FROM r213 WHERE k='org'), (SELECT u FROM r213 WHERE k='ny'), v_iso,
            7, 7, 0, 0, 0, 0, 0, 0, 0, v_hr - INTERVAL '2 hours' + INTERVAL '2 min');
    SELECT calculated_at, ctid INTO v_iso_calc, v_iso_ctid FROM analytics.energy_consumption_hourly
      WHERE device_id = v_iso AND bucket_start = v_hr - INTERVAL '2 hours';

    UPDATE telemetry.pipeline_state SET last_received_at = v_cp, last_status='SUCCESS'
      WHERE pipeline_name = 'energy_consumption_hourly';
    SELECT last_received_at INTO v_before FROM telemetry.pipeline_state WHERE pipeline_name='energy_consumption_hourly';

    CALL analytics.reconcile_energy_consumption_hourly(0, '{"reconcile_window":"7 days","n_max":6}'::jsonb);

    SELECT source_interval_count INTO v_si FROM analytics.energy_consumption_hourly
      WHERE device_id = v_dev AND bucket_start = v_hr;
    IF v_si IS NULL THEN RAISE EXCEPTION 'H FAILED: hourly row not created by reconcile'; END IF;
    IF v_si <> 14 THEN RAISE EXCEPTION 'H FAILED: hourly source_interval_count % (expected SUM=14)', v_si; END IF;

    IF (SELECT last_received_at FROM telemetry.pipeline_state WHERE pipeline_name='energy_consumption_hourly')
       IS DISTINCT FROM v_before THEN
        RAISE EXCEPTION 'H FAILED: reconcile advanced the hourly forward checkpoint';
    END IF;

    SELECT outcome, window_start, window_end INTO v_outcome, v_ws, v_we
      FROM analytics.pipeline_reconciliation_log WHERE tier='energy_consumption_hourly' ORDER BY ran_at DESC LIMIT 1;
    IF v_outcome <> 'REPAIRED' THEN RAISE EXCEPTION 'H FAILED: outcome % (expected REPAIRED)', v_outcome; END IF;
    IF v_ws IS DISTINCT FROM v_cp - INTERVAL '7 days' OR v_we IS DISTINCT FROM v_cp THEN
        RAISE EXCEPTION 'H FAILED: inspected window [%,%) is not [cp - reconcile_window, cp) = [%,%)',
            v_ws, v_we, v_cp - INTERVAL '7 days', v_cp;
    END IF;

    IF (SELECT calculated_at FROM analytics.energy_consumption_hourly
        WHERE device_id = v_iso AND bucket_start = v_hr - INTERVAL '2 hours')
       IS DISTINCT FROM v_iso_calc THEN
        RAISE EXCEPTION 'X FAILED: a correct hourly row outside the repaired coarse bucket had its calculated_at changed';
    END IF;
    -- strengthened (migration 216): the tuple must not have been rewritten AT ALL,
    -- even with byte-identical values -- calculated_at is now value-aware and would
    -- be preserved on a spurious no-op re-refresh, so check the physical row version.
    IF (SELECT ctid FROM analytics.energy_consumption_hourly
        WHERE device_id = v_iso AND bucket_start = v_hr - INTERVAL '2 hours')
       IS DISTINCT FROM v_iso_ctid THEN
        RAISE EXCEPTION 'X FAILED: a correct hourly row outside the repaired coarse bucket was rewritten (ctid moved) even though its calculated_at was preserved';
    END IF;
END;
$t$;
\echo 'PASS: H/X  hourly MISSING_CHILD repaired (source_interval_count = SUM) via refresh_energy_consumption_hourly; window = [cp - reconcile_window, cp); forward checkpoint intact; a correct row in another coarse bucket is not rewritten (calculated_at AND ctid unchanged)'

-- ======================================================================
-- I. hourly idempotency: a second immediate run is HEALTHY, 0 repaired.
-- ======================================================================
DO $t$
DECLARE v_outcome text; v_rep bigint;
BEGIN
    CALL analytics.reconcile_energy_consumption_hourly(0, '{"reconcile_window":"7 days","n_max":6}'::jsonb);
    SELECT outcome, rows_repaired INTO v_outcome, v_rep
      FROM analytics.pipeline_reconciliation_log WHERE tier='energy_consumption_hourly' ORDER BY ran_at DESC LIMIT 1;
    IF v_outcome <> 'HEALTHY' OR v_rep <> 0 THEN
        RAISE EXCEPTION 'I FAILED: second run outcome %/rows_repaired % (expected HEALTHY/0)', v_outcome, v_rep;
    END IF;
END;
$t$;
\echo 'PASS: I  hourly reconcile idempotent (2nd run HEALTHY, 0 repaired)'

-- ======================================================================
-- K. n_max bound: 3 mismatching hours, n_max = 2 -> PARTIAL, exactly 2
--    repaired this run; draining runs then reach HEALTHY.
-- ======================================================================
DO $t$
DECLARE
    v_base   timestamptz := date_bin('1 hour', now(), TIMESTAMPTZ '2000-01-01 00:00:00+00') - INTERVAL '6 days';
    v_cp     timestamptz := date_bin('1 hour', now(), TIMESTAMPTZ '2000-01-01 00:00:00+00') - INTERVAL '4 days';
    v_outcome text; v_examined int; v_mismatch int; v_rep bigint;
BEGIN
    PERFORM pg_temp.seed15('ist', (SELECT u FROM r213 WHERE k='dev_k1'), v_base,                       3, v_base);
    PERFORM pg_temp.seed15('ist', (SELECT u FROM r213 WHERE k='dev_k2'), v_base + INTERVAL '1 hour',   4, v_base);
    PERFORM pg_temp.seed15('ist', (SELECT u FROM r213 WHERE k='dev_k3'), v_base + INTERVAL '2 hours',  5, v_base);
    UPDATE telemetry.pipeline_state SET last_received_at = v_cp, last_status='SUCCESS'
      WHERE pipeline_name = 'energy_consumption_hourly';

    CALL analytics.reconcile_energy_consumption_hourly(0, '{"reconcile_window":"3 days","n_max":2}'::jsonb);
    SELECT outcome, coarse_examined, coarse_mismatch, rows_repaired
      INTO v_outcome, v_examined, v_mismatch, v_rep
      FROM analytics.pipeline_reconciliation_log WHERE tier='energy_consumption_hourly' ORDER BY ran_at DESC LIMIT 1;
    IF v_outcome <> 'PARTIAL' OR v_mismatch <> 2 OR v_rep <> 2 THEN
        RAISE EXCEPTION 'K FAILED: n_max=2 over 3 mismatching hours -> outcome %/mismatch %/repaired % (expected PARTIAL/2/2)',
            v_outcome, v_mismatch, v_rep;
    END IF;

    CALL analytics.reconcile_energy_consumption_hourly(0, '{"reconcile_window":"3 days","n_max":10}'::jsonb);
    CALL analytics.reconcile_energy_consumption_hourly(0, '{"reconcile_window":"3 days","n_max":10}'::jsonb);
    SELECT outcome INTO v_outcome FROM analytics.pipeline_reconciliation_log
      WHERE tier='energy_consumption_hourly' ORDER BY ran_at DESC LIMIT 1;
    IF v_outcome <> 'HEALTHY' THEN
        RAISE EXCEPTION 'K FAILED: draining runs did not reach HEALTHY (got %)', v_outcome;
    END IF;
END;
$t$;
\echo 'PASS: K  n_max bounds one run (3 mismatching hours, n_max=2 -> PARTIAL / 2 repaired); successive runs drain to HEALTHY'

-- ======================================================================
-- L. per-unit failure isolation: a BEFORE trigger makes the second hour's
--    repair raise. The first hour was already repaired and PERSISTS; the run
--    logs FAILED with first_error_sqlstate set; the forward checkpoint is
--    untouched.
-- ======================================================================
DO $t$
DECLARE
    v_dev1   uuid := (SELECT u FROM r213 WHERE k='dev_l1');
    v_dev2   uuid := (SELECT u FROM r213 WHERE k='dev_l2');
    v_base   timestamptz := date_bin('1 hour', now(), TIMESTAMPTZ '2000-01-01 00:00:00+00') - INTERVAL '12 days';
    v_cp     timestamptz := date_bin('1 hour', now(), TIMESTAMPTZ '2000-01-01 00:00:00+00') - INTERVAL '9 days';
    v_outcome text; v_errs int; v_sqlstate text; v_before timestamptz;
BEGIN
    PERFORM pg_temp.seed15('ist', v_dev1, v_base,                     6, v_base);
    PERFORM pg_temp.seed15('ist', v_dev2, v_base + INTERVAL '1 hour', 6, v_base);
    UPDATE telemetry.pipeline_state SET last_received_at = v_cp, last_status='SUCCESS'
      WHERE pipeline_name = 'energy_consumption_hourly';
    SELECT last_received_at INTO v_before FROM telemetry.pipeline_state WHERE pipeline_name='energy_consumption_hourly';

    EXECUTE format($f$
        CREATE FUNCTION pg_temp.boom_hourly() RETURNS trigger LANGUAGE plpgsql AS $b$
        BEGIN
          IF NEW.bucket_start = %L::timestamptz THEN
             RAISE EXCEPTION 'r213 injected repair failure at %%', NEW.bucket_start;
          END IF;
          RETURN NEW;
        END; $b$;
    $f$, v_base + INTERVAL '1 hour');
    CREATE TRIGGER boom_hourly_trg BEFORE INSERT OR UPDATE ON analytics.energy_consumption_hourly
        FOR EACH ROW EXECUTE FUNCTION pg_temp.boom_hourly();

    CALL analytics.reconcile_energy_consumption_hourly(0, '{"reconcile_window":"5 days","n_max":10}'::jsonb);

    DROP TRIGGER boom_hourly_trg ON analytics.energy_consumption_hourly;

    SELECT outcome, error_count, first_error_sqlstate INTO v_outcome, v_errs, v_sqlstate
      FROM analytics.pipeline_reconciliation_log WHERE tier='energy_consumption_hourly' ORDER BY ran_at DESC LIMIT 1;
    IF v_outcome <> 'FAILED' OR v_errs <> 1 OR v_sqlstate IS NULL THEN
        RAISE EXCEPTION 'L FAILED: outcome %/errs %/sqlstate % (expected FAILED/1/<set>)', v_outcome, v_errs, v_sqlstate;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM analytics.energy_consumption_hourly
                   WHERE device_id = v_dev1 AND bucket_start = v_base) THEN
        RAISE EXCEPTION 'L FAILED: the earlier successful hourly re-drive did not persist through the later failure';
    END IF;
    IF (SELECT last_received_at FROM telemetry.pipeline_state WHERE pipeline_name='energy_consumption_hourly')
       IS DISTINCT FROM v_before THEN
        RAISE EXCEPTION 'L FAILED: a FAILED reconcile advanced the forward checkpoint';
    END IF;
END;
$t$;
\echo 'PASS: L  per-unit failure isolation: one hour repair raises -> loop stops, run logged FAILED + first_error_sqlstate, earlier re-drive persists, forward checkpoint intact'

-- ======================================================================
-- M. 15min detector (analytics.reconcile_energy_deficits): a (device, IST-
--    origin 15-min bucket) with native rows but no child -> flagged; a child
--    with matching count and newer calculated_at -> clear; bumping the native
--    calculated_at past the child -> flagged again (stale-by-recency).
-- ======================================================================
DO $t$
DECLARE
    v_dev uuid := (SELECT u FROM r213 WHERE k='dev_15m');
    v_b   timestamptz := date_trunc('hour', now()) - INTERVAL '2 days';
    v_ws  timestamptz := date_trunc('hour', now()) - INTERVAL '9 days';
    v_cp  timestamptz := date_trunc('hour', now());
    v_n   bigint;
BEGIN
    PERFORM pg_temp.seed1m('ist', v_dev, v_b,                   1, v_b + INTERVAL '2 min');
    PERFORM pg_temp.seed1m('ist', v_dev, v_b + INTERVAL '3 min',1, v_b + INTERVAL '4 min');

    SELECT count(*) INTO v_n FROM analytics.reconcile_energy_deficits('energy_consumption_15min', v_ws, v_cp, INTERVAL '1 hour', 10);
    IF v_n < 1 THEN RAISE EXCEPTION 'M FAILED: 15min detector missed a native-with-no-child 15-min bucket'; END IF;

    PERFORM pg_temp.seed15('ist', v_dev,
        date_bin('15 minutes', v_b, TIMESTAMPTZ '2000-01-01 05:30:00+05:30'),
        2, v_b + INTERVAL '30 min');
    SELECT count(*) INTO v_n FROM analytics.reconcile_energy_deficits('energy_consumption_15min', v_ws, v_cp, INTERVAL '1 hour', 10);
    IF v_n <> 0 THEN RAISE EXCEPTION 'M FAILED: 15min detector still flags after a matching child (count=2, newer calc)'; END IF;

    UPDATE analytics.energy_consumption_1min SET calculated_at = v_b + INTERVAL '90 min'
      WHERE device_id = v_dev;
    SELECT count(*) INTO v_n FROM analytics.reconcile_energy_deficits('energy_consumption_15min', v_ws, v_cp, INTERVAL '1 hour', 10);
    IF v_n < 1 THEN RAISE EXCEPTION 'M FAILED: 15min detector did not flag a child staler than its native parent (calculated_at recency)'; END IF;
END;
$t$;
\echo 'PASS: M  15min detector: native-without-child flagged; matching child clears; child staler than native re-flagged (calculated_at recency)'

-- ======================================================================
-- N. 1min detector: a ca_energy_1min bucket for an IST-site device (60s
--    capture policy) with no child -> flagged; a child whose source_sample_count
--    matches ca.sample_count -> clear; a child whose count disagrees -> flagged.
-- ======================================================================
DO $t$
DECLARE
    v_mat text;
    v_dev uuid := (SELECT u FROM r213 WHERE k='dev_1m');
    v_ist uuid := (SELECT u FROM r213 WHERE k='ist');
    v_org uuid := (SELECT u FROM r213 WHERE k='org');
    v_b   timestamptz := date_trunc('hour', now()) - INTERVAL '6 hours' + INTERVAL '3 min';
    v_ws  timestamptz := date_trunc('hour', now()) - INTERVAL '2 days';
    v_cp  timestamptz := date_trunc('hour', now());
    v_n   bigint;
BEGIN
    SELECT format('%I.%I', ht.schema_name, ht.table_name) INTO v_mat
    FROM _timescaledb_catalog.continuous_agg ca
    JOIN _timescaledb_catalog.hypertable ht ON ht.id = ca.mat_hypertable_id
    WHERE ca.user_view_name = 'ca_energy_1min';

    EXECUTE format('INSERT INTO %s (bucket_start, organization_id, site_id, device_id, sample_count) VALUES ($1,$2,$3,$4,5)', v_mat)
      USING v_b, v_org, v_ist, v_dev;

    SELECT count(*) INTO v_n FROM analytics.reconcile_energy_deficits('energy_consumption_1min', v_ws, v_cp, INTERVAL '1 hour', 10);
    IF v_n < 1 THEN RAISE EXCEPTION 'N FAILED: 1min detector missed a ca_energy_1min bucket with no child (capture policy / window issue)'; END IF;

    PERFORM pg_temp.seed1m('ist', v_dev, v_b, 5, v_b);
    SELECT count(*) INTO v_n FROM analytics.reconcile_energy_deficits('energy_consumption_1min', v_ws, v_cp, INTERVAL '1 hour', 10);
    IF v_n <> 0 THEN RAISE EXCEPTION 'N FAILED: 1min detector still flags after a matching child (source_sample_count=5=ca.sample_count)'; END IF;

    UPDATE analytics.energy_consumption_1min SET source_sample_count = 2 WHERE device_id = v_dev AND bucket_start = v_b;
    SELECT count(*) INTO v_n FROM analytics.reconcile_energy_deficits('energy_consumption_1min', v_ws, v_cp, INTERVAL '1 hour', 10);
    IF v_n < 1 THEN RAISE EXCEPTION 'N FAILED: 1min detector did not flag a child whose source_sample_count (2) disagrees with ca.sample_count (5)'; END IF;
END;
$t$;
\echo 'PASS: N  1min detector: ca_energy_1min bucket without child flagged; matching source_sample_count clears; disagreeing count re-flagged (capture-eligibility filter honoured)'

-- ======================================================================
-- P. daily reconcile: site-local-day MISSING_CHILD -> refresh_energy_consumption_daily
--    over the IST local day; source_interval_count = SUM(15min); REPAIRED;
--    forward checkpoint intact; second run HEALTHY.
-- ======================================================================
DO $t$
DECLARE
    v_dev uuid := (SELECT u FROM r213 WHERE k='dev_day');
    v_day date := (date_trunc('day', now()) - INTERVAL '4 days')::date;
    v_ls  timestamptz := (v_day::timestamp AT TIME ZONE 'Asia/Kolkata');
    v_cp  timestamptz := date_trunc('day', now());
    v_si bigint; v_outcome text; v_before timestamptz;
BEGIN
    PERFORM pg_temp.seed15('ist', v_dev, v_ls,                        6, v_ls + INTERVAL '1 min');
    PERFORM pg_temp.seed15('ist', v_dev, v_ls + INTERVAL '6 hours',   6, v_ls + INTERVAL '1 min');
    PERFORM pg_temp.seed15('ist', v_dev, v_ls + INTERVAL '18 hours',  6, v_ls + INTERVAL '1 min');
    UPDATE telemetry.pipeline_state SET last_received_at = v_cp, last_status='SUCCESS'
      WHERE pipeline_name = 'energy_consumption_daily';
    SELECT last_received_at INTO v_before FROM telemetry.pipeline_state WHERE pipeline_name='energy_consumption_daily';

    CALL analytics.reconcile_energy_consumption_daily(0, '{"reconcile_window":"10 days","n_max":6}'::jsonb);

    SELECT source_interval_count INTO v_si FROM analytics.energy_consumption_daily
      WHERE device_id = v_dev AND bucket_start = v_ls;
    IF v_si IS NULL THEN RAISE EXCEPTION 'P FAILED: daily row not created for the IST local day'; END IF;
    IF v_si <> 18 THEN RAISE EXCEPTION 'P FAILED: daily source_interval_count % (expected SUM=18)', v_si; END IF;
    IF (SELECT last_received_at FROM telemetry.pipeline_state WHERE pipeline_name='energy_consumption_daily')
       IS DISTINCT FROM v_before THEN
        RAISE EXCEPTION 'P FAILED: daily reconcile advanced the forward checkpoint';
    END IF;
    SELECT outcome INTO v_outcome FROM analytics.pipeline_reconciliation_log
      WHERE tier='energy_consumption_daily' ORDER BY ran_at DESC LIMIT 1;
    IF v_outcome <> 'REPAIRED' THEN RAISE EXCEPTION 'P FAILED: outcome % (expected REPAIRED)', v_outcome; END IF;

    CALL analytics.reconcile_energy_consumption_daily(0, '{"reconcile_window":"10 days","n_max":6}'::jsonb);
    SELECT outcome INTO v_outcome FROM analytics.pipeline_reconciliation_log
      WHERE tier='energy_consumption_daily' ORDER BY ran_at DESC LIMIT 1;
    IF v_outcome <> 'HEALTHY' THEN RAISE EXCEPTION 'P FAILED: 2nd daily run % (expected HEALTHY)', v_outcome; END IF;
END;
$t$;
\echo 'PASS: P  daily reconcile: IST site-local-day MISSING_CHILD repaired via refresh_energy_consumption_daily (source_interval_count = SUM); forward checkpoint intact; idempotent'

-- ======================================================================
-- T. environment_daily reconcile: an already-finalised US-zone local day gets
--    LATE_SOURCE rows -> telemetry.refresh_environment_daily re-drives it over
--    site-local bounds; sample_count grows; forward checkpoint intact; a strict
--    signal means a second run is HEALTHY.
-- ======================================================================
DO $t$
DECLARE
    v_dev  uuid := (SELECT u FROM r213 WHERE k='dev_env');
    v_ny   uuid := (SELECT u FROM r213 WHERE k='ny');
    v_org  uuid := (SELECT u FROM r213 WHERE k='org');
    v_day  date := (date_trunc('day', now()) - INTERVAL '5 days')::date;
    v_ls   timestamptz := (v_day::timestamp AT TIME ZONE 'America/New_York');
    v_le   timestamptz := ((v_day + 1)::timestamp AT TIME ZONE 'America/New_York');
    v_cp   timestamptz := date_trunc('day', now());
    v_cnt bigint; v_outcome text; v_before timestamptz;
BEGIN
    INSERT INTO telemetry.environment_measurements
        (bucket_start, source_timestamp, received_at, organization_id, site_id, device_id,
         measurement_interval_seconds, quality_code, is_estimated, temperature_c)
    VALUES (v_ls + INTERVAL '6 hours',  v_ls + INTERVAL '6 hours',  now(), v_org, v_ny, v_dev, 60, 0, FALSE, 10),
           (v_ls + INTERVAL '15 hours', v_ls + INTERVAL '15 hours', now(), v_org, v_ny, v_dev, 60, 0, FALSE, 12);
    PERFORM telemetry.refresh_environment_daily(v_ls, v_le);
    SELECT sample_count INTO v_cnt FROM telemetry.environment_daily WHERE device_id=v_dev AND bucket_start=v_ls;
    IF v_cnt IS DISTINCT FROM 2 THEN RAISE EXCEPTION 'T FAILED: seed sample_count % (expected 2)', v_cnt; END IF;

    INSERT INTO telemetry.environment_measurements
        (bucket_start, source_timestamp, received_at, organization_id, site_id, device_id,
         measurement_interval_seconds, quality_code, is_estimated, temperature_c)
    VALUES (v_ls + INTERVAL '9 hours',  v_ls + INTERVAL '9 hours',  now(), v_org, v_ny, v_dev, 60, 0, FALSE, 11),
           (v_ls + INTERVAL '20 hours', v_ls + INTERVAL '20 hours', now(), v_org, v_ny, v_dev, 60, 0, FALSE, 9),
           (v_ls + INTERVAL '23 hours', v_ls + INTERVAL '23 hours', now(), v_org, v_ny, v_dev, 60, 0, FALSE, 8);

    UPDATE telemetry.pipeline_state SET last_received_at = v_cp, last_status='SUCCESS'
      WHERE pipeline_name = 'environment_daily';
    SELECT last_received_at INTO v_before FROM telemetry.pipeline_state WHERE pipeline_name='environment_daily';

    CALL telemetry.reconcile_environment_daily(0, '{"reconcile_window":"20 days","n_max":8}'::jsonb);

    SELECT sample_count INTO v_cnt FROM telemetry.environment_daily WHERE device_id=v_dev AND bucket_start=v_ls;
    IF v_cnt <> 5 THEN RAISE EXCEPTION 'T FAILED: env_daily sample_count % after reconcile (expected 5)', v_cnt; END IF;
    IF (SELECT last_received_at FROM telemetry.pipeline_state WHERE pipeline_name='environment_daily')
       IS DISTINCT FROM v_before THEN
        RAISE EXCEPTION 'T FAILED: env reconcile advanced pipeline_state.last_received_at';
    END IF;
    SELECT outcome INTO v_outcome FROM analytics.pipeline_reconciliation_log
      WHERE tier='environment_daily' ORDER BY ran_at DESC LIMIT 1;
    IF v_outcome <> 'REPAIRED' THEN RAISE EXCEPTION 'T FAILED: outcome % (expected REPAIRED)', v_outcome; END IF;

    CALL telemetry.reconcile_environment_daily(0, '{"reconcile_window":"20 days","n_max":8}'::jsonb);
    SELECT outcome INTO v_outcome FROM analytics.pipeline_reconciliation_log
      WHERE tier='environment_daily' ORDER BY ran_at DESC LIMIT 1;
    IF v_outcome <> 'HEALTHY' THEN RAISE EXCEPTION 'T FAILED: 2nd env reconcile % (expected HEALTHY; strict signal must not re-flag)', v_outcome; END IF;
END;
$t$;
\echo 'PASS: T  environment_daily reconcile: LATE_SOURCE re-driven via refresh_environment_daily (site-local bounds); watermark intact; strict signal idempotent'

-- ======================================================================
-- S. demand reconcile: with a NULL checkpoint already covered in test G, here
--    assert the log row shape and that a checkpoint-present run over an empty
--    demand fixture is HEALTHY with the exact inspected window and no watermark
--    movement. (Full NO_DATA -> VALID re-finalisation is exercised by the
--    migration-210 fixture in assert_demand_watermark_refinalization.sh.)
-- ======================================================================
DO $t$
DECLARE v_cp timestamptz := date_trunc('hour', now()); v_outcome text; v_ws timestamptz; v_we timestamptz; v_before timestamptz;
BEGIN
    UPDATE telemetry.pipeline_state SET last_received_at = v_cp, last_status='SUCCESS'
      WHERE pipeline_name = 'demand_intervals';
    SELECT last_received_at INTO v_before FROM telemetry.pipeline_state WHERE pipeline_name='demand_intervals';

    CALL analytics.reconcile_demand_intervals(0, '{"reconcile_window":"6 hours","lookback":"3 hours"}'::jsonb);

    SELECT outcome, window_start, window_end INTO v_outcome, v_ws, v_we
      FROM analytics.pipeline_reconciliation_log WHERE tier='demand_intervals' ORDER BY ran_at DESC LIMIT 1;
    IF v_outcome NOT IN ('HEALTHY','REPAIRED') THEN
        RAISE EXCEPTION 'S FAILED: demand reconcile over an empty fixture outcome % (expected HEALTHY/REPAIRED)', v_outcome;
    END IF;
    IF v_ws IS DISTINCT FROM v_cp - INTERVAL '6 hours' OR v_we IS DISTINCT FROM v_cp THEN
        RAISE EXCEPTION 'S FAILED: demand inspected window [%,%) != [cp - 6h, cp)', v_ws, v_we;
    END IF;
    IF (SELECT last_received_at FROM telemetry.pipeline_state WHERE pipeline_name='demand_intervals')
       IS DISTINCT FROM v_before THEN
        RAISE EXCEPTION 'S FAILED: demand reconcile advanced pipeline_state.last_received_at';
    END IF;
END;
$t$;
\echo 'PASS: S  demand reconcile: bounded 4-arg refresh_demand_analytics path; inspected window = [cp - reconcile_window, cp); watermark intact (full NO_DATA->VALID re-finalisation covered by the 210 fixture)'
ROLLBACK;

SELECT 'analytical reconciliation main assertions passed.' AS result;
SQL

printf '%s\n' 'PASS: part 1 (contracts + behavioural) complete'

# ==========================================================================
# PART 2 — cross-session SKIPPED_LOCKED
# ==========================================================================
hold_lock_bg 'analytics.run_energy_consumption_1min_job' 25

psql_f <<'SQL'
BEGIN;
-- wait until the background session's advisory lock is visible from here
DO $w$
DECLARE v_tries int := 0;
BEGIN
    LOOP
        EXIT WHEN EXISTS (
            SELECT 1 FROM pg_locks l
            WHERE l.locktype = 'advisory'
              AND l.objid = (hashtextextended('analytics.run_energy_consumption_1min_job', 0) & 4294967295)::int8
              AND l.pid <> pg_backend_pid()
              AND l.granted
        );
        v_tries := v_tries + 1;
        IF v_tries > 200 THEN RAISE EXCEPTION 'PART2: background advisory lock never became visible'; END IF;
        PERFORM pg_sleep(0.05);
    END LOOP;
END;
$w$;

-- give the 1min reconcile a real checkpoint so it would otherwise do work
UPDATE telemetry.pipeline_state SET last_received_at = now() - INTERVAL '1 hour', last_status='SUCCESS'
  WHERE pipeline_name='energy_consumption_1min';

CALL analytics.reconcile_energy_consumption_1min(0, '{"reconcile_window":"2 days","n_max":6}'::jsonb);

DO $a$
DECLARE v_outcome text; v_ws timestamptz;
BEGIN
    SELECT outcome, window_start INTO v_outcome, v_ws
    FROM analytics.pipeline_reconciliation_log
    WHERE tier='energy_consumption_1min' ORDER BY ran_at DESC LIMIT 1;
    IF v_outcome <> 'SKIPPED_LOCKED' THEN
        RAISE EXCEPTION 'PART2 FAILED: reconcile ran despite the forward advisory lock being held (outcome %)', v_outcome;
    END IF;
    IF v_ws IS NOT NULL THEN
        RAISE EXCEPTION 'PART2 FAILED: SKIPPED_LOCKED row has a non-NULL window_start (%), analytical work leaked', v_ws;
    END IF;
END;
$a$;
ROLLBACK;

SELECT 'cross-session SKIPPED_LOCKED assertion passed.' AS result;
SQL

printf '%s\n' 'PASS: J (cross-session)  reconcile records SKIPPED_LOCKED when the forward job holds the advisory lock'

# ==========================================================================
# PART 3 — bgw_job_id_seq desynchronisation regression
#
# Reproduces the EXACT staging deploy failure: _timescaledb_catalog.bgw_job_id_seq
# lagging max(_timescaledb_config.bgw_job.id), so the first operation in
# migration 213 that allocates a background-job id -- add_retention_policy() in
# section 1, which calls add_job() internally -- fails with
#   ERROR: duplicate key value violates unique constraint "bgw_job_pkey"
#
#   3a  NEGATIVE CONTROL: with the desync in place and NO guard, prove
#       add_retention_policy() collides (SQLSTATE 23505) -- the staging failure.
#   3b  THE FIX: same desync, run migration 213's section-0 guard verbatim,
#       then run migration 213's section-1 shape (CREATE TABLE ->
#       create_hypertable -> index -> add_retention_policy) and assert it
#       SUCCEEDS and the 180-day retention job exists.
#   3c  Section-9 coverage retained: same desync + guard, tear down and
#       re-register the seven reconcile jobs via add_job().
#
# Rollback-only. add_job/add_retention_policy/CREATE TABLE are transactional;
# setval() is NOT, so the sequence is explicitly re-healed to a safe (>= max id)
# value before ROLLBACK. Throwaway hypertables (analytics._t213_seqreg_*) never
# touch analytics.pipeline_reconciliation_log or analytics.v_pipeline_health.
# ==========================================================================
psql_f <<'SQL'
BEGIN;

DO $seqreg$
DECLARE
    v_seq      CONSTANT text := '_timescaledb_catalog.bgw_job_id_seq';
    v_orig_max bigint;
    v_sqlstate text;
    v_ret_jobs int;
    v_new_cnt  int;
    v_new_min  bigint;
    v_anchor   timestamptz := date_trunc('hour', now()) + INTERVAL '1 hour';
    r RECORD;
BEGIN
    IF to_regclass(v_seq) IS NULL THEN
        RAISE NOTICE 'PART3 SKIPPED: % not present on this TimescaleDB build', v_seq;
        RETURN;
    END IF;

    -- ================= 3a. NEGATIVE CONTROL (no guard) =====================
    SELECT COALESCE(max(id), 0) INTO v_orig_max FROM _timescaledb_config.bgw_job;
    -- is_called=false => the next nextval() returns exactly this value, which
    -- is a live bgw_job id => add_retention_policy()'s internal add_job() will
    -- collide on bgw_job_pkey (create_hypertable itself allocates no job id).
    PERFORM setval(v_seq, v_orig_max - 1, false);
    BEGIN
        CREATE TABLE analytics._t213_seqreg_probe (ran_at timestamptz NOT NULL, v int);
        PERFORM create_hypertable('analytics._t213_seqreg_probe', 'ran_at',
            chunk_time_interval => INTERVAL '30 days');
        CREATE INDEX ix_t213_seqreg_probe ON analytics._t213_seqreg_probe (ran_at DESC);
        PERFORM add_retention_policy('analytics._t213_seqreg_probe', INTERVAL '180 days');
        RAISE EXCEPTION 'PART3 FAILED (3a): add_retention_policy() unexpectedly succeeded on a desynced sequence';
    EXCEPTION
        WHEN unique_violation THEN
            v_sqlstate := SQLSTATE;      -- 23505 -- the staging failure, reproduced
        WHEN OTHERS THEN
            IF SQLERRM LIKE 'PART3 FAILED%' THEN RAISE; END IF;
            RAISE EXCEPTION 'PART3 FAILED (3a): expected unique_violation on add_retention_policy(), got % / %', SQLSTATE, SQLERRM;
    END;
    IF v_sqlstate IS DISTINCT FROM '23505' THEN
        RAISE EXCEPTION 'PART3 FAILED (3a): staging failure mode not reproduced (sqlstate %)', v_sqlstate;
    END IF;
    RAISE NOTICE 'PART3 3a: reproduced the staging failure -- add_retention_policy() -> bgw_job_pkey (sqlstate 23505) on a desynced bgw_job_id_seq';

    -- ================= 3b. THE FIX: guard + section-1 path =================
    SELECT COALESCE(max(id), 0) INTO v_orig_max FROM _timescaledb_config.bgw_job;
    PERFORM setval(v_seq, v_orig_max - 1, false);          -- re-arm the exact collision

    -- migration 213 section-0 guard, VERBATIM
    IF to_regclass('_timescaledb_catalog.bgw_job_id_seq') IS NOT NULL THEN
        PERFORM setval(
            '_timescaledb_catalog.bgw_job_id_seq',
            GREATEST(
                (SELECT last_value FROM _timescaledb_catalog.bgw_job_id_seq),
                (SELECT COALESCE(max(id), 0) FROM _timescaledb_config.bgw_job)
            ),
            true
        );
    END IF;

    -- migration 213 section-1 shape: CREATE TABLE -> create_hypertable -> index
    -- -> add_retention_policy  (must now succeed under the once-desynced seq).
    CREATE TABLE analytics._t213_seqreg_fixed (ran_at timestamptz NOT NULL, v int);
    PERFORM create_hypertable('analytics._t213_seqreg_fixed', 'ran_at',
        chunk_time_interval => INTERVAL '30 days', if_not_exists => TRUE);
    CREATE INDEX ix_t213_seqreg_fixed ON analytics._t213_seqreg_fixed (ran_at DESC);
    PERFORM add_retention_policy('analytics._t213_seqreg_fixed',
        INTERVAL '180 days', if_not_exists => TRUE);

    SELECT count(*) INTO v_ret_jobs
    FROM timescaledb_information.jobs
    WHERE proc_name = 'policy_retention'
      AND hypertable_name = '_t213_seqreg_fixed'
      AND (config ->> 'drop_after')::interval = INTERVAL '180 days';
    IF v_ret_jobs <> 1 THEN
        RAISE EXCEPTION 'PART3 FAILED (3b): expected exactly 1 180-day retention job after the guarded add_retention_policy() path, got %', v_ret_jobs;
    END IF;
    RAISE NOTICE 'PART3 3b: guarded add_retention_policy() succeeded under a desynced bgw_job_id_seq; 180-day retention job present';

    -- ================= 3c. Section-9 add_job() loop coverage ===============
    SELECT COALESCE(max(id), 0) INTO v_orig_max FROM _timescaledb_config.bgw_job;
    PERFORM setval(v_seq, v_orig_max - 1, false);
    IF to_regclass('_timescaledb_catalog.bgw_job_id_seq') IS NOT NULL THEN
        PERFORM setval('_timescaledb_catalog.bgw_job_id_seq',
            GREATEST((SELECT last_value FROM _timescaledb_catalog.bgw_job_id_seq),
                     (SELECT COALESCE(max(id), 0) FROM _timescaledb_config.bgw_job)), true);
    END IF;

    PERFORM public.delete_job(job_id)
    FROM timescaledb_information.jobs
    WHERE proc_name LIKE 'reconcile\_%' AND proc_schema IN ('analytics','telemetry');

    FOR r IN
        SELECT * FROM (VALUES
            ('analytics'::text,'reconcile_energy_consumption_1min'::text,   INTERVAL '1 hour',  INTERVAL '31 minutes', jsonb_build_object('reconcile_window','2 days','coarse','1 hour','n_max',6)),
            ('analytics','reconcile_energy_consumption_5min',   INTERVAL '1 hour',  INTERVAL '33 minutes', jsonb_build_object('reconcile_window','7 days','coarse','1 hour','n_max',6)),
            ('analytics','reconcile_energy_consumption_15min',  INTERVAL '6 hours', INTERVAL '37 minutes', jsonb_build_object('reconcile_window','8 days','coarse','1 hour','n_max',6)),
            ('analytics','reconcile_energy_consumption_hourly', INTERVAL '12 hours',INTERVAL '41 minutes', jsonb_build_object('reconcile_window','10 days','coarse','1 hour','n_max',6)),
            ('analytics','reconcile_energy_consumption_daily',  INTERVAL '24 hours',INTERVAL '47 minutes', jsonb_build_object('reconcile_window','21 days','coarse','1 day','n_max',6)),
            ('analytics','reconcile_demand_intervals',          INTERVAL '1 hour',  INTERVAL '29 minutes', jsonb_build_object('reconcile_window','6 hours','lookback','3 hours')),
            ('telemetry','reconcile_environment_daily',         INTERVAL '24 hours',INTERVAL '51 minutes', jsonb_build_object('reconcile_window','35 days','n_max',8))
        ) AS t(sch,prc,sched,offs,cfg)
    LOOP
        PERFORM add_job(
            (r.sch||'.'||r.prc)::regproc,
            schedule_interval => r.sched,
            initial_start     => v_anchor + r.offs,
            config            => r.cfg,
            check_config      => 'config.assert_reconciliation_job_config'::regproc,
            fixed_schedule    => TRUE
        );
    END LOOP;

    SELECT count(*), COALESCE(min(job_id), 0)
    INTO v_new_cnt, v_new_min
    FROM timescaledb_information.jobs
    WHERE proc_name LIKE 'reconcile\_%' AND proc_schema IN ('analytics','telemetry');
    IF v_new_cnt <> 7 THEN
        RAISE EXCEPTION 'PART3 FAILED (3c): expected 7 reconcile jobs registered under a desynced sequence, got %', v_new_cnt;
    END IF;
    IF v_new_min <= v_orig_max THEN
        RAISE EXCEPTION 'PART3 FAILED (3c): re-registered job id % is not > pre-existing max id %', v_new_min, v_orig_max;
    END IF;
    RAISE NOTICE 'PART3 3c: 7 reconcile jobs registered under a desynced bgw_job_id_seq; min new id % > pre-existing max %', v_new_min, v_orig_max;

    -- Re-heal the non-transactional sequence before ROLLBACK drops this block's jobs.
    PERFORM setval(
        v_seq,
        GREATEST((SELECT last_value FROM _timescaledb_catalog.bgw_job_id_seq),
                 (SELECT COALESCE(max(id), 0) FROM _timescaledb_config.bgw_job)),
        true
    );
END
$seqreg$;

ROLLBACK;

SELECT 'bgw_job_id_seq desync regression (add_retention_policy + add_job) passed.' AS result;
SQL

printf '%s\n' 'PASS: PART 3 (sequence-resilience)  migration 213 section-0 guard: add_retention_policy() collides without it (3a), succeeds with it (3b), section-9 add_job() loop still resilient (3c) -- all under a desynced bgw_job_id_seq'
printf '%s\n' 'PASS: analytical reconciliation assertions completed.'
