-- Migration 039
--
-- Resolution-aware native energy gap classification.
--
-- Persisted semantic energy must not classify an observation spanning
-- multiple native intervals as an ordinary GOOD interval merely because
-- the generic configured quality threshold is larger.
--
-- Effective thresholds:
--   native 1-minute semantics: min(configured rule, 1.5 minutes)
--   native 5-minute semantics: min(configured rule, 7.5 minutes)
--
-- GAP classification intentionally preserves the cumulative register delta.
-- The energy remains available to trusted aggregate accounting while
-- interval-level charts and quality metrics correctly represent missing
-- temporal attribution.


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
            EXCLUDED.calculated_at;


    GET DIAGNOSTICS
        v_affected = ROW_COUNT;

    RETURN v_affected;
END;
$function$;



COMMENT ON FUNCTION analytics.refresh_energy_consumption_1min(
    timestamp with time zone,
    timestamp with time zone
) IS
'Refresh persisted native one-minute validated energy semantics. Gap classification uses the stricter of the resolved interval-quality rule and 1.5 times the native one-minute resolution.';

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
            EXCLUDED.calculated_at;


    GET DIAGNOSTICS
        v_affected = ROW_COUNT;

    RETURN v_affected;
END;
$function$;



COMMENT ON FUNCTION analytics.refresh_energy_consumption_5min(
    timestamp with time zone,
    timestamp with time zone
) IS
'Refresh persisted native five-minute validated energy semantics. Gap classification uses the stricter of the resolved interval-quality rule and 1.5 times the native five-minute resolution.';
