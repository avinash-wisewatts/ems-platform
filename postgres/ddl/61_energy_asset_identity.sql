-- ============================================================================
-- File:
--   61_energy_asset_identity.sql
--
-- Purpose:
--   Persist operational asset identity in telemetry.energy_measurements.
--
-- Resolution:
--
--   energy_measurements.device_id
--       -> metadata.asset_devices
--       -> relationship_type = PRIMARY_METER
--       -> energy_measurements.asset_id
--
-- Reliability:
--
--   - Existing explicit asset_id values are preserved when valid.
--   - A primary-meter assignment overrides NULL asset identity.
--   - Tenant and site consistency are validated before assignment.
--   - Historical energy rows are backfilled.
--   - Future inserts and device changes are handled by a database trigger.
-- ============================================================================


-- ----------------------------------------------------------------------------
-- 1. Resolve the primary asset for a telemetry device.
-- ----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION telemetry.resolve_primary_asset_id
(
    p_device_id UUID,
    p_organization_id UUID,
    p_site_id UUID
)
RETURNS UUID
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, metadata
AS
$$
    SELECT a.id
    FROM metadata.asset_devices ad

    JOIN metadata.assets a
      ON a.id = ad.asset_id

    JOIN metadata.devices d
      ON d.id = ad.device_id

    WHERE ad.device_id = p_device_id
      AND ad.relationship_type = 'PRIMARY_METER'

      -- Reject cross-tenant or cross-site relationships.
      AND a.organization_id = p_organization_id
      AND a.site_id = p_site_id
      AND d.organization_id = p_organization_id

    LIMIT 1;
$$;


COMMENT ON FUNCTION telemetry.resolve_primary_asset_id
(
    UUID,
    UUID,
    UUID
) IS
'Returns the tenant- and site-consistent PRIMARY_METER asset assigned to a device.';


-- ----------------------------------------------------------------------------
-- 2. Trigger function for new and updated energy rows.
-- ----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION telemetry.set_energy_measurement_asset_id
()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, telemetry, metadata
AS
$$
DECLARE
    v_resolved_asset_id UUID;
BEGIN
    v_resolved_asset_id :=
        telemetry.resolve_primary_asset_id
        (
            NEW.device_id,
            NEW.organization_id,
            NEW.site_id
        );


    -- Assign the resolved primary asset when one exists.
    --
    -- If no primary assignment exists, retain any explicitly supplied asset_id.
    IF v_resolved_asset_id IS NOT NULL THEN
        NEW.asset_id := v_resolved_asset_id;
    END IF;


    RETURN NEW;
END;
$$;


COMMENT ON FUNCTION telemetry.set_energy_measurement_asset_id() IS
'Assigns the PRIMARY_METER operational asset to energy telemetry rows before persistence.';


-- ----------------------------------------------------------------------------
-- 3. Install the trigger idempotently.
-- ----------------------------------------------------------------------------

DROP TRIGGER IF EXISTS trg_set_energy_measurement_asset_id
ON telemetry.energy_measurements;


CREATE TRIGGER trg_set_energy_measurement_asset_id

BEFORE INSERT OR UPDATE OF
    device_id,
    organization_id,
    site_id,
    asset_id

ON telemetry.energy_measurements

FOR EACH ROW

EXECUTE FUNCTION telemetry.set_energy_measurement_asset_id();


-- ----------------------------------------------------------------------------
-- 4. Backfill historical energy rows.
--
-- Only rows whose current asset identity is missing or incorrect are updated.
-- ----------------------------------------------------------------------------

WITH resolved AS
(
    SELECT
        em.received_at,
        em.device_id,

        telemetry.resolve_primary_asset_id
        (
            em.device_id,
            em.organization_id,
            em.site_id
        ) AS resolved_asset_id

    FROM telemetry.energy_measurements em
)
UPDATE telemetry.energy_measurements em

SET asset_id = resolved.resolved_asset_id

FROM resolved

WHERE em.received_at = resolved.received_at
  AND em.device_id = resolved.device_id
  AND resolved.resolved_asset_id IS NOT NULL
  AND em.asset_id IS DISTINCT FROM resolved.resolved_asset_id;


-- ----------------------------------------------------------------------------
-- 5. Asset-aware latest energy view.
-- ----------------------------------------------------------------------------

CREATE OR REPLACE VIEW analytics.v_asset_energy_latest
WITH
(
    security_barrier = TRUE
)
AS
SELECT
    l.grafana_org_id,

    l.organization_id,
    l.site_id,
    l.gateway_id,

    l.asset_id,
    a.asset_name,
    a.asset_type,
    a.parent_asset_id,
    a.parent_asset_name,

    l.device_id,
    l.external_id,
    l.device_name,

    l.received_at,
    l.source_timestamp,

    l.import_energy_total_wh,
    l.export_energy_total_wh,

    l.active_power_total_w,
    l.reactive_power_total_var,
    l.apparent_power_total_va,

    l.voltage_l1_v,
    l.voltage_l2_v,
    l.voltage_l3_v,

    l.current_l1_a,
    l.current_l2_a,
    l.current_l3_a,

    l.power_factor_total,
    l.frequency_hz,

    l.current_thd_l1_percent,
    l.current_thd_l2_percent,
    l.current_thd_l3_percent

