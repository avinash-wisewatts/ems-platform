-- ============================================================================
-- Release B1 (546a718: migrations 268, 269) pre-dispatch check. READ-ONLY.
--
-- Run immediately before dispatching deploy-production.yml for B1, and only
-- with explicit authorization. Every line ends in PASS or FAIL; any FAIL
-- means do not dispatch. Catalog and small-table reads only, except the
-- per-job lookups in timescaledb_information.
--
-- P2 (pending set) is not checked here: the host checkout is still at the
-- previous release, so `apply_migrations.sh --status` there cannot show
-- 546a718's pending rows. It is checked locally: the manifest at 546a718
-- minus the production ledger must be exactly 268, 269 (verified 2026-10-19).
--
-- Expected values (2026-10-19): ledger 133 rows; digest of
-- (migration_id:checksum) over all rows = 7e872b468bd8db6ef37951bfbb29dfab,
-- equal to staging's same 133 rows; failure total (all jobs except 1114) 2840.
--
--   psql -X -v ON_ERROR_STOP=1 -f scripts/diagnostics/prod_b1_precheck.sql
-- through the read-only session settings (default_transaction_read_only=on).
-- ============================================================================
\set ON_ERROR_STOP on
\pset footer off
\pset tuples_only on
SET application_name = 'ems_b1_precheck';
SET statement_timeout = '30s';
SET lock_timeout = '2s';
SET TIME ZONE 'UTC';
SHOW default_transaction_read_only;

BEGIN READ ONLY;

SELECT 'now ' || now();

-- P1: ledger state equals the last verified state.
SELECT 'P1 ledger rows=' || count(*) || ' digest=' || md5(string_agg(migration_id || ':' || checksum_sha256, ',' ORDER BY migration_id))
       || CASE WHEN count(*) = 133
                AND md5(string_agg(migration_id || ':' || checksum_sha256, ',' ORDER BY migration_id)) = '7e872b468bd8db6ef37951bfbb29dfab'
               THEN ' PASS' ELSE ' FAIL' END
FROM admin.schema_migrations;

SELECT 'P1 268/269 not yet applied: ' || count(*) || CASE WHEN count(*) = 0 THEN ' PASS' ELSE ' FAIL' END
FROM admin.schema_migrations
WHERE migration_id IN ('268_energy_reconstruction_foundations', '269_energy_reconstruction_read_hardening');

-- Pre-state: none of 268's or 269's objects exist yet.
SELECT 'PRE 268/269 objects absent: columns=' || count(*) FILTER (WHERE c.column_name IS NOT NULL)
       || ' scope_table=' || (to_regclass('config.energy_reconstruction_scope') IS NOT NULL)
       || CASE WHEN count(*) FILTER (WHERE c.column_name IS NOT NULL) = 0
                AND to_regclass('config.energy_reconstruction_scope') IS NULL
               THEN ' PASS' ELSE ' FAIL' END
FROM information_schema.columns AS c
WHERE c.table_schema = 'analytics'
  AND c.table_name IN ('energy_consumption_1min', 'energy_consumption_5min', 'energy_consumption_15min',
                       'energy_consumption_hourly', 'energy_consumption_daily')
  AND c.column_name IN ('is_reconstructed', 'reconstructed_interval_count');

-- P10: failure baseline, no failing job, 1053 not running, no backfill.
SELECT 'P10 failure total (excl. 1114)=' || sum(total_failures) FILTER (WHERE job_id <> 1114)
       || ' failing=' || count(*) FILTER (WHERE last_run_status = 'Failed' AND job_id <> 1114)
       || CASE WHEN sum(total_failures) FILTER (WHERE job_id <> 1114) = 2840
                AND count(*) FILTER (WHERE last_run_status = 'Failed' AND job_id <> 1114) = 0
               THEN ' PASS' ELSE ' FAIL' END
FROM timescaledb_information.job_stats;

SELECT 'P10 job errors since 2026-10-17 12:00 UTC=' || count(*) || CASE WHEN count(*) = 0 THEN ' PASS' ELSE ' FAIL' END
FROM timescaledb_information.job_errors WHERE start_time >= '2026-10-17 12:00+00';

SELECT 'P10 job 1053 ' || s.job_status || ' scheduled=' || j.scheduled
       || CASE WHEN s.job_status = 'Paused' AND NOT j.scheduled THEN ' PASS' ELSE ' FAIL' END
