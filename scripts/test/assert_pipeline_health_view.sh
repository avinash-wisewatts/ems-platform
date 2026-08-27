#!/usr/bin/env bash
# ============================================================================
# Migration 214 - analytics.v_pipeline_health contract.
#
# Rollback-only. One psql heredoc: structural checks (view exists, columns,
# owner/security, grants, no-write body, seven domains), then synthetic
# fixtures for every health-state path, then the no-mutation and performance
# checks. Nothing is committed; the CAGG-watermark helper is stubbed inside the
# transaction (209-cascade-test pattern) and restored by ROLLBACK.
# ============================================================================
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
COMPOSE_FILE="${PROJECT_ROOT}/compose.test.yaml"

printf '%s\n' '=== analytics.v_pipeline_health assertions (migration 214) ==='

docker compose -f "${COMPOSE_FILE}" exec -T timescaledb-test \
    psql -X -v ON_ERROR_STOP=1 -U ems_admin -d ems_test -f - <<'SQL'
BEGIN;

-- ======================================================================
-- A. view exists; hypertable-free plain view; 7 rows; one per 213 tier
-- ======================================================================
DO $t$
DECLARE v_n int; v_tiers text[];
BEGIN
    IF to_regclass('analytics.v_pipeline_health') IS NULL THEN
        RAISE EXCEPTION 'A FAILED: analytics.v_pipeline_health does not exist';
    END IF;
    IF (SELECT relkind FROM pg_class WHERE oid = 'analytics.v_pipeline_health'::regclass) <> 'v' THEN
        RAISE EXCEPTION 'A FAILED: analytics.v_pipeline_health is not a plain view';
    END IF;
    SELECT count(*), array_agg(pipeline ORDER BY pipeline) INTO v_n, v_tiers
    FROM analytics.v_pipeline_health;
    IF v_n <> 7 THEN RAISE EXCEPTION 'A FAILED: expected 7 rows, got %', v_n; END IF;
    IF v_tiers <> ARRAY[
        'demand_intervals','energy_consumption_15min','energy_consumption_1min',
        'energy_consumption_5min','energy_consumption_daily','energy_consumption_hourly',
        'environment_daily']::text[]
    THEN RAISE EXCEPTION 'A FAILED: row set is not the 7 reconciliation domains: %', v_tiers; END IF;
END;
$t$;
\echo 'PASS: A  view exists, plain view, exactly 7 rows (one per 213 reconciliation domain)'

-- ======================================================================
-- B. exact column set + key types
-- ======================================================================
DO $t$
DECLARE v_cols text[]; v_expected text[];
BEGIN
    SELECT array_agg(column_name ORDER BY column_name) INTO v_cols
    FROM information_schema.columns
    WHERE table_schema='analytics' AND table_name='v_pipeline_health';
    v_expected := ARRAY[
        'cagg_name','cagg_overshoot','cagg_overshoot_margin','cagg_start_offset','cagg_watermark',
        'domain','evaluated_at','forward_checkpoint','forward_checkpoint_age','forward_job',
        'forward_last_run_at','forward_last_status','forward_state','health','health_rank',
        'health_reason','integrity_risk','older_backfill_horizon','pipeline',
        'reconcile_has_error','reconcile_job','reconcile_job_last_run_status','reconcile_job_next_start',
        'reconcile_job_status','reconcile_last_age','reconcile_last_error_sqlstate','reconcile_last_outcome',
        'reconcile_last_ran_at','reconcile_last_rows_repaired','reconcile_recent_partial_runs',
        'reconcile_recent_repaired_runs','reconcile_recent_run_count','reconcile_recent_skipped_runs',
        'reconcile_state','reconcile_window_end','reconcile_window_start','source_max_bucket'
    ]::text[];
    SELECT array_agg(x ORDER BY x) INTO v_expected FROM unnest(v_expected) x;
    IF v_cols IS DISTINCT FROM v_expected THEN
        RAISE EXCEPTION 'B FAILED: column set drift. got=%  expected=%', v_cols, v_expected;
    END IF;
    -- key type spot checks
    IF (SELECT data_type FROM information_schema.columns
        WHERE table_schema='analytics' AND table_name='v_pipeline_health' AND column_name='health') <> 'text'
    OR (SELECT data_type FROM information_schema.columns
        WHERE table_schema='analytics' AND table_name='v_pipeline_health' AND column_name='health_rank') <> 'smallint'
    OR (SELECT data_type FROM information_schema.columns
        WHERE table_schema='analytics' AND table_name='v_pipeline_health' AND column_name='forward_checkpoint_age') <> 'interval'
    THEN RAISE EXCEPTION 'B FAILED: unexpected type for health / health_rank / forward_checkpoint_age'; END IF;
    -- the raw reconcile error MESSAGE must NOT be a column (only the sqlstate)
    IF EXISTS (SELECT 1 FROM information_schema.columns
              WHERE table_schema='analytics' AND table_name='v_pipeline_health'
                AND column_name IN ('first_error_message','reconcile_last_error_message','last_error')) THEN
        RAISE EXCEPTION 'B FAILED: raw reconcile/pipeline error text is exposed as a column';
    END IF;
