-- ============================================================================
-- File:
--   48_energy_background_job.sql
--
-- Purpose:
--   Run the incremental energy-domain routing pipeline automatically through
--   TimescaleDB background jobs.
--
-- Schedule:
--   Every 1 minute.
--
-- Dependency:
--   The normalization job also runs every minute. The energy loader is
--   idempotent and overlap-aware, so exact execution ordering is not required.
--   Any normalized points missed during one cycle are picked up in the next.
-- ============================================================================


CREATE OR REPLACE PROCEDURE telemetry.run_energy_routing_job
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
    IF config IS NOT NULL
       AND config ? 'overlap'
       AND NULLIF(BTRIM(config ->> 'overlap'), '') IS NOT NULL
    THEN
        v_overlap := (config ->> 'overlap')::INTERVAL;
    END IF;


    IF v_overlap < INTERVAL '0 seconds' THEN
        RAISE EXCEPTION
            'Energy routing overlap cannot be negative: %',
            v_overlap;
    END IF;


    RAISE NOTICE
        'Starting energy routing job %, overlap=%',
        job_id,
        v_overlap;


    CALL telemetry.load_energy_measurements_incremental(v_overlap);


    RAISE NOTICE
        'Completed energy routing job %',
        job_id;
END;
$$;


COMMENT ON PROCEDURE
telemetry.run_energy_routing_job(INTEGER, JSONB) IS
'TimescaleDB background action that incrementally routes normalized telemetry into the energy domain hypertable.';


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
        SELECT add_job
        (
            'telemetry.run_energy_routing_job',
            INTERVAL '1 minute',
            config => jsonb_build_object
            (
                'overlap',
                '15 minutes'
            )
        )
        INTO v_job_id;

        RAISE NOTICE
            'Created energy-routing background job with job_id=%',
            v_job_id;
    ELSE
        RAISE NOTICE
            'Energy-routing job already exists with job_id=%',
            v_job_id;
    END IF;
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
            'Energy-routing job was not found after registration';
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
