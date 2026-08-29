-- ============================================================================
-- Migration 216 -- value-aware calculated_at for the energy_consumption cascade
--
-- WHAT
--   CREATE OR REPLACE the five analytics.refresh_energy_consumption_TIER
--   functions (1min, 5min, 15min, hourly, daily) with their EXACT current
--   deployed bodies, changing ONE thing in each: the ON CONFLICT ... DO UPDATE
--   assignment of `calculated_at`.
--
--   Before:  calculated_at = EXCLUDED.calculated_at        -- always advances
--   After:   calculated_at = CASE
--                WHEN ROW(every other DO-UPDATE-SET column of the stored row)
--                     IS DISTINCT FROM ROW(the same EXCLUDED columns)
--                THEN EXCLUDED.calculated_at                -- a value changed
--                ELSE this_table.calculated_at              -- nothing changed
--            END;
--
-- WHY
--   `calculated_at` is consumed ONLY by the migration-213 reconcile detectors
--   (analytics.reconcile_energy_deficits: `max(parent.calculated_at) >
--   child.calculated_at`) and the test harness -- nothing user-facing, no
--   Grafana object, and analytics.v_pipeline_health does not read it (verified).
--   The migration-209 forward jobs re-process a trailing overlap window every
--   run; the unconditional bump re-stamped `calculated_at` on rows whose values
--   were byte-identical, so every no-op reprocess manufactured a fresh
--   "recency" deficit one tier down. This makes the hourly (and, transitively,
--   daily) reconcile unable to reach a fixed point in the trailing zone even
--   though the repair itself is correct. Value-aware stamping makes
--   `calculated_at` mean "timestamp of the last recalculation that produced a
--   different stored value", so a no-op upstream refresh no longer creates
--   downstream reconciliation work.
--
-- WHAT IS PRESERVED (byte-for-byte)
--   * Every SELECT / JOIN / WHERE / GROUP BY / column list / aggregation.
--   * The full INSERT column list and the DO UPDATE SET of every value column
--     to EXCLUDED.<col> -- the matched row is STILL updated, so
--     GET DIAGNOSTICS ... = ROW_COUNT and the RETURN value are unchanged, and
--     the migration-208/209 wrapper contract
--     (`last_status = CASE WHEN v_rows = 0 THEN 'NO_SOURCE_DATA' ELSE 'SUCCESS'`)
--     is unaffected.
--   * SECURITY DEFINER, SET search_path, LANGUAGE, RETURNS, ownership, ACLs
--     (CREATE OR REPLACE keeps owner/grants).
--   * The raw -> 1min -> 5min -> 15min -> hourly -> daily lineage and every
--     aggregate definition. No schema / index / job / CAGG / retention /
--     compression / Grafana / application change.
--
-- PATTERN PRECEDENT
--   Migration 210 already uses `<table>.col IS DISTINCT FROM EXCLUDED.col` in an
--   ON CONFLICT DO UPDATE to avoid churning `finalized_at`; migration 191 made
--   config.set_site_telemetry_capture_policy a no-op when nothing changed. This
--   is the same "touched vs changed" principle applied to the cascade.
--
-- NUMERIC SAFETY
--   Every compared column is uuid / bigint / numeric / text / boolean / date /
--   timestamptz. No float/double precision -> no representation jitter; numeric
--   IS DISTINCT FROM is scale-insensitive value equality.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- refresh_energy_consumption_1min
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION analytics.refresh_energy_consumption_1min(p_from timestamp with time zone, p_to timestamp with time zone)
 RETURNS bigint
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'analytics', 'telemetry', 'config', 'metadata'
AS $function$
DECLARE
    v_affected BIGINT := 0;