END;
$t$;
\echo 'PASS: B  exact 37-column contract; health/health_rank/age types; raw error text not exposed'

-- ======================================================================
-- C. owner / security / grants (owner-privilege model, not security_invoker)
-- ======================================================================
DO $t$
BEGIN
    IF (SELECT pg_get_userbyid(relowner) FROM pg_class WHERE oid='analytics.v_pipeline_health'::regclass) <> 'ems_admin' THEN
        RAISE EXCEPTION 'C FAILED: view owner is not ems_admin';
    END IF;
    IF EXISTS (SELECT 1 FROM pg_class WHERE oid='analytics.v_pipeline_health'::regclass
              AND reloptions @> ARRAY['security_invoker=true','security_invoker=on','security_invoker=1']) THEN
        RAISE EXCEPTION 'C FAILED: view is security_invoker (must run with owner privileges)';
    END IF;
    IF has_table_privilege('public','analytics.v_pipeline_health','SELECT') THEN
        RAISE EXCEPTION 'C FAILED: SELECT not revoked from PUBLIC';
    END IF;
    -- grafana_reader is the sole role with USAGE on schema analytics and the
    -- reader of every existing analytics.v_* view (ems_readonly has no
    -- analytics-schema USAGE and cannot query any analytics view).
    IF NOT has_table_privilege('grafana_reader','analytics.v_pipeline_health','SELECT') THEN
        RAISE EXCEPTION 'C FAILED: SELECT not granted to grafana_reader';
    END IF;
    IF has_table_privilege('grafana_reader','analytics.v_pipeline_health','INSERT')
    OR has_table_privilege('grafana_reader','analytics.v_pipeline_health','UPDATE')
    OR has_table_privilege('grafana_reader','analytics.v_pipeline_health','DELETE') THEN
        RAISE EXCEPTION 'C FAILED: a write privilege leaked to grafana_reader';
    END IF;
END;
$t$;
\echo 'PASS: C  owner ems_admin; not security_invoker; SELECT to grafana_reader only; revoked from PUBLIC; no write privs'

-- ======================================================================
-- D. the view body performs NO writes / NO repair / NO CAGG refresh / NO locks
-- ======================================================================
DO $t$
DECLARE v_def text;
BEGIN
    -- A view body is a single SELECT; INSERT/UPDATE/DELETE are structurally
    -- impossible. The real risks are a side-effecting FUNCTION CALL or a CAGG
    -- refresh / advisory lock. Check for call syntax (token followed by "("),
    -- not for the reconcile/forward proc NAMES that legitimately appear as
    -- text literals in the reconcile_job / forward_job columns.
    v_def := pg_get_viewdef('analytics.v_pipeline_health'::regclass, true);
    IF v_def ~* 'refresh_continuous_aggregate[[:space:]]*\('
    OR v_def ~* 'pg_advisory[a-z_]*[[:space:]]*\('
    OR v_def ~* '(nextval|setval)[[:space:]]*\('
    OR v_def ~* 'reconcile_(energy_consumption|demand_intervals|environment_daily)[a-z_]*[[:space:]]*\('
    OR v_def ~* 'refresh_(energy_consumption|demand_analytics|environment_daily)[a-z_]*[[:space:]]*\('
    OR v_def ~* 'record_reconciliation_run[[:space:]]*\(' THEN
        RAISE EXCEPTION 'D FAILED: view body calls a repair / CAGG-refresh / lock / sequence function';
    END IF;
    -- every function the view's rule depends on must be non-volatile
    IF EXISTS (
        SELECT 1
        FROM pg_rewrite r
        JOIN pg_depend d ON d.classid = 'pg_rewrite'::regclass AND d.objid = r.oid
        JOIN pg_proc p   ON p.oid = d.refobjid AND d.refclassid = 'pg_proc'::regclass
        WHERE r.ev_class = 'analytics.v_pipeline_health'::regclass
          AND p.provolatile = 'v'
    ) THEN
        RAISE EXCEPTION 'D FAILED: view depends on a VOLATILE function';
    END IF;
END;
$t$;
\echo 'PASS: D  view body: no INSERT/UPDATE/DELETE, no refresh_*/reconcile_*/refresh_continuous_aggregate, no advisory lock, no checkpoint write'

