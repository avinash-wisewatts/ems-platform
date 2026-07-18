-- ============================================================================
-- File:
--   69_environment_routing_job.sql
--
-- Purpose:
--   Register the TimescaleDB background job that routes normalized
--   environmental points into telemetry.environment_measurements.
--
-- Schedule:
--   Every 1 minute
--
-- Processing overlap:
--   15 minutes
--
-- The overlap protects against late-arriving and partially normalized payloads.
-- The loader remains idempotent through the unique key:
--
--   (received_at, device_id)
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
      AND proc_name = 'run_environment_routing_job'
    ORDER BY job_id
    LIMIT 1;

    IF v_job_id IS NULL THEN
        PERFORM add_job
        (
            'telemetry.run_environment_routing_job',
            INTERVAL '1 minute',

            config =>
                jsonb_build_object
                (
                    'overlap',
                    '15 minutes'
                ),

            initial_start =>
                now() + INTERVAL '1 minute'
        );
    ELSE
        PERFORM alter_job
        (
            v_job_id,

            schedule_interval =>
                INTERVAL '1 minute',

            max_runtime =>
                INTERVAL '5 minutes',

            max_retries =>
                3,

            retry_period =>
                INTERVAL '1 minute',

            scheduled =>
                TRUE,

            config =>
                jsonb_build_object
                (
                    'overlap',
                    '15 minutes'
                )
        );
    END IF;
END;
$$;
