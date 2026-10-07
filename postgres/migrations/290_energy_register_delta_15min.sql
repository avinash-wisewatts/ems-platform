-- ============================================================================
-- Migration 290
-- F1: persisted 15-minute register-delta tier for cumulative energy registers
-- (analytics.energy_register_delta_15min), its refresh function, forward job
-- (which also performs the initial backfill, oldest first) and reconcile job.
--
-- WHY NOW
--   Phase registers (L1-L3 of active import/export, reactive, reactive export
--   and apparent energy) exist only in the raw tables telemetry.
--   energy_measurements / telemetry.normalized_points (90-day retention). This
--   tier preserves their history before it ages out. No customer read path,
--   API or catalogue change: exposure is a later PR (F2).
--
-- SEMANTICS (the existing Energy rules, unchanged)
--   * Source: telemetry.energy_measurements -- one row per device per capture
--     bucket carrying every register (the same source as telemetry.
--     ca_energy_1min, which feeds the Energy pipeline).
--   * For each device and register the predecessor is the device's previous
--     row (the Energy "previous eligible bucket"), never a row of another
--     device, so no delta ever spans two devices.
--   * Each delta is classified by the canonical, unchanged
--     analytics.classify_energy_register_delta with the register's
--     config.energy_register_semantics row: decreases are resets (rejected),
--     no rollover is assumed, implausible jumps are invalid, the first reading
--     of a device is INITIAL (no delta), and a GAP keeps its delta (the
--     migration-039 rule) while being counted as a gap.
--   * Gap threshold: least(config.resolve_interval_quality_rule, 1.5 x the
--     site capture interval) -- migration 039's native rule (1.5 min at 60 s,
--     7.5 min at 300 s), resolved once per device row. Rows without an
--     effective capture policy are not processed (as the Energy 1-minute tier).
--   * Reconstruction is OFF: nothing is interpolated or redistributed.
--   * A delta belongs to the 15-minute UTC bucket containing the reading that
--     closes it (the Energy 1-minute -> 15-minute attribution). Site-local
--     30m/1h/1d buckets compose from these rows at read time (all site
--     offsets are multiples of 15 minutes).
--   * Stored per device and logical point, not per asset: asset attribution
--     (metadata.asset_points) is resolved at read time, as for Energy.
--   * delta_value = sum of the valid interval deltas x scale_to_normalized_unit,
--     in the register's normalized unit (Wh / varh / VAh); NULL when the
--     bucket has no valid interval.
--   * Active import/export TOTAL are included so the tier can be checked
--     against the existing Energy tiers; the existing Energy path is
--     untouched.
--
-- WHAT (additive only)
--   1. analytics.energy_register_delta_15min -- hypertable (7-day chunks),
--      identity (device_id, logical_point_id, bucket_start), 2-year retention,
--      compression after 30 days.
--   2. analytics.refresh_energy_register_delta_15min(p_from, p_to) -- the
--      only writer; bounded (15-minute aligned, at most 2 days, never the
--      in-progress bucket), value-aware upsert, never removes rows.
--   3. analytics.run_energy_register_delta_15min_job -- forward job. First run
--      starts at the earliest telemetry.energy_measurements row, so the
--      backfill happens automatically, oldest first, at most
--      max_catchup_window per run. The only writer of telemetry.pipeline_state
--      ('energy_register_delta_15min').last_received_at.
--   4. analytics.reconcile_energy_register_delta_15min -- daily re-run of a
--      trailing window (default 3 days) up to the checkpoint, absorbing late
--      data; never moves the checkpoint, never removes rows.
--   5. pipeline_state row; both jobs scheduled; policies scheduled.
--   6. Grants: table SELECT to ems_app, ems_readonly; routines EXECUTE to
--      ems_admin only.
--
-- NOT in this migration
--   Any read function, API, registry, catalogue or frontend change; any change
--   to telemetry.energy_measurements, the Energy tiers or their jobs,
--   analytics.classify_energy_register_delta, config.energy_register_semantics
--   or retention of the raw tables.
-- ============================================================================


-- ----------------------------------------------------------------------------
-- 0. Job-id sequence guard (migration 213): before any add_job /
--    add_retention_policy / add_compression_policy.
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
DECLARE
    v_missing TEXT;