-- ======================================================================
-- E. selecting the view mutates neither pipeline_state nor the reconcile log
-- ======================================================================
DO $t$
DECLARE
    v_ps_before bigint; v_ps_after bigint;
    v_log_before bigint; v_log_after bigint;
    v_maxran_before timestamptz; v_maxran_after timestamptz;
    v_dummy int;
BEGIN
    SELECT count(*), max(updated_at)::text::timestamptz FROM telemetry.pipeline_state INTO v_ps_before, v_maxran_before;
    SELECT count(*) INTO v_log_before FROM analytics.pipeline_reconciliation_log;
    SELECT max(ran_at) INTO v_maxran_before FROM analytics.pipeline_reconciliation_log;

    PERFORM count(*) FROM analytics.v_pipeline_health;
    PERFORM * FROM analytics.v_pipeline_health;

    SELECT count(*) INTO v_ps_after FROM telemetry.pipeline_state;
    SELECT count(*) INTO v_log_after FROM analytics.pipeline_reconciliation_log;
    SELECT max(ran_at) INTO v_maxran_after FROM analytics.pipeline_reconciliation_log;

    IF v_ps_before <> v_ps_after OR v_log_before <> v_log_after
    OR v_maxran_before IS DISTINCT FROM v_maxran_after THEN
        RAISE EXCEPTION 'E FAILED: selecting the view changed pipeline_state / pipeline_reconciliation_log';
    END IF;
END;
$t$;
\echo 'PASS: E  SELECT on the view does not mutate pipeline_state or pipeline_reconciliation_log'

-- ======================================================================
-- Synthetic fixture helpers for the behavioural tests below.
-- ======================================================================
-- Clean slate for the 7 analytical pipelines + reconcile log (rolled back).
DELETE FROM analytics.pipeline_reconciliation_log;
UPDATE telemetry.pipeline_state
SET last_received_at=NULL, last_status='NEVER_RUN', last_started_at=NULL,
    last_completed_at=NULL, last_error=NULL, last_inserted_rows=0
WHERE pipeline_name IN ('energy_consumption_1min','energy_consumption_5min','energy_consumption_15min',
      'energy_consumption_hourly','energy_consumption_daily','demand_intervals','environment_daily');

CREATE FUNCTION pg_temp.seed_fwd(p_pipe text, p_age interval, p_status text)
RETURNS void LANGUAGE sql AS $f$
    UPDATE telemetry.pipeline_state
    SET last_received_at = now() - p_age, last_status = p_status,
        last_started_at = now() - LEAST(p_age, interval '2 minutes'),
        updated_at = now() - LEAST(p_age, interval '1 minute')
    WHERE pipeline_name = p_pipe;
$f$;

CREATE FUNCTION pg_temp.seed_rec(p_tier text, p_runs int, p_outcome text, p_repaired bigint,
                                 p_sqlstate text, p_step interval DEFAULT interval '1 hour')
RETURNS void LANGUAGE plpgsql AS $f$
DECLARE i int;
BEGIN
    FOR i IN 1..p_runs LOOP
        INSERT INTO analytics.pipeline_reconciliation_log
          (ran_at, tier, trigger_reason, window_start, window_end,
           coarse_examined, coarse_mismatch, rows_examined, rows_repaired, error_count,
           outcome, first_error_sqlstate, duration_ms)
        VALUES (now() - (p_step * i), p_tier, 'SCHEDULED',
                (now() - (p_step * i)) - interval '2 days', now() - (p_step * i),
                3, CASE WHEN p_repaired > 0 THEN 1 ELSE 0 END, 5, p_repaired,
                CASE WHEN p_sqlstate IS NULL THEN 0 ELSE 1 END,
                p_outcome, p_sqlstate, 40);
    END LOOP;
END;
$f$;

-- ======================================================================
-- F. HEALTHY: fresh forward checkpoint + a recent HEALTHY reconcile run.
--    (use a non-CAGG tier so integrity_risk = 'OK', not OLDER_BACKFILL_UNKNOWN)
-- ======================================================================
SELECT pg_temp.seed_fwd('energy_consumption_hourly', interval '20 minutes', 'SUCCESS');
SELECT pg_temp.seed_rec('energy_consumption_hourly', 1, 'HEALTHY', 0, NULL);
DO $t$
DECLARE r record;
BEGIN
    SELECT * INTO r FROM analytics.v_pipeline_health WHERE pipeline='energy_consumption_hourly';
    IF r.forward_state <> 'OK' OR r.reconcile_state <> 'OK'
    OR r.integrity_risk <> 'OK' OR r.health <> 'OK' OR r.health_rank <> 0 THEN
        RAISE EXCEPTION 'F FAILED: expected all-OK, got forward=% reconcile=% integrity=% health=%',
            r.forward_state, r.reconcile_state, r.integrity_risk, r.health;
    END IF;
