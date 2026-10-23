-- ============================================================================
-- Release D: 24-hour production acceptance of the migration-300 five-minute
-- schedules (READ-ONLY). Same criteria as the staging 24-hour test
-- (staging-optimization-implementation-plan.md §10.13-10.14).
--
-- Baseline (production, read-only, 2026-10-23 13:49:54 UTC, after five
-- 5-minute cycles): total_runs 1000 130,825 / 1001 98,864 / 1012 98,475 /
-- 1044 114,457 / 1063 100,484 / 1083 96,061 / 1062 104,275; failures
-- excluding 1114: 2,840. Run at or after 2026-10-24 13:50 UTC:
--
--   psql -X -v ON_ERROR_STOP=1 -f docs/10-operations/prepared/release-d/post300_24h_acceptance.sql
--
-- Pass:
--   A  each of the six jobs + 288 +/- 1 runs per 24 h (exact: elapsed / 5 min
--      +/- 1); demand 1062 + 96 +/- 1; late sweep 1137 runs hourly.
--   B  failures (excluding 1114) still 2,840; no job errors since 13:00:47 UTC.
--   C  demand finalization p99 <= interval end + 8 min, max <= + 23 min.
--   D  status mix: non-VALID rows explained by gateways with no raw messages
--      (source gaps), not by the pipeline.
--   E  lag at the check: normalized <= 330 s, energy / environment routing
--      <= 450 s, 1-minute tier <= 540 s; 1-minute tier publication delay in
--      the 4:00-8:00 range seen on staging (§10.15).
--   F  energy rows per 5-minute window: no window missing devices except
--      during source gaps from D.
-- ============================================================================
\set ON_ERROR_STOP on
\pset footer off
\set t0 '2026-10-23 13:49:54+00'
\set deploy '2026-10-23 13:00:47+00'

BEGIN TRANSACTION READ ONLY;
SET LOCAL statement_timeout = '60s';
SET LOCAL lock_timeout = '2s';
SET LOCAL TIME ZONE 'UTC';

SELECT now() AS checked_at, round(extract(epoch FROM now() - :'t0'::timestamptz) / 3600, 2) AS hours_since_baseline;

\echo === A runs since the baseline
WITH base(job_id, runs0, interval_s) AS (VALUES
    (1000, 130825, 300), (1001, 98864, 300), (1012, 98475, 300), (1044, 114457, 300),
    (1063, 100484, 300), (1083, 96061, 300), (1062, 104275, 900))
SELECT b.job_id, coalesce(j.hypertable_name, j.proc_name) AS job, j.schedule_interval,
       s.total_runs - b.runs0 AS runs,
       floor(extract(epoch FROM now() - :'t0'::timestamptz) / b.interval_s)::int AS expected,
       abs((s.total_runs - b.runs0) - floor(extract(epoch FROM now() - :'t0'::timestamptz) / b.interval_s)) <= 1 AS ok,
       s.total_failures, s.last_run_status, s.last_run_duration
FROM base b
JOIN timescaledb_information.jobs j ON j.job_id = b.job_id
JOIN timescaledb_information.job_stats s ON s.job_id = b.job_id
ORDER BY b.job_id;

SELECT j.job_id, j.proc_name, s.total_runs, s.total_failures, s.last_run_status, s.last_run_started_at
FROM timescaledb_information.jobs j JOIN timescaledb_information.job_stats s USING (job_id)
WHERE j.proc_name = 'run_routing_late_sweep_job';

\echo === B failures and job errors
SELECT sum(total_failures) FILTER (WHERE job_id <> 1114) AS failures_excl_1114,
       count(*) FILTER (WHERE last_run_status = 'Failed') AS jobs_failing
FROM timescaledb_information.job_stats;
SELECT job_id, proc_name, start_time, sqlerrcode, left(err_message, 120) AS err_message
FROM timescaledb_information.job_errors
WHERE start_time >= :'deploy'::timestamptz
ORDER BY start_time;