BEGIN
    IF p_from IS NULL OR p_to IS NULL THEN
        RAISE EXCEPTION
            'p_from and p_to are required';
    END IF;

    IF p_to <= p_from THEN
        RAISE EXCEPTION
            'p_to (%) must be later than p_from (%)',
            p_to,
            p_from;
    END IF;


    INSERT INTO analytics.energy_consumption_1min
    (
        bucket_start,

        organization_id,
        site_id,
        device_id,

        previous_bucket_start,
        elapsed_minutes,

        source_sample_count,

        import_register_wh,
        previous_import_register_wh,
        import_consumption_wh,
        import_consumption_kwh,
        import_quality_code,
        import_is_valid,
        import_reset_detected,
        import_rollover_detected,

        export_register_wh,
        previous_export_register_wh,
        export_consumption_wh,
        export_consumption_kwh,
        export_quality_code,
        export_is_valid,
        export_reset_detected,
        export_rollover_detected,

        gap_detected,

        quality_rule_id,
        gap_threshold_minutes,
        quality_rule_scope,
        quality_rule_scope_key,

        calculated_at
    )

    SELECT
        ca.bucket_start,

        ca.organization_id,
        ca.site_id,
        ca.device_id,

        previous_bucket.bucket_start,

        EXTRACT
        (
            EPOCH FROM
            (
                ca.bucket_start -
                previous_bucket.bucket_start
            )
        ) / 60.0,

        ca.sample_count,

        ca.import_energy_total_wh_max,
        previous_bucket.import_energy_total_wh_max,

        import_result.delta_wh,
        import_result.delta_wh / 1000.0,
        import_result.quality_code,
        import_result.is_valid,
        import_result.reset_detected,
        import_result.rollover_detected,

        ca.export_energy_total_wh_max,
        previous_bucket.export_energy_total_wh_max,

        export_result.delta_wh,
        export_result.delta_wh / 1000.0,
        export_result.quality_code,
        export_result.is_valid,
        export_result.reset_detected,
        export_result.rollover_detected,

        (
            import_result.quality_code = 'GAP'
            OR
            export_result.quality_code = 'GAP'
        ),

        interval_rule.rule_id,
        LEAST(interval_rule.gap_threshold_minutes, 1.500::numeric),
        interval_rule.resolved_scope,
        interval_rule.scope_key,

        clock_timestamp()

    FROM telemetry.ca_energy_1min ca


    -- ------------------------------------------------------------------------
    -- Only use one-minute aggregates during periods where the effective site
    -- capture policy permits one-minute analytics.
    -- ------------------------------------------------------------------------

    CROSS JOIN LATERAL
    telemetry.resolve_site_capture_bucket
    (
        ca.site_id,
        ca.bucket_start
    ) capture_policy


    -- ------------------------------------------------------------------------
    -- Find the previous ELIGIBLE bucket for this same device.
    --
    -- This is deliberately not "bucket_start - 1 minute".
    --
    -- If data disappears from 09:07 through 09:38 and returns at 09:39,
    -- the predecessor remains 09:07. The classifier therefore sees
    -- elapsed_minutes = 32 and can correctly classify the interval as GAP.
    -- ------------------------------------------------------------------------

    LEFT JOIN LATERAL
    (
        SELECT
            previous_ca.bucket_start,
            previous_ca.import_energy_total_wh_max,
            previous_ca.export_energy_total_wh_max

        FROM telemetry.ca_energy_1min previous_ca

        CROSS JOIN LATERAL
        telemetry.resolve_site_capture_bucket
        (
            previous_ca.site_id,
            previous_ca.bucket_start
        ) previous_capture_policy

        WHERE previous_ca.organization_id =
              ca.organization_id

          AND previous_ca.site_id =
              ca.site_id

          AND previous_ca.device_id =
              ca.device_id

          AND previous_ca.bucket_start <
              ca.bucket_start

          AND previous_capture_policy.policy_id
              IS NOT NULL

          AND previous_capture_policy.capture_interval_seconds
              <= 60

        ORDER BY
            previous_ca.bucket_start DESC

        LIMIT 1
    ) previous_bucket
      ON TRUE


    JOIN metadata.devices d
      ON d.id = ca.device_id


    -- ------------------------------------------------------------------------
    -- TOTAL active-import register semantics only.
    --
    -- The historical views joined only on profile + GRID_IMPORT and therefore
    -- matched TOTAL + L1 + L2 + L3, multiplying each interval four times.
    -- The persisted layer explicitly resolves ENERGY_IMPORT_TOTAL.
    -- ------------------------------------------------------------------------

    LEFT JOIN metadata.logical_points import_lp
      ON import_lp.name =
         'ENERGY_IMPORT_TOTAL'

    LEFT JOIN config.energy_register_semantics import_sem
      ON import_sem.profile_id =
         d.profile_id

     AND import_sem.logical_point_id =
         import_lp.id

     AND import_sem.flow_interpretation =
         'GRID_IMPORT'

     AND import_sem.is_active = TRUE


    -- ------------------------------------------------------------------------
    -- TOTAL active-export register semantics only.
    -- ------------------------------------------------------------------------

    LEFT JOIN metadata.logical_points export_lp
      ON export_lp.name =
         'ENERGY_EXPORT_TOTAL'

    LEFT JOIN config.energy_register_semantics export_sem
      ON export_sem.profile_id =
         d.profile_id

     AND export_sem.logical_point_id =
         export_lp.id

     AND export_sem.flow_interpretation =
         'GRID_EXPORT'

     AND export_sem.is_active = TRUE


    -- Effective-dated hierarchical quality rule.

    CROSS JOIN LATERAL
    config.resolve_interval_quality_rule
    (
        ca.device_id,
        ca.bucket_start
    ) interval_rule


    -- Canonical import-register classifier.

    CROSS JOIN LATERAL
    analytics.classify_energy_register_delta
    (
        ca.import_energy_total_wh_max,
        previous_bucket.import_energy_total_wh_max,

        EXTRACT
        (
            EPOCH FROM
            (
                ca.bucket_start -
                previous_bucket.bucket_start
            )
        ) / 60.0,

        import_sem.counter_direction,
        import_sem.rollover_behavior,
        import_sem.rollover_value,
        import_sem.reset_behavior,
        import_sem.expected_max_interval_delta,

        LEAST(interval_rule.gap_threshold_minutes, 1.500::numeric)
    ) import_result


    -- Canonical export-register classifier.

    CROSS JOIN LATERAL
    analytics.classify_energy_register_delta
    (
        ca.export_energy_total_wh_max,
        previous_bucket.export_energy_total_wh_max,

        EXTRACT
        (
            EPOCH FROM
            (
                ca.bucket_start -
                previous_bucket.bucket_start
            )
        ) / 60.0,

        export_sem.counter_direction,
        export_sem.rollover_behavior,
        export_sem.rollover_value,
        export_sem.reset_behavior,
        export_sem.expected_max_interval_delta,

        LEAST(interval_rule.gap_threshold_minutes, 1.500::numeric)
    ) export_result


    WHERE
        ca.bucket_start >= p_from
        AND ca.bucket_start < p_to

        AND capture_policy.policy_id
            IS NOT NULL

        AND capture_policy.capture_interval_seconds
            <= 60


    ON CONFLICT
    (
        device_id,
        bucket_start
    )
    DO UPDATE
    SET
        organization_id =
            EXCLUDED.organization_id,

        site_id =
            EXCLUDED.site_id,

        previous_bucket_start =
            EXCLUDED.previous_bucket_start,

        elapsed_minutes =
            EXCLUDED.elapsed_minutes,

        source_sample_count =
            EXCLUDED.source_sample_count,

        import_register_wh =
            EXCLUDED.import_register_wh,

        previous_import_register_wh =
            EXCLUDED.previous_import_register_wh,

        import_consumption_wh =
            EXCLUDED.import_consumption_wh,

        import_consumption_kwh =
            EXCLUDED.import_consumption_kwh,

        import_quality_code =
            EXCLUDED.import_quality_code,

        import_is_valid =
            EXCLUDED.import_is_valid,

        import_reset_detected =
            EXCLUDED.import_reset_detected,

        import_rollover_detected =
            EXCLUDED.import_rollover_detected,

        export_register_wh =
            EXCLUDED.export_register_wh,

        previous_export_register_wh =
            EXCLUDED.previous_export_register_wh,

        export_consumption_wh =
            EXCLUDED.export_consumption_wh,

        export_consumption_kwh =
            EXCLUDED.export_consumption_kwh,

        export_quality_code =
            EXCLUDED.export_quality_code,

        export_is_valid =
            EXCLUDED.export_is_valid,

        export_reset_detected =
            EXCLUDED.export_reset_detected,

        export_rollover_detected =
            EXCLUDED.export_rollover_detected,

        gap_detected =
            EXCLUDED.gap_detected,

        quality_rule_id =
            EXCLUDED.quality_rule_id,

        gap_threshold_minutes =
            EXCLUDED.gap_threshold_minutes,

        quality_rule_scope =
            EXCLUDED.quality_rule_scope,

        quality_rule_scope_key =
            EXCLUDED.quality_rule_scope_key,

        calculated_at =
            CASE
                WHEN ROW(
                    energy_consumption_1min.organization_id,
                    energy_consumption_1min.site_id,
                    energy_consumption_1min.previous_bucket_start,
                    energy_consumption_1min.elapsed_minutes,
                    energy_consumption_1min.source_sample_count,
                    energy_consumption_1min.import_register_wh,
                    energy_consumption_1min.previous_import_register_wh,
                    energy_consumption_1min.import_consumption_wh,
                    energy_consumption_1min.import_consumption_kwh,
                    energy_consumption_1min.import_quality_code,
                    energy_consumption_1min.import_is_valid,
                    energy_consumption_1min.import_reset_detected,
                    energy_consumption_1min.import_rollover_detected,
                    energy_consumption_1min.export_register_wh,
                    energy_consumption_1min.previous_export_register_wh,
                    energy_consumption_1min.export_consumption_wh,
                    energy_consumption_1min.export_consumption_kwh,
                    energy_consumption_1min.export_quality_code,
                    energy_consumption_1min.export_is_valid,
                    energy_consumption_1min.export_reset_detected,
                    energy_consumption_1min.export_rollover_detected,
                    energy_consumption_1min.gap_detected,
                    energy_consumption_1min.quality_rule_id,
                    energy_consumption_1min.gap_threshold_minutes,
                    energy_consumption_1min.quality_rule_scope,
                    energy_consumption_1min.quality_rule_scope_key
                ) IS DISTINCT FROM ROW(
                    EXCLUDED.organization_id,
                    EXCLUDED.site_id,
                    EXCLUDED.previous_bucket_start,
                    EXCLUDED.elapsed_minutes,
                    EXCLUDED.source_sample_count,
                    EXCLUDED.import_register_wh,
                    EXCLUDED.previous_import_register_wh,
                    EXCLUDED.import_consumption_wh,
                    EXCLUDED.import_consumption_kwh,
                    EXCLUDED.import_quality_code,
                    EXCLUDED.import_is_valid,
                    EXCLUDED.import_reset_detected,
                    EXCLUDED.import_rollover_detected,
                    EXCLUDED.export_register_wh,
                    EXCLUDED.previous_export_register_wh,
                    EXCLUDED.export_consumption_wh,
                    EXCLUDED.export_consumption_kwh,
                    EXCLUDED.export_quality_code,
                    EXCLUDED.export_is_valid,
                    EXCLUDED.export_reset_detected,
                    EXCLUDED.export_rollover_detected,
                    EXCLUDED.gap_detected,
                    EXCLUDED.quality_rule_id,
                    EXCLUDED.gap_threshold_minutes,
                    EXCLUDED.quality_rule_scope,
                    EXCLUDED.quality_rule_scope_key
                )
                THEN EXCLUDED.calculated_at
                ELSE energy_consumption_1min.calculated_at
            END;


    GET DIAGNOSTICS
        v_affected = ROW_COUNT;

    RETURN v_affected;
