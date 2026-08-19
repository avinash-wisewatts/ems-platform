-- 015_asset_dashboard_v1_contract.sql
-- Canonical Grafana read contract for the production Asset Dashboard V1.
-- Keeps instantaneous electrical telemetry, interval demand, energy consumption,
-- explicit operating-state telemetry, device context and alarms semantically separate.

CREATE OR REPLACE VIEW analytics.v_grafana_asset_electrical_samples
WITH (security_barrier = TRUE)
AS
SELECT
    gom.grafana_org_id,
    em.organization_id,
    em.site_id,
    a.id AS asset_id,
    a.name AS asset_name,
    em.device_id,
    d.name AS device_name,
    em.bucket_start AS sample_time,
    em.source_timestamp,
    em.received_at,
    em.active_power_total_w / 1000.0 AS active_power_kw,
    em.reactive_power_total_var / 1000.0 AS reactive_power_kvar,
    em.apparent_power_total_va / 1000.0 AS apparent_power_kva,
    em.import_energy_total_wh / 1000.0 AS import_energy_register_kwh,
    em.export_energy_total_wh / 1000.0 AS export_energy_register_kwh,
    em.voltage_ln_avg_v,
    em.voltage_l1_v,
    em.voltage_l2_v,
    em.voltage_l3_v,
    em.voltage_ll_avg_v,
    em.voltage_l12_v,
    em.voltage_l23_v,
    em.voltage_l31_v,
    em.current_total_a,
    em.current_l1_a,
    em.current_l2_a,
    em.current_l3_a,
    em.neutral_current_a,
    em.power_factor_total,
    em.frequency_hz,
    em.current_thd_total_percent,
    em.current_thd_l1_percent,
    em.current_thd_l2_percent,
    em.current_thd_l3_percent,
    em.voltage_thd_l1_percent,
    em.voltage_thd_l2_percent,
    em.voltage_thd_l3_percent,
    em.quality_code,
    em.is_estimated
FROM metadata.grafana_organization_map gom
JOIN metadata.assets a
  ON a.organization_id = gom.organization_id
JOIN metadata.asset_devices ad
  ON ad.asset_id = a.id
 AND ad.relationship_type = 'PRIMARY_METER'
JOIN metadata.devices d
  ON d.id = ad.device_id
JOIN telemetry.energy_measurements em
  ON em.organization_id = a.organization_id
 AND em.site_id = a.site_id
 AND em.device_id = ad.device_id
WHERE gom.is_active = TRUE;

COMMENT ON VIEW analytics.v_grafana_asset_electrical_samples IS
'Grafana-safe electrical samples from the asset PRIMARY_METER. active_power_kw is instantaneous power and is never labelled demand.';

CREATE OR REPLACE VIEW analytics.v_grafana_asset_energy_intervals
WITH (security_barrier = TRUE)
AS
WITH unified AS (
    SELECT
        c.grafana_org_id,
        c.bucket_start,
        c.organization_id,
        c.site_id,
        c.device_id,
        c.import_consumption_kwh,
        c.export_consumption_kwh,
        c.import_quality_code,
        c.export_quality_code,
        c.reset_detected,
        c.gap_detected,
        '1min'::text AS resolution
    FROM analytics.v_energy_consumption_1min c

    UNION ALL

    SELECT
        c.grafana_org_id,
        c.bucket_start,
        c.organization_id,
        c.site_id,
        c.device_id,
        c.import_consumption_kwh,
        c.export_consumption_kwh,
        c.import_quality_code,
        c.export_quality_code,
        c.reset_detected,
        c.gap_detected,
        '5min'::text AS resolution
    FROM analytics.v_energy_consumption_5min c

    UNION ALL

    SELECT
        c.grafana_org_id,
        c.bucket_start,
        c.organization_id,
        c.site_id,
        c.device_id,
        c.import_consumption_kwh,
        c.export_consumption_kwh,
        c.import_quality_code,
        c.export_quality_code,
        c.reset_detected,
        c.gap_detected,
        '15min'::text AS resolution
    FROM analytics.v_energy_consumption_15min c
    CROSS JOIN LATERAL telemetry.resolve_site_capture_bucket(c.site_id, c.bucket_start) cp
    WHERE cp.policy_id IS NOT NULL
      AND cp.capture_interval_seconds > 300
)
SELECT
    u.grafana_org_id,
    u.organization_id,
    u.site_id,
    a.id AS asset_id,
    a.name AS asset_name,
    u.device_id,
    d.name AS device_name,
    u.bucket_start AS interval_start,
    u.resolution,
    u.import_consumption_kwh,
    u.export_consumption_kwh,
    u.import_quality_code,
    u.export_quality_code,
    u.reset_detected,
    u.gap_detected
