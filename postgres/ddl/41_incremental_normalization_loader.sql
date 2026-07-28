-- ============================================================================
-- File:
--   41_incremental_normalization_loader.sql
--
-- Purpose:
--   Incrementally persist telemetry.v_normalized_points into the durable
--   telemetry.normalized_points TimescaleDB hypertable.
--
-- Reliability model:
--
--   1. The checkpoint uses mqtt_staging.received_at, which represents arrival
--      at the database rather than the device clock.
--
--   2. Every execution reprocesses an overlap window. This protects against:
--        - messages committed around the checkpoint boundary
--        - multiple messages sharing the same received_at timestamp
--        - loader interruptions and retries
--
--   3. The normalized hypertable UNIQUE index provides idempotency:
--
--        event_time + device_id + logical_point_id
--
--   4. ON CONFLICT DO NOTHING makes overlapping scans safe.
--
--   5. A PostgreSQL advisory transaction lock prevents two loader executions
--      from running concurrently.
--
-- Important:
--   Late device timestamps are still accepted. A payload that arrives now with
--   an older event_time has a new received_at value and is therefore selected
--   by the incremental loader.
-- ============================================================================


-- ----------------------------------------------------------------------------
-- 1. Ensure the raw landing table can be searched efficiently by arrival time.
-- ----------------------------------------------------------------------------

CREATE INDEX IF NOT EXISTS idx_mqtt_staging_received_at
ON public.mqtt_staging (received_at);


-- ----------------------------------------------------------------------------
-- 2. Ensure the durable hypertable has deterministic duplicate protection.
-- ----------------------------------------------------------------------------

CREATE UNIQUE INDEX IF NOT EXISTS uq_normalized_points_identity
ON telemetry.normalized_points
(
    event_time,
    device_id,
    logical_point_id
);


-- ----------------------------------------------------------------------------
-- 3. Persist loader execution state.
--
-- One row is maintained for each pipeline. This supports future pipelines such
-- as environmental telemetry, alarms and asset-health normalization.
-- ----------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS telemetry.pipeline_state
(
    pipeline_name            TEXT PRIMARY KEY,

    last_received_at         TIMESTAMPTZ,

    last_started_at          TIMESTAMPTZ,
    last_completed_at        TIMESTAMPTZ,

    last_inserted_rows       BIGINT NOT NULL DEFAULT 0,

    last_status              TEXT NOT NULL DEFAULT 'NEVER_RUN',

    last_error               TEXT,

    updated_at               TIMESTAMPTZ NOT NULL DEFAULT now(),

    CONSTRAINT ck_pipeline_state_status
        CHECK
        (
            last_status IN
            (
                'NEVER_RUN',
                'RUNNING',
                'SUCCESS',
                'FAILED',
                'SKIPPED_LOCKED',
                'NO_SOURCE_DATA'
            )
        )
);


INSERT INTO telemetry.pipeline_state
(
    pipeline_name,
    last_status
)
VALUES
(
    'normalized_points',
    'NEVER_RUN'
)
ON CONFLICT (pipeline_name) DO NOTHING;


-- ----------------------------------------------------------------------------
-- 4. Incremental normalization procedure.
--
-- p_overlap:
--   Reprocess this much arrival-time history on every execution.
--
-- Default:
--   15 minutes.
--
-- This does not limit how old event_time may be. It only controls overlap on
-- the database arrival timestamp.
-- ----------------------------------------------------------------------------

CREATE OR REPLACE PROCEDURE telemetry.load_normalized_points_incremental
(
    p_overlap INTERVAL DEFAULT INTERVAL '15 minutes'
)
LANGUAGE plpgsql
AS
$$
DECLARE
    v_pipeline_name       CONSTANT TEXT := 'normalized_points';

    v_previous_checkpoint TIMESTAMPTZ;
    v_window_start        TIMESTAMPTZ;
    v_window_end          TIMESTAMPTZ;

    v_inserted_rows       BIGINT := 0;
    v_lock_acquired       BOOLEAN;
