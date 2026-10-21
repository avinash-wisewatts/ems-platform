-- ============================================================================
-- Migration 306
-- Demand reconciler (job 1121 on staging): hourly 6-hour reconciliation plus
-- a wide 58-hour pass every 6 hours (staging optimization plan §10.35 F).
--
-- WHY
--   Migration 305 widened analytics.reconcile_demand_intervals to 48 hours so
--   demand intervals whose energy a recovered raw message re-supplies are
--   re-finalized. Every hourly run now costs ~2 minutes of one CPU (staging
--   2026-10-19: 110-132 s per run, avg 121 s, ~61 % host CPU while running vs
--   ~16 % without, CPU-bound; 6-hour runs averaged 15.5 s over 330 runs). In
--   14 days neither window repaired a single row: the wide window exists only
--   for recoveries, which are rare.
--
--   Coverage: telemetry.recover_failed_raw_messages refuses rows older than
--   the raw_messages retention (48 h), so a recovered row is <= 48 h old when
--   job 1077 replays it (hh:48:49); the 305 queue routes it at the next
--   hh:31:30 (<= 43 min, +1 h per lock skip / failure) and the reconciler
--   anchors on the demand checkpoint (15-30 min behind). The hourly 48-hour
--   window therefore already missed the oldest ~1-1.5 h of the recoverable
--   range. A pass every 6 hours must reach 48 h + 43 min + 6 h + 1 h retry
--   slack + 30 min checkpoint lag = ~56.2 h -> wide_window 58 hours.
--
-- THE CHANGE
--   1. analytics.reconcile_demand_intervals (migration 213 body + 3 fragments):
--      optional config keys wide_window / wide_every. When both are set, a run
--      uses wide_window instead of reconcile_window unless a successful
--      (HEALTHY / REPAIRED) demand_intervals run with at least wide_window was
--      logged in analytics.pipeline_reconciliation_log within the last
--      wide_every (30-minute tolerance). A skipped (SKIPPED_LOCKED,
--      NO_CHECKPOINT: no window logged) or FAILED wide run is therefore
--      retried by the next hourly run; the first run after this migration is
--      wide. Without the keys the procedure behaves exactly as before.
--      Invalid configuration raises invalid_parameter_value (22023): only one
--      of the two keys, a non-string / unparsable interval, wide_every under
--      1 hour, wide_window not longer than reconcile_window or wide_every.
--   2. New config.assert_demand_reconciliation_job_config: the job's
--      check_config validator (so alter_job rejects the same configurations);
--      the shared config.assert_reconciliation_job_config is unchanged.
--   3. The job's config: reconcile_window 48 hours -> 6 hours, plus
--      wide_window 58 hours and wide_every 6 hours; check_config -> the new
--      validator; every other key, the schedule (hourly, fixed), max_runtime,
--      retries and the job id unchanged.
--
-- WHY IT IS SAFE
--   - One job, one procedure: the health view (analytics.v_pipeline_health
--     keys jobs by procedure name) and the "registered once" contract stay
--     valid; a run cannot overlap itself; the forward-demand advisory lock
--     (try-lock, SKIPPED_LOCKED) is unchanged.
--   - Re-finalisation semantics unchanged: refresh_demand_analytics over
--     [checkpoint - window, checkpoint) with the migration-210 status guard
--     (VALID rows frozen); only the window is chosen differently.
--   - The decision reads analytics.pipeline_reconciliation_log by tier and
--     ran_at (index ix_pipeline_reconciliation_log_tier_time; staging 3,930
--     rows / 1.6 MB).
--   - Applying the migration changes no data.
--
-- Rollback: postgres/maintenance/306_demand_reconcile_wide_cadence_rollback.sql
--   (re-issues the migration-213 body; config back to reconcile_window
--   48 hours without the wide keys, check_config back to the shared
--   validator; drops the demand validator).
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. Preconditions: the migration-213 body; exactly one demand reconciler job,
--    at the migration-305 window and without wide keys.
-- ----------------------------------------------------------------------------
DO $pre$
BEGIN
    IF (SELECT md5(replace(prosrc, E'\r', '')) FROM pg_proc
        WHERE oid = 'analytics.reconcile_demand_intervals(integer,jsonb)'::regprocedure)
       IS DISTINCT FROM 'c2492b9d357c59aa0fa0cc97dd70f70e' THEN
        RAISE EXCEPTION 'Migration 306 precondition failed: reconcile_demand_intervals differs from the migration-213 body.';
    END IF;
    IF (SELECT count(*) FROM timescaledb_information.jobs
        WHERE proc_schema = 'analytics' AND proc_name = 'reconcile_demand_intervals') <> 1 THEN
        RAISE EXCEPTION 'Migration 306 precondition failed: expected exactly one analytics.reconcile_demand_intervals job.';
    END IF;
    IF (SELECT count(*) FROM timescaledb_information.jobs
        WHERE proc_schema = 'analytics' AND proc_name = 'reconcile_demand_intervals'
          AND config ->> 'reconcile_window' = '48 hours'
          AND NOT (config ? 'wide_window') AND NOT (config ? 'wide_every')) <> 1 THEN
        RAISE EXCEPTION 'Migration 306 precondition failed: the demand reconciler is not at the migration-305 config (reconcile_window 48 hours, no wide keys).';
    END IF;
    IF (SELECT count(*) FROM timescaledb_information.jobs
        WHERE proc_schema = 'analytics' AND proc_name = 'reconcile_demand_intervals'
          AND check_schema = 'config' AND check_name = 'assert_reconciliation_job_config') <> 1 THEN
        RAISE EXCEPTION 'Migration 306 precondition failed: the demand reconciler check_config is not config.assert_reconciliation_job_config.';
    END IF;
    IF to_regprocedure('config.assert_demand_reconciliation_job_config(jsonb)') IS NOT NULL THEN
        RAISE EXCEPTION 'Migration 306 precondition failed: config.assert_demand_reconciliation_job_config already exists.';
    END IF;
