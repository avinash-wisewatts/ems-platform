BEGIN;

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

        -- Discrete/state values are not averaged.
        WHEN lower(lp.data_type) IN ('boolean', 'status')
            THEN 'last'

        -- Explicit demand semantics.
        WHEN upper(lp.name) LIKE '%DEMAND%'
            THEN 'max'

        -- Cumulative engineering units represent registers/counters.
        WHEN lower(COALESCE(eu.symbol, '')) IN (
            'wh',
            'kwh',
            'mwh',
            'varh',
            'kvarh',
            'mvarh',
            'vah',
            'kvah',
            'mvah'
        )
            THEN 'delta'

        -- Explicit counters/pulse registers.
        WHEN upper(lp.name) LIKE '%PULSE_COUNT%'
          OR upper(lp.name) LIKE '%COUNTER%'
            THEN 'delta'

        -- Instantaneous numeric measurements:
        -- power, voltage, current, PF, frequency, THD,
        -- temperature, humidity, pressure, flow rate, etc.
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
'Tenant-safe lightweight metadata surface for configured asset points. Provides selector/catalogue metadata and generic aggregation semantics without scanning historical telemetry. Domain-native analytics may override the generic recommendation where required.';


GRANT SELECT
ON analytics.v_grafana_asset_point_selector
TO grafana_reader;

COMMIT;
