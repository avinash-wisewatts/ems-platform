-- ============================================================================
-- Release B2 (ba2cb4b: migrations 263, 270, 279, 275-278, 280-286)
-- pre-dispatch check. READ-ONLY.
--
-- Run immediately before dispatching deploy-production.yml for B2, and only
-- with explicit authorization, through the read-only session settings
-- (default_transaction_read_only=on). Catalog and small-table reads only.
--
-- Output contract (checked by prod_b2_gate.py precheck): unaligned, one line
-- per check, '<KEY> <evidence> PASS|FAIL'; 'now ' and 'INFO ' lines are
-- evidence only; the last line is 'END prod_b2_precheck'. Any FAIL, missing,
-- duplicate or unexpected line, or a non-zero psql exit means do not
-- dispatch.
--
-- P2 (pending set) is checked here, not with `apply_migrations.sh --status`:
-- the host checkout is still at the previous release. The 149 migration rows
-- of ba2cb4b's manifest are embedded below, in order; the rows production
-- has not applied must be exactly B2's 14, in manifest order.
--
-- Expected values (2026-10-20; equal on the production ledger read and on a
-- local database built at 546a718):
--   ledger 135 rows; md5 of migration_id:checksum ordered by migration_id
--   (COLLATE "C") = f7273fa86b93fbbb7faae2e213966d9c.
--   get_canonical_energy_read = migration 269's body (md5 of prosrc
--   57470d84ec0b2731be67d114c98f3f04); 263 replaces it.
--   Migration 283's precondition md5(pg_get_viewdef(
--   'analytics.v_energy_semantic_rollup_15min')) = 7a79ad575ed8e50d3b2300e946a23dd2
--   holds only in an Asia/Kolkata session: pg_get_viewdef renders the
--   date_bin origin in the session time zone (UTC gives 394451e7...). The
--   runner sets no time zone, so the role/database default must stay
--   Asia/Kolkata.
--   Failure total (all jobs except 1114) 2840.
-- ============================================================================
\set ON_ERROR_STOP on
\pset footer off
\pset tuples_only on
\pset format unaligned
SET application_name = 'ems_b2_precheck';
SET statement_timeout = '30s';
SET lock_timeout = '2s';

BEGIN READ ONLY;

-- Captured before any SET TIME ZONE: the session default the runner gets.
SELECT 'PRE.runner_tz default TimeZone=' || current_setting('TimeZone')
       || CASE WHEN current_setting('TimeZone') = 'Asia/Kolkata' THEN ' PASS' ELSE ' FAIL' END;

SELECT 'PRE.283_viewdef md5(pg_get_viewdef(v_energy_semantic_rollup_15min)) in Asia/Kolkata='
       || md5(pg_get_viewdef('analytics.v_energy_semantic_rollup_15min'::regclass))
       || CASE WHEN current_setting('TimeZone') = 'Asia/Kolkata'
                AND md5(pg_get_viewdef('analytics.v_energy_semantic_rollup_15min'::regclass))
                    = '7a79ad575ed8e50d3b2300e946a23dd2'
               THEN ' PASS' ELSE ' FAIL' END;

SET LOCAL TIME ZONE 'UTC';

SELECT 'now ' || now();

SELECT 'SESSION.readonly default_transaction_read_only=' || current_setting('default_transaction_read_only')
       || CASE WHEN current_setting('default_transaction_read_only') = 'on' THEN ' PASS' ELSE ' FAIL' END;

-- The runner connects as ems_admin to ems; PRE.runner_tz is only meaningful
-- for the same role and database.
SELECT 'SESSION.identity ' || current_user || '@' || current_database()
       || CASE WHEN current_user = 'ems_admin' AND current_database() = 'ems' THEN ' PASS' ELSE ' FAIL' END;

-- P1: the ledger is exactly the B1 state.
SELECT 'P1.ledger rows=' || count(*) || ' digest='
       || md5(string_agg(migration_id || ':' || checksum_sha256, ',' ORDER BY migration_id COLLATE "C"))
       || CASE WHEN count(*) = 135
                AND md5(string_agg(migration_id || ':' || checksum_sha256, ',' ORDER BY migration_id COLLATE "C"))
                    = 'f7273fa86b93fbbb7faae2e213966d9c'
               THEN ' PASS' ELSE ' FAIL' END