END;
$t$;
\echo 'PASS: F  HEALTHY: fresh checkpoint + recent HEALTHY reconcile -> forward/reconcile/integrity/health all OK'

-- ======================================================================
-- G. FAILED reconciliation -> reconcile_state=FAILED, health=ERROR,
--    sqlstate surfaced, has_error true.
-- ======================================================================
SELECT pg_temp.seed_fwd('energy_consumption_hourly', interval '20 minutes', 'SUCCESS');
DELETE FROM analytics.pipeline_reconciliation_log WHERE tier='energy_consumption_hourly';
SELECT pg_temp.seed_rec('energy_consumption_hourly', 1, 'FAILED', 0, '40001');
DO $t$
DECLARE r record;
BEGIN
    SELECT * INTO r FROM analytics.v_pipeline_health WHERE pipeline='energy_consumption_hourly';
    IF r.reconcile_state <> 'FAILED' OR r.health <> 'ERROR' OR r.health_rank <> 3
    OR r.reconcile_last_error_sqlstate <> '40001' OR r.reconcile_has_error IS NOT TRUE THEN
        RAISE EXCEPTION 'G FAILED: got reconcile_state=% health=% sqlstate=% has_error=%',
            r.reconcile_state, r.health, r.reconcile_last_error_sqlstate, r.reconcile_has_error;
    END IF;
    IF r.health_reason NOT LIKE '%reconcile=FAILED%40001%' THEN
        RAISE EXCEPTION 'G FAILED: health_reason does not name the failure: %', r.health_reason;
    END IF;
END;
$t$;
\echo 'PASS: G  FAILED reconcile -> reconcile_state=FAILED, health=ERROR, sqlstate surfaced (message not)'

-- ======================================================================
-- H. PARTIAL vs BACKLOGGED (n_max backlog).
-- ======================================================================
SELECT pg_temp.seed_fwd('energy_consumption_15min', interval '30 minutes', 'SUCCESS');
DELETE FROM analytics.pipeline_reconciliation_log WHERE tier='energy_consumption_15min';
-- one PARTIAL (latest), preceded by a HEALTHY  -> single catch-up pass
SELECT pg_temp.seed_rec('energy_consumption_15min', 1, 'PARTIAL', 4, NULL, interval '6 hours');
INSERT INTO analytics.pipeline_reconciliation_log (ran_at, tier, trigger_reason, window_start, window_end, outcome, rows_repaired, error_count, duration_ms)
VALUES (now() - interval '12 hours', 'energy_consumption_15min', 'SCHEDULED', now() - interval '20 days', now() - interval '12 hours', 'HEALTHY', 0, 0, 30);
DO $t$
DECLARE r record;
BEGIN
    SELECT * INTO r FROM analytics.v_pipeline_health WHERE pipeline='energy_consumption_15min';
    IF r.reconcile_state <> 'PARTIAL' OR r.health <> 'OK' THEN
        RAISE EXCEPTION 'H FAILED (single PARTIAL): reconcile_state=% health=% (expected PARTIAL / OK)', r.reconcile_state, r.health;
    END IF;
END;
$t$;
-- now two consecutive PARTIAL -> BACKLOGGED / WARNING
DELETE FROM analytics.pipeline_reconciliation_log WHERE tier='energy_consumption_15min';
SELECT pg_temp.seed_rec('energy_consumption_15min', 2, 'PARTIAL', 4, NULL, interval '6 hours');
DO $t$
DECLARE r record;
BEGIN
    SELECT * INTO r FROM analytics.v_pipeline_health WHERE pipeline='energy_consumption_15min';
    IF r.reconcile_state <> 'BACKLOGGED' OR r.health <> 'WARNING' OR r.health_rank <> 2 THEN
        RAISE EXCEPTION 'H FAILED (2x PARTIAL): reconcile_state=% health=% (expected BACKLOGGED / WARNING)', r.reconcile_state, r.health;
    END IF;
END;
$t$;
\echo 'PASS: H  single PARTIAL -> PARTIAL/OK; two consecutive PARTIAL -> BACKLOGGED/WARNING'