\echo === C demand finalization latency (interval ends after the baseline)
SELECT count(DISTINCT interval_end) AS interval_ends, count(*) AS rows,
       percentile_cont(0.5) WITHIN GROUP (ORDER BY extract(epoch FROM finalized_at - interval_end)) * interval '1 second' AS p50,
       percentile_cont(0.99) WITHIN GROUP (ORDER BY extract(epoch FROM finalized_at - interval_end)) * interval '1 second' AS p99,
       max(finalized_at - interval_end) AS max,
       count(*) FILTER (WHERE finalized_at - interval_end > interval '8 minutes') AS over_8_min
FROM analytics.demand_intervals
WHERE interval_end > :'t0'::timestamptz AND interval_end <= now() - interval '10 minutes';

\echo === D status mix: since the baseline vs the 24 h before the deploy
SELECT CASE WHEN interval_start >= :'t0'::timestamptz THEN 'after' ELSE 'before' END AS period,
       count(*) AS rows,
       round(100.0 * count(*) FILTER (WHERE quality_status = 'VALID') / count(*), 2) AS valid_pct,
       count(*) FILTER (WHERE quality_status = 'INCOMPLETE') AS incomplete,
       count(*) FILTER (WHERE quality_status = 'NO_DATA') AS no_data
FROM analytics.demand_intervals
WHERE (interval_start >= :'t0'::timestamptz AND interval_end <= now() - interval '10 minutes')
   OR (interval_start >= :'deploy'::timestamptz - interval '24 hours' AND interval_start < :'deploy'::timestamptz)
GROUP BY 1 ORDER BY 1;

\echo === D non-VALID rows since the baseline, by source gateway and hour
SELECT g.name AS gateway, date_trunc('hour', di.interval_start) AS hour, di.quality_status,
       count(*) AS rows, count(DISTINCT di.asset_id) AS assets
FROM analytics.demand_intervals di
LEFT JOIN metadata.devices d ON d.id = di.source_device_id
LEFT JOIN metadata.gateways g ON g.id = d.gateway_id
WHERE di.interval_start >= :'t0'::timestamptz AND di.interval_end <= now() - interval '10 minutes'
  AND di.quality_status <> 'VALID'
GROUP BY 1, 2, 3 ORDER BY 2, 1;

\echo === D raw messages per gateway per hour since the baseline (source volume)
SELECT split_part(source_topic, '/', 5) AS gateway, date_trunc('hour', received_at) AS hour, count(*) AS raw_messages
FROM telemetry.raw_messages
WHERE received_at >= date_trunc('hour', :'t0'::timestamptz)
GROUP BY 1, 2 ORDER BY 2, 1;

\echo === E lag now and 1-minute tier publication delay since the baseline
SELECT pipeline_name, last_status, round(extract(epoch FROM now() - last_received_at)) AS lag_s
FROM telemetry.pipeline_state
WHERE pipeline_name IN ('normalized_points', 'energy_measurements', 'environment_measurements', 'energy_consumption_1min')
ORDER BY 1;
WITH runs AS (
    SELECT date_trunc('minute', calculated_at) AS published, max(bucket_start) + interval '1 minute' AS newest_bucket_end
    FROM analytics.energy_consumption_1min
    WHERE bucket_start >= :'t0'::timestamptz AND calculated_at >= :'t0'::timestamptz
    GROUP BY 1)
SELECT count(*) AS publications,
       percentile_cont(0.5) WITHIN GROUP (ORDER BY extract(epoch FROM published - newest_bucket_end)) * interval '1 second' AS p50_delay,
       percentile_cont(0.99) WITHIN GROUP (ORDER BY extract(epoch FROM published - newest_bucket_end)) * interval '1 second' AS p99_delay,
       max(published - newest_bucket_end) AS max_delay
FROM runs;

\echo === F energy rows per 5-minute window since the baseline (devices per window)
WITH w AS (
    SELECT date_bin(interval '5 minutes', bucket_start, timestamptz '2000-01-01') AS win,
           count(*) AS rows, count(DISTINCT device_id) AS devices
    FROM telemetry.energy_measurements
    WHERE bucket_start >= :'t0'::timestamptz AND bucket_start < now() - interval '10 minutes'
    GROUP BY 1)
SELECT count(*) AS windows, min(devices) AS min_devices, max(devices) AS max_devices,
       min(rows) AS min_rows, max(rows) AS max_rows,
       count(*) FILTER (WHERE devices < (SELECT max(devices) FROM w)) AS windows_below_max
FROM w;

ROLLBACK;
