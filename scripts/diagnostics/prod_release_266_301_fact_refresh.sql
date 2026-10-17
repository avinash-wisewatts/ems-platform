-- Read-only refresh of the production facts marked [P] in
-- docs/09-release-and-deployment/production-release-plan-266-301.md (section 5).
--
-- One READ ONLY transaction that ends in ROLLBACK: no writes, no job or
-- configuration change. statement_timeout 120 s, lock_timeout 2 s.
-- Production use needs explicit authorization (CLAUDE.md section 3); run it
-- outside a job 1053 (compression) window. Validated read-only on staging
-- 2026-10-14 (about 7 s; staging values differ by design: it is at 301).
--
-- Usage on the host:
--   docker compose exec -T timescaledb sh -c --     'psql -X -q -U "$POSTGRES_USER" -d "$POSTGRES_DB"' < this_file.sql
\set ON_ERROR_STOP on
\pset pager off
BEGIN TRANSACTION READ ONLY;
SET LOCAL statement_timeout = '120s';
SET LOCAL lock_timeout = '2s';
SET LOCAL TIME ZONE 'UTC';

\echo '== R1 ledger (expect 131 rows, max 265; digest compared with staging rows <= 265)'
SELECT count(*) AS ledger_rows,
       max(left(migration_id, 3)) AS head,
       md5(string_agg(migration_id || ':' || checksum_sha256, ',' ORDER BY migration_id)
         FILTER (WHERE left(migration_id, 3) <= '265'
                   AND left(migration_id, 3) NOT IN ('253','254','255','256','257','258','259','260','261','262','263'))) AS digest_applied_set
FROM admin.schema_migrations;

\echo '== R2 1h tier frontier (expect Sep 4 00:00 -> Sep 24 06:00 UTC, 1,248,796 rows)'
SELECT min(bucket_start) AS first_hour, max(bucket_start) AS last_hour,
       count(*) AS rows, count(DISTINCT bucket_start) AS hours_with_rows
FROM analytics.point_telemetry_1h;

\echo '== R3 1h jobs + checkpoint (expect 4 jobs unscheduled, 265 config; checkpoint NULL)'
SELECT job_id, proc_name, scheduled, schedule_interval, max_runtime, max_retries, config
FROM timescaledb_information.jobs
WHERE proc_name IN ('run_point_telemetry_1h_job', 'reconcile_point_telemetry_1h')
   OR hypertable_name = 'point_telemetry_1h'
ORDER BY job_id;
SELECT pipeline_name, last_received_at FROM telemetry.pipeline_state
WHERE pipeline_name = 'point_telemetry_1h';

\echo '== R4 failure counter (runner definition) and every job error since the 2832 baseline'
SELECT (SELECT count(*) FROM timescaledb_information.job_stats
         WHERE last_run_status = 'Failed' AND job_id <> 1114) AS failed_non1114,
       (SELECT sum(total_failures) FROM timescaledb_information.job_stats
         WHERE job_id <> 1114) AS failtot_non1114,
       (SELECT total_failures FROM timescaledb_information.job_stats
         WHERE job_id = 1114) AS f1114;
SELECT job_id, proc_name, sqlerrcode, count(*) AS errors,
       min(finish_time) AS first_at, max(finish_time) AS last_at
FROM timescaledb_information.job_errors
WHERE finish_time >= '2026-10-13 05:00+00' AND job_id <> 1114  -- 2832 accepted 10:33 IST
GROUP BY 1, 2, 3 ORDER BY 1, 3;

\echo '== R5 Release A preconditions (267): compress_after >= 1 day, both md5s true'
SELECT (SELECT (config ->> 'compress_after') FROM timescaledb_information.jobs
         WHERE hypertable_schema = 'telemetry' AND hypertable_name = 'normalized_points'
           AND proc_name = 'policy_compression') AS np_compress_after,
       (SELECT md5(replace(prosrc, E'\r', '')) FROM pg_proc WHERE oid =
         'telemetry.load_energy_measurements_incremental(interval,interval)'::regprocedure)
         = 'd7adba7148a20e523c905f09cff52e8f' AS energy_loader_is_215,
       (SELECT md5(replace(prosrc, E'\r', '')) FROM pg_proc WHERE oid =
         'telemetry.load_environment_measurements_incremental(interval,interval)'::regprocedure)
         = 'b9db05675b7ae65dae5637b521a6a60b' AS env_loader_is_228;