FROM admin.schema_migrations;

-- P2: pending = manifest(ba2cb4b) minus ledger, in manifest order.
WITH manifest (ord, migration_id) AS (VALUES
    (1, '001_ems_platform_baseline_20260807'),
    (2, '002_remove_legacy_telegraf_ingest_objects'),
    (3, '003_telemetry_pipeline_performance_state'),
    (4, '004_bounded_domain_routing'),
    (5, '005_parameterized_domain_routing'),
    (6, '006_canonical_failure_classification'),
    (7, '007_site_frequency_normalization_recovery'),
    (8, '008_set_based_capture_selection_legacy_recovery'),
    (9, '009_selected_sample_direct_normalization'),
    (10, '010_effective_policy_lookback'),
    (11, '011_site_demand_policy_contract'),
    (12, '012_demand_capability_resolution'),
    (13, '013_demand_calculation_processor'),
    (14, '014_asset_demand_grafana_contract'),
    (15, '015_asset_dashboard_v1_contract'),
    (16, '016_asset_dashboard_runtime_fix'),
    (17, '017_asset_demand_automatic_decoupling'),
    (18, '018_grafana_config_permission_boundary_fix'),
    (19, '019_asset_dashboard_consolidated_read_path_fix'),
    (20, '020_preserve_site_capture_late_arrival_tolerance'),
    (21, '021_asset_raw_connectivity_context'),
    (22, '022_live_telemetry_state'),
    (23, '023_live_telemetry_ingest_ambiguity_fix'),
    (24, '024_live_telemetry_app_schema_access'),
    (25, '025_live_telemetry_canonical_units'),
    (26, '026_live_telemetry_analytics_schema_access'),
    (27, '027_reduce_demand_finalization_grace'),
    (28, '028_persisted_validated_energy_consumption_1min'),
    (29, '029_asset_energy_persisted_read_path'),
    (30, '030_fix_5min_total_register_semantics'),
    (31, '031_persisted_validated_energy_consumption_5min'),
    (32, '032_validated_energy_semantic_rollups'),
    (33, '033_energy_semantic_reporting_contract'),
    (34, '034_energy_semantic_daily_reporting'),
    (35, '035_combined_energy_quality_counters'),
    (36, '036_energy_daily_semantic_compatibility_cutover'),
    (37, '037_site_timezone_relative_energy_views'),
    (38, '038_grafana_telemetry_capture_policy'),
    (39, '039_resolution_aware_native_energy_gap_threshold'),
    (40, '040_grafana_asset_identity_context'),
    (41, '041_energy_semantic_hourly_reporting'),
    (42, '042_canonical_energy_read'),
    (43, '043_canonical_energy_read_grafana_grant'),
    (44, '044_dynamic_grafana_resolution_routing'),
    (45, '153_grafana_asset_connectivity_runtime_grant'),
    (46, '170_grafana_asset_selector'),
    (47, '171_analytics_explorer_metadata_surface'),
    (48, '172_analytics_point_aggregation_semantics'),
    (49, '173_analytics_explorer_short_history'),
    (50, '174_canonical_electrical_logical_point_names'),
    (51, '175_optimize_grafana_short_history'),
    (52, '176_parameter_aware_grafana_short_history'),
    (53, '177_energy_consumption_lifecycle'),
    (54, '178_energy_phase_power_aggregates'),
    (55, '179_persisted_energy_consumption_15min'),
    (56, '180_fix_persisted_energy_consumption_15min'),
    (57, '181_persisted_energy_consumption_hourly'),
    (58, '182_fix_persisted_energy_consumption_hourly'),
    (59, '183_persisted_energy_consumption_daily'),
    (60, '184_persisted_environment_daily'),
    (61, '045_fix_grafana_resolution_thresholds'),
    (62, '046_expand_electrical_caggs_and_routing'),
    (63, '185_analytical_explorer_caggs_and_safeguards'),
    (64, '186_fix_explorer_intervals_time_bucket_qualification'),
    (65, '187_sector_subsector_asset_type_taxonomy'),
    (66, '188_deprecate_legacy_site_sector'),
    (67, '189_split_motors_pumps_conveyors_asset_types'),
    (68, '190_coating_pans_and_189_remap_corrections'),
    (69, '191_fix_capture_policy_boundary_false_positive'),
    (70, '192_capture_interval_only_boundary_check'),
    (71, '193_onboarding_entity_field_parity'),
    (72, '194_fix_job_schedule_drift'),
    (73, '195_grafana_energy_routing_daily_tier'),
    (74, '196_persist_energy_consumption_per_flow_quality'),
    (75, '197_backfill_energy_consumption_per_flow_quality_procedure'),
    (76, '198_guard_reference_data_completeness'),
    (77, '199_commissioning_profile_completeness_gate'),
    (78, '200_canonical_energy_read_pre_policy_range'),
    (79, '201_recovery_supersession_late_arrival_bound'),
    (80, '202_recovery_normalized_points_targeted_lookup'),
    (81, '203_recovery_per_candidate_commit'),
    (82, '204_recovery_supersession_targeted_window'),
    (83, '205_normalization_bounded_catchup_window'),
    (84, '206_recovery_retention_age_population'),
    (85, '207_energy_environment_routing_bounded_catchup_window'),
    (86, '208_analytics_job_hardening'),
    (87, '209_energy_consumption_cascade_watermarks'),
    (88, '210_demand_watermark_refinalization'),
    (89, '211_environment_daily_watermark'),
    (90, '212_normalization_bounded_window'),
    (91, '213_analytical_reconciliation'),
    (92, '214_pipeline_health_view'),
    (93, '215_energy_routing_resolve_electrical_by_name'),
    (94, '216_energy_consumption_calculated_at_value_aware'),
    (95, '217_hourly_forward_window_utc_alignment'),
    (96, '218_recovery_onboarding_aware_deferral'),
    (97, '219_airsense_environmental_sensor_compatibility'),
    (98, '220_recovery_supersession_interval_predicate'),
    (99, '221_normalization_selected_elements_pk_join'),
    (100, '222_recover_failed_raw_messages_comment_restore'),
    (101, '223_semantic_foundation_parameters'),
    (102, '224_asset_space_point_temporal_binding'),
    (103, '225_asset_relationship_foundation'),
    (104, '226_environment_space_binding'),
    (105, '227_parameter_routing_foundation'),
    (106, '228_device_specific_asset_space_point_binding'),
    (107, '229_derived_calculation_foundation'),
    (108, '230_persisted_space_dew_point'),
    (109, '231_analytics_api_query_boundary'),
    (110, '232_analytics_api_hierarchy'),
    (111, '233_analytics_api_demand'),
    (112, '234_analytics_api_power_quality'),
    (113, '235_analytics_api_energy_evidence'),
    (114, '236_analytics_api_energy_typical_reference'),
    (115, '237_analytics_api_telemetry_freshness'),
    (116, '238_mvp7_alert_evaluation'),
    (117, '239_mvp7_alert_evaluation_functions'),
    (118, '240_mvp7_alert_date_filter_state_keying'),
    (119, '241_mvp7_alert_evaluation_transaction_control_fix'),
    (120, '242_mvp7_alert_data_unavailable_lifecycle'),
    (121, '243_raw_message_failure_capture_bounded_catchup_window'),
    (122, '244_analytics_api_asset_energy_intervals'),
    (123, '245_analytics_api_asset_demand'),
    (124, '246_analytics_api_asset_power_trend'),
    (125, '247_analytics_api_energy_availability'),
    (126, '248_analytics_api_energy_consumption_periodic'),
    (127, '250_demand_asset_points_source_boundary'),
    (128, '251_demand_source_confirmed_point_priority'),
    (129, '252_demand_source_boundary_quality_constraints'),
    (130, '264_point_telemetry_15m'),
    (131, '265_point_telemetry_1h'),
    (132, '266_point_telemetry_1h_activation'),
    (133, '267_routing_bounded_window_end'),
    (134, '268_energy_reconstruction_foundations'),
    (135, '269_energy_reconstruction_read_hardening'),
    (136, '263_asset_energy_consumption_asset_points_attribution'),
    (137, '270_canonical_energy_read_selective_device_reads'),
    (138, '279_asset_energy_tier_read'),
    (139, '275_site_timezone_immutable_with_telemetry'),
    (140, '276_analytics_api_catalog'),
    (141, '277_analytics_api_energy_availability'),
    (142, '278_analytics_api_energy_series'),
    (143, '280_analytics_energy_persisted_tier_switch'),
    (144, '281_asset_energy_tier_read_15m_checkpoint_floor'),
    (145, '282_analytics_energy_series_data_quality'),
    (146, '283_analytics_energy_rollup_tail_pruning'),
    (147, '284_analytics_energy_series_set_based_quality'),
    (148, '285_analytics_energy_direction_status_inlinable'),
    (149, '286_analytics_energy_availability_materialized_bounds')
),
pending AS (
    SELECT string_agg(left(m.migration_id, 3), ',' ORDER BY m.ord) AS ids,
           string_agg(m.migration_id, ',' ORDER BY m.ord) AS full_ids
    FROM manifest AS m
    WHERE NOT EXISTS (SELECT 1 FROM admin.schema_migrations AS s WHERE s.migration_id = m.migration_id)
)
SELECT 'P2.pending ' || coalesce(p.ids, 'none')
       || CASE WHEN (SELECT count(*) FROM manifest) = 149
                AND p.full_ids = '263_asset_energy_consumption_asset_points_attribution,'
                              || '270_canonical_energy_read_selective_device_reads,'
                              || '279_asset_energy_tier_read,'
                              || '275_site_timezone_immutable_with_telemetry,'
                              || '276_analytics_api_catalog,'
                              || '277_analytics_api_energy_availability,'
                              || '278_analytics_api_energy_series,'
                              || '280_analytics_energy_persisted_tier_switch,'
                              || '281_asset_energy_tier_read_15m_checkpoint_floor,'
                              || '282_analytics_energy_series_data_quality,'
                              || '283_analytics_energy_rollup_tail_pruning,'
                              || '284_analytics_energy_series_set_based_quality,'
                              || '285_analytics_energy_direction_status_inlinable,'
                              || '286_analytics_energy_availability_materialized_bounds'
               THEN ' PASS' ELSE ' FAIL' END