FROM timescaledb_information.job_stats AS s JOIN timescaledb_information.jobs AS j USING (job_id)
WHERE s.job_id = 1053;

SELECT 'P10 paused 1114-1120 unscheduled=' || count(*) FILTER (WHERE NOT j.scheduled) || '/7'
       || CASE WHEN count(*) FILTER (WHERE NOT j.scheduled) = 7 THEN ' PASS' ELSE ' FAIL' END
FROM timescaledb_information.jobs AS j WHERE j.job_id BETWEEN 1114 AND 1120;

SELECT 'P10 backfill sessions=' || count(*) || CASE WHEN count(*) = 0 THEN ' PASS' ELSE ' FAIL' END
FROM pg_stat_activity WHERE query ILIKE 'CALL analytics.backfill_point_telemetry_1h%' AND state = 'active';

-- Energy jobs that B1's locks will briefly block: all healthy now.
SELECT 'JOBS energy last runs: ' || string_agg(s.job_id || '=' || coalesce(s.last_run_status, 'none'), ' ' ORDER BY s.job_id)
       || CASE WHEN bool_and(s.last_run_status = 'Success') THEN ' PASS' ELSE ' FAIL' END
FROM timescaledb_information.job_stats AS s
WHERE s.job_id IN (1062, 1063, 1064, 1097, 1100, 1103);

-- Lock-queue precondition: no long or idle-in-transaction session, and no
-- session holding a lock on an Energy table or view.
SELECT 'LOCK sessions in a transaction > 60 s=' || count(*) || CASE WHEN count(*) = 0 THEN ' PASS' ELSE ' FAIL' END
FROM pg_stat_activity
WHERE pid <> pg_backend_pid() AND backend_type = 'client backend'
  AND xact_start < now() - interval '60 seconds';

SELECT 'LOCK idle in transaction=' || count(*) || CASE WHEN count(*) = 0 THEN ' PASS' ELSE ' FAIL' END
FROM pg_stat_activity
WHERE pid <> pg_backend_pid() AND state LIKE 'idle in transaction%';

-- Energy relations = the five hypertables, their chunks, and the analytics
-- v_energy_* / v_asset_* views. The 1-minute jobs hold these for well under a
-- second, so only a holder whose transaction is older than 10 s fails.
WITH energy_rel AS (
    SELECT format('%I.%I', h.hypertable_schema, h.hypertable_name)::regclass AS rel
    FROM timescaledb_information.hypertables AS h
    WHERE h.hypertable_schema = 'analytics'
      AND h.hypertable_name IN ('energy_consumption_1min', 'energy_consumption_5min', 'energy_consumption_15min',
                                'energy_consumption_hourly', 'energy_consumption_daily')
    UNION ALL
    SELECT format('%I.%I', ch.chunk_schema, ch.chunk_name)::regclass
    FROM timescaledb_information.chunks AS ch
    WHERE ch.hypertable_schema = 'analytics'
      AND ch.hypertable_name IN ('energy_consumption_1min', 'energy_consumption_5min', 'energy_consumption_15min',
                                 'energy_consumption_hourly', 'energy_consumption_daily')
    UNION ALL
    SELECT c.oid::regclass
    FROM pg_class AS c JOIN pg_namespace AS n ON n.oid = c.relnamespace
    WHERE n.nspname = 'analytics' AND c.relkind = 'v'
      AND (c.relname LIKE 'v_energy_%' OR c.relname LIKE 'v_asset_%')
)
SELECT 'LOCK sessions holding Energy relations for > 10 s=' || count(DISTINCT l.pid)
       || coalesce(' [' || string_agg(DISTINCT a.pid || ':' || coalesce(nullif(a.application_name, ''), a.usename), ',') || ']', '')
       || CASE WHEN count(DISTINCT l.pid) = 0 THEN ' PASS' ELSE ' FAIL' END
FROM pg_locks AS l
JOIN energy_rel AS e ON e.rel = l.relation
JOIN pg_stat_activity AS a ON a.pid = l.pid
WHERE l.pid <> pg_backend_pid()
  AND a.xact_start < now() - interval '10 seconds';

SELECT 'INFO client sessions: ' || coalesce(string_agg(app || ':' || n, ' '), 'none')
FROM (SELECT coalesce(nullif(application_name, ''), usename) AS app, count(*) AS n
      FROM pg_stat_activity WHERE backend_type = 'client backend' AND pid <> pg_backend_pid()
      GROUP BY 1) AS x;

ROLLBACK;