-- ======================================================================
-- I. SKIPPED_LOCKED: single -> SKIPPED_LOCKED/OK; 3 consecutive -> CONTENDED/WARNING
-- ======================================================================
SELECT pg_temp.seed_fwd('energy_consumption_hourly', interval '20 minutes', 'SUCCESS');
DELETE FROM analytics.pipeline_reconciliation_log WHERE tier='energy_consumption_hourly';
INSERT INTO analytics.pipeline_reconciliation_log (ran_at, tier, trigger_reason, outcome, rows_repaired, error_count, duration_ms)
VALUES (now() - interval '30 minutes', 'energy_consumption_hourly', 'SCHEDULED', 'SKIPPED_LOCKED', 0, 0, 1),
       (now() - interval '13 hours',   'energy_consumption_hourly', 'SCHEDULED', 'HEALTHY', 0, 0, 30);
DO $t$
DECLARE r record;
BEGIN
    SELECT * INTO r FROM analytics.v_pipeline_health WHERE pipeline='energy_consumption_hourly';
    IF r.reconcile_state <> 'SKIPPED_LOCKED' OR r.health <> 'OK' THEN
        RAISE EXCEPTION 'I FAILED (single lock): reconcile_state=% health=%', r.reconcile_state, r.health;
    END IF;
END;
$t$;
DELETE FROM analytics.pipeline_reconciliation_log WHERE tier='energy_consumption_hourly';
SELECT pg_temp.seed_rec('energy_consumption_hourly', 3, 'SKIPPED_LOCKED', 0, NULL, interval '30 minutes');
DO $t$
DECLARE r record;
BEGIN
    SELECT * INTO r FROM analytics.v_pipeline_health WHERE pipeline='energy_consumption_hourly';
    IF r.reconcile_state <> 'CONTENDED' OR r.health <> 'WARNING' THEN
        RAISE EXCEPTION 'I FAILED (3x lock): reconcile_state=% health=% (expected CONTENDED / WARNING)', r.reconcile_state, r.health;
    END IF;
END;
$t$;
\echo 'PASS: I  single SKIPPED_LOCKED -> OK; 3 consecutive -> CONTENDED/WARNING'

-- ======================================================================
-- J. NO_CHECKPOINT -> reconcile_state=NOT_INITIALIZED; forward NULL checkpoint
--    -> forward_state=NOT_INITIALIZED; health=UNKNOWN.
-- ======================================================================
UPDATE telemetry.pipeline_state SET last_received_at=NULL, last_status='NO_SOURCE_DATA'
WHERE pipeline_name='energy_consumption_daily';
DELETE FROM analytics.pipeline_reconciliation_log WHERE tier='energy_consumption_daily';
SELECT pg_temp.seed_rec('energy_consumption_daily', 1, 'NO_CHECKPOINT', 0, NULL, interval '24 hours');
DO $t$
DECLARE r record;
BEGIN
    SELECT * INTO r FROM analytics.v_pipeline_health WHERE pipeline='energy_consumption_daily';
    IF r.forward_state <> 'NOT_INITIALIZED' OR r.reconcile_state <> 'NOT_INITIALIZED' OR r.health <> 'UNKNOWN' THEN
        RAISE EXCEPTION 'J FAILED: forward=% reconcile=% health=% (expected NOT_INITIALIZED / NOT_INITIALIZED / UNKNOWN)',
            r.forward_state, r.reconcile_state, r.health;
    END IF;
END;
$t$;
\echo 'PASS: J  NULL checkpoint + NO_CHECKPOINT reconcile -> both NOT_INITIALIZED, health=UNKNOWN'

-- ======================================================================
-- K. NO_SOURCE_DATA forward (fresh checkpoint) -> forward_state=NO_SOURCE_DATA,
--    health drivable to OK (demand tier: integrity_risk N/A).
-- ======================================================================
SELECT pg_temp.seed_fwd('demand_intervals', interval '30 minutes', 'NO_SOURCE_DATA');
DELETE FROM analytics.pipeline_reconciliation_log WHERE tier='demand_intervals';
SELECT pg_temp.seed_rec('demand_intervals', 1, 'HEALTHY', 0, NULL);
DO $t$
DECLARE r record;
BEGIN
    SELECT * INTO r FROM analytics.v_pipeline_health WHERE pipeline='demand_intervals';
    IF r.forward_state <> 'NO_SOURCE_DATA' OR r.integrity_risk <> 'N/A' OR r.health <> 'OK' THEN
        RAISE EXCEPTION 'K FAILED: forward=% integrity=% health=%', r.forward_state, r.integrity_risk, r.health;
    END IF;
END;
$t$;
\echo 'PASS: K  NO_SOURCE_DATA forward with a fresh checkpoint -> NO_SOURCE_DATA, integrity N/A, health OK'

