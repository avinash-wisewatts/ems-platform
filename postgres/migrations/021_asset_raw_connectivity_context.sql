BEGIN;

CREATE OR REPLACE FUNCTION analytics.get_grafana_asset_connectivity_context(
    p_grafana_org_id BIGINT,
    p_asset_id UUID,
    p_at TIMESTAMPTZ DEFAULT clock_timestamp()
)
RETURNS TABLE (
    asset_id UUID,
    asset_name TEXT,
    site_id UUID,
    source_device_id UUID,
    source_device_name TEXT,
    relationship_type TEXT,
    connectivity_state TEXT,
    latest_raw_received_timestamp TIMESTAMPTZ,
    latest_raw_source_timestamp TIMESTAMPTZ,
    receipt_age_seconds DOUBLE PRECISION,
    source_age_seconds DOUBLE PRECISION
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO pg_catalog, analytics, config, metadata, telemetry
AS $function$
DECLARE
    v_asset_name TEXT;
    v_site_id UUID;
    v_device_id UUID;
    v_device_name TEXT;
    v_relationship_type TEXT;
    v_latest_raw_received TIMESTAMPTZ;
    v_latest_raw_source TIMESTAMPTZ;
    v_receiving_seconds INTEGER := 300;
    v_source_delay_seconds INTEGER := 900;
    v_silent_seconds INTEGER := 3600;
    v_state TEXT;
BEGIN
    SELECT a.name, a.site_id
      INTO v_asset_name, v_site_id
    FROM metadata.grafana_organization_map AS gom
    JOIN metadata.assets AS a
      ON a.organization_id = gom.organization_id
    WHERE gom.grafana_org_id = p_grafana_org_id
      AND gom.is_active
      AND a.id = p_asset_id
    LIMIT 1;

    IF v_site_id IS NULL THEN
        RETURN;
    END IF;

    SELECT ad.device_id, d.name, ad.relationship_type
      INTO v_device_id, v_device_name, v_relationship_type
    FROM metadata.asset_devices AS ad
    JOIN metadata.devices AS d
      ON d.id = ad.device_id
    WHERE ad.asset_id = p_asset_id
    ORDER BY
        CASE WHEN ad.relationship_type = 'PRIMARY_METER' THEN 0 ELSE 1 END,
        ad.device_id
    LIMIT 1;

    IF v_device_id IS NULL THEN
        RETURN QUERY SELECT
            p_asset_id,
            v_asset_name,
            v_site_id,
            NULL::UUID,
            NULL::TEXT,
            NULL::TEXT,
            'NO_ASSIGNED_DEVICE'::TEXT,
            NULL::TIMESTAMPTZ,
            NULL::TIMESTAMPTZ,
            NULL::DOUBLE PRECISION,
            NULL::DOUBLE PRECISION;
        RETURN;
    END IF;

    SELECT
        COALESCE(p.receiving_threshold_seconds, v_receiving_seconds),
        COALESCE(p.stale_threshold_seconds, v_source_delay_seconds),
        COALESCE(p.silent_threshold_seconds, v_silent_seconds)
      INTO v_receiving_seconds, v_source_delay_seconds, v_silent_seconds
    FROM config.telemetry_availability_policy AS p
    WHERE p.policy_key = 'DEFAULT'
    LIMIT 1;

    SELECT
        rs.latest_raw_received_at,
        rs.latest_raw_source_timestamp
      INTO
        v_latest_raw_received,
        v_latest_raw_source
    FROM telemetry.device_raw_receipt_state AS rs
    WHERE rs.device_id = v_device_id;

    v_state := CASE
        WHEN v_latest_raw_received IS NULL THEN 'NEVER_SEEN'
        WHEN v_latest_raw_received < p_at - make_interval(secs => v_silent_seconds)
            THEN 'SILENT'
        WHEN v_latest_raw_received < p_at - make_interval(secs => v_receiving_seconds)
            THEN 'STALE'
        WHEN v_latest_raw_source IS NOT NULL
         AND v_latest_raw_source < p_at - make_interval(secs => v_source_delay_seconds)
            THEN 'DELAYED'
        ELSE 'RECEIVING'
    END;

    RETURN QUERY SELECT
        p_asset_id,
        v_asset_name,
        v_site_id,
        v_device_id,
        v_device_name,
        v_relationship_type,
        v_state,
        v_latest_raw_received,
        v_latest_raw_source,
        CASE
            WHEN v_latest_raw_received IS NULL THEN NULL::DOUBLE PRECISION
            ELSE extract(epoch FROM (p_at - v_latest_raw_received))::DOUBLE PRECISION
        END,
        CASE
            WHEN v_latest_raw_source IS NULL THEN NULL::DOUBLE PRECISION
            ELSE extract(epoch FROM (p_at - v_latest_raw_source))::DOUBLE PRECISION
        END;
END;
$function$;

COMMENT ON FUNCTION analytics.get_grafana_asset_connectivity_context(BIGINT,UUID,TIMESTAMPTZ) IS
'Tenant-safe live connectivity context for one asset. Uses raw receipt state so transport status is independent of intentionally delayed normalization. A fresh receipt with an old source timestamp is DELAYED rather than SILENT.';

ALTER FUNCTION analytics.get_grafana_asset_connectivity_context(BIGINT,UUID,TIMESTAMPTZ)
OWNER TO ems_admin;

REVOKE ALL ON FUNCTION analytics.get_grafana_asset_connectivity_context(BIGINT,UUID,TIMESTAMPTZ)
FROM PUBLIC;

GRANT EXECUTE ON FUNCTION analytics.get_grafana_asset_connectivity_context(BIGINT,UUID,TIMESTAMPTZ)
TO grafana_reader;

COMMIT;
