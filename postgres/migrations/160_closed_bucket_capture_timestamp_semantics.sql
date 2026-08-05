-- ============================================================================
-- 160_closed_bucket_capture_timestamp_semantics.sql
--
-- Correct domain-table timestamp semantics and close-bucket persistence:
--   bucket_start     aligned site-policy interval identifier / hypertable time
--   received_at      actual platform receipt timestamp of selected message
--   source_timestamp device-reported event timestamp
--
-- Existing sampled rows retain their historical bucket_start. Their actual
-- platform receipt timestamp cannot be reconstructed reliably and remains NULL.
-- New rows are inserted only after the bucket closes. A genuinely newer late
-- record may correct a closed bucket only within the configured tolerance.
-- ============================================================================

-- Keep the existing TimescaleDB time dimension on the same physical column by
-- renaming it. PostgreSQL/Timescale dependencies follow the column rename.
ALTER TABLE telemetry.energy_measurements
RENAME COLUMN received_at TO bucket_start;

ALTER TABLE telemetry.environment_measurements
RENAME COLUMN received_at TO bucket_start;

ALTER TABLE telemetry.energy_measurements
ADD COLUMN received_at TIMESTAMPTZ;

ALTER TABLE telemetry.environment_measurements
ADD COLUMN received_at TIMESTAMPTZ;

COMMENT ON COLUMN telemetry.energy_measurements.bucket_start IS
'Aligned site-policy capture interval start and TimescaleDB time dimension.';
COMMENT ON COLUMN telemetry.energy_measurements.received_at IS
'Actual platform receipt timestamp of the selected raw/full-resolution message. NULL only for rows created before migration 160.';
COMMENT ON COLUMN telemetry.energy_measurements.source_timestamp IS
'Device-reported event timestamp for the selected measurement.';

COMMENT ON COLUMN telemetry.environment_measurements.bucket_start IS
'Aligned site-policy capture interval start and TimescaleDB time dimension.';
COMMENT ON COLUMN telemetry.environment_measurements.received_at IS
'Actual platform receipt timestamp of the selected raw/full-resolution message. NULL only for rows created before migration 160.';
COMMENT ON COLUMN telemetry.environment_measurements.source_timestamp IS
'Device-reported event timestamp for the selected measurement.';

-- Rebuild identity indexes on the aligned bucket key. This remains valid for
-- TimescaleDB because bucket_start is the hypertable partitioning column.
DROP INDEX IF EXISTS telemetry.uq_energy_measurements_identity;
CREATE UNIQUE INDEX uq_energy_measurements_identity
ON telemetry.energy_measurements (bucket_start, device_id);

DROP INDEX IF EXISTS telemetry.uq_environment_measurements_received_device;
CREATE UNIQUE INDEX uq_environment_measurements_bucket_device
ON telemetry.environment_measurements (bucket_start, device_id)
WHERE device_id IS NOT NULL;

-- Make index names match their actual semantics and add receipt-time indexes.
DO $$
BEGIN
    IF to_regclass('telemetry.energy_measurements_received_at_idx') IS NOT NULL
       AND to_regclass('telemetry.energy_measurements_bucket_start_idx') IS NULL THEN
        ALTER INDEX telemetry.energy_measurements_received_at_idx
        RENAME TO energy_measurements_bucket_start_idx;
    END IF;

    IF to_regclass('telemetry.environment_measurements_received_at_idx') IS NOT NULL
       AND to_regclass('telemetry.environment_measurements_bucket_start_idx') IS NULL THEN
        ALTER INDEX telemetry.environment_measurements_received_at_idx
        RENAME TO environment_measurements_bucket_start_idx;
    END IF;
END;
$$;

CREATE INDEX IF NOT EXISTS energy_measurements_received_at_idx
ON telemetry.energy_measurements (received_at DESC)
WHERE received_at IS NOT NULL;