END;
$function$;

-- ---------------------------------------------------------------------------
-- refresh_energy_consumption_5min
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION analytics.refresh_energy_consumption_5min(p_from timestamp with time zone, p_to timestamp with time zone)
 RETURNS bigint
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'analytics', 'telemetry', 'config', 'metadata'
AS $function$
DECLARE
    v_affected BIGINT := 0;
BEGIN
    IF p_from IS NULL OR p_to IS NULL THEN
        RAISE EXCEPTION
            'p_from and p_to are required';
    END IF;

    IF p_to <= p_from THEN
        RAISE EXCEPTION
            'p_to (%) must be later than p_from (%)',
            p_to,
            p_from;
    END IF;


    INSERT INTO analytics.energy_consumption_5min
    (
        bucket_start,

        organization_id,
        site_id,
        device_id,

        previous_bucket_start,
        elapsed_minutes,

        source_sample_count,

        import_register_wh,
        previous_import_register_wh,
        import_consumption_wh,
        import_consumption_kwh,
        import_quality_code,
        import_is_valid,
        import_reset_detected,
        import_rollover_detected,

        export_register_wh,
        previous_export_register_wh,
        export_consumption_wh,
        export_consumption_kwh,
        export_quality_code,
        export_is_valid,
        export_reset_detected,
        export_rollover_detected,

        gap_detected,

        quality_rule_id,
        gap_threshold_minutes,
        quality_rule_scope,
        quality_rule_scope_key,

        calculated_at
    )

    SELECT
        ca.bucket_start,

        ca.organization_id,
        ca.site_id,
        ca.device_id,

        previous_bucket.bucket_start,

        EXTRACT
        (
            EPOCH FROM
            (
                ca.bucket_start -
                previous_bucket.bucket_start
            )
        ) / 60.0,

        ca.sample_count,

        ca.import_energy_total_wh_max,
        previous_bucket.import_energy_total_wh_max,

        import_result.delta_wh,
        import_result.delta_wh / 1000.0,
        import_result.quality_code,
        import_result.is_valid,
        import_result.reset_detected,
        import_result.rollover_detected,

        ca.export_energy_total_wh_max,
        previous_bucket.export_energy_total_wh_max,

        export_result.delta_wh,
        export_result.delta_wh / 1000.0,
        export_result.quality_code,
        export_result.is_valid,
        export_result.reset_detected,
        export_result.rollover_detected,

        (
            import_result.quality_code = 'GAP'
            OR
            export_result.quality_code = 'GAP'
        ),

        interval_rule.rule_id,
        LEAST(interval_rule.gap_threshold_minutes, 7.500::numeric),
        interval_rule.resolved_scope,
        interval_rule.scope_key,

        clock_timestamp()

    FROM telemetry.ca_energy_5min ca


    -- ------------------------------------------------------------------------
    -- Native five-minute semantics are authoritative only while the site's
    -- effective capture interval is exactly 300 seconds.
    -- ------------------------------------------------------------------------

    CROSS JOIN LATERAL
    telemetry.resolve_site_capture_bucket
    (
        ca.site_id,
        ca.bucket_start
    ) capture_policy


    -- ------------------------------------------------------------------------
    -- Find the previous ELIGIBLE native five-minute bucket for this device.
    --
    -- Never assume "bucket_start - 5 minutes". If one or more source buckets
    -- disappear, elapsed_minutes must reflect the actual gap so the canonical
    -- classifier can apply the effective quality threshold correctly.
    -- ------------------------------------------------------------------------

    LEFT JOIN LATERAL
    (
        SELECT
            previous_ca.bucket_start,
            previous_ca.import_energy_total_wh_max,
            previous_ca.export_energy_total_wh_max

        FROM telemetry.ca_energy_5min previous_ca

        CROSS JOIN LATERAL
        telemetry.resolve_site_capture_bucket
        (
            previous_ca.site_id,
            previous_ca.bucket_start
        ) previous_capture_policy

        WHERE previous_ca.organization_id =
              ca.organization_id

          AND previous_ca.site_id =
              ca.site_id

          AND previous_ca.device_id =
              ca.device_id

          AND previous_ca.bucket_start <
              ca.bucket_start

          AND previous_capture_policy.policy_id
              IS NOT NULL

          AND previous_capture_policy.capture_interval_seconds
              = 300

        ORDER BY
            previous_ca.bucket_start DESC

        LIMIT 1
    ) previous_bucket
      ON TRUE


    JOIN metadata.devices d
      ON d.id = ca.device_id


    -- Canonical TOTAL active-import register semantics only.

    LEFT JOIN metadata.logical_points import_lp
      ON import_lp.name =
         'ENERGY_IMPORT_TOTAL'

    LEFT JOIN config.energy_register_semantics import_sem
      ON import_sem.profile_id =
         d.profile_id

     AND import_sem.logical_point_id =
         import_lp.id

     AND import_sem.flow_interpretation =
         'GRID_IMPORT'

     AND import_sem.is_active = TRUE


    -- Canonical TOTAL active-export register semantics only.

    LEFT JOIN metadata.logical_points export_lp
      ON export_lp.name =
         'ENERGY_EXPORT_TOTAL'

    LEFT JOIN config.energy_register_semantics export_sem
      ON export_sem.profile_id =
         d.profile_id

     AND export_sem.logical_point_id =
         export_lp.id

     AND export_sem.flow_interpretation =
         'GRID_EXPORT'

     AND export_sem.is_active = TRUE


    CROSS JOIN LATERAL
    config.resolve_interval_quality_rule
    (
        ca.device_id,
        ca.bucket_start
    ) interval_rule


    CROSS JOIN LATERAL
    analytics.classify_energy_register_delta
    (
        ca.import_energy_total_wh_max,
        previous_bucket.import_energy_total_wh_max,

        EXTRACT
        (
            EPOCH FROM
            (
                ca.bucket_start -
                previous_bucket.bucket_start
            )
        ) / 60.0,

        import_sem.counter_direction,
        import_sem.rollover_behavior,
        import_sem.rollover_value,
        import_sem.reset_behavior,
        import_sem.expected_max_interval_delta,

        LEAST(interval_rule.gap_threshold_minutes, 7.500::numeric)
    ) import_result


    CROSS JOIN LATERAL
    analytics.classify_energy_register_delta
    (
        ca.export_energy_total_wh_max,
        previous_bucket.export_energy_total_wh_max,

        EXTRACT
        (
            EPOCH FROM
            (
                ca.bucket_start -
                previous_bucket.bucket_start
            )
        ) / 60.0,

        export_sem.counter_direction,
        export_sem.rollover_behavior,
        export_sem.rollover_value,
        export_sem.reset_behavior,
        export_sem.expected_max_interval_delta,

        LEAST(interval_rule.gap_threshold_minutes, 7.500::numeric)
    ) export_result


    WHERE
        ca.bucket_start >= p_from
        AND ca.bucket_start < p_to

        AND capture_policy.policy_id
            IS NOT NULL

        AND capture_policy.capture_interval_seconds
            = 300


    ON CONFLICT
    (
        device_id,
        bucket_start
    )
    DO UPDATE
    SET
        organization_id =
            EXCLUDED.organization_id,

        site_id =
            EXCLUDED.site_id,

        previous_bucket_start =
            EXCLUDED.previous_bucket_start,

        elapsed_minutes =
            EXCLUDED.elapsed_minutes,

        source_sample_count =
            EXCLUDED.source_sample_count,

        import_register_wh =
            EXCLUDED.import_register_wh,

        previous_import_register_wh =
            EXCLUDED.previous_import_register_wh,

        import_consumption_wh =
            EXCLUDED.import_consumption_wh,

        import_consumption_kwh =
            EXCLUDED.import_consumption_kwh,

        import_quality_code =
            EXCLUDED.import_quality_code,

        import_is_valid =
            EXCLUDED.import_is_valid,

        import_reset_detected =
            EXCLUDED.import_reset_detected,

        import_rollover_detected =
            EXCLUDED.import_rollover_detected,

        export_register_wh =
            EXCLUDED.export_register_wh,

        previous_export_register_wh =
            EXCLUDED.previous_export_register_wh,

        export_consumption_wh =
            EXCLUDED.export_consumption_wh,

        export_consumption_kwh =
            EXCLUDED.export_consumption_kwh,

        export_quality_code =
            EXCLUDED.export_quality_code,

        export_is_valid =
            EXCLUDED.export_is_valid,

        export_reset_detected =
            EXCLUDED.export_reset_detected,

        export_rollover_detected =
            EXCLUDED.export_rollover_detected,

        gap_detected =
            EXCLUDED.gap_detected,

        quality_rule_id =
            EXCLUDED.quality_rule_id,

        gap_threshold_minutes =
            EXCLUDED.gap_threshold_minutes,

        quality_rule_scope =
            EXCLUDED.quality_rule_scope,

        quality_rule_scope_key =
            EXCLUDED.quality_rule_scope_key,

        calculated_at =
            CASE
                WHEN ROW(
                    energy_consumption_5min.organization_id,
                    energy_consumption_5min.site_id,
                    energy_consumption_5min.previous_bucket_start,
                    energy_consumption_5min.elapsed_minutes,
                    energy_consumption_5min.source_sample_count,
                    energy_consumption_5min.import_register_wh,
                    energy_consumption_5min.previous_import_register_wh,
                    energy_consumption_5min.import_consumption_wh,
                    energy_consumption_5min.import_consumption_kwh,
                    energy_consumption_5min.import_quality_code,
                    energy_consumption_5min.import_is_valid,
                    energy_consumption_5min.import_reset_detected,
                    energy_consumption_5min.import_rollover_detected,
                    energy_consumption_5min.export_register_wh,
                    energy_consumption_5min.previous_export_register_wh,
                    energy_consumption_5min.export_consumption_wh,
                    energy_consumption_5min.export_consumption_kwh,
                    energy_consumption_5min.export_quality_code,
                    energy_consumption_5min.export_is_valid,
                    energy_consumption_5min.export_reset_detected,
                    energy_consumption_5min.export_rollover_detected,
                    energy_consumption_5min.gap_detected,
                    energy_consumption_5min.quality_rule_id,
                    energy_consumption_5min.gap_threshold_minutes,
                    energy_consumption_5min.quality_rule_scope,
                    energy_consumption_5min.quality_rule_scope_key
                ) IS DISTINCT FROM ROW(
                    EXCLUDED.organization_id,
                    EXCLUDED.site_id,
                    EXCLUDED.previous_bucket_start,
                    EXCLUDED.elapsed_minutes,
                    EXCLUDED.source_sample_count,
                    EXCLUDED.import_register_wh,
                    EXCLUDED.previous_import_register_wh,
                    EXCLUDED.import_consumption_wh,
                    EXCLUDED.import_consumption_kwh,
                    EXCLUDED.import_quality_code,
                    EXCLUDED.import_is_valid,
                    EXCLUDED.import_reset_detected,
                    EXCLUDED.import_rollover_detected,
                    EXCLUDED.export_register_wh,
                    EXCLUDED.previous_export_register_wh,
                    EXCLUDED.export_consumption_wh,
                    EXCLUDED.export_consumption_kwh,
                    EXCLUDED.export_quality_code,
                    EXCLUDED.export_is_valid,
                    EXCLUDED.export_reset_detected,
                    EXCLUDED.export_rollover_detected,
                    EXCLUDED.gap_detected,
                    EXCLUDED.quality_rule_id,
                    EXCLUDED.gap_threshold_minutes,
                    EXCLUDED.quality_rule_scope,
                    EXCLUDED.quality_rule_scope_key
                )
                THEN EXCLUDED.calculated_at
                ELSE energy_consumption_5min.calculated_at
            END;


    GET DIAGNOSTICS
        v_affected = ROW_COUNT;

    RETURN v_affected;
