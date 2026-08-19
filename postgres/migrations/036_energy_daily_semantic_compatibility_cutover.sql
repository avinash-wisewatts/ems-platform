-- ============================================================================
-- Migration 036
-- Daily energy semantic compatibility cutover
--
-- Purpose:
--   Replace the implementation of analytics.v_energy_consumption_daily with
--   the validated semantic reporting path while preserving its exact
--   15-column public contract and reporting-bucket count semantics.
--
-- Contract rules:
--   * Energy comes from already-classified semantic native intervals.
--   * Valid interval counts remain counts of fully-valid 15-minute buckets.
--   * Reset/gap counts remain counts of affected 15-minute buckets.
--   * first/last bucket timestamps remain 15-minute reporting bucket starts.
--   * Daily boundaries use each site's configured timezone.
--
-- No cumulative-register classification occurs here.
-- ============================================================================


CREATE OR REPLACE VIEW analytics.v_energy_consumption_daily
WITH (security_barrier = true)
AS

SELECT
    r.grafana_org_id,

    (
        r.bucket_start AT TIME ZONE s.timezone
    )::date AS consumption_date,

    r.organization_id,
    r.site_id,
    r.device_id,
    r.external_id,
    r.device_name,

    sum(r.import_consumption_kwh)
        AS import_consumption_kwh,

    sum(r.export_consumption_kwh)
        AS export_consumption_kwh,

    count(*) FILTER
    (
        WHERE r.valid_import_intervals > 0
          AND r.invalid_import_intervals = 0
    ) AS valid_import_intervals,

    count(*) FILTER
    (
        WHERE r.valid_export_intervals > 0
          AND r.invalid_export_intervals = 0
    ) AS valid_export_intervals,

    count(*) FILTER
    (
        WHERE r.reset_interval_count > 0
    ) AS reset_interval_count,

    count(*) FILTER
    (
        WHERE r.gap_interval_count > 0
    ) AS gap_interval_count,

    min(r.bucket_start)
        AS first_bucket_start,

    max(r.bucket_start)
        AS last_bucket_start

FROM analytics.v_energy_reporting_15min r

JOIN metadata.sites s
  ON s.id = r.site_id
 AND s.organization_id = r.organization_id

GROUP BY
    r.grafana_org_id,
    (
        r.bucket_start AT TIME ZONE s.timezone
    )::date,
    r.organization_id,
    r.site_id,
    r.device_id,
    r.external_id,
    r.device_name;


COMMENT ON VIEW analytics.v_energy_consumption_daily IS
'Compatibility daily energy reporting backed by validated native semantic consumption. Preserves the historical 15-column contract and 15-minute reporting-bucket quality-count semantics while using each site configured timezone.';


ALTER VIEW analytics.v_energy_consumption_daily
OWNER TO ems_admin;


REVOKE ALL
ON analytics.v_energy_consumption_daily
FROM PUBLIC;


GRANT SELECT
ON analytics.v_energy_consumption_daily
TO grafana_reader;

