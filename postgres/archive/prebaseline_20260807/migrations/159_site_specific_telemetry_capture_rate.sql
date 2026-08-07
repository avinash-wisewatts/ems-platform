-- ============================================================================
-- 159_site_specific_telemetry_capture_rate.sql
--
-- Site-specific domain telemetry sampling.
-- Raw messages and normalized points remain full resolution.
-- Energy and environment domain rows are reduced to the latest valid reading
-- in each site-local, wall-clock-aligned interval.
-- ============================================================================

CREATE TABLE IF NOT EXISTS config.telemetry_capture_policies
(
    id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    site_id UUID REFERENCES metadata.sites(id) ON DELETE CASCADE,
    capture_interval_seconds INTEGER NOT NULL,
    alignment_mode TEXT NOT NULL DEFAULT 'WALL_CLOCK',
    late_arrival_tolerance_seconds INTEGER NOT NULL DEFAULT 900,
    effective_from TIMESTAMPTZ NOT NULL,
    effective_to TIMESTAMPTZ,
    is_enabled BOOLEAN NOT NULL DEFAULT TRUE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    CHECK (capture_interval_seconds IN (10,30,60,300,900)),
    CHECK (alignment_mode = 'WALL_CLOCK'),
    CHECK (late_arrival_tolerance_seconds BETWEEN 0 AND 86400),
    CHECK (effective_to IS NULL OR effective_to > effective_from)
);

CREATE INDEX IF NOT EXISTS idx_telemetry_capture_policies_resolution
ON config.telemetry_capture_policies
(
    site_id,
    effective_from DESC
)
WHERE is_enabled;

CREATE OR REPLACE FUNCTION config.prevent_telemetry_capture_policy_overlap()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    NEW.updated_at := now();

    IF NEW.is_enabled AND EXISTS
    (
        SELECT 1
        FROM config.telemetry_capture_policies p
        WHERE p.id <> COALESCE(NEW.id, -1)
          AND p.is_enabled
          AND p.site_id IS NOT DISTINCT FROM NEW.site_id
          AND tstzrange(p.effective_from, p.effective_to, '[)')
              && tstzrange(NEW.effective_from, NEW.effective_to, '[)')
    ) THEN
        RAISE EXCEPTION
            'Telemetry capture policy overlaps an existing policy for site %',
            COALESCE(NEW.site_id::text, 'PLATFORM_DEFAULT')
            USING ERRCODE = '23P01';
    END IF;

    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_telemetry_capture_policy_no_overlap
ON config.telemetry_capture_policies;

CREATE TRIGGER trg_telemetry_capture_policy_no_overlap
BEFORE INSERT OR UPDATE
ON config.telemetry_capture_policies
FOR EACH ROW
EXECUTE FUNCTION config.prevent_telemetry_capture_policy_overlap();

-- Establish the prospective platform default. Earlier domain rows retain their
-- existing per-event timestamps and are not rewritten.
INSERT INTO config.telemetry_capture_policies
(
    site_id,
    capture_interval_seconds,
    alignment_mode,
    late_arrival_tolerance_seconds,
    effective_from,
    is_enabled
)
SELECT
    NULL,
    60,
    'WALL_CLOCK',
    900,
    clock_timestamp(),
    TRUE
WHERE NOT EXISTS
(
    SELECT 1
    FROM config.telemetry_capture_policies
    WHERE site_id IS NULL
      AND is_enabled
      AND effective_to IS NULL
);

