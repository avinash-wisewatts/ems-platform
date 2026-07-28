-- ============================================================================
-- File:
--   62_asset_centric_analytics.sql
--
-- Purpose:
--   Provide a clean asset-centric analytics contract for Grafana.
--
-- Operator-facing model:
--
--   Site
--     -> Parent Asset
--       -> Operational Asset
--         -> Primary Meter
--           -> Energy / Demand / Consumption
--
-- Grafana variables:
--
--   site
--   parent_asset
--   asset
--
-- Tenant isolation:
--
--   Every view includes grafana_org_id.
--
--   Every Grafana query must filter:
--
--       WHERE grafana_org_id = ${__org.id}
--
-- Design:
--
--   Device IDs remain available for traceability, but operator-facing labels
--   use asset names such as:
--
--       Chiller 1
--       Primary Pump 1
--       Secondary Pump 1
-- ============================================================================


-- ----------------------------------------------------------------------------
-- 1. Asset selector.
--
-- Returns only assets with an active PRIMARY_METER relationship.
-- ----------------------------------------------------------------------------

CREATE OR REPLACE VIEW analytics.v_asset_selector
WITH
(
    security_barrier = TRUE
)
AS
SELECT
    ad.grafana_org_id,

    ad.organization_id,
    ad.site_id,

    ad.site_code,
    ad.site_name,

    ad.parent_asset_id,
    ad.parent_asset_name,

    ad.asset_id,
    ad.asset_name,
    ad.asset_type,

    ad.device_id,
    ad.external_id,
    ad.device_name,

    ad.relationship_type

FROM analytics.v_asset_devices ad

WHERE ad.relationship_type = 'PRIMARY_METER';


COMMENT ON VIEW analytics.v_asset_selector IS
'Grafana selector for operational assets that have a primary energy meter.';


-- ----------------------------------------------------------------------------
-- 2. Asset-aware hourly load profile.
-- ----------------------------------------------------------------------------

CREATE OR REPLACE VIEW analytics.v_asset_load_profile_hourly
WITH
(
    security_barrier = TRUE
)
AS
SELECT
    hp.grafana_org_id,

    hp.organization_id,
    hp.site_id,

    ad.asset_id,
    ad.asset_name,
    ad.asset_type,

    ad.parent_asset_id,
    ad.parent_asset_name,

    hp.device_id,
    hp.external_id,
    hp.device_name,

    hp.bucket_start,

    hp.demand_kw_avg,
    hp.demand_kw_min,
    hp.demand_kw_max,

    hp.power_factor_total_avg,
    hp.frequency_hz_avg,

    hp.sample_count,
    hp.active_power_sample_count,
    hp.power_data_availability_percent

FROM analytics.v_energy_load_profile_hourly hp

JOIN analytics.v_asset_devices ad
  ON ad.grafana_org_id = hp.grafana_org_id
 AND ad.device_id = hp.device_id
 AND ad.relationship_type = 'PRIMARY_METER';


COMMENT ON VIEW analytics.v_asset_load_profile_hourly IS
'Hourly load profile enriched with operational asset hierarchy.';


-- ----------------------------------------------------------------------------
-- 3. Asset-aware hour-of-day profile.
-- ----------------------------------------------------------------------------

CREATE OR REPLACE VIEW analytics.v_asset_load_profile_hour_of_day
WITH
(
    security_barrier = TRUE
)
AS
SELECT
    hod.grafana_org_id,

    hod.organization_id,
    hod.site_id,

    ad.asset_id,
    ad.asset_name,
    ad.asset_type,

    ad.parent_asset_id,
    ad.parent_asset_name,

    hod.device_id,
    hod.external_id,
    hod.device_name,

    hod.hour_of_day,

    hod.average_demand_kw,
    hod.minimum_demand_kw,
    hod.maximum_demand_kw,

    hod.hourly_bucket_count,
    hod.average_data_availability_percent

FROM analytics.v_energy_load_profile_hour_of_day hod

JOIN analytics.v_asset_devices ad
  ON ad.grafana_org_id = hod.grafana_org_id
 AND ad.device_id = hod.device_id
 AND ad.relationship_type = 'PRIMARY_METER';


COMMENT ON VIEW analytics.v_asset_load_profile_hour_of_day IS
'Recurring hour-of-day demand profile enriched with operational asset hierarchy.';


-- ----------------------------------------------------------------------------
-- 4. Asset-aware daily consumption.
-- ----------------------------------------------------------------------------

CREATE OR REPLACE VIEW analytics.v_asset_consumption_daily
WITH
(
    security_barrier = TRUE
)
AS
SELECT
    c.grafana_org_id,

    c.organization_id,
    c.site_id,

    ad.asset_id,
    ad.asset_name,
    ad.asset_type,

    ad.parent_asset_id,
    ad.parent_asset_name,

    c.device_id,
    c.external_id,
    c.device_name,

    c.consumption_date,

    c.import_consumption_kwh,
    c.export_consumption_kwh,

    c.valid_import_intervals,
    c.valid_export_intervals,

    c.reset_interval_count,
    c.gap_interval_count,

    c.first_bucket_start,
    c.last_bucket_start

FROM analytics.v_energy_consumption_daily c

JOIN analytics.v_asset_devices ad
  ON ad.grafana_org_id = c.grafana_org_id
 AND ad.device_id = c.device_id
 AND ad.relationship_type = 'PRIMARY_METER';


COMMENT ON VIEW analytics.v_asset_consumption_daily IS
'Daily consumption enriched with operational asset hierarchy.';


-- ----------------------------------------------------------------------------
-- 5. Asset-aware monthly consumption.
-- ----------------------------------------------------------------------------

