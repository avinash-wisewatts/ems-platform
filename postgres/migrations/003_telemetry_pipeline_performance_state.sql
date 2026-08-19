-- 003 / canonical 122
-- Telemetry pipeline performance state and normalized payload de-duplication.
--
-- Goals:
--   * keep full raw JSON once in telemetry.raw_messages (7 days)
--   * keep full failed raw JSON in telemetry.raw_message_failures (30 days)
--   * remove full JSON replication from telemetry.normalized_points
--   * persist compact device/point observation state for admin/readiness pages
--   * route from receipt-watermark deltas with at most one minute replay
--
-- Existing Timescale jobs may be paused while this migration is applied. The
-- migration intentionally does not change their scheduled=true/false state.

-- Preserve the existing failure quarantine contract on clean canonical builds.
CREATE TABLE IF NOT EXISTS telemetry.raw_message_failures
(
    raw_received_at TIMESTAMPTZ NOT NULL,
    raw_message_id BIGINT NOT NULL,
    detected_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    failure_code TEXT NOT NULL,
    failure_detail TEXT,
    source_timestamp TIMESTAMPTZ,
    source_protocol TEXT NOT NULL,
    source_topic TEXT,
    source_identifier TEXT,
    source_message_id TEXT,
    qos SMALLINT,
    payload JSONB NOT NULL,
    raw_element_count INTEGER,
    resolved_element_count INTEGER,
    unresolved_element_count INTEGER,
    profiled_element_count INTEGER,
    unprofiled_element_count INTEGER,
    enabled_point_count INTEGER,
    produced_point_count INTEGER,
    diagnostic_details JSONB NOT NULL DEFAULT '{}'::JSONB,
    PRIMARY KEY (raw_received_at,raw_message_id),
    CONSTRAINT raw_message_failures_code_not_blank CHECK (btrim(failure_code)<>'')
);

SELECT create_hypertable(
    'telemetry.raw_message_failures',
    by_range('raw_received_at',INTERVAL '1 day'),
    if_not_exists=>TRUE
);

CREATE INDEX IF NOT EXISTS raw_message_failures_detected_at_idx
ON telemetry.raw_message_failures(detected_at DESC);
CREATE INDEX IF NOT EXISTS raw_message_failures_code_time_idx
ON telemetry.raw_message_failures(failure_code,raw_received_at DESC);
CREATE INDEX IF NOT EXISTS raw_message_failures_source_time_idx
ON telemetry.raw_message_failures(source_identifier,raw_received_at DESC)
WHERE source_identifier IS NOT NULL;

ALTER TABLE telemetry.raw_message_failures SET (
    timescaledb.compress,
    timescaledb.compress_segmentby='failure_code,source_protocol,source_identifier',
    timescaledb.compress_orderby='raw_received_at DESC,raw_message_id DESC'
);
SELECT remove_compression_policy('telemetry.raw_message_failures',if_exists=>TRUE);
SELECT add_compression_policy('telemetry.raw_message_failures',INTERVAL '7 days');
SELECT remove_retention_policy('telemetry.raw_message_failures',if_exists=>TRUE);
SELECT add_retention_policy('telemetry.raw_message_failures',INTERVAL '30 days');

INSERT INTO telemetry.pipeline_state(pipeline_name,last_status)
VALUES('raw_message_failures','NEVER_RUN')
ON CONFLICT(pipeline_name) DO NOTHING;

-- platform_received_at was introduced historically by the receipt-lineage
-- migration, but older canonical foundations may not contain that migration
-- mirror. Keep this forward/canonical patch self-contained for clean rebuilds.
ALTER TABLE telemetry.normalized_points
ADD COLUMN IF NOT EXISTS platform_received_at TIMESTAMPTZ;

COMMENT ON COLUMN telemetry.normalized_points.platform_received_at IS
'Platform receipt timestamp copied from telemetry.raw_messages.received_at. Used as the durable incremental-processing watermark.';

ALTER TABLE telemetry.normalized_points
ADD COLUMN IF NOT EXISTS raw_message_id BIGINT;

COMMENT ON COLUMN telemetry.normalized_points.raw_message_id IS
'Original telemetry.raw_messages.id used with platform_received_at for short-lived raw-message lineage. No foreign key is used because raw_messages intentionally expires after seven days.';

CREATE INDEX IF NOT EXISTS normalized_points_raw_lineage_idx
ON telemetry.normalized_points(platform_received_at,raw_message_id)
WHERE raw_message_id IS NOT NULL;

-- Backfill short-lived lineage for recent rows produced before this migration.
-- One hour is intentionally bounded: failure capture has a 20-minute grace, so
-- this covers the only pre-migration rows that can still enter new diagnostics
-- without rewriting the entire historical normalized hypertable.
UPDATE telemetry.normalized_points np
SET raw_message_id=r.id
FROM telemetry.raw_messages r
WHERE np.raw_message_id IS NULL
  AND np.platform_received_at=r.received_at
  AND r.received_at >= clock_timestamp()-INTERVAL '1 hour';

CREATE TABLE IF NOT EXISTS telemetry.device_point_state
(
    device_id UUID NOT NULL,
    logical_point_id UUID NOT NULL,
    first_seen_at TIMESTAMPTZ NOT NULL,
    last_seen_at TIMESTAMPTZ NOT NULL,
    last_received_at TIMESTAMPTZ NOT NULL,
    first_valid_seen_at TIMESTAMPTZ,
    last_valid_seen_at TIMESTAMPTZ,
    last_valid_received_at TIMESTAMPTZ,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY(device_id,logical_point_id)
);

