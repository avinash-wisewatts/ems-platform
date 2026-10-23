-- ============================================================================
-- Migration 307
-- Energy consumption views: join only the total-register semantics rows
--
-- analytics.v_energy_consumption_1min and analytics.v_energy_consumption_15min
-- attach config.energy_register_semantics to every bucket by profile and flow
-- (GRID_IMPORT / GRID_EXPORT). A profile carries one active semantics row per
-- register (L1, L2, L3, TOTAL), so the baseline 001 bodies return 4 x 4 = 16
-- rows per device bucket, each classified with a different register's
-- rollover / reset / max-delta rules.
--
-- Production already runs the corrected bodies: both joins also require
-- logical_point_id = ENERGY_IMPORT_TOTAL / ENERGY_EXPORT_TOTAL, so each bucket
-- yields exactly one row. That fix predates the 2026-08-07 baseline and was
-- never captured in the repository; staging and fresh databases still carry
-- the 001 bodies (staging/production parity audit, 2026-10-23, H1).
--
-- This migration adopts the production bodies verbatim
-- (pg_get_viewdef(oid, true) on production, 2026-10-23). Nothing else changes:
-- the column list, owner, security_barrier, grants and comments are kept and
-- checked. The persisted energy tiers (refresh_energy_consumption_*) already
-- filter on the total registers and are not touched. Dependent views
-- (v_asset_consumption_15min, v_site_energy_balance_daily,
-- v_grafana_asset_energy_intervals) keep their definitions and simply read one
-- row per bucket.
--
-- Precondition: each view is either the baseline 001 body (staging, fresh
-- databases) or already the corrected body (production). On production the
-- statements are therefore a no-op by definition.
--
-- Rollback: re-apply the two CREATE OR REPLACE VIEW statements from
-- postgres/migrations/001_ems_platform_baseline_20260807.sql with
-- WITH (security_barrier = true). Applying this migration changes no data.
-- ============================================================================

DO $pre$
DECLARE
    v_1min  text := md5(pg_get_viewdef('analytics.v_energy_consumption_1min'::regclass));
    v_15min text := md5(pg_get_viewdef('analytics.v_energy_consumption_15min'::regclass));
BEGIN
    -- 001 body (staging 2026-10-23) or the corrected body (production 2026-10-23).
    IF v_1min NOT IN ('8435a69ba516afc0d245ac91aaa7a1eb', '2c75df8831276bdd8643f2d90147ffad') THEN
        RAISE EXCEPTION 'Migration 307 precondition failed: analytics.v_energy_consumption_1min body md5 % is neither the 001 nor the corrected definition', v_1min;
    END IF;
    IF v_15min NOT IN ('4841e5d1b1edb96a13d0bc9a7257648d', '8a6d00ca3464cc890fe474dd3bec18a4') THEN
        RAISE EXCEPTION 'Migration 307 precondition failed: analytics.v_energy_consumption_15min body md5 % is neither the 001 nor the corrected definition', v_15min;
    END IF;
END
$pre$;

CREATE TEMP TABLE migration_307_before ON COMMIT DROP AS
SELECT c.relname,
       pg_get_userbyid(c.relowner) AS owner,
       c.reloptions,
       c.relacl,
       obj_description(c.oid, 'pg_class') AS comment,
       (SELECT string_agg(a.attname || ':' || format_type(a.atttypid, a.atttypmod), ',' ORDER BY a.attnum)
        FROM pg_attribute AS a
        WHERE a.attrelid = c.oid AND a.attnum > 0 AND NOT a.attisdropped) AS columns
FROM pg_class AS c
WHERE c.oid IN ('analytics.v_energy_consumption_1min'::regclass,
                'analytics.v_energy_consumption_15min'::regclass);

