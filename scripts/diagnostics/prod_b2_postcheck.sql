-- ============================================================================
-- Release B2 (ba2cb4b: migrations 263, 270, 279, 275-278, 280-286)
-- post-deploy check. READ-ONLY.
--
-- Run after deploy-production.yml for B2 finishes, with explicit
-- authorization, through the read-only session settings
-- (default_transaction_read_only=on). Catalog and small-table reads only.
-- The Energy before/after comparison is separate:
-- energy_parity_capture.sql + energy_parity_compare.py (decision D3).
--
-- Output contract (checked by prod_b2_gate.py postcheck): unaligned, one
-- line per check, '<KEY> <evidence> PASS|FAIL'; 'now ' and 'INFO ' lines are
-- evidence only; the last line is 'END prod_b2_postcheck'.
--
-- Expected values (2026-10-20). Checksums = repository at ba2cb4b = staging
-- ledger. Ledger digests (md5 of migration_id:checksum ordered by
-- migration_id COLLATE "C"): the B1 rows f7273fa86b93fbbb7faae2e213966d9c,
-- all 149 rows a6d33cb028cef31547d32a4e2f14ca20 (equal to staging's same 149
-- rows). Function definitions: md5(pg_get_functiondef) after the 14
-- migrations, from a local database built at 546a718 and migrated with the
-- runner at ba2cb4b; get_portal_analytics_catalog, _energy_availability and
-- get_portal_asset_energy_series equal the pins of migrations 288 and 302,
-- the others equal staging's current definitions (no later migration
-- replaces them). Identical in UTC and Asia/Kolkata sessions.
-- ============================================================================
\set ON_ERROR_STOP on
\pset footer off
\pset tuples_only on
\pset format unaligned
SET application_name = 'ems_b2_postcheck';
SET statement_timeout = '30s';
SET lock_timeout = '2s';
SET TIME ZONE 'UTC';

BEGIN READ ONLY;

SELECT 'now ' || now();

SELECT 'SESSION.readonly default_transaction_read_only=' || current_setting('default_transaction_read_only')
       || CASE WHEN current_setting('default_transaction_read_only') = 'on' THEN ' PASS' ELSE ' FAIL' END;

SELECT 'SESSION.identity ' || current_user || '@' || current_database()
       || CASE WHEN current_user = 'ems_admin' AND current_database() = 'ems' THEN ' PASS' ELSE ' FAIL' END;

-- Ledger: exactly 149 rows; the 14 applied with the staging checksums, in
-- manifest order and after every earlier row; the 135 B1 rows unchanged.
SELECT 'LEDGER.rows rows=' || count(*) || CASE WHEN count(*) = 149 THEN ' PASS' ELSE ' FAIL' END
FROM admin.schema_migrations;

