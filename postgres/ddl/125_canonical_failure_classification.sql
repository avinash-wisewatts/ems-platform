-- 125_canonical_failure_classification.sql
-- Classify raw-message normalization failures by canonical telemetry identity.
-- normalized_points deduplicates on (event_time, device_id, logical_point_id)
-- and may move raw_message_id/platform_received_at lineage to a newer replay.
-- Failure capture therefore must not infer missing telemetry from mutable lineage.
BEGIN;

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

    v_previous_checkpoint   TIMESTAMPTZ;
    v_normalized_checkpoint TIMESTAMPTZ;
    v_window_start          TIMESTAMPTZ;
    v_window_end            TIMESTAMPTZ;

    v_inserted_rows BIGINT := 0;
    v_lock_acquired BOOLEAN;
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
                            SELECT MIN(received_at) - INTERVAL '1 microsecond'
                            FROM telemetry.raw_messages
                        ),
                        v_window_end
                    )
                )
            ELSE
                v_previous_checkpoint - LEAST(p_overlap, INTERVAL '1 minute')
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

    WITH raw_candidates AS
    (
        SELECT r.*
        FROM telemetry.raw_messages r
        WHERE r.received_at > v_window_start
          AND r.received_at <= v_window_end
    ),
    message_metrics AS
    (
        SELECT
            r.received_at AS raw_received_at,
            r.id AS raw_message_id,

            CASE
                WHEN jsonb_typeof(r.payload -> 'rtdata') = 'array'
                    THEN jsonb_array_length(r.payload -> 'rtdata')
                ELSE 0
            END AS raw_element_count,

            COALESCE(element_metrics.resolved_element_count, 0)
                AS resolved_element_count,

            COALESCE(element_metrics.unresolved_element_count, 0)
                AS unresolved_element_count,

            COALESCE(element_metrics.profiled_element_count, 0)
                AS profiled_element_count,

            COALESCE(element_metrics.unprofiled_element_count, 0)
                AS unprofiled_element_count,

            COALESCE(element_metrics.enabled_point_count, 0)
                AS enabled_point_count,

            COALESCE(element_metrics.produced_point_count, 0)
                AS produced_point_count,

            COALESCE
            (
                element_metrics.unresolved_uids,
                '[]'::JSONB
            ) AS unresolved_uids

        FROM raw_candidates r

        LEFT JOIN LATERAL
        (
            SELECT
                COUNT(*) FILTER
                (
                    WHERE resolved.device_id IS NOT NULL
                )::INTEGER AS resolved_element_count,

                COUNT(*) FILTER
                (
                    WHERE resolved.device_id IS NULL
                )::INTEGER AS unresolved_element_count,

                COUNT(*) FILTER
                (
                    WHERE resolved.device_id IS NOT NULL
                      AND resolved.profile_id IS NOT NULL
                )::INTEGER AS profiled_element_count,

                COUNT(*) FILTER
                (
                    WHERE resolved.device_id IS NOT NULL
                      AND resolved.profile_id IS NULL
                )::INTEGER AS unprofiled_element_count,

                COALESCE
                (
                    SUM(resolved.enabled_points),
                    0
                )::INTEGER AS enabled_point_count,

                COALESCE
                (
                    SUM(resolved.persisted_points),
                    0
                )::INTEGER AS produced_point_count,

                COALESCE
                (
                    jsonb_agg
                    (
                        jsonb_build_object
                        (
                            'element_number', resolved.element_number,
                            'uid', resolved.device_uid,
                            'did', resolved.device_identifier
                        )
                        ORDER BY resolved.element_number
                    )
                    FILTER
                    (
                        WHERE resolved.device_id IS NULL
                    ),
                    '[]'::JSONB
                ) AS unresolved_uids

            FROM
            (
                SELECT
                    element.element_number,
                    element.device_uid,
                    element.device_identifier,
                    element.event_time,
                    d.id AS device_id,
                    d.profile_id,
                    COALESCE(point_counts.enabled_points, 0)
                        AS enabled_points,
                    COALESCE(point_counts.persisted_points, 0)
                        AS persisted_points

                FROM
                (
                    SELECT
                        e.ordinality::INTEGER AS element_number,
                        e.value ->> 'uid' AS device_uid,
                        e.value ->> 'did' AS device_identifier,
                        CASE
                            WHEN e.value ->> 'ts' IS NULL
                                THEN r.received_at
                            WHEN pg_input_is_valid
                                 (
                                     e.value ->> 'ts',
                                     'double precision'
                                 )
                                THEN to_timestamp
                                     (
                                         (e.value ->> 'ts')::DOUBLE PRECISION
                                     )
                            ELSE r.received_at
                        END AS event_time

                    FROM jsonb_array_elements
                    (
                        CASE
                            WHEN jsonb_typeof(r.payload -> 'rtdata') = 'array'
                                THEN r.payload -> 'rtdata'
                            ELSE '[]'::JSONB
                        END
                    )
                    WITH ORDINALITY AS e(value, ordinality)
                ) AS element

                LEFT JOIN LATERAL
                (
                    SELECT di.device_id
                    FROM metadata.device_identifiers di
                    WHERE di.identifier_type = 'MQTT_UID'
                      AND lower(di.identifier_value) =
                          lower(element.device_uid)
                    ORDER BY di.device_id
                    LIMIT 1
                ) AS identifier
                  ON TRUE

                LEFT JOIN metadata.devices d
                  ON d.id = identifier.device_id

                LEFT JOIN LATERAL
                (
                    SELECT
                        COUNT(*)::INTEGER AS enabled_points,
                        COUNT(*) FILTER
                        (
                            WHERE EXISTS
                            (
                                SELECT 1
                                FROM telemetry.normalized_points np
                                WHERE np.device_id = d.id
                                  AND np.event_time = element.event_time
                                  AND np.logical_point_id =
                                      dpc.logical_point_id
                            )
                        )::INTEGER AS persisted_points
                    FROM config.device_point_configuration dpc
                    WHERE dpc.device_id = d.id
                      AND dpc.is_enabled
                ) AS point_counts
                  ON TRUE
            ) AS resolved
        ) AS element_metrics
          ON TRUE
    ),
    classified AS
    (
        SELECT
            r.*,
            m.raw_element_count,
            m.resolved_element_count,
            m.unresolved_element_count,
            m.profiled_element_count,
            m.unprofiled_element_count,
            m.enabled_point_count,
            m.produced_point_count,
            m.unresolved_uids,

            CASE
                WHEN r.payload ->> '_capture_status' = 'INVALID_JSON'
                    THEN 'INVALID_JSON'

                WHEN jsonb_typeof(r.payload -> 'rtdata')
                     IS DISTINCT FROM 'array'
                    THEN 'MISSING_RTDATA_ARRAY'

                WHEN jsonb_array_length(r.payload -> 'rtdata') = 0
                    THEN 'EMPTY_RTDATA_ARRAY'

                WHEN m.unresolved_element_count > 0
                    THEN 'UNRESOLVED_DEVICE_ELEMENTS'

                WHEN m.unprofiled_element_count > 0
                    THEN 'DEVICE_WITHOUT_PROFILE'

                WHEN m.resolved_element_count > 0
                 AND m.enabled_point_count = 0
                    THEN 'NO_ENABLED_POINTS'

                WHEN m.enabled_point_count > 0
                 AND m.produced_point_count = 0
                    THEN 'NO_PERSISTED_NORMALIZED_ROWS'

                WHEN m.produced_point_count < m.enabled_point_count
                    THEN 'PARTIAL_NORMALIZATION'

                ELSE NULL
            END AS failure_code

        FROM raw_candidates r
        JOIN message_metrics m
          ON m.raw_received_at = r.received_at
         AND m.raw_message_id = r.id
    )
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
        payload,
        raw_element_count,
        resolved_element_count,
        unresolved_element_count,
        profiled_element_count,
        unprofiled_element_count,
        enabled_point_count,
        produced_point_count,
        diagnostic_details
    )
    SELECT
        c.received_at,
        c.id,
        c.failure_code,

        CASE c.failure_code
            WHEN 'INVALID_JSON'
                THEN 'The MQTT value could not be parsed as JSON.'
            WHEN 'MISSING_RTDATA_ARRAY'
                THEN 'The payload does not contain an rtdata array.'
            WHEN 'EMPTY_RTDATA_ARRAY'
                THEN 'The payload contains an empty rtdata array.'
            WHEN 'UNRESOLVED_DEVICE_ELEMENTS'
                THEN 'One or more rtdata elements use MQTT UIDs that are not configured as device identifiers.'
            WHEN 'DEVICE_WITHOUT_PROFILE'
                THEN 'One or more resolved devices do not have a device profile.'
            WHEN 'NO_ENABLED_POINTS'
                THEN 'Resolved devices have no enabled device-point configuration.'
            WHEN 'NO_PERSISTED_NORMALIZED_ROWS'
                THEN 'Enabled points exist, but no canonical normalized rows were produced.'
            WHEN 'PARTIAL_NORMALIZATION'
                THEN 'Fewer canonical normalized rows were produced than the number of enabled device points.'
        END,

        c.source_timestamp,
        c.source_protocol,
        c.source_topic,
        c.source_identifier,
        c.source_message_id,
        c.qos,
        c.payload,
        c.raw_element_count,
        c.resolved_element_count,
        c.unresolved_element_count,
        c.profiled_element_count,
        c.unprofiled_element_count,
        c.enabled_point_count,
        c.produced_point_count,

        jsonb_build_object
        (
            'raw_element_count', c.raw_element_count,
            'resolved_element_count', c.resolved_element_count,
            'unresolved_element_count', c.unresolved_element_count,
            'profiled_element_count', c.profiled_element_count,
            'unprofiled_element_count', c.unprofiled_element_count,
            'enabled_point_count', c.enabled_point_count,
            'produced_point_count', c.produced_point_count,
            'normalization_match_basis', 'CANONICAL_IDENTITY',
            'point_shortfall',
                GREATEST
                (
                    c.enabled_point_count - c.produced_point_count,
                    0
                ),
            'unresolved_elements', c.unresolved_uids
        )

    FROM classified c
    WHERE c.failure_code IS NOT NULL

    ON CONFLICT
    (
        raw_received_at,
        raw_message_id
    )
    DO UPDATE
    SET
        detected_at = clock_timestamp(),
        failure_code = EXCLUDED.failure_code,
        failure_detail = EXCLUDED.failure_detail,
        source_timestamp = EXCLUDED.source_timestamp,
        source_protocol = EXCLUDED.source_protocol,
        source_topic = EXCLUDED.source_topic,
        source_identifier = EXCLUDED.source_identifier,
        source_message_id = EXCLUDED.source_message_id,
        qos = EXCLUDED.qos,
        payload = EXCLUDED.payload,
        raw_element_count = EXCLUDED.raw_element_count,
        resolved_element_count = EXCLUDED.resolved_element_count,
        unresolved_element_count = EXCLUDED.unresolved_element_count,
        profiled_element_count = EXCLUDED.profiled_element_count,
        unprofiled_element_count = EXCLUDED.unprofiled_element_count,
        enabled_point_count = EXCLUDED.enabled_point_count,
        produced_point_count = EXCLUDED.produced_point_count,
        diagnostic_details = EXCLUDED.diagnostic_details;

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

COMMENT ON PROCEDURE telemetry.capture_raw_message_failures_incremental(INTERVAL, INTERVAL) IS
'Captures failed raw MQTT messages after the normalization checkpoint/grace boundary. Persisted-point coverage is evaluated by canonical (device_id,event_time,logical_point_id) identity so replay lineage updates cannot create false PARTIAL_NORMALIZATION failures.';

COMMIT;
