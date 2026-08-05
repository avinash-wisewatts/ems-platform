-- Clean telemetry cutover.
-- Persisted raw path: Telegraf -> public.mqtt_staging adapter view -> telemetry.raw_messages.
-- Existing telemetry is intentionally discarded.

-- Prevent new background work while the structural cutover is in progress.
DO $$
DECLARE r record;
BEGIN
  FOR r IN
    SELECT job_id
    FROM timescaledb_information.jobs
    WHERE proc_schema = 'telemetry'
      AND proc_name IN ('run_normalization_job','run_energy_routing_job','run_environment_routing_job')
  LOOP
    PERFORM alter_job(r.job_id, scheduled => false);
  END LOOP;
END $$;

-- Parser now reads only the canonical raw archive.
CREATE OR REPLACE VIEW telemetry.v_rtdata AS
WITH messages_with_rtdata AS
(
  SELECT
    received_at,
    source_topic,
    payload
  FROM telemetry.raw_messages
  WHERE jsonb_typeof(payload -> 'rtdata') = 'array'
)
SELECT
  m.received_at,
  m.source_topic AS mqtt_topic,
  r.value ->> 'uid' AS device_uid,
  r.value ->> 'did' AS device_identifier,
  CASE
    WHEN r.value ->> 'ts' IS NULL THEN NULL::timestamptz
    WHEN pg_input_is_valid(r.value ->> 'ts', 'double precision')
      THEN to_timestamp((r.value ->> 'ts')::double precision)
    ELSE NULL::timestamptz
  END AS source_timestamp,
  r.value AS payload
FROM messages_with_rtdata m
CROSS JOIN LATERAL jsonb_array_elements(m.payload -> 'rtdata') AS r(value);

-- Retire both persistent staging tables.
DROP TABLE IF EXISTS public.mqtt_staging;
DROP TABLE IF EXISTS telemetry.mqtt_staging;

-- Preserve Telegraf's existing three-column output contract without persistent staging storage.
CREATE VIEW public.mqtt_staging AS
SELECT
  NULL::timestamptz AS received_at,
  NULL::jsonb AS tags,
  NULL::jsonb AS fields
WHERE false;

CREATE OR REPLACE FUNCTION telemetry.capture_telegraf_mqtt_insert()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, telemetry
AS $$
DECLARE
  v_payload jsonb;
  v_raw_value text;
  v_source_identifier text;
  v_source_timestamp timestamptz;
BEGIN
  v_raw_value := NEW.fields ->> 'value';

  IF v_raw_value IS NOT NULL
     AND pg_input_is_valid(v_raw_value, 'jsonb') THEN
    v_payload := v_raw_value::jsonb;
  ELSE
    v_payload := jsonb_build_object(
      '_capture_status', 'INVALID_JSON',
      '_raw_value', v_raw_value,
      '_fields', COALESCE(NEW.fields, '{}'::jsonb)
    );
  END IF;

  IF jsonb_typeof(v_payload -> 'rtdata') = 'array'
     AND jsonb_array_length(v_payload -> 'rtdata') > 0 THEN
    v_source_identifier := (v_payload -> 'rtdata' -> 0) ->> 'uid';
    IF pg_input_is_valid((v_payload -> 'rtdata' -> 0) ->> 'ts', 'double precision') THEN
      v_source_timestamp := to_timestamp(((v_payload -> 'rtdata' -> 0) ->> 'ts')::double precision);
    END IF;
  END IF;

  INSERT INTO telemetry.raw_messages
  (
    received_at,
    source_timestamp,
    source_protocol,
    source_topic,
    source_identifier,
    source_message_id,
    qos,
    payload
  )
  VALUES
  (
    COALESCE(NEW.received_at, clock_timestamp()),
    v_source_timestamp,
    'MQTT',
    NEW.tags ->> 'topic',
    v_source_identifier,
    NULL,
    NULL,
    v_payload
  );

  RETURN NULL;
END;
$$;

