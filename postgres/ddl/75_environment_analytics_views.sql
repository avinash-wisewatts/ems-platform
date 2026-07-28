-- ============================================================================
-- File:
--   75_environment_analytics_views.sql
--
-- Purpose:
--   Create the tenant-safe environmental analytics contract used by Grafana.
--
-- Source objects:
--
--   telemetry.environment_measurements
--   telemetry.ca_environment_15min
--   telemetry.ca_environment_hourly
--
-- Tenant isolation:
--
--   Every view exposes grafana_org_id through:
--
--       metadata.grafana_organization_map
--
--   Every Grafana query must include:
--
--       WHERE grafana_org_id = ${__org.id}
--
-- Payload profile:
--
--   ENVIRONMENT_SENSOR_AIRSENSE_V1
--
-- The views remain generic at the measurement layer. Additional environmental
-- payload profiles can map into the same domain tables and analytics contract.
-- ============================================================================


-- ----------------------------------------------------------------------------
-- 1. Environment sensor selector.
--
-- Used by Grafana dashboard variables.
-- ----------------------------------------------------------------------------

CREATE OR REPLACE VIEW analytics.v_environment_sensor_selector
WITH
(
    security_barrier = TRUE
)
AS
SELECT
    gom.grafana_org_id,

    d.organization_id,
    g.site_id,
    d.gateway_id,
    d.id AS device_id,

    s.code AS site_code,
    s.name AS site_name,

    d.external_id,
    d.name AS device_name,
    d.serial_number,

    d.profile_id,
    dp.profile_code,
    dp.profile_name,
    dp.manufacturer,
    dp.model

FROM metadata.grafana_organization_map gom

JOIN metadata.devices d
  ON d.organization_id = gom.organization_id

JOIN metadata.gateways g
  ON g.id = d.gateway_id

JOIN metadata.sites s
  ON s.id = g.site_id

JOIN config.device_profiles dp
  ON dp.id = d.profile_id

WHERE gom.is_active = TRUE

  AND dp.profile_code LIKE
      'ENVIRONMENT_SENSOR_%';


COMMENT ON VIEW analytics.v_environment_sensor_selector IS
'Tenant-safe Grafana selector for devices assigned environmental payload profiles.';


-- ----------------------------------------------------------------------------
-- 2. Latest environmental measurement per device.
-- ----------------------------------------------------------------------------

CREATE OR REPLACE VIEW analytics.v_environment_latest
WITH
(
    security_barrier = TRUE
)
AS
SELECT DISTINCT ON
(
    gom.grafana_org_id,
    em.device_id
)
    gom.grafana_org_id,

    em.organization_id,
    em.site_id,
    em.gateway_id,
    em.device_id,
    em.asset_id,

    s.code AS site_code,
    s.name AS site_name,

    d.external_id,
    d.name AS device_name,
    d.serial_number,

    dp.profile_code,
    dp.profile_name,

    em.received_at,
    em.source_timestamp,

    em.temperature_c,
    em.humidity_percent,
    em.pressure_hpa,
    em.co2_ppm,
    em.voc_ppb,

    em.illuminance_lux,
    em.occupancy_activity,

    em.battery_voltage_v,
    em.signal_strength_dbm,

    em.measurement_interval_seconds,
    em.quality_code,
    em.is_estimated,

    EXTRACT
    (
        EPOCH FROM
        (
            now() - em.received_at
        )
    )::BIGINT AS data_age_seconds

FROM metadata.grafana_organization_map gom

JOIN telemetry.environment_measurements em
  ON em.organization_id = gom.organization_id

JOIN metadata.devices d
  ON d.id = em.device_id

LEFT JOIN metadata.sites s
  ON s.id = em.site_id

LEFT JOIN config.device_profiles dp
  ON dp.id = d.profile_id

WHERE gom.is_active = TRUE

ORDER BY
    gom.grafana_org_id,
    em.device_id,
    em.received_at DESC,
    em.id DESC;


COMMENT ON VIEW analytics.v_environment_latest IS
'Newest environmental measurement per tenant and device, enriched with site and payload-profile metadata.';


-- ----------------------------------------------------------------------------
-- 3. Tenant-safe 15-minute environmental aggregate.
-- ----------------------------------------------------------------------------

