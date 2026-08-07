-- Universal Grafana MVP analytics contract.
-- Every view exposes grafana_org_id and dashboards MUST filter on ${__org.id}.

CREATE OR REPLACE VIEW analytics.v_grafana_sites
WITH (security_barrier = TRUE)
AS
SELECT
    gom.grafana_org_id,
    o.id AS organization_id,
    o.code AS organization_code,
    o.name AS organization_name,
    o.timezone AS organization_timezone,
    s.id AS site_id,
    s.code AS site_code,
    s.name AS site_name,
    s.timezone AS site_timezone,
    s.sector_code,
    ss.display_name AS sector_name,
    s.lifecycle_status,
    s.is_active,
    s.address,
    (SELECT count(*) FROM metadata.assets a WHERE a.site_id=s.id) AS asset_count,
    (SELECT count(*) FROM metadata.gateways g WHERE g.site_id=s.id) AS gateway_count,
    (SELECT count(*) FROM metadata.devices d JOIN metadata.gateways g ON g.id=d.gateway_id WHERE g.site_id=s.id) AS device_count
FROM metadata.grafana_organization_map gom
JOIN metadata.organizations o ON o.id=gom.organization_id
JOIN metadata.sites s ON s.organization_id=o.id
LEFT JOIN config.site_sectors ss ON ss.code=s.sector_code
WHERE gom.is_active=TRUE;

CREATE OR REPLACE VIEW analytics.v_grafana_assets
WITH (security_barrier = TRUE)
AS
WITH RECURSIVE asset_tree AS (
    SELECT a.id, a.organization_id, a.site_id, a.parent_asset_id, a.id AS root_asset_id,
           0 AS depth, ARRAY[a.id] AS path_ids, ARRAY[a.name]::text[] AS path_names
    FROM metadata.assets a
    WHERE a.parent_asset_id IS NULL
    UNION ALL
    SELECT c.id, c.organization_id, c.site_id, c.parent_asset_id, t.root_asset_id,
           t.depth+1, t.path_ids||c.id, t.path_names||c.name
    FROM asset_tree t
    JOIN metadata.assets c ON c.parent_asset_id=t.id
      AND c.organization_id=t.organization_id AND c.site_id=t.site_id
    WHERE NOT c.id=ANY(t.path_ids)
), enriched AS (
    SELECT a.*, COALESCE(t.root_asset_id,a.id) AS root_asset_id,
           COALESCE(t.depth,0) AS hierarchy_depth,
           COALESCE(t.path_names,ARRAY[a.name]::text[]) AS hierarchy_names
    FROM metadata.assets a LEFT JOIN asset_tree t ON t.id=a.id
)
SELECT gom.grafana_org_id, e.organization_id, e.site_id, s.code AS site_code, s.name AS site_name,
       s.sector_code, e.id AS asset_id, e.parent_asset_id, p.name AS parent_asset_name,
       e.root_asset_id, e.hierarchy_depth,
       array_to_string(e.hierarchy_names,' / ') AS hierarchy_path,
       e.asset_type_id, at.name AS asset_type, e.name AS asset_name, e.external_id,
       e.manufacturer, e.model, e.serial_number, e.status, e.lifecycle_status,
       e.metering_requirement, e.metadata,
       (SELECT count(*) FROM metadata.assets c WHERE c.parent_asset_id=e.id) AS child_count,
       NOT EXISTS (SELECT 1 FROM metadata.assets c WHERE c.parent_asset_id=e.id) AS is_leaf,
       (SELECT count(*) FROM metadata.asset_devices ad WHERE ad.asset_id=e.id) AS assigned_device_count,
       e.created_at, e.updated_at
FROM metadata.grafana_organization_map gom
JOIN enriched e ON e.organization_id=gom.organization_id
JOIN metadata.sites s ON s.id=e.site_id
LEFT JOIN metadata.assets p ON p.id=e.parent_asset_id
LEFT JOIN metadata.asset_types at ON at.id=e.asset_type_id
WHERE gom.is_active=TRUE;

