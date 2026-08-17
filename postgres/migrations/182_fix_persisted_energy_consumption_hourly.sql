BEGIN;

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
'Refreshes UTC-aligned persisted hourly energy consumption from already-classified 15-minute semantic intervals using PostgreSQL date_bin().';


REVOKE ALL
ON FUNCTION analytics.refresh_energy_consumption_hourly(
    TIMESTAMPTZ,
    TIMESTAMPTZ
)
FROM PUBLIC;


SELECT alter_job(
    job_id,
    scheduled => TRUE
)
FROM timescaledb_information.jobs
WHERE proc_schema = 'analytics'
  AND proc_name = 'run_energy_consumption_hourly_job';


COMMIT;
