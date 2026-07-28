-- ============================================================================
-- File:
--   57_energy_consumption_reporting_views.sql
--
-- Purpose:
--   Build tenant-safe daily, monthly, and KPI reporting views from the
--   reset-aware 15-minute consumption layer.
--
-- Source:
--   analytics.v_energy_consumption_15min
--
-- Timezone:
--   Asia/Kolkata
--
-- Inclusion rules:
--
--   GOOD:
--     Included in totals.
--
--   GAP:
--     Included in totals because cumulative registers preserve consumption
--     across the missing telemetry interval.
--
--   INITIAL:
--     Excluded because there is no preceding register.
--
--   RESET:
--     Excluded because the interval delta is not reliable.
--
--   MISSING_REGISTER:
--     Excluded because no valid register delta exists.
--
-- Multi-tenancy:
--   Every view includes grafana_org_id and Grafana queries must filter:
--
--       WHERE grafana_org_id = ${__org.id}
-- ============================================================================


-- ----------------------------------------------------------------------------
-- 1. Daily consumption by tenant, site and device.
-- ----------------------------------------------------------------------------

CREATE OR REPLACE VIEW analytics.v_energy_consumption_daily
WITH
(
    security_barrier = TRUE
)
AS
SELECT
    grafana_org_id,

    date_trunc(
        'day',
        bucket_start AT TIME ZONE 'Asia/Kolkata'
    )::DATE AS consumption_date,

    organization_id,
    site_id,
    device_id,

    external_id,
    device_name,

    SUM(import_consumption_kwh) FILTER
    (
        WHERE import_quality_code IN ('GOOD', 'GAP')
    ) AS import_consumption_kwh,

    SUM(export_consumption_kwh) FILTER
    (
        WHERE export_quality_code IN ('GOOD', 'GAP')
    ) AS export_consumption_kwh,

    COUNT(*) FILTER
    (
        WHERE import_quality_code IN ('GOOD', 'GAP')
    ) AS valid_import_intervals,

    COUNT(*) FILTER
    (
        WHERE export_quality_code IN ('GOOD', 'GAP')
    ) AS valid_export_intervals,

    COUNT(*) FILTER
    (
        WHERE import_quality_code = 'RESET'
           OR export_quality_code = 'RESET'
    ) AS reset_interval_count,

    COUNT(*) FILTER
    (
        WHERE import_quality_code = 'GAP'
           OR export_quality_code = 'GAP'
    ) AS gap_interval_count,

    MIN(bucket_start) AS first_bucket_start,
    MAX(bucket_start) AS last_bucket_start

FROM analytics.v_energy_consumption_15min

GROUP BY
    grafana_org_id,
    consumption_date,
    organization_id,
    site_id,
    device_id,
    external_id,
    device_name;


COMMENT ON VIEW analytics.v_energy_consumption_daily IS
'Daily reset-aware import and export energy consumption by tenant, site and device.';


-- ----------------------------------------------------------------------------
-- 2. Monthly consumption by tenant, site and device.
-- ----------------------------------------------------------------------------

CREATE OR REPLACE VIEW analytics.v_energy_consumption_monthly
WITH
(
    security_barrier = TRUE
)
AS
SELECT
    grafana_org_id,

    date_trunc(
        'month',
        consumption_date::TIMESTAMP
    )::DATE AS consumption_month,

    organization_id,
    site_id,
    device_id,

    external_id,
    device_name,

    SUM(import_consumption_kwh)
        AS import_consumption_kwh,

    SUM(export_consumption_kwh)
        AS export_consumption_kwh,

    SUM(valid_import_intervals)
        AS valid_import_intervals,

    SUM(valid_export_intervals)
        AS valid_export_intervals,

    SUM(reset_interval_count)
        AS reset_interval_count,

    SUM(gap_interval_count)
        AS gap_interval_count,

    MIN(first_bucket_start)
        AS first_bucket_start,

    MAX(last_bucket_start)
        AS last_bucket_start

FROM analytics.v_energy_consumption_daily

