-- ============================================================================
-- Migration 264
-- Analytical backbone M1: generic 15-minute point-telemetry tier
-- (analytics.point_telemetry_15m).
--
-- Decision record: docs/00-governance/decisions/ADR-019-analytical-backbone-
-- time-basis-and-tiers.md (UTC canonical time basis; 15m is the common
-- persisted upstream tier for 30m / 1h / 1d).
--
-- WHAT (additive only)
--   1. analytics.point_telemetry_15m -- TimescaleDB continuous aggregate over
--      telemetry.normalized_points on the UTC 15-minute grid, grouped by
--      organization_id, site_id, device_id, logical_point_id, storing
--      sum_value / sample_count / min_value / max_value. avg is NOT stored:
--      it is sum_value / sample_count at read time, and sum/count (unlike an
--      average) re-aggregate exactly into 30m / 1h / 1d.
--   2. Two NON-OVERLAPPING refresh policies (both bounded):
--        forward   : [now - 2 days,  now - 1 minute), every 5 minutes
--        late-data : [now - 35 days, now - 2 days),   every 1 day
--      The late-data policy covers the agreed 35-day recovery window
--      (telemetry.raw_message_failures is kept 30 days, and failed-message
--      recovery can re-normalize rows that old). Refresh is invalidation-
--      driven, so an unchanged window is a near no-op.
--      Verified on TimescaleDB 2.29.2 (the staging version) before writing
--      this file: a second policy with a disjoint window is accepted, an
--      overlapping one is rejected, and a late insert 20 days back is
--      picked up by the 35-day policy.
--   3. 120-day retention policy on the aggregate. NO compression.
--   4. analytics.backfill_point_telemetry_15m(p_from, p_to, p_slice) -- the
--      ONLY sanctioned way to populate history older than the policies'
--      windows (initial backfill). Bounded, 15-minute aligned, sliced, and
--      refuses any window that starts before the oldest surviving
--      telemetry.normalized_points chunk.
--   5. Grants: SELECT to ems_app, ems_readonly. NOT grafana_reader -- this
--      aggregate is not tenant-scoped; tenant-scoped reads go through
--      SECURITY DEFINER functions (future /analytics/series), never a direct
--      Grafana SELECT.
--
-- NO UNBOUNDED REFRESH -- ever
--   refresh_continuous_aggregate() over a window whose raw data has already
--   been dropped DELETES the matching aggregate rows (documented TimescaleDB
--   behaviour). normalized_points is kept 90 days and this aggregate 120
--   days, so CALL refresh_continuous_aggregate('analytics.point_telemetry_15m',
--   NULL, NULL) would destroy the 90-120 day history. Never run it. Use the
--   policies, or analytics.backfill_point_telemetry_15m for bounded windows.
--
-- Filter
--   numeric_value IS NOT NULL AND quality_code = 'GOOD' -- the same GOOD-only
--   convention the energy routing loader uses. A continuous aggregate's WHERE
--   clause cannot be changed later without a rebuild, and a rebuild can only
--   recover the 90 days of raw telemetry still retained.
--
-- NOT in this migration
--   The legacy analytics.generic_telemetry_15m / _1h (migration 185), the
--   Explorer function, Energy tiers, normalized_points retention, and every
--   existing consumer are untouched. Nothing is dropped or unscheduled.
--   normalized_points gains no asset_id column; Asset attribution resolves at
--   read time through metadata.asset_points.
--
-- Initial backfill (operator step, AFTER this migration, top-level CALL only)
--   The forward policy fills the last 2 days on its first run; the late-data
--   policy fills [now-35d, now-2d) on its first run (first scheduled for the
--   next 21:30 UTC). History older than 35 days is filled once with e.g.:
--     CALL analytics.backfill_point_telemetry_15m(
--         <oldest normalized_points chunk start, 15-minute aligned>,
--         date_bin('15 minutes', now() - interval '35 days',
--                  TIMESTAMPTZ '2000-01-01 00:00:00+00'));
-- ============================================================================


