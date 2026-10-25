-- ============================================================================
-- Release D acceptance over a fixed observation window (READ-ONLY).
--
-- Same criteria as post300_24h_acceptance.sql (kept unchanged: it records the
-- 2026-10-23 baseline), but evaluated over exactly [w0, w1), with the baseline
-- passed in and jobs found by name, so it runs unchanged on staging or
-- production. Get the variables from release_d_window_baseline.sql at w0:
--
--   psql -X -v ON_ERROR_STOP=1 \
--     -v w0='2026-10-25 08:08:44+00' \
--     -v baseline='run_normalization_job=70252,...' \
--     -v failures0=1051 \
--     [-v w1='2026-10-26 08:08:44+00'] \
--     -f docs/10-operations/prepared/release-d/release_d_acceptance_window.sql
--
-- w1 defaults to w0 + 24 h. Run it after w1 and within 48 h of w0: raw-message
-- retention is 48 h, and section D needs raw messages to attribute non-VALID
-- demand to source gaps (the script warns when they are gone).
--
-- Pass (summary at the end; FAIL / CHECK rows need review):
--   A  each job's runs since w0 = elapsed / schedule interval, +/- 1. Counters
--      are read at the time of the check, so the count covers [w0, check time);
--      run it soon after w1. The P11 sampler gives exact counts at w1.
--   B  no job errors with start_time in [w0, w1); no 40P01.
--   C  demand finalization (interval end in (w0, w1]): p99 <= + 8 min,
--      max <= + 23 min; no missing quarter-hour bucket.
--   D  non-VALID demand rows explained by gateways with no raw messages
--      (listed for review: gateway names differ between metadata and topics).
--   E  1-minute tier publication delay within 4:00-8:00 during the window;
--      lag at the check (normalized <= 330 s, routing <= 450 s, 1-minute tier
--      <= 540 s). Lag over the window needs the P11 sampler.
--   F  energy rows per 5-minute window: no window missing devices except
--      during source gaps from D (listed for review).
-- ============================================================================
\set ON_ERROR_STOP on
\pset footer off
\if :{?w0}
\else
  \echo 'w0 is required (window start, timestamptz)'
  \quit
\endif
\if :{?baseline}
\else
  \echo 'baseline is required (role=total_runs,... from release_d_window_baseline.sql)'
  \quit
\endif
\if :{?failures0}
\else
  \echo 'failures0 is required (failure total excluding job 1114 at w0)'
  \quit
\endif
BEGIN TRANSACTION READ ONLY;
SET LOCAL statement_timeout = '60s';
SET LOCAL lock_timeout = '2s';
SET LOCAL TIME ZONE 'UTC';
\if :{?w1}
\else
SELECT to_char(:'w0'::timestamptz + INTERVAL '24 hours', 'YYYY-MM-DD HH24:MI:SS.US+00') AS w1 \gset
\endif
-- Evaluation end: w1, or now if the window has not ended (minus 10 min for demand).
SELECT to_char(LEAST(now(), :'w1'::timestamptz), 'YYYY-MM-DD HH24:MI:SS.US+00') AS we \gset

SELECT now() AS checked_at, :'w0'::timestamptz AS w0, :'w1'::timestamptz AS w1,
       CASE WHEN now() < :'w1'::timestamptz THEN 'INCOMPLETE: the window has not ended; results cover [w0, now)'
            WHEN now() > :'w1'::timestamptz + INTERVAL '30 minutes' THEN 'NOTE: section A also counts runs after w1'
            ELSE 'OK' END AS window_state;

\echo === A runs since w0, by job name
SELECT b.role, j.job_id, j.schedule_interval, s.total_runs - b.runs0 AS runs,
       floor(extract(epoch FROM now() - :'w0'::timestamptz) / extract(epoch FROM j.schedule_interval))::int AS expected,
       abs((s.total_runs - b.runs0)
           - floor(extract(epoch FROM now() - :'w0'::timestamptz) / extract(epoch FROM j.schedule_interval))) <= 1 AS ok,
       s.last_run_status, s.last_run_duration
FROM (SELECT split_part(e, '=', 1) AS role, split_part(e, '=', 2)::bigint AS runs0
      FROM unnest(string_to_array(:'baseline', ',')) AS e) b
