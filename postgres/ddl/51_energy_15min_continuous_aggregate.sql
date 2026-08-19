-- ============================================================================
-- File:
--   51_energy_15min_continuous_aggregate.sql
--
-- Purpose:
--   Create the primary 15-minute energy telemetry continuous aggregate for
--   Grafana dashboards, operational analysis, and downstream rollups.
--
-- Source:
--   telemetry.energy_measurements
--
-- Bucket:
--   15 minutes
--
-- Dimensions:
--   organization_id
--   site_id
--   device_id
--
-- Energy registers:
--   Cumulative energy values are represented using MAX within the bucket.
--   They must not be summed because they are meter registers.
--
-- Interval consumption:
--   Consumption will later be calculated from the difference between
--   consecutive cumulative-register snapshots, with reset/rollover protection.
--
-- Refresh policy:
--   Every 5 minutes
--   Reprocess the previous 2 days
--   Leave the newest 1 minute outside materialization
--
-- The two-day overlap allows late and corrected telemetry to update recent
-- buckets while keeping refresh cost bounded.
-- ============================================================================


-- ----------------------------------------------------------------------------
-- 1. Create the continuous aggregate.
--
-- WITH NO DATA prevents the migration from performing a potentially expensive
-- historical refresh inside the DDL transaction.
-- ----------------------------------------------------------------------------

CREATE MATERIALIZED VIEW IF NOT EXISTS telemetry.ca_energy_15min
WITH
(
    timescaledb.continuous
)
AS