-- ----------------------------------------------------------------------------
-- 0. Job-id sequence guard (same guard as migration 213): must run before
--    add_continuous_aggregate_policy / add_retention_policy allocate job ids.
-- ----------------------------------------------------------------------------
DO $seqfix$
BEGIN
    IF to_regclass('_timescaledb_catalog.bgw_job_id_seq') IS NOT NULL THEN
        PERFORM setval(
            '_timescaledb_catalog.bgw_job_id_seq',
            GREATEST(
                (SELECT last_value FROM _timescaledb_catalog.bgw_job_id_seq),
                (SELECT COALESCE(max(id), 0) FROM _timescaledb_config.bgw_job)
            ),
            true
        );
    END IF;
END
$seqfix$;


-- ----------------------------------------------------------------------------
-- 1. Preconditions.
-- ----------------------------------------------------------------------------
DO $pre$
BEGIN
    IF to_regclass('telemetry.normalized_points') IS NULL THEN
        RAISE EXCEPTION 'Migration 264 precondition failed: telemetry.normalized_points is missing.';
    END IF;

    IF to_regclass('analytics.point_telemetry_15m') IS NOT NULL THEN
        RAISE EXCEPTION 'Migration 264 precondition failed: analytics.point_telemetry_15m already exists.';
    END IF;

    IF (
        SELECT count(*)
        FROM information_schema.columns
        WHERE table_schema = 'telemetry'
          AND table_name = 'normalized_points'
          AND column_name IN ('event_time', 'organization_id', 'site_id', 'device_id',
                              'logical_point_id', 'numeric_value', 'quality_code')
    ) <> 7 THEN
        RAISE EXCEPTION 'Migration 264 precondition failed: telemetry.normalized_points is missing an expected column.';
    END IF;
END
$pre$;


-- ----------------------------------------------------------------------------
-- 2. Continuous aggregate.
--    time_bucket(interval, timestamptz) without a timezone argument buckets
--    on absolute UTC instants, independent of the session TimeZone.
-- ----------------------------------------------------------------------------
CREATE MATERIALIZED VIEW analytics.point_telemetry_15m
WITH
(
    timescaledb.continuous,
    timescaledb.materialized_only = TRUE,
    timescaledb.create_group_indexes = FALSE
)
AS
SELECT
    time_bucket(INTERVAL '15 minutes', np.event_time) AS bucket_start,

    np.organization_id,
    np.site_id,
    np.device_id,
    np.logical_point_id,

    sum(np.numeric_value)   AS sum_value,
    count(np.numeric_value) AS sample_count,
    min(np.numeric_value)   AS min_value,
    max(np.numeric_value)   AS max_value

FROM telemetry.normalized_points AS np

WHERE np.numeric_value IS NOT NULL
  AND np.quality_code = 'GOOD'

GROUP BY
    time_bucket(INTERVAL '15 minutes', np.event_time),
    np.organization_id,
    np.site_id,
    np.device_id,
    np.logical_point_id

WITH NO DATA;


CREATE INDEX ix_point_telemetry_15m_device_point_bucket
    ON analytics.point_telemetry_15m (device_id, logical_point_id, bucket_start DESC);

CREATE INDEX ix_point_telemetry_15m_site_bucket
    ON analytics.point_telemetry_15m (site_id, bucket_start DESC);


COMMENT ON VIEW analytics.point_telemetry_15m IS
'Analytical backbone M1 (migration 264, ADR-019): generic 15-minute point telemetry on the UTC grid, the common persisted upstream tier for 30m/1h/1d. sum_value/sample_count/min_value/max_value over GOOD numeric samples of telemetry.normalized_points; average = sum_value / sample_count at read time. Keyed by device/logical point, NOT asset: Asset attribution resolves at read time through metadata.asset_points. Not tenant-scoped: read only via tenant-scoped SECURITY DEFINER functions. Bounded refresh policies [now-2d, now-1m) every 5m and [now-35d, now-2d) daily; 120-day retention; no compression. NEVER refresh with NULL bounds -- it would delete history older than the 90-day raw retention; use analytics.backfill_point_telemetry_15m.';