LEFT JOIN timescaledb_information.jobs j
       ON (CASE WHEN j.proc_name LIKE 'policy_%' THEN j.proc_name || ':' || j.hypertable_name ELSE j.proc_name END) = b.role
LEFT JOIN timescaledb_information.job_stats s ON s.job_id = j.job_id
ORDER BY b.role;

\echo === B job errors in [w0, w1), failure totals at the check
SELECT j.job_id, e.proc_name, e.sqlerrcode, count(*) AS errors,
       min(e.start_time) AS first, max(e.start_time) AS last,
       round(avg(extract(epoch FROM e.finish_time - e.start_time))::numeric, 1) AS avg_s,
       left(min(e.err_message), 100) AS err_message
FROM timescaledb_information.job_errors e
LEFT JOIN timescaledb_information.jobs j USING (job_id)
WHERE e.start_time >= :'w0'::timestamptz AND e.start_time < :'w1'::timestamptz
GROUP BY 1, 2, 3 ORDER BY 1, 3;
SELECT :failures0 AS failures0,
       sum(total_failures) FILTER (WHERE job_id <> 1114) AS failures_now_excl_1114,
       count(*) FILTER (WHERE last_run_status = 'Failed') AS jobs_last_run_failed,
       string_agg(job_id::text, ',') FILTER (WHERE last_run_status = 'Failed') AS failed_job_ids
FROM timescaledb_information.job_stats;

\echo === C demand finalization (interval end in (w0, w1])
SELECT count(DISTINCT interval_end) AS interval_ends, count(*) AS rows,
       round((percentile_cont(0.5) WITHIN GROUP (ORDER BY extract(epoch FROM finalized_at - interval_end)))::numeric) AS p50_s,
       round((percentile_cont(0.99) WITHIN GROUP (ORDER BY extract(epoch FROM finalized_at - interval_end)))::numeric) AS p99_s,
       round(max(extract(epoch FROM finalized_at - interval_end))::numeric) AS max_s,
       count(*) FILTER (WHERE finalized_at - interval_end > INTERVAL '8 minutes') AS over_8_min
FROM analytics.demand_intervals
WHERE interval_end > :'w0'::timestamptz AND interval_end <= :'we'::timestamptz
  AND interval_end <= now() - INTERVAL '10 minutes';
SELECT interval_end, count(*) AS rows_over_8_min, max(finalized_at - interval_end) AS worst
FROM analytics.demand_intervals
WHERE interval_end > :'w0'::timestamptz AND interval_end <= :'we'::timestamptz
  AND finalized_at - interval_end > INTERVAL '8 minutes'
GROUP BY 1 ORDER BY 1;
SELECT count(*) AS missing_buckets,
       string_agg(to_char(b, 'MM-DD HH24:MI'), ' ' ORDER BY b) AS which
FROM generate_series(date_bin(INTERVAL '15 minutes', :'w0'::timestamptz, TIMESTAMPTZ '2000-01-01') + INTERVAL '15 minutes',
                     LEAST(:'we'::timestamptz, now() - INTERVAL '10 minutes') - INTERVAL '15 minutes',
                     INTERVAL '15 minutes') AS b
WHERE NOT EXISTS (SELECT 1 FROM analytics.demand_intervals d WHERE d.interval_start = b);

\echo === D demand status mix: window vs the 24 h before w0
SELECT CASE WHEN interval_start >= :'w0'::timestamptz THEN '2 window' ELSE '1 24 h before w0' END AS period,
       count(*) AS rows,
       round(100.0 * count(*) FILTER (WHERE quality_status = 'VALID') / nullif(count(*), 0), 2) AS valid_pct,
       count(*) FILTER (WHERE quality_status = 'INCOMPLETE') AS incomplete,
       count(*) FILTER (WHERE quality_status = 'NO_DATA') AS no_data
FROM analytics.demand_intervals
WHERE (interval_end > :'w0'::timestamptz AND interval_end <= :'we'::timestamptz AND interval_end <= now() - INTERVAL '10 minutes')
   OR (interval_start >= :'w0'::timestamptz - INTERVAL '24 hours' AND interval_start < :'w0'::timestamptz)
GROUP BY 1 ORDER BY 1;
\echo === D non-VALID rows in the window, by site, source gateway and status
SELECT s.name AS site, g.name AS gateway, di.quality_status, count(*) AS rows,
       count(DISTINCT di.interval_start) AS buckets, min(di.interval_start) AS first, max(di.interval_start) AS last