CREATE OR REPLACE VIEW analytics.v_energy_consumption_1min
WITH (security_barrier = true) AS
 WITH eligible_buckets AS (
         SELECT ca.bucket_start,
            ca.organization_id,
            ca.site_id,
            ca.device_id,
            ca.sample_count,
            ca.import_energy_total_wh_max,
            ca.import_energy_total_wh_min,
            ca.export_energy_total_wh_max,
            ca.export_energy_total_wh_min,
            ca.reactive_energy_total_varh_max,
            ca.reactive_energy_total_varh_min,
            ca.reactive_export_energy_total_varh_max,
            ca.reactive_export_energy_total_varh_min,
            ca.apparent_energy_total_vah_max,
            ca.apparent_energy_total_vah_min,
            ca.active_power_total_w_avg,
            ca.active_power_total_w_min,
            ca.active_power_total_w_max,
            ca.active_power_l1_w_avg,
            ca.active_power_l2_w_avg,
            ca.active_power_l3_w_avg,
            ca.reactive_power_total_var_avg,
            ca.reactive_power_total_var_min,
            ca.reactive_power_total_var_max,
            ca.apparent_power_total_va_avg,
            ca.apparent_power_total_va_min,
            ca.apparent_power_total_va_max,
            ca.voltage_l1_v_avg,
            ca.voltage_l1_v_min,
            ca.voltage_l1_v_max,
            ca.voltage_l2_v_avg,
            ca.voltage_l2_v_min,
            ca.voltage_l2_v_max,
            ca.voltage_l3_v_avg,
            ca.voltage_l3_v_min,
            ca.voltage_l3_v_max,
            ca.current_l1_a_avg,
            ca.current_l1_a_min,
            ca.current_l1_a_max,
            ca.current_l2_a_avg,
            ca.current_l2_a_min,
            ca.current_l2_a_max,
            ca.current_l3_a_avg,
            ca.current_l3_a_min,
            ca.current_l3_a_max,
            ca.power_factor_total_avg,
            ca.power_factor_total_min,
            ca.power_factor_total_max,
            ca.frequency_hz_avg,
            ca.frequency_hz_min,
            ca.frequency_hz_max,
            ca.current_thd_l1_percent_avg,
            ca.current_thd_l1_percent_max,
            ca.current_thd_l2_percent_avg,
            ca.current_thd_l2_percent_max,
            ca.current_thd_l3_percent_avg,
            ca.current_thd_l3_percent_max,
            ca.active_power_sample_count,
            ca.import_energy_sample_count,
            ca.voltage_l1_sample_count,
            ca.current_l1_sample_count
           FROM telemetry.ca_energy_1min ca
             CROSS JOIN LATERAL telemetry.resolve_site_capture_bucket(ca.site_id, ca.bucket_start) capture_policy(policy_id, capture_interval_seconds, late_arrival_tolerance_seconds, site_timezone, bucket_start)
          WHERE capture_policy.policy_id IS NOT NULL AND capture_policy.capture_interval_seconds <= 60
        ), ordered_registers AS (
         SELECT gom.grafana_org_id,
            ca.bucket_start,
            ca.organization_id,
            ca.site_id,
            ca.device_id,
            ca.sample_count,
            d.profile_id,
            d.external_id,
            d.name AS device_name,
            ca.import_energy_total_wh_max AS import_register_wh,
            ca.export_energy_total_wh_max AS export_register_wh,
            lag(ca.bucket_start) OVER (PARTITION BY gom.grafana_org_id, ca.organization_id, ca.site_id, ca.device_id ORDER BY ca.bucket_start) AS previous_bucket_start,
            lag(ca.import_energy_total_wh_max) OVER (PARTITION BY gom.grafana_org_id, ca.organization_id, ca.site_id, ca.device_id ORDER BY ca.bucket_start) AS previous_import_register_wh,
            lag(ca.export_energy_total_wh_max) OVER (PARTITION BY gom.grafana_org_id, ca.organization_id, ca.site_id, ca.device_id ORDER BY ca.bucket_start) AS previous_export_register_wh
           FROM eligible_buckets ca
             JOIN metadata.grafana_organization_map gom ON gom.organization_id = ca.organization_id AND gom.is_active = true
             JOIN metadata.devices d ON d.id = ca.device_id
        ), semantic_context AS (
         SELECT o.grafana_org_id,
            o.bucket_start,
            o.organization_id,
            o.site_id,
            o.device_id,
            o.sample_count,
            o.profile_id,
            o.external_id,
            o.device_name,
            o.import_register_wh,
            o.export_register_wh,
            o.previous_bucket_start,
            o.previous_import_register_wh,
            o.previous_export_register_wh,
            EXTRACT(epoch FROM o.bucket_start - o.previous_bucket_start) / 60.0 AS elapsed_minutes,
            import_sem.counter_direction AS import_counter_direction,
            import_sem.rollover_behavior AS import_rollover_behavior,
            import_sem.rollover_value AS import_rollover_value,
            import_sem.reset_behavior AS import_reset_behavior,
            import_sem.expected_max_interval_delta AS import_expected_max_delta_wh,
            export_sem.counter_direction AS export_counter_direction,
            export_sem.rollover_behavior AS export_rollover_behavior,
            export_sem.rollover_value AS export_rollover_value,
            export_sem.reset_behavior AS export_reset_behavior,
            export_sem.expected_max_interval_delta AS export_expected_max_delta_wh
           FROM ordered_registers o
             LEFT JOIN config.energy_register_semantics import_sem ON import_sem.profile_id = o.profile_id AND import_sem.flow_interpretation = 'GRID_IMPORT'::text AND import_sem.logical_point_id = (( SELECT lp.id
                   FROM metadata.logical_points lp
                  WHERE lp.name = 'ENERGY_IMPORT_TOTAL'::text
                 LIMIT 1)) AND import_sem.is_active = true
             LEFT JOIN config.energy_register_semantics export_sem ON export_sem.profile_id = o.profile_id AND export_sem.flow_interpretation = 'GRID_EXPORT'::text AND export_sem.logical_point_id = (( SELECT lp.id
                   FROM metadata.logical_points lp
                  WHERE lp.name = 'ENERGY_EXPORT_TOTAL'::text
                 LIMIT 1)) AND export_sem.is_active = true
        )
 SELECT sc.grafana_org_id,
    sc.bucket_start,
    sc.previous_bucket_start,
    sc.elapsed_minutes,
    sc.organization_id,
    sc.site_id,
    sc.device_id,
    sc.external_id,
    sc.device_name,
    sc.sample_count,
    sc.import_register_wh,
    sc.previous_import_register_wh,
    import_result.delta_wh AS import_consumption_wh,
    import_result.delta_wh / 1000.0 AS import_consumption_kwh,
    import_result.quality_code AS import_quality_code,
    sc.export_register_wh,
    sc.previous_export_register_wh,
    export_result.delta_wh AS export_consumption_wh,
    export_result.delta_wh / 1000.0 AS export_consumption_kwh,
    export_result.quality_code AS export_quality_code,
    import_result.reset_detected OR export_result.reset_detected AS reset_detected,
    import_result.quality_code = 'GAP'::text OR export_result.quality_code = 'GAP'::text AS gap_detected
   FROM semantic_context sc
     CROSS JOIN LATERAL config.resolve_interval_quality_rule(sc.device_id, sc.bucket_start) interval_rule(rule_id, gap_threshold_minutes, resolved_scope, scope_key, effective_from, effective_to)
     CROSS JOIN LATERAL analytics.classify_energy_register_delta(sc.import_register_wh, sc.previous_import_register_wh, sc.elapsed_minutes, sc.import_counter_direction, sc.import_rollover_behavior, sc.import_rollover_value, sc.import_reset_behavior, sc.import_expected_max_delta_wh, interval_rule.gap_threshold_minutes) import_result(delta_wh, quality_code, is_valid, reset_detected, rollover_detected)
     CROSS JOIN LATERAL analytics.classify_energy_register_delta(sc.export_register_wh, sc.previous_export_register_wh, sc.elapsed_minutes, sc.export_counter_direction, sc.export_rollover_behavior, sc.export_rollover_value, sc.export_reset_behavior, sc.export_expected_max_delta_wh, interval_rule.gap_threshold_minutes) export_result(delta_wh, quality_code, is_valid, reset_detected, rollover_detected);

