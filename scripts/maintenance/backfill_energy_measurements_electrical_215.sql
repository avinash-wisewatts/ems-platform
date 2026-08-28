-- ============================================================================
-- File:
--   scripts/maintenance/backfill_energy_measurements_electrical_215.sql
--
-- Purpose:
--   Recover the 20 electrical columns of telemetry.energy_measurements that
--   migration 207 left NULL for every row inserted after 2026-08-28 01:12:36
--   IST (first NULL bucket 2026-08-28 01:09:00 IST), from the intact source
--   in telemetry.normalized_points. Run ONCE, AFTER migration 215 is deployed
--   and its routing fix is verified.
--
--   DO NOT RUN THIS UNTIL:
--     * migration 215 has been applied to the target database, AND
--     * a fresh post-215 energy_measurements bucket has been confirmed to
--       carry non-NULL active_power_total_w for a representative meter.
--
--   Idempotent: only writes cells that are still NULL, only from
--   :p_from onward, never overwrites a non-NULL value. Re-running is a no-op.
--
-- Usage (STAGING, explicitly authorized, read the counts it prints):
--   psql ... -v p_from="2026-08-28 01:09:00+05:30" \
--            -v p_to="<a recent, safely-closed bucket>" \
--            -f scripts/maintenance/backfill_energy_measurements_electrical_215.sql
--
--   Run it once per bounded [p_from, p_to) window (e.g. hour by hour) so each
--   statement stays small; the guards make any overlap harmless.
--
--   NOT for production without separate authorization.
-- ============================================================================

\set ON_ERROR_STOP on
\pset pager off

\if :{?p_from}
\else
  \echo 'ERROR: pass -v p_from="2026-08-28 01:09:00+05:30"'
  \quit 1
\endif
\if :{?p_to}
\else
  \echo 'ERROR: pass -v p_to="<recent closed bucket timestamptz>"'
  \quit 1
\endif

BEGIN;

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';
-- Never let this session write anything else by accident.
SET LOCAL search_path = pg_catalog, telemetry, metadata, config;

-- ---- pre-flight -----------------------------------------------------------
DO $preflight$
DECLARE
    v_loader_ok BOOLEAN;
BEGIN
    -- migration 215 must be in place: the loader must resolve by name, not UUID
    SELECT pg_get_functiondef('telemetry.load_energy_measurements_incremental(interval,interval)'::regprocedure)
             !~ 'logical_point_id[[:space:]]*(=|IN)[[:space:]]*\(?[[:space:]]*''[0-9a-f]{8}-[0-9a-f]{4}-'
      INTO v_loader_ok;
    IF NOT v_loader_ok THEN
        RAISE EXCEPTION
          'Refusing to backfill: telemetry.load_energy_measurements_incremental still resolves electrical signals by hard-coded UUID (migration 215 not applied).';
    END IF;
END
$preflight$;

