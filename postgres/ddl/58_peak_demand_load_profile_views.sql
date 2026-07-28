-- ============================================================================
-- File:
--   58_peak_demand_load_profile_views.sql
--
-- Purpose:
--   Create tenant-safe peak-demand and load-profile analytics views.
--
-- Sources:
--   analytics.v_energy_15min
--   analytics.v_energy_hourly
--
-- Demand convention:
--
--   15-minute average demand:
--       active_power_total_w_avg / 1000
--
--   15-minute maximum observed power:
--       active_power_total_w_max / 1000
--
--   Daily and monthly peak demand:
--       maximum 15-minute average demand within the calendar period
--
-- Timezone:
--   Asia/Kolkata
--
-- Multi-tenancy:
--   Every view includes grafana_org_id. Grafana queries must include:
--
--       WHERE grafana_org_id = ${__org.id}
-- ============================================================================


-- ----------------------------------------------------------------------------
-- 1. Fifteen-minute demand series by device.
-- ----------------------------------------------------------------------------

CREATE OR REPLACE VIEW analytics.v_energy_demand_15min
WITH
(
    security_barrier = TRUE
)
AS
SELECT
    ca.grafana_org_id,

    ca.bucket_start,

    ca.organization_id,
    ca.site_id,
    ca.device_id,

    d.external_id,
    d.device_name,

    ca.sample_count,

    ca.active_power_total_w_avg / 1000.0
        AS demand_kw_avg,

    ca.active_power_total_w_min / 1000.0
        AS demand_kw_min,

    ca.active_power_total_w_max / 1000.0
        AS demand_kw_max,

    ca.active_power_sample_count,

    CASE
        WHEN ca.sample_count <= 0
            THEN NULL

        ELSE
            ca.active_power_sample_count::NUMERIC
            /
            ca.sample_count::NUMERIC
            *
            100.0
    END AS power_data_availability_percent

FROM analytics.v_energy_15min ca

JOIN analytics.v_devices d
  ON d.grafana_org_id = ca.grafana_org_id
 AND d.device_id = ca.device_id;


COMMENT ON VIEW analytics.v_energy_demand_15min IS
'Tenant-safe fifteen-minute average, minimum and maximum active demand in kW.';


-- ----------------------------------------------------------------------------
-- 2. Daily peak demand by device.
--
-- Peak demand is the maximum 15-minute average demand in the India calendar
-- day. The associated bucket identifies when the peak occurred.
-- ----------------------------------------------------------------------------

CREATE OR REPLACE VIEW analytics.v_energy_peak_demand_daily
WITH
(
    security_barrier = TRUE
)
AS
WITH ranked AS
(
    SELECT
        d15.grafana_org_id,

        (
            d15.bucket_start AT TIME ZONE 'Asia/Kolkata'
        )::DATE AS demand_date,

        d15.organization_id,
        d15.site_id,
        d15.device_id,

        d15.external_id,
        d15.device_name,

        d15.bucket_start AS peak_bucket_start,
        d15.demand_kw_avg AS peak_demand_kw,

        d15.demand_kw_max AS peak_observed_power_kw,

        d15.sample_count,
        d15.power_data_availability_percent,

        ROW_NUMBER() OVER
        (
            PARTITION BY
                d15.grafana_org_id,
                d15.organization_id,
                d15.site_id,
                d15.device_id,
                (
                    d15.bucket_start
                    AT TIME ZONE 'Asia/Kolkata'
                )::DATE

            ORDER BY
                d15.demand_kw_avg DESC NULLS LAST,
                d15.bucket_start ASC
        ) AS demand_rank

    FROM analytics.v_energy_demand_15min d15
)

SELECT
    grafana_org_id,
    demand_date,

    organization_id,
    site_id,
    device_id,

    external_id,
    device_name,

    peak_bucket_start,
    peak_demand_kw,
    peak_observed_power_kw,

    sample_count,
    power_data_availability_percent

FROM ranked

WHERE demand_rank = 1;


COMMENT ON VIEW analytics.v_energy_peak_demand_daily IS
'Daily peak 15-minute average demand and peak timestamp by tenant, site and device.';


