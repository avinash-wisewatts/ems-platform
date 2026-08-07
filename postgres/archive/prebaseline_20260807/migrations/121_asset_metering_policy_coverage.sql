-- Stories 9.1-9.5: explicit metering policy and tenant-scoped coverage administration.

ALTER TABLE metadata.assets
    ALTER COLUMN metering_requirement DROP DEFAULT;

ALTER TABLE metadata.assets
    ALTER COLUMN metering_requirement SET NOT NULL;

ALTER TABLE metadata.assets
    DROP CONSTRAINT IF EXISTS assets_metering_requirement_ck;

ALTER TABLE metadata.assets
    ADD CONSTRAINT assets_metering_requirement_ck
    CHECK (
        metering_requirement IN (
            'DIRECT_METER_REQUIRED',
            'DESCENDANT_COVERAGE_ALLOWED',
            'NOT_REQUIRED'
        )
    );

COMMENT ON COLUMN metadata.assets.metering_requirement IS
'Explicit asset energy-meter policy. No default is permitted. DIRECT_METER_REQUIRED requires a qualifying PRIMARY_METER; DESCENDANT_COVERAGE_ALLOWED is evaluated only from active DIRECT_METER_REQUIRED descendants; NOT_REQUIRED is excluded from coverage KPIs.';

-- Reassert the coverage semantics after relationship lifecycle migration 120.
CREATE OR REPLACE VIEW analytics.v_asset_meter_coverage_configuration
WITH (security_barrier = TRUE)
AS
WITH qualifying_direct_meter AS (
    SELECT
        ad.asset_id,
        count(*) AS direct_primary_meter_count,
        min(ad.device_id::text)::uuid AS direct_primary_meter_device_id
    FROM metadata.asset_devices ad
    JOIN metadata.devices d ON d.id = ad.device_id
    JOIN metadata.device_models dm ON dm.id = d.device_model_id
    JOIN config.device_categories dc ON dc.id = dm.device_category_id
    JOIN config.asset_device_relationship_category_compatibility compatibility
      ON compatibility.relationship_type = ad.relationship_type
     AND compatibility.device_category_id = dc.id
    WHERE ad.relationship_type = 'PRIMARY_METER'
      AND lower(dc.name) = 'energy meter'
    GROUP BY ad.asset_id
),
required_descendants AS (
    SELECT
        hc.ancestor_asset_id AS asset_id,
        count(*) AS required_descendant_count,
        count(*) FILTER (WHERE meter.asset_id IS NOT NULL)
            AS configured_required_descendant_count,
        count(*) FILTER (WHERE meter.asset_id IS NULL)
            AS missing_required_descendant_count
    FROM analytics.v_asset_hierarchy_closure hc
    JOIN metadata.assets descendant
      ON descendant.id = hc.descendant_asset_id
     AND descendant.organization_id = hc.organization_id
     AND descendant.site_id = hc.site_id
    LEFT JOIN qualifying_direct_meter meter
      ON meter.asset_id = descendant.id
    WHERE hc.depth > 0
      AND descendant.status = 'active'
      AND descendant.metering_requirement = 'DIRECT_METER_REQUIRED'
    GROUP BY hc.ancestor_asset_id
)
SELECT
    asset.grafana_org_id,
    asset.organization_id,
    asset.site_id,
    asset.site_code,
    asset.site_name,
    asset.asset_id,
    asset.asset_name,
    asset.asset_type,
    asset.parent_asset_id,
    asset.parent_asset_name,
    asset.status AS asset_status,
    asset.metering_requirement,
    (
        asset.status = 'active'
        AND asset.metering_requirement <> 'NOT_REQUIRED'
    ) AS is_coverage_in_scope,
    COALESCE(dm.direct_primary_meter_count, 0) AS direct_primary_meter_count,
    dm.direct_primary_meter_device_id,
    COALESCE(rd.required_descendant_count, 0) AS required_descendant_count,
    COALESCE(rd.configured_required_descendant_count, 0)
        AS configured_required_descendant_count,
    COALESCE(rd.missing_required_descendant_count, 0)
        AS missing_required_descendant_count,
    CASE
        WHEN asset.status <> 'active' THEN 'OUT_OF_SCOPE_INACTIVE'
        WHEN asset.metering_requirement = 'NOT_REQUIRED' THEN 'EXCLUDED'
        WHEN asset.metering_requirement = 'DIRECT_METER_REQUIRED'
             AND COALESCE(dm.direct_primary_meter_count, 0) = 1
            THEN 'CONFIGURED'
        WHEN asset.metering_requirement = 'DIRECT_METER_REQUIRED'
            THEN 'MISSING_DIRECT_METER'
        WHEN asset.metering_requirement = 'DESCENDANT_COVERAGE_ALLOWED'
             AND COALESCE(rd.required_descendant_count, 0) = 0
            THEN 'NO_REQUIRED_DESCENDANTS'
        WHEN asset.metering_requirement = 'DESCENDANT_COVERAGE_ALLOWED'
             AND COALESCE(rd.missing_required_descendant_count, 0) = 0
            THEN 'CONFIGURED'
        WHEN asset.metering_requirement = 'DESCENDANT_COVERAGE_ALLOWED'
             AND COALESCE(rd.configured_required_descendant_count, 0) > 0
            THEN 'PARTIALLY_CONFIGURED'
        WHEN asset.metering_requirement = 'DESCENDANT_COVERAGE_ALLOWED'
            THEN 'MISSING_DESCENDANT_COVERAGE'
        ELSE 'UNKNOWN_POLICY'
    END AS coverage_status,
    CASE
        WHEN asset.status <> 'active'
             OR asset.metering_requirement = 'NOT_REQUIRED'
            THEN NULL
        WHEN asset.metering_requirement = 'DIRECT_METER_REQUIRED'
            THEN CASE
                WHEN COALESCE(dm.direct_primary_meter_count, 0) = 1 THEN 100.0
                ELSE 0.0
            END
        WHEN asset.metering_requirement = 'DESCENDANT_COVERAGE_ALLOWED'
             AND COALESCE(rd.required_descendant_count, 0) = 0
            THEN NULL
        WHEN asset.metering_requirement = 'DESCENDANT_COVERAGE_ALLOWED'
            THEN round(
                100.0 * COALESCE(rd.configured_required_descendant_count, 0)
                / NULLIF(rd.required_descendant_count, 0),
                2
            )
        ELSE NULL
    END AS configuration_coverage_percent