\echo '== R6 301 preconditions: both loader md5s still the pinned values'
SELECT md5(replace(prosrc, E'\r', '')) = 'cb1b3f00129bbc2c6c8e85b06905e540' AS normalize_is_pinned
FROM pg_proc WHERE oid = 'telemetry.load_normalized_points_incremental'::regproc;
SELECT md5(replace(prosrc, E'\r', '')) = 'e9b3522a2e4189ad8d34eb885b875303' AS raw_receipt_is_pinned
FROM pg_proc WHERE oid = 'telemetry.load_device_raw_receipt_state_incremental'::regproc;

\echo '== R7 retention policies (energy_measurements 90 d; 15m source 120 d)'
SELECT job_id, hypertable_schema, hypertable_name, config ->> 'drop_after' AS drop_after, next_start
FROM timescaledb_information.jobs WHERE proc_name = 'policy_retention' ORDER BY 2, 3;

\echo '== R8 energy_measurements: oldest chunks until the first with >= 2 devices'
DO $r8$
DECLARE c record; v_any boolean; v_dev bigint; v_min timestamptz; v_col text; n int := 0;
BEGIN
  SELECT column_name INTO v_col FROM timescaledb_information.dimensions
   WHERE hypertable_schema = 'telemetry' AND hypertable_name = 'energy_measurements'
     AND dimension_number = 1;
  FOR c IN SELECT chunk_schema, chunk_name, range_start, range_end, is_compressed
             FROM timescaledb_information.chunks
            WHERE hypertable_schema = 'telemetry' AND hypertable_name = 'energy_measurements'
            ORDER BY range_start LIMIT 40 LOOP
    n := n + 1;
    EXECUTE format('SELECT EXISTS (SELECT 1 FROM %I.%I)', c.chunk_schema, c.chunk_name) INTO v_any;
    IF v_any THEN
      EXECUTE format('SELECT count(DISTINCT device_id), min(%I) FROM %I.%I',
                     v_col, c.chunk_schema, c.chunk_name) INTO v_dev, v_min;
    ELSE v_dev := 0; v_min := NULL; END IF;
    RAISE NOTICE 'chunk % [% , %) compressed=% devices=% first=%',
      n, c.range_start, c.range_end, c.is_compressed, v_dev, v_min;
    EXIT WHEN v_dev >= 2;
  END LOOP;
END $r8$;

\echo '== R10 asset_points parity bridge (expect 112 rows, 56 assets, created 2026-10-08 06:11:22 UTC; 0 non-bridge rows)'
SELECT count(*) AS bridge_rows, count(DISTINCT asset_id) AS assets, min(created_at) AS created_at,
       (SELECT count(*) FROM metadata.asset_points
         WHERE effective_from <> '-infinity'::timestamptz) AS non_bridge_rows
FROM metadata.asset_points WHERE effective_from = '-infinity'::timestamptz;

\echo '== R9 environment_measurements rows in compressed chunks (291 fails above 100,000)'
DO $r9$
DECLARE c record; v bigint; t bigint := 0;
BEGIN
  FOR c IN SELECT chunk_schema, chunk_name FROM timescaledb_information.chunks
            WHERE hypertable_schema = 'telemetry' AND hypertable_name = 'environment_measurements'
              AND is_compressed LOOP
    EXECUTE format('SELECT count(*) FROM %I.%I', c.chunk_schema, c.chunk_name) INTO v;
    t := t + v;
  END LOOP;
  RAISE NOTICE 'compressed env rows = %', t;
END $r9$;

ROLLBACK;
