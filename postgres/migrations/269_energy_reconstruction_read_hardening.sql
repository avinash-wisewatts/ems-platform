-- ============================================================================
-- Migration 269
-- Late/recovered Energy reconstruction -- READ-SIDE HARDENING (ADR-020, PR2).
--
-- Makes every Energy read layer distinguish reconstructed-timing energy from
-- directly measured energy BEFORE anything can write reconstructed rows
-- (ADR-020 PR3). Migration 268's switch stays OFF and no reconstructed row
-- exists, so every pre-existing output is unchanged (proved by the golden
-- tests in app/tests/test_energy_reconstruction_read_hardening.py, which
-- recreate the exact pre-269 chain and compare).
--
-- Contract established here (PR3 must produce rows that follow it):
--
--   * A native row is a MEASURED interval unless it is reconstructed AND has
--     no source sample:
--         is_measured_interval = NOT is_reconstructed
--                                OR COALESCE(source_sample_count, 0) > 0
--     A SYNTHETIC row (reconstructed, 0 samples) exists only to carry
--     reconstructed energy for a gap slot with no measurement.
--   * Per direction, a row whose <dir>_reconstruction_role = 'INTERIOR'
--     carries no measured interval for that direction (its register is not
--     a measurement of that slot). GAP_END rows are measured intervals whose
--     consumption share is reconstructed; they keep quality_code 'GAP'.
--   * Measured coverage and counters -- source_interval_count, valid_* /
--     invalid_* intervals, gap/reset/rollover/invalid counts, register
--     first/last, quality-code arrays, first/last native bucket -- come from
--     measured rows (and non-interior directions) only.
--   * Energy totals (import/export_consumption_*) still sum every valid row,
--     so they INCLUDE reconstructed energy (ADR-020 rule 1).
--   * New counters: reconstructed_interval_count, <dir>_reconstructed_
--     intervals, <dir>_reconstructed_wh/_kwh (the part of the total whose
--     timing was reconstructed).
--   * Status: a bucket with reconstructed intervals and no higher-priority
--     condition reports RECONSTRUCTED_TIMING -- never GOOD. Priority:
--     INVALID_INTERVALS > RESET_DETECTED > GAPS_DETECTED >
--     RECONSTRUCTED_TIMING > ROLLOVER_DETECTED > GOOD. Internal code only;
--     customer wording is ADR-020 PR4.
--
-- Changed objects (all CREATE OR REPLACE; signatures, return types, column
-- order, security_barrier options and privileges preserved; new view
-- columns appended at the end):
--   views     analytics.v_energy_consumption_native,
--             v_energy_semantic_rollup_5min / _15min,
--             v_energy_reporting_5min / _15min / _hourly / _daily,
--             v_energy_consumption_daily, v_asset_consumption_daily,
--             v_asset_hierarchy_rollup_daily
--   tables    analytics.energy_consumption_15min / _hourly / _daily
--             (+ 5 NOT NULL DEFAULT 0 counter columns each)
--   functions analytics.refresh_energy_consumption_15min / _hourly / _daily,
--             analytics.reconcile_energy_deficits (15-minute branch only),
--             analytics.get_canonical_energy_read
--
-- Unchanged (correct by construction -- they read the corrected persisted
-- counters or only totals): the portal site Energy read functions, alert
-- materiality, the 1min/5min refresh functions and every job.
--
-- NOTE for the uncommitted ADR-018 migration 263 (asset_points attribution
-- of get_canonical_energy_read): it was written against the pre-269 body.
-- It must be rebased onto this version before it lands, or it would silently
-- drop the RECONSTRUCTED_TIMING handling. The tripwire test
-- test_canonical_read_handles_reconstruction_in_every_tier fails if that
-- happens.
--
-- Rollback (not run here): re-create the pre-269 definitions (see
-- app/tests/fixtures/energy_269_baseline.sql) and drop the 5 persisted
-- counter columns from the three tiers.
-- ============================================================================


-- ----------------------------------------------------------------------------
-- 0. Snapshot view options/privileges so the postconditions can prove that
--    CREATE OR REPLACE VIEW preserved them.
-- ----------------------------------------------------------------------------
CREATE TEMP TABLE migration_269_view_state ON COMMIT DROP AS
SELECT c.oid::regclass::text AS view_name, c.reloptions, c.relacl
FROM pg_class c
WHERE c.oid::regclass::text = ANY (ARRAY[
    'analytics.v_energy_consumption_native',
    'analytics.v_energy_semantic_rollup_5min',
    'analytics.v_energy_semantic_rollup_15min',
    'analytics.v_energy_reporting_5min',
    'analytics.v_energy_reporting_15min',
    'analytics.v_energy_reporting_hourly',
    'analytics.v_energy_reporting_daily',
    'analytics.v_energy_consumption_daily',
    'analytics.v_asset_consumption_daily',
    'analytics.v_asset_hierarchy_rollup_daily'
]);


-- ----------------------------------------------------------------------------
-- 1. Persisted tiers: additive reconstruction counters (defaults 0).
-- ----------------------------------------------------------------------------
DO $cols$
DECLARE
    v_table TEXT;
BEGIN
    FOREACH v_table IN ARRAY ARRAY['energy_consumption_15min', 'energy_consumption_hourly', 'energy_consumption_daily']
    LOOP
        EXECUTE format($sql$
            ALTER TABLE analytics.%1$I
                ADD COLUMN IF NOT EXISTS reconstructed_interval_count   BIGINT  NOT NULL DEFAULT 0,
                ADD COLUMN IF NOT EXISTS import_reconstructed_intervals BIGINT  NOT NULL DEFAULT 0,
                ADD COLUMN IF NOT EXISTS export_reconstructed_intervals BIGINT  NOT NULL DEFAULT 0,
                ADD COLUMN IF NOT EXISTS import_reconstructed_kwh       NUMERIC NOT NULL DEFAULT 0,
                ADD COLUMN IF NOT EXISTS export_reconstructed_kwh       NUMERIC NOT NULL DEFAULT 0
        $sql$, v_table);
        EXECUTE format($sql$
            COMMENT ON COLUMN analytics.%1$I.reconstructed_interval_count IS
            'ADR-020 (migration 269): native intervals in this bucket that carry reconstructed-timing energy (is_reconstructed). Never counted in source_interval_count / valid_* / invalid_* (measured coverage). 0 until ADR-020 PR3 writes reconstructed rows.'
        $sql$, v_table);
        EXECUTE format($sql$
            COMMENT ON COLUMN analytics.%1$I.import_reconstructed_kwh IS
            'ADR-020 (migration 269): the part of import_consumption_kwh whose timing was reconstructed (measured register total, distributed across a gap). Already included in import_consumption_kwh.'
        $sql$, v_table);
    END LOOP;
END;
$cols$;


-- ----------------------------------------------------------------------------
-- 2. Native view: measured-interval flag, reconstruction columns, and an
--    invalid_detected that never counts a reconstructed-only interval.
--    For every row with is_reconstructed = FALSE every pre-existing column
--    is unchanged.
-- ----------------------------------------------------------------------------

CREATE OR REPLACE VIEW analytics.v_energy_consumption_native AS
 SELECT energy_consumption_1min.bucket_start,
    energy_consumption_1min.organization_id,
    energy_consumption_1min.site_id,
    energy_consumption_1min.device_id,
    60 AS native_resolution_seconds,
    energy_consumption_1min.previous_bucket_start,
    energy_consumption_1min.elapsed_minutes,
    energy_consumption_1min.source_sample_count,
    energy_consumption_1min.import_register_wh,
    energy_consumption_1min.previous_import_register_wh,
    energy_consumption_1min.import_consumption_wh,
    energy_consumption_1min.import_consumption_kwh,
    energy_consumption_1min.import_quality_code,
    energy_consumption_1min.import_is_valid,
    energy_consumption_1min.import_reset_detected,
    energy_consumption_1min.import_rollover_detected,
    energy_consumption_1min.export_register_wh,
    energy_consumption_1min.previous_export_register_wh,
    energy_consumption_1min.export_consumption_wh,
    energy_consumption_1min.export_consumption_kwh,
    energy_consumption_1min.export_quality_code,
    energy_consumption_1min.export_is_valid,
    energy_consumption_1min.export_reset_detected,
    energy_consumption_1min.export_rollover_detected,
    energy_consumption_1min.gap_detected,
    COALESCE(energy_consumption_1min.import_reset_detected, false) OR COALESCE(energy_consumption_1min.export_reset_detected, false) AS reset_detected,
    COALESCE(energy_consumption_1min.import_rollover_detected, false) OR COALESCE(energy_consumption_1min.export_rollover_detected, false) AS rollover_detected,
    (NOT energy_consumption_1min.is_reconstructed OR COALESCE(energy_consumption_1min.source_sample_count, 0::bigint) > 0) AND (
        energy_consumption_1min.import_is_valid IS NOT TRUE AND energy_consumption_1min.import_reconstruction_role IS DISTINCT FROM 'INTERIOR'::text
        OR energy_consumption_1min.export_is_valid IS NOT TRUE AND energy_consumption_1min.export_reconstruction_role IS DISTINCT FROM 'INTERIOR'::text
    ) AS invalid_detected,
    energy_consumption_1min.is_reconstructed,
    energy_consumption_1min.import_reconstruction_role,
    energy_consumption_1min.import_reconstruction_method,
    energy_consumption_1min.import_gap_start,
    energy_consumption_1min.import_gap_end,
    energy_consumption_1min.import_gap_delta_wh,
    energy_consumption_1min.export_reconstruction_role,
    energy_consumption_1min.export_reconstruction_method,
    energy_consumption_1min.export_gap_start,
    energy_consumption_1min.export_gap_end,
    energy_consumption_1min.export_gap_delta_wh,
    (NOT energy_consumption_1min.is_reconstructed OR COALESCE(energy_consumption_1min.source_sample_count, 0::bigint) > 0) AS is_measured_interval,
    energy_consumption_1min.import_reconstruction_role IS NOT DISTINCT FROM 'INTERIOR'::text AS import_is_interior,
    energy_consumption_1min.export_reconstruction_role IS NOT DISTINCT FROM 'INTERIOR'::text AS export_is_interior
   FROM analytics.energy_consumption_1min
UNION ALL
 SELECT energy_consumption_5min.bucket_start,
    energy_consumption_5min.organization_id,
    energy_consumption_5min.site_id,
    energy_consumption_5min.device_id,
    300 AS native_resolution_seconds,
    energy_consumption_5min.previous_bucket_start,
    energy_consumption_5min.elapsed_minutes,
    energy_consumption_5min.source_sample_count,
    energy_consumption_5min.import_register_wh,
    energy_consumption_5min.previous_import_register_wh,
    energy_consumption_5min.import_consumption_wh,
    energy_consumption_5min.import_consumption_kwh,
    energy_consumption_5min.import_quality_code,
    energy_consumption_5min.import_is_valid,
    energy_consumption_5min.import_reset_detected,
    energy_consumption_5min.import_rollover_detected,
    energy_consumption_5min.export_register_wh,
    energy_consumption_5min.previous_export_register_wh,
    energy_consumption_5min.export_consumption_wh,
    energy_consumption_5min.export_consumption_kwh,
    energy_consumption_5min.export_quality_code,
    energy_consumption_5min.export_is_valid,
    energy_consumption_5min.export_reset_detected,
    energy_consumption_5min.export_rollover_detected,
    energy_consumption_5min.gap_detected,
    COALESCE(energy_consumption_5min.import_reset_detected, false) OR COALESCE(energy_consumption_5min.export_reset_detected, false) AS reset_detected,
    COALESCE(energy_consumption_5min.import_rollover_detected, false) OR COALESCE(energy_consumption_5min.export_rollover_detected, false) AS rollover_detected,
    (NOT energy_consumption_5min.is_reconstructed OR COALESCE(energy_consumption_5min.source_sample_count, 0::bigint) > 0) AND (
        energy_consumption_5min.import_is_valid IS NOT TRUE AND energy_consumption_5min.import_reconstruction_role IS DISTINCT FROM 'INTERIOR'::text
        OR energy_consumption_5min.export_is_valid IS NOT TRUE AND energy_consumption_5min.export_reconstruction_role IS DISTINCT FROM 'INTERIOR'::text
    ) AS invalid_detected,
    energy_consumption_5min.is_reconstructed,
    energy_consumption_5min.import_reconstruction_role,
    energy_consumption_5min.import_reconstruction_method,
    energy_consumption_5min.import_gap_start,
    energy_consumption_5min.import_gap_end,
    energy_consumption_5min.import_gap_delta_wh,
    energy_consumption_5min.export_reconstruction_role,
    energy_consumption_5min.export_reconstruction_method,
    energy_consumption_5min.export_gap_start,
    energy_consumption_5min.export_gap_end,
    energy_consumption_5min.export_gap_delta_wh,
    (NOT energy_consumption_5min.is_reconstructed OR COALESCE(energy_consumption_5min.source_sample_count, 0::bigint) > 0) AS is_measured_interval,
    energy_consumption_5min.import_reconstruction_role IS NOT DISTINCT FROM 'INTERIOR'::text AS import_is_interior,
    energy_consumption_5min.export_reconstruction_role IS NOT DISTINCT FROM 'INTERIOR'::text AS export_is_interior
   FROM analytics.energy_consumption_5min;


