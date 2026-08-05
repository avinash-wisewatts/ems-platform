\set ON_ERROR_STOP on
\echo '=== ENISCOPE PROFILE COVERAGE ==='
WITH expected(raw_field_name) AS (VALUES ('E'),('E1'),('E2'),('E3'),('Ex'),('Ex1'),('Ex2'),('Ex3'),('RE'),('RE1'),('RE2'),('RE3'),('REx'),('REx1'),('REx2'),('REx3'),('AE'),('AE1'),('AE2'),('AE3'),('P'),('P1'),('P2'),('P3'),('Q'),('Q1'),('Q2'),('Q3'),('S'),('S1'),('S2'),('S3'),('V'),('V1'),('V2'),('V3'),('U'),('U1'),('U2'),('U3'),('I'),('I1'),('I2'),('I3'),('In'),('PF'),('PF1'),('PF2'),('PF3'),('F'),('A1'),('A2'),('A3'),('D'),('D1'),('D2'),('D3'),('C'))
SELECT count(*) AS expected_fields,
       count(pfm.raw_field_name) AS mapped_fields,
       count(*)-count(pfm.raw_field_name) AS missing_fields
FROM expected e
LEFT JOIN config.device_profiles dp ON dp.profile_code='ENERGY_METER_ENISCOPE_V1'
LEFT JOIN config.profile_field_mapping pfm ON pfm.profile_id=dp.id AND pfm.raw_field_name=e.raw_field_name;

\echo '=== MISSING MAPPINGS (must return zero rows) ==='
WITH expected(raw_field_name) AS (VALUES ('E'),('E1'),('E2'),('E3'),('Ex'),('Ex1'),('Ex2'),('Ex3'),('RE'),('RE1'),('RE2'),('RE3'),('REx'),('REx1'),('REx2'),('REx3'),('AE'),('AE1'),('AE2'),('AE3'),('P'),('P1'),('P2'),('P3'),('Q'),('Q1'),('Q2'),('Q3'),('S'),('S1'),('S2'),('S3'),('V'),('V1'),('V2'),('V3'),('U'),('U1'),('U2'),('U3'),('I'),('I1'),('I2'),('I3'),('In'),('PF'),('PF1'),('PF2'),('PF3'),('F'),('A1'),('A2'),('A3'),('D'),('D1'),('D2'),('D3'),('C'))
SELECT e.raw_field_name
FROM expected e
WHERE NOT EXISTS (
 SELECT 1 FROM config.device_profiles dp
 JOIN config.profile_field_mapping pfm ON pfm.profile_id=dp.id
 WHERE dp.profile_code='ENERGY_METER_ENISCOPE_V1' AND pfm.raw_field_name=e.raw_field_name
)
ORDER BY e.raw_field_name;

\echo '=== ENERGY TABLE NEW COLUMNS ==='
SELECT column_name,data_type
FROM information_schema.columns
WHERE table_schema='telemetry' AND table_name='energy_measurements'
  AND column_name IN ('current_thd_total_percent','pulse_count')
ORDER BY column_name;

\echo '=== ROUTE VIEW OUTPUT COLUMNS ==='
SELECT count(*) AS routed_measurement_columns
FROM information_schema.columns
WHERE table_schema='telemetry' AND table_name='v_energy_measurements_route'
  AND column_name IN ('import_energy_total_wh','import_energy_l1_wh','import_energy_l2_wh','import_energy_l3_wh','export_energy_total_wh','export_energy_l1_wh','export_energy_l2_wh','export_energy_l3_wh','reactive_energy_total_varh','reactive_energy_l1_varh','reactive_energy_l2_varh','reactive_energy_l3_varh','reactive_export_energy_total_varh','reactive_export_energy_l1_varh','reactive_export_energy_l2_varh','reactive_export_energy_l3_varh','apparent_energy_total_vah','apparent_energy_l1_vah','apparent_energy_l2_vah','apparent_energy_l3_vah','active_power_total_w','active_power_l1_w','active_power_l2_w','active_power_l3_w','reactive_power_total_var','reactive_power_l1_var','reactive_power_l2_var','reactive_power_l3_var','apparent_power_total_va','apparent_power_l1_va','apparent_power_l2_va','apparent_power_l3_va','voltage_ln_avg_v','voltage_l1_v','voltage_l2_v','voltage_l3_v','voltage_ll_avg_v','voltage_l12_v','voltage_l23_v','voltage_l31_v','current_total_a','current_l1_a','current_l2_a','current_l3_a','neutral_current_a','power_factor_total','power_factor_l1','power_factor_l2','power_factor_l3','frequency_hz','phase_angle_l1_deg','phase_angle_l2_deg','phase_angle_l3_deg','current_thd_total_percent','current_thd_l1_percent','current_thd_l2_percent','current_thd_l3_percent','pulse_count');

\echo '=== CURRENT PIPELINE STATE ==='
SELECT pipeline_name,last_status,last_inserted_rows,last_error,last_completed_at
FROM telemetry.pipeline_state
WHERE pipeline_name='energy_measurements';
