-- ============================================================================
-- File:
--   72_environment_hourly_continuous_aggregate.sql
--
-- Purpose:
--   Create the hourly environmental continuous aggregate directly from the
--   raw environmental hypertable.
--
-- Source:
--   telemetry.environment_measurements
--
-- Output:
--   telemetry.ca_environment_hourly
--
-- Why this reads directly from raw measurements:
--
--   telemetry.ca_environment_15min is configured as a real-time continuous
--   aggregate (materialized_only = FALSE). TimescaleDB does not accept that
--   object as the source time bucket for this hierarchical aggregate.
--
--   Reading directly from the raw hypertable:
--
--     - preserves the real-time 15-minute aggregate;
--     - avoids refresh-order dependencies;
--     - produces exact hourly averages from source samples;
--     - remains database-native and declarative.
--
-- Refresh policy:
--   Start offset: 7 days
--   End offset:   5 minutes
--   Schedule:     every 15 minutes
-- ============================================================================


CREATE MATERIALIZED VIEW IF NOT EXISTS
telemetry.ca_environment_hourly

WITH
(
    timescaledb.continuous,
    timescaledb.materialized_only = FALSE
)

AS

SELECT
    time_bucket(
        INTERVAL '1 hour',
        received_at
    ) AS bucket_start,

    organization_id,
    site_id,
    gateway_id,
    device_id,
    asset_id,


    -- ------------------------------------------------------------------------
    -- Overall source coverage
    -- ------------------------------------------------------------------------

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
    -- Future-compatible optional fields
    -- ------------------------------------------------------------------------

    AVG(pressure_hpa)
        AS pressure_hpa_avg,

    MIN(pressure_hpa)
        AS pressure_hpa_min,

    MAX(pressure_hpa)
        AS pressure_hpa_max,

    COUNT(pressure_hpa)::BIGINT
        AS pressure_sample_count,


    AVG(co2_ppm)
        AS co2_ppm_avg,

    MIN(co2_ppm)
        AS co2_ppm_min,

    MAX(co2_ppm)
        AS co2_ppm_max,

    COUNT(co2_ppm)::BIGINT
        AS co2_sample_count,


    AVG(voc_ppb)
        AS voc_ppb_avg,

    MIN(voc_ppb)
        AS voc_ppb_min,

    MAX(voc_ppb)
        AS voc_ppb_max,

    COUNT(voc_ppb)::BIGINT
        AS voc_sample_count,


    AVG(signal_strength_dbm)
        AS signal_strength_dbm_avg,

    MIN(signal_strength_dbm)
        AS signal_strength_dbm_min,

    MAX(signal_strength_dbm)
        AS signal_strength_dbm_max,

    COUNT(signal_strength_dbm)::BIGINT
        AS signal_strength_sample_count

FROM telemetry.environment_measurements

GROUP BY
    bucket_start,
    organization_id,
    site_id,
    gateway_id,
    device_id,
    asset_id

WITH NO DATA;


COMMENT ON VIEW telemetry.ca_environment_hourly IS
'Hourly environmental aggregate calculated directly from raw environmental measurements.';


-- ----------------------------------------------------------------------------
-- Replace the refresh policy idempotently.
-- ----------------------------------------------------------------------------

SELECT remove_continuous_aggregate_policy
(
    'telemetry.ca_environment_hourly',
    if_not_exists => TRUE
);


SELECT add_continuous_aggregate_policy
(
    'telemetry.ca_environment_hourly',

    start_offset =>
        INTERVAL '7 days',

    end_offset =>
        INTERVAL '5 minutes',

    schedule_interval =>
        INTERVAL '15 minutes'
);
