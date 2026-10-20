-- ============================================================================
-- Release B1 (546a718: migrations 268, 269) post-deploy check. READ-ONLY.
--
-- Run after deploy-production.yml for B1 finishes, with explicit
-- authorization. Every line ends in PASS or FAIL (INFO lines are evidence
-- only); a full pass prints exactly 26 PASS lines. The Energy before/after comparison is separate:
-- energy_parity_capture.sql + energy_parity_compare.py.
--
-- Expected checksums (staging ledger = repository at 546a718):
--   268 f8572080a4467f618e8d5667e7f90ad12dddca0bcaec6587a39215f8a1327e4a
--   269 313d39f4951d11adffa3982652a7dbc56191762bce6eade89fa500a6ae531ed4
--
--   psql -X -v ON_ERROR_STOP=1 -f scripts/diagnostics/prod_b1_postcheck.sql
-- through the read-only session settings (default_transaction_read_only=on).
-- ============================================================================
\set ON_ERROR_STOP on
\pset footer off
\pset tuples_only on
SET application_name = 'ems_b1_postcheck';
SET statement_timeout = '30s';
SET lock_timeout = '2s';
SET TIME ZONE 'UTC';
SHOW default_transaction_read_only;

BEGIN READ ONLY;

SELECT 'now ' || now();

-- Ledger: exactly 135 rows; 268 and 269 applied with the staging checksums;
-- the other 133 rows unchanged.
SELECT 'LEDGER rows=' || count(*) || CASE WHEN count(*) = 135 THEN ' PASS' ELSE ' FAIL' END
FROM admin.schema_migrations;

SELECT 'LEDGER ' || e.id || ' ' || coalesce(m.application_mode || ' ' || m.execution_ms || ' ms', 'MISSING')
       || CASE WHEN m.application_mode = 'applied' AND m.checksum_sha256 = e.sha THEN ' PASS' ELSE ' FAIL' END
FROM (VALUES ('268_energy_reconstruction_foundations',    'f8572080a4467f618e8d5667e7f90ad12dddca0bcaec6587a39215f8a1327e4a'),
             ('269_energy_reconstruction_read_hardening', '313d39f4951d11adffa3982652a7dbc56191762bce6eade89fa500a6ae531ed4')) AS e (id, sha)
LEFT JOIN admin.schema_migrations AS m ON m.migration_id = e.id
ORDER BY e.id;

SELECT 'LEDGER earlier 133 rows digest' || CASE WHEN md5(string_agg(migration_id || ':' || checksum_sha256, ',' ORDER BY migration_id)) = '7e872b468bd8db6ef37951bfbb29dfab'
                                                THEN ' PASS' ELSE ' FAIL' END
FROM admin.schema_migrations
WHERE migration_id NOT IN ('268_energy_reconstruction_foundations', '269_energy_reconstruction_read_hardening');

-- 268: 11 columns on 1min and 5min; is_reconstructed NOT NULL DEFAULT false;
-- the import/export CHECKs exist NOT VALID.
SELECT 'POST268 ' || t.tbl || ' columns=' || count(c.column_name)
       || CASE WHEN count(c.column_name) = 11 THEN ' PASS' ELSE ' FAIL' END
FROM (VALUES ('energy_consumption_1min'), ('energy_consumption_5min')) AS t (tbl)
LEFT JOIN information_schema.columns AS c
  ON c.table_schema = 'analytics' AND c.table_name = t.tbl
 AND c.column_name IN ('is_reconstructed', 'import_reconstruction_role', 'import_reconstruction_method',
                       'import_gap_start', 'import_gap_end', 'import_gap_delta_wh', 'export_reconstruction_role',
                       'export_reconstruction_method', 'export_gap_start', 'export_gap_end', 'export_gap_delta_wh')
GROUP BY t.tbl ORDER BY t.tbl;

SELECT 'POST268 ' || conrelid::regclass || ' NOT VALID checks=' || count(*)
       || CASE WHEN count(*) >= 2 AND bool_and(NOT convalidated) THEN ' PASS' ELSE ' FAIL' END
FROM pg_constraint
WHERE conrelid IN ('analytics.energy_consumption_1min'::regclass, 'analytics.energy_consumption_5min'::regclass)
  AND contype = 'c'
  AND (conname LIKE '%reconstruction' OR conname LIKE '%synthetic_direction')
GROUP BY conrelid ORDER BY 1;

-- Reconstruction switch OFF.
SELECT 'SWITCH scope rows=' || count(*) || ' enabled=' || count(*) FILTER (WHERE is_enabled)
       || ' resolves=' || coalesce(config.energy_reconstruction_enabled(NULL, NULL)::TEXT, 'null')
       || CASE WHEN count(*) = 1 AND count(*) FILTER (WHERE is_enabled) = 0
                AND config.energy_reconstruction_enabled(NULL, NULL) IS FALSE
               THEN ' PASS' ELSE ' FAIL' END
FROM config.energy_reconstruction_scope;

SELECT 'POST268 allocation functions immutable, not PUBLIC: ' || count(*)
       || CASE WHEN count(*) = 2 AND bool_and(p.provolatile = 'i')
                AND NOT bool_or(has_function_privilege('public', p.oid, 'EXECUTE'))
               THEN ' PASS' ELSE ' FAIL' END
FROM pg_proc AS p JOIN pg_namespace AS n ON n.oid = p.pronamespace
WHERE n.nspname = 'analytics' AND p.proname IN ('energy_gap_weights', 'allocate_energy_delta');