REVOKE ALL ON FUNCTION telemetry.capture_telegraf_mqtt_insert() FROM PUBLIC;

CREATE TRIGGER trg_capture_telegraf_mqtt_insert
INSTEAD OF INSERT ON public.mqtt_staging
FOR EACH ROW
EXECUTE FUNCTION telemetry.capture_telegraf_mqtt_insert();

REVOKE ALL ON TABLE public.mqtt_staging FROM PUBLIC;
REVOKE ALL ON TABLE public.mqtt_staging FROM telegraf_writer;
GRANT USAGE ON SCHEMA public TO telegraf_writer;
GRANT INSERT ON TABLE public.mqtt_staging TO telegraf_writer;
REVOKE ALL ON TABLE telemetry.raw_messages FROM telegraf_writer;

-- Incremental normalization now checkpoints against raw_messages.
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
      raw_value, numeric_value, quality_code, mapping_source, payload
    )
    SELECT
      np.event_time, np.organization_id, np.site_id, np.gateway_id, np.device_id,
      np.logical_point_id, np.device_uid, np.logical_point, np.raw_field_name,
      np.raw_value, np.numeric_value, np.quality_code, np.mapping_source, np.payload
    FROM telemetry.v_normalized_points np
    WHERE np.received_at > v_window_start
      AND np.received_at <= v_window_end
    ON CONFLICT (event_time, device_id, logical_point_id) DO NOTHING;

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

-- Discard all telemetry while preserving metadata and configuration.
DELETE FROM telemetry.asset_health;
DELETE FROM telemetry.device_status;
DELETE FROM telemetry.water_measurements;
DELETE FROM telemetry.environment_measurements;
DELETE FROM telemetry.energy_measurements;
DELETE FROM telemetry.normalized_points;
DELETE FROM telemetry.raw_messages;

UPDATE telemetry.pipeline_state
SET last_received_at=NULL, last_started_at=NULL, last_completed_at=NULL,
    last_inserted_rows=0, last_status='NEVER_RUN', last_error=NULL, updated_at=now();

-- Raw archive: compress after 7 days, retain 30 days.
ALTER TABLE telemetry.raw_messages SET (
  timescaledb.compress,
  timescaledb.compress_segmentby = 'source_protocol,source_identifier',
  timescaledb.compress_orderby = 'received_at DESC'
);
SELECT remove_compression_policy('telemetry.raw_messages', if_exists => true);
SELECT add_compression_policy('telemetry.raw_messages', INTERVAL '7 days');
SELECT remove_retention_policy('telemetry.raw_messages', if_exists => true);
SELECT add_retention_policy('telemetry.raw_messages', INTERVAL '30 days');

-- Normalized points: retain 90 days.
SELECT remove_compression_policy('telemetry.normalized_points', if_exists => true);
SELECT add_compression_policy('telemetry.normalized_points', INTERVAL '7 days');
SELECT remove_retention_policy('telemetry.normalized_points', if_exists => true);
SELECT add_retention_policy('telemetry.normalized_points', INTERVAL '90 days');

-- Domain retention.
SELECT remove_retention_policy('telemetry.environment_measurements', if_exists => true);
SELECT add_retention_policy('telemetry.environment_measurements', INTERVAL '1 year');
SELECT remove_retention_policy('telemetry.water_measurements', if_exists => true);
SELECT add_retention_policy('telemetry.water_measurements', INTERVAL '1 year');
SELECT remove_retention_policy('telemetry.device_status', if_exists => true);
SELECT add_retention_policy('telemetry.device_status', INTERVAL '90 days');

-- Re-enable required pipeline jobs.
DO $$
DECLARE r record;
BEGIN
  FOR r IN
    SELECT job_id
    FROM timescaledb_information.jobs
    WHERE proc_schema = 'telemetry'
      AND proc_name IN ('run_normalization_job','run_energy_routing_job','run_environment_routing_job')
  LOOP
    PERFORM alter_job(r.job_id, scheduled => true);
  END LOOP;
END $$;
