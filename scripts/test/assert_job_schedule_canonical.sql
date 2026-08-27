\set ON_ERROR_STOP on

-- =============================================================================
-- WiseWatts EMS — Phase 1C job-schedule canonical contract
--
-- Proves the three telemetry routing background jobs (run_normalization_job,
-- run_energy_routing_job, run_environment_routing_job) are registered with
-- the canonical TimescaleDB schedule documented independently in
-- docs/operations/CICD_PIPELINE.md and scripts/verify/verify_jobs.sh, and
-- reasserted by postgres/migrations/194_fix_job_schedule_drift.sql:
--
--   schedule_interval = 1 minute
--   max_runtime       = 5 minutes
--   max_retries       = 3
--   retry_period      = 1 minute
--   config.overlap    = 15 minutes
--   scheduled         = TRUE
--
-- This queries the actual runtime job registry (timescaledb_information.jobs)
-- -- the same authoritative source scripts/verify/verify_jobs.sh reads against
-- staging -- rather than re-deriving expected values from the migration or
-- job-registration SQL files themselves, so the assertion cannot silently
-- drift in lockstep with a regression in the corrective migration.
--
-- Read-only verification; no fixtures are created and nothing is rolled
-- back, since this only inspects TimescaleDB's own job catalog as populated
-- by the canonical postgres/jobs/*.sql files and this migration.
-- =============================================================================

DO $$
DECLARE
    v_failures text[] := ARRAY[]::text[];
    v_job RECORD;
    v_expected_proc_names text[] := ARRAY[
        'run_normalization_job',
        'run_energy_routing_job',
        'run_environment_routing_job'
    ];
    v_proc_name text;
BEGIN
    FOREACH v_proc_name IN ARRAY v_expected_proc_names
    LOOP
        SELECT
            job_id,
            schedule_interval,
            max_runtime,
            max_retries,
            retry_period,
            scheduled,
            config ->> 'overlap' AS overlap_config
        INTO v_job
        FROM timescaledb_information.jobs
        WHERE proc_schema = 'telemetry'
          AND proc_name = v_proc_name
        ORDER BY job_id
        LIMIT 1;

        IF v_job.job_id IS NULL THEN
            v_failures := array_append(v_failures, format('%s is not registered', v_proc_name));
            CONTINUE;
        END IF;

        IF v_job.schedule_interval IS DISTINCT FROM INTERVAL '1 minute' THEN
            v_failures := array_append(v_failures, format('%s schedule_interval is %s, expected 1 minute', v_proc_name, v_job.schedule_interval));
        END IF;

        IF v_job.max_runtime IS DISTINCT FROM INTERVAL '5 minutes' THEN
            v_failures := array_append(v_failures, format('%s max_runtime is %s, expected 5 minutes', v_proc_name, v_job.max_runtime));
        END IF;

        IF v_job.max_retries IS DISTINCT FROM 3 THEN
            v_failures := array_append(v_failures, format('%s max_retries is %s, expected 3', v_proc_name, v_job.max_retries));
        END IF;

        IF v_job.retry_period IS DISTINCT FROM INTERVAL '1 minute' THEN
            v_failures := array_append(v_failures, format('%s retry_period is %s, expected 1 minute', v_proc_name, v_job.retry_period));
        END IF;

        IF v_job.overlap_config IS DISTINCT FROM '15 minutes' THEN
            v_failures := array_append(v_failures, format('%s config.overlap is %s, expected 15 minutes', v_proc_name, v_job.overlap_config));
        END IF;

        IF v_job.scheduled IS DISTINCT FROM TRUE THEN
            v_failures := array_append(v_failures, format('%s is not scheduled (enabled)', v_proc_name));
        END IF;
    END LOOP;

    IF array_length(v_failures, 1) > 0 THEN
        RAISE EXCEPTION 'Job-schedule canonical contract violated: %', array_to_string(v_failures, '; ');
    END IF;
END
$$;

-- No duplicate registrations for any of the three jobs.
DO $$
DECLARE
    v_duplicates text[];
BEGIN
    SELECT array_agg(format('%s (%s registrations)', proc_name, cnt))
    INTO v_duplicates
    FROM (
        SELECT proc_name, count(*) AS cnt
        FROM timescaledb_information.jobs
        WHERE proc_schema = 'telemetry'
          AND proc_name IN ('run_normalization_job', 'run_energy_routing_job', 'run_environment_routing_job')
        GROUP BY proc_name
        HAVING count(*) > 1
    ) dup;

    IF v_duplicates IS NOT NULL THEN
        RAISE EXCEPTION 'Duplicate telemetry routing job registrations found: %', v_duplicates;
    END IF;
END
$$;

-- =============================================================================
-- Phase 2 Foundation, Phase 0b (migration 208) job-hardening contract.
--
-- The seven analytical-tier jobs must be registered exactly once, against the
-- expected schema.proc, with a FINITE runtime/retry policy and the
-- check_config validator wired:
--
--   schedule_interval : unchanged per tier (cadence is NOT touched by 0b)
--   max_runtime       : 5 minutes  (1min / 5min / 15min tiers)
--                       10 minutes (hourly / daily / demand / environment_daily)
--   max_retries       : 3
--   retry_period      : 5 minutes
--   scheduled         : TRUE
--   config.lookback   : unchanged per tier, present and non-empty
--   check_config      : config.assert_analytical_lookback_job_config
-- =============================================================================
DO $$
DECLARE
    v_failures text[] := ARRAY[]::text[];
    v_job RECORD;
    v_exp RECORD;
    v_cnt integer;
BEGIN
    FOR v_exp IN
        SELECT * FROM (VALUES
            ('analytics', 'run_energy_consumption_1min_job',   INTERVAL '1 minute',  INTERVAL '5 minutes',  '30 minutes'),
            ('analytics', 'run_energy_consumption_5min_job',   INTERVAL '1 minute',  INTERVAL '5 minutes',  '30 minutes'),
            ('analytics', 'run_energy_consumption_15min_job',  INTERVAL '5 minutes', INTERVAL '5 minutes',  '2 hours'),
            ('analytics', 'run_energy_consumption_hourly_job', INTERVAL '15 minutes',INTERVAL '10 minutes', '2 days'),
            ('analytics', 'run_energy_consumption_daily_job',  INTERVAL '1 hour',    INTERVAL '10 minutes', '8 days'),
            ('analytics', 'run_demand_calculation_job',        INTERVAL '1 minute',  INTERVAL '10 minutes', '3 hours'),
            ('telemetry', 'run_environment_daily_job',         INTERVAL '1 hour',    INTERVAL '10 minutes', '8 days')
        ) AS t(sch, prc, sched, mrt, lookback)
    LOOP
        SELECT count(*) INTO v_cnt
        FROM timescaledb_information.jobs
        WHERE proc_schema = v_exp.sch AND proc_name = v_exp.prc;

        IF v_cnt = 0 THEN
            v_failures := array_append(v_failures, format('%s.%s is not registered', v_exp.sch, v_exp.prc));
            CONTINUE;
        ELSIF v_cnt > 1 THEN
            v_failures := array_append(v_failures, format('%s.%s has %s registrations, expected 1', v_exp.sch, v_exp.prc, v_cnt));
        END IF;

        SELECT schedule_interval, max_runtime, max_retries, retry_period, scheduled,
               config ->> 'lookback' AS lookback,
               check_schema, check_name
        INTO v_job
        FROM timescaledb_information.jobs
        WHERE proc_schema = v_exp.sch AND proc_name = v_exp.prc
        ORDER BY job_id
        LIMIT 1;

        IF v_job.schedule_interval IS DISTINCT FROM v_exp.sched THEN
            v_failures := array_append(v_failures, format('%s schedule_interval is %s, expected %s', v_exp.prc, v_job.schedule_interval, v_exp.sched));
        END IF;
        IF v_job.max_runtime IS DISTINCT FROM v_exp.mrt THEN
            v_failures := array_append(v_failures, format('%s max_runtime is %s, expected %s', v_exp.prc, v_job.max_runtime, v_exp.mrt));
        END IF;
        IF v_job.max_runtime = INTERVAL '0' THEN
            v_failures := array_append(v_failures, format('%s max_runtime is unlimited (00:00:00)', v_exp.prc));
        END IF;
        IF v_job.max_retries IS DISTINCT FROM 3 THEN
            v_failures := array_append(v_failures, format('%s max_retries is %s, expected 3', v_exp.prc, v_job.max_retries));
        END IF;
        IF v_job.retry_period IS DISTINCT FROM INTERVAL '5 minutes' THEN
            v_failures := array_append(v_failures, format('%s retry_period is %s, expected 5 minutes', v_exp.prc, v_job.retry_period));
        END IF;
        IF v_job.scheduled IS DISTINCT FROM TRUE THEN
            v_failures := array_append(v_failures, format('%s is not scheduled (enabled)', v_exp.prc));
        END IF;
        IF v_job.lookback IS DISTINCT FROM v_exp.lookback THEN
            v_failures := array_append(v_failures, format('%s config.lookback is %s, expected %s', v_exp.prc, v_job.lookback, v_exp.lookback));
        END IF;
        IF v_job.check_schema IS DISTINCT FROM 'config'
           OR v_job.check_name IS DISTINCT FROM 'assert_analytical_lookback_job_config' THEN
            v_failures := array_append(v_failures, format('%s check_config is %s.%s, expected config.assert_analytical_lookback_job_config',
                v_exp.prc, v_job.check_schema, v_job.check_name));
        END IF;
    END LOOP;

    IF array_length(v_failures, 1) > 0 THEN
        RAISE EXCEPTION 'Analytical job-hardening contract violated: %', array_to_string(v_failures, '; ');
    END IF;
END
$$;

SELECT 'Job-schedule canonical contract assertions passed.' AS result;