CREATE OR REPLACE VIEW analytics.v_energy_consumption_15min
WITH (security_barrier = true) AS
 WITH ordered_registers AS (
         SELECT gom.grafana_org_id,
            ca.bucket_start,
            ca.organization_id,
            ca.site_id,
            ca.device_id,
            ca.sample_count,
            d.profile_id,
            d.external_id,
            d.name AS device_name,
            ca.import_energy_total_wh_max AS import_register_wh,
            ca.export_energy_total_wh_max AS export_register_wh,
            lag(ca.bucket_start) OVER (PARTITION BY gom.grafana_org_id, ca.organization_id, ca.site_id, ca.device_id ORDER BY ca.bucket_start) AS previous_bucket_start,
            lag(ca.import_energy_total_wh_max) OVER (PARTITION BY gom.grafana_org_id, ca.organization_id, ca.site_id, ca.device_id ORDER BY ca.bucket_start) AS previous_import_register_wh,
            lag(ca.export_energy_total_wh_max) OVER (PARTITION BY gom.grafana_org_id, ca.organization_id, ca.site_id, ca.device_id ORDER BY ca.bucket_start) AS previous_export_register_wh
           FROM telemetry.ca_energy_15min ca
             JOIN metadata.grafana_organization_map gom ON gom.organization_id = ca.organization_id AND gom.is_active = true
             JOIN metadata.devices d ON d.id = ca.device_id
        ), semantic_context AS (
         SELECT o.grafana_org_id,
            o.bucket_start,
            o.organization_id,
            o.site_id,
            o.device_id,
            o.sample_count,
            o.profile_id,
            o.external_id,
            o.device_name,
            o.import_register_wh,
            o.export_register_wh,
            o.previous_bucket_start,
            o.previous_import_register_wh,
            o.previous_export_register_wh,
            EXTRACT(epoch FROM o.bucket_start - o.previous_bucket_start) / 60.0 AS elapsed_minutes,
            import_sem.counter_direction AS import_counter_direction,
            import_sem.rollover_behavior AS import_rollover_behavior,
            import_sem.rollover_value AS import_rollover_value,
            import_sem.reset_behavior AS import_reset_behavior,
            import_sem.expected_max_interval_delta AS import_expected_max_delta_wh,
            export_sem.counter_direction AS export_counter_direction,
            export_sem.rollover_behavior AS export_rollover_behavior,
            export_sem.rollover_value AS export_rollover_value,
            export_sem.reset_behavior AS export_reset_behavior,
            export_sem.expected_max_interval_delta AS export_expected_max_delta_wh
           FROM ordered_registers o
             LEFT JOIN config.energy_register_semantics import_sem ON import_sem.profile_id = o.profile_id AND import_sem.flow_interpretation = 'GRID_IMPORT'::text AND import_sem.logical_point_id = (( SELECT lp.id
                   FROM metadata.logical_points lp
                  WHERE lp.name = 'ENERGY_IMPORT_TOTAL'::text
                 LIMIT 1)) AND import_sem.is_active = true
             LEFT JOIN config.energy_register_semantics export_sem ON export_sem.profile_id = o.profile_id AND export_sem.flow_interpretation = 'GRID_EXPORT'::text AND export_sem.logical_point_id = (( SELECT lp.id
                   FROM metadata.logical_points lp
                  WHERE lp.name = 'ENERGY_EXPORT_TOTAL'::text
                 LIMIT 1)) AND export_sem.is_active = true
        )
 SELECT sc.grafana_org_id,
    sc.bucket_start,
    sc.previous_bucket_start,
    sc.elapsed_minutes,
    sc.organization_id,
    sc.site_id,
    sc.device_id,
    sc.external_id,
    sc.device_name,
    sc.sample_count,
    sc.import_register_wh,
    sc.previous_import_register_wh,
    import_result.delta_wh AS import_consumption_wh,
    import_result.delta_wh / 1000.0 AS import_consumption_kwh,
    import_result.quality_code AS import_quality_code,
    sc.export_register_wh,
    sc.previous_export_register_wh,
    export_result.delta_wh AS export_consumption_wh,
    export_result.delta_wh / 1000.0 AS export_consumption_kwh,
    export_result.quality_code AS export_quality_code,
    import_result.reset_detected OR export_result.reset_detected AS reset_detected,
    import_result.quality_code = 'GAP'::text OR export_result.quality_code = 'GAP'::text AS gap_detected
   FROM semantic_context sc
     CROSS JOIN LATERAL config.resolve_interval_quality_rule(sc.device_id, sc.bucket_start) interval_rule(rule_id, gap_threshold_minutes, resolved_scope, scope_key, effective_from, effective_to)
     CROSS JOIN LATERAL analytics.classify_energy_register_delta(sc.import_register_wh, sc.previous_import_register_wh, sc.elapsed_minutes, sc.import_counter_direction, sc.import_rollover_behavior, sc.import_rollover_value, sc.import_reset_behavior, sc.import_expected_max_delta_wh, interval_rule.gap_threshold_minutes) import_result(delta_wh, quality_code, is_valid, reset_detected, rollover_detected)
     CROSS JOIN LATERAL analytics.classify_energy_register_delta(sc.export_register_wh, sc.previous_export_register_wh, sc.elapsed_minutes, sc.export_counter_direction, sc.export_rollover_behavior, sc.export_rollover_value, sc.export_reset_behavior, sc.export_expected_max_delta_wh, interval_rule.gap_threshold_minutes) export_result(delta_wh, quality_code, is_valid, reset_detected, rollover_detected);

