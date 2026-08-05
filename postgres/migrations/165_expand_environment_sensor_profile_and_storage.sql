-- ============================================================================
-- Migration 165: expand environmental sensor profile and storage contract
--
-- Confirmed payload semantics:
--   T1    temperature (degC)
--   RH    relative humidity (%)
--   LL    illuminance (lux)
--   PIR   raw PIR activity value
--   PIR_t seconds since most recent PIR event
--   dis1  pulse/digital input 1 raw numeric value (semantics not over-claimed)
--   ain1..ain4 external sensor input raw numeric values
--   Vbat  battery voltage (V)
--   Stat  vendor device status code
--
-- uid/did/ts remain routing and timestamp fields and are not persisted as
-- dedicated columns in telemetry.environment_measurements.
-- ============================================================================


-- --------------------------------------------------------------------------
-- 1. Engineering unit and logical points.
-- --------------------------------------------------------------------------
INSERT INTO config.engineering_units(symbol, description)
VALUES ('s', 'Seconds')
ON CONFLICT (symbol) DO UPDATE SET description = EXCLUDED.description;

INSERT INTO metadata.logical_points(name, description, unit_id, data_type)
SELECT 'OCCUPANCY_SECONDS_SINCE_LAST_PIR_EVENT',
       'Elapsed seconds since the most recent PIR occupancy event.',
       eu.id,
       'numeric'
FROM config.engineering_units eu
WHERE eu.symbol = 's'
ON CONFLICT (name) DO UPDATE
SET description = EXCLUDED.description,
    unit_id = EXCLUDED.unit_id,
    data_type = EXCLUDED.data_type;

INSERT INTO metadata.logical_points(name, description, unit_id, data_type)
VALUES
('PULSE_INPUT_1_RAW', 'Raw numeric value reported by pulse/digital input 1; counter/state semantics are device-configuration dependent.', NULL, 'numeric'),
('EXTERNAL_SENSOR_INPUT_1_RAW', 'Raw numeric value reported by external sensor input 1.', NULL, 'numeric'),
('EXTERNAL_SENSOR_INPUT_2_RAW', 'Raw numeric value reported by external sensor input 2.', NULL, 'numeric'),
('EXTERNAL_SENSOR_INPUT_3_RAW', 'Raw numeric value reported by external sensor input 3.', NULL, 'numeric'),
('EXTERNAL_SENSOR_INPUT_4_RAW', 'Raw numeric value reported by external sensor input 4.', NULL, 'numeric'),
('DEVICE_STATUS_CODE', 'Vendor-reported numeric device status code.', NULL, 'numeric')
ON CONFLICT (name) DO UPDATE
SET description = EXCLUDED.description,
    unit_id = EXCLUDED.unit_id,
    data_type = EXCLUDED.data_type;

-- --------------------------------------------------------------------------
-- 2. Expand ENVIRONMENT_SENSOR_AIRSENSE_V1 profile mappings.
--    All measurement mappings remain optional.
-- --------------------------------------------------------------------------
DO $$
DECLARE
    v_profile_id UUID;
