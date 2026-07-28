-- ============================================================================
-- File:
--   68_incremental_environment_loader.sql
--
-- Purpose:
--   Incrementally load telemetry.environment_measurements from
--   telemetry.v_environment_measurements_route.
--
-- Design:
--   • Advisory locking
--   • Checkpoint-based incremental processing
--   • Configurable overlap window
--   • Idempotent UPSERT
--   • Pipeline-state tracking
--   • TimescaleDB scheduler wrapper
-- ============================================================================

CREATE OR REPLACE PROCEDURE telemetry.load_environment_measurements_incremental
(
    p_overlap INTERVAL DEFAULT INTERVAL '15 minutes'
)
LANGUAGE plpgsql
AS
$$
DECLARE
    v_pipeline_name CONSTANT TEXT := 'environment_measurements';

    v_previous_checkpoint TIMESTAMPTZ;
    v_window_start        TIMESTAMPTZ;
    v_window_end          TIMESTAMPTZ;

    v_affected_rows BIGINT := 0;
    v_lock_acquired BOOLEAN;
BEGIN

    IF p_overlap IS NULL
       OR p_overlap < INTERVAL '0 seconds'
    THEN
        RAISE EXCEPTION
            'p_overlap must be zero or positive';
    END IF;


    ------------------------------------------------------------------------
    -- Advisory lock.
    ------------------------------------------------------------------------

    SELECT pg_try_advisory_xact_lock
    (
        hashtextextended
        (
            'telemetry.load_environment_measurements_incremental',
            0
        )
    )
    INTO v_lock_acquired;


    IF NOT v_lock_acquired THEN

        UPDATE telemetry.pipeline_state
        SET
            last_status = 'SKIPPED_LOCKED',
            last_error  = NULL,
            updated_at  = now()
        WHERE pipeline_name = v_pipeline_name;

        RETURN;
    END IF;


    ------------------------------------------------------------------------
    -- Pipeline checkpoint.
    ------------------------------------------------------------------------

    SELECT last_received_at
    INTO v_previous_checkpoint
    FROM telemetry.pipeline_state
    WHERE pipeline_name = v_pipeline_name
    FOR UPDATE;


    UPDATE telemetry.pipeline_state
    SET
        last_started_at = clock_timestamp(),
        last_status     = 'RUNNING',
        last_error      = NULL,
        updated_at      = now()
    WHERE pipeline_name = v_pipeline_name;


    ------------------------------------------------------------------------
    -- Freeze source window.
    ------------------------------------------------------------------------

    SELECT MAX(created_at)
    INTO v_window_end
    FROM telemetry.normalized_points;


    IF v_window_end IS NULL THEN

        UPDATE telemetry.pipeline_state
        SET
            last_completed_at  = clock_timestamp(),
            last_inserted_rows = 0,
            last_status        = 'NO_SOURCE_DATA',
            updated_at         = now()
        WHERE pipeline_name = v_pipeline_name;

        RETURN;
    END IF;


    v_window_start :=
        CASE
            WHEN v_previous_checkpoint IS NULL
            THEN '-infinity'::TIMESTAMPTZ
            ELSE v_previous_checkpoint - p_overlap
        END;


    ------------------------------------------------------------------------
    -- Incremental UPSERT.
    ------------------------------------------------------------------------

    WITH affected_events AS
    (
        SELECT DISTINCT
            np.event_time AS received_at,
            np.device_id
        FROM telemetry.normalized_points np
        WHERE np.created_at > v_window_start
          AND np.created_at <= v_window_end
    )

    INSERT INTO telemetry.environment_measurements
    (
        received_at,
        source_timestamp,

        organization_id,
        site_id,
        gateway_id,
        device_id,
        asset_id,

        measurement_interval_seconds,
        quality_code,
        is_estimated,

        temperature_c,
        humidity_percent,
        pressure_hpa,
        co2_ppm,
        voc_ppb,

        battery_voltage_v,
        signal_strength_dbm,

        illuminance_lux,
        occupancy_activity,

        raw_archive_id
    )

    SELECT
        r.received_at,
        r.source_timestamp,

        r.organization_id,
        r.site_id,
        r.gateway_id,
        r.device_id,
        r.asset_id,

        r.measurement_interval_seconds,
        r.quality_code,
        r.is_estimated,

        r.temperature_c,
        r.humidity_percent,
        r.pressure_hpa,
        r.co2_ppm,
        r.voc_ppb,

        r.battery_voltage_v,
        r.signal_strength_dbm,

        r.illuminance_lux,
        r.occupancy_activity,

        r.raw_archive_id

    FROM affected_events ae

    JOIN telemetry.v_environment_measurements_route r
      ON r.received_at = ae.received_at
     AND r.device_id   = ae.device_id

    ON CONFLICT
    (
        received_at,
        device_id
    )
    WHERE device_id IS NOT NULL
    DO UPDATE
    SET

        source_timestamp =
            EXCLUDED.source_timestamp,

        organization_id =
            EXCLUDED.organization_id,

        site_id =
            EXCLUDED.site_id,

        gateway_id =
            EXCLUDED.gateway_id,

        asset_id =
            COALESCE(
                EXCLUDED.asset_id,
                telemetry.environment_measurements.asset_id
            ),

        temperature_c =
            COALESCE(
                EXCLUDED.temperature_c,
                telemetry.environment_measurements.temperature_c
            ),

        humidity_percent =
            COALESCE(
                EXCLUDED.humidity_percent,
                telemetry.environment_measurements.humidity_percent
            ),

        pressure_hpa =
            COALESCE(
                EXCLUDED.pressure_hpa,
                telemetry.environment_measurements.pressure_hpa
            ),

        co2_ppm =
            COALESCE(
                EXCLUDED.co2_ppm,
                telemetry.environment_measurements.co2_ppm
            ),

        voc_ppb =
            COALESCE(
                EXCLUDED.voc_ppb,
                telemetry.environment_measurements.voc_ppb
            ),

        battery_voltage_v =
            COALESCE(
                EXCLUDED.battery_voltage_v,
                telemetry.environment_measurements.battery_voltage_v
            ),

        signal_strength_dbm =
            COALESCE(
                EXCLUDED.signal_strength_dbm,
                telemetry.environment_measurements.signal_strength_dbm
            ),

        illuminance_lux =
            COALESCE(
                EXCLUDED.illuminance_lux,
                telemetry.environment_measurements.illuminance_lux
            ),

        occupancy_activity =
            COALESCE(
                EXCLUDED.occupancy_activity,
                telemetry.environment_measurements.occupancy_activity
            );



    GET DIAGNOSTICS v_affected_rows = ROW_COUNT;


    UPDATE telemetry.pipeline_state
    SET
        last_received_at   = v_window_end,
        last_completed_at  = clock_timestamp(),
        last_inserted_rows = v_affected_rows,
        last_status        = 'SUCCESS',
        last_error         = NULL,
        updated_at         = now()
    WHERE pipeline_name = v_pipeline_name;


EXCEPTION
    WHEN OTHERS THEN

        UPDATE telemetry.pipeline_state
        SET
            last_completed_at  = clock_timestamp(),
            last_inserted_rows = 0,
            last_status        = 'FAILED',
            last_error         = SQLSTATE || ': ' || SQLERRM,
            updated_at         = now()
        WHERE pipeline_name = v_pipeline_name;

        RAISE;
END;
$$;



CREATE OR REPLACE PROCEDURE telemetry.run_environment_routing_job
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

    CALL telemetry.load_environment_measurements_incremental
    (
        v_overlap
    );
END;
$$;
