-- ============================================================================
-- 174_short_raw_retention_and_failure_quarantine.sql
--
-- Purpose:
--   Reduce normal raw-message retention to seven days while preserving raw
--   messages that produced no persisted normalized rows for thirty days.
--
-- Design:
--   telemetry.raw_messages
--       - one-day chunks for future data
--       - compression after one day
--       - retention after seven days
--
--   telemetry.raw_message_failures
--       - raw payload quarantine
--       - populated only after normalization has checkpointed past the message
--       - twenty-minute default grace period
--       - compression after seven days
--       - retention after thirty days
--
-- Limitation:
--   This version identifies zero-output normalization failures. It does not
--   identify partial normalization where at least one point was persisted.
-- ============================================================================


-- ----------------------------------------------------------------------------
-- 1. Failure quarantine hypertable.
-- ----------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS telemetry.raw_message_failures
(
    raw_received_at       TIMESTAMPTZ NOT NULL,
    raw_message_id        BIGINT NOT NULL,

    detected_at           TIMESTAMPTZ NOT NULL
                          DEFAULT clock_timestamp(),

    failure_code          TEXT NOT NULL,
    failure_detail        TEXT,

    source_timestamp      TIMESTAMPTZ,
    source_protocol       TEXT NOT NULL,
    source_topic          TEXT,
    source_identifier     TEXT,
    source_message_id     TEXT,
    qos                   SMALLINT,

    payload               JSONB NOT NULL,

    PRIMARY KEY (raw_received_at, raw_message_id),

    CONSTRAINT raw_message_failures_code_not_blank
        CHECK (btrim(failure_code) <> '')
);


SELECT create_hypertable
(
    'telemetry.raw_message_failures',
    by_range('raw_received_at', INTERVAL '1 day'),
    if_not_exists => TRUE
);


COMMENT ON TABLE telemetry.raw_message_failures IS
'Thirty-day quarantine of raw messages that produced zero persisted normalized telemetry rows after the normalization checkpoint and grace period.';


COMMENT ON COLUMN telemetry.raw_message_failures.raw_message_id IS
'Original telemetry.raw_messages.id value. Identity is combined with raw_received_at because the source is a TimescaleDB hypertable.';


CREATE INDEX IF NOT EXISTS raw_message_failures_detected_at_idx
ON telemetry.raw_message_failures (detected_at DESC);


CREATE INDEX IF NOT EXISTS raw_message_failures_code_time_idx
ON telemetry.raw_message_failures
(
    failure_code,
    raw_received_at DESC
);


CREATE INDEX IF NOT EXISTS raw_message_failures_source_time_idx
ON telemetry.raw_message_failures
(
    source_identifier,
    raw_received_at DESC
)
WHERE source_identifier IS NOT NULL;


ALTER TABLE telemetry.raw_message_failures
SET
(
    timescaledb.compress,
    timescaledb.compress_segmentby =
        'failure_code,source_protocol,source_identifier',
    timescaledb.compress_orderby =
        'raw_received_at DESC,raw_message_id DESC'
);


SELECT remove_compression_policy
(
    'telemetry.raw_message_failures',
    if_exists => TRUE
);


SELECT add_compression_policy
(
    'telemetry.raw_message_failures',
    INTERVAL '7 days'
);


SELECT remove_retention_policy
(
    'telemetry.raw_message_failures',
    if_exists => TRUE
);


SELECT add_retention_policy
(
    'telemetry.raw_message_failures',
    INTERVAL '30 days'
);


-- ----------------------------------------------------------------------------
-- 2. Failure-capture pipeline state.
-- ----------------------------------------------------------------------------

INSERT INTO telemetry.pipeline_state
(
    pipeline_name,
    last_status
)
VALUES
(
    'raw_message_failures',
    'NEVER_RUN'
)
ON CONFLICT (pipeline_name) DO NOTHING;


-- ----------------------------------------------------------------------------
-- 3. Incremental failure capture.
--
-- A raw message is eligible only when:
--   - the normalization checkpoint has advanced past it;
--   - the grace period has elapsed;
--   - the canonical normalization view produces no rows for the raw message payload.
--
-- The normalization loader controls platform_received_at, so this check
-- represents persisted normalization output rather than merely view output.
-- ----------------------------------------------------------------------------

