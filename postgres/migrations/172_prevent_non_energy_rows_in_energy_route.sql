-- ============================================================================
-- Migration:
--   172_prevent_non_energy_rows_in_energy_route.sql
--
-- Purpose:
--   Prevent environmental and other non-energy telemetry from entering the
--   energy routing pipeline merely because it contains valid numeric points.
--
-- Root cause:
--   populated_point_count counted every valid normalized numeric point,
--   regardless of measurement domain.
--
-- Contract:
--   A full-resolution energy route row is emitted only when at least one
--   supported energy output column is populated.
-- ============================================================================

CREATE OR REPLACE VIEW telemetry.v_energy_measurements_full_resolution AS
WITH profile_context AS
(
  SELECT np.*, d.profile_id, dp.profile_code
  FROM telemetry.normalized_points np
  JOIN metadata.devices d ON d.id=np.device_id
  LEFT JOIN config.device_profiles dp ON dp.id=d.profile_id
),
register_scales AS
(
  SELECT pc.*, ers.scale_to_normalized_unit
  FROM profile_context pc
  LEFT JOIN config.energy_register_semantics ers
    ON ers.profile_id=pc.profile_id
   AND ers.logical_point_id=pc.logical_point_id
   AND ers.is_active=TRUE
),
pivoted AS
(
  SELECT
        rs.event_time AS received_at,
        rs.event_time AS source_timestamp,
        rs.organization_id,
        rs.site_id,
        rs.gateway_id,
        rs.device_id,
        NULL::UUID AS asset_id,

        MAX(rs.numeric_value * rs.scale_to_normalized_unit) FILTER (
            WHERE rs.logical_point = 'ENERGY_IMPORT_TOTAL'
              AND rs.quality_code = 'GOOD'
              AND rs.scale_to_normalized_unit IS NOT NULL
        ) AS import_energy_total_wh,

        MAX(rs.numeric_value * rs.scale_to_normalized_unit) FILTER (
            WHERE rs.logical_point = 'ENERGY_IMPORT_L1'
              AND rs.quality_code = 'GOOD'
              AND rs.scale_to_normalized_unit IS NOT NULL
        ) AS import_energy_l1_wh,

        MAX(rs.numeric_value * rs.scale_to_normalized_unit) FILTER (
            WHERE rs.logical_point = 'ENERGY_IMPORT_L2'
              AND rs.quality_code = 'GOOD'
              AND rs.scale_to_normalized_unit IS NOT NULL
        ) AS import_energy_l2_wh,

        MAX(rs.numeric_value * rs.scale_to_normalized_unit) FILTER (
            WHERE rs.logical_point = 'ENERGY_IMPORT_L3'
              AND rs.quality_code = 'GOOD'
              AND rs.scale_to_normalized_unit IS NOT NULL
        ) AS import_energy_l3_wh,

        MAX(rs.numeric_value * rs.scale_to_normalized_unit) FILTER (
            WHERE rs.logical_point = 'ENERGY_EXPORT_TOTAL'
              AND rs.quality_code = 'GOOD'
              AND rs.scale_to_normalized_unit IS NOT NULL
        ) AS export_energy_total_wh,

        MAX(rs.numeric_value * rs.scale_to_normalized_unit) FILTER (
            WHERE rs.logical_point = 'ENERGY_EXPORT_L1'
              AND rs.quality_code = 'GOOD'
              AND rs.scale_to_normalized_unit IS NOT NULL
        ) AS export_energy_l1_wh,

        MAX(rs.numeric_value * rs.scale_to_normalized_unit) FILTER (
            WHERE rs.logical_point = 'ENERGY_EXPORT_L2'
              AND rs.quality_code = 'GOOD'
              AND rs.scale_to_normalized_unit IS NOT NULL
        ) AS export_energy_l2_wh,

        MAX(rs.numeric_value * rs.scale_to_normalized_unit) FILTER (
            WHERE rs.logical_point = 'ENERGY_EXPORT_L3'
              AND rs.quality_code = 'GOOD'
              AND rs.scale_to_normalized_unit IS NOT NULL
        ) AS export_energy_l3_wh,

        MAX(rs.numeric_value * rs.scale_to_normalized_unit) FILTER (
            WHERE rs.logical_point = 'ENERGY_REACTIVE_ENERGY_TOTAL'
              AND rs.quality_code = 'GOOD'
              AND rs.scale_to_normalized_unit IS NOT NULL
        ) AS reactive_energy_total_varh,

        MAX(rs.numeric_value * rs.scale_to_normalized_unit) FILTER (
            WHERE rs.logical_point = 'ENERGY_REACTIVE_ENERGY_L1'
              AND rs.quality_code = 'GOOD'
              AND rs.scale_to_normalized_unit IS NOT NULL
        ) AS reactive_energy_l1_varh,

        MAX(rs.numeric_value * rs.scale_to_normalized_unit) FILTER (
            WHERE rs.logical_point = 'ENERGY_REACTIVE_ENERGY_L2'
              AND rs.quality_code = 'GOOD'
              AND rs.scale_to_normalized_unit IS NOT NULL
        ) AS reactive_energy_l2_varh,

        MAX(rs.numeric_value * rs.scale_to_normalized_unit) FILTER (
            WHERE rs.logical_point = 'ENERGY_REACTIVE_ENERGY_L3'
              AND rs.quality_code = 'GOOD'
              AND rs.scale_to_normalized_unit IS NOT NULL
        ) AS reactive_energy_l3_varh,

        MAX(rs.numeric_value * rs.scale_to_normalized_unit) FILTER (
            WHERE rs.logical_point = 'ENERGY_REACTIVE_EXPORT_TOTAL'
              AND rs.quality_code = 'GOOD'
              AND rs.scale_to_normalized_unit IS NOT NULL
        ) AS reactive_export_energy_total_varh,

        MAX(rs.numeric_value * rs.scale_to_normalized_unit) FILTER (
            WHERE rs.logical_point = 'ENERGY_REACTIVE_EXPORT_L1'
              AND rs.quality_code = 'GOOD'
              AND rs.scale_to_normalized_unit IS NOT NULL
        ) AS reactive_export_energy_l1_varh,

        MAX(rs.numeric_value * rs.scale_to_normalized_unit) FILTER (
            WHERE rs.logical_point = 'ENERGY_REACTIVE_EXPORT_L2'
              AND rs.quality_code = 'GOOD'
              AND rs.scale_to_normalized_unit IS NOT NULL
        ) AS reactive_export_energy_l2_varh,

        MAX(rs.numeric_value * rs.scale_to_normalized_unit) FILTER (
            WHERE rs.logical_point = 'ENERGY_REACTIVE_EXPORT_L3'
              AND rs.quality_code = 'GOOD'
              AND rs.scale_to_normalized_unit IS NOT NULL
        ) AS reactive_export_energy_l3_varh,

        MAX(rs.numeric_value * rs.scale_to_normalized_unit) FILTER (
            WHERE rs.logical_point = 'ENERGY_APPARENT_ENERGY_TOTAL'
              AND rs.quality_code = 'GOOD'
              AND rs.scale_to_normalized_unit IS NOT NULL
        ) AS apparent_energy_total_vah,

        MAX(rs.numeric_value * rs.scale_to_normalized_unit) FILTER (
            WHERE rs.logical_point = 'ENERGY_APPARENT_ENERGY_L1'
              AND rs.quality_code = 'GOOD'
              AND rs.scale_to_normalized_unit IS NOT NULL
        ) AS apparent_energy_l1_vah,

        MAX(rs.numeric_value * rs.scale_to_normalized_unit) FILTER (
            WHERE rs.logical_point = 'ENERGY_APPARENT_ENERGY_L2'
              AND rs.quality_code = 'GOOD'
              AND rs.scale_to_normalized_unit IS NOT NULL
        ) AS apparent_energy_l2_vah,

        MAX(rs.numeric_value * rs.scale_to_normalized_unit) FILTER (
            WHERE rs.logical_point = 'ENERGY_APPARENT_ENERGY_L3'
              AND rs.quality_code = 'GOOD'
              AND rs.scale_to_normalized_unit IS NOT NULL
        ) AS apparent_energy_l3_vah,

        MAX(rs.numeric_value) FILTER (
            WHERE rs.logical_point = 'ENERGY_ACTIVE_POWER_TOTAL'
              AND rs.quality_code = 'GOOD'
              AND rs.profile_code = 'ENERGY_METER_ENISCOPE_V1'
        )::DOUBLE PRECISION AS active_power_total_w,

        MAX(rs.numeric_value) FILTER (
            WHERE rs.logical_point = 'ENERGY_ACTIVE_POWER_L1'
              AND rs.quality_code = 'GOOD'
              AND rs.profile_code = 'ENERGY_METER_ENISCOPE_V1'
        )::DOUBLE PRECISION AS active_power_l1_w,

        MAX(rs.numeric_value) FILTER (
            WHERE rs.logical_point = 'ENERGY_ACTIVE_POWER_L2'
              AND rs.quality_code = 'GOOD'
              AND rs.profile_code = 'ENERGY_METER_ENISCOPE_V1'
        )::DOUBLE PRECISION AS active_power_l2_w,

        MAX(rs.numeric_value) FILTER (
            WHERE rs.logical_point = 'ENERGY_ACTIVE_POWER_L3'
              AND rs.quality_code = 'GOOD'
              AND rs.profile_code = 'ENERGY_METER_ENISCOPE_V1'
        )::DOUBLE PRECISION AS active_power_l3_w,

        MAX(rs.numeric_value) FILTER (
            WHERE rs.logical_point = 'ENERGY_REACTIVE_POWER_TOTAL'
              AND rs.quality_code = 'GOOD'
              AND rs.profile_code = 'ENERGY_METER_ENISCOPE_V1'
        )::DOUBLE PRECISION AS reactive_power_total_var,

        MAX(rs.numeric_value) FILTER (
            WHERE rs.logical_point = 'ENERGY_REACTIVE_POWER_L1'
              AND rs.quality_code = 'GOOD'
              AND rs.profile_code = 'ENERGY_METER_ENISCOPE_V1'
        )::DOUBLE PRECISION AS reactive_power_l1_var,

        MAX(rs.numeric_value) FILTER (
            WHERE rs.logical_point = 'ENERGY_REACTIVE_POWER_L2'
              AND rs.quality_code = 'GOOD'
              AND rs.profile_code = 'ENERGY_METER_ENISCOPE_V1'
        )::DOUBLE PRECISION AS reactive_power_l2_var,

        MAX(rs.numeric_value) FILTER (
            WHERE rs.logical_point = 'ENERGY_REACTIVE_POWER_L3'
              AND rs.quality_code = 'GOOD'
              AND rs.profile_code = 'ENERGY_METER_ENISCOPE_V1'
        )::DOUBLE PRECISION AS reactive_power_l3_var,

        MAX(rs.numeric_value) FILTER (
            WHERE rs.logical_point = 'ENERGY_APPARENT_POWER_TOTAL'
              AND rs.quality_code = 'GOOD'
              AND rs.profile_code = 'ENERGY_METER_ENISCOPE_V1'
        )::DOUBLE PRECISION AS apparent_power_total_va,

        MAX(rs.numeric_value) FILTER (
            WHERE rs.logical_point = 'ENERGY_APPARENT_POWER_L1'
              AND rs.quality_code = 'GOOD'
              AND rs.profile_code = 'ENERGY_METER_ENISCOPE_V1'
        )::DOUBLE PRECISION AS apparent_power_l1_va,

        MAX(rs.numeric_value) FILTER (
            WHERE rs.logical_point = 'ENERGY_APPARENT_POWER_L2'
              AND rs.quality_code = 'GOOD'
              AND rs.profile_code = 'ENERGY_METER_ENISCOPE_V1'
        )::DOUBLE PRECISION AS apparent_power_l2_va,

        MAX(rs.numeric_value) FILTER (
            WHERE rs.logical_point = 'ENERGY_APPARENT_POWER_L3'
              AND rs.quality_code = 'GOOD'
              AND rs.profile_code = 'ENERGY_METER_ENISCOPE_V1'
        )::DOUBLE PRECISION AS apparent_power_l3_va,

        MAX(rs.numeric_value) FILTER (
            WHERE rs.logical_point = 'VOLTAGE_LN_AVG'
              AND rs.quality_code = 'GOOD'
              AND rs.profile_code = 'ENERGY_METER_ENISCOPE_V1'
        )::DOUBLE PRECISION AS voltage_ln_avg_v,

        MAX(rs.numeric_value) FILTER (
            WHERE rs.logical_point = 'VOLTAGE_L1'
              AND rs.quality_code = 'GOOD'
              AND rs.profile_code = 'ENERGY_METER_ENISCOPE_V1'
        )::DOUBLE PRECISION AS voltage_l1_v,

        MAX(rs.numeric_value) FILTER (
            WHERE rs.logical_point = 'VOLTAGE_L2'
              AND rs.quality_code = 'GOOD'
              AND rs.profile_code = 'ENERGY_METER_ENISCOPE_V1'
        )::DOUBLE PRECISION AS voltage_l2_v,

        MAX(rs.numeric_value) FILTER (
            WHERE rs.logical_point = 'VOLTAGE_L3'
              AND rs.quality_code = 'GOOD'
              AND rs.profile_code = 'ENERGY_METER_ENISCOPE_V1'
        )::DOUBLE PRECISION AS voltage_l3_v,

        MAX(rs.numeric_value) FILTER (
            WHERE rs.logical_point = 'VOLTAGE_LL_AVG'
              AND rs.quality_code = 'GOOD'
              AND rs.profile_code = 'ENERGY_METER_ENISCOPE_V1'
        )::DOUBLE PRECISION AS voltage_ll_avg_v,

        MAX(rs.numeric_value) FILTER (
            WHERE rs.logical_point = 'VOLTAGE_L12'
              AND rs.quality_code = 'GOOD'
              AND rs.profile_code = 'ENERGY_METER_ENISCOPE_V1'
        )::DOUBLE PRECISION AS voltage_l12_v,

        MAX(rs.numeric_value) FILTER (
            WHERE rs.logical_point = 'VOLTAGE_L23'
              AND rs.quality_code = 'GOOD'
              AND rs.profile_code = 'ENERGY_METER_ENISCOPE_V1'
        )::DOUBLE PRECISION AS voltage_l23_v,

        MAX(rs.numeric_value) FILTER (
            WHERE rs.logical_point = 'VOLTAGE_L31'
              AND rs.quality_code = 'GOOD'
              AND rs.profile_code = 'ENERGY_METER_ENISCOPE_V1'
        )::DOUBLE PRECISION AS voltage_l31_v,

        MAX(rs.numeric_value) FILTER (
            WHERE rs.logical_point = 'CURRENT_TOTAL'
              AND rs.quality_code = 'GOOD'
              AND rs.profile_code = 'ENERGY_METER_ENISCOPE_V1'
        )::DOUBLE PRECISION AS current_total_a,

        MAX(rs.numeric_value) FILTER (
            WHERE rs.logical_point = 'CURRENT_L1'
              AND rs.quality_code = 'GOOD'
              AND rs.profile_code = 'ENERGY_METER_ENISCOPE_V1'
        )::DOUBLE PRECISION AS current_l1_a,

        MAX(rs.numeric_value) FILTER (
            WHERE rs.logical_point = 'CURRENT_L2'
              AND rs.quality_code = 'GOOD'
              AND rs.profile_code = 'ENERGY_METER_ENISCOPE_V1'
        )::DOUBLE PRECISION AS current_l2_a,

        MAX(rs.numeric_value) FILTER (
            WHERE rs.logical_point = 'CURRENT_L3'
              AND rs.quality_code = 'GOOD'
              AND rs.profile_code = 'ENERGY_METER_ENISCOPE_V1'
        )::DOUBLE PRECISION AS current_l3_a,

        MAX(rs.numeric_value) FILTER (
            WHERE rs.logical_point = 'CURRENT_NEUTRAL'
              AND rs.quality_code = 'GOOD'
              AND rs.profile_code = 'ENERGY_METER_ENISCOPE_V1'
        )::DOUBLE PRECISION AS neutral_current_a,

        MAX(rs.numeric_value) FILTER (
            WHERE rs.logical_point = 'POWER_FACTOR_TOTAL'
              AND rs.quality_code = 'GOOD'
              AND rs.profile_code = 'ENERGY_METER_ENISCOPE_V1'
        )::DOUBLE PRECISION AS power_factor_total,

        MAX(rs.numeric_value) FILTER (
            WHERE rs.logical_point = 'POWER_FACTOR_L1'
              AND rs.quality_code = 'GOOD'
              AND rs.profile_code = 'ENERGY_METER_ENISCOPE_V1'
        )::DOUBLE PRECISION AS power_factor_l1,

        MAX(rs.numeric_value) FILTER (
            WHERE rs.logical_point = 'POWER_FACTOR_L2'
              AND rs.quality_code = 'GOOD'
              AND rs.profile_code = 'ENERGY_METER_ENISCOPE_V1'
        )::DOUBLE PRECISION AS power_factor_l2,

        MAX(rs.numeric_value) FILTER (
            WHERE rs.logical_point = 'POWER_FACTOR_L3'
              AND rs.quality_code = 'GOOD'
              AND rs.profile_code = 'ENERGY_METER_ENISCOPE_V1'
        )::DOUBLE PRECISION AS power_factor_l3,

        MAX(rs.numeric_value) FILTER (
            WHERE rs.logical_point = 'FREQUENCY'
              AND rs.quality_code = 'GOOD'
              AND rs.profile_code = 'ENERGY_METER_ENISCOPE_V1'
        )::DOUBLE PRECISION AS frequency_hz,

        MAX(rs.numeric_value) FILTER (
            WHERE rs.logical_point = 'PHASE_ANGLE_L1'
              AND rs.quality_code = 'GOOD'
              AND rs.profile_code = 'ENERGY_METER_ENISCOPE_V1'
        )::DOUBLE PRECISION AS phase_angle_l1_deg,

        MAX(rs.numeric_value) FILTER (
            WHERE rs.logical_point = 'PHASE_ANGLE_L2'
              AND rs.quality_code = 'GOOD'
              AND rs.profile_code = 'ENERGY_METER_ENISCOPE_V1'
        )::DOUBLE PRECISION AS phase_angle_l2_deg,

        MAX(rs.numeric_value) FILTER (
            WHERE rs.logical_point = 'PHASE_ANGLE_L3'
              AND rs.quality_code = 'GOOD'
              AND rs.profile_code = 'ENERGY_METER_ENISCOPE_V1'
        )::DOUBLE PRECISION AS phase_angle_l3_deg,

        MAX(rs.numeric_value) FILTER (
            WHERE rs.logical_point = 'CURRENT_THD_TOTAL'
              AND rs.quality_code = 'GOOD'
              AND rs.profile_code = 'ENERGY_METER_ENISCOPE_V1'
        )::DOUBLE PRECISION AS current_thd_total_percent,

        MAX(rs.numeric_value) FILTER (
            WHERE rs.logical_point = 'CURRENT_THD_L1'
              AND rs.quality_code = 'GOOD'
              AND rs.profile_code = 'ENERGY_METER_ENISCOPE_V1'
        )::DOUBLE PRECISION AS current_thd_l1_percent,

        MAX(rs.numeric_value) FILTER (
            WHERE rs.logical_point = 'CURRENT_THD_L2'
              AND rs.quality_code = 'GOOD'
              AND rs.profile_code = 'ENERGY_METER_ENISCOPE_V1'
        )::DOUBLE PRECISION AS current_thd_l2_percent,

        MAX(rs.numeric_value) FILTER (
            WHERE rs.logical_point = 'CURRENT_THD_L3'
              AND rs.quality_code = 'GOOD'
              AND rs.profile_code = 'ENERGY_METER_ENISCOPE_V1'
        )::DOUBLE PRECISION AS current_thd_l3_percent,

        MAX(rs.numeric_value) FILTER (
            WHERE rs.logical_point = 'PULSE_COUNT'
              AND rs.quality_code = 'GOOD'
              AND rs.profile_code = 'ENERGY_METER_ENISCOPE_V1'
        )::BIGINT AS pulse_count,

        COUNT(*) FILTER (WHERE rs.quality_code='GOOD' AND rs.numeric_value IS NOT NULL) AS populated_point_count,
        COUNT(*) FILTER (WHERE rs.quality_code='INVALID_NUMERIC') AS invalid_point_count
  FROM register_scales rs
  GROUP BY rs.event_time, rs.organization_id, rs.site_id, rs.gateway_id, rs.device_id
)
SELECT *
FROM pivoted
WHERE num_nonnulls
(
    import_energy_total_wh,
    import_energy_l1_wh,
    import_energy_l2_wh,
    import_energy_l3_wh,
    export_energy_total_wh,
    export_energy_l1_wh,
    export_energy_l2_wh,
    export_energy_l3_wh,
    reactive_energy_total_varh,
    reactive_energy_l1_varh,
    reactive_energy_l2_varh,
    reactive_energy_l3_varh,
    reactive_export_energy_total_varh,
    reactive_export_energy_l1_varh,
    reactive_export_energy_l2_varh,
    reactive_export_energy_l3_varh,
    apparent_energy_total_vah,
    apparent_energy_l1_vah,
    apparent_energy_l2_vah,
    apparent_energy_l3_vah,
    active_power_total_w,
    active_power_l1_w,
    active_power_l2_w,
    active_power_l3_w,
    reactive_power_total_var,
    reactive_power_l1_var,
    reactive_power_l2_var,
    reactive_power_l3_var,
    apparent_power_total_va,
    apparent_power_l1_va,
    apparent_power_l2_va,
    apparent_power_l3_va,
    voltage_ln_avg_v,
    voltage_l1_v,
    voltage_l2_v,
    voltage_l3_v,
    voltage_ll_avg_v,
    voltage_l12_v,
    voltage_l23_v,
    voltage_l31_v,
    current_total_a,
    current_l1_a,
    current_l2_a,
    current_l3_a,
    neutral_current_a,
    power_factor_total,
    power_factor_l1,
    power_factor_l2,
    power_factor_l3,
    frequency_hz,
    phase_angle_l1_deg,
    phase_angle_l2_deg,
    phase_angle_l3_deg,
    current_thd_total_percent,
    current_thd_l1_percent,
    current_thd_l2_percent,
    current_thd_l3_percent,
    pulse_count
) > 0;

COMMENT ON VIEW telemetry.v_energy_measurements_full_resolution IS
'Full-resolution energy route. Rows are emitted only when at least one supported energy-domain output is populated.';