CREATE OR REPLACE VIEW analytics.v_grafana_devices
WITH (security_barrier = TRUE)
AS
WITH profile_mapping AS (
    SELECT
        profile_id,
        count(*)::BIGINT AS mapped_point_count,
        count(*) FILTER (WHERE is_required)::BIGINT
            AS required_point_count
    FROM config.profile_field_mapping
    GROUP BY profile_id
),
telemetry_rollup AS (
    SELECT
        np.device_id,
        max(np.event_time) AS latest_source_timestamp,
        max(np.created_at) AS latest_received_timestamp,
        max(np.event_time) FILTER (
            WHERE coalesce(np.quality_code, 'GOOD')
                    NOT IN (
                        'INVALID',
                        'REJECTED',
                        'INVALID_NUMERIC'
                    )
              AND (
                    np.numeric_value IS NOT NULL
                    OR nullif(btrim(np.raw_value), '') IS NOT NULL
              )
        ) AS latest_valid_source_timestamp,
        max(np.created_at) FILTER (
            WHERE coalesce(np.quality_code, 'GOOD')
                    NOT IN (
                        'INVALID',
                        'REJECTED',
                        'INVALID_NUMERIC'
                    )
              AND (
                    np.numeric_value IS NOT NULL
                    OR nullif(btrim(np.raw_value), '') IS NOT NULL
              )
        ) AS latest_valid_received_timestamp
    FROM telemetry.normalized_points np
    GROUP BY np.device_id
)
SELECT
    gom.grafana_org_id,
    d.organization_id,
    g.site_id,
    s.code AS site_code,
    s.name AS site_name,
    g.id AS gateway_id,
    g.name AS gateway_name,
    d.id AS device_id,
    d.name AS device_name,
    d.external_id,
    d.serial_number,
    d.firmware_version,
    d.protocol,
    d.lifecycle_status,
    dm.vendor,
    dm.model AS device_model,
    dc.name AS device_category,
    dp.profile_code,
    CASE
        WHEN d.profile_id IS NULL THEN 'INVALID_PROFILE'
        WHEN coalesce(pm.mapped_point_count, 0) = 0 THEN 'UNMAPPED'
        ELSE 'VALIDATED'
    END AS configuration_state,
    CASE
        WHEN tr.latest_received_timestamp IS NULL THEN 'NEVER_SEEN'
        WHEN tr.latest_received_timestamp
             < now() - interval '1 hour'
        THEN 'SILENT'
        WHEN d.profile_id IS NULL THEN 'INVALID_PROFILE'
        WHEN coalesce(pm.mapped_point_count, 0) = 0 THEN 'UNMAPPED'
        WHEN tr.latest_valid_source_timestamp IS NULL THEN 'RECEIVING'
        WHEN tr.latest_valid_source_timestamp
             < now() - interval '15 minutes'
        THEN 'STALE'
        WHEN tr.latest_valid_received_timestamp
             >= now() - interval '5 minutes'
        THEN 'VALIDATED'
        ELSE 'RECEIVING'
    END AS telemetry_state,
    tr.latest_source_timestamp,
    tr.latest_received_timestamp,
    tr.latest_valid_source_timestamp,
    tr.latest_valid_received_timestamp,
    coalesce(pm.mapped_point_count, 0)::BIGINT
        AS mapped_point_count,
    coalesce(pm.required_point_count, 0)::BIGINT
        AS required_point_count,
    300::INTEGER AS receiving_threshold_seconds,
    900::INTEGER AS stale_threshold_seconds,
    3600::INTEGER AS silent_threshold_seconds,
    EXTRACT(
        EPOCH FROM (
            now() - tr.latest_received_timestamp
        )
    )::BIGINT AS data_age_seconds
FROM metadata.grafana_organization_map gom
JOIN metadata.devices d
  ON d.organization_id = gom.organization_id
LEFT JOIN metadata.gateways g
  ON g.id = d.gateway_id
LEFT JOIN metadata.sites s
  ON s.id = g.site_id
LEFT JOIN metadata.device_models dm
  ON dm.id = d.device_model_id
LEFT JOIN config.device_categories dc
  ON dc.id = dm.device_category_id
LEFT JOIN config.device_profiles dp
  ON dp.id = d.profile_id
LEFT JOIN profile_mapping pm
  ON pm.profile_id = d.profile_id
LEFT JOIN telemetry_rollup tr
  ON tr.device_id = d.id
WHERE gom.is_active = TRUE;