-- ---- source projection (identical semantics to the migration-215 loader) --
-- One row per (device_id, event_time); electrical signals resolved by NAME.
CREATE TEMP TABLE _bf_src ON COMMIT DROP AS
WITH pc AS (
    SELECT np.device_id, np.event_time, np.logical_point, np.numeric_value,
           np.quality_code, np.site_id, np.source_timestamp_hint,
           d.profile_id, dp.profile_code
    FROM (
        SELECT np.*, np.event_time AS source_timestamp_hint
        FROM telemetry.normalized_points np
        WHERE np.event_time >= :'p_from'::timestamptz
          AND np.event_time <  :'p_to'::timestamptz
    ) np
    JOIN metadata.devices d       ON d.id = np.device_id
    LEFT JOIN config.device_profiles dp ON dp.id = d.profile_id
),
rs AS (
    SELECT pc.*, ers.scale_to_normalized_unit
    FROM pc
    LEFT JOIN config.energy_register_semantics ers
      ON ers.profile_id = pc.profile_id
     -- register semantics is keyed by logical_point_id in-DB; resolve it by
     -- NAME so this backfill has no UUID dependency either
     AND ers.logical_point_id = (
           SELECT lp.id FROM metadata.logical_points lp
           WHERE lp.name = pc.logical_point LIMIT 1)
     AND ers.is_active
)
SELECT
    rs.device_id,
    rs.site_id,
    b.bucket_start AS bucket_start,
    max(rs.numeric_value) FILTER (WHERE rs.logical_point = ANY (ARRAY['ACTIVE_POWER_TOTAL','ENERGY_ACTIVE_POWER_TOTAL']) AND rs.quality_code='GOOD' AND rs.profile_code='ENERGY_METER_ENISCOPE_V1')::double precision AS active_power_total_w,
    max(rs.numeric_value) FILTER (WHERE rs.logical_point = ANY (ARRAY['ACTIVE_POWER_L1','ENERGY_ACTIVE_POWER_L1']) AND rs.quality_code='GOOD' AND rs.profile_code='ENERGY_METER_ENISCOPE_V1')::double precision AS active_power_l1_w,
    max(rs.numeric_value) FILTER (WHERE rs.logical_point = ANY (ARRAY['ACTIVE_POWER_L2','ENERGY_ACTIVE_POWER_L2']) AND rs.quality_code='GOOD' AND rs.profile_code='ENERGY_METER_ENISCOPE_V1')::double precision AS active_power_l2_w,
    max(rs.numeric_value) FILTER (WHERE rs.logical_point = ANY (ARRAY['ACTIVE_POWER_L3','ENERGY_ACTIVE_POWER_L3']) AND rs.quality_code='GOOD' AND rs.profile_code='ENERGY_METER_ENISCOPE_V1')::double precision AS active_power_l3_w,
    max(rs.numeric_value) FILTER (WHERE rs.logical_point = ANY (ARRAY['REACTIVE_POWER_TOTAL','ENERGY_REACTIVE_POWER_TOTAL']) AND rs.quality_code='GOOD' AND rs.profile_code='ENERGY_METER_ENISCOPE_V1')::double precision AS reactive_power_total_var,
    max(rs.numeric_value) FILTER (WHERE rs.logical_point = ANY (ARRAY['REACTIVE_POWER_L1','ENERGY_REACTIVE_POWER_L1']) AND rs.quality_code='GOOD' AND rs.profile_code='ENERGY_METER_ENISCOPE_V1')::double precision AS reactive_power_l1_var,
    max(rs.numeric_value) FILTER (WHERE rs.logical_point = ANY (ARRAY['REACTIVE_POWER_L2','ENERGY_REACTIVE_POWER_L2']) AND rs.quality_code='GOOD' AND rs.profile_code='ENERGY_METER_ENISCOPE_V1')::double precision AS reactive_power_l2_var,
    max(rs.numeric_value) FILTER (WHERE rs.logical_point = ANY (ARRAY['REACTIVE_POWER_L3','ENERGY_REACTIVE_POWER_L3']) AND rs.quality_code='GOOD' AND rs.profile_code='ENERGY_METER_ENISCOPE_V1')::double precision AS reactive_power_l3_var,
    max(rs.numeric_value) FILTER (WHERE rs.logical_point = ANY (ARRAY['APPARENT_POWER_TOTAL','ENERGY_APPARENT_POWER_TOTAL']) AND rs.quality_code='GOOD' AND rs.profile_code='ENERGY_METER_ENISCOPE_V1')::double precision AS apparent_power_total_va,
    max(rs.numeric_value) FILTER (WHERE rs.logical_point = ANY (ARRAY['APPARENT_POWER_L1','ENERGY_APPARENT_POWER_L1']) AND rs.quality_code='GOOD' AND rs.profile_code='ENERGY_METER_ENISCOPE_V1')::double precision AS apparent_power_l1_va,
    max(rs.numeric_value) FILTER (WHERE rs.logical_point = ANY (ARRAY['APPARENT_POWER_L2','ENERGY_APPARENT_POWER_L2']) AND rs.quality_code='GOOD' AND rs.profile_code='ENERGY_METER_ENISCOPE_V1')::double precision AS apparent_power_l2_va,
    max(rs.numeric_value) FILTER (WHERE rs.logical_point = ANY (ARRAY['APPARENT_POWER_L3','ENERGY_APPARENT_POWER_L3']) AND rs.quality_code='GOOD' AND rs.profile_code='ENERGY_METER_ENISCOPE_V1')::double precision AS apparent_power_l3_va,
    max(rs.numeric_value * rs.scale_to_normalized_unit) FILTER (WHERE rs.logical_point = ANY (ARRAY['REACTIVE_ENERGY_TOTAL','ENERGY_REACTIVE_ENERGY_TOTAL']) AND rs.quality_code='GOOD' AND rs.scale_to_normalized_unit IS NOT NULL) AS reactive_energy_total_varh,
    max(rs.numeric_value * rs.scale_to_normalized_unit) FILTER (WHERE rs.logical_point = ANY (ARRAY['REACTIVE_ENERGY_L1','ENERGY_REACTIVE_ENERGY_L1']) AND rs.quality_code='GOOD' AND rs.scale_to_normalized_unit IS NOT NULL) AS reactive_energy_l1_varh,
    max(rs.numeric_value * rs.scale_to_normalized_unit) FILTER (WHERE rs.logical_point = ANY (ARRAY['REACTIVE_ENERGY_L2','ENERGY_REACTIVE_ENERGY_L2']) AND rs.quality_code='GOOD' AND rs.scale_to_normalized_unit IS NOT NULL) AS reactive_energy_l2_varh,
    max(rs.numeric_value * rs.scale_to_normalized_unit) FILTER (WHERE rs.logical_point = ANY (ARRAY['REACTIVE_ENERGY_L3','ENERGY_REACTIVE_ENERGY_L3']) AND rs.quality_code='GOOD' AND rs.scale_to_normalized_unit IS NOT NULL) AS reactive_energy_l3_varh,
    max(rs.numeric_value * rs.scale_to_normalized_unit) FILTER (WHERE rs.logical_point = ANY (ARRAY['APPARENT_ENERGY_TOTAL','ENERGY_APPARENT_ENERGY_TOTAL']) AND rs.quality_code='GOOD' AND rs.scale_to_normalized_unit IS NOT NULL) AS apparent_energy_total_vah,
    max(rs.numeric_value * rs.scale_to_normalized_unit) FILTER (WHERE rs.logical_point = ANY (ARRAY['APPARENT_ENERGY_L1','ENERGY_APPARENT_ENERGY_L1']) AND rs.quality_code='GOOD' AND rs.scale_to_normalized_unit IS NOT NULL) AS apparent_energy_l1_vah,
    max(rs.numeric_value * rs.scale_to_normalized_unit) FILTER (WHERE rs.logical_point = ANY (ARRAY['APPARENT_ENERGY_L2','ENERGY_APPARENT_ENERGY_L2']) AND rs.quality_code='GOOD' AND rs.scale_to_normalized_unit IS NOT NULL) AS apparent_energy_l2_vah,
    max(rs.numeric_value * rs.scale_to_normalized_unit) FILTER (WHERE rs.logical_point = ANY (ARRAY['APPARENT_ENERGY_L3','ENERGY_APPARENT_ENERGY_L3']) AND rs.quality_code='GOOD' AND rs.scale_to_normalized_unit IS NOT NULL) AS apparent_energy_l3_vah