-- ----------------------------------------------------------------------------
-- 3. Monthly peak demand by device.
-- ----------------------------------------------------------------------------

CREATE OR REPLACE VIEW analytics.v_energy_peak_demand_monthly
WITH
(
    security_barrier = TRUE
)
AS
WITH ranked AS
(
    SELECT
        daily.grafana_org_id,

        date_trunc(
            'month',
            daily.demand_date::TIMESTAMP
        )::DATE AS demand_month,

        daily.organization_id,
        daily.site_id,
        daily.device_id,

        daily.external_id,
        daily.device_name,

        daily.demand_date AS peak_demand_date,
        daily.peak_bucket_start,

        daily.peak_demand_kw,
        daily.peak_observed_power_kw,

        daily.power_data_availability_percent,

        ROW_NUMBER() OVER
        (
            PARTITION BY
                daily.grafana_org_id,
                daily.organization_id,
                daily.site_id,
                daily.device_id,
                date_trunc(
                    'month',
                    daily.demand_date::TIMESTAMP
                )::DATE

            ORDER BY
                daily.peak_demand_kw DESC NULLS LAST,
                daily.peak_bucket_start ASC
        ) AS demand_rank

    FROM analytics.v_energy_peak_demand_daily daily
)

SELECT
    grafana_org_id,
    demand_month,

    organization_id,
    site_id,
    device_id,

    external_id,
    device_name,

    peak_demand_date,
    peak_bucket_start,

    peak_demand_kw,
    peak_observed_power_kw,

    power_data_availability_percent

FROM ranked

WHERE demand_rank = 1;


COMMENT ON VIEW analytics.v_energy_peak_demand_monthly IS
'Monthly peak 15-minute average demand and timestamp by tenant, site and device.';


-- ----------------------------------------------------------------------------
-- 4. Hourly time series by device.
--
-- This is the primary medium-range load-profile series for Grafana.
-- ----------------------------------------------------------------------------

CREATE OR REPLACE VIEW analytics.v_energy_load_profile_hourly
WITH
(
    security_barrier = TRUE
)
AS
SELECT
    ca.grafana_org_id,

    ca.bucket_start,

    ca.organization_id,
    ca.site_id,
    ca.device_id,

    d.external_id,
    d.device_name,

    ca.sample_count,

    ca.active_power_total_w_avg / 1000.0
        AS demand_kw_avg,

    ca.active_power_total_w_min / 1000.0
        AS demand_kw_min,

    ca.active_power_total_w_max / 1000.0
        AS demand_kw_max,

    ca.power_factor_total_avg,
    ca.frequency_hz_avg,

    ca.active_power_sample_count,

    CASE
        WHEN ca.sample_count <= 0
            THEN NULL

        ELSE
            ca.active_power_sample_count::NUMERIC
            /
            ca.sample_count::NUMERIC
            *
            100.0
    END AS power_data_availability_percent

FROM analytics.v_energy_hourly ca

JOIN analytics.v_devices d
  ON d.grafana_org_id = ca.grafana_org_id
 AND d.device_id = ca.device_id;


COMMENT ON VIEW analytics.v_energy_load_profile_hourly IS
'Tenant-safe hourly active-demand load profile in kW.';


-- ----------------------------------------------------------------------------
-- 5. Average load profile by hour of day.
--
-- Useful for identifying recurring operational demand patterns.
-- ----------------------------------------------------------------------------

CREATE OR REPLACE VIEW analytics.v_energy_load_profile_hour_of_day
WITH
(
    security_barrier = TRUE
)
AS
SELECT
    hp.grafana_org_id,

    hp.organization_id,
    hp.site_id,
    hp.device_id,

    hp.external_id,
    hp.device_name,

    EXTRACT
    (
        HOUR FROM
        hp.bucket_start AT TIME ZONE 'Asia/Kolkata'
    )::INTEGER AS hour_of_day,

    AVG(hp.demand_kw_avg)
        AS average_demand_kw,

    MIN(hp.demand_kw_avg)
        AS minimum_demand_kw,

    MAX(hp.demand_kw_avg)
        AS maximum_demand_kw,

    COUNT(*)::BIGINT
        AS hourly_bucket_count,

    AVG(hp.power_data_availability_percent)
        AS average_data_availability_percent