CREATE OR REPLACE PROCEDURE telemetry.capture_raw_message_failures_incremental
(
    p_overlap INTERVAL DEFAULT INTERVAL '15 minutes',
    p_grace   INTERVAL DEFAULT INTERVAL '20 minutes'
)
LANGUAGE plpgsql
AS
$$
DECLARE
    v_pipeline_name CONSTANT TEXT := 'raw_message_failures';

    v_previous_checkpoint    TIMESTAMPTZ;
    v_normalized_checkpoint  TIMESTAMPTZ;
    v_window_start           TIMESTAMPTZ;
    v_window_end             TIMESTAMPTZ;

    v_inserted_rows          BIGINT := 0;
    v_lock_acquired          BOOLEAN;
BEGIN
    IF p_overlap IS NULL OR p_overlap < INTERVAL '0 seconds' THEN
        RAISE EXCEPTION
            'p_overlap must be zero or positive; received %',
            p_overlap;
    END IF;

    IF p_grace IS NULL OR p_grace < INTERVAL '0 seconds' THEN
        RAISE EXCEPTION
            'p_grace must be zero or positive; received %',
            p_grace;
    END IF;


    SELECT pg_try_advisory_xact_lock
    (
        hashtextextended
        (
            'telemetry.capture_raw_message_failures_incremental',
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

        RETURN;
    END IF;


    SELECT last_received_at
    INTO v_previous_checkpoint
    FROM telemetry.pipeline_state
    WHERE pipeline_name = v_pipeline_name
    FOR UPDATE;


    SELECT last_received_at
    INTO v_normalized_checkpoint
    FROM telemetry.pipeline_state
    WHERE pipeline_name = 'normalized_points';


    UPDATE telemetry.pipeline_state
    SET
        last_started_at = clock_timestamp(),
        last_status = 'RUNNING',
        last_error = NULL,
        updated_at = now()
    WHERE pipeline_name = v_pipeline_name;


    IF v_normalized_checkpoint IS NULL THEN
        UPDATE telemetry.pipeline_state
        SET
            last_completed_at = clock_timestamp(),
            last_inserted_rows = 0,
            last_status = 'NO_SOURCE_DATA',
            last_error = NULL,
            updated_at = now()
        WHERE pipeline_name = v_pipeline_name;

        RETURN;
    END IF;


    v_window_end :=
        LEAST
        (
            v_normalized_checkpoint,
            clock_timestamp() - p_grace
        );


    v_window_start :=
        CASE
            WHEN v_previous_checkpoint IS NULL THEN
                GREATEST
                (
                    clock_timestamp() - INTERVAL '7 days',
                    COALESCE
                    (
                        (
                            SELECT
                                MIN(received_at)
                                - INTERVAL '1 microsecond'
                            FROM telemetry.raw_messages
                        ),
                        v_window_end
                    )
                )
            ELSE
                v_previous_checkpoint - p_overlap
        END;


    IF v_window_end <= v_window_start THEN
        UPDATE telemetry.pipeline_state
        SET
            last_completed_at = clock_timestamp(),
            last_inserted_rows = 0,
            last_status = 'SUCCESS',
            last_error = NULL,
            updated_at = now()
        WHERE pipeline_name = v_pipeline_name;

        RETURN;
    END IF;


    INSERT INTO telemetry.raw_message_failures
    (
        raw_received_at,
        raw_message_id,
        failure_code,
        failure_detail,
        source_timestamp,
        source_protocol,
        source_topic,
        source_identifier,
        source_message_id,
        qos,
        payload
    )
    SELECT
        r.received_at,
        r.id,

        CASE
            WHEN r.payload ->> '_capture_status' = 'INVALID_JSON'
                THEN 'INVALID_JSON'
            WHEN jsonb_typeof(r.payload -> 'rtdata') IS DISTINCT FROM 'array'
                THEN 'MISSING_RTDATA_ARRAY'
            WHEN jsonb_array_length(r.payload -> 'rtdata') = 0
                THEN 'EMPTY_RTDATA_ARRAY'
            ELSE
                'NO_PERSISTED_NORMALIZED_ROWS'
        END,

        'No canonical normalized rows were produced for this raw message after the normalization checkpoint and configured grace period.',

        r.source_timestamp,
        r.source_protocol,
        r.source_topic,
        r.source_identifier,
        r.source_message_id,
        r.qos,
        r.payload

    FROM telemetry.raw_messages r

    WHERE r.received_at > v_window_start
      AND r.received_at <= v_window_end

      AND NOT EXISTS
      (
          SELECT 1
          FROM telemetry.v_normalized_points np
          WHERE np.received_at = r.received_at
            AND r.payload -> 'rtdata'
                @> jsonb_build_array(np.payload)
      )

    ON CONFLICT
    (
        raw_received_at,
        raw_message_id
    )
    DO NOTHING;


    GET DIAGNOSTICS v_inserted_rows = ROW_COUNT;


    UPDATE telemetry.pipeline_state
    SET
        last_received_at = v_window_end,
        last_completed_at = clock_timestamp(),
        last_inserted_rows = v_inserted_rows,
        last_status = 'SUCCESS',
        last_error = NULL,
        updated_at = now()
    WHERE pipeline_name = v_pipeline_name;


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


COMMENT ON PROCEDURE telemetry.capture_raw_message_failures_incremental
(
    INTERVAL,
    INTERVAL
) IS
'Copies raw messages with zero persisted normalized rows into the thirty-day failure quarantine after normalization has checkpointed past them.';


-- ----------------------------------------------------------------------------
-- 4. TimescaleDB background job.
-- ----------------------------------------------------------------------------

CREATE OR REPLACE PROCEDURE telemetry.run_raw_message_failure_capture_job
(
    job_id INTEGER,
    config JSONB
)
LANGUAGE plpgsql
AS
$$
DECLARE
    v_overlap INTERVAL := INTERVAL '15 minutes';
    v_grace   INTERVAL := INTERVAL '20 minutes';
BEGIN
    IF config IS NOT NULL
       AND config ? 'overlap'
       AND NULLIF(btrim(config ->> 'overlap'), '') IS NOT NULL
    THEN
        v_overlap := (config ->> 'overlap')::INTERVAL;
    END IF;

    IF config IS NOT NULL
       AND config ? 'grace'
       AND NULLIF(btrim(config ->> 'grace'), '') IS NOT NULL
    THEN
        v_grace := (config ->> 'grace')::INTERVAL;
    END IF;


    CALL telemetry.capture_raw_message_failures_incremental
    (
        v_overlap,
        v_grace
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
      AND proc_name = 'run_raw_message_failure_capture_job'
    ORDER BY job_id
    LIMIT 1;


    IF v_job_id IS NULL THEN
        SELECT add_job
        (
            'telemetry.run_raw_message_failure_capture_job',
            INTERVAL '5 minutes',
            config => jsonb_build_object
            (
                'overlap',
                '15 minutes',
                'grace',
                '20 minutes'
            )
        )
        INTO v_job_id;
    END IF;


    PERFORM alter_job
    (
        v_job_id,
        schedule_interval => INTERVAL '5 minutes',
        max_runtime       => INTERVAL '5 minutes',
        max_retries       => 3,
        retry_period      => INTERVAL '1 minute',
        scheduled         => TRUE,
        config            => jsonb_build_object
        (
            'overlap',
            '15 minutes',
            'grace',
            '20 minutes'
        )
    );
END;
$$;


-- ----------------------------------------------------------------------------
-- 5. Shorten canonical raw storage.
--
-- Existing seven-day chunks are unchanged. Future chunks become one day,
-- allowing retention and compression to operate with tighter boundaries.
-- ----------------------------------------------------------------------------

SELECT set_chunk_time_interval
(
    'telemetry.raw_messages',
    INTERVAL '1 day'
);


ALTER TABLE telemetry.raw_messages
SET
(
    timescaledb.compress,
    timescaledb.compress_segmentby =
        'source_protocol,source_identifier',
    timescaledb.compress_orderby =
        'received_at DESC,id DESC'
);


SELECT remove_compression_policy
(
    'telemetry.raw_messages',
    if_exists => TRUE
);


SELECT add_compression_policy
(
    'telemetry.raw_messages',
    INTERVAL '1 day'
);


SELECT remove_retention_policy
(
    'telemetry.raw_messages',
    if_exists => TRUE
);


SELECT add_retention_policy
(
    'telemetry.raw_messages',
    INTERVAL '7 days'
);


-- Telegraf must never gain direct access to the quarantine.
REVOKE ALL
ON TABLE telemetry.raw_message_failures
FROM telegraf_writer;
