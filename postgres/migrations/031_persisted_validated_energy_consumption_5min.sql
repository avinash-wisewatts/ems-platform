-- ============================================================================
-- Migration 031
-- Persisted validated native five-minute energy consumption
--
-- Native-resolution semantic layer for sites whose effective telemetry
-- capture interval is exactly 300 seconds.
--
-- Classification happens once from telemetry.ca_energy_5min. Higher reporting
-- resolutions may later aggregate these already-classified intervals.
--
-- 60-second sites are intentionally excluded because their authoritative
-- semantic history is analytics.energy_consumption_1min.
-- ============================================================================


-- ============================================================================
-- 1. PERSISTED VALIDATED NATIVE FIVE-MINUTE CONSUMPTION
-- ============================================================================

CREATE TABLE IF NOT EXISTS analytics.energy_consumption_5min
(
    bucket_start TIMESTAMPTZ NOT NULL,

    organization_id UUID NOT NULL,
    site_id         UUID NOT NULL,
    device_id       UUID NOT NULL,

    previous_bucket_start TIMESTAMPTZ,
    elapsed_minutes       NUMERIC,

    source_sample_count BIGINT,

    import_register_wh          NUMERIC,
    previous_import_register_wh NUMERIC,
    import_consumption_wh       NUMERIC,
    import_consumption_kwh      NUMERIC,
    import_quality_code         TEXT NOT NULL,
    import_is_valid             BOOLEAN NOT NULL,
    import_reset_detected       BOOLEAN NOT NULL,
    import_rollover_detected    BOOLEAN NOT NULL,

    export_register_wh          NUMERIC,
    previous_export_register_wh NUMERIC,
    export_consumption_wh       NUMERIC,
    export_consumption_kwh      NUMERIC,
    export_quality_code         TEXT NOT NULL,
    export_is_valid             BOOLEAN NOT NULL,
    export_reset_detected       BOOLEAN NOT NULL,
    export_rollover_detected    BOOLEAN NOT NULL,

    gap_detected BOOLEAN NOT NULL,

    quality_rule_id        UUID,
    gap_threshold_minutes  NUMERIC,
    quality_rule_scope     TEXT,
    quality_rule_scope_key TEXT,

    calculated_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),

    PRIMARY KEY
    (
        device_id,
        bucket_start
    )
);


COMMENT ON TABLE analytics.energy_consumption_5min IS
'Persisted validated native five-minute import/export energy consumption derived from telemetry.ca_energy_5min for effective 300-second site capture policies using canonical TOTAL-register semantics and interval-quality classification.';


COMMENT ON COLUMN analytics.energy_consumption_5min.bucket_start IS
'Canonical native five-minute source bucket represented by this validated consumption interval.';


COMMENT ON COLUMN analytics.energy_consumption_5min.previous_bucket_start IS
'Previous eligible native five-minute aggregate bucket for the same device used for cumulative-register delta calculation; may be more than five minutes earlier when source data is missing.';


COMMENT ON COLUMN analytics.energy_consumption_5min.quality_rule_id IS
'Effective-dated interval-quality rule used when this native five-minute interval was classified.';


SELECT create_hypertable
(
    'analytics.energy_consumption_5min',
    'bucket_start',
    if_not_exists => TRUE,
    migrate_data  => TRUE
);


CREATE INDEX IF NOT EXISTS
    ix_energy_consumption_5min_org_site_time
ON analytics.energy_consumption_5min
(
    organization_id,
    site_id,
    bucket_start DESC
);


CREATE INDEX IF NOT EXISTS
    ix_energy_consumption_5min_device_time
ON analytics.energy_consumption_5min
(
    device_id,
    bucket_start DESC
);


CREATE INDEX IF NOT EXISTS
    ix_energy_consumption_5min_good_import
ON analytics.energy_consumption_5min
(
    device_id,
    bucket_start DESC
)
WHERE import_quality_code = 'GOOD';


-- No retention policy yet.
--
-- The semantic history remains authoritative until validated higher-resolution
-- semantic rollups and their retention contracts have been implemented.


-- ============================================================================
-- 2. INCREMENTAL REFRESH FUNCTION
-- ============================================================================

CREATE OR REPLACE FUNCTION analytics.refresh_energy_consumption_5min
(
    p_from TIMESTAMPTZ,
    p_to   TIMESTAMPTZ
)
RETURNS BIGINT
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO
    pg_catalog,
    analytics,
    telemetry,
    config,
    metadata
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
        interval_rule.gap_threshold_minutes,
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

        interval_rule.gap_threshold_minutes
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

        interval_rule.gap_threshold_minutes
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