-- ----------------------------------------------------------------------------
-- 3. Semantic rollups: measured counters/registers/codes/buckets from
--    measured rows only; totals include reconstructed energy; new
--    reconstructed counters; distinct RECONSTRUCTED_TIMING status.
-- ----------------------------------------------------------------------------

CREATE OR REPLACE VIEW analytics.v_energy_semantic_rollup_5min AS
 WITH grouped AS (
         SELECT date_bin('00:05:00'::interval, n.bucket_start, '2000-01-01 05:30:00+05:30'::timestamp with time zone) AS bucket_start,
            n.organization_id,
            n.site_id,
            n.device_id,
            count(*) FILTER (WHERE n.is_measured_interval) AS source_interval_count,
            sum(n.source_sample_count) AS source_sample_count,
            count(*) FILTER (WHERE n.import_is_valid AND n.is_measured_interval AND NOT n.import_is_interior) AS valid_import_intervals,
            count(*) FILTER (WHERE NOT n.import_is_valid AND n.is_measured_interval AND NOT n.import_is_interior) AS invalid_import_intervals,
            count(*) FILTER (WHERE n.export_is_valid AND n.is_measured_interval AND NOT n.export_is_interior) AS valid_export_intervals,
            count(*) FILTER (WHERE NOT n.export_is_valid AND n.is_measured_interval AND NOT n.export_is_interior) AS invalid_export_intervals,
            count(*) FILTER (WHERE n.import_quality_code = 'GAP'::text AND n.is_measured_interval) AS import_gap_intervals,
            count(*) FILTER (WHERE n.export_quality_code = 'GAP'::text AND n.is_measured_interval) AS export_gap_intervals,
            count(*) FILTER (WHERE n.import_reset_detected AND n.is_measured_interval) AS import_reset_intervals,
            count(*) FILTER (WHERE n.export_reset_detected AND n.is_measured_interval) AS export_reset_intervals,
            count(*) FILTER (WHERE n.import_rollover_detected AND n.is_measured_interval) AS import_rollover_intervals,
            count(*) FILTER (WHERE n.export_rollover_detected AND n.is_measured_interval) AS export_rollover_intervals,
            sum(n.import_consumption_wh) FILTER (WHERE n.import_is_valid) AS import_consumption_wh,
            sum(n.import_consumption_kwh) FILTER (WHERE n.import_is_valid) AS import_consumption_kwh,
            sum(n.export_consumption_wh) FILTER (WHERE n.export_is_valid) AS export_consumption_wh,
            sum(n.export_consumption_kwh) FILTER (WHERE n.export_is_valid) AS export_consumption_kwh,
            min(n.bucket_start) FILTER (WHERE n.is_measured_interval) AS first_native_bucket_start,
            max(n.bucket_start) FILTER (WHERE n.is_measured_interval) AS last_native_bucket_start,
            (array_agg(n.previous_bucket_start ORDER BY n.bucket_start) FILTER (WHERE n.is_measured_interval))[1] AS first_previous_bucket_start,
            (array_agg(n.previous_import_register_wh ORDER BY n.bucket_start) FILTER (WHERE n.is_measured_interval))[1] AS previous_import_register_wh,
            (array_agg(n.import_register_wh ORDER BY n.bucket_start DESC) FILTER (WHERE n.is_measured_interval))[1] AS import_register_wh,
            (array_agg(n.previous_export_register_wh ORDER BY n.bucket_start) FILTER (WHERE n.is_measured_interval))[1] AS previous_export_register_wh,
            (array_agg(n.export_register_wh ORDER BY n.bucket_start DESC) FILTER (WHERE n.is_measured_interval))[1] AS export_register_wh,
            array_agg(DISTINCT n.import_quality_code ORDER BY n.import_quality_code) FILTER (WHERE n.is_measured_interval) AS import_quality_codes,
            array_agg(DISTINCT n.export_quality_code ORDER BY n.export_quality_code) FILTER (WHERE n.is_measured_interval) AS export_quality_codes,
            min(n.native_resolution_seconds) AS minimum_native_resolution_seconds,
            max(n.native_resolution_seconds) AS maximum_native_resolution_seconds,
            count(*) FILTER (WHERE n.gap_detected AND n.is_measured_interval) AS gap_interval_count,
            count(*) FILTER (WHERE n.reset_detected AND n.is_measured_interval) AS reset_interval_count,
            count(*) FILTER (WHERE n.rollover_detected AND n.is_measured_interval) AS rollover_interval_count,
            count(*) FILTER (WHERE n.invalid_detected AND n.is_measured_interval) AS invalid_interval_count,
            count(*) FILTER (WHERE n.is_reconstructed) AS reconstructed_interval_count,
            count(*) FILTER (WHERE n.import_reconstruction_role IS NOT NULL) AS import_reconstructed_intervals,
            count(*) FILTER (WHERE n.export_reconstruction_role IS NOT NULL) AS export_reconstructed_intervals,
            COALESCE(sum(n.import_consumption_wh) FILTER (WHERE n.import_is_valid AND n.import_reconstruction_role IS NOT NULL), 0::numeric) AS import_reconstructed_wh,
            COALESCE(sum(n.import_consumption_kwh) FILTER (WHERE n.import_is_valid AND n.import_reconstruction_role IS NOT NULL), 0::numeric) AS import_reconstructed_kwh,
            COALESCE(sum(n.export_consumption_wh) FILTER (WHERE n.export_is_valid AND n.export_reconstruction_role IS NOT NULL), 0::numeric) AS export_reconstructed_wh,
            COALESCE(sum(n.export_consumption_kwh) FILTER (WHERE n.export_is_valid AND n.export_reconstruction_role IS NOT NULL), 0::numeric) AS export_reconstructed_kwh
           FROM analytics.v_energy_consumption_native n
          GROUP BY (date_bin('00:05:00'::interval, n.bucket_start, '2000-01-01 05:30:00+05:30'::timestamp with time zone)), n.organization_id, n.site_id, n.device_id
        )
 SELECT bucket_start,
    organization_id,
    site_id,
    device_id,
    source_interval_count,
    source_sample_count,
    valid_import_intervals,
    invalid_import_intervals,
    valid_export_intervals,
    invalid_export_intervals,
    import_gap_intervals,
    export_gap_intervals,
    import_reset_intervals,
    export_reset_intervals,
    import_rollover_intervals,
    export_rollover_intervals,
    import_consumption_wh,
    import_consumption_kwh,
    export_consumption_wh,
    export_consumption_kwh,
    first_native_bucket_start,
    last_native_bucket_start,
    first_previous_bucket_start,
    previous_import_register_wh,
    import_register_wh,
    previous_export_register_wh,
    export_register_wh,
    import_quality_codes,
    export_quality_codes,
    minimum_native_resolution_seconds,
    maximum_native_resolution_seconds,
        CASE
            WHEN invalid_interval_count > 0 THEN 'INVALID_INTERVALS'::text
            WHEN reset_interval_count > 0 THEN 'RESET_DETECTED'::text
            WHEN gap_interval_count > 0 THEN 'GAPS_DETECTED'::text
            WHEN reconstructed_interval_count > 0 THEN 'RECONSTRUCTED_TIMING'::text
            WHEN rollover_interval_count > 0 THEN 'ROLLOVER_DETECTED'::text
            ELSE 'GOOD'::text
        END AS quality_status,
    gap_interval_count,
    reset_interval_count,
    rollover_interval_count,
    invalid_interval_count,
    reconstructed_interval_count,
    import_reconstructed_intervals,
    export_reconstructed_intervals,
    import_reconstructed_wh,
    import_reconstructed_kwh,
    export_reconstructed_wh,
    export_reconstructed_kwh
   FROM grouped g;

CREATE OR REPLACE VIEW analytics.v_energy_semantic_rollup_15min AS
 WITH grouped AS (
         SELECT date_bin('00:15:00'::interval, n.bucket_start, '2000-01-01 05:30:00+05:30'::timestamp with time zone) AS bucket_start,
            n.organization_id,
            n.site_id,
            n.device_id,
            count(*) FILTER (WHERE n.is_measured_interval) AS source_interval_count,
            sum(n.source_sample_count) AS source_sample_count,
            count(*) FILTER (WHERE n.import_is_valid AND n.is_measured_interval AND NOT n.import_is_interior) AS valid_import_intervals,
            count(*) FILTER (WHERE NOT n.import_is_valid AND n.is_measured_interval AND NOT n.import_is_interior) AS invalid_import_intervals,
            count(*) FILTER (WHERE n.export_is_valid AND n.is_measured_interval AND NOT n.export_is_interior) AS valid_export_intervals,
            count(*) FILTER (WHERE NOT n.export_is_valid AND n.is_measured_interval AND NOT n.export_is_interior) AS invalid_export_intervals,
            count(*) FILTER (WHERE n.import_quality_code = 'GAP'::text AND n.is_measured_interval) AS import_gap_intervals,
            count(*) FILTER (WHERE n.export_quality_code = 'GAP'::text AND n.is_measured_interval) AS export_gap_intervals,
            count(*) FILTER (WHERE n.import_reset_detected AND n.is_measured_interval) AS import_reset_intervals,
            count(*) FILTER (WHERE n.export_reset_detected AND n.is_measured_interval) AS export_reset_intervals,
            count(*) FILTER (WHERE n.import_rollover_detected AND n.is_measured_interval) AS import_rollover_intervals,
            count(*) FILTER (WHERE n.export_rollover_detected AND n.is_measured_interval) AS export_rollover_intervals,
            sum(n.import_consumption_wh) FILTER (WHERE n.import_is_valid) AS import_consumption_wh,
            sum(n.import_consumption_kwh) FILTER (WHERE n.import_is_valid) AS import_consumption_kwh,
            sum(n.export_consumption_wh) FILTER (WHERE n.export_is_valid) AS export_consumption_wh,
            sum(n.export_consumption_kwh) FILTER (WHERE n.export_is_valid) AS export_consumption_kwh,
            min(n.bucket_start) FILTER (WHERE n.is_measured_interval) AS first_native_bucket_start,
            max(n.bucket_start) FILTER (WHERE n.is_measured_interval) AS last_native_bucket_start,
            (array_agg(n.previous_bucket_start ORDER BY n.bucket_start) FILTER (WHERE n.is_measured_interval))[1] AS first_previous_bucket_start,
            (array_agg(n.previous_import_register_wh ORDER BY n.bucket_start) FILTER (WHERE n.is_measured_interval))[1] AS previous_import_register_wh,
            (array_agg(n.import_register_wh ORDER BY n.bucket_start DESC) FILTER (WHERE n.is_measured_interval))[1] AS import_register_wh,
            (array_agg(n.previous_export_register_wh ORDER BY n.bucket_start) FILTER (WHERE n.is_measured_interval))[1] AS previous_export_register_wh,
            (array_agg(n.export_register_wh ORDER BY n.bucket_start DESC) FILTER (WHERE n.is_measured_interval))[1] AS export_register_wh,
            array_agg(DISTINCT n.import_quality_code ORDER BY n.import_quality_code) FILTER (WHERE n.is_measured_interval) AS import_quality_codes,
            array_agg(DISTINCT n.export_quality_code ORDER BY n.export_quality_code) FILTER (WHERE n.is_measured_interval) AS export_quality_codes,
            min(n.native_resolution_seconds) AS minimum_native_resolution_seconds,
            max(n.native_resolution_seconds) AS maximum_native_resolution_seconds,
            count(*) FILTER (WHERE n.gap_detected AND n.is_measured_interval) AS gap_interval_count,
            count(*) FILTER (WHERE n.reset_detected AND n.is_measured_interval) AS reset_interval_count,
            count(*) FILTER (WHERE n.rollover_detected AND n.is_measured_interval) AS rollover_interval_count,
            count(*) FILTER (WHERE n.invalid_detected AND n.is_measured_interval) AS invalid_interval_count,
            count(*) FILTER (WHERE n.is_reconstructed) AS reconstructed_interval_count,
            count(*) FILTER (WHERE n.import_reconstruction_role IS NOT NULL) AS import_reconstructed_intervals,
            count(*) FILTER (WHERE n.export_reconstruction_role IS NOT NULL) AS export_reconstructed_intervals,
            COALESCE(sum(n.import_consumption_wh) FILTER (WHERE n.import_is_valid AND n.import_reconstruction_role IS NOT NULL), 0::numeric) AS import_reconstructed_wh,
            COALESCE(sum(n.import_consumption_kwh) FILTER (WHERE n.import_is_valid AND n.import_reconstruction_role IS NOT NULL), 0::numeric) AS import_reconstructed_kwh,
            COALESCE(sum(n.export_consumption_wh) FILTER (WHERE n.export_is_valid AND n.export_reconstruction_role IS NOT NULL), 0::numeric) AS export_reconstructed_wh,
            COALESCE(sum(n.export_consumption_kwh) FILTER (WHERE n.export_is_valid AND n.export_reconstruction_role IS NOT NULL), 0::numeric) AS export_reconstructed_kwh
           FROM analytics.v_energy_consumption_native n
          GROUP BY (date_bin('00:15:00'::interval, n.bucket_start, '2000-01-01 05:30:00+05:30'::timestamp with time zone)), n.organization_id, n.site_id, n.device_id
        )
 SELECT bucket_start,
    organization_id,
    site_id,
    device_id,
    source_interval_count,
    source_sample_count,
    valid_import_intervals,
    invalid_import_intervals,
    valid_export_intervals,
    invalid_export_intervals,
    import_gap_intervals,
    export_gap_intervals,
    import_reset_intervals,
    export_reset_intervals,
    import_rollover_intervals,
    export_rollover_intervals,
    import_consumption_wh,
    import_consumption_kwh,
    export_consumption_wh,
    export_consumption_kwh,
    first_native_bucket_start,
    last_native_bucket_start,
    first_previous_bucket_start,
    previous_import_register_wh,
    import_register_wh,
    previous_export_register_wh,
    export_register_wh,
    import_quality_codes,
    export_quality_codes,
    minimum_native_resolution_seconds,
    maximum_native_resolution_seconds,
        CASE
            WHEN invalid_interval_count > 0 THEN 'INVALID_INTERVALS'::text
            WHEN reset_interval_count > 0 THEN 'RESET_DETECTED'::text
            WHEN gap_interval_count > 0 THEN 'GAPS_DETECTED'::text
            WHEN reconstructed_interval_count > 0 THEN 'RECONSTRUCTED_TIMING'::text
            WHEN rollover_interval_count > 0 THEN 'ROLLOVER_DETECTED'::text
            ELSE 'GOOD'::text
        END AS quality_status,
    gap_interval_count,
    reset_interval_count,
    rollover_interval_count,
    invalid_interval_count,
    reconstructed_interval_count,
    import_reconstructed_intervals,
    export_reconstructed_intervals,
    import_reconstructed_wh,
    import_reconstructed_kwh,
    export_reconstructed_wh,
    export_reconstructed_kwh
   FROM grouped g;


