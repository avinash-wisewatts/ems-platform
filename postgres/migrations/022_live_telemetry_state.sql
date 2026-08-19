BEGIN;

CREATE TABLE IF NOT EXISTS telemetry.device_live_point_state
(
    device_id UUID NOT NULL REFERENCES metadata.devices(id) ON DELETE CASCADE,
    logical_point_id UUID NOT NULL REFERENCES metadata.logical_points(id),
    organization_id UUID NOT NULL REFERENCES metadata.organizations(id),
    site_id UUID REFERENCES metadata.sites(id),
    gateway_id UUID REFERENCES metadata.gateways(id),
    event_time TIMESTAMPTZ NOT NULL,
    received_at TIMESTAMPTZ NOT NULL,
    numeric_value NUMERIC,
    text_value TEXT,
    quality_code TEXT NOT NULL,
    raw_field_name TEXT NOT NULL,
    mapping_source TEXT NOT NULL,
    source_topic TEXT,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    PRIMARY KEY (device_id, logical_point_id)
);

CREATE INDEX IF NOT EXISTS idx_device_live_point_state_org_site
ON telemetry.device_live_point_state (organization_id, site_id, device_id);

CREATE INDEX IF NOT EXISTS idx_device_live_point_state_received
ON telemetry.device_live_point_state (received_at DESC);

COMMENT ON TABLE telemetry.device_live_point_state IS
'Canonical latest-value cache for operational live telemetry. One row per device and logical point. It is not historical storage and must never replace normalized_points or domain measurement tables.';

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
        SELECT DISTINCT ON (device_id, logical_point_id)
            *
        FROM candidate_mappings
        ORDER BY device_id, logical_point_id, mapping_priority
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
            e.device_id,
            e.logical_point_id,
            e.organization_id,
            e.site_id,
            e.gateway_id,
            e.event_time,
            p_received_at,
            CASE
                WHEN e.raw_value ~ '^[[:space:]]*[+-]?(([0-9]+([.][0-9]*)?)|([.][0-9]+))([eE][+-]?[0-9]+)?[[:space:]]*$'
                THEN trim(e.raw_value)::NUMERIC
                ELSE NULL
            END,
            e.raw_value,
            CASE
                WHEN e.data_type = 'numeric'
                 AND e.raw_value !~ '^[[:space:]]*[+-]?(([0-9]+([.][0-9]*)?)|([.][0-9]+))([eE][+-]?[0-9]+)?[[:space:]]*$'
                THEN 'INVALID_NUMERIC'
                ELSE 'GOOD'
            END,
            e.raw_field_name,
            e.mapping_source,
            p_source_topic,
            clock_timestamp()
        FROM extracted e
        WHERE e.raw_value IS NOT NULL
        ON CONFLICT (device_id, logical_point_id) DO UPDATE
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
'Maps an incoming canonical rtdata MQTT payload through existing device/profile logical-point configuration into the latest-state cache. Older replayed source timestamps never overwrite newer live state.';

REVOKE ALL ON FUNCTION telemetry.ingest_live_rtdata(TEXT, JSONB, TIMESTAMPTZ) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION telemetry.ingest_live_rtdata(TEXT, JSONB, TIMESTAMPTZ) TO ems_app;


CREATE OR REPLACE FUNCTION admin.portal_user_can_access_asset(
    p_actor_portal_user_id BIGINT,
    p_asset_id UUID
)
RETURNS BOOLEAN
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, admin, metadata
AS $$
    SELECT EXISTS
    (
        SELECT 1
        FROM metadata.assets a
        WHERE a.id = p_asset_id
          AND admin.portal_user_can_access_site(p_actor_portal_user_id, a.site_id)
    );
$$;

REVOKE ALL ON FUNCTION admin.portal_user_can_access_asset(BIGINT, UUID) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION admin.portal_user_can_access_asset(BIGINT, UUID) TO ems_app;

CREATE OR REPLACE FUNCTION admin.list_live_asset_ids_for_device(
    p_device_id UUID
)
RETURNS TABLE(asset_id UUID)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, admin, metadata
AS $$
    SELECT DISTINCT ad.asset_id
    FROM metadata.asset_devices ad
    WHERE ad.device_id = p_device_id;
$$;

REVOKE ALL ON FUNCTION admin.list_live_asset_ids_for_device(UUID) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION admin.list_live_asset_ids_for_device(UUID) TO ems_app;

