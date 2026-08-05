-- ============================================================================
-- 110_enhance_eniscope_energy_profile.sql
--
-- Complete Eniscope MQTT field contract and persist every supported electrical
-- point in telemetry.energy_measurements.
--
-- Confirmed vendor mappings:
--   U1=L1-L2, U2=L2-L3, U3=L3-L1
--   D=system current THD, D1-D3=phase current THD
--   C=cumulative pulse/count register
--
-- Eniscope payload units are already W, Wh, var, varh, VA and VAh. Profile
-- register semantics therefore use scale 1.0 into the energy domain table.
-- ============================================================================

-- Required engineering units for newly formalized logical points.
INSERT INTO config.engineering_units (symbol, description)
VALUES
    ('deg', 'Electrical phase angle in degrees'),
    ('count', 'Cumulative pulse count')
ON CONFLICT (symbol) DO UPDATE SET description = EXCLUDED.description;

-- Complete vendor-neutral logical-point catalog.
WITH required_points(name, description, unit_symbol, data_type) AS
(
  VALUES
    ('ENERGY_IMPORT_L1', 'Phase L1 imported active energy', 'kWh', 'numeric'),
    ('ENERGY_IMPORT_L2', 'Phase L2 imported active energy', 'kWh', 'numeric'),
    ('ENERGY_IMPORT_L3', 'Phase L3 imported active energy', 'kWh', 'numeric'),
    ('ENERGY_EXPORT_L1', 'Phase L1 exported active energy', 'kWh', 'numeric'),
    ('ENERGY_EXPORT_L2', 'Phase L2 exported active energy', 'kWh', 'numeric'),
    ('ENERGY_EXPORT_L3', 'Phase L3 exported active energy', 'kWh', 'numeric'),
    ('ENERGY_REACTIVE_ENERGY_L1', 'Phase L1 reactive energy import', 'kvarh', 'numeric'),
    ('ENERGY_REACTIVE_ENERGY_L2', 'Phase L2 reactive energy import', 'kvarh', 'numeric'),
    ('ENERGY_REACTIVE_ENERGY_L3', 'Phase L3 reactive energy import', 'kvarh', 'numeric'),
    ('ENERGY_REACTIVE_EXPORT_L1', 'Phase L1 reactive energy export', 'kvarh', 'numeric'),
    ('ENERGY_REACTIVE_EXPORT_L2', 'Phase L2 reactive energy export', 'kvarh', 'numeric'),
    ('ENERGY_REACTIVE_EXPORT_L3', 'Phase L3 reactive energy export', 'kvarh', 'numeric'),
    ('ENERGY_APPARENT_ENERGY_L1', 'Phase L1 apparent energy', 'kVAh', 'numeric'),
    ('ENERGY_APPARENT_ENERGY_L2', 'Phase L2 apparent energy', 'kVAh', 'numeric'),
    ('ENERGY_APPARENT_ENERGY_L3', 'Phase L3 apparent energy', 'kVAh', 'numeric'),
    ('ENERGY_REACTIVE_POWER_L1', 'Phase L1 reactive power', 'kvar', 'numeric'),
    ('ENERGY_REACTIVE_POWER_L2', 'Phase L2 reactive power', 'kvar', 'numeric'),
    ('ENERGY_REACTIVE_POWER_L3', 'Phase L3 reactive power', 'kvar', 'numeric'),
    ('ENERGY_APPARENT_POWER_L1', 'Phase L1 apparent power', 'kVA', 'numeric'),
    ('ENERGY_APPARENT_POWER_L2', 'Phase L2 apparent power', 'kVA', 'numeric'),
    ('ENERGY_APPARENT_POWER_L3', 'Phase L3 apparent power', 'kVA', 'numeric'),
    ('VOLTAGE_LN_AVG', 'Average system phase-to-neutral voltage', 'V', 'numeric'),
    ('VOLTAGE_LL_AVG', 'Average system line-to-line voltage', 'V', 'numeric'),
    ('VOLTAGE_L12', 'Line-to-line voltage L1-L2', 'V', 'numeric'),
    ('VOLTAGE_L23', 'Line-to-line voltage L2-L3', 'V', 'numeric'),
    ('VOLTAGE_L31', 'Line-to-line voltage L3-L1', 'V', 'numeric'),
    ('CURRENT_TOTAL', 'System total current', 'A', 'numeric'),
    ('CURRENT_NEUTRAL', 'Neutral current', 'A', 'numeric'),
    ('POWER_FACTOR_L1', 'Phase L1 power factor', 'none', 'numeric'),
    ('POWER_FACTOR_L2', 'Phase L2 power factor', 'none', 'numeric'),
    ('POWER_FACTOR_L3', 'Phase L3 power factor', 'none', 'numeric'),
    ('PHASE_ANGLE_L1', 'Phase L1 angle', 'deg', 'numeric'),
    ('PHASE_ANGLE_L2', 'Phase L2 angle', 'deg', 'numeric'),
    ('PHASE_ANGLE_L3', 'Phase L3 angle', 'deg', 'numeric'),
    ('PULSE_COUNT', 'Cumulative pulse counter', 'count', 'numeric'),
    ('CURRENT_THD_TOTAL', 'System total current harmonic distortion', '%', 'numeric')
)
INSERT INTO metadata.logical_points(name, description, unit_id, data_type)
SELECT rp.name, rp.description, eu.id, rp.data_type
FROM required_points rp
LEFT JOIN config.engineering_units eu ON eu.symbol = rp.unit_symbol
ON CONFLICT (name) DO UPDATE
SET description = EXCLUDED.description,
    unit_id = EXCLUDED.unit_id,
    data_type = EXCLUDED.data_type;

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM config.device_profiles WHERE profile_code='ENERGY_METER_ENISCOPE_V1') THEN
    RAISE EXCEPTION 'Required Eniscope profile ENERGY_METER_ENISCOPE_V1 does not exist';
  END IF;