COMMENT ON COLUMN analytics.point_telemetry_15m.bucket_start IS
'UTC instant starting the 15-minute bucket (UTC grid). Every IANA timezone offset is a multiple of 15 minutes, so these buckets nest exactly inside any site-local hour or day.';

COMMENT ON COLUMN analytics.point_telemetry_15m.sum_value IS
'Sum of GOOD numeric samples in the bucket. Re-aggregates exactly (sum of sums).';

COMMENT ON COLUMN analytics.point_telemetry_15m.sample_count IS
'Number of GOOD numeric samples in the bucket. Re-aggregates exactly (sum of counts); average = sum_value / sample_count.';

COMMENT ON COLUMN analytics.point_telemetry_15m.min_value IS
'Minimum GOOD numeric sample in the bucket (re-aggregates as min of mins).';

COMMENT ON COLUMN analytics.point_telemetry_15m.max_value IS
'Maximum GOOD numeric sample in the bucket (re-aggregates as max of maxes).';


-- ----------------------------------------------------------------------------
-- 3. Refresh policies (bounded, non-overlapping) and retention. No
--    compression policy is added (locked: 15m is uncompressed for now).
-- ----------------------------------------------------------------------------
SELECT add_continuous_aggregate_policy
(
    'analytics.point_telemetry_15m'::REGCLASS,

    start_offset      => INTERVAL '2 days',
    end_offset        => INTERVAL '1 minute',
    schedule_interval => INTERVAL '5 minutes'
);


SELECT add_continuous_aggregate_policy
(
    'analytics.point_telemetry_15m'::REGCLASS,

    start_offset      => INTERVAL '35 days',
    end_offset        => INTERVAL '2 days',
    schedule_interval => INTERVAL '1 day',

    -- Off-peak: next 21:30 UTC (03:00 Asia/Kolkata).
    initial_start     => date_bin(INTERVAL '1 day', now(), TIMESTAMPTZ '2000-01-01 00:00:00+00')
                         + INTERVAL '1 day'
                         + INTERVAL '21 hours 30 minutes'
);


SELECT add_retention_policy
(
    'analytics.point_telemetry_15m'::REGCLASS,

    drop_after => INTERVAL '120 days'
);


-- ----------------------------------------------------------------------------
-- 4. Bounded backfill procedure.
--    Transaction control (COMMIT) is required because
--    refresh_continuous_aggregate() cannot run inside a transaction block;
--    PostgreSQL forbids transaction control in a procedure that has a SET
--    clause or is SECURITY DEFINER, so every name below is schema-qualified
--    and the procedure runs with the caller's rights (EXECUTE: ems_admin).
--    Must be invoked with a top-level CALL (not inside BEGIN ... COMMIT).
-- ----------------------------------------------------------------------------
CREATE PROCEDURE analytics.backfill_point_telemetry_15m
(
    p_from  TIMESTAMPTZ,
    p_to    TIMESTAMPTZ,
    p_slice INTERVAL DEFAULT INTERVAL '1 day'
)
LANGUAGE plpgsql
AS $procedure$
DECLARE
    v_origin      CONSTANT TIMESTAMPTZ := TIMESTAMPTZ '2000-01-01 00:00:00+00';
    v_raw_floor   TIMESTAMPTZ;
    v_slice_start TIMESTAMPTZ;
    v_slice_end   TIMESTAMPTZ;
