-- ============================================================================
-- Migration 207
-- Extend the migration-205 bounded catch-up pattern to the energy and
-- environment domain-routing loaders, and make their scheduled wrappers run
-- bounded by default so an unattended upstream stall self-drains.
--
-- Root cause (Phase 2 Foundation investigation, 2026-08-27): migration 205
-- fixed telemetry.load_normalized_points_incremental() (job 1000) so that a
-- caller can cap how far forward one invocation advances. The two loaders one
-- hop downstream --
--   telemetry.load_energy_measurements_incremental()      (job: run_energy_routing_job)
--   telemetry.load_environment_measurements_incremental() (job: run_environment_routing_job)
-- -- still compute their forward boundary as
--   SELECT max(platform_received_at) FROM telemetry.normalized_points
--          WHERE platform_received_at IS NOT NULL
-- with NO forward bound, and process the whole (previous_checkpoint,
-- window_end] range in one transaction whose EXCEPTION handler re-RAISEs
-- (so a caught failure rolls back the pipeline_state watermark with the data).
-- This is byte-for-byte the shape that stalled job 1000: once a
-- normalized_points burst makes one pass longer than the job's 5-minute
-- max_runtime, every retry faces an equal-or-wider window with zero possible
-- durable progress. No such burst has hit these two loaders since deploy;
-- this migration removes the latent repeat before it does.
--
-- Fix (mirrors migration 205 exactly):
--   * Each loader gains one new optional parameter,
--     p_max_window INTERVAL DEFAULT NULL. When NULL (the default -- and what
--     a direct manual CALL passes) the forward boundary is computed exactly
--     as before. When a caller supplies p_max_window AND a previous
--     checkpoint already exists, the forward boundary is additionally capped
--     to LEAST(window_end, previous_checkpoint + p_max_window) via a single
--     LEAST(...) applied immediately after the existing window_end / NULL
--     check, before any downstream use.
--   * CREATE OR REPLACE PROCEDURE does not replace a procedure of a
--     different arity, so the prior one-argument signature is DROPped first
--     (identical to migration 205's handling).
--   * Every other statement in each procedure body -- the advisory
--     transaction lock, the pipeline_state RUNNING/SUCCESS/FAILED/
--     SKIPPED_LOCKED/NO_SOURCE_DATA handling, the checkpoint keying on
--     normalized_points.platform_received_at, the LEAST(p_overlap, 1 minute)
--     clamp, the window_events / full_resolution / resolve_site_capture_bucket
--     routing and register/environment calculation SQL, the
--     ON CONFLICT (bucket_start,device_id) DO UPDATE / DO NOTHING write
--     semantics, the capture_bucket_correction_deadline guard, and the
--     EXCEPTION WHEN OTHERS -> set FAILED -> RAISE contract -- is reproduced
--     verbatim from the currently deployed definition.
--
-- Scheduled wrappers:
--   telemetry.run_energy_routing_job / telemetry.run_environment_routing_job
--   now derive v_max_window (default INTERVAL '2 hours', overridable via
--   config.max_window through alter_job with no code change) and pass it to
--   the loader. The wrapper never passes NULL: an unattended multi-hour
--   backlog therefore self-drains over successive 1-minute runs (~8 runs for
--   a 15-hour gap) instead of one unbounded transaction. Unrestricted manual
--   catch-up remains available by CALLing the loader directly with one
--   argument (or an explicit NULL second argument), exactly as an operator
--   ran migration 205's bounded normalization catch-up.
--
-- Not touched by this migration: job schedule_interval / max_runtime /
-- max_retries / retry_period (still 1 minute / 5 minutes / 3 / 1 minute --
-- unchanged; assert_job_schedule_canonical still passes because config.overlap
-- is still '15 minutes'), any downstream schema / CAGG / analytics function /
-- Grafana query, telemetry.load_normalized_points_incremental() or job 1000,
-- and every other job. No new table, no queue, no service.
-- ============================================================================

BEGIN;

-- ----------------------------------------------------------------------------
-- 1. Energy routing loader: add p_max_window (mirror migration 205).
-- ----------------------------------------------------------------------------
DROP PROCEDURE IF EXISTS telemetry.load_energy_measurements_incremental(interval);

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
            WHERE rs.logical_point_id = '361ddb03-2d71-4b8a-aec5-c016ed61376d'::uuid
              AND rs.quality_code = 'GOOD'
              AND rs.scale_to_normalized_unit IS NOT NULL
        ) AS reactive_energy_total_varh,

        MAX(rs.numeric_value * rs.scale_to_normalized_unit) FILTER (
            WHERE rs.logical_point_id = 'cb060b6c-6f28-4951-92fd-02ab0226bd6c'::uuid
              AND rs.quality_code = 'GOOD'
              AND rs.scale_to_normalized_unit IS NOT NULL
        ) AS reactive_energy_l1_varh,

        MAX(rs.numeric_value * rs.scale_to_normalized_unit) FILTER (
            WHERE rs.logical_point_id = '65e814aa-bbb5-4b11-aa51-fa234ffbd2d7'::uuid
              AND rs.quality_code = 'GOOD'
              AND rs.scale_to_normalized_unit IS NOT NULL
        ) AS reactive_energy_l2_varh,

        MAX(rs.numeric_value * rs.scale_to_normalized_unit) FILTER (
            WHERE rs.logical_point_id = 'b3947e8e-2c64-4bd1-8603-89eb351afbd9'::uuid
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
            WHERE rs.logical_point_id = '2e13ca70-a769-47d0-89e3-68396e7bcd6e'::uuid
              AND rs.quality_code = 'GOOD'
              AND rs.scale_to_normalized_unit IS NOT NULL
        ) AS apparent_energy_total_vah,

        MAX(rs.numeric_value * rs.scale_to_normalized_unit) FILTER (
            WHERE rs.logical_point_id = '8abbdfcf-de76-43b8-8c1c-30b67f3e6a06'::uuid
              AND rs.quality_code = 'GOOD'
              AND rs.scale_to_normalized_unit IS NOT NULL
        ) AS apparent_energy_l1_vah,

        MAX(rs.numeric_value * rs.scale_to_normalized_unit) FILTER (
            WHERE rs.logical_point_id = '25cee3e3-1249-44ea-862d-aafe4cd1c42b'::uuid
              AND rs.quality_code = 'GOOD'
              AND rs.scale_to_normalized_unit IS NOT NULL
        ) AS apparent_energy_l2_vah,

        MAX(rs.numeric_value * rs.scale_to_normalized_unit) FILTER (
            WHERE rs.logical_point_id = '59a34763-7c77-49e2-a92a-65635ebd5956'::uuid
              AND rs.quality_code = 'GOOD'
              AND rs.scale_to_normalized_unit IS NOT NULL
        ) AS apparent_energy_l3_vah,

        MAX(rs.numeric_value) FILTER (
            WHERE rs.logical_point_id = '44652ee7-57fb-4174-b4e9-4992323056fd'::uuid
              AND rs.quality_code = 'GOOD'
              AND rs.profile_code = 'ENERGY_METER_ENISCOPE_V1'
        )::DOUBLE PRECISION AS active_power_total_w,

        MAX(rs.numeric_value) FILTER (
            WHERE rs.logical_point_id = 'adf4c51a-6c14-4e65-9f02-b37d363001f6'::uuid
              AND rs.quality_code = 'GOOD'
              AND rs.profile_code = 'ENERGY_METER_ENISCOPE_V1'
        )::DOUBLE PRECISION AS active_power_l1_w,

        MAX(rs.numeric_value) FILTER (
            WHERE rs.logical_point_id = 'b331d9ef-82fa-4e4e-b081-3582e0f5d51c'::uuid
              AND rs.quality_code = 'GOOD'
              AND rs.profile_code = 'ENERGY_METER_ENISCOPE_V1'
        )::DOUBLE PRECISION AS active_power_l2_w,

        MAX(rs.numeric_value) FILTER (
            WHERE rs.logical_point_id = '6868ab67-7cf8-4ec3-b6d7-4119d1c7da9b'::uuid
              AND rs.quality_code = 'GOOD'
              AND rs.profile_code = 'ENERGY_METER_ENISCOPE_V1'
        )::DOUBLE PRECISION AS active_power_l3_w,

        MAX(rs.numeric_value) FILTER (
            WHERE rs.logical_point_id = 'df16db14-0d1d-45f0-b637-5d55ee621227'::uuid
              AND rs.quality_code = 'GOOD'
              AND rs.profile_code = 'ENERGY_METER_ENISCOPE_V1'
        )::DOUBLE PRECISION AS reactive_power_total_var,

        MAX(rs.numeric_value) FILTER (
            WHERE rs.logical_point_id = '61e3efa2-a04c-4157-ae99-a875157f0062'::uuid
              AND rs.quality_code = 'GOOD'
              AND rs.profile_code = 'ENERGY_METER_ENISCOPE_V1'
        )::DOUBLE PRECISION AS reactive_power_l1_var,

        MAX(rs.numeric_value) FILTER (
            WHERE rs.logical_point_id = '6a7b7c26-b004-4569-9c75-defd53a9b3e4'::uuid
              AND rs.quality_code = 'GOOD'
              AND rs.profile_code = 'ENERGY_METER_ENISCOPE_V1'
        )::DOUBLE PRECISION AS reactive_power_l2_var,

        MAX(rs.numeric_value) FILTER (
            WHERE rs.logical_point_id = '29777d90-4210-40a8-8632-0732d0f41a6b'::uuid
              AND rs.quality_code = 'GOOD'
              AND rs.profile_code = 'ENERGY_METER_ENISCOPE_V1'
        )::DOUBLE PRECISION AS reactive_power_l3_var,

        MAX(rs.numeric_value) FILTER (
            WHERE rs.logical_point_id = '56b6ce2a-acf8-48be-8674-87f4e61d7e12'::uuid
              AND rs.quality_code = 'GOOD'
              AND rs.profile_code = 'ENERGY_METER_ENISCOPE_V1'
        )::DOUBLE PRECISION AS apparent_power_total_va,

        MAX(rs.numeric_value) FILTER (
            WHERE rs.logical_point_id = 'dee482f7-32cb-466f-a7c8-51491dc36b8c'::uuid
              AND rs.quality_code = 'GOOD'
              AND rs.profile_code = 'ENERGY_METER_ENISCOPE_V1'
        )::DOUBLE PRECISION AS apparent_power_l1_va,

        MAX(rs.numeric_value) FILTER (
            WHERE rs.logical_point_id = 'e2800629-bf0c-48f9-8174-7935618e7f90'::uuid
              AND rs.quality_code = 'GOOD'
              AND rs.profile_code = 'ENERGY_METER_ENISCOPE_V1'
        )::DOUBLE PRECISION AS apparent_power_l2_va,

        MAX(rs.numeric_value) FILTER (
            WHERE rs.logical_point_id = '40f1773e-6cf2-4a07-b25c-545151278989'::uuid
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
-- 2. Environment routing loader: identical bound.
-- ----------------------------------------------------------------------------
DROP PROCEDURE IF EXISTS telemetry.load_environment_measurements_incremental(interval);

CREATE OR REPLACE PROCEDURE telemetry.load_environment_measurements_incremental(IN p_overlap interval DEFAULT '00:15:00'::interval, IN p_max_window interval DEFAULT NULL)
 LANGUAGE plpgsql
AS $procedure$
DECLARE
    v_pipeline_name CONSTANT TEXT := 'environment_measurements';
    v_previous_checkpoint TIMESTAMPTZ;
    v_window_start TIMESTAMPTZ;
    v_window_end TIMESTAMPTZ;
    v_updated BIGINT := 0;
    v_inserted BIGINT := 0;
    v_lock_acquired BOOLEAN;
    v_now TIMESTAMPTZ := clock_timestamp();
BEGIN
    IF p_overlap IS NULL OR p_overlap < INTERVAL '0 seconds' THEN
        RAISE EXCEPTION 'p_overlap must be zero or positive';
    END IF;

    -- Migration 207: reject a non-positive explicit bound. NULL (the
    -- default, and what a direct/manual invocation passes) means "no
    -- bound" -- byte-for-byte the pre-207 behaviour.
    IF p_max_window IS NOT NULL AND p_max_window <= INTERVAL '0 seconds' THEN
        RAISE EXCEPTION 'p_max_window must be positive when supplied; received %', p_max_window;
    END IF;

    SELECT pg_try_advisory_xact_lock(hashtextextended('telemetry.load_environment_measurements_incremental',0))
    INTO v_lock_acquired;
    IF NOT v_lock_acquired THEN
        UPDATE telemetry.pipeline_state
        SET last_status='SKIPPED_LOCKED', last_error=NULL, updated_at=now()
        WHERE pipeline_name=v_pipeline_name;
        RETURN;
    END IF;

    SELECT last_received_at INTO v_previous_checkpoint
    FROM telemetry.pipeline_state
    WHERE pipeline_name=v_pipeline_name
    FOR UPDATE;

    UPDATE telemetry.pipeline_state
    SET last_started_at=clock_timestamp(), last_status='RUNNING', last_error=NULL, updated_at=now()
    WHERE pipeline_name=v_pipeline_name;

    SELECT max(platform_received_at) INTO v_window_end
    FROM telemetry.normalized_points
    WHERE platform_received_at IS NOT NULL;
    IF v_window_end IS NULL THEN
        UPDATE telemetry.pipeline_state
        SET last_completed_at=clock_timestamp(), last_inserted_rows=0,
            last_status='NO_SOURCE_DATA', updated_at=now()
        WHERE pipeline_name=v_pipeline_name;
        RETURN;
    END IF;

    -- Migration 207: cap the forward processing boundary to the previous
    -- checkpoint plus p_max_window when a caller supplies one and a
    -- previous checkpoint already exists. NULL (the default) leaves
    -- v_window_end exactly as computed above -- byte-for-byte the
    -- pre-207 behaviour. See telemetry.load_energy_measurements_incremental
    -- for the full rationale; this is the identical bound applied to the
    -- environment routing loader. Advisory lock, checkpoint keying,
    -- overlap semantics, the routing/calculation SQL below, and the
    -- EXCEPTION-rolls-back-the-watermark contract are all unchanged.
    IF p_max_window IS NOT NULL AND v_previous_checkpoint IS NOT NULL THEN
        v_window_end := LEAST(v_window_end, v_previous_checkpoint + p_max_window);
    END IF;

    -- Route from newly received normalized rows. Late source timestamps are
    -- discovered by their new platform receipt timestamp, so the historical
    -- correction tolerance does not need to be rescanned every minute.
    p_overlap := LEAST(p_overlap, INTERVAL '1 minute');

    v_window_start := CASE WHEN v_previous_checkpoint IS NULL
                           THEN '-infinity'::TIMESTAMPTZ
                           ELSE v_previous_checkpoint - p_overlap END;

    CREATE TEMP TABLE tmp_environment_candidates ON COMMIT DROP AS
    WITH window_events AS MATERIALIZED
    (
      SELECT np.device_id,np.event_time,MAX(np.platform_received_at) AS platform_received_at
      FROM telemetry.normalized_points np
      JOIN metadata.devices d ON d.id=np.device_id
      JOIN config.device_profiles dp ON dp.id=d.profile_id
      WHERE np.platform_received_at > v_window_start
        AND np.platform_received_at <= v_window_end
        AND dp.profile_code='ENVIRONMENT_SENSOR_AIRSENSE_V1'
        AND np.logical_point IN
        (
            'ENV_TEMPERATURE','ENV_RELATIVE_HUMIDITY','ENV_ILLUMINANCE_LUX',
            'OCCUPANCY_ACTIVITY','OCCUPANCY_SECONDS_SINCE_LAST_PIR_EVENT',
            'PULSE_INPUT_1_RAW','EXTERNAL_SENSOR_INPUT_1_RAW','EXTERNAL_SENSOR_INPUT_2_RAW',
            'EXTERNAL_SENSOR_INPUT_3_RAW','EXTERNAL_SENSOR_INPUT_4_RAW',
            'DEVICE_BATTERY_VOLTAGE','BATTERY_VOLTAGE','DEVICE_STATUS_CODE'
        )
      GROUP BY np.device_id,np.event_time
    ),
    full_resolution AS MATERIALIZED
    (
SELECT
    MAX(np.platform_received_at) AS received_at,
    np.event_time AS source_timestamp,
    np.organization_id,
    np.site_id,
    np.gateway_id,
    np.device_id,
    NULL::UUID AS asset_id,
    NULL::SMALLINT AS measurement_interval_seconds,
    NULL::SMALLINT AS quality_code,
    FALSE AS is_estimated,
    MAX(np.numeric_value) FILTER (WHERE np.logical_point = 'ENV_TEMPERATURE')::DOUBLE PRECISION AS temperature_c,
    MAX(np.numeric_value) FILTER (WHERE np.logical_point = 'ENV_RELATIVE_HUMIDITY')::DOUBLE PRECISION AS humidity_percent,
    NULL::DOUBLE PRECISION AS pressure_hpa,
    NULL::DOUBLE PRECISION AS co2_ppm,
    NULL::DOUBLE PRECISION AS voc_ppb,
    MAX(np.numeric_value) FILTER (WHERE np.logical_point IN ('BATTERY_VOLTAGE','DEVICE_BATTERY_VOLTAGE'))::DOUBLE PRECISION AS battery_voltage_v,
    NULL::DOUBLE PRECISION AS signal_strength_dbm,
    MAX(np.numeric_value) FILTER (WHERE np.logical_point = 'ENV_ILLUMINANCE_LUX')::DOUBLE PRECISION AS illuminance_lux,
    MAX(np.numeric_value) FILTER (WHERE np.logical_point = 'OCCUPANCY_ACTIVITY')::DOUBLE PRECISION AS occupancy_activity,
    NULL::BIGINT AS raw_archive_id,
    ROUND(MAX(np.numeric_value) FILTER (WHERE np.logical_point = 'OCCUPANCY_SECONDS_SINCE_LAST_PIR_EVENT'))::INTEGER AS seconds_since_last_pir_event,
    MAX(np.numeric_value) FILTER (WHERE np.logical_point = 'PULSE_INPUT_1_RAW')::DOUBLE PRECISION AS pulse_input_1_raw,
    MAX(np.numeric_value) FILTER (WHERE np.logical_point = 'EXTERNAL_SENSOR_INPUT_1_RAW')::DOUBLE PRECISION AS external_input_1_raw,
    MAX(np.numeric_value) FILTER (WHERE np.logical_point = 'EXTERNAL_SENSOR_INPUT_2_RAW')::DOUBLE PRECISION AS external_input_2_raw,
    MAX(np.numeric_value) FILTER (WHERE np.logical_point = 'EXTERNAL_SENSOR_INPUT_3_RAW')::DOUBLE PRECISION AS external_input_3_raw,
    MAX(np.numeric_value) FILTER (WHERE np.logical_point = 'EXTERNAL_SENSOR_INPUT_4_RAW')::DOUBLE PRECISION AS external_input_4_raw,
    ROUND(MAX(np.numeric_value) FILTER (WHERE np.logical_point = 'DEVICE_STATUS_CODE'))::INTEGER AS device_status_code
FROM window_events we
CROSS JOIN LATERAL
(
  SELECT src_np.*
  FROM telemetry.normalized_points src_np
  WHERE src_np.device_id = we.device_id
    AND src_np.event_time = we.event_time
  OFFSET 0
) np
JOIN metadata.devices d ON d.id = np.device_id
JOIN config.device_profiles dp ON dp.id = d.profile_id
WHERE dp.profile_code = 'ENVIRONMENT_SENSOR_AIRSENSE_V1'
  AND np.logical_point IN
  (
      'ENV_TEMPERATURE','ENV_RELATIVE_HUMIDITY','ENV_ILLUMINANCE_LUX',
      'OCCUPANCY_ACTIVITY','OCCUPANCY_SECONDS_SINCE_LAST_PIR_EVENT',
      'PULSE_INPUT_1_RAW','EXTERNAL_SENSOR_INPUT_1_RAW','EXTERNAL_SENSOR_INPUT_2_RAW',
      'EXTERNAL_SENSOR_INPUT_3_RAW','EXTERNAL_SENSOR_INPUT_4_RAW',
      'DEVICE_BATTERY_VOLTAGE','BATTERY_VOLTAGE','DEVICE_STATUS_CODE'
  )
GROUP BY np.event_time, np.organization_id, np.site_id, np.gateway_id, np.device_id
    ),
    resolved AS
    (
      SELECT fr.*,b.policy_id,b.capture_interval_seconds,
             b.late_arrival_tolerance_seconds,b.bucket_start
      FROM full_resolution fr
      CROSS JOIN LATERAL telemetry.resolve_site_capture_bucket
        (fr.site_id,COALESCE(fr.source_timestamp,fr.received_at)) AS b
    ),
    ranked AS
    (
      SELECT resolved.*,
             row_number() OVER
             (
               PARTITION BY resolved.device_id,resolved.policy_id,resolved.bucket_start
               ORDER BY COALESCE(resolved.source_timestamp,resolved.received_at) DESC,
                        resolved.received_at DESC NULLS LAST
             ) AS sample_rank
      FROM resolved
    )
    SELECT ranked.bucket_start,
           COALESCE(we.platform_received_at,ranked.received_at) AS received_at,
           ranked.source_timestamp,ranked.organization_id,ranked.site_id,ranked.gateway_id,
           ranked.device_id,ranked.asset_id,
           COALESCE(ranked.capture_interval_seconds,ranked.measurement_interval_seconds) AS measurement_interval_seconds,
           ranked.quality_code,ranked.is_estimated,ranked.temperature_c,ranked.humidity_percent,
           ranked.pressure_hpa,ranked.co2_ppm,ranked.voc_ppb,ranked.battery_voltage_v,
           ranked.signal_strength_dbm,ranked.illuminance_lux,ranked.occupancy_activity,
           ranked.raw_archive_id,ranked.seconds_since_last_pir_event,ranked.pulse_input_1_raw,
           ranked.external_input_1_raw,ranked.external_input_2_raw,ranked.external_input_3_raw,
           ranked.external_input_4_raw,ranked.device_status_code,
           ranked.bucket_start + make_interval(secs => ranked.capture_interval_seconds)
             + make_interval(secs => ranked.late_arrival_tolerance_seconds) AS correction_deadline
    FROM ranked
    JOIN window_events we
      ON we.device_id=ranked.device_id AND we.event_time=ranked.source_timestamp
    WHERE ranked.sample_rank=1
      AND ranked.bucket_start + make_interval(secs => COALESCE(ranked.capture_interval_seconds,1)) <= v_now;

    CREATE UNIQUE INDEX ON tmp_environment_candidates(bucket_start,device_id);

    UPDATE telemetry.environment_measurements t
    SET received_at=s.received_at,
        source_timestamp=s.source_timestamp,
        organization_id=s.organization_id,
        site_id=s.site_id,
        gateway_id=s.gateway_id,
        asset_id=COALESCE(s.asset_id,t.asset_id),
        measurement_interval_seconds=s.measurement_interval_seconds,
        quality_code=COALESCE(s.quality_code,t.quality_code),
        is_estimated=COALESCE(s.is_estimated,t.is_estimated),
        temperature_c=COALESCE(s.temperature_c,t.temperature_c),
        humidity_percent=COALESCE(s.humidity_percent,t.humidity_percent),
        pressure_hpa=COALESCE(s.pressure_hpa,t.pressure_hpa),
        co2_ppm=COALESCE(s.co2_ppm,t.co2_ppm),
        voc_ppb=COALESCE(s.voc_ppb,t.voc_ppb),
        battery_voltage_v=COALESCE(s.battery_voltage_v,t.battery_voltage_v),
        signal_strength_dbm=COALESCE(s.signal_strength_dbm,t.signal_strength_dbm),
        illuminance_lux=COALESCE(s.illuminance_lux,t.illuminance_lux),
        occupancy_activity=COALESCE(s.occupancy_activity,t.occupancy_activity),
        raw_archive_id=COALESCE(s.raw_archive_id,t.raw_archive_id),
        seconds_since_last_pir_event=COALESCE(s.seconds_since_last_pir_event,t.seconds_since_last_pir_event),
        pulse_input_1_raw=COALESCE(s.pulse_input_1_raw,t.pulse_input_1_raw),
        external_input_1_raw=COALESCE(s.external_input_1_raw,t.external_input_1_raw),
        external_input_2_raw=COALESCE(s.external_input_2_raw,t.external_input_2_raw),
        external_input_3_raw=COALESCE(s.external_input_3_raw,t.external_input_3_raw),
        external_input_4_raw=COALESCE(s.external_input_4_raw,t.external_input_4_raw),
        device_status_code=COALESCE(s.device_status_code,t.device_status_code)
    FROM tmp_environment_candidates s
    WHERE t.bucket_start=s.bucket_start
      AND t.device_id=s.device_id
      AND COALESCE(s.source_timestamp,s.received_at) >
          COALESCE(t.source_timestamp,t.received_at,'-infinity'::TIMESTAMPTZ)
      AND v_now <= s.correction_deadline;
    GET DIAGNOSTICS v_updated = ROW_COUNT;

    INSERT INTO telemetry.environment_measurements
    (
      bucket_start, received_at, source_timestamp,
      organization_id, site_id, gateway_id, device_id, asset_id,
      measurement_interval_seconds, quality_code, is_estimated,
      temperature_c, humidity_percent, pressure_hpa, co2_ppm, voc_ppb,
      battery_voltage_v, signal_strength_dbm, illuminance_lux, occupancy_activity,
      raw_archive_id, seconds_since_last_pir_event, pulse_input_1_raw,
      external_input_1_raw, external_input_2_raw, external_input_3_raw,
      external_input_4_raw, device_status_code
    )
    SELECT
      s.bucket_start, s.received_at, s.source_timestamp,
      s.organization_id, s.site_id, s.gateway_id, s.device_id, s.asset_id,
      s.measurement_interval_seconds, s.quality_code, s.is_estimated,
      s.temperature_c, s.humidity_percent, s.pressure_hpa, s.co2_ppm, s.voc_ppb,
      s.battery_voltage_v, s.signal_strength_dbm, s.illuminance_lux, s.occupancy_activity,
      s.raw_archive_id, s.seconds_since_last_pir_event, s.pulse_input_1_raw,
      s.external_input_1_raw, s.external_input_2_raw, s.external_input_3_raw,
      s.external_input_4_raw, s.device_status_code
    FROM tmp_environment_candidates s
    ON CONFLICT (bucket_start,device_id) WHERE device_id IS NOT NULL DO NOTHING;
    GET DIAGNOSTICS v_inserted = ROW_COUNT;

    UPDATE telemetry.pipeline_state
    SET last_received_at=v_window_end,
        last_completed_at=clock_timestamp(),
        last_inserted_rows=v_updated+v_inserted,
        last_status='SUCCESS', last_error=NULL, updated_at=now()
    WHERE pipeline_name=v_pipeline_name;

    RAISE NOTICE 'Environment routing succeeded: window=(%, %], updated=%, inserted=%',
      v_window_start, v_window_end, v_updated, v_inserted;
EXCEPTION WHEN OTHERS THEN
    UPDATE telemetry.pipeline_state
    SET last_completed_at=clock_timestamp(), last_inserted_rows=0,
        last_status='FAILED', last_error=SQLSTATE || ': ' || SQLERRM, updated_at=now()
    WHERE pipeline_name=v_pipeline_name;
    RAISE;
END;
$procedure$;

COMMENT ON PROCEDURE telemetry.load_environment_measurements_incremental(interval, interval) IS
'Incrementally routes closed-bucket normalized environment telemetry into telemetry.environment_measurements. Checkpoint is telemetry.pipeline_state(''environment_measurements'').last_received_at, keyed on telemetry.normalized_points.platform_received_at; a pg_try_advisory_xact_lock serialises concurrent runs; the single transaction''s EXCEPTION handler re-RAISEs, so a caught failure rolls back the watermark with the data. '
'Migration 207: p_max_window (default NULL) optionally caps the forward processing boundary to previous_checkpoint + p_max_window instead of always advancing to max(telemetry.normalized_points.platform_received_at). NULL preserves the exact prior behaviour. The scheduled wrapper telemetry.run_environment_routing_job passes a bounded value (default 2 hours, config.max_window-overridable) so an unattended multi-hour backlog self-drains. No intermediate COMMIT is introduced. Mirrors migration 205 / telemetry.load_energy_measurements_incremental().';

-- ----------------------------------------------------------------------------
-- 3. Scheduled wrappers: bounded by default (never pass NULL).
-- ----------------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE telemetry.run_energy_routing_job
(
    job_id INTEGER,
    config JSONB
)
LANGUAGE plpgsql
AS
$$
DECLARE
    v_overlap    INTERVAL := INTERVAL '15 minutes';
    v_max_window INTERVAL := INTERVAL '2 hours';
BEGIN
    IF config IS NOT NULL
       AND config ? 'overlap'
       AND NULLIF(BTRIM(config ->> 'overlap'), '') IS NOT NULL
    THEN
        v_overlap := (config ->> 'overlap')::INTERVAL;
    END IF;

    -- Migration 207: bounded catch-up. The scheduled action always passes a
    -- positive p_max_window so an unattended multi-hour normalized_points
    -- backlog self-drains over successive 1-minute runs rather than being
    -- attempted as one unbounded transaction. Tunable via config.max_window
    -- (alter_job, no code change); it is never cleared to NULL through this
    -- wrapper. Unrestricted catch-up remains available by CALLing
    -- telemetry.load_energy_measurements_incremental(...) directly.
    IF config IS NOT NULL
       AND config ? 'max_window'
       AND NULLIF(BTRIM(config ->> 'max_window'), '') IS NOT NULL
    THEN
        v_max_window := (config ->> 'max_window')::INTERVAL;
    END IF;

    IF v_overlap < INTERVAL '0 seconds' THEN
        RAISE EXCEPTION
            'Energy routing overlap cannot be negative: %',
            v_overlap;
    END IF;

    IF v_max_window IS NULL OR v_max_window <= INTERVAL '0 seconds' THEN
        RAISE EXCEPTION
            'Energy routing max_window must be a positive interval: %',
            v_max_window;
    END IF;

    RAISE NOTICE
        'Starting energy routing job %, overlap=%, max_window=%',
        job_id,
        v_overlap,
        v_max_window;

    CALL telemetry.load_energy_measurements_incremental(v_overlap, v_max_window);

    RAISE NOTICE
        'Completed energy routing job %',
        job_id;
END;
$$;

COMMENT ON PROCEDURE telemetry.run_energy_routing_job(INTEGER, JSONB) IS
'TimescaleDB background action that incrementally routes normalized telemetry into the energy domain hypertable. Migration 207: always passes a bounded p_max_window (default INTERVAL ''2 hours'', overridable via config.max_window) to telemetry.load_energy_measurements_incremental(), so an unattended multi-hour normalized_points backlog self-drains over successive 1-minute runs. Never passes NULL; unrestricted catch-up is a direct manual CALL of the loader.';

CREATE OR REPLACE PROCEDURE telemetry.run_environment_routing_job
(
    job_id INTEGER,
    config JSONB
)
LANGUAGE plpgsql
AS
$$
DECLARE
    v_overlap    INTERVAL := INTERVAL '15 minutes';
    v_max_window INTERVAL := INTERVAL '2 hours';
BEGIN
    IF config IS NOT NULL
       AND config ? 'overlap'
       AND NULLIF(BTRIM(config ->> 'overlap'), '') IS NOT NULL
    THEN
        v_overlap := (config ->> 'overlap')::INTERVAL;
    END IF;

    -- Migration 207: bounded catch-up (see telemetry.run_energy_routing_job
    -- for the full rationale). Never passes NULL to the loader.
    IF config IS NOT NULL
       AND config ? 'max_window'
       AND NULLIF(BTRIM(config ->> 'max_window'), '') IS NOT NULL
    THEN
        v_max_window := (config ->> 'max_window')::INTERVAL;
    END IF;

    IF v_max_window IS NULL OR v_max_window <= INTERVAL '0 seconds' THEN
        RAISE EXCEPTION
            'Environment routing max_window must be a positive interval: %',
            v_max_window;
    END IF;

    CALL telemetry.load_environment_measurements_incremental(v_overlap, v_max_window);
END;
$$;

COMMENT ON PROCEDURE telemetry.run_environment_routing_job(INTEGER, JSONB) IS
'TimescaleDB background action that incrementally routes normalized environment telemetry into telemetry.environment_measurements. Migration 207: always passes a bounded p_max_window (default INTERVAL ''2 hours'', overridable via config.max_window) to telemetry.load_environment_measurements_incremental(); never passes NULL.';

-- ----------------------------------------------------------------------------
-- 4. Record the bound in the live job config (idempotent, order-independent).
--    Merges the max_window key into whatever config the job already carries,
--    preserving config.overlap. Skips silently if the job is not registered
--    (e.g. a migration-only apply before postgres/jobs/* has run).
-- ----------------------------------------------------------------------------
DO $$
DECLARE
    r RECORD;
BEGIN
    FOR r IN
        SELECT job_id, config
        FROM timescaledb_information.jobs
        WHERE proc_schema = 'telemetry'
          AND proc_name IN ('run_energy_routing_job', 'run_environment_routing_job')
    LOOP
        IF NOT (COALESCE(r.config, '{}'::jsonb) ? 'max_window') THEN
            PERFORM alter_job(
                r.job_id,
                config => COALESCE(r.config, '{}'::jsonb)
                          || jsonb_build_object('max_window', '2 hours')
            );
            RAISE NOTICE 'Migration 207: added config.max_window=''2 hours'' to job %', r.job_id;
        END IF;
    END LOOP;
END $$;

COMMIT;