SELECT
    time_bucket
    (
        INTERVAL '15 minutes',
        bucket_start
    ) AS bucket_start,

    organization_id,
    site_id,
    device_id,

    COUNT(*)::BIGINT AS sample_count,


    -- ------------------------------------------------------------------------
    -- Cumulative active-energy registers.
    -- ------------------------------------------------------------------------

    MAX(import_energy_total_wh)
        AS import_energy_total_wh_max,

    MIN(import_energy_total_wh)
        AS import_energy_total_wh_min,

    MAX(export_energy_total_wh)
        AS export_energy_total_wh_max,

    MIN(export_energy_total_wh)
        AS export_energy_total_wh_min,


    -- ------------------------------------------------------------------------
    -- Cumulative reactive/apparent-energy registers.
    -- ------------------------------------------------------------------------

    MAX(reactive_energy_total_varh)
        AS reactive_energy_total_varh_max,

    MIN(reactive_energy_total_varh)
        AS reactive_energy_total_varh_min,

    MAX(reactive_export_energy_total_varh)
        AS reactive_export_energy_total_varh_max,

    MIN(reactive_export_energy_total_varh)
        AS reactive_export_energy_total_varh_min,

    MAX(apparent_energy_total_vah)
        AS apparent_energy_total_vah_max,

    MIN(apparent_energy_total_vah)
        AS apparent_energy_total_vah_min,


    -- ------------------------------------------------------------------------
    -- Total active power.
    -- ------------------------------------------------------------------------

    AVG(active_power_total_w)
        AS active_power_total_w_avg,

    MIN(active_power_total_w)
        AS active_power_total_w_min,

    MAX(active_power_total_w)
        AS active_power_total_w_max,


    -- ------------------------------------------------------------------------
    -- Phase active power.
    -- ------------------------------------------------------------------------

    AVG(active_power_l1_w)
        AS active_power_l1_w_avg,

    AVG(active_power_l2_w)
        AS active_power_l2_w_avg,

    AVG(active_power_l3_w)
        AS active_power_l3_w_avg,


    -- ------------------------------------------------------------------------
    -- Reactive and apparent power.
    -- ------------------------------------------------------------------------

    AVG(reactive_power_total_var)
        AS reactive_power_total_var_avg,

    MIN(reactive_power_total_var)
        AS reactive_power_total_var_min,

    MAX(reactive_power_total_var)
        AS reactive_power_total_var_max,

    AVG(apparent_power_total_va)
        AS apparent_power_total_va_avg,

    MIN(apparent_power_total_va)
        AS apparent_power_total_va_min,

    MAX(apparent_power_total_va)
        AS apparent_power_total_va_max,


    -- ------------------------------------------------------------------------
    -- Voltage.
    -- ------------------------------------------------------------------------

    AVG(voltage_l1_v)
        AS voltage_l1_v_avg,

    MIN(voltage_l1_v)
        AS voltage_l1_v_min,

    MAX(voltage_l1_v)
        AS voltage_l1_v_max,

    AVG(voltage_l2_v)
        AS voltage_l2_v_avg,

    MIN(voltage_l2_v)
        AS voltage_l2_v_min,

    MAX(voltage_l2_v)
        AS voltage_l2_v_max,

    AVG(voltage_l3_v)
        AS voltage_l3_v_avg,

    MIN(voltage_l3_v)
        AS voltage_l3_v_min,

    MAX(voltage_l3_v)
        AS voltage_l3_v_max,


    -- ------------------------------------------------------------------------
    -- Current.
    -- ------------------------------------------------------------------------

    AVG(current_l1_a)
        AS current_l1_a_avg,

    MIN(current_l1_a)
        AS current_l1_a_min,

    MAX(current_l1_a)
        AS current_l1_a_max,

    AVG(current_l2_a)
        AS current_l2_a_avg,

    MIN(current_l2_a)
        AS current_l2_a_min,

    MAX(current_l2_a)
        AS current_l2_a_max,

    AVG(current_l3_a)
        AS current_l3_a_avg,

    MIN(current_l3_a)
        AS current_l3_a_min,

    MAX(current_l3_a)
        AS current_l3_a_max,


    -- ------------------------------------------------------------------------
    -- Power factor and frequency.
    -- ------------------------------------------------------------------------

    AVG(power_factor_total)
        AS power_factor_total_avg,

    MIN(power_factor_total)
        AS power_factor_total_min,

    MAX(power_factor_total)
        AS power_factor_total_max,

    AVG(frequency_hz)
        AS frequency_hz_avg,

    MIN(frequency_hz)
        AS frequency_hz_min,

    MAX(frequency_hz)
        AS frequency_hz_max,


    -- ------------------------------------------------------------------------
    -- Current THD.
    -- ------------------------------------------------------------------------

    AVG(current_thd_l1_percent)
        AS current_thd_l1_percent_avg,

    MAX(current_thd_l1_percent)
        AS current_thd_l1_percent_max,

    AVG(current_thd_l2_percent)
        AS current_thd_l2_percent_avg,

    MAX(current_thd_l2_percent)
        AS current_thd_l2_percent_max,

    AVG(current_thd_l3_percent)
        AS current_thd_l3_percent_avg,

    MAX(current_thd_l3_percent)
        AS current_thd_l3_percent_max,


    -- ------------------------------------------------------------------------
    -- Data availability.
    -- ------------------------------------------------------------------------

    COUNT(active_power_total_w)::BIGINT
        AS active_power_sample_count,

    COUNT(import_energy_total_wh)::BIGINT
        AS import_energy_sample_count,

    COUNT(voltage_l1_v)::BIGINT
        AS voltage_l1_sample_count,

    COUNT(current_l1_a)::BIGINT
        AS current_l1_sample_count

FROM telemetry.energy_measurements

GROUP BY
    bucket_start,
    organization_id,
    site_id,
    device_id

WITH NO DATA;


-- ----------------------------------------------------------------------------
-- 2. Add the refresh policy only when one does not already exist.
-- ----------------------------------------------------------------------------

SELECT add_continuous_aggregate_policy
(
    'telemetry.ca_energy_15min'::REGCLASS,

    start_offset      => INTERVAL '2 days',
    end_offset        => INTERVAL '1 minute',
    schedule_interval => INTERVAL '5 minutes',

    if_not_exists     => TRUE
);