BEGIN
    IF p_from IS NULL OR p_to IS NULL OR p_slice IS NULL THEN
        RAISE EXCEPTION 'backfill_point_telemetry_15m: p_from, p_to and p_slice are required (unbounded refresh is forbidden)'
            USING ERRCODE = '22023';
    END IF;

    IF p_to <= p_from THEN
        RAISE EXCEPTION 'backfill_point_telemetry_15m: p_to (%) must be later than p_from (%)', p_to, p_from
            USING ERRCODE = '22023';
    END IF;

    IF p_to > now() THEN
        RAISE EXCEPTION 'backfill_point_telemetry_15m: p_to (%) must not be in the future', p_to
            USING ERRCODE = '22023';
    END IF;

    IF pg_catalog.date_bin(INTERVAL '15 minutes', p_from, v_origin) <> p_from
       OR pg_catalog.date_bin(INTERVAL '15 minutes', p_to, v_origin) <> p_to THEN
        RAISE EXCEPTION 'backfill_point_telemetry_15m: p_from (%) and p_to (%) must be aligned to the UTC 15-minute grid', p_from, p_to
            USING ERRCODE = '22023';
    END IF;

    IF p_slice < INTERVAL '15 minutes'
       OR p_slice > INTERVAL '7 days'
       OR pg_catalog.mod(extract(epoch FROM p_slice)::numeric, 900) <> 0 THEN
        RAISE EXCEPTION 'backfill_point_telemetry_15m: p_slice (%) must be a multiple of 15 minutes between 15 minutes and 7 days', p_slice
            USING ERRCODE = '22023';
    END IF;

    v_slice_start := p_from;

    WHILE v_slice_start < p_to LOOP
        v_slice_end := LEAST(v_slice_start + p_slice, p_to);

        -- Re-checked for every slice: the normalized_points retention job may
        -- drop the oldest chunk while a long backfill is running. Refreshing
        -- over a dropped chunk would delete already-materialized buckets.
        SELECT min(c.range_start)
        INTO v_raw_floor
        FROM timescaledb_information.chunks AS c
        WHERE c.hypertable_schema = 'telemetry'
          AND c.hypertable_name = 'normalized_points';

        IF v_raw_floor IS NULL OR v_slice_start < v_raw_floor THEN
            RAISE EXCEPTION 'backfill_point_telemetry_15m: slice start % precedes the oldest retained telemetry.normalized_points chunk (%); refusing to refresh over dropped raw data', v_slice_start, v_raw_floor
                USING ERRCODE = '22023';
        END IF;

        COMMIT;

        CALL public.refresh_continuous_aggregate('analytics.point_telemetry_15m', v_slice_start, v_slice_end);

        RAISE NOTICE 'backfill_point_telemetry_15m: refreshed [%, %)', v_slice_start, v_slice_end;

        v_slice_start := v_slice_end;
    END LOOP;
END;
$procedure$;


COMMENT ON PROCEDURE analytics.backfill_point_telemetry_15m(TIMESTAMPTZ, TIMESTAMPTZ, INTERVAL) IS
'Migration 264: the only sanctioned way to refresh analytics.point_telemetry_15m outside its two bounded policies (initial backfill). Requires explicit, 15-minute-aligned, non-future [p_from, p_to); refreshes in p_slice slices (15 minutes to 7 days, default 1 day) with a COMMIT before each; refuses, per slice, any start before the oldest retained telemetry.normalized_points chunk so it can never refresh over dropped raw data. Top-level CALL only.';


-- ----------------------------------------------------------------------------
-- 5. Grants.
-- ----------------------------------------------------------------------------
REVOKE ALL ON analytics.point_telemetry_15m FROM PUBLIC;

GRANT SELECT ON analytics.point_telemetry_15m TO ems_app, ems_readonly;

REVOKE ALL ON PROCEDURE analytics.backfill_point_telemetry_15m(TIMESTAMPTZ, TIMESTAMPTZ, INTERVAL) FROM PUBLIC;

GRANT EXECUTE ON PROCEDURE analytics.backfill_point_telemetry_15m(TIMESTAMPTZ, TIMESTAMPTZ, INTERVAL) TO ems_admin;


-- ----------------------------------------------------------------------------
-- 6. Postconditions.
-- ----------------------------------------------------------------------------
DO $post$
DECLARE
    v_mat_id   INTEGER;
    v_count    INTEGER;
