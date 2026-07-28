-- ============================================================================
-- File:
--   88_asset_hierarchy_rollup_daily.sql
--
-- Epic:
--   Epic 4 — Core Energy Analytics
--
-- Story:
--   4.4 — Asset hierarchy rollups
--
-- Purpose:
--   Produce tenant-safe daily energy rollups for every asset ancestor.
--
-- Source:
--   analytics.v_asset_consumption_daily
--
-- Hierarchy:
--   analytics.v_asset_hierarchy_closure
--
-- Reporting policy:
--   DIRECT_PREFERRED
--
-- Important fail-safe behavior:
--
--   If an asset has a configured PRIMARY_METER but that direct meter has no
--   valid daily row, reported consumption remains NULL. The view does not
--   silently replace missing boundary-meter data with descendant totals.
--
--   Descendant consumption remains visible separately for reconciliation.
--
-- Values exposed:
--
--   direct_*:
--       Consumption measured by the asset's own PRIMARY_METER.
--
--   descendant_*:
--       Sum of all metered descendants at every depth.
--
--   reported_*:
--       Direct value when a direct meter is configured; otherwise descendant
--       rollup.
--
-- Double-counting protection:
--   Direct and descendant values are never added together into reported
--   consumption.
-- ============================================================================


CREATE OR REPLACE VIEW analytics.v_asset_hierarchy_rollup_daily
WITH
(
    security_barrier = TRUE
)
AS
WITH direct_meter_assignments AS
(
    SELECT
        ad.grafana_org_id,
        ad.organization_id,
        ad.site_id,
        ad.asset_id,

        COUNT(DISTINCT ad.device_id)
            AS direct_meter_count

    FROM analytics.v_asset_devices ad

    WHERE ad.relationship_type = 'PRIMARY_METER'

    GROUP BY
        ad.grafana_org_id,
        ad.organization_id,
        ad.site_id,
        ad.asset_id
),

contributions AS
(
    SELECT
        h.grafana_org_id,
        h.organization_id,
        h.site_id,

        h.site_code,
        h.site_name,

        h.ancestor_asset_id AS asset_id,
        h.ancestor_asset_name AS asset_name,
        h.ancestor_asset_type_id AS asset_type_id,
        h.ancestor_asset_type AS asset_type,
        h.ancestor_parent_asset_id AS parent_asset_id,

        parent.name AS parent_asset_name,

        h.descendant_asset_id,
        h.descendant_asset_name,
        h.depth,

        c.device_id,
        c.consumption_date,

        c.import_consumption_kwh,
        c.export_consumption_kwh,

        c.valid_import_intervals,
        c.valid_export_intervals,

        c.reset_interval_count,
        c.gap_interval_count,

        c.first_bucket_start,
        c.last_bucket_start

    FROM analytics.v_asset_hierarchy_closure h

    JOIN analytics.v_asset_consumption_daily c
      ON c.grafana_org_id = h.grafana_org_id
     AND c.organization_id = h.organization_id
     AND c.site_id = h.site_id
     AND c.asset_id = h.descendant_asset_id

    LEFT JOIN metadata.assets parent
      ON parent.id = h.ancestor_parent_asset_id
     AND parent.organization_id = h.organization_id
     AND parent.site_id = h.site_id
),

aggregated AS
(
    SELECT
        c.grafana_org_id,
        c.organization_id,
        c.site_id,

        c.site_code,
        c.site_name,

        c.asset_id,
        c.asset_name,
        c.asset_type_id,
        c.asset_type,

        c.parent_asset_id,
        c.parent_asset_name,

        c.consumption_date,

        -- --------------------------------------------------------------------
        -- Direct meter values: closure depth zero.
        -- --------------------------------------------------------------------

        SUM(c.import_consumption_kwh)
        FILTER
        (
            WHERE c.depth = 0
        ) AS direct_import_consumption_kwh,

        SUM(c.export_consumption_kwh)
        FILTER
        (
            WHERE c.depth = 0
        ) AS direct_export_consumption_kwh,

        SUM(c.valid_import_intervals)
        FILTER
        (
            WHERE c.depth = 0
        ) AS direct_valid_import_intervals,

        SUM(c.valid_export_intervals)
        FILTER
        (
            WHERE c.depth = 0
        ) AS direct_valid_export_intervals,

        SUM(c.reset_interval_count)
        FILTER
        (
            WHERE c.depth = 0
        ) AS direct_reset_interval_count,

        SUM(c.gap_interval_count)
        FILTER
        (
            WHERE c.depth = 0
        ) AS direct_gap_interval_count,

        COUNT(DISTINCT c.device_id)
        FILTER
        (
            WHERE c.depth = 0
        ) AS direct_devices_with_data,

        -- --------------------------------------------------------------------
        -- Descendant rollup values: all closure depths greater than zero.
        -- --------------------------------------------------------------------

        SUM(c.import_consumption_kwh)
        FILTER
        (
            WHERE c.depth > 0
        ) AS descendant_import_consumption_kwh,

        SUM(c.export_consumption_kwh)
        FILTER
        (
            WHERE c.depth > 0
        ) AS descendant_export_consumption_kwh,

        SUM(c.valid_import_intervals)
        FILTER
        (
            WHERE c.depth > 0
        ) AS descendant_valid_import_intervals,

        SUM(c.valid_export_intervals)
        FILTER
        (
            WHERE c.depth > 0
        ) AS descendant_valid_export_intervals,

        SUM(c.reset_interval_count)
        FILTER
        (
            WHERE c.depth > 0
        ) AS descendant_reset_interval_count,

        SUM(c.gap_interval_count)
        FILTER
        (
            WHERE c.depth > 0
        ) AS descendant_gap_interval_count,

        COUNT(DISTINCT c.device_id)
        FILTER
        (
            WHERE c.depth > 0
        ) AS descendant_devices_with_data,

        COUNT(DISTINCT c.descendant_asset_id)
        FILTER
        (
            WHERE c.depth > 0
        ) AS descendants_with_data,

        MAX(c.depth)
        FILTER
        (
            WHERE c.depth > 0
        ) AS deepest_contributing_level,

        MIN(c.first_bucket_start)
            AS first_bucket_start,

        MAX(c.last_bucket_start)
            AS last_bucket_start

    FROM contributions c

    GROUP BY
        c.grafana_org_id,
        c.organization_id,
        c.site_id,
        c.site_code,
        c.site_name,
        c.asset_id,
        c.asset_name,
        c.asset_type_id,
        c.asset_type,
        c.parent_asset_id,
        c.parent_asset_name,
        c.consumption_date
),

