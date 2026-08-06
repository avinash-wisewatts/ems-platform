
-- ============================================================================
-- Migration 175
-- Device-level enabled telemetry points and partial normalization diagnostics
--
-- Scope:
--   * Configure enabled/disabled logical points per device.
--   * Seed all mapped points as enabled for existing profiled devices.
--   * Keep configuration synchronized when profiles or mappings change.
--   * Normalize only enabled points.
--   * Classify unresolved rtdata elements and partial normalization.
--   * Keep NULL/zero handling at existing point-quality level.
-- ============================================================================

CREATE TABLE IF NOT EXISTS config.device_point_configuration
(
    device_id        UUID        NOT NULL,
    logical_point_id UUID        NOT NULL,
    is_enabled       BOOLEAN     NOT NULL DEFAULT TRUE,
    created_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at       TIMESTAMPTZ NOT NULL DEFAULT now(),

    CONSTRAINT device_point_configuration_pkey
        PRIMARY KEY (device_id, logical_point_id),

    CONSTRAINT device_point_configuration_device_id_fkey
        FOREIGN KEY (device_id)
        REFERENCES metadata.devices(id)
        ON DELETE CASCADE,

    CONSTRAINT device_point_configuration_logical_point_id_fkey
        FOREIGN KEY (logical_point_id)
        REFERENCES metadata.logical_points(id)
        ON DELETE CASCADE
);

CREATE INDEX IF NOT EXISTS device_point_configuration_enabled_idx
ON config.device_point_configuration (device_id, logical_point_id)
WHERE is_enabled;

COMMENT ON TABLE config.device_point_configuration IS
'Explicit device-level enablement contract for logical telemetry points. Profile mappings define capability; these rows define which points are expected for one configured device.';

COMMENT ON COLUMN config.device_point_configuration.is_enabled IS
'When true, the point participates in normalization and message completeness checks. Disabled points are ignored even if the source payload emits null, zero, or default values.';


CREATE OR REPLACE FUNCTION config.touch_device_point_configuration_updated_at()
RETURNS TRIGGER
LANGUAGE plpgsql
AS
$$
BEGIN
    NEW.updated_at := now();
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_touch_device_point_configuration_updated_at
ON config.device_point_configuration;

CREATE TRIGGER trg_touch_device_point_configuration_updated_at
BEFORE UPDATE
ON config.device_point_configuration
FOR EACH ROW
EXECUTE FUNCTION config.touch_device_point_configuration_updated_at();


CREATE OR REPLACE FUNCTION config.sync_device_point_configuration
(
    p_device_id UUID,
    p_reset BOOLEAN DEFAULT FALSE
)
RETURNS VOID
LANGUAGE plpgsql
AS
$$
BEGIN
    IF NOT EXISTS
    (
        SELECT 1
        FROM metadata.devices
        WHERE id = p_device_id
    )
    THEN
        RETURN;
    END IF;

    IF p_reset THEN
        DELETE FROM config.device_point_configuration
        WHERE device_id = p_device_id;
    END IF;

    INSERT INTO config.device_point_configuration
    (
        device_id,
        logical_point_id,
        is_enabled
    )
    SELECT
        p_device_id,
        candidate.logical_point_id,
        TRUE
    FROM
    (
        SELECT pfm.logical_point_id
        FROM metadata.devices d
        JOIN config.profile_field_mapping pfm
          ON pfm.profile_id = d.profile_id
        WHERE d.id = p_device_id

        UNION

        SELECT dfm.logical_point_id
        FROM metadata.device_field_mapping dfm
        WHERE dfm.device_id = p_device_id
    ) AS candidate
    ON CONFLICT (device_id, logical_point_id) DO NOTHING;

    DELETE FROM config.device_point_configuration dpc
    WHERE dpc.device_id = p_device_id
      AND NOT EXISTS
      (
          SELECT 1
          FROM
          (
              SELECT pfm.logical_point_id
              FROM metadata.devices d
              JOIN config.profile_field_mapping pfm
                ON pfm.profile_id = d.profile_id
              WHERE d.id = p_device_id

              UNION

              SELECT dfm.logical_point_id
              FROM metadata.device_field_mapping dfm
              WHERE dfm.device_id = p_device_id
          ) AS current_points
          WHERE current_points.logical_point_id = dpc.logical_point_id
      );