FROM unified u
JOIN metadata.asset_devices ad
  ON ad.device_id = u.device_id
 AND ad.relationship_type = 'PRIMARY_METER'
JOIN metadata.assets a
  ON a.id = ad.asset_id
 AND a.organization_id = u.organization_id
 AND a.site_id = u.site_id
JOIN metadata.devices d
  ON d.id = u.device_id;

COMMENT ON VIEW analytics.v_grafana_asset_energy_intervals IS
'Grafana-safe asset energy consumption intervals across supported site capture resolutions. Uses only the asset PRIMARY_METER and preserves reset/gap quality.';

CREATE OR REPLACE VIEW analytics.v_grafana_asset_health_history
WITH (security_barrier = TRUE)
AS
SELECT
    gom.grafana_org_id,
    ah.organization_id,
    ah.site_id,
    ah.asset_id,
    a.name AS asset_name,
    ah.device_id,
    d.name AS device_name,
    ah.received_at AS sample_time,
    ah.source_timestamp,
    ah.running_status,
    ah.operating_state,
    ah.runtime_hours_total,
    ah.starts_count,
    ah.temperature_c,
    ah.winding_temperature_c,
    ah.bearing_temperature_c,
    ah.vibration_mm_s,
    ah.vibration_x_mm_s,
    ah.vibration_y_mm_s,
    ah.vibration_z_mm_s,
    ah.current_a,
    ah.power_kw,
    ah.alarm_active,
    ah.alarm_code,
    ah.fault_code,
    ah.quality_code,
    ah.is_estimated
FROM metadata.grafana_organization_map gom
JOIN telemetry.asset_health ah
  ON ah.organization_id = gom.organization_id
JOIN metadata.assets a
  ON a.id = ah.asset_id
LEFT JOIN metadata.devices d
  ON d.id = ah.device_id
WHERE gom.is_active = TRUE
  AND ah.asset_id IS NOT NULL;

COMMENT ON VIEW analytics.v_grafana_asset_health_history IS
'Grafana-safe explicit asset operating/condition telemetry. Operating state is shown only when actually supplied/routed; the view does not infer run/idle/off from arbitrary power thresholds.';

ALTER VIEW analytics.v_grafana_asset_electrical_samples OWNER TO ems_admin;
ALTER VIEW analytics.v_grafana_asset_energy_intervals OWNER TO ems_admin;
ALTER VIEW analytics.v_grafana_asset_health_history OWNER TO ems_admin;

REVOKE ALL ON analytics.v_grafana_asset_electrical_samples FROM PUBLIC;
REVOKE ALL ON analytics.v_grafana_asset_energy_intervals FROM PUBLIC;
REVOKE ALL ON analytics.v_grafana_asset_health_history FROM PUBLIC;

GRANT SELECT ON analytics.v_grafana_asset_electrical_samples TO ems_app, ems_readonly, grafana_reader;
GRANT SELECT ON analytics.v_grafana_asset_energy_intervals TO ems_app, ems_readonly, grafana_reader;
GRANT SELECT ON analytics.v_grafana_asset_health_history TO ems_app, ems_readonly, grafana_reader;
