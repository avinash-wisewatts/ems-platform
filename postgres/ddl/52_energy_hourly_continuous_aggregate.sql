-- ============================================================================
-- File:
--   52_energy_hourly_continuous_aggregate.sql
--
-- Purpose:
--   Create hourly energy telemetry rollups for medium- and long-range Grafana
--   dashboards.
--
-- Source:
--   telemetry.energy_measurements
--
-- Refresh policy:
--   Every 15 minutes
--   Reprocess the previous 7 days
--   Leave the newest 5 minutes outside materialization
-- ============================================================================

CREATE MATERIALIZED VIEW IF NOT EXISTS telemetry.ca_energy_hourly
WITH
(
    timescaledb.continuous
)
AS

SELECT
    time_bucket(
        INTERVAL '1 hour',
        bucket_start
    ) AS bucket_start,

    organization_id,
    site_id,
    device_id,

    COUNT(*)::BIGINT AS sample_count,

    MAX(import_energy_total_wh)
        AS import_energy_total_wh_max,

    MIN(import_energy_total_wh)
        AS import_energy_total_wh_min,

    MAX(export_energy_total_wh)
        AS export_energy_total_wh_max,

    MIN(export_energy_total_wh)
        AS export_energy_total_wh_min,

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

    AVG(active_power_total_w)
        AS active_power_total_w_avg,

    MIN(active_power_total_w)
        AS active_power_total_w_min,

    MAX(active_power_total_w)
        AS active_power_total_w_max,

    AVG(active_power_l1_w)
        AS active_power_l1_w_avg,

    AVG(active_power_l2_w)
        AS active_power_l2_w_avg,

    AVG(active_power_l3_w)
        AS active_power_l3_w_avg,

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

    COUNT(active_power_total_w)::BIGINT
        AS active_power_sample_count,

    COUNT(import_energy_total_wh)::BIGINT
        AS import_energy_sample_count

FROM telemetry.energy_measurements

GROUP BY
    bucket_start,
    organization_id,
    site_id,
    device_id

WITH NO DATA;


SELECT add_continuous_aggregate_policy
(
    'telemetry.ca_energy_hourly'::REGCLASS,

    start_offset      => INTERVAL '7 days',
    end_offset        => INTERVAL '5 minutes',
    schedule_interval => INTERVAL '15 minutes',

    if_not_exists     => TRUE
);