WITH expected (ord, id, sha) AS (VALUES
    (1,  '263_asset_energy_consumption_asset_points_attribution', 'a50e92425ed3f2378d07568e6bd750e78010a0421dd0b02c1d4727f5f3347961'),
    (2,  '270_canonical_energy_read_selective_device_reads',      '743a7e35ce900bb39126b9109c8c95c75e4cc9e4c7749b5f36cb4d75232f5d20'),
    (3,  '279_asset_energy_tier_read',                            'b761be6dfc44080f0a36cd3950594dd232e1d20a0f7d501fea76573693e4f8e8'),
    (4,  '275_site_timezone_immutable_with_telemetry',            'ea591163668de459e9bf4b804aa0ada4258a99b08c58ecf54a665cd27fb7beb3'),
    (5,  '276_analytics_api_catalog',                             '073779f81aab341f29a7976932b8db4fe63772bbdfd5e598587d43fc9bcd41f9'),
    (6,  '277_analytics_api_energy_availability',                 'a27dd3e49f520cdbfac1e60b632d7cc187b772d731f794a466d7fecb7fe09556'),
    (7,  '278_analytics_api_energy_series',                       'ab0149b733c5255b0550784d5ed4e4d30515bb7cb8e116da7105e365bed6c6e6'),
    (8,  '280_analytics_energy_persisted_tier_switch',            'd97825945513775b192611f43d2f83a702aa299873c1ade8fd3642d6f30c403a'),
    (9,  '281_asset_energy_tier_read_15m_checkpoint_floor',       'ca48589ceb99ad796156ce476cd02eb2241e7fd81869236406d3ddee05cf59d4'),
    (10, '282_analytics_energy_series_data_quality',              'a7f1cafd86ef4ce43d71ef897b88d54b39f35e41dd9973ac03208cfb54097659'),
    (11, '283_analytics_energy_rollup_tail_pruning',              '70b949ea54b64f5ee814cf368a57fb301b276900e2b4afc6ac05fdb2d5d5a856'),
    (12, '284_analytics_energy_series_set_based_quality',         'da0347d1d8765384e974396447f58701c01d2f60a66b4d07a6d6ed5cc70d8321'),
    (13, '285_analytics_energy_direction_status_inlinable',       '926d7ae413c545d5a116dbc296bccab1d7a8de4f09ff7f75a955123c3068d984'),
    (14, '286_analytics_energy_availability_materialized_bounds', 'f1fe50f6f7aa915cb3d7f60420d11a7293b8182eccb9a248566ff87ba2f16765')
),
joined AS (
    SELECT e.ord, e.id, e.sha, m.checksum_sha256, m.application_mode, m.execution_ms, m.applied_at,
           lag(m.applied_at) OVER (ORDER BY e.ord) AS prev_applied_at
    FROM expected AS e
    LEFT JOIN admin.schema_migrations AS m ON m.migration_id = e.id
)
SELECT line FROM (
    SELECT j.ord, 'LEDGER.' || left(j.id, 3) || ' ' || coalesce(j.application_mode || ' ' || j.execution_ms || ' ms', 'MISSING')
           || CASE WHEN j.application_mode = 'applied' AND j.checksum_sha256 = j.sha THEN ' PASS' ELSE ' FAIL' END AS line
    FROM joined AS j
    UNION ALL
    SELECT 15, 'LEDGER.order 14 rows in manifest order after the B1 rows: '
           || count(*) FILTER (WHERE j.applied_at IS NOT NULL
                               AND (j.prev_applied_at IS NULL OR j.applied_at > j.prev_applied_at)) || '/14'
           || CASE WHEN count(*) FILTER (WHERE j.applied_at IS NOT NULL
                                         AND (j.prev_applied_at IS NULL OR j.applied_at > j.prev_applied_at)) = 14
                    AND min(j.applied_at) > (SELECT max(m.applied_at) FROM admin.schema_migrations AS m
                                             WHERE NOT EXISTS (SELECT 1 FROM expected AS e WHERE e.id = m.migration_id))
                   THEN ' PASS' ELSE ' FAIL' END
    FROM joined AS j
) AS x
ORDER BY ord;

SELECT 'LEDGER.earlier135 rows=' || count(*) || ' digest='
       || md5(string_agg(migration_id || ':' || checksum_sha256, ',' ORDER BY migration_id COLLATE "C"))
       || CASE WHEN count(*) = 135
                AND md5(string_agg(migration_id || ':' || checksum_sha256, ',' ORDER BY migration_id COLLATE "C"))
                    = 'f7273fa86b93fbbb7faae2e213966d9c'
               THEN ' PASS' ELSE ' FAIL' END
FROM admin.schema_migrations
WHERE left(migration_id, 4) NOT IN ('263_', '270_', '279_', '275_', '276_', '277_', '278_',
                                    '280_', '281_', '282_', '283_', '284_', '285_', '286_');

SELECT 'LEDGER.all149 digest='
       || md5(string_agg(migration_id || ':' || checksum_sha256, ',' ORDER BY migration_id COLLATE "C"))
       || CASE WHEN md5(string_agg(migration_id || ':' || checksum_sha256, ',' ORDER BY migration_id COLLATE "C"))
                    = 'a6d33cb028cef31547d32a4e2f14ca20'
               THEN ' PASS' ELSE ' FAIL' END