FROM analytics.v_energy_load_profile_hourly hp

GROUP BY
    hp.grafana_org_id,
    hp.organization_id,
    hp.site_id,
    hp.device_id,
    hp.external_id,
    hp.device_name,
    hour_of_day;


COMMENT ON VIEW analytics.v_energy_load_profile_hour_of_day IS
'Average, minimum and maximum hourly demand grouped by India hour of day.';


-- ----------------------------------------------------------------------------
-- 6. Average load profile by day of week and hour.
--
-- ISO day:
--   1 = Monday
--   7 = Sunday
-- ----------------------------------------------------------------------------

CREATE OR REPLACE VIEW analytics.v_energy_load_profile_week
WITH
(
    security_barrier = TRUE
)
AS
SELECT
    hp.grafana_org_id,

    hp.organization_id,
    hp.site_id,
    hp.device_id,

    hp.external_id,
    hp.device_name,

    EXTRACT
    (
        ISODOW FROM
        hp.bucket_start AT TIME ZONE 'Asia/Kolkata'
    )::INTEGER AS iso_day_of_week,

    CASE EXTRACT
    (
        ISODOW FROM
        hp.bucket_start AT TIME ZONE 'Asia/Kolkata'
    )::INTEGER
        WHEN 1 THEN 'Monday'
        WHEN 2 THEN 'Tuesday'
        WHEN 3 THEN 'Wednesday'
        WHEN 4 THEN 'Thursday'
        WHEN 5 THEN 'Friday'
        WHEN 6 THEN 'Saturday'
        WHEN 7 THEN 'Sunday'
    END AS day_name,

    EXTRACT
    (
        HOUR FROM
        hp.bucket_start AT TIME ZONE 'Asia/Kolkata'
    )::INTEGER AS hour_of_day,

    AVG(hp.demand_kw_avg)
        AS average_demand_kw,

    MIN(hp.demand_kw_avg)
        AS minimum_demand_kw,

    MAX(hp.demand_kw_avg)
        AS maximum_demand_kw,

    COUNT(*)::BIGINT
        AS hourly_bucket_count

FROM analytics.v_energy_load_profile_hourly hp

GROUP BY
    hp.grafana_org_id,
    hp.organization_id,
    hp.site_id,
    hp.device_id,
    hp.external_id,
    hp.device_name,
    iso_day_of_week,
    day_name,
    hour_of_day;


COMMENT ON VIEW analytics.v_energy_load_profile_week IS
'Weekly load-profile matrix by ISO weekday and India hour of day.';


-- ----------------------------------------------------------------------------
-- 7. Site-level demand KPIs.
--
-- Device demands are summed by 15-minute bucket before site peaks are chosen.
-- This avoids incorrectly adding independent device peaks that occurred at
-- different times.
-- ----------------------------------------------------------------------------

CREATE OR REPLACE VIEW analytics.v_energy_site_demand_kpis
WITH
(
    security_barrier = TRUE
)
AS
WITH site_interval_demand AS
(
    SELECT
        d15.grafana_org_id,

        d15.organization_id,
        d15.site_id,

        d15.bucket_start,

        SUM(d15.demand_kw_avg)
            AS site_demand_kw,

        SUM(d15.demand_kw_max)
            AS site_observed_power_kw,

        AVG(d15.power_data_availability_percent)
            AS average_data_availability_percent

    FROM analytics.v_energy_demand_15min d15

    GROUP BY
        d15.grafana_org_id,
        d15.organization_id,
        d15.site_id,
        d15.bucket_start
),

ranked_daily AS
(
    SELECT
        sid.*,

        (
            sid.bucket_start AT TIME ZONE 'Asia/Kolkata'
        )::DATE AS demand_date,

        ROW_NUMBER() OVER
        (
            PARTITION BY
                sid.grafana_org_id,
                sid.organization_id,
                sid.site_id,
                (
                    sid.bucket_start
                    AT TIME ZONE 'Asia/Kolkata'
                )::DATE

            ORDER BY
                sid.site_demand_kw DESC NULLS LAST,
                sid.bucket_start ASC
        ) AS daily_rank

    FROM site_interval_demand sid
),

