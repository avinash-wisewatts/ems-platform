-- ============================================================================
-- Migration 215
-- Restore name-based resolution of the 20 electrical logical points in the
-- energy routing path; retire the hard-coded canonical logical_point_id
-- coupling introduced by migration 207 (and, for
-- v_energy_measurements_full_resolution, by migration 174).
--
-- CONFIRMED REGRESSION (read-only staging investigations, 2026-08-28):
--   Migration 207 (applied to staging 2026-08-28 01:12:36 IST) rewrote
--   telemetry.load_energy_measurements_incremental so that 20 columns --
--     active_power_{total,l1,l2,l3}_w, reactive_power_{total,l1,l2,l3}_var,
--     apparent_power_{total,l1,l2,l3}_va, reactive_energy_{total,l1,l2,l3}_varh,
--     apparent_energy_{total,l1,l2,l3}_vah
--   -- are selected with predicates of the form
--       rs.logical_point_id = '<canonical-uuid>'::uuid
--   e.g. active_power_total_w <- '44652ee7-57fb-4174-b4e9-4992323056fd'.
--   Those canonical UUIDs are a production-shaped identity set planted by
--   seeds/reference/13_03_logical_points_electrical_baseline.sql for
--   migration 174. They do NOT exist on databases whose electrical logical
--   points were provisioned with locally-generated UUIDs
--   (metadata.logical_points.id DEFAULT gen_random_uuid()): on staging
--   ACTIVE_POWER_TOTAL is '9180a8ba-0944-411c-9a08-65db023a391b', and none of
--   the 20 canonical UUIDs appear in metadata.logical_points,
--   telemetry.normalized_points, or config.profile_field_mapping.
--   Result: every FILTER (WHERE logical_point_id = <absent uuid>) yields NULL,
--   so all 20 columns become NULL for every energy_measurements row inserted
--   after the 207 deploy (first NULL bucket 2026-08-28 01:09 IST; the
--   ON CONFLICT ... COALESCE(EXCLUDED.x, existing.x) upsert preserves the last
--   pre-207 values, last good bucket 01:08). Fleet-wide: 22/22
--   ENERGY_METER_ENISCOPE_V1 meters, org c4bde6d1-..., 1 site.
--   telemetry.normalized_points is intact and current -- transformation loss,
--   not data loss. analytics.get_grafana_explorer_intervals is unaffected
--   because it already resolves by logical-point NAME.
--
-- IDENTITY CONTRACT (Canonical Metric Identity Review, accepted):
--   * metadata.logical_points.NAME is the authoritative, globally-unique,
--     vendor-neutral semantic identity of a metric (enforced by
--     metadata.uq_logical_points_name).
--   * metadata.logical_points.ID is a DATABASE-LOCAL surrogate key: stable
--     within a database (FK target for config.profile_field_mapping,
--     config.device_point_configuration, config.energy_register_semantics;
--     stamped onto telemetry.normalized_points) but NOT portable across
--     environments, and MUST NOT appear as a literal in any object that
--     selects/filters a metric.
--   * Routing resolves electrical signals the same way the 25+ unaffected
--     columns of this very function already do: by rs.logical_point = <NAME>
--     (+ rs.profile_code for the profile-scoped power columns;
--     + rs.scale_to_normalized_unit IS NOT NULL for the register-scaled
--     reactive/apparent energy columns), NOT by UUID.
--
-- WHAT THIS MIGRATION DOES
--   1. CREATE OR REPLACE telemetry.load_energy_measurements_incremental
--      (interval, interval) -- byte-for-byte the migration-207 body EXCEPT the
--      20 electrical predicates, each changed from
--        rs.logical_point_id = '<uuid>'::uuid
--      to
--        rs.logical_point = ANY (ARRAY['<canonical-name>', '<pre-174-name>'])
--      The two-element array bridges the migration-174 rename
--      (ENERGY_ACTIVE_POWER_TOTAL -> ACTIVE_POWER_TOTAL, etc.) by NAME instead
--      of by UUID, so pre-174-text history and canonical-text current rows
--      both route on every environment regardless of local UUID values.
--      No signature change => CREATE OR REPLACE only, no DROP;
--      postgres/jobs/* untouched; assert_job_schedule_canonical unaffected.
--      p_max_window / wrapper / pipeline_state / advisory-lock / ON CONFLICT /
--      correction-deadline / EXCEPTION-re-RAISE semantics are reproduced
--      verbatim from migration 207.
--   2. CREATE OR REPLACE telemetry.v_energy_measurements_full_resolution with
--      the analogous change. The deployed definition currently filters these
--      20 signals by their pre-174 names only (rs.logical_point =
--      'ENERGY_ACTIVE_POWER_TOTAL' ...), which matches nothing on a renamed
--      database -- a pre-existing latent breakage of this view for the same
--      20 signals. The ARRAY[...] form fixes both.
--   3. CREATE UNIQUE INDEX IF NOT EXISTS metadata.uq_logical_points_name --
--      idempotent forward guard so the name-is-identity contract exists on any
--      database that predates seeds/reference/63_environment_logical_points.sql
--      (where it is created today). Fresh installs also gain it earlier, from
--      postgres/ddl/04_metadata.sql (this migration's companion change).
--
-- NOT TOUCHED: migration 174 / 207 files (checksum-locked -- history preserved,
--   not rewritten); seeds/reference/13_03 (still migration 174's fresh-install
--   precondition fixture; inert for identity after this migration);
--   telemetry.load_environment_measurements_incremental and the two
--   run_*_routing_job wrappers (migration 207, correct); any CAGG / analytics
--   function / Grafana query; telemetry.normalized_points data;
--   config.profile_field_mapping / device_point_configuration rows; Phase 2
--   reconciliation (separate track). Historical NULLs in energy_measurements
--   are recovered by a separately-authorized guarded backfill
--   (scripts/maintenance/backfill_energy_measurements_electrical_215.sql)
--   AFTER this migration is deployed and verified.
-- ============================================================================

BEGIN;

-- ----------------------------------------------------------------------------
-- 1. Energy routing loader: resolve the 20 electrical signals by NAME.
--    Verbatim migration-207 body except the 20 electrical FILTER predicates.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE telemetry.load_energy_measurements_incremental(IN p_overlap interval DEFAULT '00:15:00'::interval, IN p_max_window interval DEFAULT NULL)
 LANGUAGE plpgsql
AS $procedure$
DECLARE
  v_pipeline_name CONSTANT TEXT := 'energy_measurements';
  v_previous_checkpoint TIMESTAMPTZ;
  v_window_start TIMESTAMPTZ;
  v_window_end TIMESTAMPTZ;
  v_affected_rows BIGINT := 0;
  v_lock_acquired BOOLEAN;
  v_now TIMESTAMPTZ := clock_timestamp();
BEGIN
  IF p_overlap IS NULL OR p_overlap < INTERVAL '0 seconds' THEN
    RAISE EXCEPTION 'p_overlap must be zero or a positive interval; received %', p_overlap;
  END IF;

  -- Migration 207: reject a non-positive explicit bound. NULL (the
  -- default, and what a direct/manual invocation passes) means "no
  -- bound" -- byte-for-byte the pre-207 behaviour.
  IF p_max_window IS NOT NULL AND p_max_window <= INTERVAL '0 seconds' THEN
    RAISE EXCEPTION 'p_max_window must be positive when supplied; received %', p_max_window;
  END IF;

  SELECT pg_try_advisory_xact_lock(hashtextextended('telemetry.load_energy_measurements_incremental',0))
  INTO v_lock_acquired;
  IF NOT v_lock_acquired THEN
    UPDATE telemetry.pipeline_state SET last_status='SKIPPED_LOCKED',last_error=NULL,updated_at=now()
    WHERE pipeline_name=v_pipeline_name;
    RETURN;
  END IF;

  SELECT last_received_at INTO v_previous_checkpoint
  FROM telemetry.pipeline_state WHERE pipeline_name=v_pipeline_name FOR UPDATE;

  UPDATE telemetry.pipeline_state
  SET last_started_at=clock_timestamp(),last_status='RUNNING',last_error=NULL,updated_at=now()
  WHERE pipeline_name=v_pipeline_name;

  SELECT max(platform_received_at) INTO v_window_end
  FROM telemetry.normalized_points
  WHERE platform_received_at IS NOT NULL;
  IF v_window_end IS NULL THEN
    UPDATE telemetry.pipeline_state
    SET last_completed_at=clock_timestamp(),last_inserted_rows=0,last_status='NO_SOURCE_DATA',last_error=NULL,updated_at=now()
    WHERE pipeline_name=v_pipeline_name;
    RETURN;
  END IF;

  -- Migration 207: cap the forward processing boundary to the previous
  -- checkpoint plus p_max_window when a caller supplies one and a
  -- previous checkpoint already exists. NULL (the default) leaves
  -- v_window_end exactly as computed above -- byte-for-byte the pre-207
  -- behaviour. The scheduled wrapper telemetry.run_energy_routing_job
  -- passes a bounded value so an unattended multi-hour
  -- normalized_points backlog self-drains over successive 1-minute runs
  -- instead of being attempted as one unbounded, max_runtime-exceeding
  -- transaction -- the job-1000 stall class, fixed for normalization by
  -- migration 205 and extended here to energy/environment routing. A
  -- direct manual CALL that omits the argument (or passes NULL) still
  -- performs unrestricted catch-up. Advisory lock, checkpoint keying,
  -- overlap semantics, the routing/calculation SQL below, and the
  -- EXCEPTION-rolls-back-the-watermark contract are all unchanged.
  IF p_max_window IS NOT NULL AND v_previous_checkpoint IS NOT NULL THEN
    v_window_end := LEAST(v_window_end, v_previous_checkpoint + p_max_window);
  END IF;

  -- Late-arriving source timestamps still have a new platform receipt time.
  -- A one-minute replay is sufficient to protect timestamp-boundary races
  -- without rescanning the full late-arrival tolerance on every run.
  p_overlap := LEAST(p_overlap, INTERVAL '1 minute');

  v_window_start := CASE WHEN v_previous_checkpoint IS NULL THEN '-infinity'::timestamptz ELSE v_previous_checkpoint-p_overlap END;

  WITH window_events AS MATERIALIZED
  (
    SELECT np.device_id,np.event_time,MAX(np.platform_received_at) AS platform_received_at
    FROM telemetry.normalized_points np
    WHERE np.platform_received_at > v_window_start
      AND np.platform_received_at <= v_window_end
    GROUP BY np.device_id,np.event_time
  ),
  full_resolution AS MATERIALIZED
  (
WITH profile_context AS
(
  SELECT
    np.event_time,
    np.organization_id,
    np.site_id,
    np.gateway_id,
    np.device_id,
    np.logical_point_id,
    np.device_uid,
    np.logical_point,
    np.raw_field_name,
    np.raw_value,
    np.numeric_value,
    np.quality_code,
    np.mapping_source,
    np.created_at,
    np.platform_received_at,
    np.raw_message_id,
    d.profile_id,
    dp.profile_code
  FROM window_events we
  CROSS JOIN LATERAL
  (
    SELECT src_np.*
    FROM telemetry.normalized_points src_np
    WHERE src_np.device_id = we.device_id
      AND src_np.event_time = we.event_time
    OFFSET 0
  ) np
  JOIN metadata.devices d ON d.id=np.device_id
  LEFT JOIN config.device_profiles dp ON dp.id=d.profile_id
),
register_scales AS
(
  SELECT pc.*, ers.scale_to_normalized_unit
  FROM profile_context pc
  LEFT JOIN config.energy_register_semantics ers
    ON ers.profile_id=pc.profile_id
   AND ers.logical_point_id=pc.logical_point_id
   AND ers.is_active=TRUE
),
pivoted AS
(
  SELECT
        rs.event_time AS received_at,
        rs.event_time AS source_timestamp,
        rs.organization_id,
        rs.site_id,
        rs.gateway_id,
        rs.device_id,
        NULL::UUID AS asset_id,

        MAX(rs.numeric_value * rs.scale_to_normalized_unit) FILTER (
            WHERE rs.logical_point = 'ENERGY_IMPORT_TOTAL'
              AND rs.quality_code = 'GOOD'
              AND rs.scale_to_normalized_unit IS NOT NULL
        ) AS import_energy_total_wh,

        MAX(rs.numeric_value * rs.scale_to_normalized_unit) FILTER (
            WHERE rs.logical_point = 'ENERGY_IMPORT_L1'
              AND rs.quality_code = 'GOOD'
              AND rs.scale_to_normalized_unit IS NOT NULL
        ) AS import_energy_l1_wh,

        MAX(rs.numeric_value * rs.scale_to_normalized_unit) FILTER (
            WHERE rs.logical_point = 'ENERGY_IMPORT_L2'
              AND rs.quality_code = 'GOOD'
              AND rs.scale_to_normalized_unit IS NOT NULL
        ) AS import_energy_l2_wh,

        MAX(rs.numeric_value * rs.scale_to_normalized_unit) FILTER (
            WHERE rs.logical_point = 'ENERGY_IMPORT_L3'
              AND rs.quality_code = 'GOOD'
              AND rs.scale_to_normalized_unit IS NOT NULL
        ) AS import_energy_l3_wh,

        MAX(rs.numeric_value * rs.scale_to_normalized_unit) FILTER (
            WHERE rs.logical_point = 'ENERGY_EXPORT_TOTAL'
              AND rs.quality_code = 'GOOD'
              AND rs.scale_to_normalized_unit IS NOT NULL
        ) AS export_energy_total_wh,

        MAX(rs.numeric_value * rs.scale_to_normalized_unit) FILTER (
            WHERE rs.logical_point = 'ENERGY_EXPORT_L1'
              AND rs.quality_code = 'GOOD'
              AND rs.scale_to_normalized_unit IS NOT NULL
        ) AS export_energy_l1_wh,

        MAX(rs.numeric_value * rs.scale_to_normalized_unit) FILTER (
            WHERE rs.logical_point = 'ENERGY_EXPORT_L2'
              AND rs.quality_code = 'GOOD'
              AND rs.scale_to_normalized_unit IS NOT NULL
        ) AS export_energy_l2_wh,

        MAX(rs.numeric_value * rs.scale_to_normalized_unit) FILTER (
            WHERE rs.logical_point = 'ENERGY_EXPORT_L3'
              AND rs.quality_code = 'GOOD'
              AND rs.scale_to_normalized_unit IS NOT NULL
        ) AS export_energy_l3_wh,

        MAX(rs.numeric_value * rs.scale_to_normalized_unit) FILTER (
            WHERE rs.logical_point = ANY (ARRAY['REACTIVE_ENERGY_TOTAL', 'ENERGY_REACTIVE_ENERGY_TOTAL'])
              AND rs.quality_code = 'GOOD'
              AND rs.scale_to_normalized_unit IS NOT NULL
        ) AS reactive_energy_total_varh,

        MAX(rs.numeric_value * rs.scale_to_normalized_unit) FILTER (
            WHERE rs.logical_point = ANY (ARRAY['REACTIVE_ENERGY_L1', 'ENERGY_REACTIVE_ENERGY_L1'])
              AND rs.quality_code = 'GOOD'
              AND rs.scale_to_normalized_unit IS NOT NULL
        ) AS reactive_energy_l1_varh,

        MAX(rs.numeric_value * rs.scale_to_normalized_unit) FILTER (
            WHERE rs.logical_point = ANY (ARRAY['REACTIVE_ENERGY_L2', 'ENERGY_REACTIVE_ENERGY_L2'])
              AND rs.quality_code = 'GOOD'
              AND rs.scale_to_normalized_unit IS NOT NULL
        ) AS reactive_energy_l2_varh,

        MAX(rs.numeric_value * rs.scale_to_normalized_unit) FILTER (
            WHERE rs.logical_point = ANY (ARRAY['REACTIVE_ENERGY_L3', 'ENERGY_REACTIVE_ENERGY_L3'])
              AND rs.quality_code = 'GOOD'
              AND rs.scale_to_normalized_unit IS NOT NULL
        ) AS reactive_energy_l3_varh,

        MAX(rs.numeric_value * rs.scale_to_normalized_unit) FILTER (
            WHERE rs.logical_point = 'ENERGY_REACTIVE_EXPORT_TOTAL'
              AND rs.quality_code = 'GOOD'
              AND rs.scale_to_normalized_unit IS NOT NULL
        ) AS reactive_export_energy_total_varh,

        MAX(rs.numeric_value * rs.scale_to_normalized_unit) FILTER (
            WHERE rs.logical_point = 'ENERGY_REACTIVE_EXPORT_L1'
              AND rs.quality_code = 'GOOD'
              AND rs.scale_to_normalized_unit IS NOT NULL
        ) AS reactive_export_energy_l1_varh,

        MAX(rs.numeric_value * rs.scale_to_normalized_unit) FILTER (
            WHERE rs.logical_point = 'ENERGY_REACTIVE_EXPORT_L2'
              AND rs.quality_code = 'GOOD'
              AND rs.scale_to_normalized_unit IS NOT NULL
        ) AS reactive_export_energy_l2_varh,

        MAX(rs.numeric_value * rs.scale_to_normalized_unit) FILTER (
            WHERE rs.logical_point = 'ENERGY_REACTIVE_EXPORT_L3'
              AND rs.quality_code = 'GOOD'
              AND rs.scale_to_normalized_unit IS NOT NULL
        ) AS reactive_export_energy_l3_varh,

        MAX(rs.numeric_value * rs.scale_to_normalized_unit) FILTER (
            WHERE rs.logical_point = ANY (ARRAY['APPARENT_ENERGY_TOTAL', 'ENERGY_APPARENT_ENERGY_TOTAL'])
              AND rs.quality_code = 'GOOD'
              AND rs.scale_to_normalized_unit IS NOT NULL
        ) AS apparent_energy_total_vah,

        MAX(rs.numeric_value * rs.scale_to_normalized_unit) FILTER (
            WHERE rs.logical_point = ANY (ARRAY['APPARENT_ENERGY_L1', 'ENERGY_APPARENT_ENERGY_L1'])
              AND rs.quality_code = 'GOOD'
              AND rs.scale_to_normalized_unit IS NOT NULL
        ) AS apparent_energy_l1_vah,

        MAX(rs.numeric_value * rs.scale_to_normalized_unit) FILTER (
            WHERE rs.logical_point = ANY (ARRAY['APPARENT_ENERGY_L2', 'ENERGY_APPARENT_ENERGY_L2'])
              AND rs.quality_code = 'GOOD'
              AND rs.scale_to_normalized_unit IS NOT NULL
        ) AS apparent_energy_l2_vah,

        MAX(rs.numeric_value * rs.scale_to_normalized_unit) FILTER (
            WHERE rs.logical_point = ANY (ARRAY['APPARENT_ENERGY_L3', 'ENERGY_APPARENT_ENERGY_L3'])
              AND rs.quality_code = 'GOOD'
              AND rs.scale_to_normalized_unit IS NOT NULL
        ) AS apparent_energy_l3_vah,

        MAX(rs.numeric_value) FILTER (
            WHERE rs.logical_point = ANY (ARRAY['ACTIVE_POWER_TOTAL', 'ENERGY_ACTIVE_POWER_TOTAL'])
              AND rs.quality_code = 'GOOD'
              AND rs.profile_code = 'ENERGY_METER_ENISCOPE_V1'
        )::DOUBLE PRECISION AS active_power_total_w,

        MAX(rs.numeric_value) FILTER (
            WHERE rs.logical_point = ANY (ARRAY['ACTIVE_POWER_L1', 'ENERGY_ACTIVE_POWER_L1'])
              AND rs.quality_code = 'GOOD'
              AND rs.profile_code = 'ENERGY_METER_ENISCOPE_V1'
        )::DOUBLE PRECISION AS active_power_l1_w,

        MAX(rs.numeric_value) FILTER (
            WHERE rs.logical_point = ANY (ARRAY['ACTIVE_POWER_L2', 'ENERGY_ACTIVE_POWER_L2'])
              AND rs.quality_code = 'GOOD'
              AND rs.profile_code = 'ENERGY_METER_ENISCOPE_V1'
        )::DOUBLE PRECISION AS active_power_l2_w,

        MAX(rs.numeric_value) FILTER (
            WHERE rs.logical_point = ANY (ARRAY['ACTIVE_POWER_L3', 'ENERGY_ACTIVE_POWER_L3'])
              AND rs.quality_code = 'GOOD'
              AND rs.profile_code = 'ENERGY_METER_ENISCOPE_V1'
        )::DOUBLE PRECISION AS active_power_l3_w,

        MAX(rs.numeric_value) FILTER (
            WHERE rs.logical_point = ANY (ARRAY['REACTIVE_POWER_TOTAL', 'ENERGY_REACTIVE_POWER_TOTAL'])
              AND rs.quality_code = 'GOOD'
              AND rs.profile_code = 'ENERGY_METER_ENISCOPE_V1'
        )::DOUBLE PRECISION AS reactive_power_total_var,

        MAX(rs.numeric_value) FILTER (
            WHERE rs.logical_point = ANY (ARRAY['REACTIVE_POWER_L1', 'ENERGY_REACTIVE_POWER_L1'])
              AND rs.quality_code = 'GOOD'
              AND rs.profile_code = 'ENERGY_METER_ENISCOPE_V1'
        )::DOUBLE PRECISION AS reactive_power_l1_var,

        MAX(rs.numeric_value) FILTER (
            WHERE rs.logical_point = ANY (ARRAY['REACTIVE_POWER_L2', 'ENERGY_REACTIVE_POWER_L2'])
              AND rs.quality_code = 'GOOD'
              AND rs.profile_code = 'ENERGY_METER_ENISCOPE_V1'
        )::DOUBLE PRECISION AS reactive_power_l2_var,

        MAX(rs.numeric_value) FILTER (
            WHERE rs.logical_point = ANY (ARRAY['REACTIVE_POWER_L3', 'ENERGY_REACTIVE_POWER_L3'])
              AND rs.quality_code = 'GOOD'
              AND rs.profile_code = 'ENERGY_METER_ENISCOPE_V1'
        )::DOUBLE PRECISION AS reactive_power_l3_var,

        MAX(rs.numeric_value) FILTER (
            WHERE rs.logical_point = ANY (ARRAY['APPARENT_POWER_TOTAL', 'ENERGY_APPARENT_POWER_TOTAL'])
              AND rs.quality_code = 'GOOD'
              AND rs.profile_code = 'ENERGY_METER_ENISCOPE_V1'
        )::DOUBLE PRECISION AS apparent_power_total_va,

        MAX(rs.numeric_value) FILTER (
            WHERE rs.logical_point = ANY (ARRAY['APPARENT_POWER_L1', 'ENERGY_APPARENT_POWER_L1'])
              AND rs.quality_code = 'GOOD'
              AND rs.profile_code = 'ENERGY_METER_ENISCOPE_V1'
        )::DOUBLE PRECISION AS apparent_power_l1_va,

        MAX(rs.numeric_value) FILTER (
            WHERE rs.logical_point = ANY (ARRAY['APPARENT_POWER_L2', 'ENERGY_APPARENT_POWER_L2'])
              AND rs.quality_code = 'GOOD'
              AND rs.profile_code = 'ENERGY_METER_ENISCOPE_V1'
        )::DOUBLE PRECISION AS apparent_power_l2_va,

        MAX(rs.numeric_value) FILTER (
            WHERE rs.logical_point = ANY (ARRAY['APPARENT_POWER_L3', 'ENERGY_APPARENT_POWER_L3'])
              AND rs.quality_code = 'GOOD'
              AND rs.profile_code = 'ENERGY_METER_ENISCOPE_V1'
        )::DOUBLE PRECISION AS apparent_power_l3_va,

        MAX(rs.numeric_value) FILTER (
            WHERE rs.logical_point = 'VOLTAGE_LN_AVG'
              AND rs.quality_code = 'GOOD'
              AND rs.profile_code = 'ENERGY_METER_ENISCOPE_V1'
        )::DOUBLE PRECISION AS voltage_ln_avg_v,

        MAX(rs.numeric_value) FILTER (
            WHERE rs.logical_point = 'VOLTAGE_L1'
              AND rs.quality_code = 'GOOD'
              AND rs.profile_code = 'ENERGY_METER_ENISCOPE_V1'
        )::DOUBLE PRECISION AS voltage_l1_v,

        MAX(rs.numeric_value) FILTER (
            WHERE rs.logical_point = 'VOLTAGE_L2'
              AND rs.quality_code = 'GOOD'
              AND rs.profile_code = 'ENERGY_METER_ENISCOPE_V1'
        )::DOUBLE PRECISION AS voltage_l2_v,

        MAX(rs.numeric_value) FILTER (
            WHERE rs.logical_point = 'VOLTAGE_L3'
              AND rs.quality_code = 'GOOD'
              AND rs.profile_code = 'ENERGY_METER_ENISCOPE_V1'
        )::DOUBLE PRECISION AS voltage_l3_v,

        MAX(rs.numeric_value) FILTER (
            WHERE rs.logical_point = 'VOLTAGE_LL_AVG'
              AND rs.quality_code = 'GOOD'
              AND rs.profile_code = 'ENERGY_METER_ENISCOPE_V1'
        )::DOUBLE PRECISION AS voltage_ll_avg_v,

        MAX(rs.numeric_value) FILTER (
            WHERE rs.logical_point = 'VOLTAGE_L12'
              AND rs.quality_code = 'GOOD'
              AND rs.profile_code = 'ENERGY_METER_ENISCOPE_V1'
        )::DOUBLE PRECISION AS voltage_l12_v,

        MAX(rs.numeric_value) FILTER (
            WHERE rs.logical_point = 'VOLTAGE_L23'
              AND rs.quality_code = 'GOOD'
              AND rs.profile_code = 'ENERGY_METER_ENISCOPE_V1'
        )::DOUBLE PRECISION AS voltage_l23_v,

        MAX(rs.numeric_value) FILTER (
            WHERE rs.logical_point = 'VOLTAGE_L31'
              AND rs.quality_code = 'GOOD'
              AND rs.profile_code = 'ENERGY_METER_ENISCOPE_V1'
        )::DOUBLE PRECISION AS voltage_l31_v,

        MAX(rs.numeric_value) FILTER (
            WHERE rs.logical_point = 'CURRENT_TOTAL'
              AND rs.quality_code = 'GOOD'
              AND rs.profile_code = 'ENERGY_METER_ENISCOPE_V1'
        )::DOUBLE PRECISION AS current_total_a,

        MAX(rs.numeric_value) FILTER (
            WHERE rs.logical_point = 'CURRENT_L1'
              AND rs.quality_code = 'GOOD'
              AND rs.profile_code = 'ENERGY_METER_ENISCOPE_V1'
        )::DOUBLE PRECISION AS current_l1_a,

        MAX(rs.numeric_value) FILTER (
            WHERE rs.logical_point = 'CURRENT_L2'
              AND rs.quality_code = 'GOOD'
              AND rs.profile_code = 'ENERGY_METER_ENISCOPE_V1'
        )::DOUBLE PRECISION AS current_l2_a,

        MAX(rs.numeric_value) FILTER (
            WHERE rs.logical_point = 'CURRENT_L3'
              AND rs.quality_code = 'GOOD'
              AND rs.profile_code = 'ENERGY_METER_ENISCOPE_V1'
        )::DOUBLE PRECISION AS current_l3_a,

        MAX(rs.numeric_value) FILTER (
            WHERE rs.logical_point = 'CURRENT_NEUTRAL'
              AND rs.quality_code = 'GOOD'
              AND rs.profile_code = 'ENERGY_METER_ENISCOPE_V1'
        )::DOUBLE PRECISION AS neutral_current_a,

        MAX(rs.numeric_value) FILTER (
            WHERE rs.logical_point = 'POWER_FACTOR_TOTAL'
              AND rs.quality_code = 'GOOD'
              AND rs.profile_code = 'ENERGY_METER_ENISCOPE_V1'
        )::DOUBLE PRECISION AS power_factor_total,

        MAX(rs.numeric_value) FILTER (
            WHERE rs.logical_point = 'POWER_FACTOR_L1'
              AND rs.quality_code = 'GOOD'
              AND rs.profile_code = 'ENERGY_METER_ENISCOPE_V1'
        )::DOUBLE PRECISION AS power_factor_l1,

        MAX(rs.numeric_value) FILTER (
            WHERE rs.logical_point = 'POWER_FACTOR_L2'
              AND rs.quality_code = 'GOOD'
              AND rs.profile_code = 'ENERGY_METER_ENISCOPE_V1'
        )::DOUBLE PRECISION AS power_factor_l2,

        MAX(rs.numeric_value) FILTER (
            WHERE rs.logical_point = 'POWER_FACTOR_L3'
              AND rs.quality_code = 'GOOD'
              AND rs.profile_code = 'ENERGY_METER_ENISCOPE_V1'
        )::DOUBLE PRECISION AS power_factor_l3,

        MAX(rs.numeric_value) FILTER (
            WHERE rs.logical_point = 'FREQUENCY'
              AND rs.quality_code = 'GOOD'
              AND rs.profile_code = 'ENERGY_METER_ENISCOPE_V1'
        )::DOUBLE PRECISION AS frequency_hz,

        MAX(rs.numeric_value) FILTER (
            WHERE rs.logical_point = 'PHASE_ANGLE_L1'
              AND rs.quality_code = 'GOOD'
              AND rs.profile_code = 'ENERGY_METER_ENISCOPE_V1'
        )::DOUBLE PRECISION AS phase_angle_l1_deg,

        MAX(rs.numeric_value) FILTER (
            WHERE rs.logical_point = 'PHASE_ANGLE_L2'
              AND rs.quality_code = 'GOOD'
              AND rs.profile_code = 'ENERGY_METER_ENISCOPE_V1'
        )::DOUBLE PRECISION AS phase_angle_l2_deg,

        MAX(rs.numeric_value) FILTER (
            WHERE rs.logical_point = 'PHASE_ANGLE_L3'
              AND rs.quality_code = 'GOOD'
              AND rs.profile_code = 'ENERGY_METER_ENISCOPE_V1'
        )::DOUBLE PRECISION AS phase_angle_l3_deg,

        MAX(rs.numeric_value) FILTER (
            WHERE rs.logical_point = 'CURRENT_THD_TOTAL'
              AND rs.quality_code = 'GOOD'
              AND rs.profile_code = 'ENERGY_METER_ENISCOPE_V1'
        )::DOUBLE PRECISION AS current_thd_total_percent,

        MAX(rs.numeric_value) FILTER (
            WHERE rs.logical_point = 'CURRENT_THD_L1'
              AND rs.quality_code = 'GOOD'
              AND rs.profile_code = 'ENERGY_METER_ENISCOPE_V1'
        )::DOUBLE PRECISION AS current_thd_l1_percent,

        MAX(rs.numeric_value) FILTER (
            WHERE rs.logical_point = 'CURRENT_THD_L2'
              AND rs.quality_code = 'GOOD'
              AND rs.profile_code = 'ENERGY_METER_ENISCOPE_V1'
        )::DOUBLE PRECISION AS current_thd_l2_percent,

        MAX(rs.numeric_value) FILTER (
            WHERE rs.logical_point = 'CURRENT_THD_L3'
              AND rs.quality_code = 'GOOD'
              AND rs.profile_code = 'ENERGY_METER_ENISCOPE_V1'
        )::DOUBLE PRECISION AS current_thd_l3_percent,

        MAX(rs.numeric_value) FILTER (
            WHERE rs.logical_point = 'PULSE_COUNT'
              AND rs.quality_code = 'GOOD'
              AND rs.profile_code = 'ENERGY_METER_ENISCOPE_V1'
        )::BIGINT AS pulse_count,

        COUNT(*) FILTER (WHERE rs.quality_code='GOOD' AND rs.numeric_value IS NOT NULL) AS populated_point_count,
        COUNT(*) FILTER (WHERE rs.quality_code='INVALID_NUMERIC') AS invalid_point_count
  FROM register_scales rs
  GROUP BY rs.event_time, rs.organization_id, rs.site_id, rs.gateway_id, rs.device_id
)
SELECT *
FROM pivoted
WHERE num_nonnulls
(
    import_energy_total_wh,
    import_energy_l1_wh,
    import_energy_l2_wh,
    import_energy_l3_wh,
    export_energy_total_wh,
    export_energy_l1_wh,
    export_energy_l2_wh,
    export_energy_l3_wh,
    reactive_energy_total_varh,
    reactive_energy_l1_varh,
    reactive_energy_l2_varh,
    reactive_energy_l3_varh,
    reactive_export_energy_total_varh,
    reactive_export_energy_l1_varh,
    reactive_export_energy_l2_varh,
    reactive_export_energy_l3_varh,
    apparent_energy_total_vah,
    apparent_energy_l1_vah,
    apparent_energy_l2_vah,
    apparent_energy_l3_vah,
    active_power_total_w,
    active_power_l1_w,
    active_power_l2_w,
    active_power_l3_w,
    reactive_power_total_var,
    reactive_power_l1_var,
    reactive_power_l2_var,
    reactive_power_l3_var,
    apparent_power_total_va,
    apparent_power_l1_va,
    apparent_power_l2_va,
    apparent_power_l3_va,
    voltage_ln_avg_v,
    voltage_l1_v,
    voltage_l2_v,
    voltage_l3_v,
    voltage_ll_avg_v,
    voltage_l12_v,
    voltage_l23_v,
    voltage_l31_v,
    current_total_a,
    current_l1_a,
    current_l2_a,
    current_l3_a,
    neutral_current_a,
    power_factor_total,
    power_factor_l1,
    power_factor_l2,
    power_factor_l3,
    frequency_hz,
    phase_angle_l1_deg,
    phase_angle_l2_deg,
    phase_angle_l3_deg,
    current_thd_total_percent,
    current_thd_l1_percent,
    current_thd_l2_percent,
    current_thd_l3_percent,
    pulse_count
) > 0
  ),
  resolved AS
  (
    SELECT fr.*,bucket.policy_id,bucket.capture_interval_seconds,
           bucket.late_arrival_tolerance_seconds,bucket.bucket_start
    FROM full_resolution fr
    CROSS JOIN LATERAL telemetry.resolve_site_capture_bucket
      (fr.site_id,COALESCE(fr.source_timestamp,fr.received_at)) AS bucket
  ),
  ranked AS
  (
    SELECT resolved.*,
           row_number() OVER
           (
             PARTITION BY resolved.device_id,resolved.policy_id,resolved.bucket_start
             ORDER BY COALESCE(resolved.source_timestamp,resolved.received_at) DESC,
                      resolved.received_at DESC
           ) AS sample_rank
    FROM resolved
  )
  INSERT INTO telemetry.energy_measurements
  (
        bucket_start, received_at, source_timestamp, organization_id, site_id, gateway_id, device_id, asset_id,
        import_energy_total_wh,
        import_energy_l1_wh,
        import_energy_l2_wh,
        import_energy_l3_wh,
        export_energy_total_wh,
        export_energy_l1_wh,
        export_energy_l2_wh,
        export_energy_l3_wh,
        reactive_energy_total_varh,
        reactive_energy_l1_varh,
        reactive_energy_l2_varh,
        reactive_energy_l3_varh,
        reactive_export_energy_total_varh,
        reactive_export_energy_l1_varh,
        reactive_export_energy_l2_varh,
        reactive_export_energy_l3_varh,
        apparent_energy_total_vah,
        apparent_energy_l1_vah,
        apparent_energy_l2_vah,
        apparent_energy_l3_vah,
        active_power_total_w,
        active_power_l1_w,
        active_power_l2_w,
        active_power_l3_w,
        reactive_power_total_var,
        reactive_power_l1_var,
        reactive_power_l2_var,
        reactive_power_l3_var,
        apparent_power_total_va,
        apparent_power_l1_va,
        apparent_power_l2_va,
        apparent_power_l3_va,
        voltage_ln_avg_v,
        voltage_l1_v,
        voltage_l2_v,
        voltage_l3_v,
        voltage_ll_avg_v,
        voltage_l12_v,
        voltage_l23_v,
        voltage_l31_v,
        current_total_a,
        current_l1_a,
        current_l2_a,
        current_l3_a,
        neutral_current_a,
        power_factor_total,
        power_factor_l1,
        power_factor_l2,
        power_factor_l3,
        frequency_hz,
        phase_angle_l1_deg,
        phase_angle_l2_deg,
        phase_angle_l3_deg,
        current_thd_total_percent,
        current_thd_l1_percent,
        current_thd_l2_percent,
        current_thd_l3_percent,
        pulse_count,
        is_estimated
  )
  SELECT
        r.bucket_start, we.platform_received_at, r.source_timestamp, r.organization_id, r.site_id, r.gateway_id, r.device_id, r.asset_id,
        r.import_energy_total_wh,
        r.import_energy_l1_wh,
        r.import_energy_l2_wh,
        r.import_energy_l3_wh,
        r.export_energy_total_wh,
        r.export_energy_l1_wh,
        r.export_energy_l2_wh,
        r.export_energy_l3_wh,
        r.reactive_energy_total_varh,
        r.reactive_energy_l1_varh,
        r.reactive_energy_l2_varh,
        r.reactive_energy_l3_varh,
        r.reactive_export_energy_total_varh,
        r.reactive_export_energy_l1_varh,
        r.reactive_export_energy_l2_varh,
        r.reactive_export_energy_l3_varh,
        r.apparent_energy_total_vah,
        r.apparent_energy_l1_vah,
        r.apparent_energy_l2_vah,
        r.apparent_energy_l3_vah,
        r.active_power_total_w,
        r.active_power_l1_w,
        r.active_power_l2_w,
        r.active_power_l3_w,
        r.reactive_power_total_var,
        r.reactive_power_l1_var,
        r.reactive_power_l2_var,
        r.reactive_power_l3_var,
        r.apparent_power_total_va,
        r.apparent_power_l1_va,
        r.apparent_power_l2_va,
        r.apparent_power_l3_va,
        r.voltage_ln_avg_v,
        r.voltage_l1_v,
        r.voltage_l2_v,
        r.voltage_l3_v,
        r.voltage_ll_avg_v,
        r.voltage_l12_v,
        r.voltage_l23_v,
        r.voltage_l31_v,
        r.current_total_a,
        r.current_l1_a,
        r.current_l2_a,
        r.current_l3_a,
        r.neutral_current_a,
        r.power_factor_total,
        r.power_factor_l1,
        r.power_factor_l2,
        r.power_factor_l3,
        r.frequency_hz,
        r.phase_angle_l1_deg,
        r.phase_angle_l2_deg,
        r.phase_angle_l3_deg,
        r.current_thd_total_percent,
        r.current_thd_l1_percent,
        r.current_thd_l2_percent,
        r.current_thd_l3_percent,
        r.pulse_count,
        FALSE
  FROM ranked r
  JOIN window_events we
    ON we.device_id=r.device_id AND we.event_time=r.source_timestamp
  WHERE r.sample_rank=1
    AND r.bucket_start + make_interval(secs => COALESCE(r.capture_interval_seconds,1)) <= v_now
  ON CONFLICT (bucket_start,device_id) DO UPDATE
  SET
        received_at=EXCLUDED.received_at,
        source_timestamp=EXCLUDED.source_timestamp,
        organization_id=EXCLUDED.organization_id,
        site_id=EXCLUDED.site_id,
        gateway_id=EXCLUDED.gateway_id,
        asset_id=COALESCE(EXCLUDED.asset_id,telemetry.energy_measurements.asset_id),
        import_energy_total_wh = COALESCE(EXCLUDED.import_energy_total_wh, telemetry.energy_measurements.import_energy_total_wh),

        import_energy_l1_wh = COALESCE(EXCLUDED.import_energy_l1_wh, telemetry.energy_measurements.import_energy_l1_wh),

        import_energy_l2_wh = COALESCE(EXCLUDED.import_energy_l2_wh, telemetry.energy_measurements.import_energy_l2_wh),

        import_energy_l3_wh = COALESCE(EXCLUDED.import_energy_l3_wh, telemetry.energy_measurements.import_energy_l3_wh),

        export_energy_total_wh = COALESCE(EXCLUDED.export_energy_total_wh, telemetry.energy_measurements.export_energy_total_wh),

        export_energy_l1_wh = COALESCE(EXCLUDED.export_energy_l1_wh, telemetry.energy_measurements.export_energy_l1_wh),

        export_energy_l2_wh = COALESCE(EXCLUDED.export_energy_l2_wh, telemetry.energy_measurements.export_energy_l2_wh),

        export_energy_l3_wh = COALESCE(EXCLUDED.export_energy_l3_wh, telemetry.energy_measurements.export_energy_l3_wh),

        reactive_energy_total_varh = COALESCE(EXCLUDED.reactive_energy_total_varh, telemetry.energy_measurements.reactive_energy_total_varh),

        reactive_energy_l1_varh = COALESCE(EXCLUDED.reactive_energy_l1_varh, telemetry.energy_measurements.reactive_energy_l1_varh),

        reactive_energy_l2_varh = COALESCE(EXCLUDED.reactive_energy_l2_varh, telemetry.energy_measurements.reactive_energy_l2_varh),

        reactive_energy_l3_varh = COALESCE(EXCLUDED.reactive_energy_l3_varh, telemetry.energy_measurements.reactive_energy_l3_varh),

        reactive_export_energy_total_varh = COALESCE(EXCLUDED.reactive_export_energy_total_varh, telemetry.energy_measurements.reactive_export_energy_total_varh),

        reactive_export_energy_l1_varh = COALESCE(EXCLUDED.reactive_export_energy_l1_varh, telemetry.energy_measurements.reactive_export_energy_l1_varh),

        reactive_export_energy_l2_varh = COALESCE(EXCLUDED.reactive_export_energy_l2_varh, telemetry.energy_measurements.reactive_export_energy_l2_varh),

        reactive_export_energy_l3_varh = COALESCE(EXCLUDED.reactive_export_energy_l3_varh, telemetry.energy_measurements.reactive_export_energy_l3_varh),

        apparent_energy_total_vah = COALESCE(EXCLUDED.apparent_energy_total_vah, telemetry.energy_measurements.apparent_energy_total_vah),

        apparent_energy_l1_vah = COALESCE(EXCLUDED.apparent_energy_l1_vah, telemetry.energy_measurements.apparent_energy_l1_vah),

        apparent_energy_l2_vah = COALESCE(EXCLUDED.apparent_energy_l2_vah, telemetry.energy_measurements.apparent_energy_l2_vah),

        apparent_energy_l3_vah = COALESCE(EXCLUDED.apparent_energy_l3_vah, telemetry.energy_measurements.apparent_energy_l3_vah),

        active_power_total_w = COALESCE(EXCLUDED.active_power_total_w, telemetry.energy_measurements.active_power_total_w),

        active_power_l1_w = COALESCE(EXCLUDED.active_power_l1_w, telemetry.energy_measurements.active_power_l1_w),

        active_power_l2_w = COALESCE(EXCLUDED.active_power_l2_w, telemetry.energy_measurements.active_power_l2_w),

        active_power_l3_w = COALESCE(EXCLUDED.active_power_l3_w, telemetry.energy_measurements.active_power_l3_w),

        reactive_power_total_var = COALESCE(EXCLUDED.reactive_power_total_var, telemetry.energy_measurements.reactive_power_total_var),

        reactive_power_l1_var = COALESCE(EXCLUDED.reactive_power_l1_var, telemetry.energy_measurements.reactive_power_l1_var),

        reactive_power_l2_var = COALESCE(EXCLUDED.reactive_power_l2_var, telemetry.energy_measurements.reactive_power_l2_var),

        reactive_power_l3_var = COALESCE(EXCLUDED.reactive_power_l3_var, telemetry.energy_measurements.reactive_power_l3_var),

        apparent_power_total_va = COALESCE(EXCLUDED.apparent_power_total_va, telemetry.energy_measurements.apparent_power_total_va),

        apparent_power_l1_va = COALESCE(EXCLUDED.apparent_power_l1_va, telemetry.energy_measurements.apparent_power_l1_va),

        apparent_power_l2_va = COALESCE(EXCLUDED.apparent_power_l2_va, telemetry.energy_measurements.apparent_power_l2_va),

        apparent_power_l3_va = COALESCE(EXCLUDED.apparent_power_l3_va, telemetry.energy_measurements.apparent_power_l3_va),

        voltage_ln_avg_v = COALESCE(EXCLUDED.voltage_ln_avg_v, telemetry.energy_measurements.voltage_ln_avg_v),

        voltage_l1_v = COALESCE(EXCLUDED.voltage_l1_v, telemetry.energy_measurements.voltage_l1_v),

        voltage_l2_v = COALESCE(EXCLUDED.voltage_l2_v, telemetry.energy_measurements.voltage_l2_v),

        voltage_l3_v = COALESCE(EXCLUDED.voltage_l3_v, telemetry.energy_measurements.voltage_l3_v),

        voltage_ll_avg_v = COALESCE(EXCLUDED.voltage_ll_avg_v, telemetry.energy_measurements.voltage_ll_avg_v),

        voltage_l12_v = COALESCE(EXCLUDED.voltage_l12_v, telemetry.energy_measurements.voltage_l12_v),

        voltage_l23_v = COALESCE(EXCLUDED.voltage_l23_v, telemetry.energy_measurements.voltage_l23_v),

        voltage_l31_v = COALESCE(EXCLUDED.voltage_l31_v, telemetry.energy_measurements.voltage_l31_v),

        current_total_a = COALESCE(EXCLUDED.current_total_a, telemetry.energy_measurements.current_total_a),

        current_l1_a = COALESCE(EXCLUDED.current_l1_a, telemetry.energy_measurements.current_l1_a),

        current_l2_a = COALESCE(EXCLUDED.current_l2_a, telemetry.energy_measurements.current_l2_a),

        current_l3_a = COALESCE(EXCLUDED.current_l3_a, telemetry.energy_measurements.current_l3_a),

        neutral_current_a = COALESCE(EXCLUDED.neutral_current_a, telemetry.energy_measurements.neutral_current_a),

        power_factor_total = COALESCE(EXCLUDED.power_factor_total, telemetry.energy_measurements.power_factor_total),

        power_factor_l1 = COALESCE(EXCLUDED.power_factor_l1, telemetry.energy_measurements.power_factor_l1),

        power_factor_l2 = COALESCE(EXCLUDED.power_factor_l2, telemetry.energy_measurements.power_factor_l2),

        power_factor_l3 = COALESCE(EXCLUDED.power_factor_l3, telemetry.energy_measurements.power_factor_l3),

        frequency_hz = COALESCE(EXCLUDED.frequency_hz, telemetry.energy_measurements.frequency_hz),

        phase_angle_l1_deg = COALESCE(EXCLUDED.phase_angle_l1_deg, telemetry.energy_measurements.phase_angle_l1_deg),

        phase_angle_l2_deg = COALESCE(EXCLUDED.phase_angle_l2_deg, telemetry.energy_measurements.phase_angle_l2_deg),

        phase_angle_l3_deg = COALESCE(EXCLUDED.phase_angle_l3_deg, telemetry.energy_measurements.phase_angle_l3_deg),

        current_thd_total_percent = COALESCE(EXCLUDED.current_thd_total_percent, telemetry.energy_measurements.current_thd_total_percent),

        current_thd_l1_percent = COALESCE(EXCLUDED.current_thd_l1_percent, telemetry.energy_measurements.current_thd_l1_percent),

        current_thd_l2_percent = COALESCE(EXCLUDED.current_thd_l2_percent, telemetry.energy_measurements.current_thd_l2_percent),

        current_thd_l3_percent = COALESCE(EXCLUDED.current_thd_l3_percent, telemetry.energy_measurements.current_thd_l3_percent),

        pulse_count = COALESCE(EXCLUDED.pulse_count, telemetry.energy_measurements.pulse_count),
        is_estimated=FALSE
  WHERE
        COALESCE(EXCLUDED.source_timestamp, EXCLUDED.received_at)
            > COALESCE(
                telemetry.energy_measurements.source_timestamp,
                telemetry.energy_measurements.received_at,
                '-infinity'::timestamptz
              )
    AND v_now <= telemetry.capture_bucket_correction_deadline
    (
        EXCLUDED.site_id,
        EXCLUDED.bucket_start
    );

  GET DIAGNOSTICS v_affected_rows=ROW_COUNT;
  UPDATE telemetry.pipeline_state
  SET last_received_at=v_window_end,last_completed_at=clock_timestamp(),last_inserted_rows=v_affected_rows,
      last_status='SUCCESS',last_error=NULL,updated_at=now()
  WHERE pipeline_name=v_pipeline_name;
  RAISE NOTICE 'Closed-bucket energy routing succeeded: window=(%, %], affected_rows=%',v_window_start,v_window_end,v_affected_rows;
EXCEPTION WHEN OTHERS THEN
  UPDATE telemetry.pipeline_state
  SET last_completed_at=clock_timestamp(),last_inserted_rows=0,last_status='FAILED',
      last_error=SQLSTATE||': '||SQLERRM,updated_at=now()
  WHERE pipeline_name=v_pipeline_name;
  RAISE;
END;
$procedure$;

COMMENT ON PROCEDURE telemetry.load_energy_measurements_incremental(interval, interval) IS
'Incrementally routes closed-bucket normalized telemetry into telemetry.energy_measurements. Checkpoint is telemetry.pipeline_state(''energy_measurements'').last_received_at, keyed on telemetry.normalized_points.platform_received_at; a pg_try_advisory_xact_lock serialises concurrent runs; the single transaction''s EXCEPTION handler re-RAISEs, so a caught failure rolls back the watermark with the data. '
'Migration 207: p_max_window (default NULL) optionally caps the forward processing boundary to previous_checkpoint + p_max_window instead of always advancing to max(telemetry.normalized_points.platform_received_at). NULL preserves the exact prior behaviour -- a one-argument or explicit-NULL manual CALL performs unrestricted catch-up. The scheduled wrapper telemetry.run_energy_routing_job passes a bounded value (default 2 hours, config.max_window-overridable) so an unattended multi-hour backlog self-drains over successive 1-minute runs. No intermediate COMMIT is introduced; this is a bound on scope, not a change to transaction boundaries. Mirrors migration 205''s bounded catch-up for telemetry.load_normalized_points_incremental().';

-- ----------------------------------------------------------------------------

-- ----------------------------------------------------------------------------
-- 2. Full-resolution view: same identity correction (also fixes the
--    pre-existing pre-174-name-only latent breakage of these 20 signals).
-- ----------------------------------------------------------------------------
CREATE OR REPLACE VIEW telemetry.v_energy_measurements_full_resolution AS 
 WITH profile_context AS (
         SELECT np.event_time,
            np.organization_id,
            np.site_id,
            np.gateway_id,
            np.device_id,
            np.logical_point_id,
            np.device_uid,
            np.logical_point,
            np.raw_field_name,
            np.raw_value,
            np.numeric_value,
            np.quality_code,
            np.mapping_source,
            np.created_at,
            np.platform_received_at,
            np.raw_message_id,
            d.profile_id,
            dp.profile_code
           FROM telemetry.normalized_points np
             JOIN metadata.devices d ON d.id = np.device_id
             LEFT JOIN config.device_profiles dp ON dp.id = d.profile_id
        ), register_scales AS (
         SELECT pc.event_time,
            pc.organization_id,
            pc.site_id,
            pc.gateway_id,
            pc.device_id,
            pc.logical_point_id,
            pc.device_uid,
            pc.logical_point,
            pc.raw_field_name,
            pc.raw_value,
            pc.numeric_value,
            pc.quality_code,
            pc.mapping_source,
            pc.created_at,
            pc.platform_received_at,
            pc.raw_message_id,
            pc.profile_id,
            pc.profile_code,
            ers.scale_to_normalized_unit
           FROM profile_context pc
             LEFT JOIN config.energy_register_semantics ers ON ers.profile_id = pc.profile_id AND ers.logical_point_id = pc.logical_point_id AND ers.is_active = true
        ), pivoted AS (
         SELECT rs.event_time AS received_at,
            rs.event_time AS source_timestamp,
            rs.organization_id,
            rs.site_id,
            rs.gateway_id,
            rs.device_id,
            NULL::uuid AS asset_id,
            max(rs.numeric_value * rs.scale_to_normalized_unit) FILTER (WHERE rs.logical_point = 'ENERGY_IMPORT_TOTAL'::text AND rs.quality_code = 'GOOD'::text AND rs.scale_to_normalized_unit IS NOT NULL) AS import_energy_total_wh,
            max(rs.numeric_value * rs.scale_to_normalized_unit) FILTER (WHERE rs.logical_point = 'ENERGY_IMPORT_L1'::text AND rs.quality_code = 'GOOD'::text AND rs.scale_to_normalized_unit IS NOT NULL) AS import_energy_l1_wh,
            max(rs.numeric_value * rs.scale_to_normalized_unit) FILTER (WHERE rs.logical_point = 'ENERGY_IMPORT_L2'::text AND rs.quality_code = 'GOOD'::text AND rs.scale_to_normalized_unit IS NOT NULL) AS import_energy_l2_wh,
            max(rs.numeric_value * rs.scale_to_normalized_unit) FILTER (WHERE rs.logical_point = 'ENERGY_IMPORT_L3'::text AND rs.quality_code = 'GOOD'::text AND rs.scale_to_normalized_unit IS NOT NULL) AS import_energy_l3_wh,
            max(rs.numeric_value * rs.scale_to_normalized_unit) FILTER (WHERE rs.logical_point = 'ENERGY_EXPORT_TOTAL'::text AND rs.quality_code = 'GOOD'::text AND rs.scale_to_normalized_unit IS NOT NULL) AS export_energy_total_wh,
            max(rs.numeric_value * rs.scale_to_normalized_unit) FILTER (WHERE rs.logical_point = 'ENERGY_EXPORT_L1'::text AND rs.quality_code = 'GOOD'::text AND rs.scale_to_normalized_unit IS NOT NULL) AS export_energy_l1_wh,
            max(rs.numeric_value * rs.scale_to_normalized_unit) FILTER (WHERE rs.logical_point = 'ENERGY_EXPORT_L2'::text AND rs.quality_code = 'GOOD'::text AND rs.scale_to_normalized_unit IS NOT NULL) AS export_energy_l2_wh,
            max(rs.numeric_value * rs.scale_to_normalized_unit) FILTER (WHERE rs.logical_point = 'ENERGY_EXPORT_L3'::text AND rs.quality_code = 'GOOD'::text AND rs.scale_to_normalized_unit IS NOT NULL) AS export_energy_l3_wh,
            max(rs.numeric_value * rs.scale_to_normalized_unit) FILTER (WHERE rs.logical_point = ANY (ARRAY['REACTIVE_ENERGY_TOTAL'::text, 'ENERGY_REACTIVE_ENERGY_TOTAL'::text]) AND rs.quality_code = 'GOOD'::text AND rs.scale_to_normalized_unit IS NOT NULL) AS reactive_energy_total_varh,
            max(rs.numeric_value * rs.scale_to_normalized_unit) FILTER (WHERE rs.logical_point = ANY (ARRAY['REACTIVE_ENERGY_L1'::text, 'ENERGY_REACTIVE_ENERGY_L1'::text]) AND rs.quality_code = 'GOOD'::text AND rs.scale_to_normalized_unit IS NOT NULL) AS reactive_energy_l1_varh,
            max(rs.numeric_value * rs.scale_to_normalized_unit) FILTER (WHERE rs.logical_point = ANY (ARRAY['REACTIVE_ENERGY_L2'::text, 'ENERGY_REACTIVE_ENERGY_L2'::text]) AND rs.quality_code = 'GOOD'::text AND rs.scale_to_normalized_unit IS NOT NULL) AS reactive_energy_l2_varh,
            max(rs.numeric_value * rs.scale_to_normalized_unit) FILTER (WHERE rs.logical_point = ANY (ARRAY['REACTIVE_ENERGY_L3'::text, 'ENERGY_REACTIVE_ENERGY_L3'::text]) AND rs.quality_code = 'GOOD'::text AND rs.scale_to_normalized_unit IS NOT NULL) AS reactive_energy_l3_varh,
            max(rs.numeric_value * rs.scale_to_normalized_unit) FILTER (WHERE rs.logical_point = 'ENERGY_REACTIVE_EXPORT_TOTAL'::text AND rs.quality_code = 'GOOD'::text AND rs.scale_to_normalized_unit IS NOT NULL) AS reactive_export_energy_total_varh,
            max(rs.numeric_value * rs.scale_to_normalized_unit) FILTER (WHERE rs.logical_point = 'ENERGY_REACTIVE_EXPORT_L1'::text AND rs.quality_code = 'GOOD'::text AND rs.scale_to_normalized_unit IS NOT NULL) AS reactive_export_energy_l1_varh,
            max(rs.numeric_value * rs.scale_to_normalized_unit) FILTER (WHERE rs.logical_point = 'ENERGY_REACTIVE_EXPORT_L2'::text AND rs.quality_code = 'GOOD'::text AND rs.scale_to_normalized_unit IS NOT NULL) AS reactive_export_energy_l2_varh,
            max(rs.numeric_value * rs.scale_to_normalized_unit) FILTER (WHERE rs.logical_point = 'ENERGY_REACTIVE_EXPORT_L3'::text AND rs.quality_code = 'GOOD'::text AND rs.scale_to_normalized_unit IS NOT NULL) AS reactive_export_energy_l3_varh,
            max(rs.numeric_value * rs.scale_to_normalized_unit) FILTER (WHERE rs.logical_point = ANY (ARRAY['APPARENT_ENERGY_TOTAL'::text, 'ENERGY_APPARENT_ENERGY_TOTAL'::text]) AND rs.quality_code = 'GOOD'::text AND rs.scale_to_normalized_unit IS NOT NULL) AS apparent_energy_total_vah,
            max(rs.numeric_value * rs.scale_to_normalized_unit) FILTER (WHERE rs.logical_point = ANY (ARRAY['APPARENT_ENERGY_L1'::text, 'ENERGY_APPARENT_ENERGY_L1'::text]) AND rs.quality_code = 'GOOD'::text AND rs.scale_to_normalized_unit IS NOT NULL) AS apparent_energy_l1_vah,
            max(rs.numeric_value * rs.scale_to_normalized_unit) FILTER (WHERE rs.logical_point = ANY (ARRAY['APPARENT_ENERGY_L2'::text, 'ENERGY_APPARENT_ENERGY_L2'::text]) AND rs.quality_code = 'GOOD'::text AND rs.scale_to_normalized_unit IS NOT NULL) AS apparent_energy_l2_vah,
            max(rs.numeric_value * rs.scale_to_normalized_unit) FILTER (WHERE rs.logical_point = ANY (ARRAY['APPARENT_ENERGY_L3'::text, 'ENERGY_APPARENT_ENERGY_L3'::text]) AND rs.quality_code = 'GOOD'::text AND rs.scale_to_normalized_unit IS NOT NULL) AS apparent_energy_l3_vah,
            max(rs.numeric_value) FILTER (WHERE rs.logical_point = ANY (ARRAY['ACTIVE_POWER_TOTAL'::text, 'ENERGY_ACTIVE_POWER_TOTAL'::text]) AND rs.quality_code = 'GOOD'::text AND rs.profile_code = 'ENERGY_METER_ENISCOPE_V1'::text)::double precision AS active_power_total_w,
            max(rs.numeric_value) FILTER (WHERE rs.logical_point = ANY (ARRAY['ACTIVE_POWER_L1'::text, 'ENERGY_ACTIVE_POWER_L1'::text]) AND rs.quality_code = 'GOOD'::text AND rs.profile_code = 'ENERGY_METER_ENISCOPE_V1'::text)::double precision AS active_power_l1_w,
            max(rs.numeric_value) FILTER (WHERE rs.logical_point = ANY (ARRAY['ACTIVE_POWER_L2'::text, 'ENERGY_ACTIVE_POWER_L2'::text]) AND rs.quality_code = 'GOOD'::text AND rs.profile_code = 'ENERGY_METER_ENISCOPE_V1'::text)::double precision AS active_power_l2_w,
            max(rs.numeric_value) FILTER (WHERE rs.logical_point = ANY (ARRAY['ACTIVE_POWER_L3'::text, 'ENERGY_ACTIVE_POWER_L3'::text]) AND rs.quality_code = 'GOOD'::text AND rs.profile_code = 'ENERGY_METER_ENISCOPE_V1'::text)::double precision AS active_power_l3_w,
            max(rs.numeric_value) FILTER (WHERE rs.logical_point = ANY (ARRAY['REACTIVE_POWER_TOTAL'::text, 'ENERGY_REACTIVE_POWER_TOTAL'::text]) AND rs.quality_code = 'GOOD'::text AND rs.profile_code = 'ENERGY_METER_ENISCOPE_V1'::text)::double precision AS reactive_power_total_var,
            max(rs.numeric_value) FILTER (WHERE rs.logical_point = ANY (ARRAY['REACTIVE_POWER_L1'::text, 'ENERGY_REACTIVE_POWER_L1'::text]) AND rs.quality_code = 'GOOD'::text AND rs.profile_code = 'ENERGY_METER_ENISCOPE_V1'::text)::double precision AS reactive_power_l1_var,
            max(rs.numeric_value) FILTER (WHERE rs.logical_point = ANY (ARRAY['REACTIVE_POWER_L2'::text, 'ENERGY_REACTIVE_POWER_L2'::text]) AND rs.quality_code = 'GOOD'::text AND rs.profile_code = 'ENERGY_METER_ENISCOPE_V1'::text)::double precision AS reactive_power_l2_var,
            max(rs.numeric_value) FILTER (WHERE rs.logical_point = ANY (ARRAY['REACTIVE_POWER_L3'::text, 'ENERGY_REACTIVE_POWER_L3'::text]) AND rs.quality_code = 'GOOD'::text AND rs.profile_code = 'ENERGY_METER_ENISCOPE_V1'::text)::double precision AS reactive_power_l3_var,
            max(rs.numeric_value) FILTER (WHERE rs.logical_point = ANY (ARRAY['APPARENT_POWER_TOTAL'::text, 'ENERGY_APPARENT_POWER_TOTAL'::text]) AND rs.quality_code = 'GOOD'::text AND rs.profile_code = 'ENERGY_METER_ENISCOPE_V1'::text)::double precision AS apparent_power_total_va,
            max(rs.numeric_value) FILTER (WHERE rs.logical_point = ANY (ARRAY['APPARENT_POWER_L1'::text, 'ENERGY_APPARENT_POWER_L1'::text]) AND rs.quality_code = 'GOOD'::text AND rs.profile_code = 'ENERGY_METER_ENISCOPE_V1'::text)::double precision AS apparent_power_l1_va,
            max(rs.numeric_value) FILTER (WHERE rs.logical_point = ANY (ARRAY['APPARENT_POWER_L2'::text, 'ENERGY_APPARENT_POWER_L2'::text]) AND rs.quality_code = 'GOOD'::text AND rs.profile_code = 'ENERGY_METER_ENISCOPE_V1'::text)::double precision AS apparent_power_l2_va,
            max(rs.numeric_value) FILTER (WHERE rs.logical_point = ANY (ARRAY['APPARENT_POWER_L3'::text, 'ENERGY_APPARENT_POWER_L3'::text]) AND rs.quality_code = 'GOOD'::text AND rs.profile_code = 'ENERGY_METER_ENISCOPE_V1'::text)::double precision AS apparent_power_l3_va,
            max(rs.numeric_value) FILTER (WHERE rs.logical_point = 'VOLTAGE_LN_AVG'::text AND rs.quality_code = 'GOOD'::text AND rs.profile_code = 'ENERGY_METER_ENISCOPE_V1'::text)::double precision AS voltage_ln_avg_v,
            max(rs.numeric_value) FILTER (WHERE rs.logical_point = 'VOLTAGE_L1'::text AND rs.quality_code = 'GOOD'::text AND rs.profile_code = 'ENERGY_METER_ENISCOPE_V1'::text)::double precision AS voltage_l1_v,
            max(rs.numeric_value) FILTER (WHERE rs.logical_point = 'VOLTAGE_L2'::text AND rs.quality_code = 'GOOD'::text AND rs.profile_code = 'ENERGY_METER_ENISCOPE_V1'::text)::double precision AS voltage_l2_v,
            max(rs.numeric_value) FILTER (WHERE rs.logical_point = 'VOLTAGE_L3'::text AND rs.quality_code = 'GOOD'::text AND rs.profile_code = 'ENERGY_METER_ENISCOPE_V1'::text)::double precision AS voltage_l3_v,
            max(rs.numeric_value) FILTER (WHERE rs.logical_point = 'VOLTAGE_LL_AVG'::text AND rs.quality_code = 'GOOD'::text AND rs.profile_code = 'ENERGY_METER_ENISCOPE_V1'::text)::double precision AS voltage_ll_avg_v,
            max(rs.numeric_value) FILTER (WHERE rs.logical_point = 'VOLTAGE_L12'::text AND rs.quality_code = 'GOOD'::text AND rs.profile_code = 'ENERGY_METER_ENISCOPE_V1'::text)::double precision AS voltage_l12_v,
            max(rs.numeric_value) FILTER (WHERE rs.logical_point = 'VOLTAGE_L23'::text AND rs.quality_code = 'GOOD'::text AND rs.profile_code = 'ENERGY_METER_ENISCOPE_V1'::text)::double precision AS voltage_l23_v,
            max(rs.numeric_value) FILTER (WHERE rs.logical_point = 'VOLTAGE_L31'::text AND rs.quality_code = 'GOOD'::text AND rs.profile_code = 'ENERGY_METER_ENISCOPE_V1'::text)::double precision AS voltage_l31_v,
            max(rs.numeric_value) FILTER (WHERE rs.logical_point = 'CURRENT_TOTAL'::text AND rs.quality_code = 'GOOD'::text AND rs.profile_code = 'ENERGY_METER_ENISCOPE_V1'::text)::double precision AS current_total_a,
            max(rs.numeric_value) FILTER (WHERE rs.logical_point = 'CURRENT_L1'::text AND rs.quality_code = 'GOOD'::text AND rs.profile_code = 'ENERGY_METER_ENISCOPE_V1'::text)::double precision AS current_l1_a,
            max(rs.numeric_value) FILTER (WHERE rs.logical_point = 'CURRENT_L2'::text AND rs.quality_code = 'GOOD'::text AND rs.profile_code = 'ENERGY_METER_ENISCOPE_V1'::text)::double precision AS current_l2_a,
            max(rs.numeric_value) FILTER (WHERE rs.logical_point = 'CURRENT_L3'::text AND rs.quality_code = 'GOOD'::text AND rs.profile_code = 'ENERGY_METER_ENISCOPE_V1'::text)::double precision AS current_l3_a,
            max(rs.numeric_value) FILTER (WHERE rs.logical_point = 'CURRENT_NEUTRAL'::text AND rs.quality_code = 'GOOD'::text AND rs.profile_code = 'ENERGY_METER_ENISCOPE_V1'::text)::double precision AS neutral_current_a,
            max(rs.numeric_value) FILTER (WHERE rs.logical_point = 'POWER_FACTOR_TOTAL'::text AND rs.quality_code = 'GOOD'::text AND rs.profile_code = 'ENERGY_METER_ENISCOPE_V1'::text)::double precision AS power_factor_total,
            max(rs.numeric_value) FILTER (WHERE rs.logical_point = 'POWER_FACTOR_L1'::text AND rs.quality_code = 'GOOD'::text AND rs.profile_code = 'ENERGY_METER_ENISCOPE_V1'::text)::double precision AS power_factor_l1,
            max(rs.numeric_value) FILTER (WHERE rs.logical_point = 'POWER_FACTOR_L2'::text AND rs.quality_code = 'GOOD'::text AND rs.profile_code = 'ENERGY_METER_ENISCOPE_V1'::text)::double precision AS power_factor_l2,
            max(rs.numeric_value) FILTER (WHERE rs.logical_point = 'POWER_FACTOR_L3'::text AND rs.quality_code = 'GOOD'::text AND rs.profile_code = 'ENERGY_METER_ENISCOPE_V1'::text)::double precision AS power_factor_l3,
            max(rs.numeric_value) FILTER (WHERE rs.logical_point = 'FREQUENCY'::text AND rs.quality_code = 'GOOD'::text AND rs.profile_code = 'ENERGY_METER_ENISCOPE_V1'::text)::double precision AS frequency_hz,
            max(rs.numeric_value) FILTER (WHERE rs.logical_point = 'PHASE_ANGLE_L1'::text AND rs.quality_code = 'GOOD'::text AND rs.profile_code = 'ENERGY_METER_ENISCOPE_V1'::text)::double precision AS phase_angle_l1_deg,
            max(rs.numeric_value) FILTER (WHERE rs.logical_point = 'PHASE_ANGLE_L2'::text AND rs.quality_code = 'GOOD'::text AND rs.profile_code = 'ENERGY_METER_ENISCOPE_V1'::text)::double precision AS phase_angle_l2_deg,
            max(rs.numeric_value) FILTER (WHERE rs.logical_point = 'PHASE_ANGLE_L3'::text AND rs.quality_code = 'GOOD'::text AND rs.profile_code = 'ENERGY_METER_ENISCOPE_V1'::text)::double precision AS phase_angle_l3_deg,
            max(rs.numeric_value) FILTER (WHERE rs.logical_point = 'CURRENT_THD_TOTAL'::text AND rs.quality_code = 'GOOD'::text AND rs.profile_code = 'ENERGY_METER_ENISCOPE_V1'::text)::double precision AS current_thd_total_percent,
            max(rs.numeric_value) FILTER (WHERE rs.logical_point = 'CURRENT_THD_L1'::text AND rs.quality_code = 'GOOD'::text AND rs.profile_code = 'ENERGY_METER_ENISCOPE_V1'::text)::double precision AS current_thd_l1_percent,
            max(rs.numeric_value) FILTER (WHERE rs.logical_point = 'CURRENT_THD_L2'::text AND rs.quality_code = 'GOOD'::text AND rs.profile_code = 'ENERGY_METER_ENISCOPE_V1'::text)::double precision AS current_thd_l2_percent,
            max(rs.numeric_value) FILTER (WHERE rs.logical_point = 'CURRENT_THD_L3'::text AND rs.quality_code = 'GOOD'::text AND rs.profile_code = 'ENERGY_METER_ENISCOPE_V1'::text)::double precision AS current_thd_l3_percent,
            max(rs.numeric_value) FILTER (WHERE rs.logical_point = 'PULSE_COUNT'::text AND rs.quality_code = 'GOOD'::text AND rs.profile_code = 'ENERGY_METER_ENISCOPE_V1'::text)::bigint AS pulse_count,
            count(*) FILTER (WHERE rs.quality_code = 'GOOD'::text AND rs.numeric_value IS NOT NULL) AS populated_point_count,
            count(*) FILTER (WHERE rs.quality_code = 'INVALID_NUMERIC'::text) AS invalid_point_count
           FROM register_scales rs
          GROUP BY rs.event_time, rs.organization_id, rs.site_id, rs.gateway_id, rs.device_id
        )
 SELECT received_at,
    source_timestamp,
    organization_id,
    site_id,
    gateway_id,
    device_id,
    asset_id,
    import_energy_total_wh,
    import_energy_l1_wh,
    import_energy_l2_wh,
    import_energy_l3_wh,
    export_energy_total_wh,
    export_energy_l1_wh,
    export_energy_l2_wh,
    export_energy_l3_wh,
    reactive_energy_total_varh,
    reactive_energy_l1_varh,
    reactive_energy_l2_varh,
    reactive_energy_l3_varh,
    reactive_export_energy_total_varh,
    reactive_export_energy_l1_varh,
    reactive_export_energy_l2_varh,
    reactive_export_energy_l3_varh,
    apparent_energy_total_vah,
    apparent_energy_l1_vah,
    apparent_energy_l2_vah,
    apparent_energy_l3_vah,
    active_power_total_w,
    active_power_l1_w,
    active_power_l2_w,
    active_power_l3_w,
    reactive_power_total_var,
    reactive_power_l1_var,
    reactive_power_l2_var,
    reactive_power_l3_var,
    apparent_power_total_va,
    apparent_power_l1_va,
    apparent_power_l2_va,
    apparent_power_l3_va,
    voltage_ln_avg_v,
    voltage_l1_v,
    voltage_l2_v,
    voltage_l3_v,
    voltage_ll_avg_v,
    voltage_l12_v,
    voltage_l23_v,
    voltage_l31_v,
    current_total_a,
    current_l1_a,
    current_l2_a,
    current_l3_a,
    neutral_current_a,
    power_factor_total,
    power_factor_l1,
    power_factor_l2,
    power_factor_l3,
    frequency_hz,
    phase_angle_l1_deg,
    phase_angle_l2_deg,
    phase_angle_l3_deg,
    current_thd_total_percent,
    current_thd_l1_percent,
    current_thd_l2_percent,
    current_thd_l3_percent,
    pulse_count,
    populated_point_count,
    invalid_point_count
   FROM pivoted
  WHERE num_nonnulls(import_energy_total_wh, import_energy_l1_wh, import_energy_l2_wh, import_energy_l3_wh, export_energy_total_wh, export_energy_l1_wh, export_energy_l2_wh, export_energy_l3_wh, reactive_energy_total_varh, reactive_energy_l1_varh, reactive_energy_l2_varh, reactive_energy_l3_varh, reactive_export_energy_total_varh, reactive_export_energy_l1_varh, reactive_export_energy_l2_varh, reactive_export_energy_l3_varh, apparent_energy_total_vah, apparent_energy_l1_vah, apparent_energy_l2_vah, apparent_energy_l3_vah, active_power_total_w, active_power_l1_w, active_power_l2_w, active_power_l3_w, reactive_power_total_var, reactive_power_l1_var, reactive_power_l2_var, reactive_power_l3_var, apparent_power_total_va, apparent_power_l1_va, apparent_power_l2_va, apparent_power_l3_va, voltage_ln_avg_v, voltage_l1_v, voltage_l2_v, voltage_l3_v, voltage_ll_avg_v, voltage_l12_v, voltage_l23_v, voltage_l31_v, current_total_a, current_l1_a, current_l2_a, current_l3_a, neutral_current_a, power_factor_total, power_factor_l1, power_factor_l2, power_factor_l3, frequency_hz, phase_angle_l1_deg, phase_angle_l2_deg, phase_angle_l3_deg, current_thd_total_percent, current_thd_l1_percent, current_thd_l2_percent, current_thd_l3_percent, pulse_count) > 0;

COMMENT ON VIEW telemetry.v_energy_measurements_full_resolution IS
'Row-per (device,event_time) wide projection of telemetry.normalized_points into the telemetry.energy_measurements column set; consumed by telemetry.v_energy_measurements_route. Migration 215: the 20 electrical signals (active/reactive/apparent power total+L1..L3; reactive/apparent energy total+L1..L3) resolve by logical-point NAME -- rs.logical_point = ANY (ARRAY[<canonical>, <pre-174>]) -- not by a hard-coded canonical logical_point_id. metadata.logical_points.name is the portable semantic identity; the id is a DB-local surrogate.';

-- ----------------------------------------------------------------------------
-- 3. Forward guard: the name-is-identity uniqueness contract (idempotent).
-- ----------------------------------------------------------------------------
CREATE UNIQUE INDEX IF NOT EXISTS uq_logical_points_name
    ON metadata.logical_points (name);

COMMIT;