FROM admin.schema_migrations;

-- Function definitions after B2 (signature, body, SECURITY DEFINER,
-- volatility, search_path, return type) and execute privileges.
WITH expected (key, sig, def_md5, x_public, x_app, x_grafana) AS (VALUES
    ('canonical_read',      'analytics.get_canonical_energy_read(bigint, uuid, timestamptz, timestamptz, text, text)',                      'bb58dfbce89f2d4a40b3144f2b074efd', false, false, true),
    ('source_windows',      'analytics.resolve_asset_energy_source_windows(uuid, text, timestamptz, timestamptz)',                         '06389c4358f4cf459ab5a40be517492a', false, false, false),
    ('direction_status',    'analytics.energy_direction_status(bigint, bigint, bigint, bigint, bigint, bigint)',                           '5e819bc3389b65f607a466a49f894da6', false, false, false),
    ('rollup_15min_range',  'analytics.energy_semantic_rollup_15min_range(uuid, uuid[], timestamptz, timestamptz)',                         '699357117e9ab97b920a3ad2881ace5f', false, false, false),
    ('floors',              'analytics.get_analytics_energy_resolution_floors()',                                                         '041685567a24b9333a24e3f27cf3a803', false, true,  false),
    ('floors_site',         'analytics.get_analytics_energy_resolution_floors(uuid, timestamptz)',                                        'a8969199ff61e2e87debafb1f794865d', false, true,  false),
    ('catalog',             'analytics.get_portal_analytics_catalog(bigint, uuid)',                                                       '586a533d408fdae936705f25dfd94f63', false, true,  false),
    ('availability',        'analytics.get_portal_analytics_energy_availability(bigint, uuid)',                                           'ab4e1d4d8c4ef1763f372c41541b96dd', false, true,  false),
    ('asset_series',        'analytics.get_portal_asset_energy_series(bigint, uuid, uuid[], timestamptz, timestamptz, text, timestamptz)', '3f43cdae3e4dbb21087d31bc77c7bab0', false, true,  false),
    ('tz_trigger_fn',       'metadata.prevent_site_timezone_change_with_telemetry()',                                                     '3a00669bb60a8fc711e3b482e142673b', false, false, false)
)
SELECT 'POST.fn_' || e.key || ' def=' || coalesce(md5(pg_get_functiondef(p.oid)), 'missing')
       || CASE WHEN p.oid IS NOT NULL
                AND md5(pg_get_functiondef(p.oid)) = e.def_md5
                AND pg_get_userbyid(p.proowner) = 'ems_admin'
                AND has_function_privilege('public', p.oid, 'EXECUTE') = e.x_public
                AND has_function_privilege('ems_app', p.oid, 'EXECUTE') = e.x_app
                AND has_function_privilege('grafana_reader', p.oid, 'EXECUTE') = e.x_grafana
               THEN ' PASS' ELSE ' FAIL' END
FROM expected AS e
LEFT JOIN pg_proc AS p ON p.oid = to_regprocedure(e.sig)
ORDER BY e.key;

-- Dropped by 280 / 282: the canonical-read-era Analytics series and the
-- 6-argument asset series. The availability comment is 280's (286, 288 pin).
SELECT 'POST.dropped remaining=' || count(*) FILTER (WHERE to_regprocedure(sig) IS NOT NULL)
       || CASE WHEN count(*) FILTER (WHERE to_regprocedure(sig) IS NOT NULL) = 0 THEN ' PASS' ELSE ' FAIL' END
FROM (VALUES ('analytics.get_portal_analytics_energy_series(bigint, uuid, uuid[], timestamptz, timestamptz, text)'),
             ('analytics.get_portal_asset_energy_series(bigint, uuid, uuid[], timestamptz, timestamptz, text)')) AS d (sig);