BEGIN
    -- Reject invalid configuration rather than silently skipping data.
    IF p_overlap IS NULL OR p_overlap < INTERVAL '0 seconds' THEN
        RAISE EXCEPTION
            'p_overlap must be zero or a positive interval; received %',
            p_overlap;
    END IF;


    -- Prevent concurrent executions of this specific loader.
    SELECT pg_try_advisory_xact_lock
    (
        hashtextextended
        (
            'telemetry.load_normalized_points_incremental',
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
            'Normalization loader skipped because another execution is active';

        RETURN;
    END IF;


    -- Lock the state row so the checkpoint cannot be changed concurrently.
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


    -- Freeze an upper boundary for this execution.
    --
    -- Rows arriving after this MAX() are intentionally left for the next run.
    SELECT MAX(received_at)
    INTO v_window_end
    FROM public.mqtt_staging;


    IF v_window_end IS NULL THEN
        UPDATE telemetry.pipeline_state
        SET
            last_completed_at = clock_timestamp(),
            last_inserted_rows = 0,
            last_status = 'NO_SOURCE_DATA',
            last_error = NULL,
            updated_at = now()
        WHERE pipeline_name = v_pipeline_name;

        RAISE NOTICE 'No rows exist in public.mqtt_staging';

        RETURN;
    END IF;


    -- On the first run, scan all available source data.
    --
    -- On subsequent runs, re-read the configured overlap before the previous
    -- checkpoint. The unique index discards any points already persisted.
    v_window_start :=
        CASE
            WHEN v_previous_checkpoint IS NULL
                THEN '-infinity'::TIMESTAMPTZ
            ELSE v_previous_checkpoint - p_overlap
        END;


    INSERT INTO telemetry.normalized_points
    (
        event_time,
        organization_id,
        site_id,
        gateway_id,
        device_id,
        logical_point_id,
        device_uid,
        logical_point,
        raw_field_name,
        raw_value,
        numeric_value,
        quality_code,
        mapping_source,
        payload
    )
    SELECT
        np.event_time,
        np.organization_id,
        np.site_id,
        np.gateway_id,
        np.device_id,
        np.logical_point_id,
        np.device_uid,
        np.logical_point,
        np.raw_field_name,
        np.raw_value,
        np.numeric_value,
        np.quality_code,
        np.mapping_source,
        np.payload
    FROM telemetry.v_normalized_points np
    WHERE np.received_at > v_window_start
      AND np.received_at <= v_window_end
    ON CONFLICT
    (
        event_time,
        device_id,
        logical_point_id
    )
    DO NOTHING;


    GET DIAGNOSTICS v_inserted_rows = ROW_COUNT;


    -- Advance the checkpoint only after the insert succeeds.
    UPDATE telemetry.pipeline_state
    SET
        last_received_at = v_window_end,
        last_completed_at = clock_timestamp(),
        last_inserted_rows = v_inserted_rows,
        last_status = 'SUCCESS',
        last_error = NULL,
        updated_at = now()
    WHERE pipeline_name = v_pipeline_name;


    RAISE NOTICE
        'Normalization succeeded: window=(%, %], inserted_rows=%',
        v_window_start,
        v_window_end,
        v_inserted_rows;


EXCEPTION
    WHEN OTHERS THEN
        -- The failing insert and checkpoint advancement are rolled back.
        --
        -- Record the diagnostic after PostgreSQL enters the exception handler.
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


-- ----------------------------------------------------------------------------
-- 5. Retire the unsafe full-table loader interface.
--
-- Existing operational commands that call telemetry.load_normalized_points()
-- will now invoke the idempotent incremental procedure rather than reloading
-- the entire normalization view without conflict handling.
-- ----------------------------------------------------------------------------

CREATE OR REPLACE PROCEDURE telemetry.load_normalized_points()
LANGUAGE plpgsql
AS
$$
BEGIN
    CALL telemetry.load_normalized_points_incremental
    (
        INTERVAL '15 minutes'
    );
END;
$$;


COMMENT ON TABLE telemetry.pipeline_state IS
'Database-managed execution state and arrival-time checkpoints for declarative telemetry pipelines.';

COMMENT ON PROCEDURE telemetry.load_normalized_points_incremental(INTERVAL) IS
'Incrementally persists normalized telemetry using an arrival-time overlap window and database-enforced deduplication.';

COMMENT ON PROCEDURE telemetry.load_normalized_points() IS
'Compatibility wrapper for the production incremental normalized telemetry loader.';
