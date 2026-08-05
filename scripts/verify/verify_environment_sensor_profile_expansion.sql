\echo '=== PROFILE MAPPINGS (ALL OPTIONAL) ==='
SELECT pfm.raw_field_name, lp.name AS logical_point, pfm.is_required, pfm.display_order
FROM config.profile_field_mapping pfm
JOIN config.device_profiles dp ON dp.id=pfm.profile_id
JOIN metadata.logical_points lp ON lp.id=pfm.logical_point_id
WHERE dp.profile_code='ENVIRONMENT_SENSOR_AIRSENSE_V1'
  AND pfm.raw_field_name IN ('T1','RH','LL','PIR','PIR_t','dis1','ain1','ain2','ain3','ain4','Vbat','Stat')
ORDER BY pfm.display_order;

\echo '=== NEW ENVIRONMENT TABLE COLUMNS ==='
SELECT column_name, data_type, is_nullable
FROM information_schema.columns
WHERE table_schema='telemetry' AND table_name='environment_measurements'
  AND column_name IN
  ('seconds_since_last_pir_event','pulse_input_1_raw','external_input_1_raw',
   'external_input_2_raw','external_input_3_raw','external_input_4_raw','device_status_code')
ORDER BY ordinal_position;

\echo '=== DID/UID MUST NOT BE TABLE COLUMNS ==='
SELECT count(*) = 0 AS no_uid_or_did_columns
FROM information_schema.columns
WHERE table_schema='telemetry' AND table_name='environment_measurements'
  AND column_name IN ('uid','did','device_uid');

\echo '=== RECENT FULL-RESOLUTION ENVIRONMENT ROUTE ==='
SELECT source_timestamp, received_at, device_id,
       temperature_c, humidity_percent, illuminance_lux, occupancy_activity,
       seconds_since_last_pir_event, pulse_input_1_raw,
       external_input_1_raw, external_input_2_raw,
       external_input_3_raw, external_input_4_raw,
       battery_voltage_v, device_status_code
FROM telemetry.v_environment_measurements_full_resolution
ORDER BY source_timestamp DESC
LIMIT 5;

\echo '=== ENVIRONMENT JOB ==='
SELECT j.job_id,j.proc_name,j.scheduled,s.last_run_status,s.last_successful_finish
FROM timescaledb_information.jobs j
LEFT JOIN timescaledb_information.job_stats s USING(job_id)
WHERE j.proc_schema='telemetry' AND j.proc_name='run_environment_routing_job';