classified AS
(
    SELECT
        a.*,

        COALESCE(dma.direct_meter_count, 0)
            AS direct_meter_count,

        COALESCE(dma.direct_meter_count, 0) > 0
            AS direct_meter_configured,

        a.direct_devices_with_data > 0
            AS direct_data_available,

        a.descendant_devices_with_data > 0
            AS descendant_data_available,

        CASE
            WHEN COALESCE(dma.direct_meter_count, 0) > 0
            THEN a.direct_import_consumption_kwh

            ELSE a.descendant_import_consumption_kwh
        END AS reported_import_consumption_kwh,

        CASE
            WHEN COALESCE(dma.direct_meter_count, 0) > 0
            THEN a.direct_export_consumption_kwh

            ELSE a.descendant_export_consumption_kwh
        END AS reported_export_consumption_kwh,

        CASE
            WHEN COALESCE(dma.direct_meter_count, 0) > 0
             AND a.direct_devices_with_data > 0
            THEN 'DIRECT_METER'

            WHEN COALESCE(dma.direct_meter_count, 0) > 0
             AND a.direct_devices_with_data = 0
            THEN 'DIRECT_METER_NO_DATA'

            WHEN COALESCE(dma.direct_meter_count, 0) = 0
             AND a.descendant_devices_with_data > 0
            THEN 'DESCENDANT_ROLLUP'

            ELSE 'NO_METERED_COVERAGE'
        END AS reporting_method,

        CASE
            WHEN COALESCE(dma.direct_meter_count, 0) > 0
             AND a.direct_devices_with_data = 0
            THEN 'DIRECT_DATA_MISSING'

            WHEN COALESCE(dma.direct_meter_count, 0) > 0
             AND COALESCE(a.direct_reset_interval_count, 0) > 0
            THEN 'RESET_DETECTED'

            WHEN COALESCE(dma.direct_meter_count, 0) > 0
             AND COALESCE(a.direct_gap_interval_count, 0) > 0
            THEN 'GAPS_DETECTED'

            WHEN COALESCE(dma.direct_meter_count, 0) = 0
             AND COALESCE(a.descendant_reset_interval_count, 0) > 0
            THEN 'RESET_DETECTED'

            WHEN COALESCE(dma.direct_meter_count, 0) = 0
             AND COALESCE(a.descendant_gap_interval_count, 0) > 0
            THEN 'GAPS_DETECTED'

            WHEN COALESCE(dma.direct_meter_count, 0) > 0
              OR a.descendant_devices_with_data > 0
            THEN 'GOOD'

            ELSE 'NO_DATA'
        END AS quality_status

    FROM aggregated a

    LEFT JOIN direct_meter_assignments dma
      ON dma.grafana_org_id = a.grafana_org_id
     AND dma.organization_id = a.organization_id
     AND dma.site_id = a.site_id
     AND dma.asset_id = a.asset_id
)

SELECT
    grafana_org_id,
    organization_id,
    site_id,

    site_code,
    site_name,

    asset_id,
    asset_name,
    asset_type_id,
    asset_type,

    parent_asset_id,
    parent_asset_name,

    consumption_date,

    direct_import_consumption_kwh,
    descendant_import_consumption_kwh,
    reported_import_consumption_kwh,

    direct_export_consumption_kwh,
    descendant_export_consumption_kwh,
    reported_export_consumption_kwh,

    direct_meter_count,
    direct_meter_configured,
    direct_data_available,
    descendant_data_available,

    direct_devices_with_data,
    descendant_devices_with_data,
    descendants_with_data,
    deepest_contributing_level,

    direct_valid_import_intervals,
    descendant_valid_import_intervals,

    direct_valid_export_intervals,
    descendant_valid_export_intervals,

    direct_reset_interval_count,
    descendant_reset_interval_count,

    direct_gap_interval_count,
    descendant_gap_interval_count,

    reporting_method,
    quality_status,

    first_bucket_start,
    last_bucket_start

FROM classified;


COMMENT ON VIEW analytics.v_asset_hierarchy_rollup_daily IS
'Tenant-safe daily recursive asset rollup exposing direct, descendant and DIRECT_PREFERRED reported energy consumption without double-counting.';


REVOKE ALL
ON analytics.v_asset_hierarchy_rollup_daily
FROM PUBLIC;


GRANT SELECT
ON analytics.v_asset_hierarchy_rollup_daily
TO grafana_reader;
