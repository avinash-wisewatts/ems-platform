BEGIN;

-- ============================================================================
-- Persisted hourly validated energy consumption.
--
-- Source:
--   analytics.energy_consumption_15min
--
-- Semantics:
--   Native register classification has already happened upstream.
--
-- Hourly history therefore ONLY aggregates already-classified semantic
-- intervals. It must never recalculate energy from coarse cumulative
-- register MIN/MAX values.
-- ============================================================================


-- ============================================================================
-- 1. TABLE
-- ============================================================================

CREATE TABLE analytics.energy_consumption_hourly
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


COMMENT ON TABLE analytics.energy_consumption_hourly IS
'Persisted hourly energy-consumption historian aggregated exclusively from canonical persisted 15-minute semantic consumption.';


SELECT create_hypertable
(
    'analytics.energy_consumption_hourly',
    'bucket_start',
    if_not_exists => TRUE,
    migrate_data  => TRUE
);


CREATE INDEX
    ix_energy_consumption_hourly_org_site_time
ON analytics.energy_consumption_hourly
(
    organization_id,
    site_id,
    bucket_start DESC
);


CREATE INDEX
    ix_energy_consumption_hourly_device_time
ON analytics.energy_consumption_hourly
(
    device_id,
    bucket_start DESC
);


-- ============================================================================
-- 2. REFRESH
-- ============================================================================

CREATE OR REPLACE FUNCTION analytics.refresh_energy_consumption_hourly
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


COMMENT ON FUNCTION analytics.refresh_energy_consumption_hourly(
    TIMESTAMPTZ,
    TIMESTAMPTZ
) IS
'Refreshes persisted hourly energy-consumption history by aggregating already-classified analytics.energy_consumption_15min intervals.';


REVOKE ALL
ON FUNCTION analytics.refresh_energy_consumption_hourly(
    TIMESTAMPTZ,
    TIMESTAMPTZ
)
FROM PUBLIC;


-- ============================================================================
-- 3. BACKGROUND JOB
-- ============================================================================

CREATE OR REPLACE PROCEDURE analytics.run_energy_consumption_hourly_job
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
        INTERVAL '2 days';

    v_to   TIMESTAMPTZ;
    v_from TIMESTAMPTZ;
BEGIN

    IF config ? 'lookback' THEN
        v_lookback :=
            (config ->> 'lookback')::INTERVAL;
    END IF;

    IF v_lookback <= INTERVAL '0 seconds' THEN
        RAISE EXCEPTION
            'hourly energy consumption lookback must be positive';
    END IF;


    -- Beginning of current hour.
    -- Only completed hourly buckets are persisted.
    v_to :=
        date_trunc
        (
            'hour',
            clock_timestamp()
        );

    v_from :=
        v_to - v_lookback;


    PERFORM
        analytics.refresh_energy_consumption_hourly
        (
            v_from,
            v_to
        );

END;

$procedure$;


SELECT add_job
(
    'analytics.run_energy_consumption_hourly_job',
    INTERVAL '15 minutes',
    config => '{"lookback":"2 days"}'::JSONB
);


-- ============================================================================
-- 4. LIFECYCLE
-- ============================================================================

ALTER TABLE analytics.energy_consumption_hourly
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
    'analytics.energy_consumption_hourly',
    INTERVAL '30 days'
);


SELECT add_retention_policy
(
    'analytics.energy_consumption_hourly',
    INTERVAL '5 years'
);


COMMIT;