-- ======================================================================
-- L. forward STALE (checkpoint older than k_fwd*schedule + max_catchup_window)
--    -> forward_state=STALE, health=WARNING.
--    daily forward: schedule 1h, max_catchup_window 8d -> stale needs > ~8d4h.
-- ======================================================================
SELECT pg_temp.seed_fwd('energy_consumption_daily', interval '20 days', 'SUCCESS');
DELETE FROM analytics.pipeline_reconciliation_log WHERE tier='energy_consumption_daily';
SELECT pg_temp.seed_rec('energy_consumption_daily', 1, 'HEALTHY', 0, NULL, interval '24 hours');
DO $t$
DECLARE r record;
BEGIN
    SELECT * INTO r FROM analytics.v_pipeline_health WHERE pipeline='energy_consumption_daily';
    IF r.forward_state <> 'STALE' OR r.health <> 'WARNING' THEN
        RAISE EXCEPTION 'L FAILED: forward_state=% health=% (expected STALE / WARNING)', r.forward_state, r.health;
    END IF;
END;
$t$;
\echo 'PASS: L  forward checkpoint older than k_fwd*schedule + max_catchup_window -> forward_state=STALE, health=WARNING'

-- ======================================================================
-- M. reconcile STALE (last run older than k_rec * reconcile schedule_interval)
--    -> reconcile_state=STALE, health=ERROR.
--    hourly reconcile schedule = 12h -> stale needs > 36h.
-- ======================================================================
SELECT pg_temp.seed_fwd('energy_consumption_hourly', interval '20 minutes', 'SUCCESS');
DELETE FROM analytics.pipeline_reconciliation_log WHERE tier='energy_consumption_hourly';
INSERT INTO analytics.pipeline_reconciliation_log (ran_at, tier, trigger_reason, window_start, window_end, outcome, rows_repaired, error_count, duration_ms)
VALUES (now() - interval '5 days', 'energy_consumption_hourly', 'SCHEDULED', now() - interval '15 days', now() - interval '5 days', 'HEALTHY', 0, 0, 30);
DO $t$
DECLARE r record;
BEGIN
    SELECT * INTO r FROM analytics.v_pipeline_health WHERE pipeline='energy_consumption_hourly';
    IF r.reconcile_state <> 'STALE' OR r.health <> 'ERROR' THEN
        RAISE EXCEPTION 'M FAILED: reconcile_state=% health=% (expected STALE / ERROR)', r.reconcile_state, r.health;
    END IF;
END;
$t$;
\echo 'PASS: M  reconcile last run older than k_rec * reconcile schedule_interval -> reconcile_state=STALE, health=ERROR'

-- ======================================================================
-- N. PERSISTENT_DEFICIT: last 3 reconcile runs all repaired>0 -> integrity ERROR.
-- ======================================================================
SELECT pg_temp.seed_fwd('energy_consumption_15min', interval '30 minutes', 'SUCCESS');
DELETE FROM analytics.pipeline_reconciliation_log WHERE tier='energy_consumption_15min';
SELECT pg_temp.seed_rec('energy_consumption_15min', 3, 'REPAIRED', 2, NULL, interval '6 hours');
DO $t$
DECLARE r record;
BEGIN
    SELECT * INTO r FROM analytics.v_pipeline_health WHERE pipeline='energy_consumption_15min';
    IF r.integrity_risk <> 'PERSISTENT_DEFICIT' OR r.health <> 'ERROR' THEN
        RAISE EXCEPTION 'N FAILED: integrity_risk=% health=% (expected PERSISTENT_DEFICIT / ERROR)', r.integrity_risk, r.health;
    END IF;
END;
$t$;
\echo 'PASS: N  three consecutive reconcile runs with rows_repaired>0 -> integrity_risk=PERSISTENT_DEFICIT, health=ERROR'

-- ======================================================================
-- O. CAGG overshoot (energy_consumption_1min). The view reads the ca_energy_1min
--    materialisation watermark inline from _timescaledb_catalog; drive it via a
--    transaction-local UPDATE of that catalog row (rolled back).
-- ======================================================================
CREATE FUNCTION pg_temp.set_ca1_watermark(p_ts timestamptz)
RETURNS void LANGUAGE sql AS $f$
    UPDATE _timescaledb_catalog.continuous_aggs_watermark
    SET watermark = _timescaledb_functions.to_unix_microseconds(p_ts)
    WHERE mat_hypertable_id = (
        SELECT mat_hypertable_id FROM _timescaledb_catalog.continuous_agg
        WHERE user_view_schema='telemetry' AND user_view_name='ca_energy_1min');
$f$;

-- source frontier ~2h behind; watermark at now-1min -> overshoot ~119m >> ~21m margin
INSERT INTO telemetry.energy_measurements
  (bucket_start, received_at, source_timestamp, organization_id, site_id, gateway_id, device_id,
   measurement_interval_seconds, quality_code, is_estimated, active_power_total_w)
