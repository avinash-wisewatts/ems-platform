-- 014_asset_demand_grafana_contract.sql
-- Expose canonical ASSET demand state/history to Grafana without reverting to
-- instantaneous power masquerading as demand.

CREATE OR REPLACE VIEW analytics.v_grafana_asset_demand_state
WITH (security_barrier = TRUE)
AS
SELECT
    gom.grafana_org_id,
    a.organization_id,
    a.site_id,
    s.name AS site_name,
    a.id AS asset_id,
    a.name AS asset_name,
    cap.demand_policy_id,
    cap.demand_monitoring_enabled,
    cap.demand_interval_seconds,
    cap.demand_basis,
    CASE cap.demand_basis
        WHEN 'ACTIVE_POWER_KW' THEN 'kW'
        WHEN 'APPARENT_POWER_KVA' THEN 'kVA'
        ELSE NULL::TEXT
    END AS demand_unit,
    cap.source_device_id,
    cap.source_device_name,
    cap.source_profile_code,
    cap.selected_method,
    cap.capability_ready,
    cap.readiness_status,
    cap.source_logical_point_name,
    cap.fallback_logical_point_name,
    ds.interval_start,
    ds.interval_end,
    ds.current_demand_kw,
    ds.current_demand_kva,
    CASE cap.demand_basis
        WHEN 'ACTIVE_POWER_KW' THEN ds.current_demand_kw
        WHEN 'APPARENT_POWER_KVA' THEN ds.current_demand_kva
        ELSE NULL::DOUBLE PRECISION
    END AS demand_value,
    ds.expected_observations,
    ds.observed_observations,
    ds.coverage_percent,
    ds.quality_status,
    CASE
        WHEN cap.readiness_status <> 'READY' THEN cap.readiness_status
        ELSE COALESCE(ds.quality_status, 'NO_DATA')
    END AS display_status,
    ds.updated_at
FROM metadata.grafana_organization_map AS gom
JOIN metadata.assets AS a
  ON a.organization_id = gom.organization_id
JOIN metadata.sites AS s
  ON s.id = a.site_id
CROSS JOIN LATERAL analytics.resolve_demand_capability(
    a.site_id,
    'ASSET',
    a.id,
    statement_timestamp()
) AS cap
LEFT JOIN analytics.demand_state AS ds
  ON ds.site_id = a.site_id
 AND ds.scope_type = 'ASSET'
 AND ds.asset_id = a.id
 AND ds.demand_policy_id = cap.demand_policy_id
WHERE gom.is_active = TRUE;

COMMENT ON VIEW analytics.v_grafana_asset_demand_state IS
'Grafana-safe current ASSET demand state. Demand values come only from the canonical demand processor; readiness remains explicit when the selected meter cannot support the policy basis.';

CREATE OR REPLACE VIEW analytics.v_grafana_asset_demand_intervals
WITH (security_barrier = TRUE)
AS
SELECT
    gom.grafana_org_id,
    di.organization_id,
    di.site_id,
    s.name AS site_name,
    di.asset_id,
    a.name AS asset_name,
    di.demand_policy_id,
    p.demand_interval_seconds,
    p.demand_basis,
    CASE p.demand_basis
        WHEN 'ACTIVE_POWER_KW' THEN 'kW'
        WHEN 'APPARENT_POWER_KVA' THEN 'kVA'
        ELSE NULL::TEXT
    END AS demand_unit,
    di.source_device_id,
    d.name AS source_device_name,
    di.interval_start,
    di.interval_end,
    di.demand_kw,
    di.demand_kva,
    CASE p.demand_basis
        WHEN 'ACTIVE_POWER_KW' THEN di.demand_kw
        WHEN 'APPARENT_POWER_KVA' THEN di.demand_kva
        ELSE NULL::DOUBLE PRECISION
    END AS demand_value,
    di.peak_power_kw,
    di.energy_kwh,
    di.source_method,
    di.expected_observations,
    di.observed_observations,
    di.coverage_percent,
    di.quality_status,
    di.finalized_at
FROM metadata.grafana_organization_map AS gom
JOIN analytics.demand_intervals AS di
  ON di.organization_id = gom.organization_id
 AND di.scope_type = 'ASSET'
JOIN metadata.assets AS a
  ON a.id = di.asset_id
JOIN metadata.sites AS s
  ON s.id = di.site_id
JOIN config.site_demand_policies AS p
  ON p.id = di.demand_policy_id
LEFT JOIN metadata.devices AS d
  ON d.id = di.source_device_id
WHERE gom.is_active = TRUE;

COMMENT ON VIEW analytics.v_grafana_asset_demand_intervals IS
'Grafana-safe finalized ASSET demand intervals with a policy-basis demand_value and explicit unit/quality metadata.';

ALTER VIEW analytics.v_grafana_asset_demand_state OWNER TO ems_admin;
ALTER VIEW analytics.v_grafana_asset_demand_intervals OWNER TO ems_admin;

REVOKE ALL ON analytics.v_grafana_asset_demand_state FROM PUBLIC;
REVOKE ALL ON analytics.v_grafana_asset_demand_intervals FROM PUBLIC;

GRANT SELECT ON analytics.v_grafana_asset_demand_state TO ems_app, ems_readonly, grafana_reader;
GRANT SELECT ON analytics.v_grafana_asset_demand_intervals TO ems_app, ems_readonly, grafana_reader;