END;
$function$;

-- ---------------------------------------------------------------------------
-- refresh_energy_consumption_15min
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION analytics.refresh_energy_consumption_15min(p_from timestamp with time zone, p_to timestamp with time zone)
 RETURNS bigint
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'analytics'
AS $function$

DECLARE
    v_affected BIGINT := 0;
BEGIN

    IF p_from IS NULL OR p_to IS NULL THEN
        RAISE EXCEPTION
            'p_from and p_to are required';
    END IF;

    IF p_to <= p_from THEN
        RAISE EXCEPTION
            'p_to (%) must be later than p_from (%)',
            p_to,
            p_from;
    END IF;


    INSERT INTO analytics.energy_consumption_15min
    (
        bucket_start,

        organization_id,
        site_id,
        device_id,

        source_interval_count,

        import_consumption_kwh,
        export_consumption_kwh,

        valid_import_intervals,
        invalid_import_intervals,

        valid_export_intervals,
        invalid_export_intervals,

        gap_interval_count,
        reset_interval_count,
        rollover_interval_count,
        invalid_interval_count,

        import_gap_intervals,
        export_gap_intervals,
        import_reset_intervals,
        export_reset_intervals,
        import_rollover_intervals,
        export_rollover_intervals,

        first_source_bucket,
        last_source_bucket,

        calculated_at
    )

    SELECT
        r.bucket_start,

        r.organization_id,
        r.site_id,
        r.device_id,

        r.source_interval_count,

        r.import_consumption_kwh,
        r.export_consumption_kwh,

        r.valid_import_intervals,
        r.invalid_import_intervals,

        r.valid_export_intervals,
        r.invalid_export_intervals,

        r.gap_interval_count,
        r.reset_interval_count,
        r.rollover_interval_count,
        r.invalid_interval_count,

        r.import_gap_intervals,
        r.export_gap_intervals,
        r.import_reset_intervals,
        r.export_reset_intervals,
        r.import_rollover_intervals,
        r.export_rollover_intervals,

        r.first_native_bucket_start,
        r.last_native_bucket_start,

        clock_timestamp()

    FROM analytics.v_energy_semantic_rollup_15min r

    WHERE
        r.bucket_start >= p_from
        AND r.bucket_start < p_to


    ON CONFLICT
    (
        device_id,
        bucket_start
    )
    DO UPDATE
    SET
        organization_id =
            EXCLUDED.organization_id,

        site_id =
            EXCLUDED.site_id,

        source_interval_count =
            EXCLUDED.source_interval_count,

        import_consumption_kwh =
            EXCLUDED.import_consumption_kwh,

        export_consumption_kwh =
            EXCLUDED.export_consumption_kwh,

        valid_import_intervals =
            EXCLUDED.valid_import_intervals,

        invalid_import_intervals =
            EXCLUDED.invalid_import_intervals,

        valid_export_intervals =
            EXCLUDED.valid_export_intervals,

        invalid_export_intervals =
            EXCLUDED.invalid_export_intervals,

        gap_interval_count =
            EXCLUDED.gap_interval_count,

        reset_interval_count =
            EXCLUDED.reset_interval_count,

        rollover_interval_count =
            EXCLUDED.rollover_interval_count,

        invalid_interval_count =
            EXCLUDED.invalid_interval_count,

        import_gap_intervals =
            EXCLUDED.import_gap_intervals,

        export_gap_intervals =
            EXCLUDED.export_gap_intervals,

        import_reset_intervals =
            EXCLUDED.import_reset_intervals,

        export_reset_intervals =
            EXCLUDED.export_reset_intervals,

        import_rollover_intervals =
            EXCLUDED.import_rollover_intervals,

        export_rollover_intervals =
            EXCLUDED.export_rollover_intervals,

        first_source_bucket =
            EXCLUDED.first_source_bucket,

        last_source_bucket =
            EXCLUDED.last_source_bucket,

        calculated_at =
            CASE
                WHEN ROW(
                    energy_consumption_15min.organization_id,
                    energy_consumption_15min.site_id,
                    energy_consumption_15min.source_interval_count,
                    energy_consumption_15min.import_consumption_kwh,
                    energy_consumption_15min.export_consumption_kwh,
                    energy_consumption_15min.valid_import_intervals,
                    energy_consumption_15min.invalid_import_intervals,
                    energy_consumption_15min.valid_export_intervals,
                    energy_consumption_15min.invalid_export_intervals,
                    energy_consumption_15min.gap_interval_count,
                    energy_consumption_15min.reset_interval_count,
                    energy_consumption_15min.rollover_interval_count,
                    energy_consumption_15min.invalid_interval_count,
                    energy_consumption_15min.import_gap_intervals,
                    energy_consumption_15min.export_gap_intervals,
                    energy_consumption_15min.import_reset_intervals,
                    energy_consumption_15min.export_reset_intervals,
                    energy_consumption_15min.import_rollover_intervals,
                    energy_consumption_15min.export_rollover_intervals,
                    energy_consumption_15min.first_source_bucket,
                    energy_consumption_15min.last_source_bucket
                ) IS DISTINCT FROM ROW(
                    EXCLUDED.organization_id,
                    EXCLUDED.site_id,
                    EXCLUDED.source_interval_count,
                    EXCLUDED.import_consumption_kwh,
                    EXCLUDED.export_consumption_kwh,
                    EXCLUDED.valid_import_intervals,
                    EXCLUDED.invalid_import_intervals,
                    EXCLUDED.valid_export_intervals,
                    EXCLUDED.invalid_export_intervals,
                    EXCLUDED.gap_interval_count,
                    EXCLUDED.reset_interval_count,
                    EXCLUDED.rollover_interval_count,
                    EXCLUDED.invalid_interval_count,
                    EXCLUDED.import_gap_intervals,
                    EXCLUDED.export_gap_intervals,
                    EXCLUDED.import_reset_intervals,
                    EXCLUDED.export_reset_intervals,
                    EXCLUDED.import_rollover_intervals,
                    EXCLUDED.export_rollover_intervals,
                    EXCLUDED.first_source_bucket,
                    EXCLUDED.last_source_bucket
                )
                THEN EXCLUDED.calculated_at
                ELSE energy_consumption_15min.calculated_at
            END;


    GET DIAGNOSTICS
        v_affected = ROW_COUNT;

    RETURN v_affected;