GROUP BY
    grafana_org_id,
    consumption_month,
    organization_id,
    site_id,
    device_id,
    external_id,
    device_name;


COMMENT ON VIEW analytics.v_energy_consumption_monthly IS
'Monthly reset-aware import and export energy consumption by tenant, site and device.';


-- ----------------------------------------------------------------------------
-- 3. Today consumption KPI by device.
-- ----------------------------------------------------------------------------

CREATE OR REPLACE VIEW analytics.v_energy_consumption_today
WITH
(
    security_barrier = TRUE
)
AS
SELECT
    grafana_org_id,
    organization_id,
    site_id,
    device_id,
    external_id,
    device_name,

    import_consumption_kwh,
    export_consumption_kwh,

    valid_import_intervals,
    valid_export_intervals,

    reset_interval_count,
    gap_interval_count,

    first_bucket_start,
    last_bucket_start

FROM analytics.v_energy_consumption_daily

WHERE consumption_date =
    (now() AT TIME ZONE 'Asia/Kolkata')::DATE;


COMMENT ON VIEW analytics.v_energy_consumption_today IS
'Current India-calendar-day energy consumption by tenant, site and device.';


-- ----------------------------------------------------------------------------
-- 4. Yesterday consumption KPI by device.
-- ----------------------------------------------------------------------------

CREATE OR REPLACE VIEW analytics.v_energy_consumption_yesterday
WITH
(
    security_barrier = TRUE
)
AS
SELECT
    grafana_org_id,
    organization_id,
    site_id,
    device_id,
    external_id,
    device_name,

    import_consumption_kwh,
    export_consumption_kwh,

    valid_import_intervals,
    valid_export_intervals,

    reset_interval_count,
    gap_interval_count,

    first_bucket_start,
    last_bucket_start

FROM analytics.v_energy_consumption_daily

WHERE consumption_date =
    (now() AT TIME ZONE 'Asia/Kolkata')::DATE - 1;


COMMENT ON VIEW analytics.v_energy_consumption_yesterday IS
'Previous India-calendar-day energy consumption by tenant, site and device.';


-- ----------------------------------------------------------------------------
-- 5. Month-to-date consumption KPI by device.
-- ----------------------------------------------------------------------------

CREATE OR REPLACE VIEW analytics.v_energy_consumption_mtd
WITH
(
    security_barrier = TRUE
)
AS
SELECT
    grafana_org_id,
    organization_id,
    site_id,
    device_id,
    external_id,
    device_name,

    SUM(import_consumption_kwh)
        AS import_consumption_kwh,

    SUM(export_consumption_kwh)
        AS export_consumption_kwh,

    SUM(valid_import_intervals)
        AS valid_import_intervals,

    SUM(valid_export_intervals)
        AS valid_export_intervals,

    SUM(reset_interval_count)
        AS reset_interval_count,

    SUM(gap_interval_count)
        AS gap_interval_count,

    MIN(first_bucket_start)
        AS first_bucket_start,

    MAX(last_bucket_start)
        AS last_bucket_start

FROM analytics.v_energy_consumption_daily

WHERE consumption_date >=
    date_trunc(
        'month',
        now() AT TIME ZONE 'Asia/Kolkata'
    )::DATE

  AND consumption_date <=
    (now() AT TIME ZONE 'Asia/Kolkata')::DATE

GROUP BY
    grafana_org_id,
    organization_id,
    site_id,
    device_id,
    external_id,
    device_name;


COMMENT ON VIEW analytics.v_energy_consumption_mtd IS
'Month-to-date India-calendar energy consumption by tenant, site and device.';


-- ----------------------------------------------------------------------------
-- 6. Site-level KPI summary.
--
-- This avoids repeating aggregation logic in Grafana stat panels.
-- ----------------------------------------------------------------------------