CREATE OR REPLACE VIEW analytics.v_environment_15min
WITH
(
    security_barrier = TRUE
)
AS
SELECT
    gom.grafana_org_id,

    ca.bucket_start,

    ca.organization_id,
    ca.site_id,
    ca.gateway_id,
    ca.device_id,
    ca.asset_id,

    s.code AS site_code,
    s.name AS site_name,

    d.external_id,
    d.name AS device_name,

    dp.profile_code,

    ca.sample_count,

    ca.temperature_c_avg,
    ca.temperature_c_min,
    ca.temperature_c_max,
    ca.temperature_sample_count,

    ca.humidity_percent_avg,
    ca.humidity_percent_min,
    ca.humidity_percent_max,
    ca.humidity_sample_count,

    ca.illuminance_lux_avg,
    ca.illuminance_lux_min,
    ca.illuminance_lux_max,
    ca.illuminance_sample_count,

    ca.occupancy_activity_avg,
    ca.occupancy_activity_min,
    ca.occupancy_activity_max,
    ca.occupancy_sample_count,

    ca.battery_voltage_v_avg,
    ca.battery_voltage_v_min,
    ca.battery_voltage_v_max,
    ca.battery_sample_count,

    ca.pressure_hpa_avg,
    ca.co2_ppm_avg,
    ca.voc_ppb_avg,
    ca.signal_strength_dbm_avg,

    ROUND
    (
        100.0
        *
        ca.temperature_sample_count
        /
        NULLIF(ca.sample_count, 0),
        2
    ) AS temperature_availability_percent,

    ROUND
    (
        100.0
        *
        ca.humidity_sample_count
        /
        NULLIF(ca.sample_count, 0),
        2
    ) AS humidity_availability_percent,

    ROUND
    (
        100.0
        *
        ca.illuminance_sample_count
        /
        NULLIF(ca.sample_count, 0),
        2
    ) AS illuminance_availability_percent,

    ROUND
    (
        100.0
        *
        ca.occupancy_sample_count
        /
        NULLIF(ca.sample_count, 0),
        2
    ) AS occupancy_availability_percent,

    ROUND
    (
        100.0
        *
        ca.battery_sample_count
        /
        NULLIF(ca.sample_count, 0),
        2
    ) AS battery_availability_percent

FROM metadata.grafana_organization_map gom

JOIN telemetry.ca_environment_15min ca
  ON ca.organization_id = gom.organization_id

JOIN metadata.devices d
  ON d.id = ca.device_id

LEFT JOIN metadata.sites s
  ON s.id = ca.site_id

LEFT JOIN config.device_profiles dp
  ON dp.id = d.profile_id

WHERE gom.is_active = TRUE;


COMMENT ON VIEW analytics.v_environment_15min IS
'Tenant-safe fifteen-minute environmental aggregate enriched with device, site, profile, and field-availability metadata.';


-- ----------------------------------------------------------------------------
-- 4. Tenant-safe hourly environmental aggregate.
-- ----------------------------------------------------------------------------

