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

SELECT 'Job-schedule canonical contract assertions passed.' AS result;
