BEGIN;

-- =====================================================================
-- Analytics Explorer lightweight point metadata surface.
--
-- Purpose:
--   Serve selectors/catalogue metadata without scanning historical
--   telemetry.
--
-- Source of truth:
--   asset/device assignments
--   configured enabled logical points
--   logical-point metadata
--
-- Deliberately NOT sourced from telemetry.normalized_points.
-- =====================================================================

CREATE OR REPLACE VIEW analytics.v_grafana_asset_point_selector AS
SELECT DISTINCT
    gom.grafana_org_id,
    a.organization_id,
    a.site_id,

    a.id AS asset_id,
    a.name AS asset_name,

    d.id AS device_id,
    d.name AS device_name,

    lp.id AS logical_point_id,
    lp.name AS logical_point,

    eu.symbol AS unit_symbol,
    lp.data_type,

    CASE
        WHEN lp.data_type IN ('boolean', 'status')
            THEN 'last'

        WHEN upper(lp.name) LIKE '%ENERGY%'
          OR upper(lp.name) LIKE '%COUNTER%'
          OR upper(lp.name) LIKE '%PULSE_COUNT%'
            THEN 'delta'

        ELSE 'avg'
    END AS recommended_aggregation

FROM metadata.grafana_organization_map AS gom

JOIN metadata.assets AS a
  ON a.organization_id = gom.organization_id

JOIN metadata.asset_devices AS ad
  ON ad.asset_id = a.id

JOIN metadata.devices AS d
  ON d.id = ad.device_id
 AND d.organization_id = a.organization_id

JOIN config.device_point_configuration AS dpc
  ON dpc.device_id = d.id
 AND dpc.is_enabled

JOIN metadata.logical_points AS lp
  ON lp.id = dpc.logical_point_id

LEFT JOIN config.engineering_units AS eu
  ON eu.id = lp.unit_id

WHERE gom.is_active;


COMMENT ON VIEW analytics.v_grafana_asset_point_selector IS
'Tenant-safe lightweight metadata surface for logical points configured on devices assigned to assets. Intended for Grafana selectors and catalogue UI; does not scan telemetry history.';


GRANT SELECT
ON analytics.v_grafana_asset_point_selector
TO grafana_reader;


COMMIT;
