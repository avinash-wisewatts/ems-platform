-- ============================================================================
-- File:
--   47_incremental_energy_loader.sql
--
-- Purpose:
--   Incrementally route canonical normalized telemetry into the wide
--   telemetry.energy_measurements hypertable.
--
-- Processing checkpoint:
--   telemetry.normalized_points.created_at
--
-- Why created_at:
--   - event_time is controlled by the source device and can arrive late.
--   - created_at records when a normalized point was persisted locally.
--   - late device events therefore remain eligible for routing.
--
-- Reliability:
--   - A configurable overlap window is reprocessed on every execution.
--   - UNIQUE(received_at, device_id) enforces one wide row per meter event.
--   - ON CONFLICT DO UPDATE allows partial wide rows to be completed when
--     additional logical points for the same event arrive later.
--   - An advisory transaction lock prevents concurrent loader executions.
--
-- Unit contract:
--   telemetry.v_energy_measurements_route already converts:
--     kWh   -> Wh
--     kW    -> W
--     kvar  -> var
--     kvarh -> varh
--     kVA   -> VA
--     kVAh  -> VAh
-- ============================================================================


-- ----------------------------------------------------------------------------
-- 1. Support efficient checkpoint-window scans.
-- ----------------------------------------------------------------------------

CREATE INDEX IF NOT EXISTS idx_normalized_points_created_at
ON telemetry.normalized_points (created_at);


-- ----------------------------------------------------------------------------
-- 2. Register the energy-domain pipeline.
-- ----------------------------------------------------------------------------

INSERT INTO telemetry.pipeline_state
(
    pipeline_name,
    last_status
)
VALUES
(
    'energy_measurements',
    'NEVER_RUN'
)
ON CONFLICT (pipeline_name) DO NOTHING;


-- ----------------------------------------------------------------------------
-- 3. Incremental energy loader.
-- ----------------------------------------------------------------------------

CREATE OR REPLACE PROCEDURE telemetry.load_energy_measurements_incremental
(
    p_overlap INTERVAL DEFAULT INTERVAL '15 minutes'
)
LANGUAGE plpgsql
AS
$$
DECLARE
    v_pipeline_name       CONSTANT TEXT := 'energy_measurements';

    v_previous_checkpoint TIMESTAMPTZ;
    v_window_start        TIMESTAMPTZ;
    v_window_end          TIMESTAMPTZ;

    v_affected_rows       BIGINT := 0;
    v_lock_acquired       BOOLEAN;