BEGIN
    IF to_regclass('analytics.energy_register_delta_15min') IS NOT NULL THEN
        RAISE EXCEPTION 'Migration 290 precondition failed: analytics.energy_register_delta_15min already exists.';
    END IF;

    IF to_regprocedure('analytics.classify_energy_register_delta(numeric, numeric, numeric, text, text, numeric, text, numeric, numeric)') IS NULL
       OR to_regprocedure('config.resolve_interval_quality_rule(uuid, timestamptz)') IS NULL
       OR to_regprocedure('telemetry.resolve_site_capture_bucket(uuid, timestamptz)') IS NULL THEN
        RAISE EXCEPTION 'Migration 290 precondition failed: the canonical register classifier, quality-rule or capture-policy resolver is missing.';
    END IF;

    IF to_regprocedure('config.assert_analytical_lookback_job_config(jsonb)') IS NULL
       OR to_regprocedure('config.assert_reconciliation_job_config(jsonb)') IS NULL THEN
        RAISE EXCEPTION 'Migration 290 precondition failed: job config validators are missing.';
    END IF;

    -- Every register column of the source exists.
    SELECT string_agg(c, ', ') INTO v_missing
    FROM unnest(ARRAY[
        'import_energy_total_wh', 'import_energy_l1_wh', 'import_energy_l2_wh', 'import_energy_l3_wh',
        'export_energy_total_wh', 'export_energy_l1_wh', 'export_energy_l2_wh', 'export_energy_l3_wh',
        'reactive_energy_total_varh', 'reactive_energy_l1_varh', 'reactive_energy_l2_varh', 'reactive_energy_l3_varh',
        'reactive_export_energy_total_varh', 'reactive_export_energy_l1_varh', 'reactive_export_energy_l2_varh', 'reactive_export_energy_l3_varh',
        'apparent_energy_total_vah', 'apparent_energy_l1_vah', 'apparent_energy_l2_vah', 'apparent_energy_l3_vah']) AS c
    WHERE NOT EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema = 'telemetry' AND table_name = 'energy_measurements' AND column_name = c);
    IF v_missing IS NOT NULL THEN
        RAISE EXCEPTION 'Migration 290 precondition failed: telemetry.energy_measurements is missing column(s) %.', v_missing;
    END IF;

    -- Every register logical point exists.
    SELECT string_agg(n, ', ') INTO v_missing
    FROM unnest(ARRAY[
        'ENERGY_IMPORT_TOTAL', 'ENERGY_IMPORT_L1', 'ENERGY_IMPORT_L2', 'ENERGY_IMPORT_L3',
        'ENERGY_EXPORT_TOTAL', 'ENERGY_EXPORT_L1', 'ENERGY_EXPORT_L2', 'ENERGY_EXPORT_L3',
        'REACTIVE_ENERGY_TOTAL', 'REACTIVE_ENERGY_L1', 'REACTIVE_ENERGY_L2', 'REACTIVE_ENERGY_L3',
        'ENERGY_REACTIVE_EXPORT_TOTAL', 'ENERGY_REACTIVE_EXPORT_L1', 'ENERGY_REACTIVE_EXPORT_L2', 'ENERGY_REACTIVE_EXPORT_L3',
        'APPARENT_ENERGY_TOTAL', 'APPARENT_ENERGY_L1', 'APPARENT_ENERGY_L2', 'APPARENT_ENERGY_L3']) AS n
    WHERE NOT EXISTS (SELECT 1 FROM metadata.logical_points WHERE name = n);
    IF v_missing IS NOT NULL THEN
        RAISE EXCEPTION 'Migration 290 precondition failed: logical point(s) % missing.', v_missing;
    END IF;

    IF EXISTS (SELECT 1 FROM telemetry.pipeline_state WHERE pipeline_name = 'energy_register_delta_15min') THEN
        RAISE EXCEPTION 'Migration 290 precondition failed: pipeline_state row energy_register_delta_15min already exists.';
    END IF;
END
$pre$;


-- ----------------------------------------------------------------------------
-- 2. Table.
-- ----------------------------------------------------------------------------
CREATE TABLE analytics.energy_register_delta_15min
(
    bucket_start             TIMESTAMPTZ NOT NULL,

    organization_id          UUID        NOT NULL,
    site_id                  UUID        NOT NULL,
    device_id                UUID        NOT NULL,
    logical_point_id         UUID        NOT NULL,

    delta_value              NUMERIC,

    source_interval_count    INTEGER     NOT NULL,
    valid_interval_count     INTEGER     NOT NULL,
    gap_interval_count       INTEGER     NOT NULL,
    reset_interval_count     INTEGER     NOT NULL,
    rollover_interval_count  INTEGER     NOT NULL,
    initial_interval_count   INTEGER     NOT NULL,
    invalid_interval_count   INTEGER     NOT NULL,

    first_source_bucket      TIMESTAMPTZ NOT NULL,
    last_source_bucket       TIMESTAMPTZ NOT NULL,

    calculated_at            TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),

    CONSTRAINT energy_register_delta_15min_grid_chk
        CHECK (bucket_start = date_bin(INTERVAL '15 minutes', bucket_start, TIMESTAMPTZ '2000-01-01 00:00:00+00')),
    CONSTRAINT energy_register_delta_15min_counts_chk
        CHECK (source_interval_count > 0
               AND valid_interval_count BETWEEN 0 AND source_interval_count
               AND gap_interval_count BETWEEN 0 AND valid_interval_count
               AND reset_interval_count BETWEEN 0 AND source_interval_count
               AND rollover_interval_count BETWEEN 0 AND source_interval_count
               AND initial_interval_count BETWEEN 0 AND source_interval_count
               AND invalid_interval_count BETWEEN 0 AND source_interval_count
               AND valid_interval_count + initial_interval_count + invalid_interval_count = source_interval_count),
    CONSTRAINT energy_register_delta_15min_delta_chk
        CHECK ((valid_interval_count = 0) = (delta_value IS NULL)),
    CONSTRAINT energy_register_delta_15min_source_bounds_chk
        CHECK (first_source_bucket <= last_source_bucket
               AND first_source_bucket >= bucket_start
               AND last_source_bucket < bucket_start + INTERVAL '15 minutes')
);

SELECT create_hypertable
(
    'analytics.energy_register_delta_15min',
    'bucket_start',
    chunk_time_interval => INTERVAL '7 days'
);

CREATE UNIQUE INDEX ux_energy_register_delta_15min_identity
    ON analytics.energy_register_delta_15min (device_id, logical_point_id, bucket_start);

CREATE INDEX ix_energy_register_delta_15min_site_bucket
    ON analytics.energy_register_delta_15min (site_id, bucket_start DESC);

ALTER TABLE analytics.energy_register_delta_15min SET
(
    timescaledb.compress,
    timescaledb.compress_segmentby = 'device_id, logical_point_id',
    timescaledb.compress_orderby   = 'bucket_start DESC'
);

COMMENT ON TABLE analytics.energy_register_delta_15min IS
'Migration 290 (F1): per device, register logical point and 15-minute UTC bucket, the interval deltas of a cumulative energy register computed from telemetry.energy_measurements with the canonical analytics.classify_energy_register_delta and the register''s config.energy_register_semantics (the existing Energy rules; reconstruction OFF). Keyed by device, not asset: asset attribution resolves at read time through metadata.asset_points. Not tenant-scoped: read only via tenant-scoped SECURITY DEFINER functions. Written only by analytics.refresh_energy_register_delta_15min; rows are never removed except by the 2-year retention policy.';