END $$;

-- Complete reusable profile mapping. All fields are optional because firmware,
-- meter type and channel capabilities can vary.
WITH required_mapping(raw_field_name, logical_point_name, display_order) AS
(
  VALUES
    ('E', 'ENERGY_IMPORT_TOTAL', 1),
    ('E1', 'ENERGY_IMPORT_L1', 2),
    ('E2', 'ENERGY_IMPORT_L2', 3),
    ('E3', 'ENERGY_IMPORT_L3', 4),
    ('Ex', 'ENERGY_EXPORT_TOTAL', 5),
    ('Ex1', 'ENERGY_EXPORT_L1', 6),
    ('Ex2', 'ENERGY_EXPORT_L2', 7),
    ('Ex3', 'ENERGY_EXPORT_L3', 8),
    ('RE', 'ENERGY_REACTIVE_ENERGY_TOTAL', 9),
    ('RE1', 'ENERGY_REACTIVE_ENERGY_L1', 10),
    ('RE2', 'ENERGY_REACTIVE_ENERGY_L2', 11),
    ('RE3', 'ENERGY_REACTIVE_ENERGY_L3', 12),
    ('REx', 'ENERGY_REACTIVE_EXPORT_TOTAL', 13),
    ('REx1', 'ENERGY_REACTIVE_EXPORT_L1', 14),
    ('REx2', 'ENERGY_REACTIVE_EXPORT_L2', 15),
    ('REx3', 'ENERGY_REACTIVE_EXPORT_L3', 16),
    ('AE', 'ENERGY_APPARENT_ENERGY_TOTAL', 17),
    ('AE1', 'ENERGY_APPARENT_ENERGY_L1', 18),
    ('AE2', 'ENERGY_APPARENT_ENERGY_L2', 19),
    ('AE3', 'ENERGY_APPARENT_ENERGY_L3', 20),
    ('P', 'ENERGY_ACTIVE_POWER_TOTAL', 21),
    ('P1', 'ENERGY_ACTIVE_POWER_L1', 22),
    ('P2', 'ENERGY_ACTIVE_POWER_L2', 23),
    ('P3', 'ENERGY_ACTIVE_POWER_L3', 24),
    ('Q', 'ENERGY_REACTIVE_POWER_TOTAL', 25),
    ('Q1', 'ENERGY_REACTIVE_POWER_L1', 26),
    ('Q2', 'ENERGY_REACTIVE_POWER_L2', 27),
    ('Q3', 'ENERGY_REACTIVE_POWER_L3', 28),
    ('S', 'ENERGY_APPARENT_POWER_TOTAL', 29),
    ('S1', 'ENERGY_APPARENT_POWER_L1', 30),
    ('S2', 'ENERGY_APPARENT_POWER_L2', 31),
    ('S3', 'ENERGY_APPARENT_POWER_L3', 32),
    ('V', 'VOLTAGE_LN_AVG', 33),
    ('V1', 'VOLTAGE_L1', 34),
    ('V2', 'VOLTAGE_L2', 35),
    ('V3', 'VOLTAGE_L3', 36),
    ('U', 'VOLTAGE_LL_AVG', 37),
    ('U1', 'VOLTAGE_L12', 38),
    ('U2', 'VOLTAGE_L23', 39),
    ('U3', 'VOLTAGE_L31', 40),
    ('I', 'CURRENT_TOTAL', 41),
    ('I1', 'CURRENT_L1', 42),
    ('I2', 'CURRENT_L2', 43),
    ('I3', 'CURRENT_L3', 44),
    ('In', 'CURRENT_NEUTRAL', 45),
    ('PF', 'POWER_FACTOR_TOTAL', 46),
    ('PF1', 'POWER_FACTOR_L1', 47),
    ('PF2', 'POWER_FACTOR_L2', 48),
    ('PF3', 'POWER_FACTOR_L3', 49),
    ('F', 'FREQUENCY', 50),
    ('A1', 'PHASE_ANGLE_L1', 51),
    ('A2', 'PHASE_ANGLE_L2', 52),
    ('A3', 'PHASE_ANGLE_L3', 53),
    ('D', 'CURRENT_THD_TOTAL', 54),
    ('D1', 'CURRENT_THD_L1', 55),
    ('D2', 'CURRENT_THD_L2', 56),
    ('D3', 'CURRENT_THD_L3', 57),
    ('C', 'PULSE_COUNT', 58)
)
INSERT INTO config.profile_field_mapping
(profile_id, raw_field_name, logical_point_id, json_path, transform_expression, is_required, display_order)
SELECT dp.id, rm.raw_field_name, lp.id, NULL, NULL, FALSE, rm.display_order
FROM required_mapping rm
JOIN config.device_profiles dp ON dp.profile_code='ENERGY_METER_ENISCOPE_V1'
JOIN metadata.logical_points lp ON lp.name=rm.logical_point_name
ON CONFLICT (profile_id, raw_field_name) DO UPDATE
SET logical_point_id=EXCLUDED.logical_point_id,
    json_path=EXCLUDED.json_path,
    transform_expression=EXCLUDED.transform_expression,
    is_required=EXCLUDED.is_required,
    display_order=EXCLUDED.display_order;

