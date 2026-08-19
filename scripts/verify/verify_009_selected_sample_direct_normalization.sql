\echo '=== 009 MIGRATION LEDGER ==='
SELECT migration_id,applied_at,execution_ms
FROM admin.schema_migrations
WHERE migration_id='009_selected_sample_direct_normalization';

\echo '=== NORMALIZER DEFINITION SANITY ==='
SELECT
    position('FROM telemetry.v_normalized_points' in pg_get_functiondef('telemetry.load_normalized_points_incremental(interval)'::regprocedure)) AS normalized_view_from_position,
    position('JOIN telemetry.raw_messages rm' in pg_get_functiondef('telemetry.load_normalized_points_incremental(interval)'::regprocedure)) AS direct_raw_join_position;

\echo '=== NORMALIZATION / RECOVERY JOB SCHEDULE STATE ==='
SELECT job_id,proc_name,schedule_interval,scheduled
FROM timescaledb_information.jobs
WHERE job_id IN (1000,1061)
ORDER BY job_id;

\echo '=== CAPTURE LEDGER ==='
SELECT capture_interval_seconds,status,count(*) AS rows,
       min(bucket_start) AS earliest_bucket,max(bucket_start) AS latest_bucket
FROM telemetry.capture_bucket_samples
GROUP BY capture_interval_seconds,status
ORDER BY capture_interval_seconds,status;