BEGIN
    SELECT ca.mat_hypertable_id
    INTO v_mat_id
    FROM _timescaledb_catalog.continuous_agg AS ca
    WHERE ca.user_view_schema = 'analytics'
      AND ca.user_view_name = 'point_telemetry_15m';

    IF v_mat_id IS NULL THEN
        RAISE EXCEPTION 'Migration 264 postcondition failed: analytics.point_telemetry_15m is not a continuous aggregate.';
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM _timescaledb_catalog.continuous_aggs_bucket_function AS bf
        WHERE bf.mat_hypertable_id = v_mat_id
          AND bf.bucket_width::INTERVAL = INTERVAL '15 minutes'
          AND bf.bucket_timezone IS NULL
          AND bf.bucket_fixed_width
    ) THEN
        RAISE EXCEPTION 'Migration 264 postcondition failed: bucket is not a fixed-width UTC 15-minute bucket.';
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM timescaledb_information.continuous_aggregates AS c
        WHERE c.view_schema = 'analytics'
          AND c.view_name = 'point_telemetry_15m'
          AND c.materialized_only
          AND NOT c.compression_enabled
    ) THEN
        RAISE EXCEPTION 'Migration 264 postcondition failed: expected materialized_only = true and compression disabled.';
    END IF;

    SELECT count(*)
    INTO v_count
    FROM timescaledb_information.jobs AS j
    WHERE j.proc_name = 'policy_refresh_continuous_aggregate'
      AND (j.config ->> 'mat_hypertable_id')::INTEGER = v_mat_id
      AND (
            (j.config ->> 'start_offset' = '2 days'  AND j.config ->> 'end_offset' = '00:01:00' AND j.schedule_interval = INTERVAL '5 minutes')
         OR (j.config ->> 'start_offset' = '35 days' AND j.config ->> 'end_offset' = '2 days'    AND j.schedule_interval = INTERVAL '1 day')
          );

    IF v_count <> 2 THEN
        RAISE EXCEPTION 'Migration 264 postcondition failed: expected exactly the two bounded refresh policies, found % matching.', v_count;
    END IF;

    IF (
        SELECT count(*)
        FROM timescaledb_information.jobs AS j
        WHERE j.proc_name = 'policy_refresh_continuous_aggregate'
          AND (j.config ->> 'mat_hypertable_id')::INTEGER = v_mat_id
    ) <> 2 THEN
        RAISE EXCEPTION 'Migration 264 postcondition failed: unexpected extra refresh policy on analytics.point_telemetry_15m.';
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM timescaledb_information.jobs AS j
        WHERE j.proc_name = 'policy_retention'
          AND (j.config ->> 'hypertable_id')::INTEGER = v_mat_id
          AND j.config ->> 'drop_after' = '120 days'
    ) THEN
        RAISE EXCEPTION 'Migration 264 postcondition failed: 120-day retention policy is missing.';
    END IF;

    IF EXISTS (
        SELECT 1
        FROM timescaledb_information.jobs AS j
        WHERE j.proc_name = 'policy_compression'
          AND (j.config ->> 'hypertable_id')::INTEGER = v_mat_id
    ) THEN
        RAISE EXCEPTION 'Migration 264 postcondition failed: a compression policy exists on analytics.point_telemetry_15m.';
    END IF;

    IF NOT has_table_privilege('ems_app', 'analytics.point_telemetry_15m', 'SELECT')
       OR NOT has_table_privilege('ems_readonly', 'analytics.point_telemetry_15m', 'SELECT')
       OR has_table_privilege('grafana_reader', 'analytics.point_telemetry_15m', 'SELECT') THEN
        RAISE EXCEPTION 'Migration 264 postcondition failed: unexpected grants on analytics.point_telemetry_15m.';
    END IF;

    RAISE NOTICE 'Migration 264: all postconditions passed (analytics.point_telemetry_15m: UTC 15m continuous aggregate, 2 bounded refresh policies, 120-day retention, no compression, backfill procedure, grants).';
END
$post$;
