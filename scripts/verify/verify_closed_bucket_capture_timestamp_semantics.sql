\set ON_ERROR_STOP on
\echo '=== DOMAIN TIMESTAMP COLUMNS ==='
SELECT table_name, ordinal_position, column_name, data_type, is_nullable
FROM information_schema.columns
WHERE table_schema='telemetry'
  AND table_name IN ('energy_measurements','environment_measurements')
  AND column_name IN ('bucket_start','received_at','source_timestamp')
ORDER BY table_name, ordinal_position;

\echo '=== HYPERTABLE TIME DIMENSIONS ==='
SELECT hypertable_name, column_name, time_interval
FROM timescaledb_information.dimensions
WHERE hypertable_schema='telemetry'
  AND hypertable_name IN ('energy_measurements','environment_measurements')
ORDER BY hypertable_name;

\echo '=== IDENTITY INDEXES ==='
SELECT tablename,indexname,indexdef
FROM pg_indexes
WHERE schemaname='telemetry'
  AND tablename IN ('energy_measurements','environment_measurements')
  AND (indexname LIKE '%identity%' OR indexname LIKE '%bucket_device%')
ORDER BY tablename,indexname;

\echo '=== CONTINUOUS AGGREGATE SOURCE DEFINITIONS ==='
SELECT view_name, view_definition
FROM timescaledb_information.continuous_aggregates
WHERE hypertable_schema='telemetry'
  AND hypertable_name IN ('energy_measurements','environment_measurements')
ORDER BY view_name;

\echo '=== OPEN BUCKET MUST NOT BE EXPOSED ==='
SELECT count(*) AS open_energy_rows
FROM telemetry.v_energy_measurements_route r
CROSS JOIN LATERAL telemetry.resolve_site_capture_bucket(
    r.site_id, COALESCE(r.source_timestamp,r.received_at)
) b
WHERE b.bucket_start + make_interval(secs=>COALESCE(b.capture_interval_seconds,1)) > clock_timestamp();

\echo '=== RECENT ENERGY SEMANTICS ==='
SELECT bucket_start, received_at, source_timestamp, site_id, device_id
FROM telemetry.energy_measurements
ORDER BY bucket_start DESC
LIMIT 20;

\echo '=== DUPLICATE BUCKET IDENTITIES ==='
SELECT 'energy' AS domain, bucket_start, device_id, count(*) AS rows
FROM telemetry.energy_measurements
WHERE device_id IS NOT NULL
GROUP BY bucket_start,device_id HAVING count(*)>1
UNION ALL
SELECT 'environment', bucket_start, device_id, count(*)
FROM telemetry.environment_measurements
WHERE device_id IS NOT NULL
GROUP BY bucket_start,device_id HAVING count(*)>1;
