-- ============================================================================
-- File: 97_mqtt_staging_timestamptz.sql
--
-- Purpose:
--   Correct the MQTT landing timestamp contract from a naive UTC wall-clock
--   value to an absolute PostgreSQL TIMESTAMPTZ value.
--
-- Historical behavior:
--   Telegraf wrote UTC wall-clock timestamps into a
--   TIMESTAMP WITHOUT TIME ZONE column. When copied into a TIMESTAMPTZ
--   checkpoint under an Asia/Kolkata session, PostgreSQL interpreted those
--   values as local India time and shifted the absolute instant by 05:30.
--
-- Conversion rule:
--   Existing values represent UTC and must therefore be converted using:
--
--       received_at AT TIME ZONE 'UTC'
--
--   A direct received_at::timestamptz cast would be incorrect because it
--   would interpret the existing value using the database session timezone.
--
-- Safety:
--   * The normalization-loader advisory lock prevents concurrent checkpoint
--     movement during the conversion.
--   * Dependent views are dropped explicitly without CASCADE.
--   * The migration runner wraps this file and its ledger insert in one
--     transaction.
-- ============================================================================


-- Use the same lock identity as load_normalized_points_incremental().
SELECT pg_advisory_xact_lock(
    hashtextextended(
        'telemetry.load_normalized_points_incremental',
        0
    )
);


-- PostgreSQL cannot change the exposed type of a view column through
-- CREATE OR REPLACE VIEW, so direct dependent views are recreated explicitly.
DROP VIEW telemetry.v_energy_meter;
DROP VIEW telemetry.v_normalized_points;
DROP VIEW telemetry.v_rtdata;


-- Existing values are UTC wall-clock timestamps.
ALTER TABLE public.mqtt_staging
    ALTER COLUMN received_at
    TYPE TIMESTAMPTZ
    USING received_at AT TIME ZONE 'UTC';


COMMENT ON COLUMN public.mqtt_staging.received_at IS
'Absolute ingestion timestamp written by Telegraf when the MQTT metric is received.';
-- ============================================================================
-- File: 23_views.sql
-- Purpose: Canonical telemetry parsing views.
--
-- Architectural role:
--   public.mqtt_staging
--          |
--          v
--   telemetry.v_rtdata
--          |
--          v
--   telemetry.v_normalized_points
--
-- Design requirements:
--   - Raw MQTT landing data remains unchanged.
--   - One rtdata array element becomes one relational row.
--   - Missing or malformed JSON payloads must not break downstream queries.
--   - This file contains canonical view definitions, not migration history.
-- ============================================================================


-- ============================================================================
-- VIEW: telemetry.v_rtdata
-- ============================================================================
--
-- Expected Telegraf staging structure:
--
--   fields = {
--       "value": "{\"rtdata\":[...]} "
--   }
--
-- Output:
--   One row per element in the rtdata JSON array.
--
-- Invalid input handling:
--   - NULL payload strings are excluded.
--   - Invalid JSON strings are excluded using pg_input_is_valid().
--   - Payloads without an rtdata array are excluded.
-- ============================================================================

CREATE OR REPLACE VIEW telemetry.v_rtdata AS

WITH valid_messages AS
(
    SELECT
        received_at,
        tags,
        (fields ->> 'value')::JSONB AS payload_json

    FROM public.mqtt_staging

    WHERE
        fields ->> 'value' IS NOT NULL

        AND pg_input_is_valid(
            fields ->> 'value',
            'jsonb'
        )
),

messages_with_rtdata AS
(
    SELECT
        received_at,
        tags,
        payload_json

    FROM valid_messages

    WHERE jsonb_typeof(payload_json -> 'rtdata') = 'array'
)

SELECT
    m.received_at,

    m.tags ->> 'topic' AS mqtt_topic,

    r.value ->> 'uid' AS device_uid,

    r.value ->> 'did' AS device_identifier,

    CASE
        WHEN r.value ->> 'ts' IS NULL
            THEN NULL

        WHEN pg_input_is_valid(
            r.value ->> 'ts',
            'double precision'
        )
            THEN to_timestamp(
                (r.value ->> 'ts')::DOUBLE PRECISION
            )

        ELSE NULL
    END AS source_timestamp,

    r.value AS payload

