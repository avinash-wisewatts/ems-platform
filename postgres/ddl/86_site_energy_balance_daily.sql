-- ============================================================================
-- File:
--   86_site_energy_balance_daily.sql
--
-- Epic:
--   Epic 4 — Core Energy Analytics
--
-- Story:
--   4.3 — Site energy balance
--
-- Purpose:
--   Calculate tenant-safe daily site energy balance using explicitly assigned,
--   authoritative and effective-dated meter roles.
--
-- Source grain:
--   analytics.v_energy_consumption_15min
--
-- Why the 15-minute source is used:
--   Site meter roles are effective-dated. Joining at bucket_start ensures that
--   a mid-day role change is applied only to the intervals for which it was
--   effective.
--
-- Site energy equation:
--
--   Derived Consumption
--       = Grid Import
--       + On-site Generation
--       - Grid Export
--       - Battery Charging
--       + Battery Discharging
--
-- Direct site consumption:
--   A SITE_CONSUMPTION role provides a directly measured site total.
--
-- Reporting precedence:
--   1. DIRECT_METER
--   2. DERIVED_BALANCE
--   3. UNAVAILABLE
--
-- LOAD_SUBMETER:
--   Explicitly excluded from the site balance to avoid double-counting.
-- ============================================================================


CREATE OR REPLACE VIEW analytics.v_site_energy_balance_daily
WITH
(
    security_barrier = TRUE
)
AS
WITH role_intervals AS
(
    SELECT
        c.grafana_org_id,
        c.organization_id,
        c.site_id,

        s.code AS site_code,
        s.name AS site_name,
        s.timezone AS site_timezone,

        (
            c.bucket_start
            AT TIME ZONE s.timezone
        )::DATE AS balance_date,

        c.bucket_start,
        c.device_id,

        r.meter_role,
        r.allocation_factor,

        c.import_consumption_kwh,
        c.export_consumption_kwh,

        c.import_quality_code,
        c.export_quality_code,

        c.gap_detected,
        c.reset_detected,

        (
            c.import_quality_code = 'ROLLOVER'
            OR c.export_quality_code = 'ROLLOVER'
        ) AS rollover_detected

    FROM analytics.v_energy_consumption_15min c

    JOIN metadata.sites s
      ON s.id = c.site_id
     AND s.organization_id = c.organization_id

    JOIN config.site_energy_meter_roles r
      ON r.site_id = c.site_id
     AND r.device_id = c.device_id
     AND r.is_active = TRUE
     AND r.is_authoritative = TRUE
     AND r.effective_range @> c.bucket_start

    WHERE r.meter_role <> 'LOAD_SUBMETER'
),

component_totals AS
(
    SELECT
        grafana_org_id,
        organization_id,
        site_id,
        site_code,
        site_name,
        site_timezone,
        balance_date,

        SUM
        (
            import_consumption_kwh * allocation_factor
        )
        FILTER
        (
            WHERE meter_role = 'GRID_IMPORT'
              AND import_quality_code IN
              (
                  'GOOD',
                  'GAP',
                  'ROLLOVER',
                  'RESET_FROM_ZERO'
              )
        ) AS grid_import_kwh,

        SUM
        (
            export_consumption_kwh * allocation_factor
        )
        FILTER
        (
            WHERE meter_role = 'GRID_EXPORT'
              AND export_quality_code IN
              (
                  'GOOD',
                  'GAP',
                  'ROLLOVER',
                  'RESET_FROM_ZERO'
              )
        ) AS grid_export_kwh,

        SUM
        (
            import_consumption_kwh * allocation_factor
        )
        FILTER
        (
            WHERE meter_role = 'ONSITE_GENERATION'
              AND import_quality_code IN
              (
                  'GOOD',
                  'GAP',
                  'ROLLOVER',
                  'RESET_FROM_ZERO'
              )
        ) AS onsite_generation_kwh,

        SUM
        (
            import_consumption_kwh * allocation_factor
        )
        FILTER
        (
            WHERE meter_role = 'SITE_CONSUMPTION'
              AND import_quality_code IN
              (
                  'GOOD',
                  'GAP',
                  'ROLLOVER',
                  'RESET_FROM_ZERO'
              )
        ) AS direct_site_consumption_kwh,

        SUM
        (
            import_consumption_kwh * allocation_factor
        )
        FILTER
        (
            WHERE meter_role = 'BATTERY_CHARGE'
              AND import_quality_code IN
              (
                  'GOOD',
                  'GAP',
                  'ROLLOVER',
                  'RESET_FROM_ZERO'
              )
        ) AS battery_charge_kwh,

        SUM
        (
            import_consumption_kwh * allocation_factor
        )
        FILTER
        (
            WHERE meter_role = 'BATTERY_DISCHARGE'
              AND import_quality_code IN
              (
                  'GOOD',
                  'GAP',
                  'ROLLOVER',
                  'RESET_FROM_ZERO'
              )
        ) AS battery_discharge_kwh,

        COUNT(DISTINCT device_id)
        FILTER
        (
            WHERE meter_role = 'GRID_IMPORT'
        ) AS grid_import_meter_count,

        COUNT(DISTINCT device_id)
        FILTER
        (
            WHERE meter_role = 'GRID_EXPORT'
        ) AS grid_export_meter_count,

        COUNT(DISTINCT device_id)
        FILTER
        (
            WHERE meter_role = 'ONSITE_GENERATION'
        ) AS generation_meter_count,

        COUNT(DISTINCT device_id)
        FILTER
        (
            WHERE meter_role = 'SITE_CONSUMPTION'
        ) AS site_consumption_meter_count,

        COUNT(DISTINCT device_id)
        FILTER
        (
            WHERE meter_role = 'BATTERY_CHARGE'
        ) AS battery_charge_meter_count,

        COUNT(DISTINCT device_id)
        FILTER
        (
            WHERE meter_role = 'BATTERY_DISCHARGE'
        ) AS battery_discharge_meter_count,

        COUNT(*) AS total_role_intervals,

        COUNT(*) FILTER
        (
            WHERE gap_detected
        ) AS gap_interval_count,

        COUNT(*) FILTER
        (
            WHERE reset_detected
        ) AS reset_interval_count,

        COUNT(*) FILTER
        (
            WHERE rollover_detected
        ) AS rollover_interval_count,

        COUNT(*) FILTER
        (
            WHERE
                import_quality_code NOT IN
                (
                    'GOOD',
                    'GAP',
                    'ROLLOVER',
                    'RESET_FROM_ZERO',
                    'INITIAL',
                    'MISSING_REGISTER'
                )
                OR
                export_quality_code NOT IN
                (
                    'GOOD',
                    'GAP',
                    'ROLLOVER',
                    'RESET_FROM_ZERO',
                    'INITIAL',
                    'MISSING_REGISTER'
                )
        ) AS invalid_interval_count,

        MIN(bucket_start) AS first_bucket_start,
        MAX(bucket_start) AS last_bucket_start

    FROM role_intervals

    GROUP BY
        grafana_org_id,
        organization_id,
        site_id,
        site_code,
        site_name,
        site_timezone,
        balance_date
),