-- ----------------------------------------------------------------------------
-- 4. Reporting views (tenant-scoped, security_barrier preserved).
-- ----------------------------------------------------------------------------

CREATE OR REPLACE VIEW analytics.v_energy_reporting_5min WITH (security_barrier = true) AS
 SELECT gom.grafana_org_id,
    r.organization_id,
    r.site_id,
    r.device_id,
    d.external_id,
    d.name AS device_name,
    r.bucket_start,
    r.source_interval_count,
    r.source_sample_count,
    r.valid_import_intervals,
    r.invalid_import_intervals,
    r.valid_export_intervals,
    r.invalid_export_intervals,
    r.import_gap_intervals,
    r.export_gap_intervals,
    r.import_reset_intervals,
    r.export_reset_intervals,
    r.import_rollover_intervals,
    r.export_rollover_intervals,
    r.import_consumption_wh,
    r.import_consumption_kwh,
    r.export_consumption_wh,
    r.export_consumption_kwh,
    r.first_native_bucket_start,
    r.last_native_bucket_start,
    r.first_previous_bucket_start,
    r.previous_import_register_wh,
    r.import_register_wh,
    r.previous_export_register_wh,
    r.export_register_wh,
    r.import_quality_codes,
    r.export_quality_codes,
    r.minimum_native_resolution_seconds,
    r.maximum_native_resolution_seconds,
    r.quality_status,
    r.gap_interval_count,
    r.reset_interval_count,
    r.rollover_interval_count,
    r.invalid_interval_count,
    r.reconstructed_interval_count,
    r.import_reconstructed_intervals,
    r.export_reconstructed_intervals,
    r.import_reconstructed_wh,
    r.import_reconstructed_kwh,
    r.export_reconstructed_wh,
    r.export_reconstructed_kwh
   FROM analytics.v_energy_semantic_rollup_5min r
     JOIN metadata.devices d ON d.id = r.device_id AND d.organization_id = r.organization_id
     JOIN metadata.grafana_organization_map gom ON gom.organization_id = r.organization_id AND gom.is_active = true;

CREATE OR REPLACE VIEW analytics.v_energy_reporting_15min WITH (security_barrier = true) AS
 SELECT gom.grafana_org_id,
    r.organization_id,
    r.site_id,
    r.device_id,
    d.external_id,
    d.name AS device_name,
    r.bucket_start,
    r.source_interval_count,
    r.source_sample_count,
    r.valid_import_intervals,
    r.invalid_import_intervals,
    r.valid_export_intervals,
    r.invalid_export_intervals,
    r.import_gap_intervals,
    r.export_gap_intervals,
    r.import_reset_intervals,
    r.export_reset_intervals,
    r.import_rollover_intervals,
    r.export_rollover_intervals,
    r.import_consumption_wh,
    r.import_consumption_kwh,
    r.export_consumption_wh,
    r.export_consumption_kwh,
    r.first_native_bucket_start,
    r.last_native_bucket_start,
    r.first_previous_bucket_start,
    r.previous_import_register_wh,
    r.import_register_wh,
    r.previous_export_register_wh,
    r.export_register_wh,
    r.import_quality_codes,
    r.export_quality_codes,
    r.minimum_native_resolution_seconds,
    r.maximum_native_resolution_seconds,
    r.quality_status,
    r.gap_interval_count,
    r.reset_interval_count,
    r.rollover_interval_count,
    r.invalid_interval_count,
    r.reconstructed_interval_count,
    r.import_reconstructed_intervals,
    r.export_reconstructed_intervals,
    r.import_reconstructed_wh,
    r.import_reconstructed_kwh,
    r.export_reconstructed_wh,
    r.export_reconstructed_kwh
   FROM analytics.v_energy_semantic_rollup_15min r
     JOIN metadata.devices d ON d.id = r.device_id AND d.organization_id = r.organization_id
     JOIN metadata.grafana_organization_map gom ON gom.organization_id = r.organization_id AND gom.is_active = true;

CREATE OR REPLACE VIEW analytics.v_energy_reporting_hourly WITH (security_barrier = true) AS
 WITH hourly AS (
         SELECT r.grafana_org_id,
            r.organization_id,
            r.site_id,
            r.device_id,
            r.external_id,
            r.device_name,
            s.timezone AS site_timezone,
            (date_trunc('hour'::text, (r.bucket_start AT TIME ZONE s.timezone)) AT TIME ZONE s.timezone) AS bucket_start,
            sum(r.source_interval_count) AS source_interval_count,
            sum(r.source_sample_count) AS source_sample_count,
            sum(r.valid_import_intervals) AS valid_import_intervals,
            sum(r.invalid_import_intervals) AS invalid_import_intervals,
            sum(r.valid_export_intervals) AS valid_export_intervals,
            sum(r.invalid_export_intervals) AS invalid_export_intervals,
            sum(r.import_gap_intervals) AS import_gap_intervals,
            sum(r.export_gap_intervals) AS export_gap_intervals,
            sum(r.import_reset_intervals) AS import_reset_intervals,
            sum(r.export_reset_intervals) AS export_reset_intervals,
            sum(r.import_rollover_intervals) AS import_rollover_intervals,
            sum(r.export_rollover_intervals) AS export_rollover_intervals,
            sum(r.import_consumption_wh) AS import_consumption_wh,
            sum(r.import_consumption_kwh) AS import_consumption_kwh,
            sum(r.export_consumption_wh) AS export_consumption_wh,
            sum(r.export_consumption_kwh) AS export_consumption_kwh,
            min(r.first_native_bucket_start) AS first_native_bucket_start,
            max(r.last_native_bucket_start) AS last_native_bucket_start,
            min(r.minimum_native_resolution_seconds) AS minimum_native_resolution_seconds,
            max(r.maximum_native_resolution_seconds) AS maximum_native_resolution_seconds,
            sum(r.gap_interval_count) AS gap_interval_count,
            sum(r.reset_interval_count) AS reset_interval_count,
            sum(r.rollover_interval_count) AS rollover_interval_count,
            sum(r.invalid_interval_count) AS invalid_interval_count,
            sum(r.reconstructed_interval_count) AS reconstructed_interval_count,
            sum(r.import_reconstructed_intervals) AS import_reconstructed_intervals,
            sum(r.export_reconstructed_intervals) AS export_reconstructed_intervals,
            sum(r.import_reconstructed_wh) AS import_reconstructed_wh,
            sum(r.import_reconstructed_kwh) AS import_reconstructed_kwh,
            sum(r.export_reconstructed_wh) AS export_reconstructed_wh,
            sum(r.export_reconstructed_kwh) AS export_reconstructed_kwh
           FROM analytics.v_energy_reporting_15min r
             JOIN metadata.sites s ON s.id = r.site_id AND s.organization_id = r.organization_id
          GROUP BY r.grafana_org_id, r.organization_id, r.site_id, r.device_id, r.external_id, r.device_name, s.timezone, ((date_trunc('hour'::text, (r.bucket_start AT TIME ZONE s.timezone)) AT TIME ZONE s.timezone))
        )
 SELECT grafana_org_id,
    organization_id,
    site_id,
    device_id,
    external_id,
    device_name,
    site_timezone,
    bucket_start,
    source_interval_count,
    source_sample_count,
    valid_import_intervals,
    invalid_import_intervals,
    valid_export_intervals,
    invalid_export_intervals,
    import_gap_intervals,
    export_gap_intervals,
    import_reset_intervals,
    export_reset_intervals,
    import_rollover_intervals,
    export_rollover_intervals,
    import_consumption_wh,
    import_consumption_kwh,
    export_consumption_wh,
    export_consumption_kwh,
    first_native_bucket_start,
    last_native_bucket_start,
    minimum_native_resolution_seconds,
    maximum_native_resolution_seconds,
        CASE
            WHEN invalid_interval_count > 0::numeric THEN 'INVALID_INTERVALS'::text
            WHEN reset_interval_count > 0::numeric THEN 'RESET_DETECTED'::text
            WHEN gap_interval_count > 0::numeric THEN 'GAPS_DETECTED'::text
            WHEN reconstructed_interval_count > 0::numeric THEN 'RECONSTRUCTED_TIMING'::text
            WHEN rollover_interval_count > 0::numeric THEN 'ROLLOVER_DETECTED'::text
            ELSE 'GOOD'::text
        END AS quality_status,
    gap_interval_count,
    reset_interval_count,
    rollover_interval_count,
    invalid_interval_count,
    reconstructed_interval_count,
    import_reconstructed_intervals,
    export_reconstructed_intervals,
    import_reconstructed_wh,
    import_reconstructed_kwh,
    export_reconstructed_wh,
    export_reconstructed_kwh
   FROM hourly h;

CREATE OR REPLACE VIEW analytics.v_energy_reporting_daily WITH (security_barrier = true) AS
 WITH daily AS (
         SELECT r.grafana_org_id,
            r.organization_id,
            r.site_id,
            r.device_id,
            r.external_id,
            r.device_name,
            s.timezone AS site_timezone,
            (r.bucket_start AT TIME ZONE s.timezone)::date AS consumption_date,
            sum(r.source_interval_count) AS source_interval_count,
            sum(r.source_sample_count) AS source_sample_count,
            sum(r.valid_import_intervals) AS valid_import_intervals,
            sum(r.invalid_import_intervals) AS invalid_import_intervals,
            sum(r.valid_export_intervals) AS valid_export_intervals,
            sum(r.invalid_export_intervals) AS invalid_export_intervals,
            sum(r.import_gap_intervals) AS import_gap_intervals,
            sum(r.export_gap_intervals) AS export_gap_intervals,
            sum(r.import_reset_intervals) AS import_reset_intervals,
            sum(r.export_reset_intervals) AS export_reset_intervals,
            sum(r.import_rollover_intervals) AS import_rollover_intervals,
            sum(r.export_rollover_intervals) AS export_rollover_intervals,
            sum(r.import_consumption_wh) AS import_consumption_wh,
            sum(r.import_consumption_kwh) AS import_consumption_kwh,
            sum(r.export_consumption_wh) AS export_consumption_wh,
            sum(r.export_consumption_kwh) AS export_consumption_kwh,
            min(r.first_native_bucket_start) AS first_native_bucket_start,
            max(r.last_native_bucket_start) AS last_native_bucket_start,
            min(r.minimum_native_resolution_seconds) AS minimum_native_resolution_seconds,
            max(r.maximum_native_resolution_seconds) AS maximum_native_resolution_seconds,
            sum(r.gap_interval_count) AS gap_interval_count,
            sum(r.reset_interval_count) AS reset_interval_count,
            sum(r.rollover_interval_count) AS rollover_interval_count,
            sum(r.invalid_interval_count) AS invalid_interval_count,
            sum(r.reconstructed_interval_count) AS reconstructed_interval_count,
            sum(r.import_reconstructed_intervals) AS import_reconstructed_intervals,
            sum(r.export_reconstructed_intervals) AS export_reconstructed_intervals,
            sum(r.import_reconstructed_wh) AS import_reconstructed_wh,
            sum(r.import_reconstructed_kwh) AS import_reconstructed_kwh,
            sum(r.export_reconstructed_wh) AS export_reconstructed_wh,
            sum(r.export_reconstructed_kwh) AS export_reconstructed_kwh
           FROM analytics.v_energy_reporting_15min r
             JOIN metadata.sites s ON s.id = r.site_id AND s.organization_id = r.organization_id
          GROUP BY r.grafana_org_id, r.organization_id, r.site_id, r.device_id, r.external_id, r.device_name, s.timezone, ((r.bucket_start AT TIME ZONE s.timezone)::date)
        )
 SELECT grafana_org_id,
    organization_id,
    site_id,
    device_id,
    external_id,
    device_name,
    site_timezone,
    consumption_date,
    source_interval_count,
    source_sample_count,
    valid_import_intervals,
    invalid_import_intervals,
    valid_export_intervals,
    invalid_export_intervals,
    import_gap_intervals,
    export_gap_intervals,
    import_reset_intervals,
    export_reset_intervals,
    import_rollover_intervals,
    export_rollover_intervals,
    import_consumption_wh,
    import_consumption_kwh,
    export_consumption_wh,
    export_consumption_kwh,
    first_native_bucket_start,
    last_native_bucket_start,
    minimum_native_resolution_seconds,
    maximum_native_resolution_seconds,
        CASE
            WHEN invalid_interval_count > 0::numeric THEN 'INVALID_INTERVALS'::text
            WHEN reset_interval_count > 0::numeric THEN 'RESET_DETECTED'::text
            WHEN gap_interval_count > 0::numeric THEN 'GAPS_DETECTED'::text
            WHEN reconstructed_interval_count > 0::numeric THEN 'RECONSTRUCTED_TIMING'::text
            WHEN rollover_interval_count > 0::numeric THEN 'ROLLOVER_DETECTED'::text
            ELSE 'GOOD'::text
        END AS quality_status,
    gap_interval_count,
    reset_interval_count,
    rollover_interval_count,
    invalid_interval_count,
    reconstructed_interval_count,
    import_reconstructed_intervals,
    export_reconstructed_intervals,
    import_reconstructed_wh,
    import_reconstructed_kwh,
    export_reconstructed_wh,
    export_reconstructed_kwh
   FROM daily d;


