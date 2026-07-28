-- ============================================================================
-- File:
--   37_telemetry_normalization_view.sql
--
-- Purpose:
--   Create the canonical telemetry normalization layer.
--
-- Architecture:
--
--   public.mqtt_staging
--          |
--          v
--   telemetry.v_rtdata
--          |
--          v
--   metadata.device_identifiers
--          |
--          v
--   device/profile field mappings
--          |
--          v
--   telemetry.v_normalized_points
--
-- Design principles:
--
--   1. Raw MQTT messages remain unchanged.
--   2. Vendor-specific field names are converted to logical points through
--      metadata rather than procedural application code.
--   3. Device-profile mappings take precedence over legacy per-device mappings.
--   4. Invalid numeric values are retained as raw text and marked with a
--      quality status instead of causing the complete query to fail.
--   5. Tenant and site identity are resolved before data reaches Grafana.
--
-- This is a view rather than a physical table. Domain-specific persistence,
-- deduplication and routing will be implemented in subsequent Step 45
-- migrations after this canonical representation is validated.
-- ============================================================================

CREATE OR REPLACE VIEW telemetry.v_normalized_points AS

WITH resolved_devices AS
(
    SELECT
        r.received_at,

        COALESCE(
            r.source_timestamp,
            r.received_at
        ) AS event_time,

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
     AND LOWER(di.identifier_value) = LOWER(r.device_uid)

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
        *

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
            -- json_path is reserved for future nested-profile mappings.
            -- Current Eniscope mappings use top-level JSON fields.
            WHEN pm.json_path IS NULL
                THEN pm.payload ->> pm.raw_field_name

            ELSE jsonb_path_query_first(
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
            THEN NULL

        WHEN raw_value ~
            '^[[:space:]]*[+-]?(([0-9]+([.][0-9]*)?)|([.][0-9]+))([eE][+-]?[0-9]+)?[[:space:]]*$'
            THEN TRIM(raw_value)::NUMERIC

        ELSE NULL
    END AS numeric_value,

    CASE
        WHEN raw_value IS NULL
            THEN 'MISSING'

        WHEN data_type = 'numeric'
         AND raw_value !~
            '^[[:space:]]*[+-]?(([0-9]+([.][0-9]*)?)|([.][0-9]+))([eE][+-]?[0-9]+)?[[:space:]]*$'
            THEN 'INVALID_NUMERIC'

        ELSE 'GOOD'
    END AS quality_code,

    mapping_source,
    payload

FROM extracted_values;
