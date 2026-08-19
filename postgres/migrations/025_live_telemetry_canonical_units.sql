BEGIN;

-- Live telemetry must expose values in the engineering unit declared by the
-- logical point. Mapping metadata therefore carries the source unit and the
-- affine conversion from source value to canonical logical-point value.
ALTER TABLE config.profile_field_mapping
    ADD COLUMN IF NOT EXISTS source_unit_symbol TEXT,
    ADD COLUMN IF NOT EXISTS scale_to_canonical_unit NUMERIC(20,9) NOT NULL DEFAULT 1,
    ADD COLUMN IF NOT EXISTS offset_to_canonical_unit NUMERIC(20,9) NOT NULL DEFAULT 0;

ALTER TABLE metadata.device_field_mapping
    ADD COLUMN IF NOT EXISTS source_unit_symbol TEXT,
    ADD COLUMN IF NOT EXISTS scale_to_canonical_unit NUMERIC(20,9) NOT NULL DEFAULT 1,
    ADD COLUMN IF NOT EXISTS offset_to_canonical_unit NUMERIC(20,9) NOT NULL DEFAULT 0;

COMMENT ON COLUMN config.profile_field_mapping.source_unit_symbol IS
'Source engineering unit emitted by this profile field. NULL means unspecified.';
COMMENT ON COLUMN config.profile_field_mapping.scale_to_canonical_unit IS
'Multiplier applied to a parsed numeric source value before storing live canonical state.';
COMMENT ON COLUMN config.profile_field_mapping.offset_to_canonical_unit IS
'Offset added after scale_to_canonical_unit when storing live canonical state.';
COMMENT ON COLUMN metadata.device_field_mapping.source_unit_symbol IS
'Source engineering unit for a device-specific field override. NULL means unspecified.';
COMMENT ON COLUMN metadata.device_field_mapping.scale_to_canonical_unit IS
'Multiplier applied to a parsed numeric device-override value before storing live canonical state.';
COMMENT ON COLUMN metadata.device_field_mapping.offset_to_canonical_unit IS
'Offset added after scale_to_canonical_unit for a device-specific field override.';

-- Eniscope V1 emits W/Wh/VA/VAh/var/varh while the mapped logical points are
-- expressed as kW/kWh/kVA/kVAh/kvar/kvarh. Keep the conversion in metadata,
-- never in Grafana or client code.
UPDATE config.profile_field_mapping pfm
SET source_unit_symbol = CASE eu.symbol
        WHEN 'kW'    THEN 'W'
        WHEN 'kWh'   THEN 'Wh'
        WHEN 'kVA'   THEN 'VA'
        WHEN 'kVAh'  THEN 'VAh'
        WHEN 'kvar'  THEN 'var'
        WHEN 'kvarh' THEN 'varh'
        ELSE pfm.source_unit_symbol
    END,
    scale_to_canonical_unit = CASE
        WHEN eu.symbol IN ('kW','kWh','kVA','kVAh','kvar','kvarh') THEN 0.001
        ELSE 1
    END,
    offset_to_canonical_unit = 0
FROM config.device_profiles dp
JOIN metadata.logical_points lp ON TRUE
JOIN config.engineering_units eu ON eu.id = lp.unit_id
WHERE pfm.profile_id = dp.id
  AND pfm.logical_point_id = lp.id
  AND dp.profile_code = 'ENERGY_METER_ENISCOPE_V1'
  AND eu.symbol IN ('kW','kWh','kVA','kVAh','kvar','kvarh');

CREATE OR REPLACE FUNCTION telemetry.ingest_live_rtdata(
    p_source_topic TEXT,
    p_payload JSONB,
    p_received_at TIMESTAMPTZ DEFAULT clock_timestamp()
)
RETURNS TABLE(device_id UUID)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, telemetry, metadata, config
AS $$
DECLARE
    v_device_ids UUID[] := ARRAY[]::UUID[];
    v_device_id UUID;