-- ----------------------------------------------------------------------------
-- 5. Legacy daily/asset/hierarchy chain: carries the reconstructed counter
--    so the hierarchy status never reports a reconstructed-only day GOOD.
-- ----------------------------------------------------------------------------

CREATE OR REPLACE VIEW analytics.v_energy_consumption_daily WITH (security_barrier = true) AS
 SELECT r.grafana_org_id,
    (r.bucket_start AT TIME ZONE s.timezone)::date AS consumption_date,
    r.organization_id,
    r.site_id,
    r.device_id,
    r.external_id,
    r.device_name,
    sum(r.import_consumption_kwh) AS import_consumption_kwh,
    sum(r.export_consumption_kwh) AS export_consumption_kwh,
    count(*) FILTER (WHERE r.valid_import_intervals > 0 AND r.invalid_import_intervals = 0) AS valid_import_intervals,
    count(*) FILTER (WHERE r.valid_export_intervals > 0 AND r.invalid_export_intervals = 0) AS valid_export_intervals,
    count(*) FILTER (WHERE r.reset_interval_count > 0) AS reset_interval_count,
    count(*) FILTER (WHERE r.gap_interval_count > 0) AS gap_interval_count,
    min(r.bucket_start) AS first_bucket_start,
    max(r.bucket_start) AS last_bucket_start,
    count(*) FILTER (WHERE r.reconstructed_interval_count > 0) AS reconstructed_interval_count
   FROM analytics.v_energy_reporting_15min r
     JOIN metadata.sites s ON s.id = r.site_id AND s.organization_id = r.organization_id
  GROUP BY r.grafana_org_id, ((r.bucket_start AT TIME ZONE s.timezone)::date), r.organization_id, r.site_id, r.device_id, r.external_id, r.device_name;

CREATE OR REPLACE VIEW analytics.v_asset_consumption_daily WITH (security_barrier = true) AS
 SELECT c.grafana_org_id,
    c.organization_id,
    c.site_id,
    ad.asset_id,
    ad.asset_name,
    ad.asset_type,
    ad.parent_asset_id,
    ad.parent_asset_name,
    c.device_id,
    c.external_id,
    c.device_name,
    c.consumption_date,
    c.import_consumption_kwh,
    c.export_consumption_kwh,
    c.valid_import_intervals,
    c.valid_export_intervals,
    c.reset_interval_count,
    c.gap_interval_count,
    c.first_bucket_start,
    c.last_bucket_start,
    c.reconstructed_interval_count
   FROM analytics.v_energy_consumption_daily c
     JOIN analytics.v_asset_devices ad ON ad.grafana_org_id = c.grafana_org_id AND ad.device_id = c.device_id AND ad.relationship_type = 'PRIMARY_METER'::text;

CREATE OR REPLACE VIEW analytics.v_asset_hierarchy_rollup_daily WITH (security_barrier = true) AS
 WITH direct_meter_assignments AS (
         SELECT ad.grafana_org_id,
            ad.organization_id,
            ad.site_id,
            ad.asset_id,
            count(DISTINCT ad.device_id) AS direct_meter_count
           FROM analytics.v_asset_devices ad
          WHERE ad.relationship_type = 'PRIMARY_METER'::text
          GROUP BY ad.grafana_org_id, ad.organization_id, ad.site_id, ad.asset_id
        ), contributions AS (
         SELECT h.grafana_org_id,
            h.organization_id,
            h.site_id,
            h.site_code,
            h.site_name,
            h.ancestor_asset_id AS asset_id,
            h.ancestor_asset_name AS asset_name,
            h.ancestor_asset_type_id AS asset_type_id,
            h.ancestor_asset_type AS asset_type,
            h.ancestor_parent_asset_id AS parent_asset_id,
            parent.name AS parent_asset_name,
            h.descendant_asset_id,
            h.descendant_asset_name,
            h.depth,
            c.device_id,
            c.consumption_date,
            c.import_consumption_kwh,
            c.export_consumption_kwh,
            c.valid_import_intervals,
            c.valid_export_intervals,
            c.reset_interval_count,
            c.gap_interval_count,
            c.first_bucket_start,
            c.last_bucket_start,
            c.reconstructed_interval_count
           FROM analytics.v_asset_hierarchy_closure h
             JOIN analytics.v_asset_consumption_daily c ON c.grafana_org_id = h.grafana_org_id AND c.organization_id = h.organization_id AND c.site_id = h.site_id AND c.asset_id = h.descendant_asset_id
             LEFT JOIN metadata.assets parent ON parent.id = h.ancestor_parent_asset_id AND parent.organization_id = h.organization_id AND parent.site_id = h.site_id
        ), aggregated AS (
         SELECT c.grafana_org_id,
            c.organization_id,
            c.site_id,
            c.site_code,
            c.site_name,
            c.asset_id,
            c.asset_name,
            c.asset_type_id,
            c.asset_type,
            c.parent_asset_id,
            c.parent_asset_name,
            c.consumption_date,
            sum(c.import_consumption_kwh) FILTER (WHERE c.depth = 0) AS direct_import_consumption_kwh,
            sum(c.export_consumption_kwh) FILTER (WHERE c.depth = 0) AS direct_export_consumption_kwh,
            sum(c.valid_import_intervals) FILTER (WHERE c.depth = 0) AS direct_valid_import_intervals,
            sum(c.valid_export_intervals) FILTER (WHERE c.depth = 0) AS direct_valid_export_intervals,
            sum(c.reset_interval_count) FILTER (WHERE c.depth = 0) AS direct_reset_interval_count,
            sum(c.gap_interval_count) FILTER (WHERE c.depth = 0) AS direct_gap_interval_count,
            sum(c.reconstructed_interval_count) FILTER (WHERE c.depth = 0) AS direct_reconstructed_interval_count,
            count(DISTINCT c.device_id) FILTER (WHERE c.depth = 0) AS direct_devices_with_data,
            sum(c.import_consumption_kwh) FILTER (WHERE c.depth > 0) AS descendant_import_consumption_kwh,
            sum(c.export_consumption_kwh) FILTER (WHERE c.depth > 0) AS descendant_export_consumption_kwh,
            sum(c.valid_import_intervals) FILTER (WHERE c.depth > 0) AS descendant_valid_import_intervals,
            sum(c.valid_export_intervals) FILTER (WHERE c.depth > 0) AS descendant_valid_export_intervals,
            sum(c.reset_interval_count) FILTER (WHERE c.depth > 0) AS descendant_reset_interval_count,
            sum(c.gap_interval_count) FILTER (WHERE c.depth > 0) AS descendant_gap_interval_count,
            sum(c.reconstructed_interval_count) FILTER (WHERE c.depth > 0) AS descendant_reconstructed_interval_count,
            count(DISTINCT c.device_id) FILTER (WHERE c.depth > 0) AS descendant_devices_with_data,
            count(DISTINCT c.descendant_asset_id) FILTER (WHERE c.depth > 0) AS descendants_with_data,
            max(c.depth) FILTER (WHERE c.depth > 0) AS deepest_contributing_level,
            min(c.first_bucket_start) AS first_bucket_start,
            max(c.last_bucket_start) AS last_bucket_start
           FROM contributions c
          GROUP BY c.grafana_org_id, c.organization_id, c.site_id, c.site_code, c.site_name, c.asset_id, c.asset_name, c.asset_type_id, c.asset_type, c.parent_asset_id, c.parent_asset_name, c.consumption_date
        ), classified AS (
         SELECT a.grafana_org_id,
            a.organization_id,
            a.site_id,
            a.site_code,
            a.site_name,
            a.asset_id,
            a.asset_name,
            a.asset_type_id,
            a.asset_type,
            a.parent_asset_id,
            a.parent_asset_name,
            a.consumption_date,
            a.direct_import_consumption_kwh,
            a.direct_export_consumption_kwh,
            a.direct_valid_import_intervals,
            a.direct_valid_export_intervals,
            a.direct_reset_interval_count,
            a.direct_gap_interval_count,
            a.direct_devices_with_data,
            a.descendant_import_consumption_kwh,
            a.descendant_export_consumption_kwh,
            a.descendant_valid_import_intervals,
            a.descendant_valid_export_intervals,
            a.descendant_reset_interval_count,
            a.descendant_gap_interval_count,
            a.direct_reconstructed_interval_count,
            a.descendant_reconstructed_interval_count,
            a.descendant_devices_with_data,
            a.descendants_with_data,
            a.deepest_contributing_level,
            a.first_bucket_start,
            a.last_bucket_start,
            COALESCE(dma.direct_meter_count, 0::bigint) AS direct_meter_count,
            COALESCE(dma.direct_meter_count, 0::bigint) > 0 AS direct_meter_configured,
            a.direct_devices_with_data > 0 AS direct_data_available,
            a.descendant_devices_with_data > 0 AS descendant_data_available,
                CASE
                    WHEN COALESCE(dma.direct_meter_count, 0::bigint) > 0 THEN a.direct_import_consumption_kwh
                    ELSE a.descendant_import_consumption_kwh
                END AS reported_import_consumption_kwh,
                CASE
                    WHEN COALESCE(dma.direct_meter_count, 0::bigint) > 0 THEN a.direct_export_consumption_kwh
                    ELSE a.descendant_export_consumption_kwh
                END AS reported_export_consumption_kwh,
                CASE
                    WHEN COALESCE(dma.direct_meter_count, 0::bigint) > 0 AND a.direct_devices_with_data > 0 THEN 'DIRECT_METER'::text
                    WHEN COALESCE(dma.direct_meter_count, 0::bigint) > 0 AND a.direct_devices_with_data = 0 THEN 'DIRECT_METER_NO_DATA'::text
                    WHEN COALESCE(dma.direct_meter_count, 0::bigint) = 0 AND a.descendant_devices_with_data > 0 THEN 'DESCENDANT_ROLLUP'::text
                    ELSE 'NO_METERED_COVERAGE'::text
                END AS reporting_method,
                CASE
                    WHEN COALESCE(dma.direct_meter_count, 0::bigint) > 0 AND a.direct_devices_with_data = 0 THEN 'DIRECT_DATA_MISSING'::text
                    WHEN COALESCE(dma.direct_meter_count, 0::bigint) > 0 AND COALESCE(a.direct_reset_interval_count, 0::numeric) > 0::numeric THEN 'RESET_DETECTED'::text
                    WHEN COALESCE(dma.direct_meter_count, 0::bigint) > 0 AND COALESCE(a.direct_gap_interval_count, 0::numeric) > 0::numeric THEN 'GAPS_DETECTED'::text
                    WHEN COALESCE(dma.direct_meter_count, 0::bigint) = 0 AND COALESCE(a.descendant_reset_interval_count, 0::numeric) > 0::numeric THEN 'RESET_DETECTED'::text
                    WHEN COALESCE(dma.direct_meter_count, 0::bigint) = 0 AND COALESCE(a.descendant_gap_interval_count, 0::numeric) > 0::numeric THEN 'GAPS_DETECTED'::text
                    WHEN COALESCE(dma.direct_meter_count, 0::bigint) > 0 AND COALESCE(a.direct_reconstructed_interval_count, 0::numeric) > 0::numeric THEN 'RECONSTRUCTED_TIMING'::text
                    WHEN COALESCE(dma.direct_meter_count, 0::bigint) = 0 AND COALESCE(a.descendant_reconstructed_interval_count, 0::numeric) > 0::numeric THEN 'RECONSTRUCTED_TIMING'::text
                    WHEN COALESCE(dma.direct_meter_count, 0::bigint) > 0 OR a.descendant_devices_with_data > 0 THEN 'GOOD'::text
                    ELSE 'NO_DATA'::text
                END AS quality_status
           FROM aggregated a
             LEFT JOIN direct_meter_assignments dma ON dma.grafana_org_id = a.grafana_org_id AND dma.organization_id = a.organization_id AND dma.site_id = a.site_id AND dma.asset_id = a.asset_id
        )
 SELECT grafana_org_id,
    organization_id,
    site_id,
    site_code,
    site_name,
    asset_id,
    asset_name,
    asset_type_id,
    asset_type,
    parent_asset_id,
    parent_asset_name,
    consumption_date,
    direct_import_consumption_kwh,
    descendant_import_consumption_kwh,
    reported_import_consumption_kwh,
    direct_export_consumption_kwh,
    descendant_export_consumption_kwh,
    reported_export_consumption_kwh,
    direct_meter_count,
    direct_meter_configured,
    direct_data_available,
    descendant_data_available,
    direct_devices_with_data,
    descendant_devices_with_data,
    descendants_with_data,
    deepest_contributing_level,
    direct_valid_import_intervals,
    descendant_valid_import_intervals,
    direct_valid_export_intervals,
    descendant_valid_export_intervals,
    direct_reset_interval_count,
    descendant_reset_interval_count,
    direct_gap_interval_count,
    descendant_gap_interval_count,
    reporting_method,
    quality_status,
    first_bucket_start,
    last_bucket_start,
    COALESCE(direct_reconstructed_interval_count, 0::numeric) AS direct_reconstructed_interval_count,
    COALESCE(descendant_reconstructed_interval_count, 0::numeric) AS descendant_reconstructed_interval_count
   FROM classified;