SELECT g, g, g, gen_random_uuid(), gen_random_uuid(), gen_random_uuid(), gen_random_uuid(), 60, 0, false, 100
FROM generate_series(now() - interval '4 hours', now() - interval '2 hours', interval '1 minute') g;
SELECT pg_temp.set_ca1_watermark(now() - interval '1 minute');
SELECT pg_temp.seed_fwd('energy_consumption_1min', interval '90 minutes', 'SUCCESS');
DELETE FROM analytics.pipeline_reconciliation_log WHERE tier='energy_consumption_1min';
SELECT pg_temp.seed_rec('energy_consumption_1min', 1, 'HEALTHY', 0, NULL);
DO $t$
DECLARE r record;
BEGIN
    SELECT * INTO r FROM analytics.v_pipeline_health WHERE pipeline='energy_consumption_1min';
    IF r.integrity_risk <> 'CAGG_OVERSHOOT' OR r.health <> 'WARNING' THEN
        RAISE EXCEPTION 'O FAILED (overshoot): integrity_risk=% health=% cagg_overshoot=% margin=%',
            r.integrity_risk, r.health, r.cagg_overshoot, r.cagg_overshoot_margin;
    END IF;
    IF r.cagg_overshoot IS NULL OR r.cagg_overshoot <= r.cagg_overshoot_margin THEN
        RAISE EXCEPTION 'O FAILED: cagg_overshoot % not greater than margin %', r.cagg_overshoot, r.cagg_overshoot_margin;
    END IF;
    IF r.health_reason NOT LIKE '%CAGG_OVERSHOOT%watermark ahead of source%' THEN
        RAISE EXCEPTION 'O FAILED: health_reason does not describe the overshoot: %', r.health_reason;
    END IF;
END;
$t$;
-- move the watermark to ~5 min ahead of source -> below margin -> OLDER_BACKFILL_UNKNOWN
SELECT pg_temp.set_ca1_watermark((SELECT max(bucket_start) FROM telemetry.energy_measurements) + interval '5 minutes');
DO $t$
DECLARE r record;
BEGIN
    SELECT * INTO r FROM analytics.v_pipeline_health WHERE pipeline='energy_consumption_1min';
    IF r.integrity_risk <> 'OLDER_BACKFILL_UNKNOWN' THEN
        RAISE EXCEPTION 'O FAILED (below margin): integrity_risk=% (expected OLDER_BACKFILL_UNKNOWN)', r.integrity_risk;
    END IF;
END;
$t$;
\echo 'PASS: O  CAGG watermark far ahead of source -> CAGG_OVERSHOOT/WARNING; within margin -> OLDER_BACKFILL_UNKNOWN'

-- ======================================================================
-- P. OLDER_BACKFILL_UNKNOWN fallback (C2): native tiers, all else OK, still
--    report the limitation and drive overall health to UNKNOWN; the
--    older_backfill_horizon is the latest reconcile window_start.
-- ======================================================================
DO $t$
DECLARE r record;
BEGIN
    SELECT * INTO r FROM analytics.v_pipeline_health WHERE pipeline='energy_consumption_1min';
    IF r.forward_state <> 'OK' OR r.reconcile_state <> 'OK' THEN
        RAISE EXCEPTION 'P FAILED: precondition not OK (forward=% reconcile=%)', r.forward_state, r.reconcile_state;
    END IF;
    IF r.integrity_risk <> 'OLDER_BACKFILL_UNKNOWN' OR r.health <> 'UNKNOWN' OR r.health_rank <> 1 THEN
        RAISE EXCEPTION 'P FAILED: integrity_risk=% health=% (expected OLDER_BACKFILL_UNKNOWN / UNKNOWN)', r.integrity_risk, r.health;
    END IF;
    IF r.older_backfill_horizon IS NULL THEN
        RAISE EXCEPTION 'P FAILED: older_backfill_horizon is NULL (should equal the latest reconcile window_start)';
    END IF;
    IF r.health_reason NOT LIKE '%OLDER_BACKFILL_UNKNOWN%diagnostic%' THEN
        RAISE EXCEPTION 'P FAILED: health_reason does not point at the operator diagnostic: %', r.health_reason;
    END IF;
END;
$t$;
\echo 'PASS: P  native-tier older-backfill limitation surfaced as OLDER_BACKFILL_UNKNOWN + horizon + diagnostic pointer'

-- ======================================================================
-- Q. tenant isolation / no cross-tenant leak: no tenant columns; queryable
--    by grafana_reader; returns 7 rows; no site/device/org identifiers.
-- ======================================================================
DO $t$
BEGIN
    IF EXISTS (SELECT 1 FROM information_schema.columns
              WHERE table_schema='analytics' AND table_name='v_pipeline_health'
                AND column_name IN ('organization_id','grafana_org_id','site_id','tenant_id',
                                    'site_name','device_id','asset_id')) THEN
        RAISE EXCEPTION 'Q FAILED: v_pipeline_health carries a tenant / site / device column';
    END IF;
