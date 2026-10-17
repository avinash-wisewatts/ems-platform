-- ============================================================================
-- Bounded routing read: EXPLAIN + one timed run (release-plan precheck P12).
--
-- READ-ONLY. Measures the migration-303 forward window read of the routing
-- loaders on the CURRENT database, without migration 303 being applied: it
-- replays only the normalized_points part of the read, with the 303 floor
-- (event_time >= the newest compressed chunk's range_end) as literals.
--
-- Safety
--   * One READ ONLY transaction ending in ROLLBACK; statement_timeout 30 s,
--     lock_timeout 2 s; no temp objects.
--   * The window is the last 5 minutes of receipts (one 300-batch window).
--   * Before anything executes, a plain EXPLAIN (no execution) of the read is
--     checked: if the plan contains any compressed-chunk scan
--     (DecompressChunk / ColumnarScan), or there is no compressed chunk to
--     exclude, the script stops without running the read. The UNBOUNDED
--     routing read (platform_received_at only) is NEVER executed here: on
--     production it scans every compressed chunk (2026-10-16: 30 s timeout
--     6 / 6).
--   * Production: run only with explicit authorization, via the read-only
--     helper (default_transaction_read_only=on), outside job 1053 and backfill
--     runs.
--
-- Run:
--   psql -X -v ON_ERROR_STOP=1 -f scripts/diagnostics/prod_routing_bounded_read_timing.sql
-- ============================================================================
\set ON_ERROR_STOP on
\pset footer off

BEGIN TRANSACTION READ ONLY;
SET LOCAL statement_timeout = '30s';
SET LOCAL lock_timeout = '2s';
SHOW transaction_read_only;

-- Q1: the 303 floor and the chunk layout (catalog only).
SELECT COALESCE(max(range_end) FILTER (WHERE is_compressed), '-infinity'::timestamptz) AS floor,
       count(*) FILTER (WHERE is_compressed)     AS compressed_chunks,
       count(*) FILTER (WHERE NOT is_compressed) AS uncompressed_chunks,
       min(range_start) FILTER (WHERE NOT is_compressed) AS oldest_uncompressed_start
FROM timescaledb_information.chunks
WHERE hypertable_schema = 'telemetry' AND hypertable_name = 'normalized_points'
\gset
\echo floor=:floor compressed=:compressed_chunks uncompressed=:uncompressed_chunks oldest_uncompressed=:oldest_uncompressed_start

-- Q2: the window end exactly as the loaders compute it (migration-267 bounded
-- lookup; ~1-4 ms on both environments, 2026-10-16) and a 5-minute window.
\timing on
SELECT max(platform_received_at) AS window_end,
       max(platform_received_at) - INTERVAL '5 minutes' AS window_start
FROM telemetry.normalized_points
WHERE platform_received_at IS NOT NULL
  AND event_time >= now() - INTERVAL '1 day'
\gset
\timing off
\echo window=(:window_start, :window_end]

-- Q3: guard. Plain EXPLAIN (not executed) of the bounded read; abort unless a
-- compressed chunk exists to be excluded and the plan touches none of them.
SELECT set_config('p12.floor', :'floor', true) AS floor_param,
       set_config('p12.window_start', :'window_start', true) AS start_param,
       set_config('p12.window_end', :'window_end', true) AS end_param;

DO $guard$
DECLARE
    v_line TEXT;
    v_plan TEXT := '';
BEGIN
    IF current_setting('p12.floor')::timestamptz = '-infinity'::timestamptz THEN
        RAISE EXCEPTION 'P12 guard: no compressed normalized_points chunk; nothing to measure.';
    END IF;
    FOR v_line IN EXECUTE format(
        'EXPLAIN SELECT np.device_id, np.event_time, max(np.platform_received_at)
           FROM telemetry.normalized_points np
          WHERE np.platform_received_at > %L AND np.platform_received_at <= %L
            AND np.event_time >= %L AND np.event_time < %L
          GROUP BY np.device_id, np.event_time',
        current_setting('p12.window_start'), current_setting('p12.window_end'),
        current_setting('p12.floor'), 'infinity')
    LOOP
        v_plan := v_plan || v_line || E'\n';
    END LOOP;
    IF v_plan ~ '(DecompressChunk|ColumnarScan|_compressed_hypertable|compress_hyper)' THEN
        RAISE EXCEPTION 'P12 guard: the bounded plan still references a compressed chunk; not executing.%', E'\n' || v_plan;
    END IF;
    RAISE NOTICE 'P12 guard passed: the bounded plan reads no compressed chunk.';
END
$guard$;

-- Q4: the bounded energy read, executed once with buffers.
EXPLAIN (ANALYZE, BUFFERS, COSTS OFF, TIMING OFF)
SELECT np.device_id, np.event_time, max(np.platform_received_at)
FROM telemetry.normalized_points np
WHERE np.platform_received_at > :'window_start' AND np.platform_received_at <= :'window_end'
  AND np.event_time >= :'floor' AND np.event_time < 'infinity'
GROUP BY np.device_id, np.event_time;

-- Q5: the bounded environment read (adds the device / profile filter), timed.
\timing on
SELECT count(*) AS env_window_events
FROM (
    SELECT np.device_id, np.event_time, max(np.platform_received_at)
    FROM telemetry.normalized_points np
    JOIN metadata.devices d ON d.id = np.device_id
    JOIN config.device_profiles dp ON dp.id = d.profile_id
    WHERE np.platform_received_at > :'window_start' AND np.platform_received_at <= :'window_end'
      AND np.event_time >= :'floor' AND np.event_time < 'infinity'
      AND dp.profile_code = 'ENVIRONMENT_SENSOR_AIRSENSE_V1'
    GROUP BY np.device_id, np.event_time
) x;
\timing off

ROLLBACK;
