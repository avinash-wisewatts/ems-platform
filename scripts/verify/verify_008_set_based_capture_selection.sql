\echo '=== 008 MIGRATION LEDGER ==='
SELECT migration_id,applied_at,execution_ms
FROM admin.schema_migrations
WHERE migration_id='008_set_based_capture_selection_legacy_recovery';

\echo '=== NORMALIZATION / RECOVERY JOBS ==='
SELECT job_id,proc_name,schedule_interval,max_runtime,scheduled,config
FROM timescaledb_information.jobs
WHERE job_id IN (1000,1061)
ORDER BY job_id;

\echo '=== FAILURE LIFECYCLE ==='
SELECT resolution_status,count(*) AS rows,min(detected_at) AS earliest,max(detected_at) AS latest
FROM telemetry.raw_message_failures
GROUP BY resolution_status
ORDER BY resolution_status;

\echo '=== CAPTURE LEDGER ==='
SELECT capture_interval_seconds,status,count(*) AS rows,
       min(bucket_start) AS earliest_bucket,max(bucket_start) AS latest_bucket
FROM telemetry.capture_bucket_samples
GROUP BY capture_interval_seconds,status
ORDER BY capture_interval_seconds,status;