FROM analytics.v_energy_latest l

JOIN analytics.v_assets a
  ON a.grafana_org_id = l.grafana_org_id
 AND a.asset_id = l.asset_id;


COMMENT ON VIEW analytics.v_asset_energy_latest IS
'Newest energy measurement enriched with operational asset hierarchy.';


-- ----------------------------------------------------------------------------
-- 6. Asset-aware 15-minute energy aggregate.
-- ----------------------------------------------------------------------------

CREATE OR REPLACE VIEW analytics.v_asset_energy_15min
WITH
(
    security_barrier = TRUE
)
AS
SELECT
    ca.grafana_org_id,

    ca.organization_id,
    ca.site_id,

    ad.asset_id,
    ad.asset_name,
    ad.asset_type,
    ad.parent_asset_id,
    ad.parent_asset_name,

    ca.device_id,
    ad.external_id,
    ad.device_name,

    ca.bucket_start,
    ca.sample_count,

    ca.import_energy_total_wh_min,
    ca.import_energy_total_wh_max,

    ca.export_energy_total_wh_min,
    ca.export_energy_total_wh_max,

    ca.active_power_total_w_avg,
    ca.active_power_total_w_min,
    ca.active_power_total_w_max,

    ca.reactive_power_total_var_avg,
    ca.apparent_power_total_va_avg,

    ca.voltage_l1_v_avg,
    ca.voltage_l2_v_avg,
    ca.voltage_l3_v_avg,

    ca.current_l1_a_avg,
    ca.current_l2_a_avg,
    ca.current_l3_a_avg,

    ca.power_factor_total_avg,
    ca.frequency_hz_avg,

    ca.active_power_sample_count,
    ca.import_energy_sample_count

FROM analytics.v_energy_15min ca

JOIN analytics.v_asset_devices ad
  ON ad.grafana_org_id = ca.grafana_org_id
 AND ad.device_id = ca.device_id
 AND ad.relationship_type = 'PRIMARY_METER';


COMMENT ON VIEW analytics.v_asset_energy_15min IS
'Fifteen-minute energy aggregate enriched with operational asset hierarchy.';


-- ----------------------------------------------------------------------------
-- 7. Asset-aware demand series.
-- ----------------------------------------------------------------------------

CREATE OR REPLACE VIEW analytics.v_asset_demand_15min
WITH
(
    security_barrier = TRUE
)
AS
SELECT
    d.grafana_org_id,

    d.organization_id,
    d.site_id,

    ad.asset_id,
    ad.asset_name,
    ad.asset_type,
    ad.parent_asset_id,
    ad.parent_asset_name,

    d.device_id,
    d.external_id,
    d.device_name,

    d.bucket_start,

    d.demand_kw_avg,
    d.demand_kw_min,
    d.demand_kw_max,

    d.sample_count,
    d.active_power_sample_count,
    d.power_data_availability_percent

FROM analytics.v_energy_demand_15min d

JOIN analytics.v_asset_devices ad
  ON ad.grafana_org_id = d.grafana_org_id
 AND ad.device_id = d.device_id
 AND ad.relationship_type = 'PRIMARY_METER';


COMMENT ON VIEW analytics.v_asset_demand_15min IS
'Fifteen-minute demand enriched with operational asset hierarchy.';


-- ----------------------------------------------------------------------------
-- 8. Asset-aware consumption series.
-- ----------------------------------------------------------------------------

CREATE OR REPLACE VIEW analytics.v_asset_consumption_15min
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

    c.bucket_start,
    c.previous_bucket_start,
    c.elapsed_minutes,

    c.import_register_wh,
    c.previous_import_register_wh,
    c.import_consumption_wh,
    c.import_consumption_kwh,
    c.import_quality_code,

    c.export_register_wh,
    c.previous_export_register_wh,
    c.export_consumption_wh,
    c.export_consumption_kwh,
    c.export_quality_code,

    c.reset_detected,
    c.gap_detected

FROM analytics.v_energy_consumption_15min c

JOIN analytics.v_asset_devices ad
  ON ad.grafana_org_id = c.grafana_org_id
 AND ad.device_id = c.device_id
 AND ad.relationship_type = 'PRIMARY_METER';


COMMENT ON VIEW analytics.v_asset_consumption_15min IS
'Reset-aware energy consumption enriched with operational asset hierarchy.';


-- ----------------------------------------------------------------------------
-- 9. Least-privilege access.
-- ----------------------------------------------------------------------------

REVOKE ALL ON
    analytics.v_asset_energy_latest,
    analytics.v_asset_energy_15min,
    analytics.v_asset_demand_15min,
    analytics.v_asset_consumption_15min
FROM PUBLIC;


GRANT SELECT ON
    analytics.v_asset_energy_latest,
    analytics.v_asset_energy_15min,
    analytics.v_asset_demand_15min,
    analytics.v_asset_consumption_15min
TO grafana_reader;
