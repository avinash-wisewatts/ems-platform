-- ============================================================================
-- Migration 196
-- Phase 1E-A — persist per-flow quality intervals through the canonical
-- 15-minute / hourly / daily energy-consumption lineage
--
-- analytics.v_energy_semantic_rollup_15min already computes independent
-- import/export gap/reset/rollover interval counts (import_gap_intervals,
-- export_gap_intervals, import_reset_intervals, export_reset_intervals,
-- import_rollover_intervals, export_rollover_intervals) -- confirmed by
-- direct inspection of its live definition. analytics.refresh_energy_
-- consumption_15min() reads that view but has never carried these six
-- columns into analytics.energy_consumption_15min; only the COMBINED
-- (import-OR-export) gap_interval_count/reset_interval_count/rollover_
-- interval_count are persisted today. Downstream, refresh_energy_
-- consumption_hourly()/daily() therefore have nothing per-flow to sum.
--
-- This migration does not introduce any new calculation or classification
-- logic. It only stops already-computed, already-correct per-flow
-- information from being discarded on the way to persistence, and carries
-- it forward additively through the existing hourly/daily rollup exactly
-- as the combined counters already are.
--
-- Scope (Phase 1E-A only, per the approved Phase 1E Architecture
-- Resolution Plan):
--   - Six new NULLABLE BIGINT columns on energy_consumption_15min/
--     hourly/daily. Nullable because historical backfill is explicitly
--     Phase 1E-B, not this migration -- existing historical rows (if any)
--     keep NULL in these columns until backfilled separately.
--   - refresh_energy_consumption_15min() extended to populate them from
--     v_energy_semantic_rollup_15min's own already-computed columns.
--   - refresh_energy_consumption_hourly()/daily() extended to SUM them
--     from the (now-extended) 15-minute persisted table, mirroring
--     exactly how the combined counters are already summed.
--   - No reporting view, no get_canonical_energy_read(), no Grafana
--     object, no other migration or job is touched.
-- ============================================================================


-- ----------------------------------------------------------------------------
-- 1. Additive schema extension.
-- ----------------------------------------------------------------------------

ALTER TABLE analytics.energy_consumption_15min
    ADD COLUMN IF NOT EXISTS import_gap_intervals BIGINT,
    ADD COLUMN IF NOT EXISTS export_gap_intervals BIGINT,
    ADD COLUMN IF NOT EXISTS import_reset_intervals BIGINT,
    ADD COLUMN IF NOT EXISTS export_reset_intervals BIGINT,
    ADD COLUMN IF NOT EXISTS import_rollover_intervals BIGINT,
    ADD COLUMN IF NOT EXISTS export_rollover_intervals BIGINT;

ALTER TABLE analytics.energy_consumption_hourly
    ADD COLUMN IF NOT EXISTS import_gap_intervals BIGINT,
    ADD COLUMN IF NOT EXISTS export_gap_intervals BIGINT,
    ADD COLUMN IF NOT EXISTS import_reset_intervals BIGINT,
    ADD COLUMN IF NOT EXISTS export_reset_intervals BIGINT,
    ADD COLUMN IF NOT EXISTS import_rollover_intervals BIGINT,
    ADD COLUMN IF NOT EXISTS export_rollover_intervals BIGINT;

ALTER TABLE analytics.energy_consumption_daily
    ADD COLUMN IF NOT EXISTS import_gap_intervals BIGINT,
    ADD COLUMN IF NOT EXISTS export_gap_intervals BIGINT,
    ADD COLUMN IF NOT EXISTS import_reset_intervals BIGINT,
    ADD COLUMN IF NOT EXISTS export_reset_intervals BIGINT,
    ADD COLUMN IF NOT EXISTS import_rollover_intervals BIGINT,
    ADD COLUMN IF NOT EXISTS export_rollover_intervals BIGINT;

COMMENT ON COLUMN analytics.energy_consumption_15min.import_gap_intervals IS
'Phase 1E-A: count of native import intervals classified GAP within this bucket. Carried through from analytics.v_energy_semantic_rollup_15min; NULL for rows persisted before this column existed (historical backfill is Phase 1E-B, not performed here).';
COMMENT ON COLUMN analytics.energy_consumption_hourly.import_gap_intervals IS
'Phase 1E-A: additive sum of analytics.energy_consumption_15min.import_gap_intervals for this hour. NULL for rows persisted before this column existed.';
COMMENT ON COLUMN analytics.energy_consumption_daily.import_gap_intervals IS
'Phase 1E-A: additive sum of analytics.energy_consumption_15min.import_gap_intervals for this site-local day. NULL for rows persisted before this column existed.';


-- ----------------------------------------------------------------------------
-- 2. Extend the 15-minute refresh function to persist the six columns it
--    already reads from analytics.v_energy_semantic_rollup_15min.
-- ----------------------------------------------------------------------------

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
            EXCLUDED.calculated_at;


    GET DIAGNOSTICS
        v_affected = ROW_COUNT;

    RETURN v_affected;

END;

$function$;

COMMENT ON FUNCTION analytics.refresh_energy_consumption_15min(TIMESTAMPTZ, TIMESTAMPTZ) IS
'Refreshes persisted canonical 15-minute energy-consumption semantics from analytics.v_energy_semantic_rollup_15min using native semantic interval boundaries. Phase 1E-A: also persists the six per-flow gap/reset/rollover interval counts the source view already computes, alongside the existing combined counters.';


-- ----------------------------------------------------------------------------
-- 3. Extend the hourly refresh function to additively sum the six columns
--    from the (now-extended) persisted 15-minute table only.
-- ----------------------------------------------------------------------------

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
            EXCLUDED.calculated_at;


    GET DIAGNOSTICS
        v_affected = ROW_COUNT;

    RETURN v_affected;

END;

$function$;

COMMENT ON FUNCTION analytics.refresh_energy_consumption_hourly(TIMESTAMPTZ, TIMESTAMPTZ) IS
'Persists hourly validated energy consumption aggregated only from already-classified 15-minute semantic intervals. Phase 1E-A: also additively sums the six per-flow gap/reset/rollover interval counts from the 15-minute tier, alongside the existing combined counters.';


-- ----------------------------------------------------------------------------
-- 4. Extend the daily refresh function identically. Timezone/local-day
--    bucketing logic is entirely unchanged; only the additional summed
--    columns are new.
-- ----------------------------------------------------------------------------

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
            EXCLUDED.calculated_at;


    GET DIAGNOSTICS
        v_affected = ROW_COUNT;

    RETURN v_affected;

END;

$function$;

COMMENT ON FUNCTION analytics.refresh_energy_consumption_daily(TIMESTAMPTZ, TIMESTAMPTZ) IS
'Persists site-local daily energy consumption using metadata.sites.timezone rather than UTC-aligned hourly aggregation. Do NOT aggregate from UTC-aligned hourly history -- a UTC hourly bucket may cross a site''s local midnight. Phase 1E-A: also additively sums the six per-flow gap/reset/rollover interval counts from the 15-minute tier, alongside the existing combined counters.';