FROM pending AS p
UNION ALL
SELECT 'P2.ledger_in_manifest rows outside ba2cb4b manifest=' || count(*)
       || CASE WHEN count(*) = 0 THEN ' PASS' ELSE ' FAIL' END
FROM admin.schema_migrations AS s
WHERE NOT EXISTS (SELECT 1 FROM manifest AS m WHERE m.migration_id = s.migration_id);

-- Pre-state that B2's migrations assert or replace.
SELECT 'PRE.canonical_269 md5(prosrc)=' || coalesce(md5(replace(p.prosrc, E'\r', '')), 'missing')
       || CASE WHEN md5(replace(p.prosrc, E'\r', '')) = '57470d84ec0b2731be67d114c98f3f04' THEN ' PASS' ELSE ' FAIL' END
FROM (SELECT 1) AS one
LEFT JOIN pg_proc AS p
  ON p.oid = to_regprocedure('analytics.get_canonical_energy_read(bigint, uuid, timestamptz, timestamptz, text, text)');

-- Objects the migrations' preconditions require (263, 275-279, 283).
SELECT 'PRE.deps present=' || count(*) FILTER (WHERE ok) || '/' || count(*)
       || coalesce(' missing=' || string_agg(name, ',') FILTER (WHERE NOT ok), '')
       || CASE WHEN bool_and(ok) THEN ' PASS' ELSE ' FAIL' END