BEGIN
    IF p_overlap IS NULL OR p_overlap < INTERVAL '0 seconds' THEN
        RAISE EXCEPTION
            'p_overlap must be zero or a positive interval; received %',
            p_overlap;
    END IF;


    -- Prevent two energy-routing executions from modifying the same event rows.
    SELECT pg_try_advisory_xact_lock
    (
        hashtextextended
        (
            'telemetry.load_energy_measurements_incremental',
            0
        )
    )
    INTO v_lock_acquired;


    IF NOT v_lock_acquired THEN
        UPDATE telemetry.pipeline_state
        SET
            last_status = 'SKIPPED_LOCKED',
            last_error = NULL,
            updated_at = now()
        WHERE pipeline_name = v_pipeline_name;

        RAISE NOTICE
            'Energy loader skipped because another execution is active';

        RETURN;
    END IF;


    SELECT last_received_at
    INTO v_previous_checkpoint
    FROM telemetry.pipeline_state
    WHERE pipeline_name = v_pipeline_name
    FOR UPDATE;


    UPDATE telemetry.pipeline_state
    SET
        last_started_at = clock_timestamp(),
        last_status = 'RUNNING',
        last_error = NULL,
        updated_at = now()
    WHERE pipeline_name = v_pipeline_name;


    -- Freeze the upper checkpoint boundary for this run.
    SELECT MAX(created_at)
    INTO v_window_end
    FROM telemetry.normalized_points;


    IF v_window_end IS NULL THEN
        UPDATE telemetry.pipeline_state
        SET
            last_completed_at = clock_timestamp(),
            last_inserted_rows = 0,
            last_status = 'NO_SOURCE_DATA',
            last_error = NULL,
            updated_at = now()
        WHERE pipeline_name = v_pipeline_name;

        RAISE NOTICE
            'No rows exist in telemetry.normalized_points';

        RETURN;
    END IF;


    v_window_start :=
        CASE
            WHEN v_previous_checkpoint IS NULL
                THEN '-infinity'::TIMESTAMPTZ
            ELSE v_previous_checkpoint - p_overlap
        END;


    -- Find only event/device keys touched within this processing window.
    --
    -- The routing view is then queried for the complete current pivot for each
    -- affected event. This safely completes partial rows.
    WITH affected_events AS
    (
        SELECT DISTINCT
            np.event_time AS received_at,
            np.device_id
        FROM telemetry.normalized_points np
        WHERE np.created_at > v_window_start
          AND np.created_at <= v_window_end
    )
    INSERT INTO telemetry.energy_measurements
    (
        received_at,
        source_timestamp,

        organization_id,
        site_id,
        gateway_id,
        device_id,
        asset_id,

        import_energy_total_wh,
        export_energy_total_wh,

        reactive_energy_total_varh,
        reactive_export_energy_total_varh,

        apparent_energy_total_vah,

        active_power_total_w,
        active_power_l1_w,
        active_power_l2_w,
        active_power_l3_w,

        reactive_power_total_var,
        apparent_power_total_va,

        voltage_l1_v,
        voltage_l2_v,
        voltage_l3_v,

        current_l1_a,
        current_l2_a,
        current_l3_a,

        power_factor_total,
        frequency_hz,

        current_thd_l1_percent,
        current_thd_l2_percent,
        current_thd_l3_percent,

        is_estimated
    )
    SELECT
        r.received_at,
        r.source_timestamp,

        r.organization_id,
        r.site_id,
        r.gateway_id,
        r.device_id,
        r.asset_id,

        r.import_energy_total_wh,
        r.export_energy_total_wh,

        r.reactive_energy_total_varh,
        r.reactive_export_energy_total_varh,

        r.apparent_energy_total_vah,

        r.active_power_total_w,
        r.active_power_l1_w,
        r.active_power_l2_w,
        r.active_power_l3_w,

        r.reactive_power_total_var,
        r.apparent_power_total_va,

        r.voltage_l1_v,
        r.voltage_l2_v,
        r.voltage_l3_v,

        r.current_l1_a,
        r.current_l2_a,
        r.current_l3_a,

        r.power_factor_total,
        r.frequency_hz,

        r.current_thd_l1_percent,
        r.current_thd_l2_percent,
        r.current_thd_l3_percent,

        FALSE

    FROM affected_events ae

    JOIN telemetry.v_energy_measurements_route r
      ON r.received_at = ae.received_at
     AND r.device_id = ae.device_id

    ON CONFLICT
    (
        received_at,
        device_id
    )
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
                telemetry.energy_measurements.asset_id
            ),

        import_energy_total_wh =
            COALESCE(
                EXCLUDED.import_energy_total_wh,
                telemetry.energy_measurements.import_energy_total_wh
            ),

        export_energy_total_wh =
            COALESCE(
                EXCLUDED.export_energy_total_wh,
                telemetry.energy_measurements.export_energy_total_wh
            ),

        reactive_energy_total_varh =
            COALESCE(
                EXCLUDED.reactive_energy_total_varh,
                telemetry.energy_measurements.reactive_energy_total_varh
            ),

        reactive_export_energy_total_varh =
            COALESCE(
                EXCLUDED.reactive_export_energy_total_varh,
                telemetry.energy_measurements.reactive_export_energy_total_varh
            ),

        apparent_energy_total_vah =
            COALESCE(
                EXCLUDED.apparent_energy_total_vah,
                telemetry.energy_measurements.apparent_energy_total_vah
            ),

        active_power_total_w =
            COALESCE(
                EXCLUDED.active_power_total_w,
                telemetry.energy_measurements.active_power_total_w
            ),

        active_power_l1_w =
            COALESCE(
                EXCLUDED.active_power_l1_w,
                telemetry.energy_measurements.active_power_l1_w
            ),

        active_power_l2_w =
            COALESCE(
                EXCLUDED.active_power_l2_w,
                telemetry.energy_measurements.active_power_l2_w
            ),

        active_power_l3_w =
            COALESCE(
                EXCLUDED.active_power_l3_w,
                telemetry.energy_measurements.active_power_l3_w
            ),

        reactive_power_total_var =
            COALESCE(
                EXCLUDED.reactive_power_total_var,
                telemetry.energy_measurements.reactive_power_total_var
            ),

        apparent_power_total_va =
            COALESCE(
                EXCLUDED.apparent_power_total_va,
                telemetry.energy_measurements.apparent_power_total_va
            ),

        voltage_l1_v =
            COALESCE(
                EXCLUDED.voltage_l1_v,
                telemetry.energy_measurements.voltage_l1_v
            ),

        voltage_l2_v =
            COALESCE(
                EXCLUDED.voltage_l2_v,
                telemetry.energy_measurements.voltage_l2_v
            ),

        voltage_l3_v =
            COALESCE(
                EXCLUDED.voltage_l3_v,
                telemetry.energy_measurements.voltage_l3_v
            ),

        current_l1_a =
            COALESCE(
                EXCLUDED.current_l1_a,
                telemetry.energy_measurements.current_l1_a
            ),

        current_l2_a =
            COALESCE(
                EXCLUDED.current_l2_a,
                telemetry.energy_measurements.current_l2_a
            ),

        current_l3_a =
            COALESCE(
                EXCLUDED.current_l3_a,
                telemetry.energy_measurements.current_l3_a
            ),

        power_factor_total =
            COALESCE(
                EXCLUDED.power_factor_total,
                telemetry.energy_measurements.power_factor_total
            ),

        frequency_hz =
            COALESCE(
                EXCLUDED.frequency_hz,
                telemetry.energy_measurements.frequency_hz
            ),

        current_thd_l1_percent =
            COALESCE(
                EXCLUDED.current_thd_l1_percent,
                telemetry.energy_measurements.current_thd_l1_percent
            ),

        current_thd_l2_percent =
            COALESCE(
                EXCLUDED.current_thd_l2_percent,
                telemetry.energy_measurements.current_thd_l2_percent
            ),

        current_thd_l3_percent =
            COALESCE(
                EXCLUDED.current_thd_l3_percent,
                telemetry.energy_measurements.current_thd_l3_percent
            );


    GET DIAGNOSTICS v_affected_rows = ROW_COUNT;


    UPDATE telemetry.pipeline_state
    SET
        last_received_at = v_window_end,
        last_completed_at = clock_timestamp(),
        last_inserted_rows = v_affected_rows,
        last_status = 'SUCCESS',
        last_error = NULL,
        updated_at = now()
    WHERE pipeline_name = v_pipeline_name;


    RAISE NOTICE
        'Energy routing succeeded: window=(%, %], affected_rows=%',
        v_window_start,
        v_window_end,
        v_affected_rows;


EXCEPTION
    WHEN OTHERS THEN
        UPDATE telemetry.pipeline_state
        SET
            last_completed_at = clock_timestamp(),
            last_inserted_rows = 0,
            last_status = 'FAILED',
            last_error = SQLSTATE || ': ' || SQLERRM,
            updated_at = now()
        WHERE pipeline_name = v_pipeline_name;

        RAISE;
END;
$$;


COMMENT ON PROCEDURE
telemetry.load_energy_measurements_incremental(INTERVAL) IS
'Incrementally pivots normalized energy points into wide energy measurements, completing partial event rows through idempotent upserts.';