CREATE OR REPLACE VIEW analytics.v_asset_consumption_monthly
WITH
(
    security_barrier = TRUE
)
AS
SELECT
    c.grafana_org_id,

    c.organization_id,
    c.site_id,

    ad.asset_id,
    ad.asset_name,
    ad.asset_type,

    ad.parent_asset_id,
    ad.parent_asset_name,

    c.device_id,
    c.external_id,
    c.device_name,

    c.consumption_month,

    c.import_consumption_kwh,
    c.export_consumption_kwh,

    c.valid_import_intervals,
    c.valid_export_intervals,

    c.reset_interval_count,
    c.gap_interval_count,

    c.first_bucket_start,
    c.last_bucket_start

FROM analytics.v_energy_consumption_monthly c

JOIN analytics.v_asset_devices ad
  ON ad.grafana_org_id = c.grafana_org_id
 AND ad.device_id = c.device_id
 AND ad.relationship_type = 'PRIMARY_METER';


COMMENT ON VIEW analytics.v_asset_consumption_monthly IS
'Monthly consumption enriched with operational asset hierarchy.';


-- ----------------------------------------------------------------------------
-- 6. Asset-aware daily peak demand.
-- ----------------------------------------------------------------------------

CREATE OR REPLACE VIEW analytics.v_asset_peak_demand_daily
WITH
(
    security_barrier = TRUE
)
AS
SELECT
    p.grafana_org_id,

    p.organization_id,
    p.site_id,

    ad.asset_id,
    ad.asset_name,
    ad.asset_type,

    ad.parent_asset_id,
    ad.parent_asset_name,

    p.device_id,
    p.external_id,
    p.device_name,

    p.demand_date,

    p.peak_bucket_start,
    p.peak_demand_kw,
    p.peak_observed_power_kw,

    p.sample_count,
    p.power_data_availability_percent

FROM analytics.v_energy_peak_demand_daily p

JOIN analytics.v_asset_devices ad
  ON ad.grafana_org_id = p.grafana_org_id
 AND ad.device_id = p.device_id
 AND ad.relationship_type = 'PRIMARY_METER';


COMMENT ON VIEW analytics.v_asset_peak_demand_daily IS
'Daily peak demand enriched with operational asset hierarchy.';


-- ----------------------------------------------------------------------------
-- 7. Asset-aware monthly peak demand.
-- ----------------------------------------------------------------------------

CREATE OR REPLACE VIEW analytics.v_asset_peak_demand_monthly
WITH
(
    security_barrier = TRUE
)
AS
SELECT
    p.grafana_org_id,

    p.organization_id,
    p.site_id,

    ad.asset_id,
    ad.asset_name,
    ad.asset_type,

    ad.parent_asset_id,
    ad.parent_asset_name,

    p.device_id,
    p.external_id,
    p.device_name,

    p.demand_month,
    p.peak_demand_date,
    p.peak_bucket_start,

    p.peak_demand_kw,
    p.peak_observed_power_kw,

    p.power_data_availability_percent

FROM analytics.v_energy_peak_demand_monthly p

JOIN analytics.v_asset_devices ad
  ON ad.grafana_org_id = p.grafana_org_id
 AND ad.device_id = p.device_id
 AND ad.relationship_type = 'PRIMARY_METER';


COMMENT ON VIEW analytics.v_asset_peak_demand_monthly IS
'Monthly peak demand enriched with operational asset hierarchy.';


-- ----------------------------------------------------------------------------
-- 8. Asset-level latest KPI summary.
-- ----------------------------------------------------------------------------

CREATE OR REPLACE VIEW analytics.v_asset_energy_kpis
WITH
(
    security_barrier = TRUE
)
AS
SELECT
    latest.grafana_org_id,

    latest.organization_id,
    latest.site_id,

    latest.parent_asset_id,
    latest.parent_asset_name,

    latest.asset_id,
    latest.asset_name,
    latest.asset_type,

    latest.device_id,
    latest.external_id,
    latest.device_name,

    latest.received_at,

    latest.active_power_total_w / 1000.0
        AS current_demand_kw,

    latest.import_energy_total_wh / 1000.0
        AS import_energy_register_kwh,

    latest.power_factor_total,
    latest.frequency_hz,

    EXTRACT
    (
        EPOCH FROM
        (
            now() - latest.received_at
        )
    )::BIGINT AS data_age_seconds

FROM analytics.v_asset_energy_latest latest;


COMMENT ON VIEW analytics.v_asset_energy_kpis IS
'Latest operational asset energy KPIs for Grafana stat and status panels.';


-- ----------------------------------------------------------------------------
-- 9. Least-privilege access.
-- ----------------------------------------------------------------------------

REVOKE ALL ON
    analytics.v_asset_selector,
    analytics.v_asset_load_profile_hourly,
    analytics.v_asset_load_profile_hour_of_day,
    analytics.v_asset_consumption_daily,
    analytics.v_asset_consumption_monthly,
    analytics.v_asset_peak_demand_daily,
    analytics.v_asset_peak_demand_monthly,
    analytics.v_asset_energy_kpis
FROM PUBLIC;


GRANT SELECT ON
    analytics.v_asset_selector,
    analytics.v_asset_load_profile_hourly,
    analytics.v_asset_load_profile_hour_of_day,
    analytics.v_asset_consumption_daily,
    analytics.v_asset_consumption_monthly,
    analytics.v_asset_peak_demand_daily,
    analytics.v_asset_peak_demand_monthly,
    analytics.v_asset_energy_kpis
TO grafana_reader;