-- Complete cumulative-register semantics for total and phase registers.
WITH required_semantics
(logical_point_name, source_unit_symbol, normalized_unit_symbol, scale_to_normalized_unit,
 counter_direction, rollover_behavior, rollover_value, reset_behavior,
 flow_interpretation, expected_max_interval_delta) AS
(
  VALUES
    ('ENERGY_IMPORT_TOTAL', 'Wh', 'Wh', 1.0, 'INCREASING', 'NONE', NULL::NUMERIC, 'REJECT_DELTA', 'GRID_IMPORT', 1000000.0),
    ('ENERGY_IMPORT_L1', 'Wh', 'Wh', 1.0, 'INCREASING', 'NONE', NULL::NUMERIC, 'REJECT_DELTA', 'GRID_IMPORT', 1000000.0),
    ('ENERGY_IMPORT_L2', 'Wh', 'Wh', 1.0, 'INCREASING', 'NONE', NULL::NUMERIC, 'REJECT_DELTA', 'GRID_IMPORT', 1000000.0),
    ('ENERGY_IMPORT_L3', 'Wh', 'Wh', 1.0, 'INCREASING', 'NONE', NULL::NUMERIC, 'REJECT_DELTA', 'GRID_IMPORT', 1000000.0),
    ('ENERGY_EXPORT_TOTAL', 'Wh', 'Wh', 1.0, 'INCREASING', 'NONE', NULL::NUMERIC, 'REJECT_DELTA', 'GRID_EXPORT', 1000000.0),
    ('ENERGY_EXPORT_L1', 'Wh', 'Wh', 1.0, 'INCREASING', 'NONE', NULL::NUMERIC, 'REJECT_DELTA', 'GRID_EXPORT', 1000000.0),
    ('ENERGY_EXPORT_L2', 'Wh', 'Wh', 1.0, 'INCREASING', 'NONE', NULL::NUMERIC, 'REJECT_DELTA', 'GRID_EXPORT', 1000000.0),
    ('ENERGY_EXPORT_L3', 'Wh', 'Wh', 1.0, 'INCREASING', 'NONE', NULL::NUMERIC, 'REJECT_DELTA', 'GRID_EXPORT', 1000000.0),
    ('ENERGY_REACTIVE_ENERGY_TOTAL', 'varh', 'varh', 1.0, 'INCREASING', 'NONE', NULL::NUMERIC, 'REJECT_DELTA', 'REACTIVE_IMPORT', 1000000.0),
    ('ENERGY_REACTIVE_ENERGY_L1', 'varh', 'varh', 1.0, 'INCREASING', 'NONE', NULL::NUMERIC, 'REJECT_DELTA', 'REACTIVE_IMPORT', 1000000.0),
    ('ENERGY_REACTIVE_ENERGY_L2', 'varh', 'varh', 1.0, 'INCREASING', 'NONE', NULL::NUMERIC, 'REJECT_DELTA', 'REACTIVE_IMPORT', 1000000.0),
    ('ENERGY_REACTIVE_ENERGY_L3', 'varh', 'varh', 1.0, 'INCREASING', 'NONE', NULL::NUMERIC, 'REJECT_DELTA', 'REACTIVE_IMPORT', 1000000.0),
    ('ENERGY_REACTIVE_EXPORT_TOTAL', 'varh', 'varh', 1.0, 'INCREASING', 'NONE', NULL::NUMERIC, 'REJECT_DELTA', 'REACTIVE_EXPORT', 1000000.0),
    ('ENERGY_REACTIVE_EXPORT_L1', 'varh', 'varh', 1.0, 'INCREASING', 'NONE', NULL::NUMERIC, 'REJECT_DELTA', 'REACTIVE_EXPORT', 1000000.0),
    ('ENERGY_REACTIVE_EXPORT_L2', 'varh', 'varh', 1.0, 'INCREASING', 'NONE', NULL::NUMERIC, 'REJECT_DELTA', 'REACTIVE_EXPORT', 1000000.0),
    ('ENERGY_REACTIVE_EXPORT_L3', 'varh', 'varh', 1.0, 'INCREASING', 'NONE', NULL::NUMERIC, 'REJECT_DELTA', 'REACTIVE_EXPORT', 1000000.0),
    ('ENERGY_APPARENT_ENERGY_TOTAL', 'VAh', 'VAh', 1.0, 'INCREASING', 'NONE', NULL::NUMERIC, 'REJECT_DELTA', 'APPARENT_TOTAL', 1500000.0),
    ('ENERGY_APPARENT_ENERGY_L1', 'VAh', 'VAh', 1.0, 'INCREASING', 'NONE', NULL::NUMERIC, 'REJECT_DELTA', 'APPARENT_TOTAL', 1500000.0),
    ('ENERGY_APPARENT_ENERGY_L2', 'VAh', 'VAh', 1.0, 'INCREASING', 'NONE', NULL::NUMERIC, 'REJECT_DELTA', 'APPARENT_TOTAL', 1500000.0),
    ('ENERGY_APPARENT_ENERGY_L3', 'VAh', 'VAh', 1.0, 'INCREASING', 'NONE', NULL::NUMERIC, 'REJECT_DELTA', 'APPARENT_TOTAL', 1500000.0)
)
INSERT INTO config.energy_register_semantics
(profile_id, logical_point_id, source_unit_symbol, normalized_unit_symbol,
 scale_to_normalized_unit, counter_direction, rollover_behavior, rollover_value,
 reset_behavior, flow_interpretation, expected_max_interval_delta, is_active)