CREATE OR REPLACE FUNCTION telemetry.resolve_site_capture_bucket
(
    p_site_id UUID,
    p_event_time TIMESTAMPTZ
)
RETURNS TABLE
(
    policy_id BIGINT,
    capture_interval_seconds INTEGER,
    late_arrival_tolerance_seconds INTEGER,
    site_timezone TEXT,
    bucket_start TIMESTAMPTZ
)
LANGUAGE sql
STABLE
AS $$
WITH site_context AS
(
    SELECT COALESCE(s.timezone, 'UTC') AS timezone
    FROM (SELECT 1) seed
    LEFT JOIN metadata.sites s
      ON s.id = p_site_id
),
selected_policy AS
(
    SELECT
        p.id,
        p.capture_interval_seconds,
        p.late_arrival_tolerance_seconds,
        p.effective_from
    FROM config.telemetry_capture_policies p
    WHERE p.is_enabled
      AND (p.site_id = p_site_id OR p.site_id IS NULL)
      AND p_event_time >= p.effective_from
      AND (p.effective_to IS NULL OR p_event_time < p.effective_to)
    ORDER BY
        (p.site_id IS NOT NULL) DESC,
        p.effective_from DESC,
        p.id DESC
    LIMIT 1
),
resolved AS
(
    SELECT
        sp.id,
        sp.capture_interval_seconds,
        sp.late_arrival_tolerance_seconds,
        sp.effective_from,
        sc.timezone,
        p_event_time AT TIME ZONE sc.timezone AS local_event_time
    FROM site_context sc
    LEFT JOIN selected_policy sp ON TRUE
),
bucketed AS
(
    SELECT
        r.*,
        CASE
            WHEN r.id IS NULL THEN r.local_event_time
            ELSE
                date_trunc('day', r.local_event_time)
                + make_interval
                  (
                      secs =>
                          floor
                          (
                              extract
                              (
                                  epoch FROM
                                  (
                                      r.local_event_time
                                      - date_trunc('day', r.local_event_time)
                                  )
                              )
                              / r.capture_interval_seconds
                          )::INTEGER
                          * r.capture_interval_seconds
                  )
        END AS local_bucket_start
    FROM resolved r
)
SELECT
    b.id,
    b.capture_interval_seconds,
    b.late_arrival_tolerance_seconds,
    b.timezone,
    CASE
        WHEN b.id IS NULL THEN b.local_bucket_start AT TIME ZONE b.timezone
        ELSE GREATEST
        (
            b.local_bucket_start AT TIME ZONE b.timezone,
            b.effective_from
        )
    END
FROM bucketed b;
$$;

COMMENT ON FUNCTION telemetry.resolve_site_capture_bucket(UUID,TIMESTAMPTZ) IS
'Resolves the effective site-specific capture policy and returns a site-local wall-clock bucket. Returns the original event time when no prospective policy applies.';

CREATE OR REPLACE FUNCTION config.set_site_telemetry_capture_policy
(
    p_site_id UUID,
    p_capture_interval_seconds INTEGER,
    p_effective_from TIMESTAMPTZ DEFAULT clock_timestamp(),
    p_late_arrival_tolerance_seconds INTEGER DEFAULT 900
)
RETURNS BIGINT
LANGUAGE plpgsql
AS $$
DECLARE
    v_policy_id BIGINT;
BEGIN
    IF NOT EXISTS (SELECT 1 FROM metadata.sites WHERE id = p_site_id) THEN
        RAISE EXCEPTION 'Unknown site: %', p_site_id USING ERRCODE='23503';
    END IF;

    IF p_capture_interval_seconds NOT IN (10,30,60,300,900) THEN
        RAISE EXCEPTION 'Capture interval must be one of 10, 30, 60, 300, or 900 seconds'
            USING ERRCODE='22023';
    END IF;

    IF p_late_arrival_tolerance_seconds < 0 OR p_late_arrival_tolerance_seconds > 86400 THEN
        RAISE EXCEPTION 'Late-arrival tolerance must be between 0 and 86400 seconds'
            USING ERRCODE='22023';
    END IF;

    IF p_effective_from < clock_timestamp() - INTERVAL '1 second' THEN
        RAISE EXCEPTION 'Telemetry capture policy changes are prospective only'
            USING ERRCODE='22023';
    END IF;

    PERFORM 1
    FROM config.telemetry_capture_policies
    WHERE site_id = p_site_id
    FOR UPDATE;

    IF EXISTS
    (
        SELECT 1
        FROM config.telemetry_capture_policies
        WHERE site_id = p_site_id
          AND is_enabled
          AND effective_from >= p_effective_from
    ) THEN
        RAISE EXCEPTION 'A current or future site policy already starts at or after %', p_effective_from
            USING ERRCODE='23P01';
    END IF;

    UPDATE config.telemetry_capture_policies
    SET effective_to = p_effective_from,
        updated_at = now()
    WHERE site_id = p_site_id
      AND is_enabled
      AND effective_from < p_effective_from
      AND effective_to IS NULL;

    INSERT INTO config.telemetry_capture_policies
    (
        site_id,
        capture_interval_seconds,
        alignment_mode,
        late_arrival_tolerance_seconds,
        effective_from,
        is_enabled
    )
    VALUES
    (
        p_site_id,
        p_capture_interval_seconds,
        'WALL_CLOCK',
        p_late_arrival_tolerance_seconds,
        p_effective_from,
        TRUE
    )
    RETURNING id INTO v_policy_id;

    RETURN v_policy_id;