-- ----------------------------------------------------------------------------
-- 6. Persisted tier refresh functions: write the new counters; the
--    value-aware calculated_at CASE compares them too (no churn: every
--    existing row already holds the 0 the refresh computes).
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

        calculated_at,
        reconstructed_interval_count,
        import_reconstructed_intervals,
        export_reconstructed_intervals,
        import_reconstructed_kwh,
        export_reconstructed_kwh
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

        clock_timestamp(),
        r.reconstructed_interval_count,
        r.import_reconstructed_intervals,
        r.export_reconstructed_intervals,
        r.import_reconstructed_kwh,
        r.export_reconstructed_kwh

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
        reconstructed_interval_count =
            EXCLUDED.reconstructed_interval_count,
        import_reconstructed_intervals =
            EXCLUDED.import_reconstructed_intervals,
        export_reconstructed_intervals =
            EXCLUDED.export_reconstructed_intervals,
        import_reconstructed_kwh =
            EXCLUDED.import_reconstructed_kwh,
        export_reconstructed_kwh =
            EXCLUDED.export_reconstructed_kwh,

        calculated_at =
            CASE
                WHEN ROW(
                    energy_consumption_15min.organization_id,
                    energy_consumption_15min.site_id,
                    energy_consumption_15min.source_interval_count,
                    energy_consumption_15min.import_consumption_kwh,
                    energy_consumption_15min.export_consumption_kwh,
                    energy_consumption_15min.valid_import_intervals,
                    energy_consumption_15min.invalid_import_intervals,
                    energy_consumption_15min.valid_export_intervals,
                    energy_consumption_15min.invalid_export_intervals,
                    energy_consumption_15min.gap_interval_count,
                    energy_consumption_15min.reset_interval_count,
                    energy_consumption_15min.rollover_interval_count,
                    energy_consumption_15min.invalid_interval_count,
                    energy_consumption_15min.import_gap_intervals,
                    energy_consumption_15min.export_gap_intervals,
                    energy_consumption_15min.import_reset_intervals,
                    energy_consumption_15min.export_reset_intervals,
                    energy_consumption_15min.import_rollover_intervals,
                    energy_consumption_15min.export_rollover_intervals,
                    energy_consumption_15min.first_source_bucket,
                    energy_consumption_15min.last_source_bucket,
                    energy_consumption_15min.reconstructed_interval_count,
                    energy_consumption_15min.import_reconstructed_intervals,
                    energy_consumption_15min.export_reconstructed_intervals,
                    energy_consumption_15min.import_reconstructed_kwh,
                    energy_consumption_15min.export_reconstructed_kwh
                ) IS DISTINCT FROM ROW(
                    EXCLUDED.organization_id,
                    EXCLUDED.site_id,
                    EXCLUDED.source_interval_count,
                    EXCLUDED.import_consumption_kwh,
                    EXCLUDED.export_consumption_kwh,
                    EXCLUDED.valid_import_intervals,
                    EXCLUDED.invalid_import_intervals,
                    EXCLUDED.valid_export_intervals,
                    EXCLUDED.invalid_export_intervals,
                    EXCLUDED.gap_interval_count,
                    EXCLUDED.reset_interval_count,
                    EXCLUDED.rollover_interval_count,
                    EXCLUDED.invalid_interval_count,
                    EXCLUDED.import_gap_intervals,
                    EXCLUDED.export_gap_intervals,
                    EXCLUDED.import_reset_intervals,
                    EXCLUDED.export_reset_intervals,
                    EXCLUDED.import_rollover_intervals,
                    EXCLUDED.export_rollover_intervals,
                    EXCLUDED.first_source_bucket,
                    EXCLUDED.last_source_bucket,
                    EXCLUDED.reconstructed_interval_count,
                    EXCLUDED.import_reconstructed_intervals,
                    EXCLUDED.export_reconstructed_intervals,
                    EXCLUDED.import_reconstructed_kwh,
                    EXCLUDED.export_reconstructed_kwh
                )
                THEN EXCLUDED.calculated_at
                ELSE energy_consumption_15min.calculated_at
            END;


    GET DIAGNOSTICS
        v_affected = ROW_COUNT;

    RETURN v_affected;

END;

$function$;

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

        calculated_at,
        reconstructed_interval_count,
        import_reconstructed_intervals,
        export_reconstructed_intervals,
        import_reconstructed_kwh,
        export_reconstructed_kwh
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

        clock_timestamp(),
        SUM(s.reconstructed_interval_count)::BIGINT,
        SUM(s.import_reconstructed_intervals)::BIGINT,
        SUM(s.export_reconstructed_intervals)::BIGINT,
        SUM(s.import_reconstructed_kwh)::NUMERIC,
        SUM(s.export_reconstructed_kwh)::NUMERIC

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
        reconstructed_interval_count =
            EXCLUDED.reconstructed_interval_count,
        import_reconstructed_intervals =
            EXCLUDED.import_reconstructed_intervals,
        export_reconstructed_intervals =
            EXCLUDED.export_reconstructed_intervals,
        import_reconstructed_kwh =
            EXCLUDED.import_reconstructed_kwh,
        export_reconstructed_kwh =
            EXCLUDED.export_reconstructed_kwh,

        calculated_at =
            CASE
                WHEN ROW(
                    energy_consumption_hourly.organization_id,
                    energy_consumption_hourly.site_id,
                    energy_consumption_hourly.source_interval_count,
                    energy_consumption_hourly.import_consumption_kwh,
                    energy_consumption_hourly.export_consumption_kwh,
                    energy_consumption_hourly.valid_import_intervals,
                    energy_consumption_hourly.invalid_import_intervals,
                    energy_consumption_hourly.valid_export_intervals,
                    energy_consumption_hourly.invalid_export_intervals,
                    energy_consumption_hourly.gap_interval_count,
                    energy_consumption_hourly.reset_interval_count,
                    energy_consumption_hourly.rollover_interval_count,
                    energy_consumption_hourly.invalid_interval_count,
                    energy_consumption_hourly.import_gap_intervals,
                    energy_consumption_hourly.export_gap_intervals,
                    energy_consumption_hourly.import_reset_intervals,
                    energy_consumption_hourly.export_reset_intervals,
                    energy_consumption_hourly.import_rollover_intervals,
                    energy_consumption_hourly.export_rollover_intervals,
                    energy_consumption_hourly.first_source_bucket,
                    energy_consumption_hourly.last_source_bucket,
                    energy_consumption_hourly.reconstructed_interval_count,
                    energy_consumption_hourly.import_reconstructed_intervals,
                    energy_consumption_hourly.export_reconstructed_intervals,
                    energy_consumption_hourly.import_reconstructed_kwh,
                    energy_consumption_hourly.export_reconstructed_kwh
                ) IS DISTINCT FROM ROW(
                    EXCLUDED.organization_id,
                    EXCLUDED.site_id,
                    EXCLUDED.source_interval_count,
                    EXCLUDED.import_consumption_kwh,
                    EXCLUDED.export_consumption_kwh,
                    EXCLUDED.valid_import_intervals,
                    EXCLUDED.invalid_import_intervals,
                    EXCLUDED.valid_export_intervals,
                    EXCLUDED.invalid_export_intervals,
                    EXCLUDED.gap_interval_count,
                    EXCLUDED.reset_interval_count,
                    EXCLUDED.rollover_interval_count,
                    EXCLUDED.invalid_interval_count,
                    EXCLUDED.import_gap_intervals,
                    EXCLUDED.export_gap_intervals,
                    EXCLUDED.import_reset_intervals,
                    EXCLUDED.export_reset_intervals,
                    EXCLUDED.import_rollover_intervals,
                    EXCLUDED.export_rollover_intervals,
                    EXCLUDED.first_source_bucket,
                    EXCLUDED.last_source_bucket,
                    EXCLUDED.reconstructed_interval_count,
                    EXCLUDED.import_reconstructed_intervals,
                    EXCLUDED.export_reconstructed_intervals,
                    EXCLUDED.import_reconstructed_kwh,
                    EXCLUDED.export_reconstructed_kwh
                )
                THEN EXCLUDED.calculated_at
                ELSE energy_consumption_hourly.calculated_at
            END;


    GET DIAGNOSTICS
        v_affected = ROW_COUNT;

    RETURN v_affected;

END;

$function$;

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

        calculated_at,
        reconstructed_interval_count,
        import_reconstructed_intervals,
        export_reconstructed_intervals,
        import_reconstructed_kwh,
        export_reconstructed_kwh
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

        clock_timestamp(),
        SUM(l.reconstructed_interval_count)::BIGINT,
        SUM(l.import_reconstructed_intervals)::BIGINT,
        SUM(l.export_reconstructed_intervals)::BIGINT,
        SUM(l.import_reconstructed_kwh)::NUMERIC,
        SUM(l.export_reconstructed_kwh)::NUMERIC

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
        reconstructed_interval_count =
            EXCLUDED.reconstructed_interval_count,
        import_reconstructed_intervals =
            EXCLUDED.import_reconstructed_intervals,
        export_reconstructed_intervals =
            EXCLUDED.export_reconstructed_intervals,
        import_reconstructed_kwh =
            EXCLUDED.import_reconstructed_kwh,
        export_reconstructed_kwh =
            EXCLUDED.export_reconstructed_kwh,

        calculated_at =
            CASE
                WHEN ROW(
                    energy_consumption_daily.consumption_date,
                    energy_consumption_daily.site_timezone,
                    energy_consumption_daily.organization_id,
                    energy_consumption_daily.site_id,
                    energy_consumption_daily.source_interval_count,
                    energy_consumption_daily.import_consumption_kwh,
                    energy_consumption_daily.export_consumption_kwh,
                    energy_consumption_daily.valid_import_intervals,
                    energy_consumption_daily.invalid_import_intervals,
                    energy_consumption_daily.valid_export_intervals,
                    energy_consumption_daily.invalid_export_intervals,
                    energy_consumption_daily.gap_interval_count,
                    energy_consumption_daily.reset_interval_count,
                    energy_consumption_daily.rollover_interval_count,
                    energy_consumption_daily.invalid_interval_count,
                    energy_consumption_daily.import_gap_intervals,
                    energy_consumption_daily.export_gap_intervals,
                    energy_consumption_daily.import_reset_intervals,
                    energy_consumption_daily.export_reset_intervals,
                    energy_consumption_daily.import_rollover_intervals,
                    energy_consumption_daily.export_rollover_intervals,
                    energy_consumption_daily.first_source_bucket,
                    energy_consumption_daily.last_source_bucket,
                    energy_consumption_daily.reconstructed_interval_count,
                    energy_consumption_daily.import_reconstructed_intervals,
                    energy_consumption_daily.export_reconstructed_intervals,
                    energy_consumption_daily.import_reconstructed_kwh,
                    energy_consumption_daily.export_reconstructed_kwh
                ) IS DISTINCT FROM ROW(
                    EXCLUDED.consumption_date,
                    EXCLUDED.site_timezone,
                    EXCLUDED.organization_id,
                    EXCLUDED.site_id,
                    EXCLUDED.source_interval_count,
                    EXCLUDED.import_consumption_kwh,
                    EXCLUDED.export_consumption_kwh,
                    EXCLUDED.valid_import_intervals,
                    EXCLUDED.invalid_import_intervals,
                    EXCLUDED.valid_export_intervals,
                    EXCLUDED.invalid_export_intervals,
                    EXCLUDED.gap_interval_count,
                    EXCLUDED.reset_interval_count,
                    EXCLUDED.rollover_interval_count,
                    EXCLUDED.invalid_interval_count,
                    EXCLUDED.import_gap_intervals,
                    EXCLUDED.export_gap_intervals,
                    EXCLUDED.import_reset_intervals,
                    EXCLUDED.export_reset_intervals,
                    EXCLUDED.import_rollover_intervals,
                    EXCLUDED.export_rollover_intervals,
                    EXCLUDED.first_source_bucket,
                    EXCLUDED.last_source_bucket,
                    EXCLUDED.reconstructed_interval_count,
                    EXCLUDED.import_reconstructed_intervals,
                    EXCLUDED.export_reconstructed_intervals,
                    EXCLUDED.import_reconstructed_kwh,
                    EXCLUDED.export_reconstructed_kwh
                )
                THEN EXCLUDED.calculated_at
                ELSE energy_consumption_daily.calculated_at
            END;


    GET DIAGNOSTICS
        v_affected = ROW_COUNT;

    RETURN v_affected;