END
$pre$;

CREATE TEMP TABLE m306_job_before ON COMMIT DROP AS
SELECT job_id, schedule_interval, fixed_schedule, initial_start, max_runtime, max_retries,
       retry_period, scheduled, owner, config
FROM timescaledb_information.jobs
WHERE proc_schema = 'analytics' AND proc_name = 'reconcile_demand_intervals';


-- ----------------------------------------------------------------------------
-- 2. config.assert_demand_reconciliation_job_config: the demand reconciler's
--    own check_config validator. The shared config.assert_reconciliation_job_config
--    (all ten reconcilers) is NOT widened -- the other reconcilers would accept
--    wide keys they ignore. This one strips wide_window / wide_every, delegates
--    every other key to the shared validator unchanged, and enforces the wide
--    rules (22023). The procedure calls it too whenever a wide key is present,
--    so alter_job and direct CALLs share one rule set.
-- ----------------------------------------------------------------------------
CREATE FUNCTION config.assert_demand_reconciliation_job_config(config jsonb)
RETURNS void
LANGUAGE plpgsql
AS $function$
DECLARE
    -- the procedure's default reconcile_window when the key is absent
    v_rw         INTERVAL := INTERVAL '6 hours';
    v_wide       INTERVAL;
    v_wide_every INTERVAL;
