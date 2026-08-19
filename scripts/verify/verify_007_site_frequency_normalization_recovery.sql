\echo '=== 007 MIGRATION LEDGER ==='
SELECT migration_id,applied_at,execution_ms
FROM admin.schema_migrations
WHERE migration_id='007_site_frequency_normalization_recovery';

\echo ''
\echo '=== RAW / FAILURE RETENTION JOBS ==='
SELECT job_id,proc_schema,proc_name,schedule_interval,config
FROM timescaledb_information.jobs
WHERE hypertable_schema='telemetry'
  AND hypertable_name IN ('raw_messages','raw_message_failures')
ORDER BY hypertable_name,job_id;

\echo ''
\echo '=== TELEMETRY PROCESSING JOBS ==='
SELECT job_id,proc_name,schedule_interval,max_runtime,scheduled,config
FROM timescaledb_information.jobs
WHERE proc_schema='telemetry'
  AND proc_name IN
  (
      'run_normalization_job',
      'run_energy_routing_job',
      'run_environment_routing_job',
      'run_raw_message_failure_capture_job',
      'run_raw_receipt_state_job',
      'run_failed_message_recovery_job'
  )
ORDER BY proc_name;

\echo ''
\echo '=== CAPTURE SAMPLE LEDGER ==='
SELECT
    capture_interval_seconds,
    status,
    count(*) AS rows,
    min(bucket_start) AS earliest_bucket,
    max(bucket_start) AS latest_bucket
FROM telemetry.capture_bucket_samples
GROUP BY capture_interval_seconds,status
ORDER BY capture_interval_seconds,status;

\echo ''
\echo '=== RAW RECEIPT VS NORMALIZED STATE ==='
SELECT
    d.id AS device_id,
    d.name AS device_name,
    rs.latest_raw_received_at,
    ts.latest_received_timestamp,
    ts.latest_valid_received_timestamp,
    now()-rs.latest_raw_received_at AS raw_age,
    now()-ts.latest_valid_received_timestamp AS normalized_valid_age
FROM metadata.devices d
LEFT JOIN telemetry.device_raw_receipt_state rs ON rs.device_id=d.id
LEFT JOIN telemetry.device_telemetry_state ts ON ts.device_id=d.id
WHERE rs.device_id IS NOT NULL
ORDER BY rs.latest_raw_received_at DESC;

\echo ''
\echo '=== SITE-FREQUENCY NORMALIZED BUCKET CHECK ==='
WITH sampled AS
(
    SELECT
        s.site_id,
        s.device_id,
        s.capture_interval_seconds,
        s.bucket_start,
        s.event_time,
        lag(s.bucket_start) OVER
        (PARTITION BY s.site_id,s.device_id ORDER BY s.bucket_start) AS previous_bucket
    FROM telemetry.capture_bucket_samples s
    WHERE s.status IN ('NORMALIZED','RECOVERED')
      AND s.bucket_start>=now()-INTERVAL '2 hours'
)
SELECT
    site_id,
    device_id,
    capture_interval_seconds,
    count(*) AS buckets,
    min(extract(epoch FROM bucket_start-previous_bucket)) FILTER (WHERE previous_bucket IS NOT NULL) AS min_gap_seconds,
    max(extract(epoch FROM bucket_start-previous_bucket)) FILTER (WHERE previous_bucket IS NOT NULL) AS max_gap_seconds
FROM sampled
GROUP BY site_id,device_id,capture_interval_seconds
ORDER BY site_id,device_id;

\echo ''
\echo '=== RECOVERY STATUS ==='
SELECT
    resolution_status,
    count(*) AS rows,
    min(raw_received_at) AS earliest,
    max(raw_received_at) AS latest,
    max(last_replay_at) AS latest_replay
FROM telemetry.raw_message_failures
GROUP BY resolution_status
ORDER BY resolution_status;
