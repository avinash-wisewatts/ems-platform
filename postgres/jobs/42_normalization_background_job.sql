-- ============================================================================
-- File:
--   42_normalization_background_job.sql
--
-- Purpose:
--   Register the normalized telemetry loader as a TimescaleDB background job.
--
-- Schedule:
--   Every 1 minute.
--
-- Reliability:
--   - The worker calls the overlap-aware incremental loader.
--   - The loader uses a 15-minute received_at overlap.
--   - The normalized hypertable unique index provides idempotency.
--   - TimescaleDB records job executions, failures and retry status.
--
-- TimescaleDB user-defined actions require the procedure signature:
--
--     procedure(job_id INTEGER, config JSONB)
--
-- The job configuration currently supports:
--
--     {
--       "overlap": "15 minutes"
--     }
-- ============================================================================


-- ----------------------------------------------------------------------------
-- 1. TimescaleDB-compatible background procedure.
-- ----------------------------------------------------------------------------

CREATE OR REPLACE PROCEDURE telemetry.run_normalization_job
(
    job_id INTEGER,
    config JSONB
)
LANGUAGE plpgsql
AS
$$
DECLARE
    v_overlap INTERVAL := INTERVAL '15 minutes';
BEGIN
    -- Allow the overlap window to be changed declaratively through the
    -- TimescaleDB job configuration.
    IF config IS NOT NULL
       AND config ? 'overlap'
       AND NULLIF(BTRIM(config ->> 'overlap'), '') IS NOT NULL
    THEN
        v_overlap := (config ->> 'overlap')::INTERVAL;
    END IF;


    IF v_overlap < INTERVAL '0 seconds' THEN
        RAISE EXCEPTION
            'Normalization job overlap cannot be negative: %',
            v_overlap;
    END IF;


    RAISE NOTICE
        'Starting normalization job %, overlap=%',
        job_id,
        v_overlap;


    CALL telemetry.load_normalized_points_incremental(v_overlap);


    RAISE NOTICE
        'Completed normalization job %',
        job_id;
END;
$$;


COMMENT ON PROCEDURE telemetry.run_normalization_job(INTEGER, JSONB) IS
'TimescaleDB background action that executes the incremental normalized telemetry loader.';


-- ----------------------------------------------------------------------------
-- 2. Register the job only when it does not already exist.
--
-- This makes the migration safe to rerun.
-- ----------------------------------------------------------------------------

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
        SELECT add_job
        (
            'telemetry.run_normalization_job',
            INTERVAL '1 minute',
            config => jsonb_build_object
            (
                'overlap',
                '15 minutes'
            )
        )
        INTO v_job_id;


        RAISE NOTICE
            'Created normalization background job with job_id=%',
            v_job_id;
    ELSE
        RAISE NOTICE
            'Normalization background job already exists with job_id=%',
            v_job_id;
    END IF;
END;
$$;


-- ----------------------------------------------------------------------------
-- 3. Apply production retry and runtime settings.
--
-- The anonymous block locates the registered job rather than hard-coding its
-- generated job ID.
-- ----------------------------------------------------------------------------

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
            'Normalization job was not found after registration';
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