CREATE OR REPLACE FUNCTION admin.get_portal_asset_live_state(
    p_actor_portal_user_id BIGINT,
    p_asset_id UUID,
    p_at TIMESTAMPTZ DEFAULT clock_timestamp()
)
RETURNS TABLE
(
    asset_id UUID,
    asset_name TEXT,
    site_id UUID,
    device_id UUID,
    device_name TEXT,
    relationship_type TEXT,
    logical_point_id UUID,
    logical_point TEXT,
    unit_symbol TEXT,
    numeric_value NUMERIC,
    text_value TEXT,
    event_time TIMESTAMPTZ,
    received_at TIMESTAMPTZ,
    freshness_state TEXT,
    receipt_age_seconds DOUBLE PRECISION,
    source_age_seconds DOUBLE PRECISION,
    quality_code TEXT
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, admin, metadata, telemetry, config
AS $$
    WITH target AS
    (
        SELECT a.id, a.name, a.site_id
        FROM metadata.assets a
        WHERE a.id = p_asset_id
          AND admin.portal_user_can_access_site(p_actor_portal_user_id, a.site_id)
    ),
    policy AS
    (
        SELECT
            COALESCE(tap.receiving_threshold_seconds, 300) AS receiving_seconds,
            COALESCE(tap.stale_threshold_seconds, 900) AS delayed_seconds,
            COALESCE(tap.silent_threshold_seconds, 3600) AS offline_seconds
        FROM config.telemetry_availability_policy tap
        WHERE tap.policy_key = 'DEFAULT'
        LIMIT 1
    )
    SELECT
        t.id,
        t.name,
        t.site_id,
        d.id,
        d.name,
        ad.relationship_type,
        lp.id,
        lp.name,
        eu.symbol,
        s.numeric_value,
        s.text_value,
        s.event_time,
        s.received_at,
        CASE
            WHEN EXTRACT(EPOCH FROM (p_at - s.received_at)) > p.offline_seconds THEN 'OFFLINE'
            WHEN EXTRACT(EPOCH FROM (p_at - s.received_at)) > p.receiving_seconds THEN 'STALE'
            WHEN EXTRACT(EPOCH FROM (p_at - s.event_time)) > p.delayed_seconds THEN 'DELAYED'
            ELSE 'LIVE'
        END,
        GREATEST(0, EXTRACT(EPOCH FROM (p_at - s.received_at))),
        GREATEST(0, EXTRACT(EPOCH FROM (p_at - s.event_time))),
        s.quality_code
    FROM target t
    JOIN metadata.asset_devices ad ON ad.asset_id = t.id
    JOIN metadata.devices d ON d.id = ad.device_id
    JOIN telemetry.device_live_point_state s ON s.device_id = d.id
    JOIN metadata.logical_points lp ON lp.id = s.logical_point_id
    LEFT JOIN config.engineering_units eu ON eu.id = lp.unit_id
    CROSS JOIN policy p
    ORDER BY
        CASE WHEN ad.relationship_type = 'PRIMARY_METER' THEN 0 ELSE 1 END,
        d.name,
        lp.name;
$$;

REVOKE ALL ON FUNCTION admin.get_portal_asset_live_state(BIGINT, UUID, TIMESTAMPTZ) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION admin.get_portal_asset_live_state(BIGINT, UUID, TIMESTAMPTZ) TO ems_app;

CREATE OR REPLACE FUNCTION analytics.get_grafana_asset_live_state(
    p_grafana_org_id BIGINT,
    p_asset_id UUID,
    p_at TIMESTAMPTZ DEFAULT clock_timestamp()
)
RETURNS TABLE
(
    asset_id UUID,
    asset_name TEXT,
    site_id UUID,
    device_id UUID,
    device_name TEXT,
    relationship_type TEXT,
    logical_point_id UUID,
    logical_point TEXT,
    unit_symbol TEXT,
    numeric_value NUMERIC,
    text_value TEXT,
    event_time TIMESTAMPTZ,
    received_at TIMESTAMPTZ,
    freshness_state TEXT,
    receipt_age_seconds DOUBLE PRECISION,
    source_age_seconds DOUBLE PRECISION,
    quality_code TEXT
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, analytics, metadata, telemetry, config
AS $$
    WITH tenant AS
    (
        SELECT gom.organization_id
        FROM metadata.grafana_organization_map gom
        WHERE gom.grafana_org_id = p_grafana_org_id
          AND gom.is_active
    ),
    target AS
    (
        SELECT a.id, a.name, a.site_id
        FROM metadata.assets a
        JOIN tenant t ON t.organization_id = a.organization_id
        WHERE a.id = p_asset_id
    ),
    policy AS
    (
        SELECT
            COALESCE(tap.receiving_threshold_seconds, 300) AS receiving_seconds,
            COALESCE(tap.stale_threshold_seconds, 900) AS delayed_seconds,
            COALESCE(tap.silent_threshold_seconds, 3600) AS offline_seconds
        FROM config.telemetry_availability_policy tap
        WHERE tap.policy_key = 'DEFAULT'
        LIMIT 1
    )
    SELECT
        t.id,
        t.name,
        t.site_id,
        d.id,
        d.name,
        ad.relationship_type,
        lp.id,
        lp.name,
        eu.symbol,
        s.numeric_value,
        s.text_value,
        s.event_time,
        s.received_at,
        CASE
            WHEN EXTRACT(EPOCH FROM (p_at - s.received_at)) > p.offline_seconds THEN 'OFFLINE'
            WHEN EXTRACT(EPOCH FROM (p_at - s.received_at)) > p.receiving_seconds THEN 'STALE'
            WHEN EXTRACT(EPOCH FROM (p_at - s.event_time)) > p.delayed_seconds THEN 'DELAYED'
            ELSE 'LIVE'
        END,
        GREATEST(0, EXTRACT(EPOCH FROM (p_at - s.received_at))),
        GREATEST(0, EXTRACT(EPOCH FROM (p_at - s.event_time))),
        s.quality_code
    FROM target t
    JOIN metadata.asset_devices ad ON ad.asset_id = t.id
    JOIN metadata.devices d ON d.id = ad.device_id
    JOIN telemetry.device_live_point_state s ON s.device_id = d.id
    JOIN metadata.logical_points lp ON lp.id = s.logical_point_id
    LEFT JOIN config.engineering_units eu ON eu.id = lp.unit_id
    CROSS JOIN policy p
    ORDER BY
        CASE WHEN ad.relationship_type = 'PRIMARY_METER' THEN 0 ELSE 1 END,
        d.name,
        lp.name;
$$;

ALTER FUNCTION analytics.get_grafana_asset_live_state(BIGINT, UUID, TIMESTAMPTZ) OWNER TO ems_admin;
REVOKE ALL ON FUNCTION analytics.get_grafana_asset_live_state(BIGINT, UUID, TIMESTAMPTZ) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION analytics.get_grafana_asset_live_state(BIGINT, UUID, TIMESTAMPTZ) TO grafana_reader, ems_readonly, ems_app;

COMMIT;