END;
$$;

COMMENT ON FUNCTION config.sync_device_point_configuration(UUID, BOOLEAN) IS
'Synchronizes one device point-enable configuration with its current profile and device-specific mappings. Existing enabled/disabled choices are preserved unless p_reset is true.';


CREATE OR REPLACE FUNCTION config.sync_device_points_after_profile_change()
RETURNS TRIGGER
LANGUAGE plpgsql
AS
$$
BEGIN
    IF TG_OP = 'INSERT'
       OR OLD.profile_id IS DISTINCT FROM NEW.profile_id
    THEN
        PERFORM config.sync_device_point_configuration(NEW.id, TRUE);
    END IF;

    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_sync_device_points_after_profile_change
ON metadata.devices;

CREATE TRIGGER trg_sync_device_points_after_profile_change
AFTER INSERT OR UPDATE OF profile_id
ON metadata.devices
FOR EACH ROW
EXECUTE FUNCTION config.sync_device_points_after_profile_change();


CREATE OR REPLACE FUNCTION config.sync_device_points_after_profile_mapping_change()
RETURNS TRIGGER
LANGUAGE plpgsql
AS
$$
DECLARE
    v_device_id UUID;
BEGIN
    IF TG_OP IN ('UPDATE', 'DELETE') THEN
        FOR v_device_id IN
            SELECT id
            FROM metadata.devices
            WHERE profile_id = OLD.profile_id
        LOOP
            PERFORM config.sync_device_point_configuration(v_device_id, FALSE);
        END LOOP;
    END IF;

    IF TG_OP IN ('INSERT', 'UPDATE') THEN
        FOR v_device_id IN
            SELECT id
            FROM metadata.devices
            WHERE profile_id = NEW.profile_id
        LOOP
            PERFORM config.sync_device_point_configuration(v_device_id, FALSE);
        END LOOP;
    END IF;

    IF TG_OP = 'DELETE' THEN
        RETURN OLD;
    END IF;

    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_sync_device_points_after_profile_mapping_change
ON config.profile_field_mapping;

CREATE TRIGGER trg_sync_device_points_after_profile_mapping_change
AFTER INSERT OR UPDATE OF profile_id, logical_point_id OR DELETE
ON config.profile_field_mapping
FOR EACH ROW
EXECUTE FUNCTION config.sync_device_points_after_profile_mapping_change();


CREATE OR REPLACE FUNCTION config.sync_device_points_after_device_mapping_change()
RETURNS TRIGGER
LANGUAGE plpgsql
AS
$$
BEGIN
    IF TG_OP IN ('UPDATE', 'DELETE') THEN
        PERFORM config.sync_device_point_configuration(OLD.device_id, FALSE);
    END IF;

    IF TG_OP IN ('INSERT', 'UPDATE') THEN
        PERFORM config.sync_device_point_configuration(NEW.device_id, FALSE);
    END IF;

    IF TG_OP = 'DELETE' THEN
        RETURN OLD;
    END IF;

    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_sync_device_points_after_device_mapping_change
ON metadata.device_field_mapping;

CREATE TRIGGER trg_sync_device_points_after_device_mapping_change
AFTER INSERT OR UPDATE OF device_id, logical_point_id OR DELETE
ON metadata.device_field_mapping
FOR EACH ROW
EXECUTE FUNCTION config.sync_device_points_after_device_mapping_change();


DO
$$
DECLARE
    v_device_id UUID;
BEGIN
    FOR v_device_id IN
        SELECT id
        FROM metadata.devices
        WHERE profile_id IS NOT NULL

        UNION

        SELECT DISTINCT device_id
        FROM metadata.device_field_mapping
    LOOP
        PERFORM config.sync_device_point_configuration(v_device_id, FALSE);
    END LOOP;
END;
$$;