SELECT dp.id, lp.id, rs.source_unit_symbol, rs.normalized_unit_symbol,
       rs.scale_to_normalized_unit, rs.counter_direction, rs.rollover_behavior,
       rs.rollover_value, rs.reset_behavior, rs.flow_interpretation,
       rs.expected_max_interval_delta, TRUE
FROM required_semantics rs
JOIN config.device_profiles dp ON dp.profile_code='ENERGY_METER_ENISCOPE_V1'
JOIN metadata.logical_points lp ON lp.name=rs.logical_point_name
ON CONFLICT (profile_id, logical_point_id) DO UPDATE
SET source_unit_symbol=EXCLUDED.source_unit_symbol,
    normalized_unit_symbol=EXCLUDED.normalized_unit_symbol,
    scale_to_normalized_unit=EXCLUDED.scale_to_normalized_unit,
    counter_direction=EXCLUDED.counter_direction,
    rollover_behavior=EXCLUDED.rollover_behavior,
    rollover_value=EXCLUDED.rollover_value,
    reset_behavior=EXCLUDED.reset_behavior,
    flow_interpretation=EXCLUDED.flow_interpretation,
    expected_max_interval_delta=EXCLUDED.expected_max_interval_delta,
    is_active=TRUE,
    updated_at=now();