classified AS
(
    SELECT
        c.*,

        CASE
            WHEN c.grid_import_kwh IS NULL
            THEN NULL

            ELSE
                c.grid_import_kwh
                + COALESCE(c.onsite_generation_kwh, 0)
                - COALESCE(c.grid_export_kwh, 0)
                - COALESCE(c.battery_charge_kwh, 0)
                + COALESCE(c.battery_discharge_kwh, 0)
        END AS derived_site_consumption_kwh,

        CASE
            WHEN c.direct_site_consumption_kwh IS NOT NULL
            THEN c.direct_site_consumption_kwh

            WHEN c.grid_import_kwh IS NOT NULL
            THEN
                c.grid_import_kwh
                + COALESCE(c.onsite_generation_kwh, 0)
                - COALESCE(c.grid_export_kwh, 0)
                - COALESCE(c.battery_charge_kwh, 0)
                + COALESCE(c.battery_discharge_kwh, 0)

            ELSE NULL
        END AS reported_site_consumption_kwh,

        CASE
            WHEN c.direct_site_consumption_kwh IS NOT NULL
            THEN 'DIRECT_METER'

            WHEN c.grid_import_kwh IS NOT NULL
            THEN 'DERIVED_BALANCE'

            ELSE 'UNAVAILABLE'
        END AS balance_method,

        CASE
            WHEN c.direct_site_consumption_kwh IS NOT NULL
            THEN 'DIRECT_SITE_METER_AVAILABLE'

            WHEN c.grid_import_kwh IS NOT NULL
             AND c.onsite_generation_kwh IS NOT NULL
             AND c.grid_export_kwh IS NOT NULL
             AND c.battery_charge_kwh IS NOT NULL
             AND c.battery_discharge_kwh IS NOT NULL
            THEN 'FULL_BALANCE_COMPONENTS'

            WHEN c.grid_import_kwh IS NOT NULL
            THEN 'PARTIAL_BALANCE_COMPONENTS'

            ELSE 'NO_SITE_BOUNDARY_METER'
        END AS coverage_status,

        CASE
            WHEN c.invalid_interval_count > 0
            THEN 'INVALID_INTERVALS'

            WHEN c.reset_interval_count > 0
            THEN 'RESET_DETECTED'

            WHEN c.gap_interval_count > 0
            THEN 'GAPS_DETECTED'

            WHEN c.total_role_intervals > 0
            THEN 'GOOD'

            ELSE 'NO_DATA'
        END AS quality_status

    FROM component_totals c
)

SELECT
    grafana_org_id,
    organization_id,

    site_id,
    site_code,
    site_name,
    site_timezone,

    balance_date,

    grid_import_kwh,
    grid_export_kwh,
    onsite_generation_kwh,

    battery_charge_kwh,
    battery_discharge_kwh,

    direct_site_consumption_kwh,
    derived_site_consumption_kwh,
    reported_site_consumption_kwh,

    balance_method,
    coverage_status,
    quality_status,

    grid_import_meter_count,
    grid_export_meter_count,
    generation_meter_count,
    site_consumption_meter_count,
    battery_charge_meter_count,
    battery_discharge_meter_count,

    total_role_intervals,
    gap_interval_count,
    reset_interval_count,
    rollover_interval_count,
    invalid_interval_count,

    first_bucket_start,
    last_bucket_start

FROM classified;


COMMENT ON VIEW analytics.v_site_energy_balance_daily IS
'Tenant-safe daily site energy balance derived from authoritative, effective-dated site meter roles using each site configured timezone.';


REVOKE ALL
ON analytics.v_site_energy_balance_daily
FROM PUBLIC;


GRANT SELECT
ON analytics.v_site_energy_balance_daily
TO grafana_reader;