CREATE OR REPLACE VIEW telemetry.v_normalized_points AS
WITH resolved_devices AS
(
    SELECT
        r.received_at,
        COALESCE(r.source_timestamp, r.received_at) AS event_time,
        r.source_timestamp,
        r.mqtt_topic,
        r.device_uid,
        r.device_identifier,
        r.payload,
        d.id AS device_id,
        d.organization_id,
        d.gateway_id,
        g.site_id,
        d.profile_id
    FROM telemetry.v_rtdata r
    JOIN metadata.device_identifiers di
      ON di.identifier_type = 'MQTT_UID'
     AND lower(di.identifier_value) = lower(r.device_uid)
    JOIN metadata.devices d
      ON d.id = di.device_id
    LEFT JOIN metadata.gateways g
      ON g.id = d.gateway_id
    WHERE r.device_uid IS NOT NULL
),
profile_mappings AS
(
    SELECT
        rd.received_at,
        rd.event_time,
        rd.source_timestamp,
        rd.mqtt_topic,
        rd.organization_id,
        rd.site_id,
        rd.gateway_id,
        rd.device_id,
        rd.device_uid,
        rd.device_identifier,
        rd.payload,
        pfm.logical_point_id,
        lp.name AS logical_point,
        lp.data_type,
        pfm.raw_field_name,
        pfm.json_path,
        pfm.transform_expression,
        1 AS mapping_priority,
        'DEVICE_PROFILE'::TEXT AS mapping_source
    FROM resolved_devices rd
    JOIN config.profile_field_mapping pfm
      ON pfm.profile_id = rd.profile_id
    JOIN config.device_point_configuration dpc
      ON dpc.device_id = rd.device_id
     AND dpc.logical_point_id = pfm.logical_point_id
     AND dpc.is_enabled
    JOIN metadata.logical_points lp
      ON lp.id = pfm.logical_point_id
    WHERE rd.profile_id IS NOT NULL
),
device_mappings AS
(
    SELECT
        rd.received_at,
        rd.event_time,
        rd.source_timestamp,
        rd.mqtt_topic,
        rd.organization_id,
        rd.site_id,
        rd.gateway_id,
        rd.device_id,
        rd.device_uid,
        rd.device_identifier,
        rd.payload,
        dfm.logical_point_id,
        lp.name AS logical_point,
        lp.data_type,
        dfm.raw_field_name,
        NULL::TEXT AS json_path,
        NULL::TEXT AS transform_expression,
        2 AS mapping_priority,
        'DEVICE_OVERRIDE'::TEXT AS mapping_source
    FROM resolved_devices rd
    JOIN metadata.device_field_mapping dfm
      ON dfm.device_id = rd.device_id
    JOIN config.device_point_configuration dpc
      ON dpc.device_id = rd.device_id
     AND dpc.logical_point_id = dfm.logical_point_id
     AND dpc.is_enabled
    JOIN metadata.logical_points lp
      ON lp.id = dfm.logical_point_id
),
candidate_mappings AS
(
    SELECT * FROM profile_mappings
    UNION ALL
    SELECT * FROM device_mappings
),
preferred_mappings AS
(
    SELECT DISTINCT ON
    (
        received_at,
        device_id,
        logical_point_id
    )
        received_at,
        event_time,
        source_timestamp,
        mqtt_topic,
        organization_id,
        site_id,
        gateway_id,
        device_id,
        device_uid,
        device_identifier,
        payload,
        logical_point_id,
        logical_point,
        data_type,
        raw_field_name,
        json_path,
        transform_expression,
        mapping_priority,
        mapping_source
    FROM candidate_mappings
    ORDER BY
        received_at,
        device_id,
        logical_point_id,
        mapping_priority
),
extracted_values AS
(
    SELECT
        pm.*,
        CASE
            WHEN pm.json_path IS NULL
                THEN pm.payload ->> pm.raw_field_name
            ELSE
                jsonb_path_query_first
                (
                    pm.payload,
                    pm.json_path::jsonpath
                ) #>> '{}'
        END AS raw_value
    FROM preferred_mappings pm
)
SELECT
    received_at,
    event_time,
    source_timestamp,
    organization_id,
    site_id,
    gateway_id,
    device_id,
    device_uid,
    device_identifier,
    mqtt_topic,
    logical_point_id,
    logical_point,
    data_type,
    raw_field_name,
    raw_value,
    CASE
        WHEN raw_value IS NULL
            THEN NULL::NUMERIC
        WHEN raw_value ~
             '^[[:space:]]*[+-]?(([0-9]+([.][0-9]*)?)|([.][0-9]+))([eE][+-]?[0-9]+)?[[:space:]]*$'
            THEN btrim(raw_value)::NUMERIC
        ELSE NULL::NUMERIC
    END AS numeric_value,
    CASE
        WHEN raw_value IS NULL
            THEN 'MISSING'::TEXT
        WHEN data_type = 'numeric'
         AND raw_value !~
             '^[[:space:]]*[+-]?(([0-9]+([.][0-9]*)?)|([.][0-9]+))([eE][+-]?[0-9]+)?[[:space:]]*$'
            THEN 'INVALID_NUMERIC'::TEXT
        ELSE 'GOOD'::TEXT
    END AS quality_code,
    mapping_source,
    payload
