\echo '=== NORMALIZED LINEAGE COLUMN ==='
SELECT column_name,data_type FROM information_schema.columns
WHERE table_schema='telemetry' AND table_name='normalized_points' AND column_name='platform_received_at';

\echo '=== ENERGY JOB MUST REMAIN DISABLED ==='
SELECT job_id,proc_name,scheduled,last_run_status
FROM timescaledb_information.jobs j
LEFT JOIN timescaledb_information.job_stats s USING (job_id)
WHERE j.proc_schema='telemetry' AND j.proc_name='run_energy_routing_job';

\echo '=== RECENT NORMALIZED LINEAGE ==='
SELECT event_time,platform_received_at,created_at,device_id
FROM telemetry.normalized_points
WHERE platform_received_at IS NOT NULL
ORDER BY created_at DESC LIMIT 10;

\echo '=== CLOSED ENERGY ROUTE ==='
SELECT bucket_start,received_at,source_timestamp,device_id
FROM telemetry.v_energy_measurements_route
ORDER BY bucket_start DESC LIMIT 10;