daily_peaks AS
(
    SELECT *
    FROM ranked_daily
    WHERE daily_rank = 1
),

ranked_monthly AS
(
    SELECT
        dp.*,

        date_trunc(
            'month',
            dp.demand_date::TIMESTAMP
        )::DATE AS demand_month,

        ROW_NUMBER() OVER
        (
            PARTITION BY
                dp.grafana_org_id,
                dp.organization_id,
                dp.site_id,
                date_trunc(
                    'month',
                    dp.demand_date::TIMESTAMP
                )::DATE

            ORDER BY
                dp.site_demand_kw DESC NULLS LAST,
                dp.bucket_start ASC
        ) AS monthly_rank

    FROM daily_peaks dp
),

today_peak AS
(
    SELECT *
    FROM daily_peaks
    WHERE demand_date =
        (now() AT TIME ZONE 'Asia/Kolkata')::DATE
),

month_peak AS
(
    SELECT *
    FROM ranked_monthly
    WHERE monthly_rank = 1
      AND demand_month =
          date_trunc(
              'month',
              now() AT TIME ZONE 'Asia/Kolkata'
          )::DATE
),

latest_interval AS
(
    SELECT DISTINCT ON
    (
        grafana_org_id,
        organization_id,
        site_id
    )
        grafana_org_id,
        organization_id,
        site_id,

        bucket_start,
        site_demand_kw,
        site_observed_power_kw,
        average_data_availability_percent

    FROM site_interval_demand

    ORDER BY
        grafana_org_id,
        organization_id,
        site_id,
        bucket_start DESC
)

SELECT
    s.grafana_org_id,

    s.organization_id,
    s.site_id,
    s.site_code,
    s.site_name,

    latest.bucket_start
        AS latest_bucket_start,

    COALESCE(latest.site_demand_kw, 0)
        AS latest_site_demand_kw,

    COALESCE(today.site_demand_kw, 0)
        AS today_peak_demand_kw,

    today.bucket_start
        AS today_peak_bucket_start,

    COALESCE(month.site_demand_kw, 0)
        AS month_peak_demand_kw,

    month.bucket_start
        AS month_peak_bucket_start,

    latest.average_data_availability_percent
        AS latest_data_availability_percent

FROM analytics.v_sites s

LEFT JOIN latest_interval latest
  ON latest.grafana_org_id = s.grafana_org_id
 AND latest.organization_id = s.organization_id
 AND latest.site_id = s.site_id

LEFT JOIN today_peak today
  ON today.grafana_org_id = s.grafana_org_id
 AND today.organization_id = s.organization_id
 AND today.site_id = s.site_id

LEFT JOIN month_peak month
  ON month.grafana_org_id = s.grafana_org_id
 AND month.organization_id = s.organization_id
 AND month.site_id = s.site_id;


COMMENT ON VIEW analytics.v_energy_site_demand_kpis IS
'Current, daily peak and month-to-date peak site demand using coincident 15-minute device demand.';


-- ----------------------------------------------------------------------------
-- 8. Least-privilege grants.
-- ----------------------------------------------------------------------------

REVOKE ALL ON
    analytics.v_energy_demand_15min,
    analytics.v_energy_peak_demand_daily,
    analytics.v_energy_peak_demand_monthly,
    analytics.v_energy_load_profile_hourly,
    analytics.v_energy_load_profile_hour_of_day,
    analytics.v_energy_load_profile_week,
    analytics.v_energy_site_demand_kpis
FROM PUBLIC;


GRANT SELECT ON
    analytics.v_energy_demand_15min,
    analytics.v_energy_peak_demand_daily,
    analytics.v_energy_peak_demand_monthly,
    analytics.v_energy_load_profile_hourly,
    analytics.v_energy_load_profile_hour_of_day,
    analytics.v_energy_load_profile_week,
    analytics.v_energy_site_demand_kpis
TO grafana_reader;