FROM extracted_values;

COMMENT ON VIEW telemetry.v_normalized_points IS
'Canonical normalized telemetry view. Only logical points enabled in config.device_point_configuration participate in normalization.';


ALTER TABLE telemetry.raw_message_failures
    ADD COLUMN IF NOT EXISTS raw_element_count INTEGER,
    ADD COLUMN IF NOT EXISTS resolved_element_count INTEGER,
    ADD COLUMN IF NOT EXISTS unresolved_element_count INTEGER,
    ADD COLUMN IF NOT EXISTS profiled_element_count INTEGER,
    ADD COLUMN IF NOT EXISTS unprofiled_element_count INTEGER,
    ADD COLUMN IF NOT EXISTS enabled_point_count INTEGER,
    ADD COLUMN IF NOT EXISTS produced_point_count INTEGER,
    ADD COLUMN IF NOT EXISTS diagnostic_details JSONB NOT NULL DEFAULT '{}'::JSONB;

COMMENT ON COLUMN telemetry.raw_message_failures.diagnostic_details IS
'Structured processing diagnostics, including unresolved MQTT UIDs and message-level completeness counts.';


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

            COALESCE(actual_metrics.produced_point_count, 0)
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
                    e.ordinality::INTEGER AS element_number,
                    e.value ->> 'uid' AS device_uid,
                    e.value ->> 'did' AS device_identifier,
                    d.id AS device_id,
                    d.profile_id,
                    COALESCE(enabled.enabled_points, 0)
                        AS enabled_points

                FROM jsonb_array_elements
                (
                    CASE
                        WHEN jsonb_typeof(r.payload -> 'rtdata') = 'array'
                            THEN r.payload -> 'rtdata'
                        ELSE '[]'::JSONB
                    END
                )
                WITH ORDINALITY AS e(value, ordinality)

                LEFT JOIN LATERAL
                (
                    SELECT di.device_id
                    FROM metadata.device_identifiers di
                    WHERE di.identifier_type = 'MQTT_UID'
                      AND lower(di.identifier_value) =
                          lower(e.value ->> 'uid')
                    ORDER BY di.device_id
                    LIMIT 1
                ) AS identifier
                  ON TRUE

                LEFT JOIN metadata.devices d
                  ON d.id = identifier.device_id

                LEFT JOIN LATERAL
                (
                    SELECT
                        COUNT(*)::INTEGER AS enabled_points
                    FROM config.device_point_configuration dpc
                    WHERE dpc.device_id = d.id
                      AND dpc.is_enabled
                ) AS enabled
                  ON TRUE
            ) AS resolved
        ) AS element_metrics
          ON TRUE

        LEFT JOIN LATERAL
        (
            SELECT
                COUNT
                (
                    DISTINCT
                    (
                        np.device_id,
                        np.logical_point_id
                    )
                )::INTEGER AS produced_point_count
            FROM telemetry.v_normalized_points np
            WHERE np.received_at = r.received_at
              AND r.payload -> 'rtdata'
                  @> jsonb_build_array(np.payload)
        ) AS actual_metrics
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

COMMENT ON PROCEDURE telemetry.capture_raw_message_failures_incremental
(INTERVAL, INTERVAL) IS
'Captures malformed messages, unresolved rtdata elements, devices without profiles or enabled points, zero-output normalization, and partial normalization. NULL and zero values do not create message-level failures.';


DO
$$
BEGIN
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'ems_app') THEN
        GRANT SELECT, INSERT, UPDATE, DELETE
        ON config.device_point_configuration
        TO ems_app;
    END IF;

    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'ems_readonly') THEN
        GRANT SELECT
        ON config.device_point_configuration
        TO ems_readonly;
    END IF;
END;
$$;