FROM analytics.v_assets asset
LEFT JOIN qualifying_direct_meter dm ON dm.asset_id = asset.asset_id
LEFT JOIN required_descendants rd ON rd.asset_id = asset.asset_id;

COMMENT ON VIEW analytics.v_asset_meter_coverage_configuration IS
'Tenant-safe configuration-only asset metering coverage. Direct readiness requires one qualifying PRIMARY_METER. Descendant coverage counts only active descendants explicitly marked DIRECT_METER_REQUIRED. NOT_REQUIRED assets remain visible but are excluded from KPI denominators.';

DROP FUNCTION IF EXISTS admin.list_accessible_asset_meter_coverage(BIGINT);

CREATE FUNCTION admin.list_accessible_asset_meter_coverage(
    p_actor_portal_user_id BIGINT
)
RETURNS TABLE (
    grafana_org_id BIGINT,
    organization_id UUID,
    site_id UUID,
    site_code TEXT,
    site_name TEXT,
    asset_id UUID,
    asset_name TEXT,
    asset_type TEXT,
    parent_asset_id UUID,
    parent_asset_name TEXT,
    asset_status TEXT,
    metering_requirement TEXT,
    is_coverage_in_scope BOOLEAN,
    direct_primary_meter_count BIGINT,
    direct_primary_meter_device_id UUID,
    required_descendant_count BIGINT,
    configured_required_descendant_count BIGINT,
    missing_required_descendant_count BIGINT,
    coverage_status TEXT,
    configuration_coverage_percent NUMERIC,
    action_path TEXT,
    action_label TEXT
)
LANGUAGE SQL
STABLE
SECURITY DEFINER
SET search_path TO pg_catalog, admin, metadata, analytics
AS $function$
SELECT
    coverage.grafana_org_id,
    coverage.organization_id,
    coverage.site_id,
    coverage.site_code,
    coverage.site_name,
    coverage.asset_id,
    coverage.asset_name,
    coverage.asset_type,
    coverage.parent_asset_id,
    coverage.parent_asset_name,
    coverage.asset_status,
    coverage.metering_requirement,
    coverage.is_coverage_in_scope,
    coverage.direct_primary_meter_count,
    coverage.direct_primary_meter_device_id,
    coverage.required_descendant_count,
    coverage.configured_required_descendant_count,
    coverage.missing_required_descendant_count,
    coverage.coverage_status,
    coverage.configuration_coverage_percent,
    CASE
        WHEN coverage.coverage_status = 'MISSING_DIRECT_METER'
            THEN '/administration/relationships'
        ELSE '/administration/assets'
    END AS action_path,
    CASE
        WHEN coverage.coverage_status = 'MISSING_DIRECT_METER'
            THEN 'Assign primary meter'
        WHEN coverage.coverage_status IN (
            'PARTIALLY_CONFIGURED',
            'MISSING_DESCENDANT_COVERAGE'
        ) THEN 'Review descendants'
        WHEN coverage.coverage_status = 'NO_REQUIRED_DESCENDANTS'
            THEN 'Review asset policy'
        ELSE 'Manage asset'
    END AS action_label
FROM analytics.v_asset_meter_coverage_configuration coverage
WHERE admin.portal_user_can_access_site(
    p_actor_portal_user_id,
    coverage.site_id
)
ORDER BY coverage.site_name, coverage.asset_name;
$function$;

ALTER FUNCTION admin.list_accessible_asset_meter_coverage(BIGINT)
    OWNER TO ems_admin;
REVOKE ALL ON FUNCTION admin.list_accessible_asset_meter_coverage(BIGINT)
    FROM PUBLIC;
GRANT EXECUTE ON FUNCTION admin.list_accessible_asset_meter_coverage(BIGINT)
    TO ems_app;
