-- ============================================================================
-- Migration 303 post-deploy validation (staging first). READ-ONLY.
--
-- Run after an APPROVED deploy, at least 2 hours later (two sweep runs), and
-- again at 24 hours. One READ ONLY transaction, ROLLBACK at the end; every read
-- is bounded to recent event_time (uncompressed chunks only).
--
-- Expected
--   V1 ledger: 303 applied exactly once.
--   V2 loader md5s: energy ee8c1867c0426587cda0d40467be57a2,
--      environment be09c0efb5cc8f5f819f2bb30b8d5370.
--   V3 one run_routing_late_sweep_job: 1 hour, fixed, phase 31:30 UTC,
--      max_runtime 10 min; last run Success; no failures.
--   V4 checkpoints: both *_late_sweep rows SUCCESS / NO_SOURCE_DATA, each at or
--      behind its forward checkpoint, and within ~1 h 10 min of it.
--   V5 routing runtimes (job_stats, last run) and forward lag: compare with
--      the pre-deploy baseline in the operations plan.
--   V6 completeness, last 3 closed hours: every energy device-minute with
--      normalized data has an energy_measurements row (missing = 0), and every
--      AirSense device-5-minute bucket an environment_measurements row.
--   V7 demand: VALID share of finalized intervals over the last 24 h is not
--      lower than over the 24 h before deploy.
-- ============================================================================
\set ON_ERROR_STOP on
\pset footer off

BEGIN TRANSACTION READ ONLY;
SET LOCAL statement_timeout = '60s';
SET LOCAL lock_timeout = '2s';
SHOW transaction_read_only;

\echo === V1 ledger
SELECT migration_id, checksum_sha256, application_mode
FROM admin.schema_migrations WHERE migration_id LIKE '30%' ORDER BY migration_id;

\echo === V2 loader bodies
SELECT p.proname, md5(replace(p.prosrc, E'\r', '')) AS md5
FROM pg_proc p
WHERE p.oid IN ('telemetry.load_energy_measurements_incremental(interval,interval)'::regprocedure,
                'telemetry.load_environment_measurements_incremental(interval,interval)'::regprocedure)
ORDER BY 1;

\echo === V3 sweep job
SELECT j.job_id, j.schedule_interval, j.fixed_schedule, j.max_runtime, j.config,
       extract(epoch FROM j.initial_start)::bigint % 3600 AS phase_s,
       s.last_run_status, s.last_run_duration, s.total_runs, s.total_failures,
       s.next_start AT TIME ZONE 'UTC' AS next_start_utc
FROM timescaledb_information.jobs j
JOIN timescaledb_information.job_stats s USING (job_id)
WHERE j.proc_schema = 'telemetry' AND j.proc_name = 'run_routing_late_sweep_job';

\echo === V4 checkpoints
SELECT f.pipeline_name, f.last_received_at AT TIME ZONE 'UTC' AS forward_ckpt_utc,
       w.last_received_at AT TIME ZONE 'UTC' AS sweep_ckpt_utc, w.last_status AS sweep_status,
       f.last_received_at - w.last_received_at AS sweep_behind,
       w.last_received_at <= f.last_received_at AS never_ahead
FROM telemetry.pipeline_state f
JOIN telemetry.pipeline_state w ON w.pipeline_name = f.pipeline_name || '_late_sweep'
WHERE f.pipeline_name IN ('energy_measurements', 'environment_measurements');

\echo === V5 routing runtimes and lag
SELECT j.job_id, j.proc_name, j.schedule_interval, s.last_run_status,
       s.last_run_duration, s.total_failures, ps.last_inserted_rows,
       now() - ps.last_received_at AS forward_lag
FROM timescaledb_information.jobs j
JOIN timescaledb_information.job_stats s USING (job_id)
LEFT JOIN telemetry.pipeline_state ps
       ON ps.pipeline_name = CASE j.proc_name WHEN 'run_energy_routing_job' THEN 'energy_measurements'
                                              WHEN 'run_environment_routing_job' THEN 'environment_measurements' END
WHERE j.proc_name IN ('run_energy_routing_job', 'run_environment_routing_job', 'run_routing_late_sweep_job')
ORDER BY j.job_id;

\echo === V6 completeness, last 3 closed hours (missing must be 0)
SELECT date_trunc('hour', now()) - INTERVAL '3 hours' AS v6_from, date_trunc('hour', now()) AS v6_to \gset
WITH energy_src AS (
    SELECT DISTINCT np.device_id, date_bin('1 minute', np.event_time, TIMESTAMPTZ '2000-01-01') AS b
    FROM telemetry.normalized_points np
    JOIN metadata.devices d ON d.id = np.device_id
    JOIN config.device_profiles dp ON dp.id = d.profile_id
    WHERE np.event_time >= :'v6_from' AND np.event_time < :'v6_to'
      AND dp.profile_code = 'ENERGY_METER_ENISCOPE_V1'
      AND np.logical_point = 'ENERGY_IMPORT_TOTAL' AND np.quality_code = 'GOOD'
),
energy_dst AS (
    SELECT DISTINCT device_id, bucket_start AS b FROM telemetry.energy_measurements
    WHERE bucket_start >= :'v6_from' AND bucket_start < :'v6_to'
),
env_src AS (
    SELECT DISTINCT np.device_id, date_bin('5 minutes', np.event_time, TIMESTAMPTZ '2000-01-01') AS b
    FROM telemetry.normalized_points np
    JOIN metadata.devices d ON d.id = np.device_id
    JOIN config.device_profiles dp ON dp.id = d.profile_id
    WHERE np.event_time >= :'v6_from' AND np.event_time < :'v6_to'
      AND dp.profile_code = 'ENVIRONMENT_SENSOR_AIRSENSE_V1'
),
env_dst AS (
    SELECT DISTINCT device_id, bucket_start AS b FROM telemetry.environment_measurements
    WHERE bucket_start >= :'v6_from' AND bucket_start < :'v6_to'
)
SELECT 'energy' AS domain, count(*) AS source_buckets, count(*) FILTER (WHERE d.b IS NULL) AS missing
FROM energy_src s LEFT JOIN energy_dst d USING (device_id, b)
UNION ALL
SELECT 'environment', count(*), count(*) FILTER (WHERE d.b IS NULL)
FROM env_src s LEFT JOIN env_dst d USING (device_id, b);

\echo === V7 demand VALID share (last 24 h vs the 24 h before)
SELECT now() - INTERVAL '48 hours' AS v7_from \gset
SELECT CASE WHEN interval_start >= now() - INTERVAL '24 hours' THEN 'last_24h' ELSE 'previous_24h' END AS period,
       count(*) AS intervals,
       count(*) FILTER (WHERE quality_status = 'VALID') AS valid,
       round(100.0 * count(*) FILTER (WHERE quality_status = 'VALID') / NULLIF(count(*), 0), 1) AS valid_pct
FROM analytics.demand_intervals
WHERE interval_start >= :'v7_from'
GROUP BY 1 ORDER BY 1;

ROLLBACK;