CREATE OR REPLACE VIEW analytics.v_grafana_asset_devices
WITH (security_barrier = TRUE)
AS
SELECT
    gom.grafana_org_id,
    a.organization_id,
    a.site_id,
    s.name AS site_name,
    a.id AS asset_id,
    a.name AS asset_name,
    ad.device_id,
    d.name AS device_name,
    d.external_id AS device_external_id,
    ad.relationship_type,
    d.lifecycle_status AS device_lifecycle_status,
    gd.telemetry_state,
    gd.latest_received_timestamp
FROM metadata.grafana_organization_map gom
JOIN metadata.assets a
  ON a.organization_id = gom.organization_id
JOIN metadata.sites s
  ON s.id = a.site_id
JOIN metadata.asset_devices ad
  ON ad.asset_id = a.id
JOIN metadata.devices d
  ON d.id = ad.device_id
LEFT JOIN analytics.v_grafana_devices gd
  ON gd.grafana_org_id = gom.grafana_org_id
 AND gd.device_id = d.id
WHERE gom.is_active = TRUE;

CREATE OR REPLACE VIEW analytics.v_grafana_energy_samples
WITH (security_barrier = TRUE)
AS
SELECT gom.grafana_org_id, em.organization_id, em.site_id, em.gateway_id, em.device_id,
       COALESCE(em.asset_id, ad.asset_id) AS asset_id,
       em.received_at AS sample_time, em.source_timestamp,
       em.active_power_total_w/1000.0 AS active_power_kw,
       em.import_energy_total_wh/1000.0 AS import_energy_register_kwh,
       em.export_energy_total_wh/1000.0 AS export_energy_register_kwh,
       em.power_factor_total, em.frequency_hz,
       em.voltage_ln_avg_v, em.voltage_l1_v, em.voltage_l2_v, em.voltage_l3_v,
       em.current_total_a, em.quality_code, em.is_estimated
FROM metadata.grafana_organization_map gom
JOIN telemetry.energy_measurements em ON em.organization_id=gom.organization_id
LEFT JOIN LATERAL (
    SELECT ad.asset_id FROM metadata.asset_devices ad
    WHERE ad.device_id=em.device_id
    ORDER BY CASE ad.relationship_type WHEN 'PRIMARY_METER' THEN 0 ELSE 1 END, ad.created_at
    LIMIT 1
) ad ON TRUE
WHERE gom.is_active=TRUE;

CREATE OR REPLACE VIEW analytics.v_grafana_point_catalog
WITH (security_barrier = TRUE)
AS
SELECT DISTINCT gom.grafana_org_id, np.organization_id, np.site_id, np.device_id,
       d.name AS device_name, ad.asset_id, a.name AS asset_name,
       np.logical_point_id, COALESCE(lp.name,np.logical_point) AS logical_point,
       eu.symbol AS unit_symbol, lp.data_type,
       CASE
         WHEN upper(COALESCE(lp.name,np.logical_point,'')) LIKE '%ENERGY%TOTAL%' THEN 'delta'
         WHEN lp.data_type IN ('boolean','status') THEN 'last'
         ELSE 'avg'
       END AS recommended_aggregation
FROM metadata.grafana_organization_map gom
JOIN telemetry.normalized_points np ON np.organization_id=gom.organization_id
LEFT JOIN metadata.logical_points lp ON lp.id=np.logical_point_id
LEFT JOIN config.engineering_units eu ON eu.id=lp.unit_id
LEFT JOIN metadata.devices d ON d.id=np.device_id
LEFT JOIN metadata.asset_devices ad ON ad.device_id=np.device_id
LEFT JOIN metadata.assets a ON a.id=ad.asset_id
WHERE gom.is_active=TRUE;

CREATE OR REPLACE VIEW analytics.v_grafana_normalized_points
WITH (security_barrier = TRUE)
AS
SELECT gom.grafana_org_id, np.organization_id, np.site_id, np.gateway_id, np.device_id,
       ad.asset_id, np.event_time, np.logical_point_id,
       COALESCE(lp.name,np.logical_point) AS logical_point,
       eu.symbol AS unit_symbol, lp.data_type,
       np.numeric_value, np.raw_value, np.quality_code
FROM metadata.grafana_organization_map gom
JOIN telemetry.normalized_points np ON np.organization_id=gom.organization_id
LEFT JOIN metadata.logical_points lp ON lp.id=np.logical_point_id
LEFT JOIN config.engineering_units eu ON eu.id=lp.unit_id
LEFT JOIN LATERAL (
    SELECT asset_id FROM metadata.asset_devices ad WHERE ad.device_id=np.device_id
    ORDER BY CASE ad.relationship_type WHEN 'PRIMARY_METER' THEN 0 ELSE 1 END, ad.created_at LIMIT 1
) ad ON TRUE
WHERE gom.is_active=TRUE;