FROM analytics.demand_intervals di
LEFT JOIN metadata.assets a ON a.id = di.asset_id
LEFT JOIN metadata.sites s ON s.id = a.site_id
LEFT JOIN metadata.devices d ON d.id = di.source_device_id
LEFT JOIN metadata.gateways g ON g.id = d.gateway_id
WHERE di.interval_end > :'w0'::timestamptz AND di.interval_end <= :'we'::timestamptz
  AND di.interval_end <= now() - INTERVAL '10 minutes' AND di.quality_status <> 'VALID'
GROUP BY 1, 2, 3 ORDER BY 1, 2, 3;
\echo === D raw messages per topic gateway in the window (source volume)
SELECT min(received_at) AS raw_oldest_retained,
       CASE WHEN min(received_at) > :'w0'::timestamptz THEN 'CHECK: raw messages before ' || min(received_at) || ' are gone; section D attribution is partial'
            ELSE 'OK' END AS raw_retention
FROM telemetry.raw_messages;
SELECT split_part(source_topic, '/', 5) AS topic_gateway, count(*) AS raw_messages,
       count(DISTINCT date_trunc('hour', received_at)) AS hours_with_messages
FROM telemetry.raw_messages
WHERE received_at >= :'w0'::timestamptz AND received_at < :'we'::timestamptz
GROUP BY 1 ORDER BY 1;

\echo === E 1-minute tier publication delay in the window; lag at the check
WITH runs AS (
    SELECT date_trunc('minute', calculated_at) AS published, max(bucket_start) + INTERVAL '1 minute' AS newest_bucket_end
    FROM analytics.energy_consumption_1min
    WHERE bucket_start >= :'w0'::timestamptz - INTERVAL '15 minutes'
      AND calculated_at >= :'w0'::timestamptz AND calculated_at < :'we'::timestamptz
    GROUP BY 1)
SELECT count(*) AS publications, min(published - newest_bucket_end) AS min_delay,
       max(published - newest_bucket_end) AS max_delay
FROM runs;
SELECT pipeline_name, last_status, round(extract(epoch FROM now() - last_received_at)) AS lag_s
FROM telemetry.pipeline_state
WHERE pipeline_name IN ('normalized_points', 'energy_measurements', 'environment_measurements', 'energy_consumption_1min')
ORDER BY 1;

\echo === F energy rows per 5-minute window (devices per window)
WITH w AS (
    SELECT date_bin(INTERVAL '5 minutes', bucket_start, TIMESTAMPTZ '2000-01-01') AS win,
           count(*) AS rows, count(DISTINCT device_id) AS devices
    FROM telemetry.energy_measurements
    WHERE bucket_start >= :'w0'::timestamptz AND bucket_start < LEAST(:'we'::timestamptz, now() - INTERVAL '10 minutes')
    GROUP BY 1)
SELECT count(*) AS windows, min(devices) AS min_devices, max(devices) AS max_devices,
       count(*) FILTER (WHERE devices < (SELECT max(devices) FROM w)) AS windows_below_max,
       string_agg(CASE WHEN devices < (SELECT max(devices) FROM w) THEN to_char(win, 'MM-DD HH24:MI') || '=' || devices END, ' ') AS which
FROM w;

\echo === Summary (criteria that the script can decide; D and F rows need the listings above)
WITH a AS (
    SELECT bool_and(j.job_id IS NOT NULL
                    AND abs((s.total_runs - b.runs0)
                            - floor(extract(epoch FROM now() - :'w0'::timestamptz) / extract(epoch FROM j.schedule_interval))) <= 1) AS ok
    FROM (SELECT split_part(e, '=', 1) AS role, split_part(e, '=', 2)::bigint AS runs0
          FROM unnest(string_to_array(:'baseline', ',')) AS e) b
    LEFT JOIN timescaledb_information.jobs j
           ON (CASE WHEN j.proc_name LIKE 'policy_%' THEN j.proc_name || ':' || j.hypertable_name ELSE j.proc_name END) = b.role
    LEFT JOIN timescaledb_information.job_stats s ON s.job_id = j.job_id),