SELECT 'POST.availability_comment md5=' || coalesce(md5(obj_description(to_regprocedure('analytics.get_portal_analytics_energy_availability(bigint, uuid)'), 'pg_proc')), 'none')
       || CASE WHEN md5(obj_description(to_regprocedure('analytics.get_portal_analytics_energy_availability(bigint, uuid)'), 'pg_proc'))
                    = 'bb352ba5380264118a27d102d7a1a70b'
               THEN ' PASS' ELSE ' FAIL' END;

-- 275: the site time-zone guard is installed and enabled.
SELECT 'POST.tz_trigger sites_prevent_timezone_change_with_telemetry enabled=' || coalesce(max(t.tgenabled::TEXT), 'missing')
       || CASE WHEN count(*) = 1 AND max(t.tgenabled::TEXT) = 'O'
                AND bool_and(t.tgfoid = to_regprocedure('metadata.prevent_site_timezone_change_with_telemetry()'))
               THEN ' PASS' ELSE ' FAIL' END
FROM pg_trigger AS t
WHERE t.tgrelid = 'metadata.sites'::regclass AND t.tgname = 'sites_prevent_timezone_change_with_telemetry';

-- The canonical read's new source (263) is still the 56-asset parity bridge.
SELECT 'POST.bridge rows=' || count(*) FILTER (WHERE effective_from = '-infinity')
       || ' assets=' || count(DISTINCT asset_id) FILTER (WHERE effective_from = '-infinity')
       || ' non_bridge=' || count(*) FILTER (WHERE effective_from <> '-infinity')
       || CASE WHEN count(*) FILTER (WHERE effective_from = '-infinity') = 112
                AND count(DISTINCT asset_id) FILTER (WHERE effective_from = '-infinity') = 56
                AND count(*) FILTER (WHERE effective_from <> '-infinity') = 0
               THEN ' PASS' ELSE ' FAIL' END
FROM metadata.asset_points;

-- Health: failure baseline, no failing job, no new job error, Energy jobs
-- succeeding, no lock waiters, paused jobs unchanged, 1h tier advancing.
-- "failing" reads each job's last completed run from the stats catalog: while
-- a job runs, job_stats.last_run_status is NULL (see the job lines below), so
-- a running job whose previous run failed would otherwise not count.
SELECT 'HEALTH.failures total(excl. 1114)=' || coalesce(t.failures::TEXT, 'none') || ' failing=' || f.failing
       || CASE WHEN t.failures = 2840 AND f.failing = 0 THEN ' PASS' ELSE ' FAIL' END
FROM (SELECT sum(total_failures) FILTER (WHERE job_id <> 1114) AS failures FROM timescaledb_information.job_stats) AS t
CROSS JOIN (SELECT count(*) AS failing FROM _timescaledb_internal.bgw_job_stat
            WHERE job_id <> 1114 AND last_run_success IS NOT TRUE) AS f;

SELECT 'HEALTH.errors job errors since 2026-10-17 12:00 UTC=' || count(*) || CASE WHEN count(*) = 0 THEN ' PASS' ELSE ' FAIL' END
FROM timescaledb_information.job_errors WHERE start_time >= '2026-10-17 12:00+00';

