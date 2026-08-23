-- ============================================================================
-- Migration 194
-- Correct TimescaleDB background-job schedule/overlap drift
--
-- Diagnosis (docs/operations/CICD_PIPELINE.md, "verify_jobs.sh vs. the
-- running TimescaleDB job schedule"): the canonical job-registration files
-- (postgres/jobs/42_normalization_background_job.sql,
-- 48_energy_background_job.sql, 69_environment_routing_job.sql) already
-- register each job with schedule_interval = 1 minute, config.overlap =
-- 15 minutes, max_runtime = 5 minutes, max_retries = 3, retry_period =
-- 1 minute. Those files are correct as-is and are NOT changed by this
-- migration. The defect is that the currently RUNNING job configuration on
-- staging had drifted away from that canonical definition:
--
--   run_normalization_job      : 5 min schedule / 20 min overlap  (expected 1 min / 15 min)
--   run_energy_routing_job     : 1 min schedule / 1 min overlap   (expected 1 min / 15 min)
--   run_environment_routing_job: 1 min schedule / 1 min overlap   (expected 1 min / 15 min)
--
-- This migration reasserts the canonical schedule on each already-registered
-- job. It intentionally does not create or replace any procedure and does
-- not register a job that does not already exist -- if a job is missing,
-- that is a different defect than the one diagnosed here and this migration
-- deliberately fails loudly rather than silently creating one.
-- ============================================================================


DO
$$
DECLARE
    v_job_id INTEGER;
BEGIN
    SELECT job_id
    INTO v_job_id
    FROM timescaledb_information.jobs
    WHERE proc_schema = 'telemetry'
      AND proc_name = 'run_normalization_job'
    ORDER BY job_id
    LIMIT 1;

    IF v_job_id IS NULL THEN
        RAISE EXCEPTION
            'run_normalization_job is not registered; expected an existing job to correct';
    END IF;

    PERFORM alter_job
    (
        v_job_id,
        schedule_interval => INTERVAL '1 minute',
        max_runtime       => INTERVAL '5 minutes',
        max_retries       => 3,
        retry_period      => INTERVAL '1 minute',
        scheduled         => TRUE,
        config            => jsonb_build_object
        (
            'overlap',
            '15 minutes'
        )
    );
END;
$$;


DO
$$
DECLARE
    v_job_id INTEGER;
BEGIN
    SELECT job_id
    INTO v_job_id
    FROM timescaledb_information.jobs
    WHERE proc_schema = 'telemetry'
      AND proc_name = 'run_energy_routing_job'
    ORDER BY job_id
    LIMIT 1;

    IF v_job_id IS NULL THEN
        RAISE EXCEPTION
            'run_energy_routing_job is not registered; expected an existing job to correct';
    END IF;

    PERFORM alter_job
    (
        v_job_id,
        schedule_interval => INTERVAL '1 minute',
        max_runtime       => INTERVAL '5 minutes',
        max_retries       => 3,
        retry_period      => INTERVAL '1 minute',
        scheduled         => TRUE,
        config            => jsonb_build_object
        (
            'overlap',
            '15 minutes'
        )
    );
END;
$$;


DO
$$
DECLARE
    v_job_id INTEGER;
BEGIN
    SELECT job_id
    INTO v_job_id
    FROM timescaledb_information.jobs
    WHERE proc_schema = 'telemetry'
      AND proc_name = 'run_environment_routing_job'
    ORDER BY job_id
    LIMIT 1;

    IF v_job_id IS NULL THEN
        RAISE EXCEPTION
            'run_environment_routing_job is not registered; expected an existing job to correct';
    END IF;

    PERFORM alter_job
    (
        v_job_id,
        schedule_interval => INTERVAL '1 minute',
        max_runtime       => INTERVAL '5 minutes',
        max_retries       => 3,
        retry_period      => INTERVAL '1 minute',
        scheduled         => TRUE,
        config            => jsonb_build_object
        (
            'overlap',
            '15 minutes'
        )
    );
END;
$$;
