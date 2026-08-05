\echo '=== POLICY TABLE ==='
SELECT capture_interval_seconds, alignment_mode, late_arrival_tolerance_seconds, is_enabled
FROM config.telemetry_capture_policies
WHERE site_id IS NULL AND effective_to IS NULL;

\echo '=== ALLOWED INTERVAL CHECK ==='
SELECT pg_get_constraintdef(oid)
FROM pg_constraint
WHERE conrelid='config.telemetry_capture_policies'::regclass
  AND pg_get_constraintdef(oid) ILIKE '%capture_interval_seconds%';

\echo '=== ROUTE LAYERS ==='
SELECT to_regclass('telemetry.v_energy_measurements_full_resolution') IS NOT NULL AS energy_full_resolution,
       to_regclass('telemetry.v_energy_measurements_route') IS NOT NULL AS energy_sampled,
       to_regclass('telemetry.v_environment_measurements_full_resolution') IS NOT NULL AS environment_full_resolution,
       to_regclass('telemetry.v_environment_measurements_route') IS NOT NULL AS environment_sampled;

\echo '=== DEFAULT BUCKET RESOLUTION ==='
SELECT capture_interval_seconds, late_arrival_tolerance_seconds, site_timezone, bucket_start
FROM telemetry.resolve_site_capture_bucket(NULL, now());

\echo '=== PIPELINE JOBS ==='
SELECT job_id, proc_name, scheduled
FROM timescaledb_information.jobs
WHERE proc_schema='telemetry'
  AND proc_name IN ('run_energy_routing_job','run_environment_routing_job')
ORDER BY proc_name;

\echo '=== PIPELINE STATE ==='
SELECT pipeline_name,last_status,last_inserted_rows,last_error,last_completed_at
FROM telemetry.pipeline_state
WHERE pipeline_name IN ('energy_measurements','environment_measurements')
ORDER BY pipeline_name;