CREATE TABLE IF NOT EXISTS telemetry.device_telemetry_state
(
    device_id UUID PRIMARY KEY,
    latest_source_timestamp TIMESTAMPTZ,
    latest_received_timestamp TIMESTAMPTZ,
    latest_valid_source_timestamp TIMESTAMPTZ,
    latest_valid_received_timestamp TIMESTAMPTZ,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

COMMENT ON TABLE telemetry.device_point_state IS
'Compact persistent observation state per device/logical point. Used for commissioning readiness without scanning telemetry history.';
COMMENT ON TABLE telemetry.device_telemetry_state IS
'Compact persistent latest telemetry state per device. Used by admin inventory, device workspace and gateway connectivity without history scans.';

-- One-time state seed from existing durable telemetry. The jobs are expected to
-- be paused during production application of this migration.
CREATE TEMP TABLE tmp_device_point_state_backfill ON COMMIT PRESERVE ROWS AS
SELECT
    np.device_id,
    np.logical_point_id,
    min(np.event_time) AS first_seen_at,
    max(np.event_time) AS last_seen_at,
    max(coalesce(np.platform_received_at,np.created_at)) AS last_received_at,
    min(np.event_time) FILTER (
        WHERE coalesce(np.quality_code,'GOOD') NOT IN ('INVALID','REJECTED','INVALID_NUMERIC')
          AND (np.numeric_value IS NOT NULL OR nullif(btrim(np.raw_value),'') IS NOT NULL)
    ) AS first_valid_seen_at,
    max(np.event_time) FILTER (
        WHERE coalesce(np.quality_code,'GOOD') NOT IN ('INVALID','REJECTED','INVALID_NUMERIC')
          AND (np.numeric_value IS NOT NULL OR nullif(btrim(np.raw_value),'') IS NOT NULL)
    ) AS last_valid_seen_at,
    max(coalesce(np.platform_received_at,np.created_at)) FILTER (
        WHERE coalesce(np.quality_code,'GOOD') NOT IN ('INVALID','REJECTED','INVALID_NUMERIC')
          AND (np.numeric_value IS NOT NULL OR nullif(btrim(np.raw_value),'') IS NOT NULL)
    ) AS last_valid_received_at
FROM telemetry.normalized_points np
GROUP BY np.device_id,np.logical_point_id;

INSERT INTO telemetry.device_point_state
(
    device_id,logical_point_id,first_seen_at,last_seen_at,last_received_at,
    first_valid_seen_at,last_valid_seen_at,last_valid_received_at,updated_at
)
SELECT device_id,logical_point_id,first_seen_at,last_seen_at,last_received_at,
       first_valid_seen_at,last_valid_seen_at,last_valid_received_at,now()
FROM tmp_device_point_state_backfill
ON CONFLICT(device_id,logical_point_id) DO UPDATE
SET first_seen_at=EXCLUDED.first_seen_at,
    last_seen_at=EXCLUDED.last_seen_at,
    last_received_at=EXCLUDED.last_received_at,
    first_valid_seen_at=EXCLUDED.first_valid_seen_at,
    last_valid_seen_at=EXCLUDED.last_valid_seen_at,
    last_valid_received_at=EXCLUDED.last_valid_received_at,
    updated_at=now();

INSERT INTO telemetry.device_telemetry_state
(
    device_id,latest_source_timestamp,latest_received_timestamp,
    latest_valid_source_timestamp,latest_valid_received_timestamp,updated_at
)
SELECT device_id,max(last_seen_at),max(last_received_at),
       max(last_valid_seen_at),max(last_valid_received_at),now()
FROM tmp_device_point_state_backfill
GROUP BY device_id
ON CONFLICT(device_id) DO UPDATE
SET latest_source_timestamp=EXCLUDED.latest_source_timestamp,
    latest_received_timestamp=EXCLUDED.latest_received_timestamp,
    latest_valid_source_timestamp=EXCLUDED.latest_valid_source_timestamp,
    latest_valid_received_timestamp=EXCLUDED.latest_valid_received_timestamp,
    updated_at=now();

DROP TABLE IF EXISTS tmp_device_point_state_backfill;

CREATE OR REPLACE VIEW telemetry.v_rtdata AS
WITH messages_with_rtdata AS
(
    SELECT
        id AS raw_message_id,
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
        WHEN r.value ->> 'ts' IS NULL THEN NULL::TIMESTAMPTZ
        WHEN pg_input_is_valid(r.value ->> 'ts','double precision')
            THEN to_timestamp((r.value ->> 'ts')::DOUBLE PRECISION)
        ELSE NULL::TIMESTAMPTZ
    END AS source_timestamp,
    r.value AS payload,
    m.raw_message_id
FROM messages_with_rtdata m
CROSS JOIN LATERAL jsonb_array_elements(m.payload -> 'rtdata') AS r(value);

CREATE OR REPLACE VIEW telemetry.v_normalized_points AS
WITH resolved_devices AS
(
    SELECT
        r.received_at,
        r.raw_message_id,
        COALESCE(r.source_timestamp, r.received_at) AS event_time,
        r.source_timestamp,
        r.mqtt_topic,
        r.device_uid,
        r.device_identifier,
        r.payload,
        d.id AS device_id,
        d.organization_id,
        d.gateway_id,
        g.site_id,
        d.profile_id
    FROM telemetry.v_rtdata r
    JOIN metadata.device_identifiers di
      ON di.identifier_type = 'MQTT_UID'
     AND lower(di.identifier_value) = lower(r.device_uid)
    JOIN metadata.devices d
      ON d.id = di.device_id
    LEFT JOIN metadata.gateways g
      ON g.id = d.gateway_id
    WHERE r.device_uid IS NOT NULL
),
profile_mappings AS
(
    SELECT
        rd.received_at,
        rd.raw_message_id,
        rd.event_time,
        rd.source_timestamp,
        rd.mqtt_topic,
        rd.organization_id,
        rd.site_id,
        rd.gateway_id,
        rd.device_id,
        rd.device_uid,
        rd.device_identifier,
        rd.payload,
        pfm.logical_point_id,
        lp.name AS logical_point,
        lp.data_type,
        pfm.raw_field_name,
        pfm.json_path,
        pfm.transform_expression,
        1 AS mapping_priority,
        'DEVICE_PROFILE'::TEXT AS mapping_source
    FROM resolved_devices rd
    JOIN config.profile_field_mapping pfm
      ON pfm.profile_id = rd.profile_id
    JOIN config.device_point_configuration dpc
      ON dpc.device_id = rd.device_id
     AND dpc.logical_point_id = pfm.logical_point_id
     AND dpc.is_enabled
    JOIN metadata.logical_points lp
      ON lp.id = pfm.logical_point_id
    WHERE rd.profile_id IS NOT NULL
),
device_mappings AS
(
    SELECT
        rd.received_at,
        rd.raw_message_id,
        rd.event_time,
        rd.source_timestamp,
        rd.mqtt_topic,
        rd.organization_id,
        rd.site_id,
        rd.gateway_id,
        rd.device_id,
        rd.device_uid,
        rd.device_identifier,
        rd.payload,
        dfm.logical_point_id,
        lp.name AS logical_point,
        lp.data_type,
        dfm.raw_field_name,
        NULL::TEXT AS json_path,
        NULL::TEXT AS transform_expression,
        2 AS mapping_priority,
        'DEVICE_OVERRIDE'::TEXT AS mapping_source
    FROM resolved_devices rd
    JOIN metadata.device_field_mapping dfm
      ON dfm.device_id = rd.device_id
    JOIN config.device_point_configuration dpc
      ON dpc.device_id = rd.device_id
     AND dpc.logical_point_id = dfm.logical_point_id
     AND dpc.is_enabled
    JOIN metadata.logical_points lp
      ON lp.id = dfm.logical_point_id
),
candidate_mappings AS
(
    SELECT * FROM profile_mappings
    UNION ALL
    SELECT * FROM device_mappings
),
preferred_mappings AS
(
    SELECT DISTINCT ON
    (
        received_at,
        device_id,
        logical_point_id
    )
        received_at,
        raw_message_id,
        event_time,
        source_timestamp,
        mqtt_topic,
        organization_id,
        site_id,
        gateway_id,
        device_id,
        device_uid,
        device_identifier,
        payload,
        logical_point_id,
        logical_point,
        data_type,
        raw_field_name,
        json_path,
        transform_expression,
        mapping_priority,
        mapping_source
    FROM candidate_mappings
    ORDER BY
        received_at,
        device_id,
        logical_point_id,
        mapping_priority
),
extracted_values AS
(
    SELECT
        pm.*,
        CASE
            WHEN pm.json_path IS NULL
                THEN pm.payload ->> pm.raw_field_name
            ELSE
                jsonb_path_query_first
                (
                    pm.payload,
                    pm.json_path::jsonpath
                ) #>> '{}'
        END AS raw_value
    FROM preferred_mappings pm
)
SELECT
    received_at,
    event_time,
    source_timestamp,
    organization_id,
    site_id,
    gateway_id,
    device_id,
    device_uid,
    device_identifier,
    mqtt_topic,
    logical_point_id,
    logical_point,
    data_type,
    raw_field_name,
    raw_value,
    CASE
        WHEN raw_value IS NULL
            THEN NULL::NUMERIC
        WHEN raw_value ~
             '^[[:space:]]*[+-]?(([0-9]+([.][0-9]*)?)|([.][0-9]+))([eE][+-]?[0-9]+)?[[:space:]]*$'
            THEN btrim(raw_value)::NUMERIC
        ELSE NULL::NUMERIC
    END AS numeric_value,
    CASE
        WHEN raw_value IS NULL
            THEN 'MISSING'::TEXT
        WHEN data_type = 'numeric'
         AND raw_value !~
             '^[[:space:]]*[+-]?(([0-9]+([.][0-9]*)?)|([.][0-9]+))([eE][+-]?[0-9]+)?[[:space:]]*$'
            THEN 'INVALID_NUMERIC'::TEXT
        ELSE 'GOOD'::TEXT
    END AS quality_code,
    mapping_source,
    payload,
    raw_message_id
FROM extracted_values;

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
    v_effective_overlap INTERVAL;
BEGIN
    IF p_overlap IS NULL OR p_overlap < INTERVAL '0 seconds' THEN
        RAISE EXCEPTION 'p_overlap must be zero or positive; received %', p_overlap;
    END IF;

    v_effective_overlap := LEAST(p_overlap, INTERVAL '1 minute');

    SELECT pg_try_advisory_xact_lock(
        hashtextextended('telemetry.load_normalized_points_incremental', 0)
    ) INTO v_lock_acquired;

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
    SET last_started_at=clock_timestamp(), last_status='RUNNING',
        last_error=NULL, updated_at=now()
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
        WHEN v_previous_checkpoint IS NULL THEN '-infinity'::TIMESTAMPTZ
        ELSE v_previous_checkpoint - v_effective_overlap
    END;

    CREATE TEMP TABLE tmp_normalized_batch ON COMMIT DROP AS
    SELECT DISTINCT ON (np.event_time, np.device_id, np.logical_point_id)
        np.received_at,
        np.raw_message_id,
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
        np.mapping_source
    FROM telemetry.v_normalized_points np
    WHERE np.received_at > v_window_start
      AND np.received_at <= v_window_end
    ORDER BY np.event_time, np.device_id, np.logical_point_id,
             np.received_at DESC, np.raw_message_id DESC;

    INSERT INTO telemetry.normalized_points
    (
        event_time, organization_id, site_id, gateway_id, device_id,
        logical_point_id, device_uid, logical_point, raw_field_name,
        raw_value, numeric_value, quality_code, mapping_source,
        platform_received_at, raw_message_id
    )
    SELECT
        b.event_time, b.organization_id, b.site_id, b.gateway_id, b.device_id,
        b.logical_point_id, b.device_uid, b.logical_point, b.raw_field_name,
        b.raw_value, b.numeric_value, b.quality_code, b.mapping_source,
        b.received_at, b.raw_message_id
    FROM tmp_normalized_batch b
    ON CONFLICT (event_time, device_id, logical_point_id) DO UPDATE
    SET platform_received_at = EXCLUDED.platform_received_at,
        raw_message_id = EXCLUDED.raw_message_id
    WHERE telemetry.normalized_points.platform_received_at IS NULL
       OR telemetry.normalized_points.raw_message_id IS NULL
       OR EXCLUDED.platform_received_at > telemetry.normalized_points.platform_received_at;

    GET DIAGNOSTICS v_inserted_rows = ROW_COUNT;

    INSERT INTO telemetry.device_point_state
    (
        device_id, logical_point_id,
        first_seen_at, last_seen_at, last_received_at,
        first_valid_seen_at, last_valid_seen_at, last_valid_received_at,
        updated_at
    )
    SELECT
        b.device_id,
        b.logical_point_id,
        min(b.event_time),
        max(b.event_time),
        max(b.received_at),
        min(b.event_time) FILTER (WHERE coalesce(b.quality_code,'GOOD') NOT IN ('INVALID','REJECTED','INVALID_NUMERIC') AND (b.numeric_value IS NOT NULL OR nullif(btrim(b.raw_value),'') IS NOT NULL)),
        max(b.event_time) FILTER (WHERE coalesce(b.quality_code,'GOOD') NOT IN ('INVALID','REJECTED','INVALID_NUMERIC') AND (b.numeric_value IS NOT NULL OR nullif(btrim(b.raw_value),'') IS NOT NULL)),
        max(b.received_at) FILTER (WHERE coalesce(b.quality_code,'GOOD') NOT IN ('INVALID','REJECTED','INVALID_NUMERIC') AND (b.numeric_value IS NOT NULL OR nullif(btrim(b.raw_value),'') IS NOT NULL)),
        now()
    FROM tmp_normalized_batch b
    GROUP BY b.device_id, b.logical_point_id
    ON CONFLICT (device_id, logical_point_id) DO UPDATE
    SET first_seen_at = LEAST(telemetry.device_point_state.first_seen_at, EXCLUDED.first_seen_at),
        last_seen_at = GREATEST(telemetry.device_point_state.last_seen_at, EXCLUDED.last_seen_at),
        last_received_at = GREATEST(telemetry.device_point_state.last_received_at, EXCLUDED.last_received_at),
        first_valid_seen_at = CASE
            WHEN telemetry.device_point_state.first_valid_seen_at IS NULL THEN EXCLUDED.first_valid_seen_at
            WHEN EXCLUDED.first_valid_seen_at IS NULL THEN telemetry.device_point_state.first_valid_seen_at
            ELSE LEAST(telemetry.device_point_state.first_valid_seen_at, EXCLUDED.first_valid_seen_at)
        END,
        last_valid_seen_at = GREATEST(telemetry.device_point_state.last_valid_seen_at, EXCLUDED.last_valid_seen_at),
        last_valid_received_at = GREATEST(telemetry.device_point_state.last_valid_received_at, EXCLUDED.last_valid_received_at),
        updated_at = now();

    INSERT INTO telemetry.device_telemetry_state
    (
        device_id,
        latest_source_timestamp,
        latest_received_timestamp,
        latest_valid_source_timestamp,
        latest_valid_received_timestamp,
        updated_at
    )
    SELECT
        b.device_id,
        max(b.event_time),
        max(b.received_at),
        max(b.event_time) FILTER (WHERE coalesce(b.quality_code,'GOOD') NOT IN ('INVALID','REJECTED','INVALID_NUMERIC') AND (b.numeric_value IS NOT NULL OR nullif(btrim(b.raw_value),'') IS NOT NULL)),
        max(b.received_at) FILTER (WHERE coalesce(b.quality_code,'GOOD') NOT IN ('INVALID','REJECTED','INVALID_NUMERIC') AND (b.numeric_value IS NOT NULL OR nullif(btrim(b.raw_value),'') IS NOT NULL)),
        now()
    FROM tmp_normalized_batch b
    GROUP BY b.device_id
    ON CONFLICT (device_id) DO UPDATE
    SET latest_source_timestamp = GREATEST(telemetry.device_telemetry_state.latest_source_timestamp, EXCLUDED.latest_source_timestamp),
        latest_received_timestamp = GREATEST(telemetry.device_telemetry_state.latest_received_timestamp, EXCLUDED.latest_received_timestamp),
        latest_valid_source_timestamp = GREATEST(telemetry.device_telemetry_state.latest_valid_source_timestamp, EXCLUDED.latest_valid_source_timestamp),
        latest_valid_received_timestamp = GREATEST(telemetry.device_telemetry_state.latest_valid_received_timestamp, EXCLUDED.latest_valid_received_timestamp),
        updated_at = now();

    UPDATE telemetry.pipeline_state
    SET last_received_at=v_window_end,
        last_completed_at=clock_timestamp(),
        last_inserted_rows=v_inserted_rows,
        last_status='SUCCESS', last_error=NULL, updated_at=now()
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
    WHERE np.platform_received_at > v_window_start
      AND np.platform_received_at <= v_window_end
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
    WITH affected AS
    (
        SELECT DISTINCT b.bucket_start, np.device_id
        FROM telemetry.normalized_points np
        CROSS JOIN LATERAL telemetry.resolve_site_capture_bucket
            (np.site_id, np.event_time) AS b
        WHERE np.platform_received_at > v_window_start
          AND np.platform_received_at <= v_window_end
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

CREATE OR REPLACE PROCEDURE telemetry.capture_raw_message_failures_incremental
(
    p_overlap INTERVAL DEFAULT INTERVAL '15 minutes',
    p_grace   INTERVAL DEFAULT INTERVAL '20 minutes'
)
LANGUAGE plpgsql
AS
$$
DECLARE
    v_pipeline_name CONSTANT TEXT := 'raw_message_failures';

    v_previous_checkpoint   TIMESTAMPTZ;
    v_normalized_checkpoint TIMESTAMPTZ;
    v_window_start          TIMESTAMPTZ;
    v_window_end            TIMESTAMPTZ;

    v_inserted_rows BIGINT := 0;
    v_lock_acquired BOOLEAN;
BEGIN
    IF p_overlap IS NULL OR p_overlap < INTERVAL '0 seconds' THEN
        RAISE EXCEPTION
            'p_overlap must be zero or positive; received %',
            p_overlap;
    END IF;

    IF p_grace IS NULL OR p_grace < INTERVAL '0 seconds' THEN
        RAISE EXCEPTION
            'p_grace must be zero or positive; received %',
            p_grace;
    END IF;

    SELECT pg_try_advisory_xact_lock
    (
        hashtextextended
        (
            'telemetry.capture_raw_message_failures_incremental',
            0
        )
    )
    INTO v_lock_acquired;

    IF NOT v_lock_acquired THEN
        UPDATE telemetry.pipeline_state
        SET
            last_status = 'SKIPPED_LOCKED',
            last_error = NULL,
            updated_at = now()
        WHERE pipeline_name = v_pipeline_name;

        RETURN;
    END IF;

    SELECT last_received_at
    INTO v_previous_checkpoint
    FROM telemetry.pipeline_state
    WHERE pipeline_name = v_pipeline_name
    FOR UPDATE;

    SELECT last_received_at
    INTO v_normalized_checkpoint
    FROM telemetry.pipeline_state
    WHERE pipeline_name = 'normalized_points';

    UPDATE telemetry.pipeline_state
    SET
        last_started_at = clock_timestamp(),
        last_status = 'RUNNING',
        last_error = NULL,
        updated_at = now()
    WHERE pipeline_name = v_pipeline_name;

    IF v_normalized_checkpoint IS NULL THEN
        UPDATE telemetry.pipeline_state
        SET
            last_completed_at = clock_timestamp(),
            last_inserted_rows = 0,
            last_status = 'NO_SOURCE_DATA',
            last_error = NULL,
            updated_at = now()
        WHERE pipeline_name = v_pipeline_name;

        RETURN;
    END IF;

    v_window_end :=
        LEAST
        (
            v_normalized_checkpoint,
            clock_timestamp() - p_grace
        );

    v_window_start :=
        CASE
            WHEN v_previous_checkpoint IS NULL THEN
                GREATEST
                (
                    clock_timestamp() - INTERVAL '7 days',
                    COALESCE
                    (
                        (
                            SELECT MIN(received_at) - INTERVAL '1 microsecond'
                            FROM telemetry.raw_messages
                        ),
                        v_window_end
                    )
                )
            ELSE
                v_previous_checkpoint - LEAST(p_overlap, INTERVAL '1 minute')
        END;

    IF v_window_end <= v_window_start THEN
        UPDATE telemetry.pipeline_state
        SET
            last_completed_at = clock_timestamp(),
            last_inserted_rows = 0,
            last_status = 'SUCCESS',
            last_error = NULL,
            updated_at = now()
        WHERE pipeline_name = v_pipeline_name;

        RETURN;
    END IF;

    WITH raw_candidates AS
    (
        SELECT r.*
        FROM telemetry.raw_messages r
        WHERE r.received_at > v_window_start
          AND r.received_at <= v_window_end
    ),
    message_metrics AS
    (
        SELECT
            r.received_at AS raw_received_at,
            r.id AS raw_message_id,

            CASE
                WHEN jsonb_typeof(r.payload -> 'rtdata') = 'array'
                    THEN jsonb_array_length(r.payload -> 'rtdata')
                ELSE 0
            END AS raw_element_count,

            COALESCE(element_metrics.resolved_element_count, 0)
                AS resolved_element_count,

            COALESCE(element_metrics.unresolved_element_count, 0)
                AS unresolved_element_count,

            COALESCE(element_metrics.profiled_element_count, 0)
                AS profiled_element_count,

            COALESCE(element_metrics.unprofiled_element_count, 0)
                AS unprofiled_element_count,

            COALESCE(element_metrics.enabled_point_count, 0)
                AS enabled_point_count,

            COALESCE(actual_metrics.produced_point_count, 0)
                AS produced_point_count,

            COALESCE
            (
                element_metrics.unresolved_uids,
                '[]'::JSONB
            ) AS unresolved_uids

        FROM raw_candidates r

        LEFT JOIN LATERAL
        (
            SELECT
                COUNT(*) FILTER
                (
                    WHERE resolved.device_id IS NOT NULL
                )::INTEGER AS resolved_element_count,

                COUNT(*) FILTER
                (
                    WHERE resolved.device_id IS NULL
                )::INTEGER AS unresolved_element_count,

                COUNT(*) FILTER
                (
                    WHERE resolved.device_id IS NOT NULL
                      AND resolved.profile_id IS NOT NULL
                )::INTEGER AS profiled_element_count,

                COUNT(*) FILTER
                (
                    WHERE resolved.device_id IS NOT NULL
                      AND resolved.profile_id IS NULL
                )::INTEGER AS unprofiled_element_count,

                COALESCE
                (
                    SUM(resolved.enabled_points),
                    0
                )::INTEGER AS enabled_point_count,

                COALESCE
                (
                    jsonb_agg
                    (
                        jsonb_build_object
                        (
                            'element_number', resolved.element_number,
                            'uid', resolved.device_uid,
                            'did', resolved.device_identifier
                        )
                        ORDER BY resolved.element_number
                    )
                    FILTER
                    (
                        WHERE resolved.device_id IS NULL
                    ),
                    '[]'::JSONB
                ) AS unresolved_uids

            FROM
            (
                SELECT
                    e.ordinality::INTEGER AS element_number,
                    e.value ->> 'uid' AS device_uid,
                    e.value ->> 'did' AS device_identifier,
                    d.id AS device_id,
                    d.profile_id,
                    COALESCE(enabled.enabled_points, 0)
                        AS enabled_points

                FROM jsonb_array_elements
                (
                    CASE
                        WHEN jsonb_typeof(r.payload -> 'rtdata') = 'array'
                            THEN r.payload -> 'rtdata'
                        ELSE '[]'::JSONB
                    END
                )
                WITH ORDINALITY AS e(value, ordinality)

                LEFT JOIN LATERAL
                (
                    SELECT di.device_id
                    FROM metadata.device_identifiers di
                    WHERE di.identifier_type = 'MQTT_UID'
                      AND lower(di.identifier_value) =
                          lower(e.value ->> 'uid')
                    ORDER BY di.device_id
                    LIMIT 1
                ) AS identifier
                  ON TRUE

                LEFT JOIN metadata.devices d
                  ON d.id = identifier.device_id

                LEFT JOIN LATERAL
                (
                    SELECT
                        COUNT(*)::INTEGER AS enabled_points
                    FROM config.device_point_configuration dpc
                    WHERE dpc.device_id = d.id
                      AND dpc.is_enabled
                ) AS enabled
                  ON TRUE
            ) AS resolved
        ) AS element_metrics
          ON TRUE

        LEFT JOIN LATERAL
        (
            SELECT
                COUNT
                (
                    DISTINCT
                    (
                        np.device_id,
                        np.logical_point_id
                    )
                )::INTEGER AS produced_point_count
            FROM telemetry.normalized_points np
            WHERE np.platform_received_at = r.received_at
              AND np.raw_message_id = r.id
        ) AS actual_metrics
          ON TRUE
    ),
    classified AS
    (
        SELECT
            r.*,
            m.raw_element_count,
            m.resolved_element_count,
            m.unresolved_element_count,
            m.profiled_element_count,
            m.unprofiled_element_count,
            m.enabled_point_count,
            m.produced_point_count,
            m.unresolved_uids,

            CASE
                WHEN r.payload ->> '_capture_status' = 'INVALID_JSON'
                    THEN 'INVALID_JSON'

                WHEN jsonb_typeof(r.payload -> 'rtdata')
                     IS DISTINCT FROM 'array'
                    THEN 'MISSING_RTDATA_ARRAY'

                WHEN jsonb_array_length(r.payload -> 'rtdata') = 0
                    THEN 'EMPTY_RTDATA_ARRAY'

                WHEN m.unresolved_element_count > 0
                    THEN 'UNRESOLVED_DEVICE_ELEMENTS'

                WHEN m.unprofiled_element_count > 0
                    THEN 'DEVICE_WITHOUT_PROFILE'

                WHEN m.resolved_element_count > 0
                 AND m.enabled_point_count = 0
                    THEN 'NO_ENABLED_POINTS'

                WHEN m.enabled_point_count > 0
                 AND m.produced_point_count = 0
                    THEN 'NO_PERSISTED_NORMALIZED_ROWS'

                WHEN m.produced_point_count < m.enabled_point_count
                    THEN 'PARTIAL_NORMALIZATION'

                ELSE NULL
            END AS failure_code

        FROM raw_candidates r
        JOIN message_metrics m
          ON m.raw_received_at = r.received_at
         AND m.raw_message_id = r.id
    )
    INSERT INTO telemetry.raw_message_failures
    (
        raw_received_at,
        raw_message_id,
        failure_code,
        failure_detail,
        source_timestamp,
        source_protocol,
        source_topic,
        source_identifier,
        source_message_id,
        qos,
        payload,
        raw_element_count,
        resolved_element_count,
        unresolved_element_count,
        profiled_element_count,
        unprofiled_element_count,
        enabled_point_count,
        produced_point_count,
        diagnostic_details
    )
    SELECT
        c.received_at,
        c.id,
        c.failure_code,

        CASE c.failure_code
            WHEN 'INVALID_JSON'
                THEN 'The MQTT value could not be parsed as JSON.'
            WHEN 'MISSING_RTDATA_ARRAY'
                THEN 'The payload does not contain an rtdata array.'
            WHEN 'EMPTY_RTDATA_ARRAY'
                THEN 'The payload contains an empty rtdata array.'
            WHEN 'UNRESOLVED_DEVICE_ELEMENTS'
                THEN 'One or more rtdata elements use MQTT UIDs that are not configured as device identifiers.'
            WHEN 'DEVICE_WITHOUT_PROFILE'
                THEN 'One or more resolved devices do not have a device profile.'
            WHEN 'NO_ENABLED_POINTS'
                THEN 'Resolved devices have no enabled device-point configuration.'
            WHEN 'NO_PERSISTED_NORMALIZED_ROWS'
                THEN 'Enabled points exist, but no canonical normalized rows were produced.'
            WHEN 'PARTIAL_NORMALIZATION'
                THEN 'Fewer canonical normalized rows were produced than the number of enabled device points.'
        END,

        c.source_timestamp,
        c.source_protocol,
        c.source_topic,
        c.source_identifier,
        c.source_message_id,
        c.qos,
        c.payload,
        c.raw_element_count,
        c.resolved_element_count,
        c.unresolved_element_count,
        c.profiled_element_count,
        c.unprofiled_element_count,
        c.enabled_point_count,
        c.produced_point_count,

        jsonb_build_object
        (
            'raw_element_count', c.raw_element_count,
            'resolved_element_count', c.resolved_element_count,
            'unresolved_element_count', c.unresolved_element_count,
            'profiled_element_count', c.profiled_element_count,
            'unprofiled_element_count', c.unprofiled_element_count,
            'enabled_point_count', c.enabled_point_count,
            'produced_point_count', c.produced_point_count,
            'point_shortfall',
                GREATEST
                (
                    c.enabled_point_count - c.produced_point_count,
                    0
                ),
            'unresolved_elements', c.unresolved_uids
        )

    FROM classified c
    WHERE c.failure_code IS NOT NULL

    ON CONFLICT
    (
        raw_received_at,
        raw_message_id
    )
    DO UPDATE
    SET
        detected_at = clock_timestamp(),
        failure_code = EXCLUDED.failure_code,
        failure_detail = EXCLUDED.failure_detail,
        source_timestamp = EXCLUDED.source_timestamp,
        source_protocol = EXCLUDED.source_protocol,
        source_topic = EXCLUDED.source_topic,
        source_identifier = EXCLUDED.source_identifier,
        source_message_id = EXCLUDED.source_message_id,
        qos = EXCLUDED.qos,
        payload = EXCLUDED.payload,
        raw_element_count = EXCLUDED.raw_element_count,
        resolved_element_count = EXCLUDED.resolved_element_count,
        unresolved_element_count = EXCLUDED.unresolved_element_count,
        profiled_element_count = EXCLUDED.profiled_element_count,
        unprofiled_element_count = EXCLUDED.unprofiled_element_count,
        enabled_point_count = EXCLUDED.enabled_point_count,
        produced_point_count = EXCLUDED.produced_point_count,
        diagnostic_details = EXCLUDED.diagnostic_details;

    GET DIAGNOSTICS v_inserted_rows = ROW_COUNT;

    UPDATE telemetry.pipeline_state
    SET
        last_received_at = v_window_end,
        last_completed_at = clock_timestamp(),
        last_inserted_rows = v_inserted_rows,
        last_status = 'SUCCESS',
        last_error = NULL,
        updated_at = now()
    WHERE pipeline_name = v_pipeline_name;

EXCEPTION
    WHEN OTHERS THEN
        UPDATE telemetry.pipeline_state
        SET
            last_completed_at = clock_timestamp(),
            last_inserted_rows = 0,
            last_status = 'FAILED',
            last_error = SQLSTATE || ': ' || SQLERRM,
            updated_at = now()
        WHERE pipeline_name = v_pipeline_name;

        RAISE;
END;
$$;

CREATE OR REPLACE VIEW analytics.v_device_telemetry_availability
WITH (security_barrier = TRUE)
AS
WITH policy AS (
    SELECT receiving_threshold_seconds, stale_threshold_seconds, silent_threshold_seconds
    FROM config.telemetry_availability_policy
    WHERE policy_key='DEFAULT'
),
profile_mapping AS (
    SELECT profile_id,
           count(*) AS mapped_point_count,
           count(*) FILTER (WHERE is_required) AS required_point_count
    FROM config.profile_field_mapping
    GROUP BY profile_id
),
asset_association AS (
    SELECT ad.device_id,
           string_agg(DISTINCT a.name, ', ' ORDER BY a.name) AS associated_asset_names
    FROM metadata.asset_devices ad
    JOIN metadata.assets a ON a.id=ad.asset_id
    GROUP BY ad.device_id
)
SELECT
    d.organization_id,
    g.site_id,
    s.name AS site_name,
    g.id AS gateway_id,
    g.name AS gateway_name,
    d.id AS device_id,
    d.name AS device_name,
    d.external_id,
    d.lifecycle_status,
    d.profile_id,
    dp.profile_code,
    coalesce(aa.associated_asset_names,'—') AS associated_asset_names,
    CASE
        WHEN d.profile_id IS NULL OR d.device_model_id IS NULL THEN 'INVALID_PROFILE'
        WHEN NOT EXISTS (
            SELECT 1 FROM config.device_profile_categories dpc
            JOIN metadata.device_models dm ON dm.id=d.device_model_id
            WHERE dpc.profile_id=d.profile_id
              AND dpc.device_category_id=dm.device_category_id
        ) THEN 'INVALID_PROFILE'
        WHEN coalesce(pm.mapped_point_count,0)=0 THEN 'UNMAPPED'
        ELSE 'VALIDATED'
    END AS configuration_state,
    CASE
        WHEN ts.latest_received_timestamp IS NULL THEN 'NEVER_SEEN'
        WHEN ts.latest_received_timestamp < now()-make_interval(secs=>p.silent_threshold_seconds) THEN 'SILENT'
        WHEN d.profile_id IS NULL OR d.device_model_id IS NULL OR coalesce(pm.mapped_point_count,0)=0
          OR NOT EXISTS (
              SELECT 1 FROM config.device_profile_categories dpc
              JOIN metadata.device_models dm ON dm.id=d.device_model_id
              WHERE dpc.profile_id=d.profile_id
                AND dpc.device_category_id=dm.device_category_id
          ) THEN 'INVALID_PROFILE'
        WHEN d.operational_policy='ASSET_ASSIGNED'
         AND NOT EXISTS (SELECT 1 FROM metadata.asset_devices ad WHERE ad.device_id=d.id)
        THEN 'UNMAPPED'
        WHEN ts.latest_valid_source_timestamp IS NULL THEN 'RECEIVING'
        WHEN ts.latest_valid_source_timestamp < now()-make_interval(secs=>p.stale_threshold_seconds) THEN 'STALE'
        WHEN ts.latest_valid_received_timestamp >= now()-make_interval(secs=>p.receiving_threshold_seconds) THEN 'VALIDATED'
        ELSE 'RECEIVING'
    END AS telemetry_state,
    ts.latest_source_timestamp,
    ts.latest_received_timestamp,
    ts.latest_valid_source_timestamp,
    ts.latest_valid_received_timestamp,
    CASE
        WHEN d.profile_id IS NULL THEN 'PROFILE_MISSING'
        WHEN d.device_model_id IS NULL THEN 'DEVICE_MODEL_MISSING'
        WHEN NOT EXISTS (
            SELECT 1 FROM config.device_profile_categories dpc
            JOIN metadata.device_models dm ON dm.id=d.device_model_id
            WHERE dpc.profile_id=d.profile_id
              AND dpc.device_category_id=dm.device_category_id
        ) THEN 'PROFILE_CATEGORY_INCOMPATIBLE'
        WHEN coalesce(pm.mapped_point_count,0)=0 THEN 'PROFILE_UNMAPPED'
        ELSE 'PROFILE_VALID'
    END AS profile_validation_result,
    coalesce(pm.mapped_point_count,0)::BIGINT AS mapped_point_count,
    coalesce(pm.required_point_count,0)::BIGINT AS required_point_count,
    p.receiving_threshold_seconds,
    p.stale_threshold_seconds,
    p.silent_threshold_seconds
FROM metadata.devices d
JOIN metadata.gateways g ON g.id=d.gateway_id
JOIN metadata.sites s ON s.id=g.site_id
LEFT JOIN config.device_profiles dp ON dp.id=d.profile_id
LEFT JOIN profile_mapping pm ON pm.profile_id=d.profile_id
LEFT JOIN telemetry.device_telemetry_state ts ON ts.device_id=d.id
LEFT JOIN asset_association aa ON aa.device_id=d.id
CROSS JOIN policy p;

CREATE OR REPLACE VIEW analytics.v_gateway_connectivity
WITH (security_barrier = TRUE)
AS
WITH status_seen AS (
    SELECT ds.gateway_id,
           max(coalesce(ds.last_successful_communication,ds.source_timestamp,ds.received_at)) AS last_seen_at
    FROM telemetry.device_status ds
    WHERE ds.gateway_id IS NOT NULL
    GROUP BY ds.gateway_id
),
telemetry_seen AS (
    SELECT d.gateway_id,
           max(ts.latest_received_timestamp) AS last_seen_at
    FROM metadata.devices d
    JOIN telemetry.device_telemetry_state ts ON ts.device_id=d.id
    WHERE d.gateway_id IS NOT NULL
    GROUP BY d.gateway_id
)
SELECT
    g.id AS gateway_id,
    ss.last_seen_at AS status_last_seen_at,
    ts.last_seen_at AS telemetry_last_seen_at,
    greatest(ss.last_seen_at,ts.last_seen_at) AS last_seen_at,
    CASE
        WHEN ss.last_seen_at IS NULL AND ts.last_seen_at IS NULL THEN NULL
        WHEN ts.last_seen_at IS NULL THEN 'DEVICE_STATUS'
        WHEN ss.last_seen_at IS NULL THEN 'NORMALIZED_TELEMETRY'
        WHEN ts.last_seen_at >= ss.last_seen_at THEN 'NORMALIZED_TELEMETRY'
        ELSE 'DEVICE_STATUS'
    END AS last_seen_source
FROM metadata.gateways g
LEFT JOIN status_seen ss ON ss.gateway_id=g.id
LEFT JOIN telemetry_seen ts ON ts.gateway_id=g.id;

CREATE OR REPLACE VIEW analytics.v_commissioning_readiness
WITH (security_barrier = TRUE)
AS
WITH asset_readiness AS (
    SELECT
        'ASSET'::text AS entity_type,
        a.id AS entity_id,
        a.organization_id,
        a.site_id,
        a.name AS entity_name,
        a.lifecycle_status,
        CASE
            WHEN a.lifecycle_status = 'ACTIVE' THEN 'COMMISSIONED'
            WHEN a.lifecycle_status = 'COMMISSIONING' THEN 'IN_PROGRESS'
            WHEN a.lifecycle_status = 'DECOMMISSIONED' THEN 'FAILED'
            WHEN c.coverage_status IN ('MISSING_DIRECT_METER', 'UNKNOWN_POLICY') THEN 'BLOCKED'
            ELSE 'READY'
        END AS commissioning_status,
        (
            a.lifecycle_status <> 'DECOMMISSIONED'
            AND (
                a.lifecycle_status = 'ACTIVE'
                OR a.metering_requirement IN ('NOT_REQUIRED', 'DESCENDANT_COVERAGE_ALLOWED')
                OR (
                    a.metering_requirement = 'DIRECT_METER_REQUIRED'
                    AND c.coverage_status = 'CONFIGURED'
                )
            )
        ) AS is_ready,
        ARRAY_REMOVE(ARRAY[
            CASE WHEN a.lifecycle_status = 'DECOMMISSIONED' THEN 'ASSET_DECOMMISSIONED' END,
            CASE WHEN a.metering_requirement IS NULL THEN 'METERING_POLICY_MISSING' END,
            CASE
                WHEN a.metering_requirement = 'DIRECT_METER_REQUIRED'
                 AND c.coverage_status IS DISTINCT FROM 'CONFIGURED'
                THEN 'QUALIFYING_PRIMARY_METER_REQUIRED'
            END
        ], NULL)::text[] AS blocking_reason_codes,
        ARRAY_REMOVE(ARRAY[
            CASE
                WHEN a.metering_requirement = 'DESCENDANT_COVERAGE_ALLOWED'
                 AND c.coverage_status IN ('NO_REQUIRED_DESCENDANTS', 'PARTIALLY_CONFIGURED', 'MISSING_DESCENDANT_COVERAGE')
                THEN c.coverage_status
            END
        ], NULL)::text[] AS warning_reason_codes
    FROM metadata.assets a
    LEFT JOIN analytics.v_asset_meter_coverage_configuration c
      ON c.asset_id = a.id
),
gateway_last_seen AS (
    SELECT gateway_id, last_seen_at
    FROM analytics.v_gateway_connectivity
),
gateway_readiness AS (
    SELECT
        'GATEWAY'::text AS entity_type,
        g.id AS entity_id,
        g.organization_id,
        g.site_id,
        g.name AS entity_name,
        g.lifecycle_status,
        CASE
            WHEN g.lifecycle_status = 'ACTIVE' THEN 'COMMISSIONED'
            WHEN g.lifecycle_status = 'COMMISSIONING' THEN 'IN_PROGRESS'
            WHEN g.lifecycle_status = 'DECOMMISSIONED' THEN 'FAILED'
            WHEN nullif(btrim(g.external_id), '') IS NULL OR g.gateway_model_id IS NULL THEN 'BLOCKED'
            WHEN gls.last_seen_at IS NULL THEN 'BLOCKED'
            WHEN gls.last_seen_at < now() - make_interval(secs => gcp.online_threshold_seconds) THEN 'BLOCKED'
            ELSE 'READY'
        END AS commissioning_status,
        (
            g.lifecycle_status = 'ACTIVE'
            OR (
                g.lifecycle_status <> 'DECOMMISSIONED'
                AND nullif(btrim(g.external_id), '') IS NOT NULL
                AND g.gateway_model_id IS NOT NULL
                AND gls.last_seen_at >= now() - make_interval(secs => gcp.online_threshold_seconds)
            )
        ) AS is_ready,
        ARRAY_REMOVE(ARRAY[
            CASE WHEN g.lifecycle_status = 'DECOMMISSIONED' THEN 'GATEWAY_DECOMMISSIONED' END,
            CASE WHEN nullif(btrim(g.external_id), '') IS NULL THEN 'GATEWAY_IDENTITY_MISSING' END,
            CASE WHEN g.gateway_model_id IS NULL THEN 'GATEWAY_MODEL_MISSING' END,
            CASE WHEN g.lifecycle_status <> 'ACTIVE' AND gls.last_seen_at IS NULL THEN 'GATEWAY_NEVER_SEEN' END,
            CASE WHEN g.lifecycle_status <> 'ACTIVE' AND gls.last_seen_at IS NOT NULL AND gls.last_seen_at < now() - make_interval(secs => gcp.online_threshold_seconds) THEN 'GATEWAY_CONNECTIVITY_OFFLINE' END
        ], NULL)::text[] AS blocking_reason_codes,
        ARRAY_REMOVE(ARRAY[
            CASE WHEN g.lifecycle_status = 'ACTIVE' AND gls.last_seen_at IS NULL THEN 'GATEWAY_CURRENTLY_NEVER_SEEN' END,
            CASE WHEN g.lifecycle_status = 'ACTIVE' AND gls.last_seen_at IS NOT NULL AND gls.last_seen_at < now() - make_interval(secs => gcp.online_threshold_seconds) THEN 'GATEWAY_CURRENTLY_OFFLINE' END
        ], NULL)::text[] AS warning_reason_codes
    FROM metadata.gateways g
    CROSS JOIN config.gateway_connectivity_policy gcp
    LEFT JOIN gateway_last_seen gls ON gls.gateway_id = g.id
),
device_required_points AS (
    SELECT
        d.id AS device_id,
        count(DISTINCT pfm.logical_point_id) FILTER (WHERE pfm.is_required) AS required_point_count,
        count(DISTINCT dps.logical_point_id) FILTER (
            WHERE pfm.is_required
              AND dps.last_valid_received_at IS NOT NULL
        ) AS validated_required_point_count
    FROM metadata.devices d
    LEFT JOIN config.profile_field_mapping pfm
      ON pfm.profile_id=d.profile_id
    LEFT JOIN telemetry.device_point_state dps
      ON dps.device_id=d.id
     AND dps.logical_point_id=pfm.logical_point_id
    GROUP BY d.id
),
device_readiness AS (
    SELECT
        'DEVICE'::text AS entity_type,
        d.id AS entity_id,
        d.organization_id,
        g.site_id,
        d.name AS entity_name,
        d.lifecycle_status,
        CASE
            WHEN d.lifecycle_status = 'ACTIVE' THEN 'COMMISSIONED'
            WHEN d.lifecycle_status = 'COMMISSIONING' THEN 'IN_PROGRESS'
            WHEN d.lifecycle_status = 'DECOMMISSIONED' THEN 'FAILED'
            WHEN d.gateway_id IS NULL OR d.device_model_id IS NULL OR d.profile_id IS NULL THEN 'BLOCKED'
            WHEN NOT EXISTS (
                SELECT 1
                FROM config.device_profile_categories dpc
                JOIN metadata.device_models dm ON dm.id = d.device_model_id
                WHERE dpc.profile_id = d.profile_id
                  AND dpc.device_category_id = dm.device_category_id
            ) THEN 'BLOCKED'
            WHEN drp.validated_required_point_count < drp.required_point_count THEN 'BLOCKED'
            WHEN d.operational_policy = 'ASSET_ASSIGNED'
             AND NOT EXISTS (
                SELECT 1 FROM metadata.asset_devices ad WHERE ad.device_id = d.id
             ) THEN 'BLOCKED'
            ELSE 'READY'
        END AS commissioning_status,
        (
            d.lifecycle_status = 'ACTIVE'
            OR (
                d.lifecycle_status <> 'DECOMMISSIONED'
                AND d.gateway_id IS NOT NULL
                AND d.device_model_id IS NOT NULL
                AND d.profile_id IS NOT NULL
                AND EXISTS (
                    SELECT 1
                    FROM config.device_profile_categories dpc
                    JOIN metadata.device_models dm ON dm.id = d.device_model_id
                    WHERE dpc.profile_id = d.profile_id
                      AND dpc.device_category_id = dm.device_category_id
                )
                AND drp.validated_required_point_count = drp.required_point_count
                AND (
                    d.operational_policy <> 'ASSET_ASSIGNED'
                    OR EXISTS (
                        SELECT 1 FROM metadata.asset_devices ad WHERE ad.device_id = d.id
                    )
                )
            )
        ) AS is_ready,
        ARRAY_REMOVE(ARRAY[
            CASE WHEN d.lifecycle_status = 'DECOMMISSIONED' THEN 'DEVICE_DECOMMISSIONED' END,
            CASE WHEN d.gateway_id IS NULL THEN 'GATEWAY_REQUIRED' END,
            CASE WHEN d.device_model_id IS NULL THEN 'DEVICE_MODEL_REQUIRED' END,
            CASE WHEN d.profile_id IS NULL THEN 'DEVICE_PROFILE_REQUIRED' END,
            CASE
                WHEN d.device_model_id IS NOT NULL
                 AND d.profile_id IS NOT NULL
                 AND NOT EXISTS (
                    SELECT 1
                    FROM config.device_profile_categories dpc
                    JOIN metadata.device_models dm ON dm.id = d.device_model_id
                    WHERE dpc.profile_id = d.profile_id
                      AND dpc.device_category_id = dm.device_category_id
                 )
                THEN 'PROFILE_CATEGORY_INCOMPATIBLE'
            END,
            CASE
                WHEN coalesce(drp.required_point_count, 0) > 0
                 AND drp.validated_required_point_count < drp.required_point_count
                THEN 'REQUIRED_TELEMETRY_POINTS_NOT_VALIDATED'
            END,
            CASE
                WHEN d.operational_policy = 'ASSET_ASSIGNED'
                 AND NOT EXISTS (SELECT 1 FROM metadata.asset_devices ad WHERE ad.device_id = d.id)
                THEN 'ASSET_ASSIGNMENT_REQUIRED_BY_POLICY'
            END
        ], NULL)::text[] AS blocking_reason_codes,
        ARRAY[]::text[] AS warning_reason_codes
    FROM metadata.devices d
    LEFT JOIN metadata.gateways g ON g.id = d.gateway_id
    LEFT JOIN device_required_points drp ON drp.device_id = d.id
)
SELECT * FROM asset_readiness
UNION ALL
SELECT * FROM gateway_readiness
UNION ALL
SELECT * FROM device_readiness;


COMMENT ON VIEW analytics.v_device_telemetry_availability IS
'Latest device telemetry/configuration state backed by compact telemetry.device_telemetry_state rather than historical telemetry scans.';
COMMENT ON VIEW analytics.v_gateway_connectivity IS
'Gateway last-seen evidence from explicit device status or compact assigned-device telemetry state.';
COMMENT ON VIEW analytics.v_commissioning_readiness IS
'Declarative readiness for assets, gateways and devices. Required telemetry validation uses compact telemetry.device_point_state rather than historical telemetry scans.';

-- Remove the hidden payload-column dependency created historically by
-- SELECT np.* inside the full-resolution energy view.  The final public view
-- contract is unchanged; only the internal profile_context projection is made
-- explicit so normalized_points.payload can be dropped safely.
CREATE OR REPLACE VIEW telemetry.v_energy_measurements_full_resolution AS
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
) > 0;

COMMENT ON VIEW telemetry.v_energy_measurements_full_resolution IS
'Full-resolution energy route. Rows are emitted only when at least one supported energy-domain output is populated.';


-- Defensive dependency gate: after the full-resolution energy view has been
-- rewritten, no database object should still depend on the durable payload
-- column. Abort before the schema change if production has an untracked
-- dependency that is absent from the repository snapshot.
DO $$
DECLARE
    v_payload_attnum SMALLINT;
    v_dependents TEXT;
BEGIN
    SELECT attnum
    INTO v_payload_attnum
    FROM pg_catalog.pg_attribute
    WHERE attrelid = 'telemetry.normalized_points'::regclass
      AND attname = 'payload'
      AND NOT attisdropped;

    IF v_payload_attnum IS NOT NULL THEN
        SELECT string_agg(
                   DISTINCT pg_catalog.pg_describe_object(
                       d.classid, d.objid, d.objsubid
                   ),
                   '; ' ORDER BY pg_catalog.pg_describe_object(
                       d.classid, d.objid, d.objsubid
                   )
               )
        INTO v_dependents
        FROM pg_catalog.pg_depend d
        WHERE d.refobjid = 'telemetry.normalized_points'::regclass
          AND d.refobjsubid = v_payload_attnum
          AND d.deptype IN ('n','a');

        IF v_dependents IS NOT NULL THEN
            RAISE EXCEPTION
                'Refusing to drop telemetry.normalized_points.payload; remaining dependencies: %',
                v_dependents;
        END IF;
    END IF;
END;
$$;

-- Durable normalized rows no longer carry the per-element JSON payload. The
-- canonical raw payload remains in raw_messages and failed payloads remain in
-- raw_message_failures for their configured retention periods.
ALTER TABLE telemetry.normalized_points
DROP COLUMN IF EXISTS payload;

-- Compress old normalized chunks after the schema change. Compression rewrites
-- tuples using the lean column set and avoids a disruptive VACUUM FULL.
SELECT remove_compression_policy('telemetry.normalized_points',if_exists=>TRUE);
SELECT add_compression_policy('telemetry.normalized_points',INTERVAL '1 day');

-- Bound replay windows. The scheduled state is deliberately left unchanged.
DO $$
DECLARE r RECORD;
BEGIN
    FOR r IN
        SELECT job_id,proc_name
        FROM timescaledb_information.jobs
        WHERE proc_schema='telemetry'
          AND proc_name IN (
              'run_normalization_job',
              'run_energy_routing_job',
              'run_environment_routing_job'
          )
    LOOP
        PERFORM alter_job(r.job_id,config=>' {"overlap":"1 minute"} '::jsonb);
    END LOOP;

    FOR r IN
        SELECT job_id
        FROM timescaledb_information.jobs
        WHERE proc_schema='telemetry'
          AND proc_name='run_raw_message_failure_capture_job'
    LOOP
        PERFORM alter_job(r.job_id,config=>' {"grace":"20 minutes","overlap":"1 minute"} '::jsonb);
    END LOOP;
END;
$$;

-- Preserve ownership/access boundaries for new state objects.
ALTER TABLE telemetry.device_point_state OWNER TO ems_admin;
ALTER TABLE telemetry.device_telemetry_state OWNER TO ems_admin;
REVOKE ALL ON telemetry.device_point_state FROM PUBLIC;
REVOKE ALL ON telemetry.device_telemetry_state FROM PUBLIC;
GRANT SELECT ON telemetry.device_point_state,telemetry.device_telemetry_state TO ems_readonly,grafana_reader;
GRANT SELECT,INSERT,UPDATE ON telemetry.device_point_state,telemetry.device_telemetry_state TO ems_admin;


ALTER VIEW analytics.v_device_telemetry_availability OWNER TO ems_admin;
ALTER VIEW analytics.v_gateway_connectivity OWNER TO ems_admin;
ALTER VIEW analytics.v_commissioning_readiness OWNER TO ems_admin;
REVOKE ALL ON analytics.v_device_telemetry_availability FROM PUBLIC;
REVOKE ALL ON analytics.v_gateway_connectivity FROM PUBLIC;
REVOKE ALL ON analytics.v_commissioning_readiness FROM PUBLIC;
GRANT SELECT ON analytics.v_gateway_connectivity,analytics.v_commissioning_readiness TO ems_app,ems_readonly,grafana_reader;