BEGIN
    SELECT id INTO v_profile_id
    FROM config.device_profiles
    WHERE profile_code = 'ENVIRONMENT_SENSOR_AIRSENSE_V1';

    IF v_profile_id IS NULL THEN
        RAISE EXCEPTION 'ENVIRONMENT_SENSOR_AIRSENSE_V1 profile not found';
    END IF;

    UPDATE config.device_profiles
    SET description = 'Generic optional-field profile for temperature, humidity, illuminance, PIR activity, seconds since last PIR event, pulse input, four external sensor inputs, battery voltage, and device status code.',
        updated_at = now()
    WHERE id = v_profile_id;

    INSERT INTO config.profile_field_mapping
        (profile_id, raw_field_name, logical_point_id, json_path,
         transform_expression, is_required, display_order)
    SELECT v_profile_id, m.raw_field_name, lp.id, NULL, NULL, FALSE, m.display_order
    FROM (VALUES
        ('PIR_t', 'OCCUPANCY_SECONDS_SINCE_LAST_PIR_EVENT', 50),
        ('dis1',  'PULSE_INPUT_1_RAW',                         60),
        ('ain1',  'EXTERNAL_SENSOR_INPUT_1_RAW',               70),
        ('ain2',  'EXTERNAL_SENSOR_INPUT_2_RAW',               80),
        ('ain3',  'EXTERNAL_SENSOR_INPUT_3_RAW',               90),
        ('ain4',  'EXTERNAL_SENSOR_INPUT_4_RAW',              100),
        ('Stat',  'DEVICE_STATUS_CODE',                       120)
    ) AS m(raw_field_name, logical_point_name, display_order)
    JOIN metadata.logical_points lp
      ON lp.name = m.logical_point_name
    ON CONFLICT (profile_id, raw_field_name) DO UPDATE
    SET logical_point_id = EXCLUDED.logical_point_id,
        json_path = EXCLUDED.json_path,
        transform_expression = EXCLUDED.transform_expression,
        is_required = FALSE,
        display_order = EXCLUDED.display_order;

    -- Keep the existing Vbat mapping after the new input fields in display order.
    UPDATE config.profile_field_mapping
    SET display_order = 110,
        is_required = FALSE
    WHERE profile_id = v_profile_id
      AND raw_field_name = 'Vbat';

    IF (
        SELECT count(*)
        FROM config.profile_field_mapping pfm
        WHERE pfm.profile_id = v_profile_id
          AND pfm.raw_field_name IN
              ('T1','RH','LL','PIR','PIR_t','dis1','ain1','ain2','ain3','ain4','Vbat','Stat')
          AND pfm.is_required = FALSE
    ) <> 12 THEN
        RAISE EXCEPTION 'Expected 12 optional environment profile mappings';
    END IF;
END;
$$;

-- --------------------------------------------------------------------------
-- 3. Extend destination table. Identity/lineage columns remain mandatory;
--    every measurement column remains nullable.
-- --------------------------------------------------------------------------
ALTER TABLE telemetry.environment_measurements
    ADD COLUMN IF NOT EXISTS seconds_since_last_pir_event INTEGER,
    ADD COLUMN IF NOT EXISTS pulse_input_1_raw DOUBLE PRECISION,
    ADD COLUMN IF NOT EXISTS external_input_1_raw DOUBLE PRECISION,
    ADD COLUMN IF NOT EXISTS external_input_2_raw DOUBLE PRECISION,
    ADD COLUMN IF NOT EXISTS external_input_3_raw DOUBLE PRECISION,
    ADD COLUMN IF NOT EXISTS external_input_4_raw DOUBLE PRECISION,
    ADD COLUMN IF NOT EXISTS device_status_code INTEGER;

COMMENT ON COLUMN telemetry.environment_measurements.seconds_since_last_pir_event IS
'Elapsed whole seconds since the most recent PIR event, mapped from PIR_t.';
COMMENT ON COLUMN telemetry.environment_measurements.pulse_input_1_raw IS
'Raw numeric value from dis1. Counter/state semantics depend on device configuration.';
COMMENT ON COLUMN telemetry.environment_measurements.external_input_1_raw IS 'Raw numeric external sensor input ain1.';
COMMENT ON COLUMN telemetry.environment_measurements.external_input_2_raw IS 'Raw numeric external sensor input ain2.';
COMMENT ON COLUMN telemetry.environment_measurements.external_input_3_raw IS 'Raw numeric external sensor input ain3.';
COMMENT ON COLUMN telemetry.environment_measurements.external_input_4_raw IS 'Raw numeric external sensor input ain4.';
COMMENT ON COLUMN telemetry.environment_measurements.device_status_code IS 'Vendor-reported numeric device status code mapped from Stat.';