FROM messages_with_rtdata m

CROSS JOIN LATERAL jsonb_array_elements(
    m.payload_json -> 'rtdata'
) AS r(value);

-- ============================================================================
-- VIEW: telemetry.v_energy_meter
-- ============================================================================
--
-- Compatibility contract:
--   This legacy parsing view is retained for existing engineering queries.
--   New production routing must use telemetry.v_normalized_points and the
--   domain-specific telemetry.energy_measurements table.
-- ============================================================================

CREATE OR REPLACE VIEW telemetry.v_energy_meter AS

SELECT
    received_at,

    to_timestamp(
        (payload ->> 'ts')::DOUBLE PRECISION
    ) AS event_time,

    payload ->> 'uid' AS device_uid,

    (payload ->> 'did')::INTEGER AS device_id,

    (payload ->> 'P')::DOUBLE PRECISION AS active_power_kw,
    (payload ->> 'Q')::DOUBLE PRECISION AS reactive_power_kvar,
    (payload ->> 'S')::DOUBLE PRECISION AS apparent_power_kva,
    (payload ->> 'PF')::DOUBLE PRECISION AS power_factor,
    (payload ->> 'E')::DOUBLE PRECISION AS import_energy_kwh,
    (payload ->> 'AE')::DOUBLE PRECISION AS export_energy_kwh,

    (payload ->> 'U1')::DOUBLE PRECISION AS voltage_l1,
    (payload ->> 'U2')::DOUBLE PRECISION AS voltage_l2,
    (payload ->> 'U3')::DOUBLE PRECISION AS voltage_l3,

    (payload ->> 'I1')::DOUBLE PRECISION AS current_l1,
    (payload ->> 'I2')::DOUBLE PRECISION AS current_l2,
    (payload ->> 'I3')::DOUBLE PRECISION AS current_l3,

    payload

FROM telemetry.v_rtdata

WHERE payload ? 'P';


COMMENT ON VIEW telemetry.v_energy_meter IS
'Legacy Eniscope energy parsing compatibility view. New integrations should use the normalized telemetry contract.';

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


-- Reset the normalization source checkpoint to the corrected absolute
-- timestamp. The loader overlap window will safely re-read recent rows, while
-- its unique business key prevents duplicate normalized points.
UPDATE telemetry.pipeline_state
SET
    last_received_at = (
        SELECT max(received_at)
        FROM public.mqtt_staging
    ),
    last_status = 'SUCCESS',
    last_error = NULL,
    updated_at = now()
WHERE pipeline_name = 'normalized_points';


-- Fail the migration if the resulting timestamp contract is not correct.
DO $migration_validation$
DECLARE
    v_staging_type TEXT;
    v_rtdata_type TEXT;
    v_normalized_type TEXT;
BEGIN
    SELECT data_type
    INTO v_staging_type
    FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name = 'mqtt_staging'
      AND column_name = 'received_at';

    SELECT data_type
    INTO v_rtdata_type
    FROM information_schema.columns
    WHERE table_schema = 'telemetry'
      AND table_name = 'v_rtdata'
      AND column_name = 'received_at';

    SELECT data_type
    INTO v_normalized_type
    FROM information_schema.columns
    WHERE table_schema = 'telemetry'
      AND table_name = 'v_normalized_points'
      AND column_name = 'received_at';

    IF v_staging_type <> 'timestamp with time zone' THEN
        RAISE EXCEPTION
            'Unexpected public.mqtt_staging.received_at type: %',
            v_staging_type;
    END IF;

    IF v_rtdata_type <> 'timestamp with time zone' THEN
        RAISE EXCEPTION
            'Unexpected telemetry.v_rtdata.received_at type: %',
            v_rtdata_type;
    END IF;

    IF v_normalized_type <> 'timestamp with time zone' THEN
        RAISE EXCEPTION
            'Unexpected telemetry.v_normalized_points.received_at type: %',
            v_normalized_type;
    END IF;
END;
$migration_validation$;