COMMENT ON COLUMN analytics.energy_register_delta_15min.bucket_start IS
'15-minute UTC bucket (date_bin, origin 2000-01-01 00:00 UTC) containing the readings that close the counted intervals. Site-local 30m/1h/1d buckets compose from these rows (every site offset is a multiple of 15 minutes).';

COMMENT ON COLUMN analytics.energy_register_delta_15min.delta_value IS
'Sum of the valid interval deltas x config.energy_register_semantics.scale_to_normalized_unit, in the register''s normalized unit (Wh, varh or VAh). NULL when no interval in the bucket is valid. GAP intervals are valid (migration 039: the cumulative delta is kept) and also counted in gap_interval_count.';

COMMENT ON COLUMN analytics.energy_register_delta_15min.source_interval_count IS
'Readings closing an interval in this bucket = valid_interval_count + initial_interval_count + invalid_interval_count.';

COMMENT ON COLUMN analytics.energy_register_delta_15min.initial_interval_count IS
'Readings with no predecessor row of the same device (the device''s first reading): no delta, by the Energy rule.';

COMMENT ON COLUMN analytics.energy_register_delta_15min.invalid_interval_count IS
'Readings whose delta was rejected by the classifier (RESET, IMPLAUSIBLE_DELTA, MISSING_REGISTER, configuration or direction errors). reset_interval_count and rollover_interval_count break out reset / rollover detections.';


-- ----------------------------------------------------------------------------
-- 3. Retention (2 years) and compression (after 30 days) -- scheduled.
-- ----------------------------------------------------------------------------
SELECT add_retention_policy('analytics.energy_register_delta_15min', drop_after => INTERVAL '2 years');

SELECT add_compression_policy('analytics.energy_register_delta_15min', compress_after => INTERVAL '30 days');


-- ----------------------------------------------------------------------------
-- 4. Refresh (the only writer of the table).
-- ----------------------------------------------------------------------------
CREATE FUNCTION analytics.refresh_energy_register_delta_15min
(
    p_from TIMESTAMPTZ,
    p_to   TIMESTAMPTZ
)
RETURNS BIGINT
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO pg_catalog, analytics, telemetry, config, metadata
AS $function$
DECLARE
    v_origin CONSTANT TIMESTAMPTZ := TIMESTAMPTZ '2000-01-01 00:00:00+00';
    v_rows   BIGINT;