END;

$function$;

-- ---------------------------------------------------------------------------
-- refresh_energy_consumption_hourly
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION analytics.refresh_energy_consumption_hourly(p_from timestamp with time zone, p_to timestamp with time zone)
 RETURNS bigint
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'analytics'
AS $function$

DECLARE
    v_affected BIGINT := 0;
BEGIN

    IF p_from IS NULL OR p_to IS NULL THEN
        RAISE EXCEPTION
            'p_from and p_to are required';
    END IF;

    IF p_to <= p_from THEN
        RAISE EXCEPTION
            'p_to (%) must be later than p_from (%)',
            p_to,
            p_from;
    END IF;


    INSERT INTO analytics.energy_consumption_hourly
    (
        bucket_start,

        organization_id,
        site_id,
        device_id,

        source_interval_count,

        import_consumption_kwh,
        export_consumption_kwh,

        valid_import_intervals,
        invalid_import_intervals,

        valid_export_intervals,
        invalid_export_intervals,

        gap_interval_count,
        reset_interval_count,
        rollover_interval_count,
        invalid_interval_count,

        import_gap_intervals,
        export_gap_intervals,
        import_reset_intervals,
        export_reset_intervals,
        import_rollover_intervals,
        export_rollover_intervals,

        first_source_bucket,
        last_source_bucket,

        calculated_at
    )

    SELECT
        date_bin
        (
            INTERVAL '1 hour',
            s.bucket_start,
            TIMESTAMPTZ '2000-01-01 00:00:00+00'
        ) AS bucket_start,

        s.organization_id,
        s.site_id,
        s.device_id,

        SUM(s.source_interval_count)::BIGINT,

        SUM(s.import_consumption_kwh),
        SUM(s.export_consumption_kwh),

        SUM(s.valid_import_intervals)::BIGINT,
        SUM(s.invalid_import_intervals)::BIGINT,

        SUM(s.valid_export_intervals)::BIGINT,
        SUM(s.invalid_export_intervals)::BIGINT,

        SUM(s.gap_interval_count)::BIGINT,
        SUM(s.reset_interval_count)::BIGINT,
        SUM(s.rollover_interval_count)::BIGINT,
        SUM(s.invalid_interval_count)::BIGINT,

        SUM(s.import_gap_intervals)::BIGINT,
        SUM(s.export_gap_intervals)::BIGINT,
        SUM(s.import_reset_intervals)::BIGINT,
        SUM(s.export_reset_intervals)::BIGINT,
        SUM(s.import_rollover_intervals)::BIGINT,
        SUM(s.export_rollover_intervals)::BIGINT,

        MIN(s.first_source_bucket),
        MAX(s.last_source_bucket),

        clock_timestamp()

    FROM analytics.energy_consumption_15min s

    WHERE
        s.bucket_start >= p_from
        AND s.bucket_start < p_to

    GROUP BY
        date_bin
        (
            INTERVAL '1 hour',
            s.bucket_start,
            TIMESTAMPTZ '2000-01-01 00:00:00+00'
        ),
        s.organization_id,
        s.site_id,
        s.device_id


    ON CONFLICT
    (
        device_id,
        bucket_start
    )
    DO UPDATE
    SET
        organization_id =
            EXCLUDED.organization_id,

        site_id =
            EXCLUDED.site_id,

        source_interval_count =
            EXCLUDED.source_interval_count,

        import_consumption_kwh =
            EXCLUDED.import_consumption_kwh,

        export_consumption_kwh =
            EXCLUDED.export_consumption_kwh,

        valid_import_intervals =
            EXCLUDED.valid_import_intervals,

        invalid_import_intervals =
            EXCLUDED.invalid_import_intervals,

        valid_export_intervals =
            EXCLUDED.valid_export_intervals,

        invalid_export_intervals =
            EXCLUDED.invalid_export_intervals,

        gap_interval_count =
            EXCLUDED.gap_interval_count,

        reset_interval_count =
            EXCLUDED.reset_interval_count,

        rollover_interval_count =
            EXCLUDED.rollover_interval_count,

        invalid_interval_count =
            EXCLUDED.invalid_interval_count,

        import_gap_intervals =
            EXCLUDED.import_gap_intervals,

        export_gap_intervals =
            EXCLUDED.export_gap_intervals,

        import_reset_intervals =
            EXCLUDED.import_reset_intervals,

        export_reset_intervals =
            EXCLUDED.export_reset_intervals,

        import_rollover_intervals =
            EXCLUDED.import_rollover_intervals,

        export_rollover_intervals =
            EXCLUDED.export_rollover_intervals,

        first_source_bucket =
            EXCLUDED.first_source_bucket,

        last_source_bucket =
            EXCLUDED.last_source_bucket,

        calculated_at =
            CASE
                WHEN ROW(
                    energy_consumption_hourly.organization_id,
                    energy_consumption_hourly.site_id,
                    energy_consumption_hourly.source_interval_count,
                    energy_consumption_hourly.import_consumption_kwh,
                    energy_consumption_hourly.export_consumption_kwh,
                    energy_consumption_hourly.valid_import_intervals,
                    energy_consumption_hourly.invalid_import_intervals,
                    energy_consumption_hourly.valid_export_intervals,
                    energy_consumption_hourly.invalid_export_intervals,
                    energy_consumption_hourly.gap_interval_count,
                    energy_consumption_hourly.reset_interval_count,
                    energy_consumption_hourly.rollover_interval_count,
                    energy_consumption_hourly.invalid_interval_count,
                    energy_consumption_hourly.import_gap_intervals,
                    energy_consumption_hourly.export_gap_intervals,
                    energy_consumption_hourly.import_reset_intervals,
                    energy_consumption_hourly.export_reset_intervals,
                    energy_consumption_hourly.import_rollover_intervals,
                    energy_consumption_hourly.export_rollover_intervals,
                    energy_consumption_hourly.first_source_bucket,
                    energy_consumption_hourly.last_source_bucket
                ) IS DISTINCT FROM ROW(
                    EXCLUDED.organization_id,
                    EXCLUDED.site_id,
                    EXCLUDED.source_interval_count,
                    EXCLUDED.import_consumption_kwh,
                    EXCLUDED.export_consumption_kwh,
                    EXCLUDED.valid_import_intervals,
                    EXCLUDED.invalid_import_intervals,
                    EXCLUDED.valid_export_intervals,
                    EXCLUDED.invalid_export_intervals,
                    EXCLUDED.gap_interval_count,
                    EXCLUDED.reset_interval_count,
                    EXCLUDED.rollover_interval_count,
                    EXCLUDED.invalid_interval_count,
                    EXCLUDED.import_gap_intervals,
                    EXCLUDED.export_gap_intervals,
                    EXCLUDED.import_reset_intervals,
                    EXCLUDED.export_reset_intervals,
                    EXCLUDED.import_rollover_intervals,
                    EXCLUDED.export_rollover_intervals,
                    EXCLUDED.first_source_bucket,
                    EXCLUDED.last_source_bucket
                )
                THEN EXCLUDED.calculated_at
                ELSE energy_consumption_hourly.calculated_at
            END;


    GET DIAGNOSTICS
        v_affected = ROW_COUNT;

    RETURN v_affected;