BEGIN
    IF config IS NULL THEN
        RETURN;
    END IF;
    IF jsonb_typeof(config) <> 'object' THEN
        PERFORM config.assert_reconciliation_job_config(config);   -- raises
        RETURN;
    END IF;

    PERFORM config.assert_reconciliation_job_config(config - 'wide_window' - 'wide_every');

    IF NOT (config ? 'wide_window' OR config ? 'wide_every') THEN
        RETURN;
    END IF;
    IF NOT (config ? 'wide_window' AND config ? 'wide_every') THEN
        RAISE EXCEPTION 'demand reconciliation job config: wide_window and wide_every must be configured together (config %)', config
            USING ERRCODE = 'invalid_parameter_value';
    END IF;
    IF jsonb_typeof(config -> 'wide_window') IS DISTINCT FROM 'string'
       OR NOT pg_input_is_valid(config ->> 'wide_window', 'interval') THEN
        RAISE EXCEPTION 'demand reconciliation job config: wide_window must be an interval string; got %', config -> 'wide_window'
            USING ERRCODE = 'invalid_parameter_value';
    END IF;
    IF jsonb_typeof(config -> 'wide_every') IS DISTINCT FROM 'string'
       OR NOT pg_input_is_valid(config ->> 'wide_every', 'interval') THEN
        RAISE EXCEPTION 'demand reconciliation job config: wide_every must be an interval string; got %', config -> 'wide_every'
            USING ERRCODE = 'invalid_parameter_value';
    END IF;

    IF config ? 'reconcile_window' THEN
        v_rw := (config ->> 'reconcile_window')::INTERVAL;
    END IF;
    v_wide       := (config ->> 'wide_window')::INTERVAL;
    v_wide_every := (config ->> 'wide_every')::INTERVAL;
    IF v_wide_every < INTERVAL '1 hour' THEN
        RAISE EXCEPTION 'demand reconciliation job config: wide_every (%) must be at least 1 hour', v_wide_every
            USING ERRCODE = 'invalid_parameter_value';
    END IF;
    IF v_wide <= v_rw THEN
        RAISE EXCEPTION 'demand reconciliation job config: wide_window (%) must be longer than reconcile_window (%)', v_wide, v_rw
            USING ERRCODE = 'invalid_parameter_value';
    END IF;
    IF v_wide <= v_wide_every THEN
        RAISE EXCEPTION 'demand reconciliation job config: wide_window (%) must be longer than wide_every (%)', v_wide, v_wide_every
            USING ERRCODE = 'invalid_parameter_value';
    END IF;
END;
$function$;

