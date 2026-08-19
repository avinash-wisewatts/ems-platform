-- 004_bounded_domain_routing.sql
-- Genuinely incremental energy/environment routing. The background loaders
-- materialize only source events received inside the bounded checkpoint window;
-- public route views remain unchanged for compatibility and diagnostics.
BEGIN;

CREATE OR REPLACE PROCEDURE telemetry.load_energy_measurements_incremental
(
  p_overlap INTERVAL DEFAULT INTERVAL '15 minutes'
)
LANGUAGE plpgsql
AS $$
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
  FROM telemetry.normalized_points np
  JOIN window_events we
    ON we.device_id=np.device_id AND we.event_time=np.event_time
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
            WHERE rs.logical_point = 'ENERGY_REACTIVE_ENERGY_TOTAL'
              AND rs.quality_code = 'GOOD'
              AND rs.scale_to_normalized_unit IS NOT NULL
        ) AS reactive_energy_total_varh,

        MAX(rs.numeric_value * rs.scale_to_normalized_unit) FILTER (
            WHERE rs.logical_point = 'ENERGY_REACTIVE_ENERGY_L1'
              AND rs.quality_code = 'GOOD'
              AND rs.scale_to_normalized_unit IS NOT NULL
        ) AS reactive_energy_l1_varh,

        MAX(rs.numeric_value * rs.scale_to_normalized_unit) FILTER (
            WHERE rs.logical_point = 'ENERGY_REACTIVE_ENERGY_L2'
              AND rs.quality_code = 'GOOD'
              AND rs.scale_to_normalized_unit IS NOT NULL
        ) AS reactive_energy_l2_varh,

        MAX(rs.numeric_value * rs.scale_to_normalized_unit) FILTER (
            WHERE rs.logical_point = 'ENERGY_REACTIVE_ENERGY_L3'
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
            WHERE rs.logical_point = 'ENERGY_APPARENT_ENERGY_TOTAL'
              AND rs.quality_code = 'GOOD'
              AND rs.scale_to_normalized_unit IS NOT NULL
        ) AS apparent_energy_total_vah,

        MAX(rs.numeric_value * rs.scale_to_normalized_unit) FILTER (
            WHERE rs.logical_point = 'ENERGY_APPARENT_ENERGY_L1'
              AND rs.quality_code = 'GOOD'
              AND rs.scale_to_normalized_unit IS NOT NULL
        ) AS apparent_energy_l1_vah,

        MAX(rs.numeric_value * rs.scale_to_normalized_unit) FILTER (
            WHERE rs.logical_point = 'ENERGY_APPARENT_ENERGY_L2'
              AND rs.quality_code = 'GOOD'
              AND rs.scale_to_normalized_unit IS NOT NULL
        ) AS apparent_energy_l2_vah,

        MAX(rs.numeric_value * rs.scale_to_normalized_unit) FILTER (
            WHERE rs.logical_point = 'ENERGY_APPARENT_ENERGY_L3'
              AND rs.quality_code = 'GOOD'
              AND rs.scale_to_normalized_unit IS NOT NULL
        ) AS apparent_energy_l3_vah,

        MAX(rs.numeric_value) FILTER (
            WHERE rs.logical_point = 'ENERGY_ACTIVE_POWER_TOTAL'
              AND rs.quality_code = 'GOOD'
              AND rs.profile_code = 'ENERGY_METER_ENISCOPE_V1'
        )::DOUBLE PRECISION AS active_power_total_w,

        MAX(rs.numeric_value) FILTER (
            WHERE rs.logical_point = 'ENERGY_ACTIVE_POWER_L1'
              AND rs.quality_code = 'GOOD'
              AND rs.profile_code = 'ENERGY_METER_ENISCOPE_V1'
        )::DOUBLE PRECISION AS active_power_l1_w,

        MAX(rs.numeric_value) FILTER (
            WHERE rs.logical_point = 'ENERGY_ACTIVE_POWER_L2'
              AND rs.quality_code = 'GOOD'
              AND rs.profile_code = 'ENERGY_METER_ENISCOPE_V1'
        )::DOUBLE PRECISION AS active_power_l2_w,

        MAX(rs.numeric_value) FILTER (
            WHERE rs.logical_point = 'ENERGY_ACTIVE_POWER_L3'
              AND rs.quality_code = 'GOOD'
              AND rs.profile_code = 'ENERGY_METER_ENISCOPE_V1'
        )::DOUBLE PRECISION AS active_power_l3_w,

        MAX(rs.numeric_value) FILTER (
            WHERE rs.logical_point = 'ENERGY_REACTIVE_POWER_TOTAL'
              AND rs.quality_code = 'GOOD'
              AND rs.profile_code = 'ENERGY_METER_ENISCOPE_V1'
        )::DOUBLE PRECISION AS reactive_power_total_var,

        MAX(rs.numeric_value) FILTER (
            WHERE rs.logical_point = 'ENERGY_REACTIVE_POWER_L1'
              AND rs.quality_code = 'GOOD'
              AND rs.profile_code = 'ENERGY_METER_ENISCOPE_V1'
        )::DOUBLE PRECISION AS reactive_power_l1_var,

        MAX(rs.numeric_value) FILTER (
            WHERE rs.logical_point = 'ENERGY_REACTIVE_POWER_L2'
              AND rs.quality_code = 'GOOD'
              AND rs.profile_code = 'ENERGY_METER_ENISCOPE_V1'
        )::DOUBLE PRECISION AS reactive_power_l2_var,

        MAX(rs.numeric_value) FILTER (
            WHERE rs.logical_point = 'ENERGY_REACTIVE_POWER_L3'
              AND rs.quality_code = 'GOOD'
              AND rs.profile_code = 'ENERGY_METER_ENISCOPE_V1'
        )::DOUBLE PRECISION AS reactive_power_l3_var,

        MAX(rs.numeric_value) FILTER (
            WHERE rs.logical_point = 'ENERGY_APPARENT_POWER_TOTAL'
              AND rs.quality_code = 'GOOD'
              AND rs.profile_code = 'ENERGY_METER_ENISCOPE_V1'
        )::DOUBLE PRECISION AS apparent_power_total_va,

        MAX(rs.numeric_value) FILTER (
            WHERE rs.logical_point = 'ENERGY_APPARENT_POWER_L1'
              AND rs.quality_code = 'GOOD'
              AND rs.profile_code = 'ENERGY_METER_ENISCOPE_V1'
        )::DOUBLE PRECISION AS apparent_power_l1_va,

        MAX(rs.numeric_value) FILTER (
            WHERE rs.logical_point = 'ENERGY_APPARENT_POWER_L2'
              AND rs.quality_code = 'GOOD'
              AND rs.profile_code = 'ENERGY_METER_ENISCOPE_V1'
        )::DOUBLE PRECISION AS apparent_power_l2_va,

        MAX(rs.numeric_value) FILTER (
            WHERE rs.logical_point = 'ENERGY_APPARENT_POWER_L3'
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
$$;

CREATE OR REPLACE PROCEDURE telemetry.load_environment_measurements_incremental
(
    p_overlap INTERVAL DEFAULT INTERVAL '15 minutes'
)
LANGUAGE plpgsql
AS $$
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
FROM telemetry.normalized_points np
JOIN window_events we
  ON we.device_id=np.device_id AND we.event_time=np.event_time
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
$$;

COMMIT;