FROM (VALUES
    ('metadata.asset_points',                    to_regclass('metadata.asset_points') IS NOT NULL),
    ('metadata.asset_points.device_id',          EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'metadata' AND table_name = 'asset_points' AND column_name = 'device_id')),
    ('metadata.logical_points.qualifier',        EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'metadata' AND table_name = 'logical_points' AND column_name = 'qualifier')),
    ('logical_point ENERGY_IMPORT_TOTAL',        EXISTS (SELECT 1 FROM metadata.logical_points WHERE name = 'ENERGY_IMPORT_TOTAL')),
    ('logical_point ENERGY_EXPORT_TOTAL',        EXISTS (SELECT 1 FROM metadata.logical_points WHERE name = 'ENERGY_EXPORT_TOTAL')),
    ('metadata.sites.timezone',                  EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'metadata' AND table_name = 'sites' AND column_name = 'timezone')),
    ('analytics.v_energy_consumption_native',    to_regclass('analytics.v_energy_consumption_native') IS NOT NULL),
    ('analytics.v_energy_reporting_5min',        to_regclass('analytics.v_energy_reporting_5min') IS NOT NULL),
    ('analytics.v_energy_reporting_15min',       to_regclass('analytics.v_energy_reporting_15min') IS NOT NULL),
    ('analytics.v_energy_reporting_hourly',      to_regclass('analytics.v_energy_reporting_hourly') IS NOT NULL),
    ('analytics.v_energy_reporting_daily',       to_regclass('analytics.v_energy_reporting_daily') IS NOT NULL),
    ('analytics.v_energy_semantic_rollup_15min', to_regclass('analytics.v_energy_semantic_rollup_15min') IS NOT NULL),
    ('native.is_measured_interval',              EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'analytics' AND table_name = 'v_energy_consumption_native' AND column_name = 'is_measured_interval')),
    ('daily.export_reconstructed_intervals',     EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'analytics' AND table_name = 'v_energy_reporting_daily' AND column_name = 'export_reconstructed_intervals')),
    ('15min.import_reconstructed_intervals',     EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'analytics' AND table_name = 'energy_consumption_15min' AND column_name = 'import_reconstructed_intervals')),
    ('analytics.energy_consumption_15min',       to_regclass('analytics.energy_consumption_15min') IS NOT NULL),
    ('analytics.energy_consumption_hourly',      to_regclass('analytics.energy_consumption_hourly') IS NOT NULL),
    ('analytics.energy_consumption_daily',       to_regclass('analytics.energy_consumption_daily') IS NOT NULL),
    ('analytics.point_telemetry_1h',             to_regclass('analytics.point_telemetry_1h') IS NOT NULL),
    ('telemetry.normalized_points',              to_regclass('telemetry.normalized_points') IS NOT NULL),
    ('telemetry.pipeline_state',                 to_regclass('telemetry.pipeline_state') IS NOT NULL),
    ('telemetry.resolve_site_capture_bucket',    to_regprocedure('telemetry.resolve_site_capture_bucket(uuid, timestamptz)') IS NOT NULL),
    ('admin.portal_user_can_access_site',        to_regprocedure('admin.portal_user_can_access_site(bigint, uuid)') IS NOT NULL),
    ('admin.list_accessible_assets',             to_regprocedure('admin.list_accessible_assets(bigint)') IS NOT NULL),
    ('role ems_admin',                           EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'ems_admin')),
    ('role ems_app',                             EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'ems_app')),
    ('role grafana_reader',                      EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'grafana_reader'))
) AS d (name, ok);