BEGIN
    IF p_payload IS NULL OR jsonb_typeof(p_payload -> 'rtdata') <> 'array' THEN
        RETURN;
    END IF;

    WITH source_elements AS MATERIALIZED
    (
        SELECT
            elem.value AS payload,
            elem.value ->> 'uid' AS device_uid,
            CASE
                WHEN pg_input_is_valid(elem.value ->> 'ts', 'double precision')
                THEN to_timestamp((elem.value ->> 'ts')::DOUBLE PRECISION)
                ELSE p_received_at
            END AS event_time
        FROM jsonb_array_elements(p_payload -> 'rtdata') AS elem(value)
        WHERE NULLIF(elem.value ->> 'uid', '') IS NOT NULL
    ),
    resolved_devices AS MATERIALIZED
    (
        SELECT
            se.payload,
            se.event_time,
            d.id AS device_id,
            d.organization_id,
            g.site_id,
            d.gateway_id,
            d.profile_id
        FROM source_elements se
        JOIN metadata.device_identifiers di
          ON di.identifier_type = 'MQTT_UID'
         AND lower(di.identifier_value) = lower(se.device_uid)
        JOIN metadata.devices d ON d.id = di.device_id
        LEFT JOIN metadata.gateways g ON g.id = d.gateway_id
    ),
    profile_mappings AS MATERIALIZED
    (
        SELECT
            rd.*,
            pfm.logical_point_id,
            lp.data_type,
            pfm.raw_field_name,
            pfm.json_path,
            pfm.source_unit_symbol,
            pfm.scale_to_canonical_unit,
            pfm.offset_to_canonical_unit,
            1 AS mapping_priority,
            'DEVICE_PROFILE'::TEXT AS mapping_source
        FROM resolved_devices rd
        JOIN config.profile_field_mapping pfm ON pfm.profile_id = rd.profile_id
        JOIN config.device_point_configuration dpc
          ON dpc.device_id = rd.device_id
         AND dpc.logical_point_id = pfm.logical_point_id
         AND dpc.is_enabled
        JOIN metadata.logical_points lp ON lp.id = pfm.logical_point_id
        WHERE rd.profile_id IS NOT NULL
    ),
    device_mappings AS MATERIALIZED
    (
        SELECT
            rd.*,
            dfm.logical_point_id,
            lp.data_type,
            dfm.raw_field_name,
            NULL::TEXT AS json_path,
            dfm.source_unit_symbol,
            dfm.scale_to_canonical_unit,
            dfm.offset_to_canonical_unit,
            2 AS mapping_priority,
            'DEVICE_OVERRIDE'::TEXT AS mapping_source
        FROM resolved_devices rd
        JOIN metadata.device_field_mapping dfm ON dfm.device_id = rd.device_id
        JOIN config.device_point_configuration dpc
          ON dpc.device_id = rd.device_id
         AND dpc.logical_point_id = dfm.logical_point_id
         AND dpc.is_enabled
        JOIN metadata.logical_points lp ON lp.id = dfm.logical_point_id
    ),
    candidate_mappings AS MATERIALIZED
    (
        SELECT * FROM profile_mappings
        UNION ALL
        SELECT * FROM device_mappings
    ),
    preferred_mappings AS MATERIALIZED
    (
        SELECT DISTINCT ON (cm.device_id, cm.logical_point_id)
            cm.*
        FROM candidate_mappings cm
        ORDER BY cm.device_id, cm.logical_point_id, cm.mapping_priority
    ),
    extracted AS MATERIALIZED
    (
        SELECT
            pm.*,
            CASE
                WHEN pm.json_path IS NULL THEN pm.payload ->> pm.raw_field_name
                ELSE jsonb_path_query_first(pm.payload, pm.json_path::jsonpath) #>> '{}'
            END AS raw_value
        FROM preferred_mappings pm
    ),
    canonicalized AS MATERIALIZED
    (
        SELECT
            e.*,
            CASE
                WHEN e.raw_value ~ '^[[:space:]]*[+-]?(([0-9]+([.][0-9]*)?)|([.][0-9]+))([eE][+-]?[0-9]+)?[[:space:]]*$'
                THEN (trim(e.raw_value)::NUMERIC * e.scale_to_canonical_unit)
                     + e.offset_to_canonical_unit
                ELSE NULL
            END AS canonical_numeric_value
        FROM extracted e
    ),
    upserted AS
    (
        INSERT INTO telemetry.device_live_point_state
        (
            device_id,
            logical_point_id,
            organization_id,
            site_id,
            gateway_id,
            event_time,
            received_at,
            numeric_value,
            text_value,
            quality_code,
            raw_field_name,
            mapping_source,
            source_topic,
            updated_at
        )
        SELECT
            c.device_id,
            c.logical_point_id,
            c.organization_id,
            c.site_id,
            c.gateway_id,
            c.event_time,
            p_received_at,
            c.canonical_numeric_value,
            CASE
                WHEN c.canonical_numeric_value IS NOT NULL
                THEN c.canonical_numeric_value::TEXT
                ELSE c.raw_value
            END,
            CASE
                WHEN c.data_type = 'numeric'
                 AND c.raw_value !~ '^[[:space:]]*[+-]?(([0-9]+([.][0-9]*)?)|([.][0-9]+))([eE][+-]?[0-9]+)?[[:space:]]*$'
                THEN 'INVALID_NUMERIC'
                ELSE 'GOOD'
            END,
            c.raw_field_name,
            c.mapping_source,
            p_source_topic,
            clock_timestamp()
        FROM canonicalized c
        WHERE c.raw_value IS NOT NULL
        ON CONFLICT ON CONSTRAINT device_live_point_state_pkey DO UPDATE
        SET organization_id = EXCLUDED.organization_id,
            site_id = EXCLUDED.site_id,
            gateway_id = EXCLUDED.gateway_id,
            event_time = EXCLUDED.event_time,
            received_at = EXCLUDED.received_at,
            numeric_value = EXCLUDED.numeric_value,
            text_value = EXCLUDED.text_value,
            quality_code = EXCLUDED.quality_code,
            raw_field_name = EXCLUDED.raw_field_name,
            mapping_source = EXCLUDED.mapping_source,
            source_topic = EXCLUDED.source_topic,
            updated_at = clock_timestamp()
        WHERE EXCLUDED.event_time > telemetry.device_live_point_state.event_time
           OR (
                EXCLUDED.event_time = telemetry.device_live_point_state.event_time
            AND EXCLUDED.received_at >= telemetry.device_live_point_state.received_at
           )
        RETURNING telemetry.device_live_point_state.device_id
    )
    SELECT array_agg(DISTINCT u.device_id)
    INTO v_device_ids
    FROM upserted u;

    IF v_device_ids IS NULL THEN
        RETURN;
    END IF;

    FOREACH v_device_id IN ARRAY v_device_ids LOOP
        PERFORM pg_notify('ems_live_device_update', v_device_id::TEXT);
    END LOOP;

    RETURN QUERY
    SELECT u.device_id
    FROM unnest(v_device_ids) AS u(device_id);
END;
$$;

COMMENT ON FUNCTION telemetry.ingest_live_rtdata(TEXT, JSONB, TIMESTAMPTZ) IS
'Maps incoming rtdata through device/profile logical-point configuration and source-to-canonical engineering-unit conversion into the latest-state cache. Older replayed source timestamps never overwrite newer live state.';

REVOKE ALL ON FUNCTION telemetry.ingest_live_rtdata(TEXT, JSONB, TIMESTAMPTZ) FROM PUBLIC;
GRANT USAGE ON SCHEMA telemetry TO ems_app;
GRANT EXECUTE ON FUNCTION telemetry.ingest_live_rtdata(TEXT, JSONB, TIMESTAMPTZ) TO ems_app;

COMMIT;