END;

$function$;


-- ----------------------------------------------------------------------------
-- 7. 15-minute reconcile detection: count measured native rows only, the
--    same definition v_energy_semantic_rollup_15min.source_interval_count
--    now uses (otherwise a reconstructed slot would be a permanent false
--    mismatch).
-- ----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION analytics.reconcile_energy_deficits(p_tier text, p_window_start timestamp with time zone, p_window_end timestamp with time zone, p_coarse interval, p_limit integer)
 RETURNS TABLE(coarse_bucket_start timestamp with time zone, mism_rows bigint)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'analytics', 'telemetry', 'config', 'metadata'
AS $function$
BEGIN
    IF p_tier = 'energy_consumption_1min' THEN
        RETURN QUERY
        WITH parent AS (
            SELECT ca.device_id, ca.bucket_start,
                   date_trunc('hour', ca.bucket_start) AS coarse,
                   ca.sample_count::bigint AS p_vol
            FROM telemetry.ca_energy_1min ca
            CROSS JOIN LATERAL telemetry.resolve_site_capture_bucket(ca.site_id, ca.bucket_start) rp
            WHERE ca.bucket_start >= p_window_start AND ca.bucket_start < p_window_end
              AND rp.policy_id IS NOT NULL
              AND rp.capture_interval_seconds <= 60
        ),
        child AS (
            SELECT c.device_id, c.bucket_start,
                   date_trunc('hour', c.bucket_start) AS coarse,
                   c.source_sample_count::bigint AS c_vol
            FROM analytics.energy_consumption_1min c
            WHERE c.bucket_start >= p_window_start AND c.bucket_start < p_window_end
        ),
        mism AS (
            SELECT COALESCE(p.coarse, c.coarse) AS coarse
            FROM parent p
            FULL JOIN child c ON p.device_id = c.device_id AND p.bucket_start = c.bucket_start
            WHERE p.device_id IS NOT NULL
              AND (c.device_id IS NULL OR p.p_vol IS DISTINCT FROM c.c_vol)
        )
        SELECT m.coarse, count(*)::bigint
        FROM mism m
        GROUP BY m.coarse
        ORDER BY m.coarse
        LIMIT p_limit;

    ELSIF p_tier = 'energy_consumption_5min' THEN
        RETURN QUERY
        WITH parent AS (
            SELECT ca.device_id, ca.bucket_start,
                   date_trunc('hour', ca.bucket_start) AS coarse,
                   ca.sample_count::bigint AS p_vol
            FROM telemetry.ca_energy_5min ca
            CROSS JOIN LATERAL telemetry.resolve_site_capture_bucket(ca.site_id, ca.bucket_start) rp
            WHERE ca.bucket_start >= p_window_start AND ca.bucket_start < p_window_end
              AND rp.policy_id IS NOT NULL
              AND rp.capture_interval_seconds = 300
        ),
        child AS (
            SELECT c.device_id, c.bucket_start,
                   date_trunc('hour', c.bucket_start) AS coarse,
                   c.source_sample_count::bigint AS c_vol
            FROM analytics.energy_consumption_5min c
            WHERE c.bucket_start >= p_window_start AND c.bucket_start < p_window_end
        ),
        mism AS (
            SELECT COALESCE(p.coarse, c.coarse) AS coarse
            FROM parent p
            FULL JOIN child c ON p.device_id = c.device_id AND p.bucket_start = c.bucket_start
            WHERE p.device_id IS NOT NULL
              AND (c.device_id IS NULL OR p.p_vol IS DISTINCT FROM c.c_vol)
        )
        SELECT m.coarse, count(*)::bigint
        FROM mism m
        GROUP BY m.coarse
        ORDER BY m.coarse
        LIMIT p_limit;

    ELSIF p_tier = 'energy_consumption_15min' THEN
        RETURN QUERY
        WITH native AS (
            SELECT n.device_id,
                   date_bin('15 minutes', n.bucket_start, TIMESTAMPTZ '2000-01-01 05:30:00+05:30') AS b15,
                   n.calculated_at,
                   (NOT n.is_reconstructed OR COALESCE(n.source_sample_count, 0) > 0) AS is_measured
            FROM analytics.energy_consumption_1min n
            WHERE n.bucket_start >= p_window_start AND n.bucket_start < p_window_end
            UNION ALL
            SELECT n.device_id,
                   date_bin('15 minutes', n.bucket_start, TIMESTAMPTZ '2000-01-01 05:30:00+05:30') AS b15,
                   n.calculated_at,
                   (NOT n.is_reconstructed OR COALESCE(n.source_sample_count, 0) > 0) AS is_measured
            FROM analytics.energy_consumption_5min n
            WHERE n.bucket_start >= p_window_start AND n.bucket_start < p_window_end
        ),
        parent AS (
            SELECT device_id, b15,
                   (count(*) FILTER (WHERE is_measured))::bigint AS p_cnt,
                   max(calculated_at) AS p_calc
            FROM native
            GROUP BY device_id, b15
        ),
        child AS (
            SELECT c.device_id, c.bucket_start AS b15,
                   c.source_interval_count::bigint AS c_cnt,
                   c.calculated_at AS c_calc
            FROM analytics.energy_consumption_15min c
            WHERE c.bucket_start >= p_window_start AND c.bucket_start < p_window_end
        ),
        mism AS (
            SELECT COALESCE(p.b15, c.b15) AS b15
            FROM parent p
            FULL JOIN child c ON p.device_id = c.device_id AND p.b15 = c.b15
            WHERE p.device_id IS NOT NULL
              AND ( c.device_id IS NULL
                    OR p.p_cnt  IS DISTINCT FROM c.c_cnt
                    OR p.p_calc > c.c_calc )
        )
        SELECT date_trunc('hour', m.b15) AS coarse_bucket_start, count(*)::bigint
        FROM mism m
        GROUP BY date_trunc('hour', m.b15)
        ORDER BY 1
        LIMIT p_limit;

    ELSIF p_tier = 'energy_consumption_hourly' THEN
        RETURN QUERY
        WITH parent AS (
            SELECT s.device_id,
                   date_bin('1 hour', s.bucket_start, TIMESTAMPTZ '2000-01-01 00:00:00+00') AS hr,
                   sum(s.source_interval_count)::bigint AS p_si,
                   max(s.calculated_at) AS p_calc
            FROM analytics.energy_consumption_15min s
            WHERE s.bucket_start >= p_window_start AND s.bucket_start < p_window_end
            GROUP BY s.device_id,
                     date_bin('1 hour', s.bucket_start, TIMESTAMPTZ '2000-01-01 00:00:00+00')
        ),
        child AS (
            SELECT c.device_id, c.bucket_start AS hr,
                   c.source_interval_count::bigint AS c_si,
                   c.calculated_at AS c_calc
            FROM analytics.energy_consumption_hourly c
            WHERE c.bucket_start >= p_window_start AND c.bucket_start < p_window_end
        ),
        mism AS (
            SELECT COALESCE(p.hr, c.hr) AS hr
            FROM parent p
            FULL JOIN child c ON p.device_id = c.device_id AND p.hr = c.hr
            WHERE p.device_id IS NOT NULL
              AND ( c.device_id IS NULL
                    OR p.p_si   IS DISTINCT FROM c.c_si
                    OR p.p_calc > c.c_calc )
        )
        SELECT m.hr, count(*)::bigint
        FROM mism m
        GROUP BY m.hr
        ORDER BY m.hr
        LIMIT p_limit;

    ELSE
        RAISE EXCEPTION 'analytics.reconcile_energy_deficits: unsupported tier %', p_tier;
    END IF;
END;
$function$;


-- ----------------------------------------------------------------------------
-- 8. analytics.get_canonical_energy_read: reconstructed rows/buckets report
--    RECONSTRUCTED_TIMING (never GOOD) and contribute nothing to measured
--    coverage/counters. Signature and return type unchanged.
-- ----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION analytics.get_canonical_energy_read(p_grafana_org_id bigint, p_asset_id uuid, p_from timestamp with time zone, p_to timestamp with time zone, p_requested_resolution text, p_fallback_policy text DEFAULT 'native'::text)
 RETURNS TABLE(requested_resolution text, resolution text, native_resolution_seconds integer, interval_start timestamp with time zone, interval_end timestamp with time zone, resolved_device_id uuid, device_name text, import_consumption_kwh numeric, export_consumption_kwh numeric, import_quality_status text, export_quality_status text, source_interval_count bigint, valid_import_intervals bigint, invalid_import_intervals bigint, valid_export_intervals bigint, invalid_export_intervals bigint, coverage_ratio numeric, gap_interval_count bigint, reset_interval_count bigint, rollover_interval_count bigint, invalid_interval_count bigint, first_native_bucket_start timestamp with time zone, last_native_bucket_start timestamp with time zone, is_partial_bucket boolean, fallback_applied boolean, fallback_reason text)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'analytics', 'metadata', 'telemetry', 'config'
AS $function$
DECLARE
    v_device_id                 UUID;
    v_site_id                   UUID;
    v_device_name                TEXT;

    v_policy_id                  BIGINT;
    v_capture_interval_seconds   INTEGER;
    v_native_duration            INTERVAL;
    v_boundary_time               TIMESTAMPTZ;
    v_boundary_capture_interval_seconds INTEGER;

    v_earliest_applicable_from   TIMESTAMPTZ;
    v_effective_from             TIMESTAMPTZ;

    v_requested_width            INTERVAL;
    v_native_matches             TEXT;

    v_actual                     TEXT;
    v_fallback_applied           BOOLEAN;
    v_fallback_reason            TEXT;