-- Only genuinely missing energy-domain columns.
ALTER TABLE telemetry.energy_measurements
  ADD COLUMN IF NOT EXISTS current_thd_total_percent DOUBLE PRECISION,
  ADD COLUMN IF NOT EXISTS pulse_count BIGINT;

COMMENT ON COLUMN telemetry.energy_measurements.current_thd_total_percent IS
'System current total harmonic distortion from Eniscope field D, percent.';
COMMENT ON COLUMN telemetry.energy_measurements.pulse_count IS
'Absolute cumulative pulse/count register from Eniscope field C; interval deltas are derived later.';

-- Complete profile-aware pivot.
DROP VIEW IF EXISTS telemetry.v_energy_measurements_route;
CREATE VIEW telemetry.v_energy_measurements_route AS
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

COMMENT ON VIEW telemetry.v_energy_measurements_route IS
'Complete profile-aware Eniscope energy routing for all documented rtdata fields, including phase registers, line-line voltage, phase angle, THD and pulse count.';

-- Complete incremental loader.
CREATE OR REPLACE PROCEDURE telemetry.load_energy_measurements_incremental
(
  p_overlap INTERVAL DEFAULT INTERVAL '15 minutes'
)
LANGUAGE plpgsql
AS $$
DECLARE
  v_pipeline_name CONSTANT TEXT := 'energy_measurements';
  v_previous_checkpoint TIMESTAMPTZ;
  v_window_start TIMESTAMPTZ;
  v_window_end TIMESTAMPTZ;
  v_affected_rows BIGINT := 0;
  v_lock_acquired BOOLEAN;
