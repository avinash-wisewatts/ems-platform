-- ============================================================================
-- Migration 037
-- Site-timezone-aware Today / Yesterday / MTD energy compatibility views
--
-- Purpose:
--   Remove the global fixed-timezone calendar assumption from relative energy
--   reporting while preserving the existing public view contracts.
--
-- Source:
--   analytics.v_energy_consumption_daily, whose consumption_date is already
--   calculated in each site's configured timezone.
--
-- No energy calculation or classification occurs here.
-- ============================================================================


-- ============================================================================
-- 1. TODAY
-- ============================================================================

CREATE OR REPLACE VIEW analytics.v_energy_consumption_today
WITH (security_barrier = true)
AS

SELECT
    c.grafana_org_id,
    c.organization_id,
    c.site_id,
    c.device_id,
    c.external_id,
    c.device_name,

    c.import_consumption_kwh,
    c.export_consumption_kwh,

    c.valid_import_intervals,
    c.valid_export_intervals,

    c.reset_interval_count,
    c.gap_interval_count,

    c.first_bucket_start,
    c.last_bucket_start

FROM analytics.v_energy_consumption_daily c

JOIN metadata.sites s
  ON s.id = c.site_id
 AND s.organization_id = c.organization_id

WHERE c.consumption_date =
      (now() AT TIME ZONE s.timezone)::date;


COMMENT ON VIEW analytics.v_energy_consumption_today IS
'Current site-local calendar-day energy consumption by tenant, site and device.';


-- ============================================================================
-- 2. YESTERDAY
-- ============================================================================

CREATE OR REPLACE VIEW analytics.v_energy_consumption_yesterday
WITH (security_barrier = true)
AS

SELECT
    c.grafana_org_id,
    c.organization_id,
    c.site_id,
    c.device_id,
    c.external_id,
    c.device_name,

    c.import_consumption_kwh,
    c.export_consumption_kwh,

    c.valid_import_intervals,
    c.valid_export_intervals,

    c.reset_interval_count,
    c.gap_interval_count,

    c.first_bucket_start,
    c.last_bucket_start

FROM analytics.v_energy_consumption_daily c

JOIN metadata.sites s
  ON s.id = c.site_id
 AND s.organization_id = c.organization_id

WHERE c.consumption_date =
      (now() AT TIME ZONE s.timezone)::date - 1;


COMMENT ON VIEW analytics.v_energy_consumption_yesterday IS
'Previous site-local calendar-day energy consumption by tenant, site and device.';


-- ============================================================================
-- 3. MONTH TO DATE
-- ============================================================================

CREATE OR REPLACE VIEW analytics.v_energy_consumption_mtd
WITH (security_barrier = true)
AS

SELECT
    c.grafana_org_id,
    c.organization_id,
    c.site_id,
    c.device_id,
    c.external_id,
    c.device_name,

    sum(c.import_consumption_kwh)
        AS import_consumption_kwh,

    sum(c.export_consumption_kwh)
        AS export_consumption_kwh,

    sum(c.valid_import_intervals)
        AS valid_import_intervals,

    sum(c.valid_export_intervals)
        AS valid_export_intervals,

    sum(c.reset_interval_count)
        AS reset_interval_count,

    sum(c.gap_interval_count)
        AS gap_interval_count,

    min(c.first_bucket_start)
        AS first_bucket_start,

    max(c.last_bucket_start)
        AS last_bucket_start

FROM analytics.v_energy_consumption_daily c

JOIN metadata.sites s
  ON s.id = c.site_id
 AND s.organization_id = c.organization_id

WHERE c.consumption_date >=
      date_trunc(
          'month',
          now() AT TIME ZONE s.timezone
      )::date

  AND c.consumption_date <=
      (now() AT TIME ZONE s.timezone)::date

GROUP BY
    c.grafana_org_id,
    c.organization_id,
    c.site_id,
    c.device_id,
    c.external_id,
    c.device_name;


COMMENT ON VIEW analytics.v_energy_consumption_mtd IS
'Month-to-date site-local calendar energy consumption by tenant, site and device.';


-- ============================================================================
-- 4. OWNERSHIP / SECURITY
-- ============================================================================

ALTER VIEW analytics.v_energy_consumption_today
OWNER TO ems_admin;

ALTER VIEW analytics.v_energy_consumption_yesterday
OWNER TO ems_admin;

ALTER VIEW analytics.v_energy_consumption_mtd
OWNER TO ems_admin;


REVOKE ALL ON
    analytics.v_energy_consumption_today,
    analytics.v_energy_consumption_yesterday,
    analytics.v_energy_consumption_mtd
FROM PUBLIC;


GRANT SELECT ON
    analytics.v_energy_consumption_today,
    analytics.v_energy_consumption_yesterday,
    analytics.v_energy_consumption_mtd
TO grafana_reader;