CREATE OR REPLACE VIEW analytics.v_energy_consumption_site_kpis
WITH
(
    security_barrier = TRUE
)
AS
WITH today AS
(
    SELECT
        grafana_org_id,
        organization_id,
        site_id,

        SUM(import_consumption_kwh)
            AS today_import_kwh,

        SUM(export_consumption_kwh)
            AS today_export_kwh,

        SUM(reset_interval_count)
            AS today_reset_intervals,

        SUM(gap_interval_count)
            AS today_gap_intervals

    FROM analytics.v_energy_consumption_today

    GROUP BY
        grafana_org_id,
        organization_id,
        site_id
),

yesterday AS
(
    SELECT
        grafana_org_id,
        organization_id,
        site_id,

        SUM(import_consumption_kwh)
            AS yesterday_import_kwh,

        SUM(export_consumption_kwh)
            AS yesterday_export_kwh

    FROM analytics.v_energy_consumption_yesterday

    GROUP BY
        grafana_org_id,
        organization_id,
        site_id
),

mtd AS
(
    SELECT
        grafana_org_id,
        organization_id,
        site_id,

        SUM(import_consumption_kwh)
            AS mtd_import_kwh,

        SUM(export_consumption_kwh)
            AS mtd_export_kwh

    FROM analytics.v_energy_consumption_mtd

    GROUP BY
        grafana_org_id,
        organization_id,
        site_id
),

site_scope AS
(
    SELECT DISTINCT
        grafana_org_id,
        organization_id,
        site_id,
        site_code,
        site_name
    FROM analytics.v_sites
)

SELECT
    ss.grafana_org_id,
    ss.organization_id,
    ss.site_id,
    ss.site_code,
    ss.site_name,

    COALESCE(t.today_import_kwh, 0)
        AS today_import_kwh,

    COALESCE(y.yesterday_import_kwh, 0)
        AS yesterday_import_kwh,

    COALESCE(m.mtd_import_kwh, 0)
        AS mtd_import_kwh,

    COALESCE(t.today_export_kwh, 0)
        AS today_export_kwh,

    COALESCE(y.yesterday_export_kwh, 0)
        AS yesterday_export_kwh,

    COALESCE(m.mtd_export_kwh, 0)
        AS mtd_export_kwh,

    COALESCE(t.today_reset_intervals, 0)
        AS today_reset_intervals,

    COALESCE(t.today_gap_intervals, 0)
        AS today_gap_intervals,

    CASE
        WHEN COALESCE(y.yesterday_import_kwh, 0) = 0
            THEN NULL

        ELSE
            (
                COALESCE(t.today_import_kwh, 0)
                -
                y.yesterday_import_kwh
            )
            /
            y.yesterday_import_kwh
            *
            100.0
    END AS today_vs_yesterday_percent

FROM site_scope ss

LEFT JOIN today t
  ON t.grafana_org_id = ss.grafana_org_id
 AND t.organization_id = ss.organization_id
 AND t.site_id = ss.site_id

LEFT JOIN yesterday y
  ON y.grafana_org_id = ss.grafana_org_id
 AND y.organization_id = ss.organization_id
 AND y.site_id = ss.site_id

LEFT JOIN mtd m
  ON m.grafana_org_id = ss.grafana_org_id
 AND m.organization_id = ss.organization_id
 AND m.site_id = ss.site_id;


COMMENT ON VIEW analytics.v_energy_consumption_site_kpis IS
'Site-level today, yesterday and month-to-date energy KPIs for Grafana stat panels.';


-- ----------------------------------------------------------------------------
-- 7. Lock down and grant only approved access.
-- ----------------------------------------------------------------------------

REVOKE ALL ON
    analytics.v_energy_consumption_daily,
    analytics.v_energy_consumption_monthly,
    analytics.v_energy_consumption_today,
    analytics.v_energy_consumption_yesterday,
    analytics.v_energy_consumption_mtd,
    analytics.v_energy_consumption_site_kpis
FROM PUBLIC;


GRANT SELECT ON
    analytics.v_energy_consumption_daily,
    analytics.v_energy_consumption_monthly,
    analytics.v_energy_consumption_today,
    analytics.v_energy_consumption_yesterday,
    analytics.v_energy_consumption_mtd,
    analytics.v_energy_consumption_site_kpis
TO grafana_reader;