BEGIN
  IF p_overlap IS NULL OR p_overlap < INTERVAL '0 seconds' THEN
    RAISE EXCEPTION 'p_overlap must be zero or a positive interval; received %', p_overlap;
  END IF;

  SELECT pg_try_advisory_xact_lock(hashtextextended('telemetry.load_energy_measurements_incremental',0))
  INTO v_lock_acquired;
  IF NOT v_lock_acquired THEN
    UPDATE telemetry.pipeline_state SET last_status='SKIPPED_LOCKED',last_error=NULL,updated_at=now()
    WHERE pipeline_name=v_pipeline_name;
    RETURN;
  END IF;

  SELECT last_received_at INTO v_previous_checkpoint
  FROM telemetry.pipeline_state WHERE pipeline_name=v_pipeline_name FOR UPDATE;

  UPDATE telemetry.pipeline_state
  SET last_started_at=clock_timestamp(),last_status='RUNNING',last_error=NULL,updated_at=now()
  WHERE pipeline_name=v_pipeline_name;

  SELECT max(created_at) INTO v_window_end FROM telemetry.normalized_points;
  IF v_window_end IS NULL THEN
    UPDATE telemetry.pipeline_state
    SET last_completed_at=clock_timestamp(),last_inserted_rows=0,last_status='NO_SOURCE_DATA',last_error=NULL,updated_at=now()
    WHERE pipeline_name=v_pipeline_name;
    RETURN;
  END IF;

  v_window_start := CASE WHEN v_previous_checkpoint IS NULL THEN '-infinity'::timestamptz ELSE v_previous_checkpoint-p_overlap END;

  WITH affected_events AS
  (
    SELECT DISTINCT event_time AS received_at, device_id
    FROM telemetry.normalized_points
    WHERE created_at > v_window_start AND created_at <= v_window_end
  )
  INSERT INTO telemetry.energy_measurements
  (
        received_at, source_timestamp, organization_id, site_id, gateway_id, device_id, asset_id,
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
        pulse_count,
        is_estimated
  )
  SELECT
        r.received_at, r.source_timestamp, r.organization_id, r.site_id, r.gateway_id, r.device_id, r.asset_id,
        r.import_energy_total_wh,
        r.import_energy_l1_wh,
        r.import_energy_l2_wh,
        r.import_energy_l3_wh,
        r.export_energy_total_wh,
        r.export_energy_l1_wh,
        r.export_energy_l2_wh,
        r.export_energy_l3_wh,
        r.reactive_energy_total_varh,
        r.reactive_energy_l1_varh,
        r.reactive_energy_l2_varh,
        r.reactive_energy_l3_varh,
        r.reactive_export_energy_total_varh,
        r.reactive_export_energy_l1_varh,
        r.reactive_export_energy_l2_varh,
        r.reactive_export_energy_l3_varh,
        r.apparent_energy_total_vah,
        r.apparent_energy_l1_vah,
        r.apparent_energy_l2_vah,
        r.apparent_energy_l3_vah,
        r.active_power_total_w,
        r.active_power_l1_w,
        r.active_power_l2_w,
        r.active_power_l3_w,
        r.reactive_power_total_var,
        r.reactive_power_l1_var,
        r.reactive_power_l2_var,
        r.reactive_power_l3_var,
        r.apparent_power_total_va,
        r.apparent_power_l1_va,
        r.apparent_power_l2_va,
        r.apparent_power_l3_va,
        r.voltage_ln_avg_v,
        r.voltage_l1_v,
        r.voltage_l2_v,
        r.voltage_l3_v,
        r.voltage_ll_avg_v,
        r.voltage_l12_v,
        r.voltage_l23_v,
        r.voltage_l31_v,
        r.current_total_a,
        r.current_l1_a,
        r.current_l2_a,
        r.current_l3_a,
        r.neutral_current_a,
        r.power_factor_total,
        r.power_factor_l1,
        r.power_factor_l2,
        r.power_factor_l3,
        r.frequency_hz,
        r.phase_angle_l1_deg,
        r.phase_angle_l2_deg,
        r.phase_angle_l3_deg,
        r.current_thd_total_percent,
        r.current_thd_l1_percent,
        r.current_thd_l2_percent,
        r.current_thd_l3_percent,
        r.pulse_count,
        FALSE
  FROM affected_events ae
  JOIN telemetry.v_energy_measurements_route r
    ON r.received_at=ae.received_at AND r.device_id=ae.device_id
  ON CONFLICT (received_at,device_id) DO UPDATE
  SET
        source_timestamp=EXCLUDED.source_timestamp,
        organization_id=EXCLUDED.organization_id,
        site_id=EXCLUDED.site_id,
        gateway_id=EXCLUDED.gateway_id,
        asset_id=COALESCE(EXCLUDED.asset_id,telemetry.energy_measurements.asset_id),
        import_energy_total_wh = COALESCE(EXCLUDED.import_energy_total_wh, telemetry.energy_measurements.import_energy_total_wh),

        import_energy_l1_wh = COALESCE(EXCLUDED.import_energy_l1_wh, telemetry.energy_measurements.import_energy_l1_wh),

        import_energy_l2_wh = COALESCE(EXCLUDED.import_energy_l2_wh, telemetry.energy_measurements.import_energy_l2_wh),

        import_energy_l3_wh = COALESCE(EXCLUDED.import_energy_l3_wh, telemetry.energy_measurements.import_energy_l3_wh),

        export_energy_total_wh = COALESCE(EXCLUDED.export_energy_total_wh, telemetry.energy_measurements.export_energy_total_wh),

        export_energy_l1_wh = COALESCE(EXCLUDED.export_energy_l1_wh, telemetry.energy_measurements.export_energy_l1_wh),

        export_energy_l2_wh = COALESCE(EXCLUDED.export_energy_l2_wh, telemetry.energy_measurements.export_energy_l2_wh),

        export_energy_l3_wh = COALESCE(EXCLUDED.export_energy_l3_wh, telemetry.energy_measurements.export_energy_l3_wh),

        reactive_energy_total_varh = COALESCE(EXCLUDED.reactive_energy_total_varh, telemetry.energy_measurements.reactive_energy_total_varh),

        reactive_energy_l1_varh = COALESCE(EXCLUDED.reactive_energy_l1_varh, telemetry.energy_measurements.reactive_energy_l1_varh),

        reactive_energy_l2_varh = COALESCE(EXCLUDED.reactive_energy_l2_varh, telemetry.energy_measurements.reactive_energy_l2_varh),

        reactive_energy_l3_varh = COALESCE(EXCLUDED.reactive_energy_l3_varh, telemetry.energy_measurements.reactive_energy_l3_varh),

        reactive_export_energy_total_varh = COALESCE(EXCLUDED.reactive_export_energy_total_varh, telemetry.energy_measurements.reactive_export_energy_total_varh),

        reactive_export_energy_l1_varh = COALESCE(EXCLUDED.reactive_export_energy_l1_varh, telemetry.energy_measurements.reactive_export_energy_l1_varh),

        reactive_export_energy_l2_varh = COALESCE(EXCLUDED.reactive_export_energy_l2_varh, telemetry.energy_measurements.reactive_export_energy_l2_varh),

        reactive_export_energy_l3_varh = COALESCE(EXCLUDED.reactive_export_energy_l3_varh, telemetry.energy_measurements.reactive_export_energy_l3_varh),

        apparent_energy_total_vah = COALESCE(EXCLUDED.apparent_energy_total_vah, telemetry.energy_measurements.apparent_energy_total_vah),

        apparent_energy_l1_vah = COALESCE(EXCLUDED.apparent_energy_l1_vah, telemetry.energy_measurements.apparent_energy_l1_vah),

        apparent_energy_l2_vah = COALESCE(EXCLUDED.apparent_energy_l2_vah, telemetry.energy_measurements.apparent_energy_l2_vah),

        apparent_energy_l3_vah = COALESCE(EXCLUDED.apparent_energy_l3_vah, telemetry.energy_measurements.apparent_energy_l3_vah),

        active_power_total_w = COALESCE(EXCLUDED.active_power_total_w, telemetry.energy_measurements.active_power_total_w),

        active_power_l1_w = COALESCE(EXCLUDED.active_power_l1_w, telemetry.energy_measurements.active_power_l1_w),

        active_power_l2_w = COALESCE(EXCLUDED.active_power_l2_w, telemetry.energy_measurements.active_power_l2_w),

        active_power_l3_w = COALESCE(EXCLUDED.active_power_l3_w, telemetry.energy_measurements.active_power_l3_w),

        reactive_power_total_var = COALESCE(EXCLUDED.reactive_power_total_var, telemetry.energy_measurements.reactive_power_total_var),

        reactive_power_l1_var = COALESCE(EXCLUDED.reactive_power_l1_var, telemetry.energy_measurements.reactive_power_l1_var),

        reactive_power_l2_var = COALESCE(EXCLUDED.reactive_power_l2_var, telemetry.energy_measurements.reactive_power_l2_var),

        reactive_power_l3_var = COALESCE(EXCLUDED.reactive_power_l3_var, telemetry.energy_measurements.reactive_power_l3_var),

        apparent_power_total_va = COALESCE(EXCLUDED.apparent_power_total_va, telemetry.energy_measurements.apparent_power_total_va),

        apparent_power_l1_va = COALESCE(EXCLUDED.apparent_power_l1_va, telemetry.energy_measurements.apparent_power_l1_va),

        apparent_power_l2_va = COALESCE(EXCLUDED.apparent_power_l2_va, telemetry.energy_measurements.apparent_power_l2_va),

        apparent_power_l3_va = COALESCE(EXCLUDED.apparent_power_l3_va, telemetry.energy_measurements.apparent_power_l3_va),

        voltage_ln_avg_v = COALESCE(EXCLUDED.voltage_ln_avg_v, telemetry.energy_measurements.voltage_ln_avg_v),

        voltage_l1_v = COALESCE(EXCLUDED.voltage_l1_v, telemetry.energy_measurements.voltage_l1_v),

        voltage_l2_v = COALESCE(EXCLUDED.voltage_l2_v, telemetry.energy_measurements.voltage_l2_v),

        voltage_l3_v = COALESCE(EXCLUDED.voltage_l3_v, telemetry.energy_measurements.voltage_l3_v),

        voltage_ll_avg_v = COALESCE(EXCLUDED.voltage_ll_avg_v, telemetry.energy_measurements.voltage_ll_avg_v),

        voltage_l12_v = COALESCE(EXCLUDED.voltage_l12_v, telemetry.energy_measurements.voltage_l12_v),

        voltage_l23_v = COALESCE(EXCLUDED.voltage_l23_v, telemetry.energy_measurements.voltage_l23_v),

        voltage_l31_v = COALESCE(EXCLUDED.voltage_l31_v, telemetry.energy_measurements.voltage_l31_v),

        current_total_a = COALESCE(EXCLUDED.current_total_a, telemetry.energy_measurements.current_total_a),

        current_l1_a = COALESCE(EXCLUDED.current_l1_a, telemetry.energy_measurements.current_l1_a),

        current_l2_a = COALESCE(EXCLUDED.current_l2_a, telemetry.energy_measurements.current_l2_a),

        current_l3_a = COALESCE(EXCLUDED.current_l3_a, telemetry.energy_measurements.current_l3_a),

        neutral_current_a = COALESCE(EXCLUDED.neutral_current_a, telemetry.energy_measurements.neutral_current_a),

        power_factor_total = COALESCE(EXCLUDED.power_factor_total, telemetry.energy_measurements.power_factor_total),

        power_factor_l1 = COALESCE(EXCLUDED.power_factor_l1, telemetry.energy_measurements.power_factor_l1),

        power_factor_l2 = COALESCE(EXCLUDED.power_factor_l2, telemetry.energy_measurements.power_factor_l2),

        power_factor_l3 = COALESCE(EXCLUDED.power_factor_l3, telemetry.energy_measurements.power_factor_l3),

        frequency_hz = COALESCE(EXCLUDED.frequency_hz, telemetry.energy_measurements.frequency_hz),

        phase_angle_l1_deg = COALESCE(EXCLUDED.phase_angle_l1_deg, telemetry.energy_measurements.phase_angle_l1_deg),

        phase_angle_l2_deg = COALESCE(EXCLUDED.phase_angle_l2_deg, telemetry.energy_measurements.phase_angle_l2_deg),

        phase_angle_l3_deg = COALESCE(EXCLUDED.phase_angle_l3_deg, telemetry.energy_measurements.phase_angle_l3_deg),

        current_thd_total_percent = COALESCE(EXCLUDED.current_thd_total_percent, telemetry.energy_measurements.current_thd_total_percent),

        current_thd_l1_percent = COALESCE(EXCLUDED.current_thd_l1_percent, telemetry.energy_measurements.current_thd_l1_percent),

        current_thd_l2_percent = COALESCE(EXCLUDED.current_thd_l2_percent, telemetry.energy_measurements.current_thd_l2_percent),

        current_thd_l3_percent = COALESCE(EXCLUDED.current_thd_l3_percent, telemetry.energy_measurements.current_thd_l3_percent),

        pulse_count = COALESCE(EXCLUDED.pulse_count, telemetry.energy_measurements.pulse_count),
        is_estimated=FALSE;

  GET DIAGNOSTICS v_affected_rows=ROW_COUNT;
  UPDATE telemetry.pipeline_state
  SET last_received_at=v_window_end,last_completed_at=clock_timestamp(),last_inserted_rows=v_affected_rows,
      last_status='SUCCESS',last_error=NULL,updated_at=now()
  WHERE pipeline_name=v_pipeline_name;
  RAISE NOTICE 'Energy routing succeeded: window=(%, %], affected_rows=%',v_window_start,v_window_end,v_affected_rows;
EXCEPTION WHEN OTHERS THEN
  UPDATE telemetry.pipeline_state
  SET last_completed_at=clock_timestamp(),last_inserted_rows=0,last_status='FAILED',
      last_error=SQLSTATE||': '||SQLERRM,updated_at=now()
  WHERE pipeline_name=v_pipeline_name;
  RAISE;
END;
$$;
