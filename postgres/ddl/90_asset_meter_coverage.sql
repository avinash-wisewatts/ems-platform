-- ============================================================================
-- File:
--   90_asset_meter_coverage.sql
--
-- Epic:
--   Epic 4 — Core Energy Analytics
--
-- Story:
--   4.5 — Asset meter coverage
--
-- Purpose:
--   1. Expose the asset metering policy through the tenant-safe asset view.
--   2. Calculate configuration coverage independently from telemetry freshness.
--   3. Support direct-meter and descendant-based coverage policies.
--
-- Important distinction:
--
--   Configuration coverage
--       Answers whether the required PRIMARY_METER relationships exist.
--
--   Data availability
--       Answers whether configured meters are currently supplying usable data.
--
--   These concepts must remain separate. A correctly configured but temporarily
--   silent meter must not be reported as an unconfigured asset.
--
-- Descendant policy:
--
--   DESCENDANT_COVERAGE_ALLOWED is satisfied only when every active descendant
--   whose own policy is DIRECT_METER_REQUIRED has a PRIMARY_METER.
--
--   One arbitrary metered descendant is not sufficient to declare the entire
--   parent hierarchy covered.
-- ============================================================================


-- ----------------------------------------------------------------------------
-- 1. Extend the tenant-safe asset base view.
--
-- CREATE OR REPLACE VIEW requires existing columns to retain their order.
-- metering_requirement is therefore appended after the existing columns.
-- ----------------------------------------------------------------------------

CREATE OR REPLACE VIEW analytics.v_assets
WITH
(
    security_barrier = TRUE
)
AS
SELECT
    gom.grafana_org_id,

    a.organization_id,
    a.site_id,

    s.code AS site_code,
    s.name AS site_name,

    a.id AS asset_id,
    a.parent_asset_id,

    parent.name AS parent_asset_name,

    a.asset_type_id,
    at.name AS asset_type,
    at.description AS asset_type_description,

    a.name AS asset_name,
    a.manufacturer,
    a.model,
    a.serial_number,
    a.status,
    a.metadata,

    a.created_at,
    a.updated_at,

    -- Added by Story 4.5. Appended to preserve the existing view contract.
    a.metering_requirement

FROM metadata.grafana_organization_map gom

JOIN metadata.assets a
  ON a.organization_id = gom.organization_id

JOIN metadata.sites s
  ON s.id = a.site_id

LEFT JOIN metadata.assets parent
  ON parent.id = a.parent_asset_id

LEFT JOIN metadata.asset_types at
  ON at.id = a.asset_type_id

WHERE gom.is_active = TRUE;


COMMENT ON VIEW analytics.v_assets IS
'Tenant-safe operational asset hierarchy including the explicit asset metering requirement.';


-- ----------------------------------------------------------------------------
-- 2. Configuration-only meter coverage.
-- ----------------------------------------------------------------------------

CREATE OR REPLACE VIEW analytics.v_asset_meter_coverage_configuration
WITH
(
    security_barrier = TRUE
)
AS
WITH direct_meter AS
(
    -- Partial unique indexes guarantee at most one row per asset and device for
    -- PRIMARY_METER relationships. Aggregation remains defensive against legacy
    -- or externally restored data.
    SELECT
        ad.asset_id,
        count(*) AS direct_primary_meter_count,
        min(ad.device_id::text)::uuid
            AS direct_primary_meter_device_id

    FROM metadata.asset_devices ad

    WHERE ad.relationship_type = 'PRIMARY_METER'

    GROUP BY ad.asset_id
),

required_descendants AS
(
    -- Only descendants with an explicit direct-meter obligation form the
    -- denominator for descendant coverage.
    SELECT
        hc.ancestor_asset_id AS asset_id,

        count(*) AS required_descendant_count,

        count(*) FILTER
        (
            WHERE descendant_meter.asset_id IS NOT NULL
        ) AS configured_required_descendant_count,

        count(*) FILTER
        (
            WHERE descendant_meter.asset_id IS NULL
        ) AS missing_required_descendant_count

    FROM analytics.v_asset_hierarchy_closure hc

    JOIN metadata.assets descendant
      ON descendant.id = hc.descendant_asset_id
     AND descendant.organization_id = hc.organization_id
     AND descendant.site_id = hc.site_id

    LEFT JOIN direct_meter descendant_meter
      ON descendant_meter.asset_id = descendant.id

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

    -- Keep every asset visible. Only active assets with a metering obligation
    -- participate in coverage KPI denominators.
    (
        asset.status = 'active'
        AND asset.metering_requirement <> 'NOT_REQUIRED'
    ) AS is_coverage_in_scope,

    COALESCE(dm.direct_primary_meter_count, 0)
        AS direct_primary_meter_count,

    dm.direct_primary_meter_device_id,

    COALESCE(rd.required_descendant_count, 0)
        AS required_descendant_count,

    COALESCE(rd.configured_required_descendant_count, 0)
        AS configured_required_descendant_count,

    COALESCE(rd.missing_required_descendant_count, 0)
        AS missing_required_descendant_count,

    CASE
        WHEN asset.status <> 'active'
            THEN 'OUT_OF_SCOPE_INACTIVE'

        WHEN asset.metering_requirement = 'NOT_REQUIRED'
            THEN 'EXCLUDED'

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
             AND COALESCE(
                    rd.configured_required_descendant_count,
                    0
                 ) > 0
            THEN 'PARTIALLY_CONFIGURED'

        WHEN asset.metering_requirement = 'DESCENDANT_COVERAGE_ALLOWED'
            THEN 'MISSING_DESCENDANT_COVERAGE'

        -- Defensive fallback. The metadata.assets check constraint should make
        -- this branch unreachable.
        ELSE 'UNKNOWN_POLICY'
    END AS coverage_status,

    CASE
        WHEN asset.status <> 'active'
            THEN NULL

        WHEN asset.metering_requirement = 'NOT_REQUIRED'
            THEN NULL

        WHEN asset.metering_requirement = 'DIRECT_METER_REQUIRED'
            THEN
                CASE
                    WHEN COALESCE(dm.direct_primary_meter_count, 0) = 1
                        THEN 100.0
                    ELSE 0.0
                END

        WHEN asset.metering_requirement = 'DESCENDANT_COVERAGE_ALLOWED'
             AND COALESCE(rd.required_descendant_count, 0) = 0
            THEN NULL

        WHEN asset.metering_requirement = 'DESCENDANT_COVERAGE_ALLOWED'
            THEN round
            (
                100.0
                * COALESCE(
                    rd.configured_required_descendant_count,
                    0
                  )
                / NULLIF(rd.required_descendant_count, 0),
                2
            )

        ELSE NULL
    END AS configuration_coverage_percent

FROM analytics.v_assets asset

LEFT JOIN direct_meter dm
  ON dm.asset_id = asset.asset_id

LEFT JOIN required_descendants rd
  ON rd.asset_id = asset.asset_id;


COMMENT ON VIEW analytics.v_asset_meter_coverage_configuration IS
'Tenant-safe asset meter configuration coverage. This view evaluates configured PRIMARY_METER relationships only and intentionally excludes telemetry freshness.';


-- ----------------------------------------------------------------------------
-- 3. Least-privilege access.
-- ----------------------------------------------------------------------------

REVOKE ALL
ON analytics.v_asset_meter_coverage_configuration
FROM PUBLIC;


GRANT SELECT
ON analytics.v_asset_meter_coverage_configuration
TO grafana_reader;