FROM rs
CROSS JOIN LATERAL telemetry.resolve_site_capture_bucket(rs.site_id, rs.event_time) AS b
GROUP BY rs.device_id, rs.site_id, b.bucket_start;

\echo '--- source projection built (rows) ---'
SELECT count(*) AS projected_buckets,
       count(active_power_total_w) AS have_ap_total
FROM _bf_src;

\echo '--- energy_measurements cells still NULL in window, BEFORE ---'
SELECT count(*) AS rows_in_window,
       count(*) FILTER (WHERE active_power_total_w IS NULL)  AS null_ap_total,
       count(*) FILTER (WHERE apparent_energy_total_vah IS NULL) AS null_appe_total
FROM telemetry.energy_measurements
WHERE bucket_start >= :'p_from'::timestamptz AND bucket_start < :'p_to'::timestamptz;

-- ---- the guarded fill --------------------------------------------------
-- Only NULL target cells; only from p_from; existing values untouched.
UPDATE telemetry.energy_measurements em
SET
    active_power_total_w       = COALESCE(em.active_power_total_w,       s.active_power_total_w),
    active_power_l1_w          = COALESCE(em.active_power_l1_w,          s.active_power_l1_w),
    active_power_l2_w          = COALESCE(em.active_power_l2_w,          s.active_power_l2_w),
    active_power_l3_w          = COALESCE(em.active_power_l3_w,          s.active_power_l3_w),
    reactive_power_total_var   = COALESCE(em.reactive_power_total_var,   s.reactive_power_total_var),
    reactive_power_l1_var      = COALESCE(em.reactive_power_l1_var,      s.reactive_power_l1_var),
    reactive_power_l2_var      = COALESCE(em.reactive_power_l2_var,      s.reactive_power_l2_var),
    reactive_power_l3_var      = COALESCE(em.reactive_power_l3_var,      s.reactive_power_l3_var),
    apparent_power_total_va    = COALESCE(em.apparent_power_total_va,    s.apparent_power_total_va),
    apparent_power_l1_va       = COALESCE(em.apparent_power_l1_va,       s.apparent_power_l1_va),
    apparent_power_l2_va       = COALESCE(em.apparent_power_l2_va,       s.apparent_power_l2_va),
    apparent_power_l3_va       = COALESCE(em.apparent_power_l3_va,       s.apparent_power_l3_va),
    reactive_energy_total_varh = COALESCE(em.reactive_energy_total_varh, s.reactive_energy_total_varh),
    reactive_energy_l1_varh    = COALESCE(em.reactive_energy_l1_varh,    s.reactive_energy_l1_varh),
    reactive_energy_l2_varh    = COALESCE(em.reactive_energy_l2_varh,    s.reactive_energy_l2_varh),
    reactive_energy_l3_varh    = COALESCE(em.reactive_energy_l3_varh,    s.reactive_energy_l3_varh),
    apparent_energy_total_vah  = COALESCE(em.apparent_energy_total_vah,  s.apparent_energy_total_vah),
    apparent_energy_l1_vah     = COALESCE(em.apparent_energy_l1_vah,     s.apparent_energy_l1_vah),
    apparent_energy_l2_vah     = COALESCE(em.apparent_energy_l2_vah,     s.apparent_energy_l2_vah),
    apparent_energy_l3_vah     = COALESCE(em.apparent_energy_l3_vah,     s.apparent_energy_l3_vah)