BEGIN
    IF p_from IS NULL OR p_to IS NULL THEN
        RAISE EXCEPTION 'refresh_energy_register_delta_15min: p_from and p_to are required (unbounded refresh is forbidden)'
            USING ERRCODE = '22023';
    END IF;

    IF p_to <= p_from THEN
        RAISE EXCEPTION 'refresh_energy_register_delta_15min: p_to (%) must be later than p_from (%)', p_to, p_from
            USING ERRCODE = '22023';
    END IF;

    IF date_bin(INTERVAL '15 minutes', p_from, v_origin) <> p_from
       OR date_bin(INTERVAL '15 minutes', p_to, v_origin) <> p_to THEN
        RAISE EXCEPTION 'refresh_energy_register_delta_15min: p_from (%) and p_to (%) must be aligned to the 15-minute UTC grid', p_from, p_to
            USING ERRCODE = '22023';
    END IF;

    IF p_to - p_from > INTERVAL '2 days' THEN
        RAISE EXCEPTION 'refresh_energy_register_delta_15min: window [%, %) exceeds 2 days', p_from, p_to
            USING ERRCODE = '22023';
    END IF;

    IF p_to > date_bin(INTERVAL '15 minutes', clock_timestamp(), v_origin) THEN
        RAISE EXCEPTION 'refresh_energy_register_delta_15min: p_to (%) is beyond the last closed 15-minute bucket', p_to
            USING ERRCODE = '22023';
    END IF;

    WITH register_map (lp_name) AS (
        VALUES
            ('ENERGY_IMPORT_TOTAL'), ('ENERGY_IMPORT_L1'), ('ENERGY_IMPORT_L2'), ('ENERGY_IMPORT_L3'),
            ('ENERGY_EXPORT_TOTAL'), ('ENERGY_EXPORT_L1'), ('ENERGY_EXPORT_L2'), ('ENERGY_EXPORT_L3'),
            ('REACTIVE_ENERGY_TOTAL'), ('REACTIVE_ENERGY_L1'), ('REACTIVE_ENERGY_L2'), ('REACTIVE_ENERGY_L3'),
            ('ENERGY_REACTIVE_EXPORT_TOTAL'), ('ENERGY_REACTIVE_EXPORT_L1'), ('ENERGY_REACTIVE_EXPORT_L2'), ('ENERGY_REACTIVE_EXPORT_L3'),
            ('APPARENT_ENERGY_TOTAL'), ('APPARENT_ENERGY_L1'), ('APPARENT_ENERGY_L2'), ('APPARENT_ENERGY_L3')
    ),
    registers AS MATERIALIZED (
        -- Active register semantics per profile and register (small: one row
        -- per profile x register), looked up by (profile, name) with a hash.
        SELECT ers.profile_id, rm.lp_name, lp.id AS logical_point_id,
               ers.counter_direction, ers.rollover_behavior, ers.rollover_value,
               ers.reset_behavior, ers.expected_max_interval_delta, ers.scale_to_normalized_unit
        FROM register_map AS rm
        JOIN metadata.logical_points AS lp ON lp.name = rm.lp_name
        JOIN config.energy_register_semantics AS ers
          ON ers.logical_point_id = lp.id AND ers.is_active
    ),
    window_rows AS MATERIALIZED (
        SELECT FALSE AS is_seed, em.*
        FROM telemetry.energy_measurements AS em
        WHERE em.bucket_start >= p_from
          AND em.bucket_start <  p_to
    ),
    seed_rows AS MATERIALIZED (
        -- Each device's previous row before the window (the Energy "previous
        -- eligible bucket"); unbounded in time, one index probe per device.
        SELECT p.*
        FROM (SELECT DISTINCT w.device_id FROM window_rows AS w) AS s
        CROSS JOIN LATERAL (
            SELECT TRUE AS is_seed, em.*
            FROM telemetry.energy_measurements AS em
            WHERE em.device_id = s.device_id
              AND em.bucket_start < p_from
            ORDER BY em.bucket_start DESC
            LIMIT 1
        ) AS p
    ),
    ordered AS (
        SELECT
            b.is_seed, b.bucket_start, b.organization_id, b.site_id, b.device_id,
            lag(b.bucket_start) OVER w AS prev_bucket_start,
            b.import_energy_total_wh            AS c01, lag(b.import_energy_total_wh)            OVER w AS p01,
            b.import_energy_l1_wh               AS c02, lag(b.import_energy_l1_wh)               OVER w AS p02,
            b.import_energy_l2_wh               AS c03, lag(b.import_energy_l2_wh)               OVER w AS p03,
            b.import_energy_l3_wh               AS c04, lag(b.import_energy_l3_wh)               OVER w AS p04,
            b.export_energy_total_wh            AS c05, lag(b.export_energy_total_wh)            OVER w AS p05,
            b.export_energy_l1_wh               AS c06, lag(b.export_energy_l1_wh)               OVER w AS p06,
            b.export_energy_l2_wh               AS c07, lag(b.export_energy_l2_wh)               OVER w AS p07,
            b.export_energy_l3_wh               AS c08, lag(b.export_energy_l3_wh)               OVER w AS p08,
            b.reactive_energy_total_varh        AS c09, lag(b.reactive_energy_total_varh)        OVER w AS p09,
            b.reactive_energy_l1_varh           AS c10, lag(b.reactive_energy_l1_varh)           OVER w AS p10,
            b.reactive_energy_l2_varh           AS c11, lag(b.reactive_energy_l2_varh)           OVER w AS p11,
            b.reactive_energy_l3_varh           AS c12, lag(b.reactive_energy_l3_varh)           OVER w AS p12,
            b.reactive_export_energy_total_varh AS c13, lag(b.reactive_export_energy_total_varh) OVER w AS p13,
            b.reactive_export_energy_l1_varh    AS c14, lag(b.reactive_export_energy_l1_varh)    OVER w AS p14,
            b.reactive_export_energy_l2_varh    AS c15, lag(b.reactive_export_energy_l2_varh)    OVER w AS p15,
            b.reactive_export_energy_l3_varh    AS c16, lag(b.reactive_export_energy_l3_varh)    OVER w AS p16,
            b.apparent_energy_total_vah         AS c17, lag(b.apparent_energy_total_vah)         OVER w AS p17,
            b.apparent_energy_l1_vah            AS c18, lag(b.apparent_energy_l1_vah)            OVER w AS p18,
            b.apparent_energy_l2_vah            AS c19, lag(b.apparent_energy_l2_vah)            OVER w AS p19,
            b.apparent_energy_l3_vah            AS c20, lag(b.apparent_energy_l3_vah)            OVER w AS p20
        FROM (SELECT * FROM window_rows UNION ALL SELECT * FROM seed_rows) AS b
        WINDOW w AS (PARTITION BY b.device_id ORDER BY b.bucket_start)
    ),
    device_rows AS MATERIALIZED (
        -- Per device row (never per register): profile, elapsed minutes and
        -- the migration-039 native gap threshold. Rows without an effective
        -- capture policy are skipped (as the Energy 1-minute tier).
        SELECT o.*,
               d.profile_id,
               extract(epoch FROM o.bucket_start - o.prev_bucket_start) / 60.0 AS elapsed_minutes,
               LEAST(qr.gap_threshold_minutes,
                     (cp.capture_interval_seconds * 1.5 / 60.0)::NUMERIC) AS gap_threshold_minutes
        FROM ordered AS o
        JOIN metadata.devices AS d ON d.id = o.device_id
        CROSS JOIN LATERAL telemetry.resolve_site_capture_bucket(o.site_id, o.bucket_start) AS cp
        CROSS JOIN LATERAL config.resolve_interval_quality_rule(o.device_id, o.bucket_start) AS qr
        WHERE NOT o.is_seed
          AND cp.policy_id IS NOT NULL
          AND d.profile_id IS NOT NULL
    ),
    readings AS (
        SELECT r.organization_id, r.site_id, r.device_id, r.profile_id, r.bucket_start,
               r.elapsed_minutes, r.gap_threshold_minutes, u.lp_name, u.cur, u.prev
        FROM device_rows AS r
        CROSS JOIN LATERAL (VALUES
            ('ENERGY_IMPORT_TOTAL', r.c01, r.p01), ('ENERGY_IMPORT_L1', r.c02, r.p02),
            ('ENERGY_IMPORT_L2', r.c03, r.p03), ('ENERGY_IMPORT_L3', r.c04, r.p04),
            ('ENERGY_EXPORT_TOTAL', r.c05, r.p05), ('ENERGY_EXPORT_L1', r.c06, r.p06),
            ('ENERGY_EXPORT_L2', r.c07, r.p07), ('ENERGY_EXPORT_L3', r.c08, r.p08),
            ('REACTIVE_ENERGY_TOTAL', r.c09, r.p09), ('REACTIVE_ENERGY_L1', r.c10, r.p10),
            ('REACTIVE_ENERGY_L2', r.c11, r.p11), ('REACTIVE_ENERGY_L3', r.c12, r.p12),
            ('ENERGY_REACTIVE_EXPORT_TOTAL', r.c13, r.p13), ('ENERGY_REACTIVE_EXPORT_L1', r.c14, r.p14),
            ('ENERGY_REACTIVE_EXPORT_L2', r.c15, r.p15), ('ENERGY_REACTIVE_EXPORT_L3', r.c16, r.p16),
            ('APPARENT_ENERGY_TOTAL', r.c17, r.p17), ('APPARENT_ENERGY_L1', r.c18, r.p18),
            ('APPARENT_ENERGY_L2', r.c19, r.p19), ('APPARENT_ENERGY_L3', r.c20, r.p20)
        ) AS u (lp_name, cur, prev)
        -- A register the device never reports produces no rows.
        WHERE u.cur IS NOT NULL OR u.prev IS NOT NULL
    ),
    classified AS (
        SELECT x.organization_id, x.site_id, x.device_id, g.logical_point_id, x.bucket_start,
               c.delta_wh * g.scale_to_normalized_unit AS delta_value,
               c.quality_code, c.is_valid, c.reset_detected, c.rollover_detected
        FROM readings AS x
        JOIN registers AS g
          ON g.profile_id = x.profile_id
         AND g.lp_name = x.lp_name
        CROSS JOIN LATERAL analytics.classify_energy_register_delta(
            x.cur, x.prev, x.elapsed_minutes,
            g.counter_direction, g.rollover_behavior, g.rollover_value, g.reset_behavior,
            g.expected_max_interval_delta, x.gap_threshold_minutes) AS c
    ),
    buckets AS (
        SELECT
            date_bin(INTERVAL '15 minutes', k.bucket_start, v_origin) AS bucket_start,
            -- The bucket's identity is (device, point, bucket); organization and
            -- site come from its latest reading.
            (array_agg(k.organization_id ORDER BY k.bucket_start DESC))[1] AS organization_id,
            (array_agg(k.site_id ORDER BY k.bucket_start DESC))[1] AS site_id,
            k.device_id,
            k.logical_point_id,
            sum(k.delta_value) FILTER (WHERE k.is_valid) AS delta_value,
            count(*)::INTEGER AS source_interval_count,
            count(*) FILTER (WHERE k.is_valid)::INTEGER AS valid_interval_count,
            count(*) FILTER (WHERE k.is_valid AND k.quality_code = 'GAP')::INTEGER AS gap_interval_count,
            count(*) FILTER (WHERE k.reset_detected)::INTEGER AS reset_interval_count,
            count(*) FILTER (WHERE k.rollover_detected)::INTEGER AS rollover_interval_count,
            count(*) FILTER (WHERE k.quality_code = 'INITIAL')::INTEGER AS initial_interval_count,
            count(*) FILTER (WHERE NOT k.is_valid AND k.quality_code <> 'INITIAL')::INTEGER AS invalid_interval_count,
            min(k.bucket_start) AS first_source_bucket,
            max(k.bucket_start) AS last_source_bucket
        FROM classified AS k
        GROUP BY date_bin(INTERVAL '15 minutes', k.bucket_start, v_origin), k.device_id, k.logical_point_id
    )
    INSERT INTO analytics.energy_register_delta_15min AS t
    (
        bucket_start, organization_id, site_id, device_id, logical_point_id,
        delta_value, source_interval_count, valid_interval_count, gap_interval_count,
        reset_interval_count, rollover_interval_count, initial_interval_count, invalid_interval_count,
        first_source_bucket, last_source_bucket, calculated_at
    )
    SELECT
        b.bucket_start, b.organization_id, b.site_id, b.device_id, b.logical_point_id,
        b.delta_value, b.source_interval_count, b.valid_interval_count, b.gap_interval_count,
        b.reset_interval_count, b.rollover_interval_count, b.initial_interval_count, b.invalid_interval_count,
        b.first_source_bucket, b.last_source_bucket, clock_timestamp()
    FROM buckets AS b
    ON CONFLICT (device_id, logical_point_id, bucket_start)
    DO UPDATE SET
        organization_id         = EXCLUDED.organization_id,
        site_id                 = EXCLUDED.site_id,
        delta_value             = EXCLUDED.delta_value,
        source_interval_count   = EXCLUDED.source_interval_count,
        valid_interval_count    = EXCLUDED.valid_interval_count,
        gap_interval_count      = EXCLUDED.gap_interval_count,
        reset_interval_count    = EXCLUDED.reset_interval_count,
        rollover_interval_count = EXCLUDED.rollover_interval_count,
        initial_interval_count  = EXCLUDED.initial_interval_count,
        invalid_interval_count  = EXCLUDED.invalid_interval_count,
        first_source_bucket     = EXCLUDED.first_source_bucket,
        last_source_bucket      = EXCLUDED.last_source_bucket,
        calculated_at           = EXCLUDED.calculated_at
    WHERE (t.organization_id, t.site_id, t.delta_value, t.source_interval_count, t.valid_interval_count,
           t.gap_interval_count, t.reset_interval_count, t.rollover_interval_count,
           t.initial_interval_count, t.invalid_interval_count, t.first_source_bucket, t.last_source_bucket)
          IS DISTINCT FROM
          (EXCLUDED.organization_id, EXCLUDED.site_id, EXCLUDED.delta_value, EXCLUDED.source_interval_count,
           EXCLUDED.valid_interval_count, EXCLUDED.gap_interval_count, EXCLUDED.reset_interval_count,
           EXCLUDED.rollover_interval_count, EXCLUDED.initial_interval_count, EXCLUDED.invalid_interval_count,
           EXCLUDED.first_source_bucket, EXCLUDED.last_source_bucket);

    GET DIAGNOSTICS v_rows = ROW_COUNT;

    RETURN v_rows;