BEGIN
    IF p_from IS NULL OR p_to IS NULL THEN
        RAISE EXCEPTION 'p_from and p_to are required';
    END IF;

    IF p_to <= p_from THEN
        RAISE EXCEPTION
            'p_to (%) must be later than p_from (%)', p_to, p_from;
    END IF;

    IF p_requested_resolution IS NULL THEN
        RAISE EXCEPTION 'p_requested_resolution is required';
    END IF;

    IF p_fallback_policy IS NULL THEN
        p_fallback_policy := 'native';
    END IF;

    IF p_fallback_policy NOT IN ('native', 'coarser', 'strict') THEN
        RAISE EXCEPTION
            'p_fallback_policy must be one of ''native'', ''coarser'', '
            '''strict'', got %', p_fallback_policy;
    END IF;

    IF p_requested_resolution != 'native'
        AND p_requested_resolution NOT IN ('5m', '15m', '1h', '1d')
    THEN
        RAISE EXCEPTION
            'unknown requested resolution %; must be ''native'', ''5m'', '
            '''15m'', ''1h'' or ''1d''', p_requested_resolution;
    END IF;

    -- ------------------------------------------------------------------
    -- Tenant authorization + asset + PRIMARY_METER device + gateway + site.
    --
    -- The existing proven Grafana pattern: grafana_organization_map ->
    -- organization -> asset -> asset_devices, extended by one hop to
    -- gateway -> site. Tenant mismatch, a non-existent asset, an asset
    -- with no PRIMARY_METER, and a device with no gateway all collapse to
    -- zero rows -- consistent with analytics.get_grafana_asset_energy_intervals
    -- -- so this never leaks *why* resolution failed.
    -- ------------------------------------------------------------------

    SELECT
        d.id,
        g.site_id,
        d.name
    INTO
        v_device_id,
        v_site_id,
        v_device_name
    FROM metadata.grafana_organization_map AS gom

    JOIN metadata.assets AS a
      ON a.organization_id = gom.organization_id

    JOIN metadata.asset_devices AS ad
      ON ad.asset_id = a.id
     AND ad.relationship_type = 'PRIMARY_METER'

    JOIN metadata.devices AS d
      ON d.id = ad.device_id

    JOIN metadata.gateways AS g
      ON g.id = d.gateway_id

    WHERE gom.grafana_org_id = p_grafana_org_id
      AND gom.is_active
      AND a.id = p_asset_id

    LIMIT 1;

    IF v_device_id IS NULL THEN
        RETURN;
    END IF;

    -- ------------------------------------------------------------------
    -- Native capture capability, resolved at p_from.
    -- ------------------------------------------------------------------

    v_effective_from := p_from;

    SELECT
        b.policy_id,
        b.capture_interval_seconds
    INTO
        v_policy_id,
        v_capture_interval_seconds
    FROM telemetry.resolve_site_capture_bucket(v_site_id, v_effective_from) AS b;

    IF v_policy_id IS NULL THEN
        -- ------------------------------------------------------------------
        -- No policy (site-specific or the global site_id IS NULL default)
        -- covers p_from. Distinguish "genuinely before any capture
        -- configuration ever existed for this site" (expected -- no policy
        -- could ever have produced telemetry there, so the correct answer
        -- is an empty result, not an error) from "a gap inside an
        -- otherwise-configured era" (a real configuration inconsistency for
        -- a commissioned period -- still an error). The distinguishing
        -- signal is the earliest effective_from across every policy that
        -- could ever apply to this site: if p_from predates that instant,
        -- there was categorically no policy yet, anywhere, for this site;
        -- if p_from is at or after it but resolution still fails, a policy
        -- actually goes missing somewhere it should not.
        -- ------------------------------------------------------------------

        SELECT MIN(p.effective_from)
        INTO v_earliest_applicable_from
        FROM config.telemetry_capture_policies p
        WHERE p.is_enabled
          AND (p.site_id = v_site_id OR p.site_id IS NULL);

        IF v_earliest_applicable_from IS NULL
            OR p_from >= v_earliest_applicable_from
        THEN
            -- Either this site has no applicable policy at all (a genuine
            -- configuration gap regardless of when it's queried), or
            -- p_from already falls inside the configured era and still
            -- didn't resolve (a gap between policies). Both are real
            -- configuration problems, not "no data yet" -- preserve the
            -- original failure.
            RAISE EXCEPTION
                'no capture policy resolvable for site % at %', v_site_id, p_from;
        END IF;

        IF p_to <= v_earliest_applicable_from THEN
            -- The entire requested range predates any capture policy this
            -- site has ever had. No telemetry could exist for any of it --
            -- an empty result, not an error.
            RETURN;
        END IF;

        -- The requested range straddles the boundary: nothing could have
        -- been captured before v_earliest_applicable_from, so clip the
        -- effective read window forward to it and re-resolve. The portion
        -- from p_from up to the clip point contributes zero rows, exactly
        -- as if it had never been part of the request.
        v_effective_from := v_earliest_applicable_from;

        SELECT
            b.policy_id,
            b.capture_interval_seconds
        INTO
            v_policy_id,
            v_capture_interval_seconds
        FROM telemetry.resolve_site_capture_bucket(v_site_id, v_effective_from) AS b;

        IF v_policy_id IS NULL THEN
            RAISE EXCEPTION
                'no capture policy resolvable for site % at % after clipping to the earliest applicable policy',
                v_site_id, v_effective_from;
        END IF;
    END IF;

    -- ------------------------------------------------------------------
    -- Historical-time safety: reject ranges that cross a genuine change in
    -- capture_interval_seconds rather than silently applying the interval
    -- in force at either endpoint. Re-resolves the actual policy (via
    -- telemetry.resolve_site_capture_bucket itself -- its precedence
    -- logic is never duplicated here) at every candidate transition
    -- instant inside (p_from, p_to).
    --
    -- Compares only capture_interval_seconds -- the one resolved parameter
    -- this function's own math actually depends on (bucket width, and
    -- every coverage-ratio / partial-bucket denominator below all assume
    -- one constant interval across the window). late_arrival_tolerance_
    -- seconds is deliberately excluded: it only governs whether a raw
    -- sample gets folded into its bucket at *ingestion* time, which is
    -- already baked into whatever is persisted in the native/aggregate
    -- tables this function reads -- it changes nothing about how this
    -- function computes its output. Comparing it here (as an earlier
    -- version of this function did) rejected every multi-week read that
    -- crossed a site's late-arrival-tolerance tuning during onboarding,
    -- even though nothing this function returns would have been affected
    -- -- a false positive, not a real capture-policy change.
    -- ------------------------------------------------------------------

    FOR v_boundary_time IN
        SELECT DISTINCT t
        FROM (
            SELECT effective_from AS t
            FROM config.telemetry_capture_policies
            WHERE is_enabled
              AND (site_id = v_site_id OR site_id IS NULL)

            UNION

            SELECT effective_to AS t
            FROM config.telemetry_capture_policies
            WHERE is_enabled
              AND (site_id = v_site_id OR site_id IS NULL)
              AND effective_to IS NOT NULL
        ) AS candidates
        WHERE t > v_effective_from
          AND t < p_to
        ORDER BY t
    LOOP
        SELECT b.capture_interval_seconds
        INTO v_boundary_capture_interval_seconds
        FROM telemetry.resolve_site_capture_bucket(v_site_id, v_boundary_time) AS b;

        IF v_boundary_capture_interval_seconds IS DISTINCT FROM v_capture_interval_seconds THEN
            RAISE EXCEPTION
                'requested range [%, %) crosses a capture-policy change for '
                'site % at %; cross-policy historical reads are not yet '
                'supported',
                p_from, p_to, v_site_id, v_boundary_time;
        END IF;
    END LOOP;

    v_native_duration := make_interval(secs => v_capture_interval_seconds);

    -- ------------------------------------------------------------------
    -- requested -> actual reporting resolution. Compares ACTUAL DURATIONS,
    -- never strings. The resolution-tier width mapping is an inline
    -- VALUES list (not a physical table) so this migration creates only
    -- one production object.
    -- ------------------------------------------------------------------

    IF p_requested_resolution = 'native' THEN
        v_actual            := 'native';
        v_fallback_applied  := FALSE;
        v_fallback_reason   := NULL;
    ELSE
        SELECT bucket_width
        INTO v_requested_width
        FROM (
            VALUES
                ('5m',  INTERVAL '5 minutes'),
                ('15m', INTERVAL '15 minutes'),
                ('1h',  INTERVAL '1 hour'),
                ('1d',  INTERVAL '1 day')
        ) AS t(resolution_key, bucket_width)
        WHERE resolution_key = p_requested_resolution;

        IF v_requested_width >= v_native_duration THEN
            v_actual            := p_requested_resolution;
            v_fallback_applied  := FALSE;
            v_fallback_reason   := NULL;
        ELSIF p_fallback_policy = 'strict' THEN
            v_actual            := NULL;
            v_fallback_applied  := FALSE;
            v_fallback_reason   := 'requested_resolution_finer_than_native_and_policy_is_strict';
        ELSE
            SELECT resolution_key
            INTO v_native_matches
            FROM (
                VALUES
                    ('5m',  INTERVAL '5 minutes'),
                    ('15m', INTERVAL '15 minutes'),
                    ('1h',  INTERVAL '1 hour'),
                    ('1d',  INTERVAL '1 day')
            ) AS t(resolution_key, bucket_width)
            WHERE bucket_width = v_native_duration;

            v_actual            := COALESCE(v_native_matches, 'native');
            v_fallback_applied  := TRUE;
            v_fallback_reason   := 'requested_resolution_finer_than_native';
        END IF;
    END IF;

    -- ------------------------------------------------------------------
    -- Strict-unavailable: preserve resolved metadata, fabricate no data.
    -- ------------------------------------------------------------------

    IF v_actual IS NULL THEN
        RETURN QUERY SELECT
            p_requested_resolution,
            NULL::TEXT,
            v_capture_interval_seconds,
            NULL::TIMESTAMPTZ,
            NULL::TIMESTAMPTZ,
            v_device_id,
            v_device_name,
            NULL::NUMERIC,
            NULL::NUMERIC,
            NULL::TEXT,
            NULL::TEXT,
            NULL::BIGINT,
            NULL::BIGINT,
            NULL::BIGINT,
            NULL::BIGINT,
            NULL::BIGINT,
            NULL::NUMERIC,
            NULL::BIGINT,
            NULL::BIGINT,
            NULL::BIGINT,
            NULL::BIGINT,
            NULL::TIMESTAMPTZ,
            NULL::TIMESTAMPTZ,
            NULL::BOOLEAN,
            v_fallback_applied,
            v_fallback_reason;
        RETURN;
    END IF;

    -- ------------------------------------------------------------------
    -- NATIVE: analytics.v_energy_consumption_native. One row per already-
    -- classified native interval. No aggregation, no reclassification.
    -- ------------------------------------------------------------------

    IF v_actual = 'native' THEN
        RETURN QUERY
        SELECT
            p_requested_resolution,
            'native'::TEXT,
            v_capture_interval_seconds,
            n.bucket_start,
            n.bucket_start + make_interval(secs => n.native_resolution_seconds),
            v_device_id,
            v_device_name,

            n.import_consumption_kwh,
            n.export_consumption_kwh,

            CASE
                WHEN NOT n.import_is_valid THEN 'INVALID_INTERVALS'
                WHEN n.import_reset_detected THEN 'RESET_DETECTED'
                WHEN n.import_quality_code = 'GAP' THEN 'GAPS_DETECTED'
                WHEN n.import_reconstruction_role IS NOT NULL THEN 'RECONSTRUCTED_TIMING'
                WHEN n.import_rollover_detected THEN 'ROLLOVER_DETECTED'
                ELSE 'GOOD'
            END,
            CASE
                WHEN NOT n.export_is_valid THEN 'INVALID_INTERVALS'
                WHEN n.export_reset_detected THEN 'RESET_DETECTED'
                WHEN n.export_quality_code = 'GAP' THEN 'GAPS_DETECTED'
                WHEN n.export_reconstruction_role IS NOT NULL THEN 'RECONSTRUCTED_TIMING'
                WHEN n.export_rollover_detected THEN 'ROLLOVER_DETECTED'
                ELSE 'GOOD'
            END,

            n.is_measured_interval::INT::BIGINT,
            (n.import_is_valid AND n.is_measured_interval AND NOT n.import_is_interior)::INT::BIGINT,
            (NOT n.import_is_valid AND n.is_measured_interval AND NOT n.import_is_interior)::INT::BIGINT,
            (n.export_is_valid AND n.is_measured_interval AND NOT n.export_is_interior)::INT::BIGINT,
            (NOT n.export_is_valid AND n.is_measured_interval AND NOT n.export_is_interior)::INT::BIGINT,
            CASE WHEN n.is_measured_interval THEN 1.0::NUMERIC ELSE 0.0::NUMERIC END,

            (n.gap_detected AND n.is_measured_interval)::INT::BIGINT,
            (n.reset_detected AND n.is_measured_interval)::INT::BIGINT,
            (n.rollover_detected AND n.is_measured_interval)::INT::BIGINT,
            n.invalid_detected::INT::BIGINT,

            n.bucket_start,
            n.bucket_start,
            FALSE,

            v_fallback_applied,
            v_fallback_reason

        FROM analytics.v_energy_consumption_native n
        WHERE n.device_id = v_device_id
          AND n.bucket_start >= v_effective_from
          AND n.bucket_start < p_to
        ORDER BY n.bucket_start;
        RETURN;
    END IF;

    -- ------------------------------------------------------------------
    -- 5m / 15m: analytics.v_energy_reporting_5min / _15min. Already
    -- tenant-scoped (security_barrier views joined to
    -- grafana_organization_map); device_id filter additionally applied
    -- since tenant was already proven above.
    -- ------------------------------------------------------------------

    IF v_actual IN ('5m', '15m') THEN
        RETURN QUERY
        SELECT
            p_requested_resolution,
            v_actual,
            v_capture_interval_seconds,
            r.bucket_start,
            r.bucket_start + (CASE WHEN v_actual = '5m' THEN INTERVAL '5 minutes' ELSE INTERVAL '15 minutes' END),
            v_device_id,
            v_device_name,

            r.import_consumption_kwh,
            r.export_consumption_kwh,

            CASE
                WHEN r.invalid_import_intervals > 0 THEN 'INVALID_INTERVALS'
                WHEN r.import_reset_intervals > 0 THEN 'RESET_DETECTED'
                WHEN r.import_gap_intervals > 0 THEN 'GAPS_DETECTED'
                WHEN r.import_reconstructed_intervals > 0 THEN 'RECONSTRUCTED_TIMING'
                WHEN r.import_rollover_intervals > 0 THEN 'ROLLOVER_DETECTED'
                ELSE 'GOOD'
            END,
            CASE
                WHEN r.invalid_export_intervals > 0 THEN 'INVALID_INTERVALS'
                WHEN r.export_reset_intervals > 0 THEN 'RESET_DETECTED'
                WHEN r.export_gap_intervals > 0 THEN 'GAPS_DETECTED'
                WHEN r.export_reconstructed_intervals > 0 THEN 'RECONSTRUCTED_TIMING'
                WHEN r.export_rollover_intervals > 0 THEN 'ROLLOVER_DETECTED'
                ELSE 'GOOD'
            END,

            r.source_interval_count,
            r.valid_import_intervals,
            r.invalid_import_intervals,
            r.valid_export_intervals,
            r.invalid_export_intervals,

            (
                r.source_interval_count::NUMERIC
                / NULLIF(
                    (CASE WHEN v_actual = '5m' THEN 300 ELSE 900 END) / v_capture_interval_seconds,
                    0
                )
            ),

            r.gap_interval_count,
            r.reset_interval_count,
            r.rollover_interval_count,
            r.invalid_interval_count,

            r.first_native_bucket_start,
            r.last_native_bucket_start,

            (
                r.source_interval_count < (CASE WHEN v_actual = '5m' THEN 300 ELSE 900 END) / v_capture_interval_seconds
                OR r.bucket_start < v_effective_from
                OR r.bucket_start + (CASE WHEN v_actual = '5m' THEN INTERVAL '5 minutes' ELSE INTERVAL '15 minutes' END) > p_to
            ),

            v_fallback_applied,
            v_fallback_reason

        FROM (
            SELECT * FROM analytics.v_energy_reporting_5min WHERE v_actual = '5m'
            UNION ALL
            SELECT * FROM analytics.v_energy_reporting_15min WHERE v_actual = '15m'
        ) r
        WHERE r.device_id = v_device_id
          AND r.grafana_org_id = p_grafana_org_id
          AND r.bucket_start >= date_bin(
                  (CASE WHEN v_actual = '5m' THEN INTERVAL '5 minutes' ELSE INTERVAL '15 minutes' END),
                  v_effective_from,
                  TIMESTAMPTZ '2000-01-01 00:00:00+00'
              )
          AND r.bucket_start < p_to
        ORDER BY r.bucket_start;
        RETURN;
    END IF;

    -- ------------------------------------------------------------------
    -- 1h: analytics.v_energy_reporting_hourly (migration 041). Already
    -- tenant-scoped, site-timezone-aware, aggregated exclusively from the
    -- validated 15-minute semantic contract. bucket_start is already a
    -- real TIMESTAMPTZ (site-local hour start), so this mirrors the 1d
    -- branch's direct-instant overlap filtering rather than 5m/15m's
    -- date_bin pre-filter.
    -- ------------------------------------------------------------------

    IF v_actual = '1h' THEN
        RETURN QUERY
        SELECT
            p_requested_resolution,
            '1h'::TEXT,
            v_capture_interval_seconds,
            h.bucket_start,
            h.bucket_start + INTERVAL '1 hour',
            v_device_id,
            v_device_name,

            h.import_consumption_kwh,
            h.export_consumption_kwh,

            CASE
                WHEN h.invalid_import_intervals > 0 THEN 'INVALID_INTERVALS'
                WHEN h.import_reset_intervals > 0 THEN 'RESET_DETECTED'
                WHEN h.import_gap_intervals > 0 THEN 'GAPS_DETECTED'
                WHEN h.import_reconstructed_intervals > 0 THEN 'RECONSTRUCTED_TIMING'
                WHEN h.import_rollover_intervals > 0 THEN 'ROLLOVER_DETECTED'
                ELSE 'GOOD'
            END,
            CASE
                WHEN h.invalid_export_intervals > 0 THEN 'INVALID_INTERVALS'
                WHEN h.export_reset_intervals > 0 THEN 'RESET_DETECTED'
                WHEN h.export_gap_intervals > 0 THEN 'GAPS_DETECTED'
                WHEN h.export_reconstructed_intervals > 0 THEN 'RECONSTRUCTED_TIMING'
                WHEN h.export_rollover_intervals > 0 THEN 'ROLLOVER_DETECTED'
                ELSE 'GOOD'
            END,

            h.source_interval_count::BIGINT,
            h.valid_import_intervals::BIGINT,
            h.invalid_import_intervals::BIGINT,
            h.valid_export_intervals::BIGINT,
            h.invalid_export_intervals::BIGINT,

            (h.source_interval_count::NUMERIC / NULLIF(3600 / v_capture_interval_seconds, 0)),

            h.gap_interval_count::BIGINT,
            h.reset_interval_count::BIGINT,
            h.rollover_interval_count::BIGINT,
            h.invalid_interval_count::BIGINT,

            h.first_native_bucket_start,
            h.last_native_bucket_start,

            (
                h.source_interval_count < 3600 / v_capture_interval_seconds
                OR h.bucket_start < v_effective_from
                OR h.bucket_start + INTERVAL '1 hour' > p_to
            ),

            v_fallback_applied,
            v_fallback_reason

        FROM analytics.v_energy_reporting_hourly h
        WHERE h.device_id = v_device_id
          AND h.grafana_org_id = p_grafana_org_id
          AND h.bucket_start < p_to
          AND h.bucket_start + INTERVAL '1 hour' > v_effective_from
        ORDER BY h.bucket_start;
        RETURN;
    END IF;

    -- ------------------------------------------------------------------
    -- 1d: analytics.v_energy_reporting_daily. Site-timezone-aware,
    -- aggregated from the validated 15-minute semantic contract.
    -- ------------------------------------------------------------------

    IF v_actual = '1d' THEN
        RETURN QUERY
        SELECT
            p_requested_resolution,
            '1d'::TEXT,
            v_capture_interval_seconds,
            (d.consumption_date::TIMESTAMP AT TIME ZONE d.site_timezone),
            (d.consumption_date::TIMESTAMP AT TIME ZONE d.site_timezone) + INTERVAL '1 day',
            v_device_id,
            v_device_name,

            d.import_consumption_kwh,
            d.export_consumption_kwh,

            CASE
                WHEN d.invalid_import_intervals > 0 THEN 'INVALID_INTERVALS'
                WHEN d.import_reset_intervals > 0 THEN 'RESET_DETECTED'
                WHEN d.import_gap_intervals > 0 THEN 'GAPS_DETECTED'
                WHEN d.import_reconstructed_intervals > 0 THEN 'RECONSTRUCTED_TIMING'
                WHEN d.import_rollover_intervals > 0 THEN 'ROLLOVER_DETECTED'
                ELSE 'GOOD'
            END,
            CASE
                WHEN d.invalid_export_intervals > 0 THEN 'INVALID_INTERVALS'
                WHEN d.export_reset_intervals > 0 THEN 'RESET_DETECTED'
                WHEN d.export_gap_intervals > 0 THEN 'GAPS_DETECTED'
                WHEN d.export_reconstructed_intervals > 0 THEN 'RECONSTRUCTED_TIMING'
                WHEN d.export_rollover_intervals > 0 THEN 'ROLLOVER_DETECTED'
                ELSE 'GOOD'
            END,

            d.source_interval_count::BIGINT,
            d.valid_import_intervals::BIGINT,
            d.invalid_import_intervals::BIGINT,
            d.valid_export_intervals::BIGINT,
            d.invalid_export_intervals::BIGINT,

            -- Nominal 86400s day length; does not correct for DST transitions.
            (d.source_interval_count::NUMERIC / NULLIF(86400 / v_capture_interval_seconds, 0)),

            d.gap_interval_count::BIGINT,
            d.reset_interval_count::BIGINT,
            d.rollover_interval_count::BIGINT,
            d.invalid_interval_count::BIGINT,

            d.first_native_bucket_start,
            d.last_native_bucket_start,

            (
                d.source_interval_count < 86400 / v_capture_interval_seconds
                OR (d.consumption_date::TIMESTAMP AT TIME ZONE d.site_timezone) < v_effective_from
                OR (d.consumption_date::TIMESTAMP AT TIME ZONE d.site_timezone) + INTERVAL '1 day' > p_to
            ),

            v_fallback_applied,
            v_fallback_reason

        FROM analytics.v_energy_reporting_daily d
        WHERE d.device_id = v_device_id
          AND d.grafana_org_id = p_grafana_org_id
          AND (d.consumption_date::TIMESTAMP AT TIME ZONE d.site_timezone) < p_to
          AND (d.consumption_date::TIMESTAMP AT TIME ZONE d.site_timezone) + INTERVAL '1 day' > v_effective_from
        ORDER BY d.consumption_date;
        RETURN;
    END IF;

    RAISE EXCEPTION
        'unhandled actual_resolution %; canonical reader has no dispatch '
        'branch for this resolution tier',
        v_actual;
END;
$function$;


-- ----------------------------------------------------------------------------
-- 9. Postconditions (catalog-only -- no scan of Energy data).
-- ----------------------------------------------------------------------------

DO $post$
DECLARE
    v_table   TEXT;
    v_missing TEXT;
    v_def     TEXT;
    v_bad     TEXT;
BEGIN
    -- Persisted tier counters.
    FOREACH v_table IN ARRAY ARRAY['energy_consumption_15min', 'energy_consumption_hourly', 'energy_consumption_daily']
    LOOP
        SELECT string_agg(c, ', ') INTO v_missing
        FROM unnest(ARRAY['reconstructed_interval_count', 'import_reconstructed_intervals',
                          'export_reconstructed_intervals', 'import_reconstructed_kwh',
                          'export_reconstructed_kwh']) AS c
        WHERE NOT EXISTS (
            SELECT 1 FROM information_schema.columns ic
            WHERE ic.table_schema = 'analytics' AND ic.table_name = v_table
              AND ic.column_name = c AND ic.is_nullable = 'NO' AND ic.column_default = '0'
        );
        IF v_missing IS NOT NULL THEN
            RAISE EXCEPTION 'Migration 269 postcondition failed: analytics.% missing NOT NULL DEFAULT 0 columns %', v_table, v_missing;
        END IF;

        v_def := pg_get_functiondef(format('analytics.refresh_%s(timestamptz,timestamptz)', v_table)::regprocedure);
        IF position('reconstructed_interval_count = ' IN regexp_replace(v_def, '\s+', ' ', 'g')) = 0
           OR position(v_table || '.export_reconstructed_kwh' IN v_def) = 0
           OR position('EXCLUDED.export_reconstructed_kwh' IN v_def) = 0 THEN
            RAISE EXCEPTION 'Migration 269 postcondition failed: analytics.refresh_% does not write/compare the reconstruction counters', v_table;
        END IF;
    END LOOP;

    -- View options and privileges preserved by CREATE OR REPLACE VIEW.
    SELECT string_agg(s.view_name, ', ') INTO v_bad
    FROM migration_269_view_state s
    JOIN pg_class c ON c.oid = s.view_name::regclass
    WHERE c.reloptions IS DISTINCT FROM s.reloptions
       OR c.relacl IS DISTINCT FROM s.relacl;
    IF v_bad IS NOT NULL THEN
        RAISE EXCEPTION 'Migration 269 postcondition failed: options/privileges changed on %', v_bad;
    END IF;
    IF (SELECT count(*) FROM migration_269_view_state) <> 10 THEN
        RAISE EXCEPTION 'Migration 269 postcondition failed: expected 10 snapshotted views';
    END IF;

    -- New view columns.
    SELECT string_agg(x.v || '.' || x.c, ', ') INTO v_missing
    FROM (VALUES
        ('v_energy_consumption_native', 'is_measured_interval'),
        ('v_energy_consumption_native', 'import_is_interior'),
        ('v_energy_consumption_native', 'export_is_interior'),
        ('v_energy_semantic_rollup_5min', 'reconstructed_interval_count'),
        ('v_energy_semantic_rollup_15min', 'export_reconstructed_kwh'),
        ('v_energy_reporting_5min', 'import_reconstructed_intervals'),
        ('v_energy_reporting_15min', 'export_reconstructed_intervals'),
        ('v_energy_reporting_hourly', 'reconstructed_interval_count'),
        ('v_energy_reporting_daily', 'reconstructed_interval_count'),
        ('v_energy_consumption_daily', 'reconstructed_interval_count'),
        ('v_asset_consumption_daily', 'reconstructed_interval_count'),
        ('v_asset_hierarchy_rollup_daily', 'direct_reconstructed_interval_count')
    ) AS x(v, c)
    WHERE NOT EXISTS (
        SELECT 1 FROM information_schema.columns ic
        WHERE ic.table_schema = 'analytics' AND ic.table_name = x.v AND ic.column_name = x.c
    );
    IF v_missing IS NOT NULL THEN
        RAISE EXCEPTION 'Migration 269 postcondition failed: missing view columns %', v_missing;
    END IF;

    -- Canonical read: every tier (native + 5m/15m + 1h + 1d, both directions)
    -- reports RECONSTRUCTED_TIMING; native counters are measured-only.
    v_def := pg_get_functiondef('analytics.get_canonical_energy_read(bigint,uuid,timestamptz,timestamptz,text,text)'::regprocedure);
    IF (length(v_def) - length(replace(v_def, 'RECONSTRUCTED_TIMING', ''))) / length('RECONSTRUCTED_TIMING') <> 8
       OR position('n.is_measured_interval::INT::BIGINT' IN v_def) = 0 THEN
        RAISE EXCEPTION 'Migration 269 postcondition failed: get_canonical_energy_read reconstruction handling incomplete';
    END IF;

    -- 15-minute reconcile counts measured native rows only.
    v_def := pg_get_functiondef('analytics.reconcile_energy_deficits(text,timestamptz,timestamptz,interval,integer)'::regprocedure);
    IF position('count(*) FILTER (WHERE is_measured)' IN v_def) = 0 THEN
        RAISE EXCEPTION 'Migration 269 postcondition failed: reconcile_energy_deficits 15-minute branch not measured-only';
    END IF;

    -- The switch is untouched (ADR-020: still OFF).
    IF config.energy_reconstruction_enabled(NULL, NULL) IS DISTINCT FROM FALSE THEN
        RAISE EXCEPTION 'Migration 269 postcondition failed: reconstruction switch is not OFF';
    END IF;

    RAISE NOTICE 'Migration 269: all postconditions passed (Energy read layers distinguish reconstructed timing; outputs unchanged while no reconstructed rows exist).';
END;
$post$;