CREATE OR REPLACE VIEW analytics.v_environment_hourly
WITH
(
    security_barrier = TRUE
)
AS
SELECT
    gom.grafana_org_id,

    ca.bucket_start,

    ca.organization_id,
    ca.site_id,
    ca.gateway_id,
    ca.device_id,
    ca.asset_id,

    s.code AS site_code,
    s.name AS site_name,

    d.external_id,
    d.name AS device_name,

    dp.profile_code,

    ca.sample_count,

    ca.temperature_c_avg,
    ca.temperature_c_min,
    ca.temperature_c_max,
    ca.temperature_sample_count,

    ca.humidity_percent_avg,
    ca.humidity_percent_min,
    ca.humidity_percent_max,
    ca.humidity_sample_count,

    ca.illuminance_lux_avg,
    ca.illuminance_lux_min,
    ca.illuminance_lux_max,
    ca.illuminance_sample_count,

    ca.occupancy_activity_avg,
    ca.occupancy_activity_min,
    ca.occupancy_activity_max,
    ca.occupancy_sample_count,

    ca.battery_voltage_v_avg,
    ca.battery_voltage_v_min,
    ca.battery_voltage_v_max,
    ca.battery_sample_count,

    ca.pressure_hpa_avg,
    ca.pressure_hpa_min,
    ca.pressure_hpa_max,
    ca.pressure_sample_count,

    ca.co2_ppm_avg,
    ca.co2_ppm_min,
    ca.co2_ppm_max,
    ca.co2_sample_count,

    ca.voc_ppb_avg,
    ca.voc_ppb_min,
    ca.voc_ppb_max,
    ca.voc_sample_count,

    ca.signal_strength_dbm_avg,
    ca.signal_strength_dbm_min,
    ca.signal_strength_dbm_max,
    ca.signal_strength_sample_count,

    ROUND
    (
        100.0
        *
        ca.temperature_sample_count
        /
        NULLIF(ca.sample_count, 0),
        2
    ) AS temperature_availability_percent,

    ROUND
    (
        100.0
        *
        ca.humidity_sample_count
        /
        NULLIF(ca.sample_count, 0),
        2
    ) AS humidity_availability_percent,

    ROUND
    (
        100.0
        *
        ca.illuminance_sample_count
        /
        NULLIF(ca.sample_count, 0),
        2
    ) AS illuminance_availability_percent,

    ROUND
    (
        100.0
        *
        ca.occupancy_sample_count
        /
        NULLIF(ca.sample_count, 0),
        2
    ) AS occupancy_availability_percent,

    ROUND
    (
        100.0
        *
        ca.battery_sample_count
        /
        NULLIF(ca.sample_count, 0),
        2
    ) AS battery_availability_percent

FROM metadata.grafana_organization_map gom

JOIN telemetry.ca_environment_hourly ca
  ON ca.organization_id = gom.organization_id

JOIN metadata.devices d
  ON d.id = ca.device_id

LEFT JOIN metadata.sites s
  ON s.id = ca.site_id

LEFT JOIN config.device_profiles dp
  ON dp.id = d.profile_id

WHERE gom.is_active = TRUE;


COMMENT ON VIEW analytics.v_environment_hourly IS
'Tenant-safe hourly environmental aggregate enriched with device, site, profile, and field-availability metadata.';


-- ----------------------------------------------------------------------------
-- 5. Latest environment sensor KPI contract.
-- ----------------------------------------------------------------------------

CREATE OR REPLACE VIEW analytics.v_environment_sensor_kpis
WITH
(
    security_barrier = TRUE
)
AS
SELECT
    latest.grafana_org_id,

    latest.organization_id,
    latest.site_id,
    latest.gateway_id,
    latest.device_id,
    latest.asset_id,

    latest.site_code,
    latest.site_name,

    latest.external_id,
    latest.device_name,

    latest.profile_code,
    latest.profile_name,

    latest.received_at,
    latest.source_timestamp,
    latest.data_age_seconds,

    latest.temperature_c,
    latest.humidity_percent,
    latest.illuminance_lux,
    latest.occupancy_activity,
    latest.battery_voltage_v,

    latest.pressure_hpa,
    latest.co2_ppm,
    latest.voc_ppb,
    latest.signal_strength_dbm,

    CASE
        WHEN latest.received_at IS NULL
            THEN 'NO_DATA'

        WHEN latest.data_age_seconds <= 180
            THEN 'ONLINE'

        WHEN latest.data_age_seconds <= 600
            THEN 'STALE'

        ELSE 'OFFLINE'
    END AS sensor_status

FROM analytics.v_environment_latest latest;


COMMENT ON VIEW analytics.v_environment_sensor_kpis IS
'Latest environment sensor KPI and freshness contract for Grafana status and stat panels.';


-- ----------------------------------------------------------------------------
-- 6. Least-privilege access.
-- ----------------------------------------------------------------------------

REVOKE ALL ON
    analytics.v_environment_sensor_selector,
    analytics.v_environment_latest,
    analytics.v_environment_15min,
    analytics.v_environment_hourly,
    analytics.v_environment_sensor_kpis
FROM PUBLIC;


GRANT SELECT ON
    analytics.v_environment_sensor_selector,
    analytics.v_environment_latest,
    analytics.v_environment_15min,
    analytics.v_environment_hourly,
    analytics.v_environment_sensor_kpis
TO grafana_reader;