CREATE INDEX IF NOT EXISTS environment_measurements_received_at_idx
ON telemetry.environment_measurements (received_at DESC)
WHERE received_at IS NOT NULL;

-- Replace sampled routes. The full-resolution source views remain unchanged.
DROP VIEW telemetry.v_energy_measurements_route;
DROP VIEW telemetry.v_environment_measurements_route;

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
    ranked.received_at,
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

CREATE VIEW telemetry.v_environment_measurements_route AS
WITH resolved AS
(
    SELECT
        r.*,
        bucket.policy_id,
        bucket.capture_interval_seconds,
        bucket.late_arrival_tolerance_seconds,
        bucket.bucket_start
    FROM telemetry.v_environment_measurements_full_resolution r
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
    ranked.received_at,
    ranked.source_timestamp,
    ranked.organization_id,
    ranked.site_id,
    ranked.gateway_id,
    ranked.device_id,
    ranked.asset_id,
    COALESCE(ranked.capture_interval_seconds, ranked.measurement_interval_seconds) AS measurement_interval_seconds,
    ranked.quality_code,
    ranked.is_estimated,
    ranked.temperature_c,
    ranked.humidity_percent,
    ranked.pressure_hpa,
    ranked.co2_ppm,
    ranked.voc_ppb,
    ranked.battery_voltage_v,
    ranked.signal_strength_dbm,
    ranked.illuminance_lux,
    ranked.occupancy_activity,
    ranked.raw_archive_id
FROM ranked
WHERE ranked.sample_rank = 1
  AND ranked.bucket_start
      + make_interval(secs => COALESCE(ranked.capture_interval_seconds, 1))
      <= clock_timestamp();

COMMENT ON VIEW telemetry.v_environment_measurements_route IS
'Closed-bucket environment route. bucket_start identifies the aligned interval; received_at preserves actual platform receipt time; source_timestamp preserves device event time.';

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
    AND v_now <= EXCLUDED.bucket_start
        + make_interval
          (
              secs => COALESCE
              (
                  (
                      SELECT p.capture_interval_seconds
                      FROM config.telemetry_capture_policies p
                      WHERE p.is_enabled
                        AND (p.site_id = EXCLUDED.site_id OR p.site_id IS NULL)
                        AND EXCLUDED.bucket_start >= p.effective_from
                        AND (p.effective_to IS NULL OR EXCLUDED.bucket_start < p.effective_to)
                      ORDER BY (p.site_id IS NOT NULL) DESC, p.effective_from DESC, p.id DESC
                      LIMIT 1
                  ),
                  1
              )
          )
        + make_interval
          (
              secs => COALESCE
              (
                  (
                      SELECT p.late_arrival_tolerance_seconds
                      FROM config.telemetry_capture_policies p
                      WHERE p.is_enabled
                        AND (p.site_id = EXCLUDED.site_id OR p.site_id IS NULL)
                        AND EXCLUDED.bucket_start >= p.effective_from
                        AND (p.effective_to IS NULL OR EXCLUDED.bucket_start < p.effective_to)
                      ORDER BY (p.site_id IS NOT NULL) DESC, p.effective_from DESC, p.id DESC
                      LIMIT 1
                  ),
                  900
              )
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
AS
$$
DECLARE
    v_pipeline_name CONSTANT TEXT := 'environment_measurements';

    v_previous_checkpoint TIMESTAMPTZ;
    v_window_start        TIMESTAMPTZ;
    v_window_end          TIMESTAMPTZ;

    v_affected_rows BIGINT := 0;
    v_lock_acquired BOOLEAN;
    v_now TIMESTAMPTZ := clock_timestamp();
BEGIN

    IF p_overlap IS NULL
       OR p_overlap < INTERVAL '0 seconds'
    THEN
        RAISE EXCEPTION
            'p_overlap must be zero or positive';
    END IF;


    ------------------------------------------------------------------------
    -- Advisory lock.
    ------------------------------------------------------------------------

    SELECT pg_try_advisory_xact_lock
    (
        hashtextextended
        (
            'telemetry.load_environment_measurements_incremental',
            0
        )
    )
    INTO v_lock_acquired;


    IF NOT v_lock_acquired THEN

        UPDATE telemetry.pipeline_state
        SET
            last_status = 'SKIPPED_LOCKED',
            last_error  = NULL,
            updated_at  = now()
        WHERE pipeline_name = v_pipeline_name;

        RETURN;
    END IF;


    ------------------------------------------------------------------------
    -- Pipeline checkpoint.
    ------------------------------------------------------------------------

    SELECT last_received_at
    INTO v_previous_checkpoint
    FROM telemetry.pipeline_state
    WHERE pipeline_name = v_pipeline_name
    FOR UPDATE;


    UPDATE telemetry.pipeline_state
    SET
        last_started_at = clock_timestamp(),
        last_status     = 'RUNNING',
        last_error      = NULL,
        updated_at      = now()
    WHERE pipeline_name = v_pipeline_name;


    ------------------------------------------------------------------------
    -- Freeze source window.
    ------------------------------------------------------------------------

    SELECT MAX(created_at)
    INTO v_window_end
    FROM telemetry.normalized_points;


    IF v_window_end IS NULL THEN

        UPDATE telemetry.pipeline_state
        SET
            last_completed_at  = clock_timestamp(),
            last_inserted_rows = 0,
            last_status        = 'NO_SOURCE_DATA',
            updated_at         = now()
        WHERE pipeline_name = v_pipeline_name;

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

    v_window_start :=
        CASE
            WHEN v_previous_checkpoint IS NULL
            THEN '-infinity'::TIMESTAMPTZ
            ELSE v_previous_checkpoint - p_overlap
        END;


    ------------------------------------------------------------------------
    -- Incremental UPSERT.
    ------------------------------------------------------------------------

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

    INSERT INTO telemetry.environment_measurements
    (
        bucket_start,
        received_at,
        source_timestamp,

        organization_id,
        site_id,
        gateway_id,
        device_id,
        asset_id,

        measurement_interval_seconds,
        quality_code,
        is_estimated,

        temperature_c,
        humidity_percent,
        pressure_hpa,
        co2_ppm,
        voc_ppb,

        battery_voltage_v,
        signal_strength_dbm,

        illuminance_lux,
        occupancy_activity,

        raw_archive_id
    )

    SELECT
        r.bucket_start,
        r.received_at,
        r.source_timestamp,

        r.organization_id,
        r.site_id,
        r.gateway_id,
        r.device_id,
        r.asset_id,

        r.measurement_interval_seconds,
        r.quality_code,
        r.is_estimated,

        r.temperature_c,
        r.humidity_percent,
        r.pressure_hpa,
        r.co2_ppm,
        r.voc_ppb,

        r.battery_voltage_v,
        r.signal_strength_dbm,

        r.illuminance_lux,
        r.occupancy_activity,

        r.raw_archive_id

    FROM affected_events ae

    JOIN telemetry.v_environment_measurements_route r
      ON r.bucket_start = ae.bucket_start
     AND r.device_id   = ae.device_id

    ON CONFLICT
    (
        bucket_start,
        device_id
    )
    WHERE device_id IS NOT NULL
    DO UPDATE
    SET

        received_at =
            EXCLUDED.received_at,

        source_timestamp =
            EXCLUDED.source_timestamp,

        organization_id =
            EXCLUDED.organization_id,

        site_id =
            EXCLUDED.site_id,

        gateway_id =
            EXCLUDED.gateway_id,

        asset_id =
            COALESCE(
                EXCLUDED.asset_id,
                telemetry.environment_measurements.asset_id
            ),

        temperature_c =
            COALESCE(
                EXCLUDED.temperature_c,
                telemetry.environment_measurements.temperature_c
            ),

        humidity_percent =
            COALESCE(
                EXCLUDED.humidity_percent,
                telemetry.environment_measurements.humidity_percent
            ),

        pressure_hpa =
            COALESCE(
                EXCLUDED.pressure_hpa,
                telemetry.environment_measurements.pressure_hpa
            ),

        co2_ppm =
            COALESCE(
                EXCLUDED.co2_ppm,
                telemetry.environment_measurements.co2_ppm
            ),

        voc_ppb =
            COALESCE(
                EXCLUDED.voc_ppb,
                telemetry.environment_measurements.voc_ppb
            ),

        battery_voltage_v =
            COALESCE(
                EXCLUDED.battery_voltage_v,
                telemetry.environment_measurements.battery_voltage_v
            ),

        signal_strength_dbm =
            COALESCE(
                EXCLUDED.signal_strength_dbm,
                telemetry.environment_measurements.signal_strength_dbm
            ),

        illuminance_lux =
            COALESCE(
                EXCLUDED.illuminance_lux,
                telemetry.environment_measurements.illuminance_lux
            ),

        occupancy_activity =
            COALESCE(
                EXCLUDED.occupancy_activity,
                telemetry.environment_measurements.occupancy_activity
            )

    WHERE
        COALESCE(EXCLUDED.source_timestamp, EXCLUDED.received_at)
            > COALESCE(
                telemetry.environment_measurements.source_timestamp,
                telemetry.environment_measurements.received_at,
                '-infinity'::timestamptz
              )
      AND v_now <= EXCLUDED.bucket_start
          + make_interval
            (
                secs => COALESCE
                (
                    (
                        SELECT p.capture_interval_seconds
                        FROM config.telemetry_capture_policies p
                        WHERE p.is_enabled
                          AND (p.site_id = EXCLUDED.site_id OR p.site_id IS NULL)
                          AND EXCLUDED.bucket_start >= p.effective_from
                          AND (p.effective_to IS NULL OR EXCLUDED.bucket_start < p.effective_to)
                        ORDER BY (p.site_id IS NOT NULL) DESC, p.effective_from DESC, p.id DESC
                        LIMIT 1
                    ),
                    1
                )
            )
          + make_interval
            (
                secs => COALESCE
                (
                    (
                        SELECT p.late_arrival_tolerance_seconds
                        FROM config.telemetry_capture_policies p
                        WHERE p.is_enabled
                          AND (p.site_id = EXCLUDED.site_id OR p.site_id IS NULL)
                          AND EXCLUDED.bucket_start >= p.effective_from
                          AND (p.effective_to IS NULL OR EXCLUDED.bucket_start < p.effective_to)
                        ORDER BY (p.site_id IS NOT NULL) DESC, p.effective_from DESC, p.id DESC
                        LIMIT 1
                    ),
                    900
                )
            );



    GET DIAGNOSTICS v_affected_rows = ROW_COUNT;


    UPDATE telemetry.pipeline_state
    SET
        last_received_at   = v_window_end,
        last_completed_at  = clock_timestamp(),
        last_inserted_rows = v_affected_rows,
        last_status        = 'SUCCESS',
        last_error         = NULL,
        updated_at         = now()
    WHERE pipeline_name = v_pipeline_name;


EXCEPTION
    WHEN OTHERS THEN

        UPDATE telemetry.pipeline_state
        SET
            last_completed_at  = clock_timestamp(),
            last_inserted_rows = 0,
            last_status        = 'FAILED',
            last_error         = SQLSTATE || ': ' || SQLERRM,
            updated_at         = now()
        WHERE pipeline_name = v_pipeline_name;

        RAISE;
END;
$$;


-- Preserve operational privileges used by pipeline workers and readers.
GRANT SELECT ON telemetry.v_energy_measurements_route TO ems_readonly, grafana_reader;
GRANT SELECT ON telemetry.v_environment_measurements_route TO ems_readonly, grafana_reader;

-- Continuous aggregates stay bound to the renamed hypertable time column.
-- Their output bucket_start columns and refresh/compression policies are kept.