ALTER FUNCTION config.assert_demand_reconciliation_job_config(jsonb) OWNER TO ems_admin;
REVOKE ALL ON FUNCTION config.assert_demand_reconciliation_job_config(jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION config.assert_demand_reconciliation_job_config(jsonb) TO ems_admin;

COMMENT ON FUNCTION config.assert_demand_reconciliation_job_config(jsonb) IS
'Migration 306: check_config validator of the demand reconciler job (analytics.reconcile_demand_intervals), also called by that procedure whenever a wide key is present. Keys other than wide_window / wide_every are validated by config.assert_reconciliation_job_config unchanged. wide_window and wide_every must come together as interval strings; wide_every >= 1 hour; wide_window > reconcile_window (default 6 hours) and > wide_every. Violations raise invalid_parameter_value (22023).';


-- ----------------------------------------------------------------------------
-- 3. The procedure: migration-213 body + the three migration-306 fragments.
--    Signature, owner, SECURITY DEFINER, search_path and grants unchanged
--    (CREATE OR REPLACE keeps owner and ACL).
-- ----------------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE analytics.reconcile_demand_intervals(IN job_id integer, IN config jsonb)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'analytics', 'config', 'metadata'
AS $procedure$
DECLARE
    v_pipeline  CONSTANT text := 'demand_intervals';
    v_fwd_lock  CONSTANT text := 'analytics.run_demand_calculation_job';
    v_rw        INTERVAL := INTERVAL '6 hours';
    v_lookback  INTERVAL := INTERVAL '3 hours';
    v_run       uuid := gen_random_uuid();
    v_started   timestamptz := clock_timestamp();
    v_cp        timestamptz;
    v_ws        timestamptz;
    v_repaired  bigint  := 0;
    v_errs      integer := 0;
    v_sqlstate  text;
    v_errmsg    text;
    v_outcome   text;
    v_wide       INTERVAL;     -- Migration 306: wide pass (config wide_window / wide_every)
    v_wide_every INTERVAL;
BEGIN
    IF config ? 'reconcile_window' THEN v_rw       := (config ->> 'reconcile_window')::INTERVAL; END IF;
    IF config ? 'lookback'         THEN v_lookback := (config ->> 'lookback')::INTERVAL; END IF;

    -- Migration 306: optional wide pass. wide_window and wide_every come as a
    -- pair; config.assert_demand_reconciliation_job_config (also this job's
    -- alter_job check) rejects anything else with 22023, so an invalid wide
    -- configuration fails the run: never ignored, never a silent fallback to
    -- reconcile_window.
    IF config ? 'wide_window' OR config ? 'wide_every' THEN
        PERFORM config.assert_demand_reconciliation_job_config(config);
        v_wide       := (config ->> 'wide_window')::INTERVAL;
        v_wide_every := (config ->> 'wide_every')::INTERVAL;
    END IF;

    IF NOT pg_try_advisory_xact_lock(hashtextextended(v_fwd_lock, 0)) THEN
        PERFORM analytics.record_reconciliation_run(v_run, v_pipeline, v_started,
            NULL, NULL, NULL, NULL, NULL, 0, 0, 'SKIPPED_LOCKED', NULL, NULL);
        RETURN;
    END IF;

    SELECT last_received_at INTO v_cp
    FROM telemetry.pipeline_state WHERE pipeline_name = v_pipeline;

    IF v_cp IS NULL THEN
        PERFORM analytics.record_reconciliation_run(v_run, v_pipeline, v_started,
            NULL, NULL, NULL, NULL, NULL, 0, 0, 'NO_CHECKPOINT', NULL, NULL);
        RETURN;
    END IF;

    -- Migration 306: this run is the wide pass unless a successful (HEALTHY /
    -- REPAIRED) run with at least the wide window was logged within the last
    -- wide_every (30-minute tolerance for schedule jitter and the 15-minute
    -- retry). A SKIPPED_LOCKED / NO_CHECKPOINT run logs no window and a FAILED
    -- run does not count, so the next hourly run retries the wide window.
    IF v_wide IS NOT NULL AND NOT EXISTS (
        SELECT 1 FROM analytics.pipeline_reconciliation_log l
        WHERE l.tier = v_pipeline
          AND l.ran_at > v_started - v_wide_every + INTERVAL '30 minutes'
          AND l.outcome IN ('HEALTHY', 'REPAIRED')
          AND l.window_end - l.window_start >= v_wide
    ) THEN
        v_rw := v_wide;
    END IF;

    v_ws := v_cp - v_rw;

    -- p_now = clock_timestamp() keeps the live analytics.demand_state block
    -- current; p_finalize_from / p_finalize_to bound ONLY the historical
    -- finalisation loop -> a bounded re-finalisation over [v_ws, v_cp) that does
    -- NOT touch telemetry.pipeline_state('demand_intervals') and applies the
    -- 210 status guard (VALID rows frozen; scope-branched partial-index upsert).
    BEGIN
        CALL analytics.refresh_demand_analytics(clock_timestamp(), v_lookback, v_ws, v_cp);
    EXCEPTION WHEN OTHERS THEN
        v_errs := 1;
        v_sqlstate := SQLSTATE;
        v_errmsg   := left(SQLERRM, 1000);
    END;

    SELECT count(*)::bigint INTO v_repaired
    FROM analytics.demand_intervals
    WHERE interval_start >= v_ws
      AND interval_start <  v_cp
      AND finalized_at   >= v_started;

    v_outcome := CASE WHEN v_errs > 0 THEN 'FAILED'
                      WHEN v_repaired > 0 THEN 'REPAIRED'
                      ELSE 'HEALTHY' END;

    PERFORM analytics.record_reconciliation_run(v_run, v_pipeline, v_started,
        v_ws, v_cp, NULL, NULL, NULL, v_repaired, v_errs, v_outcome, v_sqlstate, v_errmsg);
END;
$procedure$;

COMMENT ON PROCEDURE analytics.reconcile_demand_intervals(integer, jsonb) IS
'Migration 213: bounded trailing reconciliation for analytics.demand_intervals. Demand has no source-count fingerprint; the repair IS the re-run: CALL analytics.refresh_demand_analytics(clock_timestamp(), lookback, p_finalize_from => checkpoint - window, p_finalize_to => checkpoint). Applies the migration-210 status guard (VALID frozen; scope-branched SITE/ASSET partial-index upsert). The live demand_state block stays keyed to p_now. NEVER writes telemetry.pipeline_state.last_received_at. Migration 306: window = reconcile_window, or wide_window when config has wide_window + wide_every and no successful (HEALTHY / REPAIRED) run with at least wide_window was logged within the last wide_every (30-minute tolerance), so a skipped or failed wide pass is retried by the next run; invalid wide configuration raises 22023. demand max_catchup_window is unchanged.';


-- ----------------------------------------------------------------------------
-- 4. The job: 6-hour hourly window plus the 58-hour wide pass every 6 hours,
--    validated by the demand check. Rollback: the config NOTICEd here, check
--    config.assert_reconciliation_job_config.
-- ----------------------------------------------------------------------------
DO $job$
DECLARE
    v_job INTEGER;
    v_cfg JSONB;
    v_new JSONB;
BEGIN
    SELECT job_id, config INTO v_job, v_cfg
    FROM timescaledb_information.jobs
    WHERE proc_schema = 'analytics' AND proc_name = 'reconcile_demand_intervals';
    v_new := v_cfg || jsonb_build_object('reconcile_window', '6 hours', 'wide_window', '58 hours', 'wide_every', '6 hours');
    PERFORM alter_job(v_job, config => v_new,
                      check_config => 'config.assert_demand_reconciliation_job_config'::regproc);
    RAISE NOTICE 'Migration 306: job % config % -> %, check_config config.assert_demand_reconciliation_job_config', v_job, v_cfg, v_new;
END
$job$;


-- ----------------------------------------------------------------------------
-- 5. Postconditions: new body exact; reverting the fragments gives back the
--    migration-213 body byte for byte; owner / SECURITY DEFINER / ACL kept;
--    config and check as intended; every other job attribute unchanged; the
--    shared validator unchanged.
-- ----------------------------------------------------------------------------
DO $post$
DECLARE
    v_body TEXT;
BEGIN
    SELECT replace(prosrc, E'\r', '') INTO v_body FROM pg_proc
    WHERE oid = 'analytics.reconcile_demand_intervals(integer,jsonb)'::regprocedure;
    IF md5(v_body) IS DISTINCT FROM '4b9820743f6ecddcbb89051269faf6e0' THEN
        RAISE EXCEPTION 'Migration 306 postcondition failed: reconcile_demand_intervals is not the migration-306 body.';
    END IF;
    IF md5(replace(replace(replace(v_body, $n1$    v_outcome   text;
    v_wide       INTERVAL;     -- Migration 306: wide pass (config wide_window / wide_every)
    v_wide_every INTERVAL;
BEGIN
$n1$, $o1$    v_outcome   text;
BEGIN
$o1$), $n2$    IF config ? 'lookback'         THEN v_lookback := (config ->> 'lookback')::INTERVAL; END IF;

    -- Migration 306: optional wide pass. wide_window and wide_every come as a
    -- pair; config.assert_demand_reconciliation_job_config (also this job's
    -- alter_job check) rejects anything else with 22023, so an invalid wide
    -- configuration fails the run: never ignored, never a silent fallback to
    -- reconcile_window.
    IF config ? 'wide_window' OR config ? 'wide_every' THEN
        PERFORM config.assert_demand_reconciliation_job_config(config);
        v_wide       := (config ->> 'wide_window')::INTERVAL;
        v_wide_every := (config ->> 'wide_every')::INTERVAL;
    END IF;
$n2$, $o2$    IF config ? 'lookback'         THEN v_lookback := (config ->> 'lookback')::INTERVAL; END IF;
$o2$), $n3$    -- Migration 306: this run is the wide pass unless a successful (HEALTHY /
    -- REPAIRED) run with at least the wide window was logged within the last
    -- wide_every (30-minute tolerance for schedule jitter and the 15-minute
    -- retry). A SKIPPED_LOCKED / NO_CHECKPOINT run logs no window and a FAILED
    -- run does not count, so the next hourly run retries the wide window.
    IF v_wide IS NOT NULL AND NOT EXISTS (
        SELECT 1 FROM analytics.pipeline_reconciliation_log l
        WHERE l.tier = v_pipeline
          AND l.ran_at > v_started - v_wide_every + INTERVAL '30 minutes'
          AND l.outcome IN ('HEALTHY', 'REPAIRED')
          AND l.window_end - l.window_start >= v_wide
    ) THEN
        v_rw := v_wide;
    END IF;

    v_ws := v_cp - v_rw;
$n3$, $o3$    v_ws := v_cp - v_rw;
$o3$)) IS DISTINCT FROM 'c2492b9d357c59aa0fa0cc97dd70f70e' THEN
        RAISE EXCEPTION 'Migration 306 postcondition failed: the body differs from migration 213 outside the migration-306 fragments.';
    END IF;
    IF (SELECT prosecdef FROM pg_proc WHERE oid = 'analytics.reconcile_demand_intervals(integer,jsonb)'::regprocedure) IS NOT TRUE
       OR (SELECT pg_get_userbyid(proowner) FROM pg_proc WHERE oid = 'analytics.reconcile_demand_intervals(integer,jsonb)'::regprocedure) <> 'ems_admin'
       OR has_function_privilege('public', 'analytics.reconcile_demand_intervals(integer,jsonb)', 'EXECUTE') THEN
        RAISE EXCEPTION 'Migration 306 postcondition failed: owner / SECURITY DEFINER / PUBLIC EXECUTE changed.';
    END IF;
    IF (SELECT count(*) FROM timescaledb_information.jobs
        WHERE proc_schema = 'analytics' AND proc_name = 'reconcile_demand_intervals') <> 1
       OR (SELECT count(*) FROM timescaledb_information.jobs AS j JOIN m306_job_before AS b USING (job_id)
           WHERE j.proc_schema = 'analytics' AND j.proc_name = 'reconcile_demand_intervals'
             AND j.config = b.config || '{"reconcile_window": "6 hours", "wide_window": "58 hours", "wide_every": "6 hours"}'::jsonb
             AND (j.schedule_interval, j.fixed_schedule, j.initial_start, j.max_runtime, j.max_retries, j.retry_period, j.scheduled, j.owner)
                 IS NOT DISTINCT FROM
                 (b.schedule_interval, b.fixed_schedule, b.initial_start, b.max_runtime, b.max_retries, b.retry_period, b.scheduled, b.owner)) <> 1 THEN
        RAISE EXCEPTION 'Migration 306 postcondition failed: the demand reconciler job is not exactly the migration-305 job with the 306 config.';
    END IF;
    IF (SELECT count(*) FROM timescaledb_information.jobs
        WHERE proc_schema = 'analytics' AND proc_name = 'reconcile_demand_intervals'
          AND check_schema = 'config' AND check_name = 'assert_demand_reconciliation_job_config') <> 1 THEN
        RAISE EXCEPTION 'Migration 306 postcondition failed: the demand reconciler check_config is not config.assert_demand_reconciliation_job_config.';
    END IF;
    IF (SELECT md5(replace(prosrc, E'\r', '')) FROM pg_proc
        WHERE oid = 'config.assert_reconciliation_job_config(jsonb)'::regprocedure)
       IS DISTINCT FROM '897a9771d434a64fc873cfa23217e878' THEN
        RAISE EXCEPTION 'Migration 306 postcondition failed: the shared config.assert_reconciliation_job_config changed.';
    END IF;
    IF (SELECT pg_get_userbyid(proowner) FROM pg_proc WHERE oid = 'config.assert_demand_reconciliation_job_config(jsonb)'::regprocedure) <> 'ems_admin'
       OR has_function_privilege('public', 'config.assert_demand_reconciliation_job_config(jsonb)', 'EXECUTE') THEN
        RAISE EXCEPTION 'Migration 306 postcondition failed: config.assert_demand_reconciliation_job_config owner / PUBLIC EXECUTE.';
    END IF;

    RAISE NOTICE 'Migration 306: all postconditions passed.';
END
$post$;
