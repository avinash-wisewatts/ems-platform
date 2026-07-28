-- ============================================================================
-- File:
--   71_environment_15min_continuous_aggregate.sql
--
-- Purpose:
--   Create the 15-minute environmental telemetry continuous aggregate.
--
-- Source:
--   telemetry.environment_measurements
--
-- Output:
--   telemetry.ca_environment_15min
--
-- Dimensions:
--   organization_id
--   site_id
--   gateway_id
--   device_id
--   asset_id
--
-- Measurements:
--   temperature
--   humidity
--   illuminance
--   occupancy activity
--   battery voltage
--
-- Refresh policy:
--   Start offset: 2 days
--   End offset:   1 minute
--   Schedule:     every 5 minutes
--
-- The one-minute end offset avoids repeatedly refreshing the currently active
-- ingestion interval.
-- ============================================================================


-- ----------------------------------------------------------------------------
-- 1. Create the continuous aggregate without blocking deployment for a full
--    historical refresh.
-- ----------------------------------------------------------------------------

CREATE MATERIALIZED VIEW IF NOT EXISTS
telemetry.ca_environment_15min

WITH
(
    timescaledb.continuous,
    timescaledb.materialized_only = FALSE
)

AS

SELECT
    time_bucket(
        INTERVAL '15 minutes',
        received_at
    ) AS bucket_start,

    organization_id,
    site_id,
    gateway_id,
    device_id,
    asset_id,

    COUNT(*)::BIGINT
        AS sample_count,


    -- ------------------------------------------------------------------------
    -- Temperature
    -- ------------------------------------------------------------------------

    AVG(temperature_c)
        AS temperature_c_avg,

    MIN(temperature_c)
        AS temperature_c_min,

    MAX(temperature_c)
        AS temperature_c_max,

    COUNT(temperature_c)::BIGINT
        AS temperature_sample_count,


    -- ------------------------------------------------------------------------
    -- Relative humidity
    -- ------------------------------------------------------------------------

    AVG(humidity_percent)
        AS humidity_percent_avg,

    MIN(humidity_percent)
        AS humidity_percent_min,

    MAX(humidity_percent)
        AS humidity_percent_max,

    COUNT(humidity_percent)::BIGINT
        AS humidity_sample_count,


    -- ------------------------------------------------------------------------
    -- Illuminance
    -- ------------------------------------------------------------------------

    AVG(illuminance_lux)
        AS illuminance_lux_avg,

    MIN(illuminance_lux)
        AS illuminance_lux_min,

    MAX(illuminance_lux)
        AS illuminance_lux_max,

    COUNT(illuminance_lux)::BIGINT
        AS illuminance_sample_count,


    -- ------------------------------------------------------------------------
    -- Occupancy activity
    -- ------------------------------------------------------------------------

    AVG(occupancy_activity)
        AS occupancy_activity_avg,

    MIN(occupancy_activity)
        AS occupancy_activity_min,

    MAX(occupancy_activity)
        AS occupancy_activity_max,

    COUNT(occupancy_activity)::BIGINT
        AS occupancy_sample_count,


    -- ------------------------------------------------------------------------
    -- Battery voltage
    -- ------------------------------------------------------------------------

    AVG(battery_voltage_v)
        AS battery_voltage_v_avg,

    MIN(battery_voltage_v)
        AS battery_voltage_v_min,

    MAX(battery_voltage_v)
        AS battery_voltage_v_max,

    COUNT(battery_voltage_v)::BIGINT
        AS battery_sample_count,


    -- ------------------------------------------------------------------------
    -- Future-compatible environmental fields
    -- ------------------------------------------------------------------------

    AVG(pressure_hpa)
        AS pressure_hpa_avg,

    AVG(co2_ppm)
        AS co2_ppm_avg,

    AVG(voc_ppb)
        AS voc_ppb_avg,

    AVG(signal_strength_dbm)
        AS signal_strength_dbm_avg

FROM telemetry.environment_measurements

GROUP BY
    bucket_start,
    organization_id,
    site_id,
    gateway_id,
    device_id,
    asset_id

WITH NO DATA;


COMMENT ON VIEW telemetry.ca_environment_15min IS
'Fifteen-minute environmental telemetry aggregate for operational dashboards and short-range analysis.';


-- ----------------------------------------------------------------------------
-- 2. Add tenant/site/device query indexes.
-- ----------------------------------------------------------------------------

CREATE INDEX IF NOT EXISTS
idx_ca_environment_15min_org_site_time

ON telemetry.ca_environment_15min
(
    organization_id,
    site_id,
    bucket_start DESC
);


CREATE INDEX IF NOT EXISTS
idx_ca_environment_15min_device_time

ON telemetry.ca_environment_15min
(
    device_id,
    bucket_start DESC
);


-- ----------------------------------------------------------------------------
-- 3. Replace the refresh policy idempotently.
-- ----------------------------------------------------------------------------

SELECT remove_continuous_aggregate_policy
(
    'telemetry.ca_environment_15min',
    if_not_exists => TRUE
);


SELECT add_continuous_aggregate_policy
(
    'telemetry.ca_environment_15min',

    start_offset =>
        INTERVAL '2 days',

    end_offset =>
        INTERVAL '1 minute',

    schedule_interval =>
        INTERVAL '5 minutes'
);