-- --------------------------------------------------------------------------
-- 4. Full-resolution environment routing from normalized points.
--    No uid/did columns are introduced.
-- --------------------------------------------------------------------------
-- PostgreSQL cannot change an existing view column type through CREATE OR REPLACE.
-- Drop the closed-bucket route first because it depends on the full-resolution view,
-- then recreate both views with the intentional DOUBLE PRECISION contract.
DROP VIEW IF EXISTS telemetry.v_environment_measurements_route;
DROP VIEW IF EXISTS telemetry.v_environment_measurements_full_resolution;

CREATE VIEW telemetry.v_environment_measurements_full_resolution AS
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
GROUP BY np.event_time, np.organization_id, np.site_id, np.gateway_id, np.device_id;

COMMENT ON VIEW telemetry.v_environment_measurements_full_resolution IS
'Full-resolution environmental readings pivoted from normalized points for ENVIRONMENT_SENSOR_AIRSENSE_V1; uid/did remain routing fields only.';

-- --------------------------------------------------------------------------
-- 5. Rebuild closed-bucket route with all optional fields.
-- --------------------------------------------------------------------------
CREATE VIEW telemetry.v_environment_measurements_route AS
WITH resolved AS
(
    SELECT r.*, b.policy_id, b.capture_interval_seconds,
           b.late_arrival_tolerance_seconds, b.bucket_start
    FROM telemetry.v_environment_measurements_full_resolution r
    CROSS JOIN LATERAL telemetry.resolve_site_capture_bucket
        (r.site_id, COALESCE(r.source_timestamp, r.received_at)) AS b
),
ranked AS
(
    SELECT resolved.*,
           row_number() OVER
           (
             PARTITION BY resolved.device_id, resolved.policy_id, resolved.bucket_start
             ORDER BY COALESCE(resolved.source_timestamp,resolved.received_at) DESC,
                      resolved.received_at DESC NULLS LAST
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
    ranked.raw_archive_id,
    ranked.seconds_since_last_pir_event,
    ranked.pulse_input_1_raw,
    ranked.external_input_1_raw,
    ranked.external_input_2_raw,
    ranked.external_input_3_raw,
    ranked.external_input_4_raw,
    ranked.device_status_code
FROM ranked
WHERE ranked.sample_rank = 1
  AND ranked.bucket_start + make_interval(secs => COALESCE(ranked.capture_interval_seconds,1)) <= clock_timestamp();

COMMENT ON VIEW telemetry.v_environment_measurements_route IS
'Closed-bucket environmental route with optional AirSense PIR timer, pulse input, four external inputs, battery and status fields.';

-- --------------------------------------------------------------------------
-- 6. Planner-safe incremental environment loader.
--    Uses UPDATE + INSERT instead of correlated ON CONFLICT subplans.
-- --------------------------------------------------------------------------
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

    SELECT max(created_at) INTO v_window_end FROM telemetry.normalized_points;
    IF v_window_end IS NULL THEN
        UPDATE telemetry.pipeline_state
        SET last_completed_at=clock_timestamp(), last_inserted_rows=0,
            last_status='NO_SOURCE_DATA', updated_at=now()
        WHERE pipeline_name=v_pipeline_name;
        RETURN;
    END IF;

    SELECT GREATEST
    (
        p_overlap,
        make_interval(secs => COALESCE(max(late_arrival_tolerance_seconds),900))
    ) INTO p_overlap
    FROM config.telemetry_capture_policies
    WHERE is_enabled;

    v_window_start := CASE WHEN v_previous_checkpoint IS NULL
                           THEN '-infinity'::TIMESTAMPTZ
                           ELSE v_previous_checkpoint - p_overlap END;

    CREATE TEMP TABLE tmp_environment_candidates ON COMMIT DROP AS
    WITH affected AS
    (
        SELECT DISTINCT b.bucket_start, np.device_id
        FROM telemetry.normalized_points np
        CROSS JOIN LATERAL telemetry.resolve_site_capture_bucket
            (np.site_id, np.event_time) AS b
        WHERE np.created_at > v_window_start
          AND np.created_at <= v_window_end
          AND np.logical_point IN
          (
              'ENV_TEMPERATURE','ENV_RELATIVE_HUMIDITY','ENV_ILLUMINANCE_LUX',
              'OCCUPANCY_ACTIVITY','OCCUPANCY_SECONDS_SINCE_LAST_PIR_EVENT',
              'PULSE_INPUT_1_RAW','EXTERNAL_SENSOR_INPUT_1_RAW','EXTERNAL_SENSOR_INPUT_2_RAW',
              'EXTERNAL_SENSOR_INPUT_3_RAW','EXTERNAL_SENSOR_INPUT_4_RAW',
              'DEVICE_BATTERY_VOLTAGE','BATTERY_VOLTAGE','DEVICE_STATUS_CODE'
          )
    )
    SELECT r.*,
           r.bucket_start
             + make_interval(secs => b.capture_interval_seconds)
             + make_interval(secs => b.late_arrival_tolerance_seconds) AS correction_deadline
    FROM telemetry.v_environment_measurements_route r
    JOIN affected a
      ON a.bucket_start=r.bucket_start AND a.device_id=r.device_id
    CROSS JOIN LATERAL telemetry.resolve_site_capture_bucket
      (r.site_id, COALESCE(r.source_timestamp,r.received_at)) AS b;

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

-- --------------------------------------------------------------------------
-- 7. Append the new fields to the latest-reading analytics view.
-- --------------------------------------------------------------------------
CREATE OR REPLACE VIEW analytics.v_environment_latest
WITH (security_barrier = TRUE) AS
SELECT DISTINCT ON (gom.grafana_org_id, em.device_id)
    gom.grafana_org_id,
    em.organization_id,
    em.site_id,
    em.gateway_id,
    em.device_id,
    em.asset_id,
    s.code AS site_code,
    s.name AS site_name,
    d.external_id,
    d.name AS device_name,
    d.serial_number,
    dp.profile_code,
    dp.profile_name,
    em.received_at,
    em.source_timestamp,
    em.temperature_c,
    em.humidity_percent,
    em.pressure_hpa,
    em.co2_ppm,
    em.voc_ppb,
    em.illuminance_lux,
    em.occupancy_activity,
    em.battery_voltage_v,
    em.signal_strength_dbm,
    em.measurement_interval_seconds,
    em.quality_code,
    em.is_estimated,
    EXTRACT(EPOCH FROM (now() - COALESCE(em.received_at,em.source_timestamp)))::BIGINT AS data_age_seconds,
    em.seconds_since_last_pir_event,
    em.pulse_input_1_raw,
    em.external_input_1_raw,
    em.external_input_2_raw,
    em.external_input_3_raw,
    em.external_input_4_raw,
    em.device_status_code
FROM metadata.grafana_organization_map gom
JOIN telemetry.environment_measurements em ON em.organization_id=gom.organization_id
JOIN metadata.devices d ON d.id=em.device_id
LEFT JOIN metadata.sites s ON s.id=em.site_id
LEFT JOIN config.device_profiles dp ON dp.id=d.profile_id
WHERE gom.is_active=TRUE
ORDER BY gom.grafana_org_id, em.device_id, em.bucket_start DESC, em.id DESC;

COMMENT ON VIEW analytics.v_environment_latest IS
'Newest environmental measurement per tenant/device including PIR timer, pulse input, external inputs, battery and status code.';

GRANT SELECT ON telemetry.v_environment_measurements_full_resolution,
                telemetry.v_environment_measurements_route
TO ems_readonly, grafana_reader;
GRANT SELECT ON analytics.v_environment_latest TO ems_readonly, grafana_reader;