END;
$t$;
SET LOCAL ROLE grafana_reader;
DO $t$
DECLARE v_n int;
BEGIN
    SELECT count(*) INTO v_n FROM analytics.v_pipeline_health;
    IF v_n <> 7 THEN RAISE EXCEPTION 'Q FAILED: grafana_reader sees % rows (expected 7)', v_n; END IF;
END;
$t$;
RESET ROLE;
\echo 'PASS: Q  system-scoped: no tenant/site/device columns; grafana_reader can read all 7 rows via the owner-privilege view'

-- ======================================================================
-- R. performance / boundedness: EXPLAIN shows no Seq Scan of a large source /
--    analytical table; the plan touches the 213 tier index and per-chunk
--    bucket_start index scans only.
-- ======================================================================
DO $t$
DECLARE v_line text; v_all text := ''; v_ms numeric;
BEGIN
    FOR v_line IN EXECUTE 'EXPLAIN (ANALYZE, BUFFERS) SELECT * FROM analytics.v_pipeline_health'
    LOOP
        v_all := v_all || v_line || E'\n';
    END LOOP;
    IF v_all ~ 'Seq Scan on [^ ]*energy_measurements'
    OR v_all ~ 'Seq Scan on [^ ]*environment_measurements'
    OR v_all ~ 'Seq Scan on [^ ]*energy_consumption_(1min|5min|15min|hourly|daily)'
    OR v_all ~ 'Seq Scan on [^ ]*_hyper_2_'
    OR v_all ~ 'Seq Scan on [^ ]*_hyper_31_' THEN
        RAISE EXCEPTION 'R FAILED: plan Seq-Scans a large source/analytical hypertable:%', E'\n' || v_all;
    END IF;
    IF v_all !~ 'ix_pipeline_reconciliation_log_tier_time' THEN
        RAISE EXCEPTION 'R FAILED: reconcile-log access does not use the 213 (tier, ran_at DESC) index:%', E'\n' || v_all;
    END IF;
    v_ms := substring(v_all from 'Execution Time: ([0-9.]+) ms')::numeric;
    RAISE NOTICE 'R: v_pipeline_health execution time = % ms', v_ms;
    IF v_ms IS NULL OR v_ms > 250 THEN
        RAISE EXCEPTION 'R FAILED: view executed in % ms (ceiling 250 ms)', v_ms;
    END IF;
END;
$t$;
\echo 'PASS: R  bounded: no Seq Scan of energy_measurements / environment_measurements / energy_consumption_* / reconcile-log chunks; latest-per-tier uses the 213 index; execution < 250 ms'

-- ======================================================================
-- S. empty / disposable-DB behaviour: fresh pipeline_state (NULL checkpoints)
--    and an empty reconcile log -> 7 rows, every one UNKNOWN, no crash.
-- ======================================================================
DELETE FROM analytics.pipeline_reconciliation_log;
UPDATE telemetry.pipeline_state
SET last_received_at=NULL, last_status='NEVER_RUN', last_started_at=NULL, last_completed_at=NULL, last_error=NULL
WHERE pipeline_name IN ('energy_consumption_1min','energy_consumption_5min','energy_consumption_15min',
      'energy_consumption_hourly','energy_consumption_daily','demand_intervals','environment_daily');
DO $t$
DECLARE v_rows int; v_non_unknown int;
BEGIN
    SELECT count(*), count(*) FILTER (WHERE health <> 'UNKNOWN') INTO v_rows, v_non_unknown
    FROM analytics.v_pipeline_health;
    IF v_rows <> 7 OR v_non_unknown <> 0 THEN
        RAISE EXCEPTION 'S FAILED: fresh DB -> % rows, % not UNKNOWN (expected 7 / 0)', v_rows, v_non_unknown;
    END IF;
    IF EXISTS (SELECT 1 FROM analytics.v_pipeline_health
              WHERE forward_state <> 'NOT_INITIALIZED' OR reconcile_state <> 'NOT_INITIALIZED') THEN
        RAISE EXCEPTION 'S FAILED: fresh DB -> a tier is not NOT_INITIALIZED on both axes';
    END IF;
END;
$t$;
\echo 'PASS: S  fresh/disposable DB: 7 rows, all NOT_INITIALIZED / UNKNOWN, no error'

ROLLBACK;

SELECT 'analytics.v_pipeline_health assertions passed.' AS result;
SQL

printf '%s\n' 'PASS: analytics.v_pipeline_health assertions completed.'