-- No reconstructed row exists (bounded to the last 2 days, uncompressed).
SELECT 'POST268 reconstructed 1min rows (last 2 days)=' || count(*) || CASE WHEN count(*) = 0 THEN ' PASS' ELSE ' FAIL' END
FROM analytics.energy_consumption_1min
WHERE bucket_start >= now() - interval '2 days' AND is_reconstructed;

-- 269: 5 counter columns on each persisted tier; views keep security_barrier.
SELECT 'POST269 ' || t.tbl || ' counters=' || count(c.column_name)
       || CASE WHEN count(c.column_name) = 5 THEN ' PASS' ELSE ' FAIL' END
FROM (VALUES ('energy_consumption_15min'), ('energy_consumption_hourly'), ('energy_consumption_daily')) AS t (tbl)
LEFT JOIN information_schema.columns AS c
  ON c.table_schema = 'analytics' AND c.table_name = t.tbl AND c.column_name LIKE '%reconstructed%'
GROUP BY t.tbl ORDER BY t.tbl;

SELECT 'POST269 reporting views with security_barrier=' || count(*) FILTER (WHERE 'security_barrier=true' = ANY (c.reloptions))
       || '/' || count(*)
       || CASE WHEN count(*) = 7 AND count(*) FILTER (WHERE 'security_barrier=true' = ANY (c.reloptions)) = 7 THEN ' PASS' ELSE ' FAIL' END
FROM pg_class AS c JOIN pg_namespace AS n ON n.oid = c.relnamespace
WHERE n.nspname = 'analytics'
  AND c.relname IN ('v_energy_reporting_5min', 'v_energy_reporting_15min', 'v_energy_reporting_hourly', 'v_energy_reporting_daily',
                    'v_energy_consumption_daily', 'v_asset_consumption_daily', 'v_asset_hierarchy_rollup_daily');

-- Health: failure baseline, no failing job, no new job error, Energy jobs
-- succeeding after the deploy, no lock waiters, paused jobs unchanged.
SELECT 'HEALTH failure total (excl. 1114)=' || sum(total_failures) FILTER (WHERE job_id <> 1114)
       || ' failing=' || count(*) FILTER (WHERE last_run_status = 'Failed' AND job_id <> 1114)
       || CASE WHEN sum(total_failures) FILTER (WHERE job_id <> 1114) = 2840
                AND count(*) FILTER (WHERE last_run_status = 'Failed' AND job_id <> 1114) = 0
               THEN ' PASS' ELSE ' FAIL' END
FROM timescaledb_information.job_stats;

SELECT 'HEALTH job errors since 2026-10-17 12:00 UTC=' || count(*) || CASE WHEN count(*) = 0 THEN ' PASS' ELSE ' FAIL' END
FROM timescaledb_information.job_errors WHERE start_time >= '2026-10-17 12:00+00';

-- While a job runs, job_stats has last_run_duration NULL and last_run_status
-- still describes the previous finished run; every part is coalesced so the
-- line (and its PASS/FAIL) is never NULL, and a missing job prints FAIL.
SELECT 'HEALTH energy job ' || e.job_id || ' ' || coalesce(s.last_run_status, 'none')
       || CASE WHEN s.job_status = 'Running'
               THEN ' (previous run; running since ' || coalesce(to_char(s.last_run_started_at, 'HH24:MI:SS'), '-') || ')'
               ELSE ' at ' || coalesce(to_char(s.last_run_started_at, 'HH24:MI:SS'), '-') || ' ('
                    || coalesce(round(extract(epoch FROM s.last_run_duration)::NUMERIC, 2)::TEXT, '-') || ' s)'
          END
       || CASE WHEN s.last_run_status = 'Success' THEN ' PASS' ELSE ' FAIL' END
FROM (VALUES (1062), (1063), (1064), (1097), (1100), (1103)) AS e (job_id)
LEFT JOIN timescaledb_information.job_stats AS s ON s.job_id = e.job_id
ORDER BY e.job_id;

SELECT 'HEALTH lock waiters=' || count(*) || CASE WHEN count(*) = 0 THEN ' PASS' ELSE ' FAIL' END
FROM pg_stat_activity WHERE pid <> pg_backend_pid() AND wait_event_type = 'Lock';

SELECT 'HEALTH paused 1053 + 1114-1120 unscheduled=' || count(*) FILTER (WHERE NOT j.scheduled) || '/8'
       || CASE WHEN count(*) FILTER (WHERE NOT j.scheduled) = 8 THEN ' PASS' ELSE ' FAIL' END
FROM timescaledb_information.jobs AS j WHERE j.job_id = 1053 OR j.job_id BETWEEN 1114 AND 1120;

SELECT 'HEALTH 1h checkpoint ' || coalesce(p.last_received_at::TEXT, '-') || ' ' || coalesce(p.last_status, 'none')
       || CASE WHEN p.last_status = 'SUCCESS' THEN ' PASS' ELSE ' FAIL' END
FROM (SELECT 1) AS one
LEFT JOIN telemetry.pipeline_state AS p ON p.pipeline_name = 'point_telemetry_1h';

-- A missing row or NULL timestamp prints 'unknown' instead of a blank line.
SELECT 'INFO routing lag energy=' || coalesce(extract(epoch FROM n.last_received_at - e.last_received_at)::INT || ' s', 'unknown')
       || ' environment=' || coalesce(extract(epoch FROM n.last_received_at - v.last_received_at)::INT || ' s', 'unknown')
FROM (SELECT 1) AS one
LEFT JOIN telemetry.pipeline_state AS n ON n.pipeline_name = 'normalized_points'
LEFT JOIN telemetry.pipeline_state AS e ON e.pipeline_name = 'energy_measurements'
LEFT JOIN telemetry.pipeline_state AS v ON v.pipeline_name = 'environment_measurements';

ROLLBACK;