END;

$function$;

-- ---------------------------------------------------------------------------
-- refresh_energy_consumption_daily
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION analytics.refresh_energy_consumption_daily(p_from timestamp with time zone, p_to timestamp with time zone)
 RETURNS bigint
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'analytics'
AS $function$

DECLARE
    v_affected BIGINT := 0;
BEGIN

    IF p_from IS NULL OR p_to IS NULL THEN
        RAISE EXCEPTION
            'p_from and p_to are required';
    END IF;

    IF p_to <= p_from THEN
        RAISE EXCEPTION
            'p_to (%) must be later than p_from (%)',
            p_to,
            p_from;
    END IF;


    INSERT INTO analytics.energy_consumption_daily
    (
        bucket_start,
        consumption_date,
        site_timezone,

        organization_id,
        site_id,
        device_id,

        source_interval_count,

        import_consumption_kwh,
        export_consumption_kwh,

        valid_import_intervals,
        invalid_import_intervals,

        valid_export_intervals,
        invalid_export_intervals,

        gap_interval_count,
        reset_interval_count,
        rollover_interval_count,
        invalid_interval_count,

        import_gap_intervals,
        export_gap_intervals,
        import_reset_intervals,
        export_reset_intervals,
        import_rollover_intervals,
        export_rollover_intervals,

        first_source_bucket,
        last_source_bucket,

        calculated_at
    )

    WITH localized AS
    (
        SELECT
            s.*,

            site.timezone AS site_timezone,

            (
                s.bucket_start
                AT TIME ZONE site.timezone
            )::DATE AS consumption_date,

            (
                (
                    (
                        s.bucket_start
                        AT TIME ZONE site.timezone
                    )::DATE
                )::TIMESTAMP
                AT TIME ZONE site.timezone
            ) AS local_day_start,

            (
                (
                    (
                        (
                            s.bucket_start
                            AT TIME ZONE site.timezone
                        )::DATE
                        + 1
                    )::TIMESTAMP
                )
                AT TIME ZONE site.timezone
            ) AS local_day_end

        FROM analytics.energy_consumption_15min s

        JOIN metadata.sites site
          ON site.id = s.site_id
         AND site.organization_id =
             s.organization_id

        -- One extra day guarantees that the complete local day overlapping
        -- p_from is available regardless of timezone offset.
        WHERE
            s.bucket_start >=
                p_from - INTERVAL '1 day'

            AND s.bucket_start <
                p_to
    )

    SELECT
        l.local_day_start,
        l.consumption_date,
        l.site_timezone,

        l.organization_id,
        l.site_id,
        l.device_id,

        SUM(l.source_interval_count)::BIGINT,

        SUM(l.import_consumption_kwh),
        SUM(l.export_consumption_kwh),

        SUM(l.valid_import_intervals)::BIGINT,
        SUM(l.invalid_import_intervals)::BIGINT,

        SUM(l.valid_export_intervals)::BIGINT,
        SUM(l.invalid_export_intervals)::BIGINT,

        SUM(l.gap_interval_count)::BIGINT,
        SUM(l.reset_interval_count)::BIGINT,
        SUM(l.rollover_interval_count)::BIGINT,
        SUM(l.invalid_interval_count)::BIGINT,

        SUM(l.import_gap_intervals)::BIGINT,
        SUM(l.export_gap_intervals)::BIGINT,
        SUM(l.import_reset_intervals)::BIGINT,
        SUM(l.export_reset_intervals)::BIGINT,
        SUM(l.import_rollover_intervals)::BIGINT,
        SUM(l.export_rollover_intervals)::BIGINT,

        MIN(l.first_source_bucket),
        MAX(l.last_source_bucket),

        clock_timestamp()

    FROM localized l

    -- Include a local day only once its local end boundary has completed.
    -- The overlap test allows the first local day touching p_from to be
    -- recalculated in full.
    WHERE
        l.local_day_end > p_from
        AND l.local_day_end <= p_to

    GROUP BY
        l.local_day_start,
        l.consumption_date,
        l.site_timezone,
        l.organization_id,
        l.site_id,
        l.device_id


    ON CONFLICT
    (
        device_id,
        bucket_start
    )
    DO UPDATE
    SET
        consumption_date =
            EXCLUDED.consumption_date,

        site_timezone =
            EXCLUDED.site_timezone,

        organization_id =
            EXCLUDED.organization_id,

        site_id =
            EXCLUDED.site_id,

        source_interval_count =
            EXCLUDED.source_interval_count,

        import_consumption_kwh =
            EXCLUDED.import_consumption_kwh,

        export_consumption_kwh =
            EXCLUDED.export_consumption_kwh,

        valid_import_intervals =
            EXCLUDED.valid_import_intervals,

        invalid_import_intervals =
            EXCLUDED.invalid_import_intervals,

        valid_export_intervals =
            EXCLUDED.valid_export_intervals,

        invalid_export_intervals =
            EXCLUDED.invalid_export_intervals,

        gap_interval_count =
            EXCLUDED.gap_interval_count,

        reset_interval_count =
            EXCLUDED.reset_interval_count,

        rollover_interval_count =
            EXCLUDED.rollover_interval_count,

        invalid_interval_count =
            EXCLUDED.invalid_interval_count,

        import_gap_intervals =
            EXCLUDED.import_gap_intervals,

        export_gap_intervals =
            EXCLUDED.export_gap_intervals,

        import_reset_intervals =
            EXCLUDED.import_reset_intervals,

        export_reset_intervals =
            EXCLUDED.export_reset_intervals,

        import_rollover_intervals =
            EXCLUDED.import_rollover_intervals,

        export_rollover_intervals =
            EXCLUDED.export_rollover_intervals,

        first_source_bucket =
            EXCLUDED.first_source_bucket,

        last_source_bucket =
            EXCLUDED.last_source_bucket,

        calculated_at =
            CASE
                WHEN ROW(
                    energy_consumption_daily.consumption_date,
                    energy_consumption_daily.site_timezone,
                    energy_consumption_daily.organization_id,
                    energy_consumption_daily.site_id,
                    energy_consumption_daily.source_interval_count,
                    energy_consumption_daily.import_consumption_kwh,
                    energy_consumption_daily.export_consumption_kwh,
                    energy_consumption_daily.valid_import_intervals,
                    energy_consumption_daily.invalid_import_intervals,
                    energy_consumption_daily.valid_export_intervals,
                    energy_consumption_daily.invalid_export_intervals,
                    energy_consumption_daily.gap_interval_count,
                    energy_consumption_daily.reset_interval_count,
                    energy_consumption_daily.rollover_interval_count,
                    energy_consumption_daily.invalid_interval_count,
                    energy_consumption_daily.import_gap_intervals,
                    energy_consumption_daily.export_gap_intervals,
                    energy_consumption_daily.import_reset_intervals,
                    energy_consumption_daily.export_reset_intervals,
                    energy_consumption_daily.import_rollover_intervals,
                    energy_consumption_daily.export_rollover_intervals,
                    energy_consumption_daily.first_source_bucket,
                    energy_consumption_daily.last_source_bucket
                ) IS DISTINCT FROM ROW(
                    EXCLUDED.consumption_date,
                    EXCLUDED.site_timezone,
                    EXCLUDED.organization_id,
                    EXCLUDED.site_id,
                    EXCLUDED.source_interval_count,
                    EXCLUDED.import_consumption_kwh,
                    EXCLUDED.export_consumption_kwh,
                    EXCLUDED.valid_import_intervals,
                    EXCLUDED.invalid_import_intervals,
                    EXCLUDED.valid_export_intervals,
                    EXCLUDED.invalid_export_intervals,
                    EXCLUDED.gap_interval_count,
                    EXCLUDED.reset_interval_count,
                    EXCLUDED.rollover_interval_count,
                    EXCLUDED.invalid_interval_count,
                    EXCLUDED.import_gap_intervals,
                    EXCLUDED.export_gap_intervals,
                    EXCLUDED.import_reset_intervals,
                    EXCLUDED.export_reset_intervals,
                    EXCLUDED.import_rollover_intervals,
                    EXCLUDED.export_rollover_intervals,
                    EXCLUDED.first_source_bucket,
                    EXCLUDED.last_source_bucket
                )
                THEN EXCLUDED.calculated_at
                ELSE energy_consumption_daily.calculated_at
            END;


    GET DIAGNOSTICS
        v_affected = ROW_COUNT;

    RETURN v_affected;

END;

$function$;