-- Nothing B2 creates exists yet (any signature).
SELECT 'PRE.b2_absent existing=' || count(*)
       || coalesce(' [' || string_agg(n.nspname || '.' || p.proname, ',') || ']', '')
       || CASE WHEN count(*) = 0 THEN ' PASS' ELSE ' FAIL' END
FROM pg_proc AS p JOIN pg_namespace AS n ON n.oid = p.pronamespace
WHERE (n.nspname, p.proname) IN (
    ('analytics', 'resolve_asset_energy_source_windows'), ('analytics', 'energy_direction_status'),
    ('analytics', 'get_portal_asset_energy_series'), ('analytics', 'get_portal_analytics_catalog'),
    ('analytics', 'get_portal_analytics_energy_availability'), ('analytics', 'get_portal_analytics_energy_series'),
    ('analytics', 'get_analytics_energy_resolution_floors'), ('analytics', 'energy_semantic_rollup_15min_range'),
    ('metadata', 'prevent_site_timezone_change_with_telemetry'));

SELECT 'PRE.trigger_absent sites_prevent_timezone_change_with_telemetry=' || count(*)
       || CASE WHEN count(*) = 0 THEN ' PASS' ELSE ' FAIL' END
FROM pg_trigger
WHERE tgrelid = 'metadata.sites'::regclass AND tgname = 'sites_prevent_timezone_change_with_telemetry';