-- Energy jobs succeeding after the deploy; same rule as the precheck's JOBS
-- lines. TimescaleDB marks a run's start by setting the stats row's
-- last_finish to -infinity, so job_stats.last_run_status is NULL while the job
-- runs; last_run_success, consecutive_failures and total_failures still
-- describe the last completed run. Scheduled: latest completed run 'Success'.
-- Running: previous completed run succeeded, a successful finish recorded
-- (the catalog stores "never" as -infinity) and the failure total still 2840.
-- Anything else (Paused, missing job or stats row, ambiguous evidence, one
-- job_stats row per status) fails closed; every part is coalesced.
WITH s AS (
    SELECT DISTINCT job_id, job_status, last_run_status, last_run_started_at, last_run_duration
    FROM timescaledb_information.job_stats
),
total AS (
    SELECT sum(total_failures) FILTER (WHERE job_id <> 1114) AS failures FROM timescaledb_information.job_stats
)
SELECT 'HEALTH.job' || e.job_id || ' ' || coalesce(s.job_status, 'missing')
       || ' last_run=' || coalesce(s.last_run_status, 'none')
       || ' started ' || coalesce(to_char(s.last_run_started_at, 'HH24:MI:SS'), '-')
       || ' (' || coalesce(round(extract(epoch FROM s.last_run_duration)::NUMERIC, 2)::TEXT, '-') || ' s)'
       || ' previous_completed=' || CASE js.last_run_success WHEN true THEN 'Success' WHEN false THEN 'Failed' ELSE 'unknown' END
       || ' consecutive_failures=' || coalesce(js.consecutive_failures::TEXT, '-')
       || ' total_failures=' || coalesce(js.total_failures::TEXT, '-')
       || CASE
              WHEN s.job_status = 'Scheduled'
                   AND s.last_run_status = 'Success'
                   AND js.last_run_success IS TRUE AND js.consecutive_failures = 0
                  THEN ' PASS'
              WHEN s.job_status = 'Running'
                   AND js.last_run_success IS TRUE AND js.consecutive_failures = 0
                   AND js.last_successful_finish > '-infinity'::TIMESTAMPTZ
                   AND (SELECT failures FROM total) = 2840
                  THEN ' PASS'
              ELSE ' FAIL'
          END
FROM (VALUES (1062), (1063), (1064), (1097), (1100), (1103)) AS e (job_id)
LEFT JOIN s ON s.job_id = e.job_id
LEFT JOIN _timescaledb_internal.bgw_job_stat AS js ON js.job_id = e.job_id
ORDER BY e.job_id, s.job_status;

SELECT 'HEALTH.lock_waiters=' || count(*) || CASE WHEN count(*) = 0 THEN ' PASS' ELSE ' FAIL' END
FROM pg_stat_activity WHERE pid <> pg_backend_pid() AND wait_event_type = 'Lock';

SELECT 'HEALTH.paused 1053 + 1114-1120 present=' || count(j.job_id) || ' unscheduled=' || count(*) FILTER (WHERE NOT j.scheduled)
       || CASE WHEN count(j.job_id) = 8 AND count(*) FILTER (WHERE NOT j.scheduled) = 8 THEN ' PASS' ELSE ' FAIL' END
FROM (VALUES (1053), (1114), (1115), (1116), (1117), (1118), (1119), (1120)) AS e (job_id)
LEFT JOIN timescaledb_information.jobs AS j ON j.job_id = e.job_id;

SELECT 'HEALTH.1h_checkpoint ' || coalesce(p.last_received_at::TEXT, '-') || ' ' || coalesce(p.last_status, 'none')
       || CASE WHEN p.last_status = 'SUCCESS' THEN ' PASS' ELSE ' FAIL' END
FROM (SELECT 1) AS one
LEFT JOIN telemetry.pipeline_state AS p ON p.pipeline_name = 'point_telemetry_1h';

-- Evidence for 282's stale flag (release note): routing lag. A missing row
-- or NULL timestamp prints 'unknown'.
SELECT 'INFO routing lag energy=' || coalesce(extract(epoch FROM n.last_received_at - e.last_received_at)::INT || ' s', 'unknown')
       || ' environment=' || coalesce(extract(epoch FROM n.last_received_at - v.last_received_at)::INT || ' s', 'unknown')
FROM (SELECT 1) AS one
LEFT JOIN telemetry.pipeline_state AS n ON n.pipeline_name = 'normalized_points'
LEFT JOIN telemetry.pipeline_state AS e ON e.pipeline_name = 'energy_measurements'
LEFT JOIN telemetry.pipeline_state AS v ON v.pipeline_name = 'environment_measurements';

SELECT 'END prod_b2_postcheck';

ROLLBACK;
