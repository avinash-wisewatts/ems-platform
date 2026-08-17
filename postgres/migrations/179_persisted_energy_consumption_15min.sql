BEGIN;

-- ============================================================================
-- Persist validated 15-minute energy consumption.
--
-- Source:
--   analytics.v_energy_semantic_rollup_15min
--
-- The source already aggregates canonical native 1m / 5m semantic intervals.
-- No cumulative-register reclassification occurs here.
--
-- This preserves:
--   * consumption conservation;
--   * GOOD / invalid interval accounting;
--   * GAP events;
--   * reset events;
--   * rollover events.
-- ============================================================================


CREATE TABLE analytics.energy_consumption_15min
(
    bucket_start TIMESTAMPTZ NOT NULL,

    organization_id UUID NOT NULL,
    site_id         UUID NOT NULL,
    device_id       UUID NOT NULL,

    source_interval_count BIGINT NOT NULL,

    import_consumption_kwh NUMERIC,
    export_consumption_kwh NUMERIC,

    valid_import_intervals   BIGINT NOT NULL,
    invalid_import_intervals BIGINT NOT NULL,

    valid_export_intervals   BIGINT NOT NULL,
    invalid_export_intervals BIGINT NOT NULL,

    gap_interval_count      BIGINT NOT NULL,
    reset_interval_count    BIGINT NOT NULL,
    rollover_interval_count BIGINT NOT NULL,
    invalid_interval_count  BIGINT NOT NULL,

    first_source_bucket TIMESTAMPTZ,
    last_source_bucket  TIMESTAMPTZ,

    calculated_at TIMESTAMPTZ NOT NULL
        DEFAULT clock_timestamp(),

    PRIMARY KEY
    (
        device_id,
        bucket_start
    )
);


COMMENT ON TABLE analytics.energy_consumption_15min IS
'Persisted canonical 15-minute energy-consumption semantics aggregated from already-classified native energy consumption intervals.';


SELECT create_hypertable
(
    'analytics.energy_consumption_15min',
    'bucket_start',
    if_not_exists => TRUE,
    migrate_data  => TRUE
);


CREATE INDEX
    ix_energy_consumption_15min_org_site_time
ON analytics.energy_consumption_15min
(
    organization_id,
    site_id,
    bucket_start DESC
);


CREATE INDEX
    ix_energy_consumption_15min_device_time
ON analytics.energy_consumption_15min
(
    device_id,
    bucket_start DESC
);


-- ============================================================================
-- REFRESH
-- ============================================================================

CREATE OR REPLACE FUNCTION analytics.refresh_energy_consumption_15min
(
    p_from TIMESTAMPTZ,
    p_to   TIMESTAMPTZ
)
RETURNS BIGINT
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO
    pg_catalog,
    analytics
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

        first_source_bucket =
            EXCLUDED.first_source_bucket,

        last_source_bucket =
            EXCLUDED.last_source_bucket,

        calculated_at =
            EXCLUDED.calculated_at;


    GET DIAGNOSTICS
        v_affected = ROW_COUNT;

    RETURN v_affected;

END;

$function$;


COMMENT ON FUNCTION analytics.refresh_energy_consumption_15min(
    TIMESTAMPTZ,
    TIMESTAMPTZ
) IS
'Refreshes persisted canonical 15-minute energy-consumption semantics from analytics.v_energy_semantic_rollup_15min.';


REVOKE ALL
ON FUNCTION analytics.refresh_energy_consumption_15min(
    TIMESTAMPTZ,
    TIMESTAMPTZ
)
FROM PUBLIC;


-- ============================================================================
-- JOB
-- ============================================================================

CREATE OR REPLACE PROCEDURE analytics.run_energy_consumption_15min_job
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
        INTERVAL '2 hours';

    v_to   TIMESTAMPTZ;
    v_from TIMESTAMPTZ;
BEGIN

    IF config ? 'lookback' THEN
        v_lookback :=
            (config ->> 'lookback')::INTERVAL;
    END IF;

    IF v_lookback <= INTERVAL '0 seconds' THEN
        RAISE EXCEPTION
            'energy consumption 15-minute lookback must be positive';
    END IF;


    v_to :=
        date_bin
        (
            INTERVAL '15 minutes',
            clock_timestamp(),
            TIMESTAMPTZ '2000-01-01 00:00:00+00'
        );

    v_from :=
        v_to - v_lookback;


    PERFORM
        analytics.refresh_energy_consumption_15min
        (
            v_from,
            v_to
        );

END;

$procedure$;


SELECT add_job
(
    'analytics.run_energy_consumption_15min_job',
    INTERVAL '5 minutes',
    config => '{"lookback":"2 hours"}'::JSONB
);


-- ============================================================================
-- COMPRESSION / RETENTION
-- ============================================================================

ALTER TABLE analytics.energy_consumption_15min
SET
(
    timescaledb.compress = TRUE,
    timescaledb.compress_segmentby =
        'organization_id,site_id,device_id',
    timescaledb.compress_orderby =
        'bucket_start DESC'
);


SELECT add_compression_policy
(
    'analytics.energy_consumption_15min',
    INTERVAL '7 days'
);


SELECT add_retention_policy
(
    'analytics.energy_consumption_15min',
    INTERVAL '2 years'
);


COMMIT;
