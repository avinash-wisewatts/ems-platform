BEGIN;

-- ============================================================================
-- Correct persisted 15-minute semantic consumption refresh.
--
-- analytics.v_energy_semantic_rollup_15min exposes:
--   first_native_bucket_start
--   last_native_bucket_start
--
-- These map to the persisted table's:
--   first_source_bucket
--   last_source_bucket
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
'Refreshes persisted canonical 15-minute energy-consumption semantics from analytics.v_energy_semantic_rollup_15min using native semantic interval boundaries.';


REVOKE ALL
ON FUNCTION analytics.refresh_energy_consumption_15min(
    TIMESTAMPTZ,
    TIMESTAMPTZ
)
FROM PUBLIC;


-- Re-enable the 15-minute consumption job if it was disabled during repair.
SELECT alter_job
(
    job_id,
    scheduled => TRUE
)
FROM timescaledb_information.jobs
WHERE proc_schema = 'analytics'
  AND proc_name = 'run_energy_consumption_15min_job';


COMMIT;