CREATE OR REPLACE VIEW analytics.v_grafana_active_alarms
WITH (security_barrier = TRUE)
AS
WITH latest_asset_health AS (
    SELECT DISTINCT ON (ah.asset_id) ah.*
    FROM telemetry.asset_health ah
    WHERE ah.asset_id IS NOT NULL
    ORDER BY ah.asset_id, ah.received_at DESC, ah.id DESC
), asset_alarms AS (
    SELECT gom.grafana_org_id, ah.organization_id, ah.site_id,
           'ASSET_ALARM:'||ah.asset_id::text AS alarm_key,
           'ASSET'::text AS entity_type, ah.asset_id AS entity_id, a.name AS entity_name,
           COALESCE(NULLIF(ah.alarm_code,''),NULLIF(ah.fault_code,''),'ASSET_ALARM') AS alarm_code,
           'HIGH'::text AS severity, 'ACTIVE'::text AS alarm_state,
           COALESCE(NULLIF(ah.operating_state,''),'Asset alarm signal is active') AS alarm_message,
           ah.received_at AS detected_at, ah.received_at AS last_observed_at,
           NULL::uuid AS device_id, ah.asset_id
    FROM latest_asset_health ah
    JOIN metadata.grafana_organization_map gom ON gom.organization_id=ah.organization_id AND gom.is_active
    LEFT JOIN metadata.assets a ON a.id=ah.asset_id
    WHERE ah.alarm_active IS TRUE OR NULLIF(ah.fault_code,'') IS NOT NULL
), telemetry_alarms AS (
    SELECT va.grafana_org_id, va.organization_id, va.site_id,
           'DEVICE_TELEMETRY:'||va.device_id::text AS alarm_key,
           'DEVICE'::text AS entity_type, va.device_id AS entity_id, va.device_name AS entity_name,
           va.telemetry_state AS alarm_code,
           CASE va.telemetry_state WHEN 'SILENT' THEN 'CRITICAL' WHEN 'NEVER_SEEN' THEN 'HIGH'
             WHEN 'INVALID_PROFILE' THEN 'HIGH' WHEN 'STALE' THEN 'MEDIUM' ELSE 'LOW' END AS severity,
           'ACTIVE'::text AS alarm_state,
           CASE va.telemetry_state
             WHEN 'SILENT' THEN 'No telemetry within the configured silent threshold.'
             WHEN 'NEVER_SEEN' THEN 'The device has never produced normalized telemetry.'
             WHEN 'INVALID_PROFILE' THEN 'The device profile or mapping is invalid.'
             WHEN 'STALE' THEN 'Telemetry is older than the configured stale threshold.'
             WHEN 'UNMAPPED' THEN 'The device is not correctly mapped or assigned.'
             ELSE 'Telemetry is not in the validated state.' END AS alarm_message,
           COALESCE(va.latest_received_timestamp,d.created_at) AS detected_at,
           va.latest_received_timestamp AS last_observed_at,
           va.device_id, NULL::uuid AS asset_id
    FROM analytics.v_grafana_devices va
    JOIN metadata.devices d ON d.id=va.device_id
    WHERE va.telemetry_state IN ('SILENT','NEVER_SEEN','INVALID_PROFILE','STALE','UNMAPPED')
)
SELECT * FROM asset_alarms
UNION ALL
SELECT * FROM telemetry_alarms;

COMMENT ON VIEW analytics.v_grafana_active_alarms IS
'MVP read-only active alarm feed from authoritative asset alarm signals and telemetry-availability conditions. It is not an acknowledgement or escalation history.';

GRANT USAGE ON SCHEMA analytics TO grafana_reader;
GRANT SELECT ON analytics.v_grafana_sites,
    analytics.v_grafana_assets,
    analytics.v_grafana_devices,
    analytics.v_grafana_asset_devices,
    analytics.v_grafana_energy_samples,
    analytics.v_grafana_point_catalog,
    analytics.v_grafana_normalized_points,
    analytics.v_grafana_active_alarms
TO grafana_reader;