-- P5: the parity bridge (R10) and the capture asset set are the same 56
-- assets: 263 switches the canonical read from PRIMARY_METER to asset_points.
SELECT 'P5.bridge rows=' || count(*) FILTER (WHERE effective_from = '-infinity')
       || ' assets=' || count(DISTINCT asset_id) FILTER (WHERE effective_from = '-infinity')
       || ' non_bridge=' || count(*) FILTER (WHERE effective_from <> '-infinity')
       || CASE WHEN count(*) FILTER (WHERE effective_from = '-infinity') = 112
                AND count(DISTINCT asset_id) FILTER (WHERE effective_from = '-infinity') = 56
                AND count(*) FILTER (WHERE effective_from <> '-infinity') = 0
               THEN ' PASS' ELSE ' FAIL' END
FROM metadata.asset_points;

WITH capture AS (
    SELECT DISTINCT ad.asset_id
    FROM metadata.asset_devices AS ad
    JOIN metadata.assets AS a ON a.id = ad.asset_id
    JOIN metadata.grafana_organization_map AS g ON g.organization_id = a.organization_id AND g.is_active
    WHERE ad.relationship_type = 'PRIMARY_METER'
),
bridge AS (SELECT DISTINCT asset_id FROM metadata.asset_points WHERE effective_from = '-infinity')
SELECT 'P5.capture_set capture=' || (SELECT count(*) FROM capture)
       || ' only_capture=' || (SELECT count(*) FROM capture WHERE asset_id NOT IN (SELECT asset_id FROM bridge))
       || ' only_bridge=' || (SELECT count(*) FROM bridge WHERE asset_id NOT IN (SELECT asset_id FROM capture))
       || CASE WHEN (SELECT count(*) FROM capture) = 56
                AND NOT EXISTS (SELECT 1 FROM capture WHERE asset_id NOT IN (SELECT asset_id FROM bridge))
                AND NOT EXISTS (SELECT 1 FROM bridge WHERE asset_id NOT IN (SELECT asset_id FROM capture))
               THEN ' PASS' ELSE ' FAIL' END;

-- P10: failure baseline, no failing job, paused jobs unchanged, no backfill.
-- "failing" reads each job's last completed run from the stats catalog: while
-- a job runs, job_stats.last_run_status is NULL (see JOBS below), so a
-- running job whose previous run failed would otherwise not count.
SELECT 'P10.failures total(excl. 1114)=' || coalesce(t.failures::TEXT, 'none') || ' failing=' || f.failing
       || CASE WHEN t.failures = 2840 AND f.failing = 0 THEN ' PASS' ELSE ' FAIL' END
FROM (SELECT sum(total_failures) FILTER (WHERE job_id <> 1114) AS failures FROM timescaledb_information.job_stats) AS t
CROSS JOIN (SELECT count(*) AS failing FROM _timescaledb_internal.bgw_job_stat
            WHERE job_id <> 1114 AND last_run_success IS NOT TRUE) AS f;

SELECT 'P10.errors job errors since 2026-10-17 12:00 UTC=' || count(*) || CASE WHEN count(*) = 0 THEN ' PASS' ELSE ' FAIL' END
FROM timescaledb_information.job_errors WHERE start_time >= '2026-10-17 12:00+00';