END;
$$;

REVOKE ALL ON FUNCTION config.set_site_telemetry_capture_policy(UUID,INTEGER,TIMESTAMPTZ,INTEGER) FROM PUBLIC;

-- Preserve the existing full-resolution route as an internal source.
ALTER VIEW telemetry.v_energy_measurements_route
RENAME TO v_energy_measurements_full_resolution;

CREATE VIEW telemetry.v_energy_measurements_route AS
WITH resolved AS
(
    SELECT
        r.*,
        bucket.policy_id,
        bucket.capture_interval_seconds,
        bucket.bucket_start
    FROM telemetry.v_energy_measurements_full_resolution r
    CROSS JOIN LATERAL telemetry.resolve_site_capture_bucket
    (
        r.site_id,
        r.received_at
    ) AS bucket
),
ranked AS
(
    SELECT
        resolved.*,
        row_number() OVER
        (
            PARTITION BY resolved.device_id, resolved.policy_id, resolved.bucket_start
            ORDER BY resolved.received_at DESC,
                     resolved.source_timestamp DESC NULLS LAST
        ) AS sample_rank
    FROM resolved
)
SELECT
    ranked.bucket_start AS received_at,
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
WHERE ranked.sample_rank = 1;

COMMENT ON VIEW telemetry.v_energy_measurements_route IS
'Site-policy sampled energy route: latest valid meter reading per device and site-local wall-clock interval.';

ALTER VIEW telemetry.v_environment_measurements_route
RENAME TO v_environment_measurements_full_resolution;

CREATE VIEW telemetry.v_environment_measurements_route AS
WITH resolved AS
(
    SELECT
        r.*,
        bucket.policy_id,
        bucket.capture_interval_seconds,
        bucket.bucket_start
    FROM telemetry.v_environment_measurements_full_resolution r
    CROSS JOIN LATERAL telemetry.resolve_site_capture_bucket
    (
        r.site_id,
        r.received_at
    ) AS bucket
),
ranked AS
(
    SELECT
        resolved.*,
        row_number() OVER
        (
            PARTITION BY resolved.device_id, resolved.policy_id, resolved.bucket_start
            ORDER BY resolved.received_at DESC,
                     resolved.source_timestamp DESC NULLS LAST
        ) AS sample_rank
    FROM resolved
)
SELECT
    ranked.bucket_start AS received_at,
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
WHERE ranked.sample_rank = 1;

COMMENT ON VIEW telemetry.v_environment_measurements_route IS
'Site-policy sampled environment route: latest valid sensor reading per device and site-local wall-clock interval.';

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
        bucket.bucket_start AS received_at,
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
    WHERE np.created_at > v_window_start
      AND np.created_at <= v_window_end
  )
  INSERT INTO telemetry.energy_measurements
  (
        received_at, source_timestamp, organization_id, site_id, gateway_id, device_id, asset_id,
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
        r.received_at, r.source_timestamp, r.organization_id, r.site_id, r.gateway_id, r.device_id, r.asset_id,
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
    ON r.received_at=ae.received_at AND r.device_id=ae.device_id
  ON CONFLICT (received_at,device_id) DO UPDATE
  SET
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
        is_estimated=FALSE;

  GET DIAGNOSTICS v_affected_rows=ROW_COUNT;
  UPDATE telemetry.pipeline_state
  SET last_received_at=v_window_end,last_completed_at=clock_timestamp(),last_inserted_rows=v_affected_rows,
      last_status='SUCCESS',last_error=NULL,updated_at=now()
  WHERE pipeline_name=v_pipeline_name;
  RAISE NOTICE 'Sampled energy routing succeeded: window=(%, %], affected_rows=%',v_window_start,v_window_end,v_affected_rows;
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
            bucket.bucket_start AS received_at,
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
        WHERE np.created_at > v_window_start
          AND np.created_at <= v_window_end
    )

    INSERT INTO telemetry.environment_measurements
    (
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
      ON r.received_at = ae.received_at
     AND r.device_id   = ae.device_id

    ON CONFLICT
    (
        received_at,
        device_id
    )
    WHERE device_id IS NOT NULL
    DO UPDATE
    SET

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