END;
$function$;

COMMENT ON FUNCTION analytics.refresh_energy_register_delta_15min(TIMESTAMPTZ, TIMESTAMPTZ) IS
'Migration 290: the only writer of analytics.energy_register_delta_15min. Recomputes every 15-minute UTC bucket in [p_from, p_to) from telemetry.energy_measurements (bounded on bucket_start, plus each device''s previous row before p_from) with the canonical analytics.classify_energy_register_delta and config.energy_register_semantics, and upserts it; a row is written only when its values change. Requires explicit 15-minute-aligned bounds, at most 2 days, ending no later than the last closed 15-minute bucket. Never removes rows. Returns the number of rows inserted or changed.';


-- ----------------------------------------------------------------------------
-- 5. Forward job (also the initial, oldest-first backfill).
-- ----------------------------------------------------------------------------
CREATE PROCEDURE analytics.run_energy_register_delta_15min_job
(
    job_id INTEGER,
    config JSONB
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO pg_catalog, analytics, telemetry
AS $procedure$
DECLARE
    v_pipeline_name CONSTANT TEXT := 'energy_register_delta_15min';
    v_origin        CONSTANT TIMESTAMPTZ := TIMESTAMPTZ '2000-01-01 00:00:00+00';
    v_max_catchup   INTERVAL := INTERVAL '1 day';
    v_overlap       INTERVAL := INTERVAL '1 hour';
    v_ckpt          TIMESTAMPTZ;
    v_earliest      TIMESTAMPTZ;
    v_closed        TIMESTAMPTZ;
    v_start         TIMESTAMPTZ;
    v_from          TIMESTAMPTZ;
    v_to            TIMESTAMPTZ;
    v_rows          BIGINT := 0;
BEGIN
    IF config ? 'max_catchup_window' THEN v_max_catchup := (config ->> 'max_catchup_window')::INTERVAL; END IF;
    IF config ? 'overlap'            THEN v_overlap     := (config ->> 'overlap')::INTERVAL; END IF;

    IF v_max_catchup <= INTERVAL '0 seconds' OR v_overlap < INTERVAL '0 seconds'
       OR v_max_catchup + v_overlap > INTERVAL '2 days' THEN
        RAISE EXCEPTION 'energy_register_delta_15min job config: max_catchup_window must be positive, overlap non-negative and their sum at most 2 days (max_catchup_window=%, overlap=%)',
            v_max_catchup, v_overlap;
    END IF;

    IF NOT pg_try_advisory_xact_lock(hashtextextended('analytics.run_energy_register_delta_15min_job', 0)) THEN
        UPDATE telemetry.pipeline_state
        SET last_status = 'SKIPPED_LOCKED', last_error = NULL, updated_at = now()
        WHERE pipeline_name = v_pipeline_name;
        RETURN;
    END IF;

    SELECT last_received_at INTO v_ckpt
    FROM telemetry.pipeline_state
    WHERE pipeline_name = v_pipeline_name
    FOR UPDATE;

    UPDATE telemetry.pipeline_state
    SET last_started_at = clock_timestamp(), last_status = 'RUNNING', last_error = NULL, updated_at = now()
    WHERE pipeline_name = v_pipeline_name;

    v_closed := date_bin(INTERVAL '15 minutes', clock_timestamp(), v_origin);

    IF v_ckpt IS NULL THEN
        -- First run: start at the earliest retained source row, so the whole
        -- retained history is backfilled oldest first.
        SELECT min(em.bucket_start) INTO v_earliest FROM telemetry.energy_measurements AS em;
        v_start := date_bin(INTERVAL '15 minutes', v_earliest, v_origin);
        v_from  := v_start;
    ELSE
        v_start := v_ckpt;
        v_from  := date_bin(INTERVAL '15 minutes', v_ckpt - v_overlap, v_origin);
    END IF;

    v_to := date_bin(INTERVAL '15 minutes', LEAST(v_closed, v_start + v_max_catchup), v_origin);

    IF v_start IS NULL OR v_to IS NULL OR v_to <= v_start THEN
        UPDATE telemetry.pipeline_state
        SET last_completed_at = clock_timestamp(), last_inserted_rows = 0,
            last_status = CASE WHEN v_ckpt IS NOT NULL THEN 'SUCCESS' ELSE 'NO_SOURCE_DATA' END,
            last_error = NULL, updated_at = now()
        WHERE pipeline_name = v_pipeline_name;
        RETURN;
    END IF;

    v_rows := analytics.refresh_energy_register_delta_15min(v_from, v_to);

    UPDATE telemetry.pipeline_state
    SET last_received_at   = v_to,
        last_completed_at  = clock_timestamp(),
        last_inserted_rows = v_rows,
        last_status        = 'SUCCESS',
        last_error         = NULL,
        updated_at         = now()
    WHERE pipeline_name = v_pipeline_name;
EXCEPTION WHEN OTHERS THEN
    UPDATE telemetry.pipeline_state
    SET last_completed_at = clock_timestamp(), last_inserted_rows = 0,
        last_status = 'FAILED', last_error = SQLSTATE || ': ' || SQLERRM, updated_at = now()
    WHERE pipeline_name = v_pipeline_name;
    RAISE;
END;
$procedure$;

COMMENT ON PROCEDURE analytics.run_energy_register_delta_15min_job(INTEGER, JSONB) IS
'Migration 290: forward job for analytics.energy_register_delta_15min. Advisory lock hashtextextended(''analytics.run_energy_register_delta_15min_job'',0) -> SKIPPED_LOCKED. First run (checkpoint NULL) starts at the earliest telemetry.energy_measurements row, so the retained history is backfilled oldest first. Window on the 15-minute UTC grid: v_to = LEAST(last closed bucket, checkpoint + max_catchup_window (1 day)); v_from = checkpoint - overlap (1 hour) re-derives recent buckets so ordinary late data is absorbed. The only writer of telemetry.pipeline_state(''energy_register_delta_15min'').last_received_at, advanced to v_to on success.';


-- ----------------------------------------------------------------------------
-- 6. Reconcile job: re-run a trailing window up to the checkpoint.
-- ----------------------------------------------------------------------------
CREATE PROCEDURE analytics.reconcile_energy_register_delta_15min
(
    job_id INTEGER,
    config JSONB
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO pg_catalog, analytics, telemetry
AS $procedure$
DECLARE
    v_origin   CONSTANT TIMESTAMPTZ := TIMESTAMPTZ '2000-01-01 00:00:00+00';
    v_window   INTERVAL := INTERVAL '3 days';
    v_slice    INTERVAL := INTERVAL '1 day';
    v_ckpt     TIMESTAMPTZ;
    v_from     TIMESTAMPTZ;
    v_to       TIMESTAMPTZ;
BEGIN
    IF config ? 'reconcile_window' THEN v_window := (config ->> 'reconcile_window')::INTERVAL; END IF;
    IF config ? 'coarse'           THEN v_slice  := (config ->> 'coarse')::INTERVAL; END IF;

    IF v_window <= INTERVAL '0 seconds' OR v_window > INTERVAL '35 days'
       OR v_slice <= INTERVAL '0 seconds' OR v_slice > INTERVAL '2 days' THEN
        RAISE EXCEPTION 'energy_register_delta_15min reconcile config: reconcile_window must be in (0, 35 days] and coarse in (0, 2 days] (reconcile_window=%, coarse=%)',
            v_window, v_slice;
    END IF;

    -- Same lock as the forward job: the two never run concurrently.
    IF NOT pg_try_advisory_xact_lock(hashtextextended('analytics.run_energy_register_delta_15min_job', 0)) THEN
        RETURN;
    END IF;

    SELECT last_received_at INTO v_ckpt
    FROM telemetry.pipeline_state
    WHERE pipeline_name = 'energy_register_delta_15min';

    IF v_ckpt IS NULL THEN
        RETURN;
    END IF;

    v_from := date_bin(INTERVAL '15 minutes', v_ckpt - v_window, v_origin);
    WHILE v_from < v_ckpt LOOP
        v_to := LEAST(v_ckpt, date_bin(INTERVAL '15 minutes', v_from + v_slice, v_origin));
        PERFORM analytics.refresh_energy_register_delta_15min(v_from, v_to);
        v_from := v_to;
    END LOOP;
END;
$procedure$;

COMMENT ON PROCEDURE analytics.reconcile_energy_register_delta_15min(INTEGER, JSONB) IS
'Migration 290: daily reconcile for analytics.energy_register_delta_15min. Re-runs analytics.refresh_energy_register_delta_15min over [checkpoint - reconcile_window (3 days), checkpoint) in coarse (1 day) slices, absorbing late source rows; value-aware, so unchanged rows are not rewritten. Shares the forward job''s advisory lock (returns silently when it is held); never moves the checkpoint, never removes rows.';


-- ----------------------------------------------------------------------------
-- 7. pipeline_state row (checkpoint NULL until the forward job first runs).
-- ----------------------------------------------------------------------------
INSERT INTO telemetry.pipeline_state (pipeline_name)
VALUES ('energy_register_delta_15min')
ON CONFLICT (pipeline_name) DO NOTHING;


-- ----------------------------------------------------------------------------
-- 8. Jobs (scheduled).
-- ----------------------------------------------------------------------------
DO $jobs$
DECLARE
    v_origin    CONSTANT TIMESTAMPTZ := TIMESTAMPTZ '2000-01-01 00:00:00+00';
    v_fwd_start TIMESTAMPTZ := date_bin(INTERVAL '5 minutes', now(), v_origin) + INTERVAL '7 minutes';
    v_rec_start TIMESTAMPTZ := date_bin(INTERVAL '1 day', now(), v_origin) + INTERVAL '23 hours';
BEGIN
    IF v_rec_start <= now() THEN
        v_rec_start := v_rec_start + INTERVAL '1 day';
    END IF;

    PERFORM add_job(
        'analytics.run_energy_register_delta_15min_job'::regproc,
        schedule_interval => INTERVAL '5 minutes',
        initial_start     => v_fwd_start,
        config            => jsonb_build_object('max_catchup_window', '1 day', 'overlap', '1 hour'),
        check_config      => 'config.assert_analytical_lookback_job_config'::regproc,
        scheduled         => TRUE,
        fixed_schedule    => FALSE
    );

    PERFORM add_job(
        'analytics.reconcile_energy_register_delta_15min'::regproc,
        schedule_interval => INTERVAL '1 day',
        initial_start     => v_rec_start,
        config            => jsonb_build_object('reconcile_window', '3 days', 'coarse', '1 day'),
        check_config      => 'config.assert_reconciliation_job_config'::regproc,
        scheduled         => TRUE,
        fixed_schedule    => TRUE
    );

    PERFORM alter_job(j.job_id,
                      max_runtime  => INTERVAL '20 minutes',
                      max_retries  => 3,
                      retry_period => INTERVAL '5 minutes')
    FROM timescaledb_information.jobs AS j
    WHERE j.proc_schema = 'analytics'
      AND j.proc_name IN ('run_energy_register_delta_15min_job', 'reconcile_energy_register_delta_15min');
END
$jobs$;


-- ----------------------------------------------------------------------------
-- 9. Grants.
-- ----------------------------------------------------------------------------
REVOKE ALL ON analytics.energy_register_delta_15min FROM PUBLIC;
GRANT SELECT ON analytics.energy_register_delta_15min TO ems_app, ems_readonly;

REVOKE ALL ON FUNCTION analytics.refresh_energy_register_delta_15min(TIMESTAMPTZ, TIMESTAMPTZ) FROM PUBLIC;
REVOKE ALL ON PROCEDURE analytics.run_energy_register_delta_15min_job(INTEGER, JSONB) FROM PUBLIC;
REVOKE ALL ON PROCEDURE analytics.reconcile_energy_register_delta_15min(INTEGER, JSONB) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION analytics.refresh_energy_register_delta_15min(TIMESTAMPTZ, TIMESTAMPTZ) TO ems_admin;
GRANT EXECUTE ON PROCEDURE analytics.run_energy_register_delta_15min_job(INTEGER, JSONB) TO ems_admin;
GRANT EXECUTE ON PROCEDURE analytics.reconcile_energy_register_delta_15min(INTEGER, JSONB) TO ems_admin;


-- ----------------------------------------------------------------------------
-- 10. Postconditions.
-- ----------------------------------------------------------------------------
DO $post$
DECLARE
    v_count INTEGER;
BEGIN
    -- Identity columns NOT NULL; no asset / timezone column.
    SELECT count(*) INTO v_count
    FROM information_schema.columns
    WHERE table_schema = 'analytics' AND table_name = 'energy_register_delta_15min'
      AND column_name IN ('bucket_start', 'organization_id', 'site_id', 'device_id', 'logical_point_id')
      AND is_nullable = 'NO';
    IF v_count <> 5 THEN
        RAISE EXCEPTION 'Migration 290 postcondition failed: identity columns must all be NOT NULL.';
    END IF;

    IF EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema = 'analytics' AND table_name = 'energy_register_delta_15min'
          AND (column_name LIKE '%asset%' OR column_name LIKE '%timezone%' OR column_name LIKE '%local%')
    ) THEN
        RAISE EXCEPTION 'Migration 290 postcondition failed: unexpected asset/timezone/local column.';
    END IF;

    -- Hypertable, 7-day chunks, compression enabled, unique identity index.
    IF NOT EXISTS (
        SELECT 1 FROM timescaledb_information.dimensions
        WHERE hypertable_schema = 'analytics' AND hypertable_name = 'energy_register_delta_15min'
          AND column_name = 'bucket_start' AND time_interval = INTERVAL '7 days'
    ) OR NOT EXISTS (
        SELECT 1 FROM timescaledb_information.hypertables
        WHERE hypertable_schema = 'analytics' AND hypertable_name = 'energy_register_delta_15min'
          AND compression_enabled
    ) OR NOT EXISTS (
        SELECT 1 FROM pg_index AS i JOIN pg_class AS c ON c.oid = i.indexrelid
        WHERE c.relname = 'ux_energy_register_delta_15min_identity' AND i.indisunique
    ) THEN
        RAISE EXCEPTION 'Migration 290 postcondition failed: hypertable / chunk interval / compression / identity index.';
    END IF;

    -- Retention (2 years) and compression (30 days) policies, scheduled.
    SELECT count(*) INTO v_count
    FROM timescaledb_information.jobs
    WHERE hypertable_schema = 'analytics' AND hypertable_name = 'energy_register_delta_15min' AND scheduled
      AND ((proc_name = 'policy_retention' AND config ->> 'drop_after' = '2 years')
        OR (proc_name = 'policy_compression' AND config ->> 'compress_after' = '30 days'));
    IF v_count <> 2 THEN
        RAISE EXCEPTION 'Migration 290 postcondition failed: retention / compression policies.';
    END IF;

    -- Forward and reconcile jobs registered exactly once each, scheduled.
    SELECT count(*) INTO v_count
    FROM timescaledb_information.jobs
    WHERE proc_schema = 'analytics' AND scheduled
      AND proc_name IN ('run_energy_register_delta_15min_job', 'reconcile_energy_register_delta_15min');
    IF v_count <> 2 THEN
        RAISE EXCEPTION 'Migration 290 postcondition failed: expected the forward and reconcile jobs once each, scheduled (found %).', v_count;
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM telemetry.pipeline_state
        WHERE pipeline_name = 'energy_register_delta_15min' AND last_received_at IS NULL
    ) THEN
        RAISE EXCEPTION 'Migration 290 postcondition failed: pipeline_state row missing or checkpoint not NULL.';
    END IF;

    -- Routines: SECURITY DEFINER, owner ems_admin, no PUBLIC / ems_app EXECUTE.
    SELECT count(*) INTO v_count
    FROM pg_proc AS p
    JOIN pg_roles AS r ON r.oid = p.proowner
    WHERE p.oid IN (
        'analytics.refresh_energy_register_delta_15min(timestamptz, timestamptz)'::regprocedure,
        'analytics.run_energy_register_delta_15min_job(integer, jsonb)'::regprocedure,
        'analytics.reconcile_energy_register_delta_15min(integer, jsonb)'::regprocedure)
      AND p.prosecdef
      AND r.rolname = 'ems_admin'
      AND NOT has_function_privilege('public', p.oid, 'EXECUTE')
      AND NOT has_function_privilege('ems_app', p.oid, 'EXECUTE');
    IF v_count <> 3 THEN
        RAISE EXCEPTION 'Migration 290 postcondition failed: routine security / ownership / grants.';
    END IF;

    IF NOT has_table_privilege('ems_app', 'analytics.energy_register_delta_15min', 'SELECT')
       OR has_table_privilege('ems_app', 'analytics.energy_register_delta_15min', 'INSERT') THEN
        RAISE EXCEPTION 'Migration 290 postcondition failed: table grants.';
    END IF;

    RAISE NOTICE 'Migration 290: all postconditions passed (energy_register_delta_15min tier, refresh, forward and reconcile jobs scheduled; no read path).';
END
$post$;