SELECT 'P10.paused 1053 + 1114-1120 present=' || count(j.job_id) || ' unscheduled=' || count(*) FILTER (WHERE NOT j.scheduled)
       || CASE WHEN count(j.job_id) = 8 AND count(*) FILTER (WHERE NOT j.scheduled) = 8 THEN ' PASS' ELSE ' FAIL' END
FROM (VALUES (1053), (1114), (1115), (1116), (1117), (1118), (1119), (1120)) AS e (job_id)
LEFT JOIN timescaledb_information.jobs AS j ON j.job_id = e.job_id;

SELECT 'P10.backfill sessions=' || count(*) || CASE WHEN count(*) = 0 THEN ' PASS' ELSE ' FAIL' END
FROM pg_stat_activity WHERE query ILIKE 'CALL analytics.backfill_point_telemetry_1h%' AND state = 'active';

-- Energy jobs healthy. TimescaleDB marks a run's start by setting the stats
-- row's last_finish to -infinity, so job_stats.last_run_status is NULL while
-- the job runs; last_run_success, consecutive_failures and total_failures
-- still describe the last completed run. Hence:
--   Scheduled: the latest completed run succeeded (last_run_status 'Success');
--   Running:   the previous completed run succeeded (last_run_success, no
--              consecutive failures, a successful finish recorded: the
--              catalog stores "never" as -infinity, not NULL) and the
--              failure count is unchanged (the total is still 2840; counts
--              only grow, so an unchanged total means an unchanged job count);
--   anything else fails closed: Paused, missing job or stats row, NULL
--   evidence, or one job_stats row per status (duplicate key in the gate).
--   Every part is coalesced, so a line is never blank.
WITH s AS (
    SELECT DISTINCT job_id, job_status, last_run_status FROM timescaledb_information.job_stats
),
total AS (
    SELECT sum(total_failures) FILTER (WHERE job_id <> 1114) AS failures FROM timescaledb_information.job_stats
)
SELECT 'JOBS.' || e.job_id || ' ' || coalesce(s.job_status, 'missing')
       || ' last_run=' || coalesce(s.last_run_status, 'none')
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

-- Lock-queue precondition. B2 alters no hypertable: its relation lock is 275's
-- CREATE TRIGGER on metadata.sites (SHARE ROW EXCLUSIVE); the rest replaces
-- or drops functions.
SELECT 'LOCK.long_xact client sessions in a transaction > 60 s=' || count(*) || CASE WHEN count(*) = 0 THEN ' PASS' ELSE ' FAIL' END
FROM pg_stat_activity
WHERE pid <> pg_backend_pid() AND backend_type = 'client backend'
  AND xact_start < now() - interval '60 seconds';

SELECT 'LOCK.idle_xact idle in transaction=' || count(*) || CASE WHEN count(*) = 0 THEN ' PASS' ELSE ' FAIL' END
FROM pg_stat_activity
WHERE pid <> pg_backend_pid() AND state LIKE 'idle in transaction%';

SELECT 'LOCK.sites sessions holding metadata.sites for > 10 s=' || count(DISTINCT l.pid)
       || coalesce(' [' || string_agg(DISTINCT a.pid || ':' || coalesce(nullif(a.application_name, ''), a.usename), ',') || ']', '')
       || CASE WHEN count(DISTINCT l.pid) = 0 THEN ' PASS' ELSE ' FAIL' END
FROM pg_locks AS l
JOIN pg_stat_activity AS a ON a.pid = l.pid
WHERE l.relation = 'metadata.sites'::regclass
  AND l.pid <> pg_backend_pid()
  AND a.xact_start < now() - interval '10 seconds';

SELECT 'INFO client sessions: ' || coalesce(string_agg(app || ':' || n, ' ' ORDER BY app), 'none')
FROM (SELECT coalesce(nullif(application_name, ''), usename) AS app, count(*) AS n
      FROM pg_stat_activity WHERE backend_type = 'client backend' AND pid <> pg_backend_pid()
      GROUP BY 1) AS x;

SELECT 'END prod_b2_precheck';

ROLLBACK;
