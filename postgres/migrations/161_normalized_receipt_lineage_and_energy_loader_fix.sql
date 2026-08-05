-- 161_normalized_receipt_lineage_and_energy_loader_fix.sql
-- Forward fix for migration 160. Keeps energy routing disabled until verified.


ALTER TABLE telemetry.normalized_points
ADD COLUMN IF NOT EXISTS platform_received_at TIMESTAMPTZ;

COMMENT ON COLUMN telemetry.normalized_points.platform_received_at IS
'Actual platform receipt timestamp inherited from telemetry.raw_messages through telemetry.v_normalized_points.';

CREATE INDEX IF NOT EXISTS normalized_points_platform_received_at_idx
ON telemetry.normalized_points (platform_received_at DESC)
WHERE platform_received_at IS NOT NULL;

CREATE OR REPLACE PROCEDURE telemetry.load_normalized_points_incremental
(
    p_overlap INTERVAL DEFAULT INTERVAL '15 minutes'
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_pipeline_name CONSTANT TEXT := 'normalized_points';
    v_previous_checkpoint TIMESTAMPTZ;
    v_window_start TIMESTAMPTZ;
    v_window_end TIMESTAMPTZ;
    v_inserted_rows BIGINT := 0;
    v_lock_acquired BOOLEAN;
BEGIN
    IF p_overlap IS NULL OR p_overlap < INTERVAL '0 seconds' THEN
        RAISE EXCEPTION 'p_overlap must be zero or positive; received %', p_overlap;
    END IF;

    SELECT pg_try_advisory_xact_lock(hashtextextended('telemetry.load_normalized_points_incremental', 0))
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

    SELECT max(received_at) INTO v_window_end FROM telemetry.raw_messages;

    IF v_window_end IS NULL THEN
        UPDATE telemetry.pipeline_state
        SET last_completed_at=clock_timestamp(), last_inserted_rows=0,
            last_status='NO_SOURCE_DATA', last_error=NULL, updated_at=now()
        WHERE pipeline_name=v_pipeline_name;
        RETURN;
    END IF;

    v_window_start := CASE
      WHEN v_previous_checkpoint IS NULL THEN '-infinity'::timestamptz
      ELSE v_previous_checkpoint - p_overlap
    END;

    INSERT INTO telemetry.normalized_points
    (
      event_time, organization_id, site_id, gateway_id, device_id,
      logical_point_id, device_uid, logical_point, raw_field_name,
      raw_value, numeric_value, quality_code, mapping_source, payload,
      platform_received_at
    )
    SELECT
      np.event_time, np.organization_id, np.site_id, np.gateway_id, np.device_id,
      np.logical_point_id, np.device_uid, np.logical_point, np.raw_field_name,
      np.raw_value, np.numeric_value, np.quality_code, np.mapping_source, np.payload,
      np.received_at
    FROM telemetry.v_normalized_points np
    WHERE np.received_at > v_window_start
      AND np.received_at <= v_window_end
    ON CONFLICT (event_time, device_id, logical_point_id) DO UPDATE
    SET platform_received_at = EXCLUDED.platform_received_at
    WHERE telemetry.normalized_points.platform_received_at IS NULL
       OR EXCLUDED.platform_received_at > telemetry.normalized_points.platform_received_at;

    GET DIAGNOSTICS v_inserted_rows = ROW_COUNT;

    UPDATE telemetry.pipeline_state
    SET last_received_at=v_window_end, last_completed_at=clock_timestamp(),
        last_inserted_rows=v_inserted_rows, last_status='SUCCESS',
        last_error=NULL, updated_at=now()
    WHERE pipeline_name=v_pipeline_name;
EXCEPTION WHEN OTHERS THEN
    UPDATE telemetry.pipeline_state
    SET last_completed_at=clock_timestamp(), last_inserted_rows=0,
        last_status='FAILED', last_error=SQLSTATE || ': ' || SQLERRM,
        updated_at=now()
    WHERE pipeline_name=v_pipeline_name;
    RAISE;
END;
$$;

CREATE OR REPLACE FUNCTION telemetry.capture_bucket_correction_deadline
(
    p_site_id UUID,
    p_bucket_start TIMESTAMPTZ
)
RETURNS TIMESTAMPTZ
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    v_interval_seconds INTEGER := 1;
    v_tolerance_seconds INTEGER := 900;
BEGIN
    SELECT
        p.capture_interval_seconds,
        p.late_arrival_tolerance_seconds
    INTO
        v_interval_seconds,
        v_tolerance_seconds
    FROM config.telemetry_capture_policies p
    WHERE p.is_enabled
      AND (p.site_id = p_site_id OR p.site_id IS NULL)
      AND p_bucket_start >= p.effective_from
      AND (p.effective_to IS NULL OR p_bucket_start < p.effective_to)
    ORDER BY (p.site_id IS NOT NULL) DESC, p.effective_from DESC, p.id DESC
    LIMIT 1;

    RETURN p_bucket_start
        + make_interval(secs => COALESCE(v_interval_seconds, 1))
        + make_interval(secs => COALESCE(v_tolerance_seconds, 900));
END;
$$;

REVOKE ALL ON FUNCTION telemetry.capture_bucket_correction_deadline(UUID,TIMESTAMPTZ) FROM PUBLIC;

DROP VIEW telemetry.v_energy_measurements_route;

CREATE VIEW telemetry.v_energy_measurements_route AS
WITH resolved AS
(
    SELECT
        r.*,
        bucket.policy_id,
        bucket.capture_interval_seconds,
        bucket.late_arrival_tolerance_seconds,
        bucket.bucket_start
    FROM telemetry.v_energy_measurements_full_resolution r
    CROSS JOIN LATERAL telemetry.resolve_site_capture_bucket
    (
        r.site_id,
        COALESCE(r.source_timestamp, r.received_at)
    ) AS bucket
),
ranked AS
(
    SELECT
        resolved.*,
        row_number() OVER
        (
            PARTITION BY resolved.device_id, resolved.policy_id, resolved.bucket_start
            ORDER BY COALESCE(resolved.source_timestamp, resolved.received_at) DESC,
                     resolved.received_at DESC
        ) AS sample_rank
    FROM resolved
)
SELECT
    ranked.bucket_start,
    COALESCE
    (
        (
            SELECT MAX(np.platform_received_at)
            FROM telemetry.normalized_points np
            WHERE np.device_id = ranked.device_id
              AND np.event_time = ranked.source_timestamp
        ),
        ranked.received_at
    ) AS received_at,
    ranked.source_timestamp,
    ranked.organization_id,
    ranked.site_id,
    ranked.gateway_id,
    ranked.device_id,
    ranked.asset_id,
    ranked.import_energy_total_wh,
    ranked.import_energy_l1_wh,
    ranked.import_energy_l2_wh,
    ranked.import_energy_l3_wh,
    ranked.export_energy_total_wh,
    ranked.export_energy_l1_wh,
    ranked.export_energy_l2_wh,
    ranked.export_energy_l3_wh,
    ranked.reactive_energy_total_varh,
    ranked.reactive_energy_l1_varh,
    ranked.reactive_energy_l2_varh,
    ranked.reactive_energy_l3_varh,
    ranked.reactive_export_energy_total_varh,
    ranked.reactive_export_energy_l1_varh,
    ranked.reactive_export_energy_l2_varh,
    ranked.reactive_export_energy_l3_varh,
    ranked.apparent_energy_total_vah,
    ranked.apparent_energy_l1_vah,
    ranked.apparent_energy_l2_vah,
    ranked.apparent_energy_l3_vah,
    ranked.active_power_total_w,
    ranked.active_power_l1_w,
    ranked.active_power_l2_w,
    ranked.active_power_l3_w,
    ranked.reactive_power_total_var,
    ranked.reactive_power_l1_var,
    ranked.reactive_power_l2_var,
    ranked.reactive_power_l3_var,
    ranked.apparent_power_total_va,
    ranked.apparent_power_l1_va,
    ranked.apparent_power_l2_va,
    ranked.apparent_power_l3_va,
    ranked.voltage_ln_avg_v,
    ranked.voltage_l1_v,
    ranked.voltage_l2_v,
    ranked.voltage_l3_v,
    ranked.voltage_ll_avg_v,
    ranked.voltage_l12_v,
    ranked.voltage_l23_v,
    ranked.voltage_l31_v,
    ranked.current_total_a,
    ranked.current_l1_a,
    ranked.current_l2_a,
    ranked.current_l3_a,
    ranked.neutral_current_a,
    ranked.power_factor_total,
    ranked.power_factor_l1,
    ranked.power_factor_l2,
    ranked.power_factor_l3,
    ranked.frequency_hz,
    ranked.phase_angle_l1_deg,
    ranked.phase_angle_l2_deg,
    ranked.phase_angle_l3_deg,
    ranked.current_thd_total_percent,
    ranked.current_thd_l1_percent,
    ranked.current_thd_l2_percent,
    ranked.current_thd_l3_percent,
    ranked.pulse_count,
    ranked.populated_point_count,
    ranked.invalid_point_count
FROM ranked
WHERE ranked.sample_rank = 1
  AND ranked.bucket_start
      + make_interval(secs => COALESCE(ranked.capture_interval_seconds, 1))
      <= clock_timestamp();

COMMENT ON VIEW telemetry.v_energy_measurements_route IS
'Closed-bucket energy route. bucket_start identifies the aligned interval; received_at preserves actual platform receipt time; source_timestamp preserves device event time.';


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

  SELECT max(created_at) INTO v_window_end FROM telemetry.normalized_points;
  IF v_window_end IS NULL THEN
    UPDATE telemetry.pipeline_state
    SET last_completed_at=clock_timestamp(),last_inserted_rows=0,last_status='NO_SOURCE_DATA',last_error=NULL,updated_at=now()
    WHERE pipeline_name=v_pipeline_name;
    RETURN;
  END IF;

  SELECT GREATEST
  (
      p_overlap,
      make_interval
      (
          secs => COALESCE
          (
              MAX(late_arrival_tolerance_seconds),
              900
          )
      )
  )
  INTO p_overlap
  FROM config.telemetry_capture_policies
  WHERE is_enabled;

  v_window_start := CASE WHEN v_previous_checkpoint IS NULL THEN '-infinity'::timestamptz ELSE v_previous_checkpoint-p_overlap END;

  WITH affected_events AS
  (
    SELECT DISTINCT
        bucket.bucket_start AS bucket_start,
        np.device_id
    FROM telemetry.normalized_points np
    JOIN metadata.devices d
      ON d.id = np.device_id
    LEFT JOIN metadata.gateways g
      ON g.id = d.gateway_id
    CROSS JOIN LATERAL telemetry.resolve_site_capture_bucket
    (
        COALESCE(np.site_id, g.site_id),
        np.event_time
    ) AS bucket
    WHERE
      (
          (np.created_at > v_window_start AND np.created_at <= v_window_end)
          OR np.event_time >= v_now - p_overlap - INTERVAL '15 minutes'
      )
      AND bucket.bucket_start
          + make_interval(secs => COALESCE(bucket.capture_interval_seconds, 1))
          <= v_now
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
        r.bucket_start, r.received_at, r.source_timestamp, r.organization_id, r.site_id, r.gateway_id, r.device_id, r.asset_id,
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
  FROM affected_events ae
  JOIN telemetry.v_energy_measurements_route r
    ON r.bucket_start=ae.bucket_start AND r.device_id=ae.device_id
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



-- Safety: this migration does not enable the energy routing job.