COMMENT ON FUNCTION analytics.refresh_energy_consumption_5min
(
    TIMESTAMPTZ,
    TIMESTAMPTZ
)
IS
'Idempotently persists validated native five-minute import/export consumption from telemetry.ca_energy_5min for effective 300-second site capture policies over the requested half-open interval [p_from,p_to).';


-- ============================================================================
-- 3. BACKGROUND JOB
-- ============================================================================

CREATE OR REPLACE PROCEDURE analytics.run_energy_consumption_5min_job
(
    job_id INTEGER,
    config JSONB
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO
    pg_catalog,
    analytics
AS $procedure$
DECLARE
    v_lookback INTERVAL :=
        INTERVAL '30 minutes';

    v_to   TIMESTAMPTZ;
    v_from TIMESTAMPTZ;
BEGIN
    IF config ? 'lookback' THEN
        v_lookback :=
            (config ->> 'lookback')::INTERVAL;
    END IF;

    IF v_lookback <= INTERVAL '0 seconds' THEN
        RAISE EXCEPTION
            'energy consumption lookback must be positive';
    END IF;

    -- Start of the current five-minute bucket. The half-open refresh range
    -- therefore contains completed native five-minute buckets only.
    v_to :=
        date_bin
        (
            INTERVAL '5 minutes',
            clock_timestamp(),
            TIMESTAMPTZ '2000-01-01 00:00:00+00'
        );

    v_from :=
        v_to - v_lookback;

    PERFORM
        analytics.refresh_energy_consumption_5min
        (
            v_from,
            v_to
        );
END;
$procedure$;


COMMENT ON PROCEDURE analytics.run_energy_consumption_5min_job
(
    INTEGER,
    JSONB
)
IS
'TimescaleDB job wrapper that refreshes recent persisted validated native five-minute energy-consumption intervals for effective 300-second site capture policies.';


DO $block$
DECLARE
    v_job_id INTEGER;
BEGIN
    SELECT
        j.job_id
    INTO v_job_id

    FROM timescaledb_information.jobs j

    WHERE j.proc_schema =
          'analytics'

      AND j.proc_name =
          'run_energy_consumption_5min_job'

    ORDER BY
        j.job_id

    LIMIT 1;


    IF v_job_id IS NULL THEN

        SELECT add_job
        (
            'analytics.run_energy_consumption_5min_job',
            INTERVAL '1 minute',
            config =>
                '{"lookback":"30 minutes"}'::JSONB
        )
        INTO v_job_id;

    ELSE

        PERFORM alter_job
        (
            v_job_id,
            schedule_interval =>
                INTERVAL '1 minute',

            config =>
                '{"lookback":"30 minutes"}'::JSONB,

            scheduled =>
                TRUE
        );

    END IF;
END;
$block$;


-- ============================================================================
-- 4. SECURITY BOUNDARY
-- ============================================================================

ALTER TABLE
    analytics.energy_consumption_5min
OWNER TO ems_admin;


ALTER FUNCTION
    analytics.refresh_energy_consumption_5min
    (
        TIMESTAMPTZ,
        TIMESTAMPTZ
    )
OWNER TO ems_admin;


ALTER PROCEDURE
    analytics.run_energy_consumption_5min_job
    (
        INTEGER,
        JSONB
    )
OWNER TO ems_admin;


REVOKE ALL
ON analytics.energy_consumption_5min
FROM PUBLIC;


REVOKE ALL
ON FUNCTION analytics.refresh_energy_consumption_5min
(
    TIMESTAMPTZ,
    TIMESTAMPTZ
)
FROM PUBLIC;


REVOKE ALL
ON PROCEDURE analytics.run_energy_consumption_5min_job
(
    INTEGER,
    JSONB
)
FROM PUBLIC;


-- Internal semantic layer only. No direct Grafana/ems_readonly table access.

GRANT EXECUTE
ON FUNCTION analytics.refresh_energy_consumption_5min
(
    TIMESTAMPTZ,
    TIMESTAMPTZ
)
TO ems_admin;


GRANT EXECUTE
ON PROCEDURE analytics.run_energy_consumption_5min_job
(
    INTEGER,
    JSONB
)
TO ems_admin;