DO $post$
DECLARE
    v_bad text;
BEGIN
    IF md5(pg_get_viewdef('analytics.v_energy_consumption_1min'::regclass)) <> '2c75df8831276bdd8643f2d90147ffad' THEN
        RAISE EXCEPTION 'Migration 307 postcondition failed: analytics.v_energy_consumption_1min is not the corrected definition';
    END IF;
    IF md5(pg_get_viewdef('analytics.v_energy_consumption_15min'::regclass)) <> '8a6d00ca3464cc890fe474dd3bec18a4' THEN
        RAISE EXCEPTION 'Migration 307 postcondition failed: analytics.v_energy_consumption_15min is not the corrected definition';
    END IF;

    SELECT string_agg(b.relname, ', ')
    INTO v_bad
    FROM migration_307_before AS b
    JOIN pg_class AS c ON c.relname = b.relname
                      AND c.relnamespace = 'analytics'::regnamespace
    WHERE (pg_get_userbyid(c.relowner), c.reloptions, c.relacl, obj_description(c.oid, 'pg_class'),
           (SELECT string_agg(a.attname || ':' || format_type(a.atttypid, a.atttypmod), ',' ORDER BY a.attnum)
            FROM pg_attribute AS a
            WHERE a.attrelid = c.oid AND a.attnum > 0 AND NOT a.attisdropped))
          IS DISTINCT FROM
          (b.owner, b.reloptions, b.relacl, b.comment, b.columns);
    IF v_bad IS NOT NULL THEN
        RAISE EXCEPTION 'Migration 307 postcondition failed: owner / options / grants / comment / columns changed on %', v_bad;
    END IF;
END
$post$;
