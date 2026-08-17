BEGIN;

-- ============================================================================
-- Persisted site-local daily energy consumption.
--
-- Source:
--   analytics.energy_consumption_15min
--
-- Daily boundaries are resolved from metadata.sites.timezone.
--
-- Do NOT aggregate from UTC-aligned hourly history. A UTC hourly bucket may
-- cross a site's local midnight in non-whole-hour / non-UTC timezones.
--
-- Native register classification has already happened upstream. This layer
-- only conserves already-classified consumption and quality counters.
-- ============================================================================


-- ============================================================================
-- 1. TABLE
-- ============================================================================

CREATE TABLE analytics.energy_consumption_daily
(
    bucket_start TIMESTAMPTZ NOT NULL,

    consumption_date DATE NOT NULL,
    site_timezone    TEXT NOT NULL,

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


COMMENT ON TABLE analytics.energy_consumption_daily IS
'Persisted long-term site-local daily energy-consumption historian aggregated from canonical persisted 15-minute semantic consumption.';


COMMENT ON COLUMN analytics.energy_consumption_daily.bucket_start IS
'UTC instant corresponding to local midnight for consumption_date in site_timezone.';


COMMENT ON COLUMN analytics.energy_consumption_daily.consumption_date IS
'Local calendar date in the effective site timezone.';


SELECT create_hypertable
(
    'analytics.energy_consumption_daily',
    'bucket_start',
    if_not_exists => TRUE,
    migrate_data  => TRUE
);


CREATE INDEX
    ix_energy_consumption_daily_org_site_date
ON analytics.energy_consumption_daily
(
    organization_id,
    site_id,
    consumption_date DESC
);


CREATE INDEX
    ix_energy_consumption_daily_device_time
ON analytics.energy_consumption_daily
(
    device_id,
    bucket_start DESC
);


-- ============================================================================
-- 2. REFRESH
-- ============================================================================

CREATE OR REPLACE FUNCTION analytics.refresh_energy_consumption_daily
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


COMMENT ON FUNCTION analytics.refresh_energy_consumption_daily(
    TIMESTAMPTZ,
    TIMESTAMPTZ
) IS
'Refreshes completed site-local daily energy consumption from persisted 15-minute semantic intervals using metadata.sites.timezone.';


REVOKE ALL
ON FUNCTION analytics.refresh_energy_consumption_daily(
    TIMESTAMPTZ,
    TIMESTAMPTZ
)
FROM PUBLIC;


-- ============================================================================
-- 3. BACKGROUND JOB
-- ============================================================================

CREATE OR REPLACE PROCEDURE analytics.run_energy_consumption_daily_job
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
        INTERVAL '8 days';

    v_to   TIMESTAMPTZ;
    v_from TIMESTAMPTZ;
BEGIN

    IF config ? 'lookback' THEN
        v_lookback :=
            (config ->> 'lookback')::INTERVAL;
    END IF;

    IF v_lookback <= INTERVAL '0 seconds' THEN
        RAISE EXCEPTION
            'daily energy consumption lookback must be positive';
    END IF;


    v_to :=
        clock_timestamp();

    v_from :=
        v_to - v_lookback;


    PERFORM
        analytics.refresh_energy_consumption_daily
        (
            v_from,
            v_to
        );

END;

$procedure$;


SELECT add_job
(
    'analytics.run_energy_consumption_daily_job',
    INTERVAL '1 hour',
    config => '{"lookback":"8 days"}'::JSONB
);


-- ============================================================================
-- 4. LIFECYCLE
-- ============================================================================

ALTER TABLE analytics.energy_consumption_daily
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
    'analytics.energy_consumption_daily',
    INTERVAL '90 days'
);

-- Intentionally NO retention policy.
--
-- Daily consumption is the durable long-term accounting layer.


COMMIT;