FROM _bf_src s
WHERE em.device_id    = s.device_id
  AND em.bucket_start = s.bucket_start
  AND em.bucket_start >= :'p_from'::timestamptz
  AND em.bucket_start <  :'p_to'::timestamptz
  -- touch the row only if at least one target cell is NULL and we have a value
  AND (
        (em.active_power_total_w IS NULL AND s.active_power_total_w IS NOT NULL) OR
        (em.active_power_l1_w IS NULL AND s.active_power_l1_w IS NOT NULL) OR
        (em.active_power_l2_w IS NULL AND s.active_power_l2_w IS NOT NULL) OR
        (em.active_power_l3_w IS NULL AND s.active_power_l3_w IS NOT NULL) OR
        (em.reactive_power_total_var IS NULL AND s.reactive_power_total_var IS NOT NULL) OR
        (em.reactive_power_l1_var IS NULL AND s.reactive_power_l1_var IS NOT NULL) OR
        (em.reactive_power_l2_var IS NULL AND s.reactive_power_l2_var IS NOT NULL) OR
        (em.reactive_power_l3_var IS NULL AND s.reactive_power_l3_var IS NOT NULL) OR
        (em.apparent_power_total_va IS NULL AND s.apparent_power_total_va IS NOT NULL) OR
        (em.apparent_power_l1_va IS NULL AND s.apparent_power_l1_va IS NOT NULL) OR
        (em.apparent_power_l2_va IS NULL AND s.apparent_power_l2_va IS NOT NULL) OR
        (em.apparent_power_l3_va IS NULL AND s.apparent_power_l3_va IS NOT NULL) OR
        (em.reactive_energy_total_varh IS NULL AND s.reactive_energy_total_varh IS NOT NULL) OR
        (em.reactive_energy_l1_varh IS NULL AND s.reactive_energy_l1_varh IS NOT NULL) OR
        (em.reactive_energy_l2_varh IS NULL AND s.reactive_energy_l2_varh IS NOT NULL) OR
        (em.reactive_energy_l3_varh IS NULL AND s.reactive_energy_l3_varh IS NOT NULL) OR
        (em.apparent_energy_total_vah IS NULL AND s.apparent_energy_total_vah IS NOT NULL) OR
        (em.apparent_energy_l1_vah IS NULL AND s.apparent_energy_l1_vah IS NOT NULL) OR
        (em.apparent_energy_l2_vah IS NULL AND s.apparent_energy_l2_vah IS NOT NULL) OR
        (em.apparent_energy_l3_vah IS NULL AND s.apparent_energy_l3_vah IS NOT NULL)
      );

\echo '--- rows updated by this batch ---'
-- (psql prints the UPDATE tag; also re-check the window)
SELECT count(*) AS rows_in_window,
       count(*) FILTER (WHERE active_power_total_w IS NULL)  AS null_ap_total_after,
       count(*) FILTER (WHERE apparent_energy_total_vah IS NULL) AS null_appe_total_after
FROM telemetry.energy_measurements
WHERE bucket_start >= :'p_from'::timestamptz AND bucket_start < :'p_to'::timestamptz;

-- Review the counts above. If they look right:
--   COMMIT;
-- otherwise:
--   ROLLBACK;
-- This script intentionally does NOT auto-commit.
\echo '>>> Review counts, then type  COMMIT;  or  ROLLBACK;'
