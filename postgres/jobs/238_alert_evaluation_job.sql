-- ============================================================================
-- File:
--   238_alert_evaluation_job.sql
--
-- Purpose:
--   Register the TimescaleDB background job that evaluates MVP-7 Basic
--   Alerts (analytics.run_alert_evaluation_job -> analytics.evaluate_alerts,
--   migration 239). ADR-017 (A1): extends the existing TimescaleDB-native
--   background-job mechanism already used by
--   postgres/jobs/69_environment_routing_job.sql and its siblings.
--
-- Schedule:
--   Every 1 minute -- satisfies both the 5-minute qualification and
--   1-minute resolution granularity ADR-016 decisions 2 and 4 require.
-- ============================================================================

DO
$$
DECLARE
    v_job_id INTEGER;
BEGIN
    SELECT job_id
    INTO v_job_id
    FROM timescaledb_information.jobs
    WHERE proc_schema = 'analytics'
      AND proc_name = 'run_alert_evaluation_job'
    ORDER BY job_id
    LIMIT 1;

    IF v_job_id IS NULL THEN
        PERFORM add_job
        (
            'analytics.run_alert_evaluation_job',
            INTERVAL '1 minute',

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
                TRUE
        );
    END IF;
END;
$$;