bb AS (
    SELECT count(*) AS errors, count(*) FILTER (WHERE sqlerrcode = '40P01') AS deadlocks
    FROM timescaledb_information.job_errors
    WHERE start_time >= :'w0'::timestamptz AND start_time < :'w1'::timestamptz),
c AS (
    SELECT percentile_cont(0.99) WITHIN GROUP (ORDER BY extract(epoch FROM finalized_at - interval_end)) AS p99_s,
           max(extract(epoch FROM finalized_at - interval_end)) AS max_s
    FROM analytics.demand_intervals
    WHERE interval_end > :'w0'::timestamptz AND interval_end <= :'we'::timestamptz
      AND interval_end <= now() - INTERVAL '10 minutes'),
cm AS (
    SELECT count(*) AS missing
    FROM generate_series(date_bin(INTERVAL '15 minutes', :'w0'::timestamptz, TIMESTAMPTZ '2000-01-01') + INTERVAL '15 minutes',
                         LEAST(:'we'::timestamptz, now() - INTERVAL '10 minutes') - INTERVAL '15 minutes',
                         INTERVAL '15 minutes') AS b
    WHERE NOT EXISTS (SELECT 1 FROM analytics.demand_intervals d WHERE d.interval_start = b)),
e AS (
    SELECT min(published - newest_bucket_end) AS min_d, max(published - newest_bucket_end) AS max_d
    FROM (SELECT date_trunc('minute', calculated_at) AS published, max(bucket_start) + INTERVAL '1 minute' AS newest_bucket_end
          FROM analytics.energy_consumption_1min
          WHERE bucket_start >= :'w0'::timestamptz - INTERVAL '15 minutes'
            AND calculated_at >= :'w0'::timestamptz AND calculated_at < :'we'::timestamptz
          GROUP BY 1) r),
l AS (
    SELECT bool_and(CASE pipeline_name
                        WHEN 'normalized_points' THEN extract(epoch FROM now() - last_received_at) <= 330
                        WHEN 'energy_consumption_1min' THEN extract(epoch FROM now() - last_received_at) <= 540
                        ELSE extract(epoch FROM now() - last_received_at) <= 450 END) AS ok
    FROM telemetry.pipeline_state
    WHERE pipeline_name IN ('normalized_points', 'energy_measurements', 'environment_measurements', 'energy_consumption_1min'))
SELECT * FROM (VALUES
    ('A cadence (+/- 1 run per job)', CASE WHEN (SELECT ok FROM a) THEN 'PASS' ELSE 'FAIL' END),
    ('B no job errors in [w0, w1)', CASE WHEN (SELECT errors FROM bb) = 0 THEN 'PASS' ELSE 'FAIL (' || (SELECT errors FROM bb) || ')' END),
    ('B no 40P01 in [w0, w1)', CASE WHEN (SELECT deadlocks FROM bb) = 0 THEN 'PASS' ELSE 'FAIL (' || (SELECT deadlocks FROM bb) || ')' END),
    ('C demand p99 <= 8 min', CASE WHEN (SELECT p99_s FROM c) <= 480 THEN 'PASS' ELSE 'FAIL (' || round((SELECT p99_s FROM c)::numeric) || ' s)' END),
    ('C demand max <= 23 min', CASE WHEN (SELECT max_s FROM c) <= 1380 THEN 'PASS' ELSE 'FAIL (' || round((SELECT max_s FROM c)::numeric) || ' s)' END),
    ('C no missing demand bucket', CASE WHEN (SELECT missing FROM cm) = 0 THEN 'PASS' ELSE 'FAIL (' || (SELECT missing FROM cm) || ')' END),
    ('D non-VALID explained by source gaps', 'CHECK (listings D)'),
    ('E 1-min publication delay 4:00-8:00', CASE WHEN (SELECT min_d FROM e) >= INTERVAL '4 minutes' AND (SELECT max_d FROM e) <= INTERVAL '8 minutes' THEN 'PASS' ELSE 'FAIL' END),
    ('E lag at the check', CASE WHEN (SELECT ok FROM l) THEN 'PASS (snapshot)' ELSE 'FAIL (snapshot)' END),
    ('E lag over the window', 'CHECK (P11 sampler)'),
    ('F energy windows complete outside gaps', 'CHECK (listing F)')
) AS t(criterion, result);

ROLLBACK;
