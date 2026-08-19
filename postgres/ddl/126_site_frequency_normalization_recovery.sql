-- 126_site_frequency_normalization_recovery.sql
-- Site-frequency normalization, 48-hour raw retention, raw-arrival connectivity,
-- selected-sample failure semantics, and hourly recovery/replay.
-- The migration runner owns the transaction.

-- ---------------------------------------------------------------------------
-- 1. Persist one finalized source sample per site/bucket/device.
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS telemetry.capture_bucket_samples
(
    site_id UUID NOT NULL,
    device_id UUID NOT NULL,
    policy_id BIGINT,
    bucket_start TIMESTAMPTZ NOT NULL,
    capture_interval_seconds INTEGER NOT NULL,
    late_arrival_tolerance_seconds INTEGER NOT NULL,
    source_timestamp TIMESTAMPTZ,
    event_time TIMESTAMPTZ NOT NULL,
    raw_received_at TIMESTAMPTZ NOT NULL,
    raw_message_id BIGINT NOT NULL,
    selected_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    normalized_at TIMESTAMPTZ,
    status TEXT NOT NULL DEFAULT 'SELECTED',
    last_error TEXT,
    PRIMARY KEY (site_id, bucket_start, device_id),
    CONSTRAINT capture_bucket_samples_status_ck
        CHECK (status IN ('SELECTED','NORMALIZED','FAILED','RECOVERED')),
    CONSTRAINT capture_bucket_samples_interval_ck
        CHECK (capture_interval_seconds > 0),
    CONSTRAINT capture_bucket_samples_late_ck
        CHECK (late_arrival_tolerance_seconds >= 0)
);

CREATE INDEX IF NOT EXISTS capture_bucket_samples_raw_idx
ON telemetry.capture_bucket_samples(raw_received_at, raw_message_id);

CREATE INDEX IF NOT EXISTS capture_bucket_samples_pending_idx
ON telemetry.capture_bucket_samples(bucket_start, device_id)
WHERE status IN ('SELECTED','FAILED');

COMMENT ON TABLE telemetry.capture_bucket_samples IS
'One finalized latest source sample per site wall-clock capture bucket and device. This is the durable idempotency ledger between raw MQTT receipt and canonical normalization.';

-- ---------------------------------------------------------------------------
-- 2. Raw-arrival state is deliberately separate from stored sample state.
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS telemetry.device_raw_receipt_state
(
    device_id UUID PRIMARY KEY,
    latest_raw_received_at TIMESTAMPTZ NOT NULL,
    latest_raw_source_timestamp TIMESTAMPTZ,
    latest_raw_message_id BIGINT,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

COMMENT ON TABLE telemetry.device_raw_receipt_state IS
'Latest resolved raw MQTT receipt per device. Connectivity uses this state so a five-minute normalization batch does not make a continuously publishing device appear offline.';

INSERT INTO telemetry.pipeline_state(pipeline_name,last_status)
VALUES ('raw_receipt_state','NEVER_RUN')
ON CONFLICT (pipeline_name) DO NOTHING;

CREATE OR REPLACE PROCEDURE telemetry.load_device_raw_receipt_state_incremental
(
    p_overlap INTERVAL DEFAULT INTERVAL '2 minutes'
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_pipeline_name CONSTANT TEXT := 'raw_receipt_state';
    v_previous_checkpoint TIMESTAMPTZ;
    v_window_start TIMESTAMPTZ;
    v_window_end TIMESTAMPTZ;
    v_rows BIGINT := 0;
    v_lock_acquired BOOLEAN;
BEGIN
    IF p_overlap IS NULL OR p_overlap < INTERVAL '0 seconds' THEN
        RAISE EXCEPTION 'p_overlap must be zero or positive; received %', p_overlap;
    END IF;

    SELECT pg_try_advisory_xact_lock(
        hashtextextended('telemetry.load_device_raw_receipt_state_incremental',0)
    ) INTO v_lock_acquired;

    IF NOT v_lock_acquired THEN
        UPDATE telemetry.pipeline_state
        SET last_status='SKIPPED_LOCKED',last_error=NULL,updated_at=now()
        WHERE pipeline_name=v_pipeline_name;
        RETURN;
    END IF;

    SELECT last_received_at INTO v_previous_checkpoint
    FROM telemetry.pipeline_state
    WHERE pipeline_name=v_pipeline_name
    FOR UPDATE;

    UPDATE telemetry.pipeline_state
    SET last_started_at=clock_timestamp(),last_status='RUNNING',last_error=NULL,updated_at=now()
    WHERE pipeline_name=v_pipeline_name;

    SELECT max(received_at) INTO v_window_end FROM telemetry.raw_messages;
    IF v_window_end IS NULL THEN
        UPDATE telemetry.pipeline_state
        SET last_completed_at=clock_timestamp(),last_inserted_rows=0,
            last_status='NO_SOURCE_DATA',last_error=NULL,updated_at=now()
        WHERE pipeline_name=v_pipeline_name;
        RETURN;
    END IF;

    v_window_start := CASE
        WHEN v_previous_checkpoint IS NULL
            THEN GREATEST(v_window_end-INTERVAL '10 minutes',
                          COALESCE((SELECT min(received_at)-INTERVAL '1 microsecond'
                                    FROM telemetry.raw_messages),v_window_end))
        ELSE v_previous_checkpoint-p_overlap
    END;

    CREATE TEMP TABLE tmp_raw_receipt_batch ON COMMIT DROP AS
    SELECT DISTINCT ON (d.id)
        d.id AS device_id,
        r.received_at,
        r.source_timestamp,
        r.raw_message_id
    FROM telemetry.v_rtdata r
    JOIN metadata.device_identifiers di
      ON di.identifier_type='MQTT_UID'
     AND lower(di.identifier_value)=lower(r.device_uid)
    JOIN metadata.devices d ON d.id=di.device_id
    WHERE r.received_at > v_window_start
      AND r.received_at <= v_window_end
    ORDER BY d.id,r.received_at DESC,r.raw_message_id DESC;

    INSERT INTO telemetry.device_raw_receipt_state
    (device_id,latest_raw_received_at,latest_raw_source_timestamp,latest_raw_message_id,updated_at)
    SELECT device_id,received_at,source_timestamp,raw_message_id,now()
    FROM tmp_raw_receipt_batch
    ON CONFLICT (device_id) DO UPDATE
    SET latest_raw_received_at=GREATEST(
            telemetry.device_raw_receipt_state.latest_raw_received_at,
            EXCLUDED.latest_raw_received_at),
        latest_raw_source_timestamp=CASE
            WHEN EXCLUDED.latest_raw_received_at >= telemetry.device_raw_receipt_state.latest_raw_received_at
            THEN EXCLUDED.latest_raw_source_timestamp
            ELSE telemetry.device_raw_receipt_state.latest_raw_source_timestamp
        END,
        latest_raw_message_id=CASE
            WHEN EXCLUDED.latest_raw_received_at >= telemetry.device_raw_receipt_state.latest_raw_received_at
            THEN EXCLUDED.latest_raw_message_id
            ELSE telemetry.device_raw_receipt_state.latest_raw_message_id
        END,
        updated_at=now();

    GET DIAGNOSTICS v_rows=ROW_COUNT;

    -- Preserve existing admin/device availability semantics: receipt freshness
    -- follows raw MQTT arrival, while valid/source freshness remains tied to
    -- canonical sampled normalization.
    INSERT INTO telemetry.device_telemetry_state
    (device_id,latest_received_timestamp,updated_at)
    SELECT device_id,received_at,now()
    FROM tmp_raw_receipt_batch
    ON CONFLICT (device_id) DO UPDATE
    SET latest_received_timestamp=GREATEST(
            telemetry.device_telemetry_state.latest_received_timestamp,
            EXCLUDED.latest_received_timestamp),
        updated_at=now();

    UPDATE telemetry.pipeline_state
    SET last_received_at=v_window_end,last_completed_at=clock_timestamp(),
        last_inserted_rows=v_rows,last_status='SUCCESS',last_error=NULL,updated_at=now()
    WHERE pipeline_name=v_pipeline_name;
EXCEPTION WHEN OTHERS THEN
    UPDATE telemetry.pipeline_state
    SET last_completed_at=clock_timestamp(),last_inserted_rows=0,
        last_status='FAILED',last_error=SQLSTATE||': '||SQLERRM,updated_at=now()
    WHERE pipeline_name=v_pipeline_name;
    RAISE;
END;
$$;

CREATE OR REPLACE PROCEDURE telemetry.run_raw_receipt_state_job(job_id INTEGER,config JSONB)
LANGUAGE plpgsql
AS $$
DECLARE
    v_overlap INTERVAL := INTERVAL '2 minutes';
BEGIN
    IF config IS NOT NULL AND config ? 'overlap'
       AND NULLIF(btrim(config->>'overlap'),'') IS NOT NULL THEN
        v_overlap := (config->>'overlap')::INTERVAL;
    END IF;
    CALL telemetry.load_device_raw_receipt_state_incremental(v_overlap);
END;
$$;

-- ---------------------------------------------------------------------------
-- 3. Replace full-resolution normalization with capture-bucket selection.
--    The raw window is parsed only to device-element level first; point
--    expansion is performed only for the selected sample identities.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE telemetry.load_normalized_points_incremental
(
    p_overlap INTERVAL DEFAULT INTERVAL '20 minutes'
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_pipeline_name CONSTANT TEXT := 'normalized_points';
    v_previous_checkpoint TIMESTAMPTZ;
    v_window_start TIMESTAMPTZ;
    v_window_end TIMESTAMPTZ;
    v_dynamic_overlap INTERVAL;
    v_rows BIGINT := 0;
    v_lock_acquired BOOLEAN;
BEGIN
    IF p_overlap IS NULL OR p_overlap < INTERVAL '0 seconds' THEN
        RAISE EXCEPTION 'p_overlap must be zero or positive; received %',p_overlap;
    END IF;

    SELECT pg_try_advisory_xact_lock(
        hashtextextended('telemetry.load_normalized_points_incremental',0)
    ) INTO v_lock_acquired;

    IF NOT v_lock_acquired THEN
        UPDATE telemetry.pipeline_state
        SET last_status='SKIPPED_LOCKED',last_error=NULL,updated_at=now()
        WHERE pipeline_name=v_pipeline_name;
        RETURN;
    END IF;

    SELECT last_received_at INTO v_previous_checkpoint
    FROM telemetry.pipeline_state
    WHERE pipeline_name=v_pipeline_name
    FOR UPDATE;

    UPDATE telemetry.pipeline_state
    SET last_started_at=clock_timestamp(),last_status='RUNNING',last_error=NULL,updated_at=now()
    WHERE pipeline_name=v_pipeline_name;

    SELECT max(received_at) INTO v_window_end FROM telemetry.raw_messages;
    IF v_window_end IS NULL THEN
        UPDATE telemetry.pipeline_state
        SET last_completed_at=clock_timestamp(),last_inserted_rows=0,
            last_status='NO_SOURCE_DATA',last_error=NULL,updated_at=now()
        WHERE pipeline_name=v_pipeline_name;
        RETURN;
    END IF;

    SELECT make_interval(secs => GREATEST(
               COALESCE(max(capture_interval_seconds+late_arrival_tolerance_seconds),0),
               extract(epoch FROM p_overlap)::INTEGER
           ))
      INTO v_dynamic_overlap
    FROM config.telemetry_capture_policies
    WHERE is_enabled;

    v_window_start := CASE
        WHEN v_previous_checkpoint IS NULL
            THEN GREATEST(v_window_end-INTERVAL '48 hours',
                          COALESCE((SELECT min(received_at)-INTERVAL '1 microsecond'
                                    FROM telemetry.raw_messages),v_window_end))
        ELSE v_previous_checkpoint-v_dynamic_overlap
    END;

    CREATE TEMP TABLE tmp_capture_candidates ON COMMIT DROP AS
    WITH resolved AS MATERIALIZED
    (
        SELECT
            r.received_at,
            r.raw_message_id,
            COALESCE(r.source_timestamp,r.received_at) AS event_time,
            r.source_timestamp,
            r.device_uid,
            d.id AS device_id,
            g.site_id,
            b.policy_id,
            b.capture_interval_seconds,
            b.late_arrival_tolerance_seconds,
            b.bucket_start,
            b.bucket_start+make_interval(secs=>b.capture_interval_seconds) AS bucket_end,
            b.bucket_start+make_interval(secs=>b.capture_interval_seconds+b.late_arrival_tolerance_seconds) AS finalization_deadline
        FROM telemetry.v_rtdata r
        JOIN metadata.device_identifiers di
          ON di.identifier_type='MQTT_UID'
         AND lower(di.identifier_value)=lower(r.device_uid)
        JOIN metadata.devices d ON d.id=di.device_id
        JOIN metadata.gateways g ON g.id=d.gateway_id
        CROSS JOIN LATERAL telemetry.resolve_site_capture_bucket(
            g.site_id,COALESCE(r.source_timestamp,r.received_at)
        ) b
        WHERE r.received_at > v_window_start
          AND r.received_at <= v_window_end
          AND d.profile_id IS NOT NULL
          AND b.policy_id IS NOT NULL
    )
    SELECT DISTINCT ON (site_id,bucket_start,device_id)
        site_id,device_id,policy_id,bucket_start,
        capture_interval_seconds,late_arrival_tolerance_seconds,
        source_timestamp,event_time,received_at AS raw_received_at,raw_message_id
    FROM resolved
    WHERE finalization_deadline <= clock_timestamp()
      AND received_at <= finalization_deadline
    ORDER BY site_id,bucket_start,device_id,
             event_time DESC,received_at DESC,raw_message_id DESC;

    CREATE UNIQUE INDEX ON tmp_capture_candidates(site_id,bucket_start,device_id);

    INSERT INTO telemetry.capture_bucket_samples
    (
        site_id,device_id,policy_id,bucket_start,capture_interval_seconds,
        late_arrival_tolerance_seconds,source_timestamp,event_time,
        raw_received_at,raw_message_id,status,last_error
    )
    SELECT
        c.site_id,c.device_id,c.policy_id,c.bucket_start,c.capture_interval_seconds,
        c.late_arrival_tolerance_seconds,c.source_timestamp,c.event_time,
        c.raw_received_at,c.raw_message_id,'SELECTED',NULL
    FROM tmp_capture_candidates c
    ON CONFLICT (site_id,bucket_start,device_id) DO NOTHING;

    CREATE TEMP TABLE tmp_selected_samples ON COMMIT DROP AS
    SELECT s.*
    FROM telemetry.capture_bucket_samples s
    JOIN tmp_capture_candidates c
      ON c.site_id=s.site_id
     AND c.bucket_start=s.bucket_start
     AND c.device_id=s.device_id
    WHERE s.status IN ('SELECTED','FAILED');

    CREATE TEMP TABLE tmp_normalized_batch ON COMMIT DROP AS
    SELECT np.*
    FROM tmp_selected_samples s
    CROSS JOIN LATERAL
    (
        SELECT source_np.*
        FROM telemetry.v_normalized_points source_np
        WHERE source_np.raw_message_id=s.raw_message_id
          AND source_np.device_id=s.device_id
          AND source_np.event_time=s.event_time
        OFFSET 0
    ) np;

    INSERT INTO telemetry.normalized_points
    (
        event_time,organization_id,site_id,gateway_id,device_id,
        logical_point_id,device_uid,logical_point,raw_field_name,
        raw_value,numeric_value,quality_code,mapping_source,
        platform_received_at,raw_message_id
    )
    SELECT
        b.event_time,b.organization_id,b.site_id,b.gateway_id,b.device_id,
        b.logical_point_id,b.device_uid,b.logical_point,b.raw_field_name,
        b.raw_value,b.numeric_value,b.quality_code,b.mapping_source,
        b.received_at,b.raw_message_id
    FROM tmp_normalized_batch b
    ON CONFLICT (event_time,device_id,logical_point_id) DO UPDATE
    SET platform_received_at=EXCLUDED.platform_received_at,
        raw_message_id=EXCLUDED.raw_message_id
    WHERE telemetry.normalized_points.platform_received_at IS NULL
       OR telemetry.normalized_points.raw_message_id IS NULL
       OR EXCLUDED.platform_received_at > telemetry.normalized_points.platform_received_at;

    GET DIAGNOSTICS v_rows=ROW_COUNT;

    UPDATE telemetry.capture_bucket_samples s
    SET status=CASE WHEN x.point_count>0 THEN 'NORMALIZED' ELSE 'FAILED' END,
        normalized_at=CASE WHEN x.point_count>0 THEN clock_timestamp() ELSE s.normalized_at END,
        last_error=CASE WHEN x.point_count>0 THEN NULL ELSE 'No enabled normalized points produced for selected sample.' END
    FROM
    (
        SELECT ss.site_id,ss.bucket_start,ss.device_id,count(nb.logical_point_id)::INTEGER AS point_count
        FROM tmp_selected_samples ss
        LEFT JOIN tmp_normalized_batch nb
          ON nb.device_id=ss.device_id
         AND nb.raw_message_id=ss.raw_message_id
         AND nb.event_time=ss.event_time
        GROUP BY ss.site_id,ss.bucket_start,ss.device_id
    ) x
    WHERE s.site_id=x.site_id AND s.bucket_start=x.bucket_start AND s.device_id=x.device_id;

    INSERT INTO telemetry.device_point_state
    (
        device_id,logical_point_id,first_seen_at,last_seen_at,last_received_at,
        first_valid_seen_at,last_valid_seen_at,last_valid_received_at,updated_at
    )
    SELECT
        b.device_id,b.logical_point_id,min(b.event_time),max(b.event_time),max(b.received_at),
        min(b.event_time) FILTER (WHERE coalesce(b.quality_code,'GOOD') NOT IN ('INVALID','REJECTED','INVALID_NUMERIC') AND (b.numeric_value IS NOT NULL OR nullif(btrim(b.raw_value),'') IS NOT NULL)),
        max(b.event_time) FILTER (WHERE coalesce(b.quality_code,'GOOD') NOT IN ('INVALID','REJECTED','INVALID_NUMERIC') AND (b.numeric_value IS NOT NULL OR nullif(btrim(b.raw_value),'') IS NOT NULL)),
        max(b.received_at) FILTER (WHERE coalesce(b.quality_code,'GOOD') NOT IN ('INVALID','REJECTED','INVALID_NUMERIC') AND (b.numeric_value IS NOT NULL OR nullif(btrim(b.raw_value),'') IS NOT NULL)),
        now()
    FROM tmp_normalized_batch b
    GROUP BY b.device_id,b.logical_point_id
    ON CONFLICT (device_id,logical_point_id) DO UPDATE
    SET first_seen_at=LEAST(telemetry.device_point_state.first_seen_at,EXCLUDED.first_seen_at),
        last_seen_at=GREATEST(telemetry.device_point_state.last_seen_at,EXCLUDED.last_seen_at),
        last_received_at=GREATEST(telemetry.device_point_state.last_received_at,EXCLUDED.last_received_at),
        first_valid_seen_at=CASE
            WHEN telemetry.device_point_state.first_valid_seen_at IS NULL THEN EXCLUDED.first_valid_seen_at
            WHEN EXCLUDED.first_valid_seen_at IS NULL THEN telemetry.device_point_state.first_valid_seen_at
            ELSE LEAST(telemetry.device_point_state.first_valid_seen_at,EXCLUDED.first_valid_seen_at)
        END,
        last_valid_seen_at=GREATEST(telemetry.device_point_state.last_valid_seen_at,EXCLUDED.last_valid_seen_at),
        last_valid_received_at=GREATEST(telemetry.device_point_state.last_valid_received_at,EXCLUDED.last_valid_received_at),
        updated_at=now();

    INSERT INTO telemetry.device_telemetry_state
    (device_id,latest_source_timestamp,latest_received_timestamp,
     latest_valid_source_timestamp,latest_valid_received_timestamp,updated_at)
    SELECT
        b.device_id,max(b.event_time),max(b.received_at),
        max(b.event_time) FILTER (WHERE coalesce(b.quality_code,'GOOD') NOT IN ('INVALID','REJECTED','INVALID_NUMERIC') AND (b.numeric_value IS NOT NULL OR nullif(btrim(b.raw_value),'') IS NOT NULL)),
        max(b.received_at) FILTER (WHERE coalesce(b.quality_code,'GOOD') NOT IN ('INVALID','REJECTED','INVALID_NUMERIC') AND (b.numeric_value IS NOT NULL OR nullif(btrim(b.raw_value),'') IS NOT NULL)),now()
    FROM tmp_normalized_batch b
    GROUP BY b.device_id
    ON CONFLICT (device_id) DO UPDATE
    SET latest_source_timestamp=GREATEST(telemetry.device_telemetry_state.latest_source_timestamp,EXCLUDED.latest_source_timestamp),
        latest_received_timestamp=GREATEST(telemetry.device_telemetry_state.latest_received_timestamp,EXCLUDED.latest_received_timestamp),
        latest_valid_source_timestamp=GREATEST(telemetry.device_telemetry_state.latest_valid_source_timestamp,EXCLUDED.latest_valid_source_timestamp),
        latest_valid_received_timestamp=GREATEST(telemetry.device_telemetry_state.latest_valid_received_timestamp,EXCLUDED.latest_valid_received_timestamp),
        updated_at=now();

    UPDATE telemetry.pipeline_state
    SET last_received_at=v_window_end,last_completed_at=clock_timestamp(),
        last_inserted_rows=v_rows,last_status='SUCCESS',last_error=NULL,updated_at=now()
    WHERE pipeline_name=v_pipeline_name;
EXCEPTION WHEN OTHERS THEN
    UPDATE telemetry.pipeline_state
    SET last_completed_at=clock_timestamp(),last_inserted_rows=0,
        last_status='FAILED',last_error=SQLSTATE||': '||SQLERRM,updated_at=now()
    WHERE pipeline_name=v_pipeline_name;
    RAISE;
END;
$$;

COMMENT ON PROCEDURE telemetry.load_normalized_points_incremental(INTERVAL) IS
'Processes all closed site capture buckets in one shared batch. For each site/bucket/device it selects the latest source sample before the configured late-arrival deadline, then expands only that sample into enabled canonical logical points.';

-- ---------------------------------------------------------------------------
-- 4. Connectivity uses raw receipt state, while validity still comes from the
--    persisted/site-frequency normalized state.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW analytics.v_gateway_connectivity
WITH (security_barrier=TRUE)
AS
WITH status_seen AS
(
    SELECT ds.gateway_id,
           max(coalesce(ds.last_successful_communication,ds.source_timestamp,ds.received_at)) AS last_seen_at
    FROM telemetry.device_status ds
    WHERE ds.gateway_id IS NOT NULL
    GROUP BY ds.gateway_id
),
raw_seen AS
(
    SELECT d.gateway_id,max(rs.latest_raw_received_at) AS last_seen_at
    FROM metadata.devices d
    JOIN telemetry.device_raw_receipt_state rs ON rs.device_id=d.id
    WHERE d.gateway_id IS NOT NULL
    GROUP BY d.gateway_id
)
SELECT
    g.id AS gateway_id,
    ss.last_seen_at AS status_last_seen_at,
    rs.last_seen_at AS telemetry_last_seen_at,
    greatest(ss.last_seen_at,rs.last_seen_at) AS last_seen_at,
    CASE
        WHEN ss.last_seen_at IS NULL AND rs.last_seen_at IS NULL THEN NULL
        WHEN rs.last_seen_at IS NULL THEN 'DEVICE_STATUS'
        WHEN ss.last_seen_at IS NULL THEN 'RAW_TELEMETRY'
        WHEN rs.last_seen_at >= ss.last_seen_at THEN 'RAW_TELEMETRY'
        ELSE 'DEVICE_STATUS'
    END AS last_seen_source
FROM metadata.gateways g
LEFT JOIN status_seen ss ON ss.gateway_id=g.id
LEFT JOIN raw_seen rs ON rs.gateway_id=g.id;

-- ---------------------------------------------------------------------------
-- 5. Failure quarantine gains recovery state. Selected-sample persistence is
--    now the expected-normalization contract; high-frequency raw packets that
--    were not selected are normal and are not persistence failures.
-- ---------------------------------------------------------------------------
ALTER TABLE telemetry.raw_message_failures
    ADD COLUMN IF NOT EXISTS resolution_status TEXT NOT NULL DEFAULT 'OPEN',
    ADD COLUMN IF NOT EXISTS resolved_at TIMESTAMPTZ,
    ADD COLUMN IF NOT EXISTS resolution_method TEXT,
    ADD COLUMN IF NOT EXISTS replay_attempt_count INTEGER NOT NULL DEFAULT 0,
    ADD COLUMN IF NOT EXISTS last_replay_at TIMESTAMPTZ,
    ADD COLUMN IF NOT EXISTS next_replay_at TIMESTAMPTZ,
    ADD COLUMN IF NOT EXISTS last_replay_error TEXT;

DO $$
BEGIN
    IF NOT EXISTS
    (
        SELECT 1 FROM pg_constraint
        WHERE conname='raw_message_failures_resolution_status_ck'
          AND conrelid='telemetry.raw_message_failures'::regclass
    ) THEN
        ALTER TABLE telemetry.raw_message_failures
        ADD CONSTRAINT raw_message_failures_resolution_status_ck
        CHECK (resolution_status IN ('OPEN','RETRY_PENDING','RECOVERED','PERMANENT_FAILURE'));
    END IF;
END;
$$;

CREATE INDEX IF NOT EXISTS raw_message_failures_recovery_due_idx
ON telemetry.raw_message_failures(next_replay_at,raw_received_at)
WHERE resolution_status IN ('OPEN','RETRY_PENDING');

CREATE OR REPLACE PROCEDURE telemetry.capture_raw_message_failures_incremental
(
    p_overlap INTERVAL DEFAULT INTERVAL '15 minutes',
    p_grace INTERVAL DEFAULT INTERVAL '20 minutes'
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_pipeline_name CONSTANT TEXT := 'raw_message_failures';
    v_previous_checkpoint TIMESTAMPTZ;
    v_normalized_checkpoint TIMESTAMPTZ;
    v_window_start TIMESTAMPTZ;
    v_window_end TIMESTAMPTZ;
    v_rows BIGINT := 0;
    v_lock_acquired BOOLEAN;
BEGIN
    SELECT pg_try_advisory_xact_lock(hashtextextended('telemetry.capture_raw_message_failures_incremental',0))
      INTO v_lock_acquired;
    IF NOT v_lock_acquired THEN RETURN; END IF;

    SELECT last_received_at INTO v_previous_checkpoint
    FROM telemetry.pipeline_state WHERE pipeline_name=v_pipeline_name FOR UPDATE;
    SELECT last_received_at INTO v_normalized_checkpoint
    FROM telemetry.pipeline_state WHERE pipeline_name='normalized_points';

    UPDATE telemetry.pipeline_state
    SET last_started_at=clock_timestamp(),last_status='RUNNING',last_error=NULL,updated_at=now()
    WHERE pipeline_name=v_pipeline_name;

    IF v_normalized_checkpoint IS NULL THEN RETURN; END IF;
    v_window_end:=LEAST(v_normalized_checkpoint,clock_timestamp()-p_grace);
    v_window_start:=CASE WHEN v_previous_checkpoint IS NULL
        THEN GREATEST(clock_timestamp()-INTERVAL '48 hours',
             COALESCE((SELECT min(received_at)-INTERVAL '1 microsecond' FROM telemetry.raw_messages),v_window_end))
        ELSE v_previous_checkpoint-p_overlap END;

    WITH raw_candidates AS MATERIALIZED
    (
        SELECT r.*
        FROM telemetry.raw_messages r
        WHERE r.received_at>v_window_start AND r.received_at<=v_window_end
    ),
    selected_messages AS MATERIALIZED
    (
        SELECT DISTINCT raw_received_at,raw_message_id
        FROM telemetry.capture_bucket_samples
        WHERE raw_received_at>v_window_start AND raw_received_at<=v_window_end
    ),
    metrics AS
    (
        SELECT
            r.received_at,r.id,r.source_timestamp,r.source_protocol,r.source_topic,
            r.source_identifier,r.source_message_id,r.qos,r.payload,
            CASE WHEN jsonb_typeof(r.payload->'rtdata')='array'
                 THEN jsonb_array_length(r.payload->'rtdata') ELSE 0 END AS raw_element_count,
            COALESCE(sel.expected_points,0)::INTEGER AS enabled_point_count,
            COALESCE(sel.persisted_points,0)::INTEGER AS produced_point_count,
            COALESCE(sel.selected_devices,0)::INTEGER AS selected_device_count,
            COALESCE(res.unresolved_count,0)::INTEGER AS unresolved_count,
            COALESCE(res.unprofiled_count,0)::INTEGER AS unprofiled_count,
            row_number() OVER
            (
                PARTITION BY coalesce(nullif(r.source_identifier,''),nullif(r.source_topic,''),'__UNKNOWN_SOURCE__')
                ORDER BY r.received_at DESC,r.id DESC
            ) AS diagnostic_rank
        FROM raw_candidates r
        LEFT JOIN selected_messages sm ON sm.raw_received_at=r.received_at AND sm.raw_message_id=r.id
        LEFT JOIN LATERAL
        (
            SELECT
                count(*)::INTEGER AS selected_devices,
                COALESCE(sum(ep.enabled_points),0)::INTEGER AS expected_points,
                COALESCE(sum(ep.persisted_points),0)::INTEGER AS persisted_points
            FROM telemetry.capture_bucket_samples s
            LEFT JOIN LATERAL
            (
                SELECT count(*)::INTEGER AS enabled_points,
                       count(*) FILTER (WHERE EXISTS
                       (
                           SELECT 1 FROM telemetry.normalized_points np
                           WHERE np.device_id=s.device_id
                             AND np.event_time=s.event_time
                             AND np.logical_point_id=dpc.logical_point_id
                       ))::INTEGER AS persisted_points
                FROM config.device_point_configuration dpc
                WHERE dpc.device_id=s.device_id AND dpc.is_enabled
            ) ep ON TRUE
            WHERE s.raw_received_at=r.received_at AND s.raw_message_id=r.id
        ) sel ON sm.raw_message_id IS NOT NULL
        LEFT JOIN LATERAL
        (
            SELECT
                count(*) FILTER (WHERE d.id IS NULL)::INTEGER AS unresolved_count,
                count(*) FILTER (WHERE d.id IS NOT NULL AND d.profile_id IS NULL)::INTEGER AS unprofiled_count
            FROM jsonb_array_elements(CASE WHEN jsonb_typeof(r.payload->'rtdata')='array'
                     THEN r.payload->'rtdata' ELSE '[]'::jsonb END) e(value)
            LEFT JOIN LATERAL
            (
                SELECT di.device_id FROM metadata.device_identifiers di
                WHERE di.identifier_type='MQTT_UID'
                  AND lower(di.identifier_value)=lower(e.value->>'uid')
                ORDER BY di.device_id LIMIT 1
            ) di ON TRUE
            LEFT JOIN metadata.devices d ON d.id=di.device_id
        ) res ON TRUE
    ),
    classified AS
    (
        SELECT m.*,
        CASE
            WHEN m.payload->>'_capture_status'='INVALID_JSON' THEN 'INVALID_JSON'
            WHEN jsonb_typeof(m.payload->'rtdata') IS DISTINCT FROM 'array' THEN 'MISSING_RTDATA_ARRAY'
            WHEN jsonb_array_length(m.payload->'rtdata')=0 THEN 'EMPTY_RTDATA_ARRAY'
            WHEN m.unresolved_count>0 AND m.diagnostic_rank=1 THEN 'UNRESOLVED_DEVICE_ELEMENTS'
            WHEN m.unprofiled_count>0 AND m.diagnostic_rank=1 THEN 'DEVICE_WITHOUT_PROFILE'
            WHEN m.selected_device_count>0 AND m.enabled_point_count=0 THEN 'NO_ENABLED_POINTS'
            WHEN m.selected_device_count>0 AND m.enabled_point_count>0 AND m.produced_point_count=0 THEN 'NO_PERSISTED_NORMALIZED_ROWS'
            WHEN m.selected_device_count>0 AND m.produced_point_count<m.enabled_point_count THEN 'PARTIAL_NORMALIZATION'
            ELSE NULL
        END AS failure_code
        FROM metrics m
    )
    INSERT INTO telemetry.raw_message_failures
    (
        raw_received_at,raw_message_id,failure_code,failure_detail,source_timestamp,
        source_protocol,source_topic,source_identifier,source_message_id,qos,payload,
        raw_element_count,resolved_element_count,unresolved_element_count,
        profiled_element_count,unprofiled_element_count,enabled_point_count,
        produced_point_count,diagnostic_details,resolution_status,next_replay_at
    )
    SELECT
        c.received_at,c.id,c.failure_code,
        'Failure evaluated against site-frequency selected normalization samples.',
        c.source_timestamp,c.source_protocol,c.source_topic,c.source_identifier,
        c.source_message_id,c.qos,c.payload,c.raw_element_count,
        GREATEST(c.raw_element_count-c.unresolved_count,0),c.unresolved_count,
        GREATEST(c.raw_element_count-c.unresolved_count-c.unprofiled_count,0),c.unprofiled_count,
        c.enabled_point_count,c.produced_point_count,
        jsonb_build_object(
            'normalization_expectation','SELECTED_CAPTURE_SAMPLE_ONLY',
            'selected_device_count',c.selected_device_count,
            'enabled_point_count',c.enabled_point_count,
            'produced_point_count',c.produced_point_count,
            'point_shortfall',GREATEST(c.enabled_point_count-c.produced_point_count,0)),
        'OPEN',clock_timestamp()+INTERVAL '1 hour'
    FROM classified c
    WHERE c.failure_code IS NOT NULL
    ON CONFLICT (raw_received_at,raw_message_id) DO UPDATE
    SET detected_at=clock_timestamp(),failure_code=EXCLUDED.failure_code,
        failure_detail=EXCLUDED.failure_detail,diagnostic_details=EXCLUDED.diagnostic_details,
        enabled_point_count=EXCLUDED.enabled_point_count,
        produced_point_count=EXCLUDED.produced_point_count,
        next_replay_at=CASE
            WHEN telemetry.raw_message_failures.resolution_status='RECOVERED'
            THEN telemetry.raw_message_failures.next_replay_at
            ELSE COALESCE(telemetry.raw_message_failures.next_replay_at,clock_timestamp()+INTERVAL '1 hour') END;

    GET DIAGNOSTICS v_rows=ROW_COUNT;
    UPDATE telemetry.pipeline_state
    SET last_received_at=v_window_end,last_completed_at=clock_timestamp(),
        last_inserted_rows=v_rows,last_status='SUCCESS',last_error=NULL,updated_at=now()
    WHERE pipeline_name=v_pipeline_name;
EXCEPTION WHEN OTHERS THEN
    UPDATE telemetry.pipeline_state
    SET last_completed_at=clock_timestamp(),last_inserted_rows=0,
        last_status='FAILED',last_error=SQLSTATE||': '||SQLERRM,updated_at=now()
    WHERE pipeline_name=v_pipeline_name;
    RAISE;
END;
$$;

-- ---------------------------------------------------------------------------
-- 6. Hourly bounded auto-replay/recovery. Replay is attempted while the source
--    raw row remains inside the 48-hour raw retention window. The failure row
--    remains for audit and is marked RECOVERED instead of being deleted.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE telemetry.recover_failed_raw_messages
(
    p_limit INTEGER DEFAULT 100
)
LANGUAGE plpgsql
AS $$
DECLARE
    f RECORD;
    v_exists BOOLEAN;
    v_has_capture BOOLEAN;
    v_has_normalized BOOLEAN;
BEGIN
    IF p_limit IS NULL OR p_limit<1 OR p_limit>1000 THEN
        RAISE EXCEPTION 'p_limit must be between 1 and 1000';
    END IF;

    FOR f IN
        SELECT *
        FROM telemetry.raw_message_failures
        WHERE resolution_status IN ('OPEN','RETRY_PENDING')
          AND coalesce(next_replay_at,'-infinity'::timestamptz)<=clock_timestamp()
          AND replay_attempt_count<5
        ORDER BY raw_received_at
        LIMIT p_limit
        FOR UPDATE SKIP LOCKED
    LOOP
        UPDATE telemetry.raw_message_failures
        SET replay_attempt_count=replay_attempt_count+1,last_replay_at=clock_timestamp(),
            resolution_status='RETRY_PENDING',last_replay_error=NULL
        WHERE raw_received_at=f.raw_received_at AND raw_message_id=f.raw_message_id;

        SELECT EXISTS
        (
            SELECT 1 FROM telemetry.raw_messages r
            WHERE r.received_at=f.raw_received_at AND r.id=f.raw_message_id
        ) INTO v_exists;

        IF NOT v_exists THEN
            UPDATE telemetry.raw_message_failures
            SET resolution_status=CASE WHEN replay_attempt_count>=5 THEN 'PERMANENT_FAILURE' ELSE 'RETRY_PENDING' END,
                next_replay_at=clock_timestamp()+INTERVAL '6 hours',
                last_replay_error='Original raw row is outside the 48-hour raw retention window; payload remains quarantined for manual forensic recovery.'
            WHERE raw_received_at=f.raw_received_at AND raw_message_id=f.raw_message_id;
            CONTINUE;
        END IF;

        -- Re-evaluate the exact raw packet. If its device sample is now already
        -- represented by a finalized capture bucket, recovery is complete by
        -- canonical supersession. Otherwise insert a selected capture row only
        -- when this packet is the latest eligible sample in its bucket.
        WITH current_elements AS MATERIALIZED
        (
            SELECT
                r.received_at,r.raw_message_id,COALESCE(r.source_timestamp,r.received_at) AS event_time,
                r.source_timestamp,d.id AS device_id,g.site_id,
                b.policy_id,b.capture_interval_seconds,b.late_arrival_tolerance_seconds,b.bucket_start,
                b.bucket_start+make_interval(secs=>b.capture_interval_seconds+b.late_arrival_tolerance_seconds) AS deadline
            FROM telemetry.v_rtdata r
            JOIN metadata.device_identifiers di
              ON di.identifier_type='MQTT_UID' AND lower(di.identifier_value)=lower(r.device_uid)
            JOIN metadata.devices d ON d.id=di.device_id
            JOIN metadata.gateways g ON g.id=d.gateway_id
            CROSS JOIN LATERAL telemetry.resolve_site_capture_bucket(g.site_id,COALESCE(r.source_timestamp,r.received_at)) b
            WHERE r.received_at=f.raw_received_at AND r.raw_message_id=f.raw_message_id
              AND d.profile_id IS NOT NULL AND b.policy_id IS NOT NULL
        )
        INSERT INTO telemetry.capture_bucket_samples
        (
            site_id,device_id,policy_id,bucket_start,capture_interval_seconds,
            late_arrival_tolerance_seconds,source_timestamp,event_time,
            raw_received_at,raw_message_id,status,last_error
        )
        SELECT ce.site_id,ce.device_id,ce.policy_id,ce.bucket_start,ce.capture_interval_seconds,
               ce.late_arrival_tolerance_seconds,ce.source_timestamp,ce.event_time,
               ce.received_at,ce.raw_message_id,'SELECTED',NULL
        FROM current_elements ce
        WHERE ce.deadline<=clock_timestamp()
          AND ce.received_at<=ce.deadline
          AND NOT EXISTS
          (
              SELECT 1
              FROM telemetry.v_rtdata r2
              JOIN metadata.device_identifiers di2
                ON di2.identifier_type='MQTT_UID'
               AND lower(di2.identifier_value)=lower(r2.device_uid)
              JOIN metadata.devices d2 ON d2.id=di2.device_id
              JOIN metadata.gateways g2 ON g2.id=d2.gateway_id
              CROSS JOIN LATERAL telemetry.resolve_site_capture_bucket
              (
                  g2.site_id,COALESCE(r2.source_timestamp,r2.received_at)
              ) b2
              WHERE d2.id=ce.device_id
                AND g2.site_id=ce.site_id
                AND b2.bucket_start=ce.bucket_start
                AND r2.received_at<=ce.deadline
                AND ROW
                    (COALESCE(r2.source_timestamp,r2.received_at),r2.received_at,r2.raw_message_id)
                    > ROW(ce.event_time,ce.received_at,ce.raw_message_id)
          )
        ON CONFLICT (site_id,bucket_start,device_id) DO NOTHING;

        -- Materialize any replay-selected samples from this raw packet.
        INSERT INTO telemetry.normalized_points
        (
            event_time,organization_id,site_id,gateway_id,device_id,
            logical_point_id,device_uid,logical_point,raw_field_name,
            raw_value,numeric_value,quality_code,mapping_source,
            platform_received_at,raw_message_id
        )
        SELECT np.event_time,np.organization_id,np.site_id,np.gateway_id,np.device_id,
               np.logical_point_id,np.device_uid,np.logical_point,np.raw_field_name,
               np.raw_value,np.numeric_value,np.quality_code,np.mapping_source,
               np.received_at,np.raw_message_id
        FROM telemetry.capture_bucket_samples s
        CROSS JOIN LATERAL
        (
            SELECT source_np.* FROM telemetry.v_normalized_points source_np
            WHERE source_np.raw_message_id=s.raw_message_id
              AND source_np.device_id=s.device_id
              AND source_np.event_time=s.event_time
            OFFSET 0
        ) np
        WHERE s.raw_received_at=f.raw_received_at
          AND s.raw_message_id=f.raw_message_id
          AND s.status IN ('SELECTED','FAILED')
        ON CONFLICT (event_time,device_id,logical_point_id) DO UPDATE
        SET platform_received_at=EXCLUDED.platform_received_at,raw_message_id=EXCLUDED.raw_message_id
        WHERE EXCLUDED.platform_received_at>telemetry.normalized_points.platform_received_at;

        UPDATE telemetry.capture_bucket_samples s
        SET status='RECOVERED',normalized_at=coalesce(s.normalized_at,clock_timestamp()),last_error=NULL
        WHERE s.raw_received_at=f.raw_received_at AND s.raw_message_id=f.raw_message_id
          AND EXISTS
          (
              SELECT 1 FROM telemetry.normalized_points np
              WHERE np.device_id=s.device_id AND np.event_time=s.event_time
          );

        SELECT EXISTS
        (
            SELECT 1 FROM telemetry.capture_bucket_samples s
            WHERE s.raw_received_at=f.raw_received_at AND s.raw_message_id=f.raw_message_id
        ) INTO v_has_capture;

        SELECT EXISTS
        (
            SELECT 1
            FROM telemetry.v_rtdata fr
            JOIN metadata.device_identifiers fdi
              ON fdi.identifier_type='MQTT_UID'
             AND lower(fdi.identifier_value)=lower(fr.device_uid)
            JOIN metadata.devices fd ON fd.id=fdi.device_id
            JOIN metadata.gateways fg ON fg.id=fd.gateway_id
            CROSS JOIN LATERAL telemetry.resolve_site_capture_bucket
            (
                fg.site_id,COALESCE(fr.source_timestamp,fr.received_at)
            ) fb
            JOIN telemetry.capture_bucket_samples s
              ON s.site_id=fg.site_id
             AND s.device_id=fd.id
             AND s.bucket_start=fb.bucket_start
            JOIN telemetry.normalized_points np
              ON np.device_id=s.device_id AND np.event_time=s.event_time
            WHERE fr.received_at=f.raw_received_at
              AND fr.raw_message_id=f.raw_message_id
        ) INTO v_has_normalized;

        IF v_has_normalized THEN
            UPDATE telemetry.raw_message_failures
            SET resolution_status='RECOVERED',resolved_at=clock_timestamp(),
                resolution_method='AUTO_REPLAY_OR_CANONICAL_SUPERSESSION',next_replay_at=NULL,last_replay_error=NULL
            WHERE raw_received_at=f.raw_received_at AND raw_message_id=f.raw_message_id;
        ELSE
            UPDATE telemetry.raw_message_failures
            SET resolution_status=CASE WHEN replay_attempt_count>=5 THEN 'PERMANENT_FAILURE' ELSE 'RETRY_PENDING' END,
                next_replay_at=clock_timestamp()+CASE
                    WHEN replay_attempt_count<=1 THEN INTERVAL '1 hour'
                    WHEN replay_attempt_count=2 THEN INTERVAL '2 hours'
                    WHEN replay_attempt_count=3 THEN INTERVAL '6 hours'
                    ELSE INTERVAL '12 hours' END,
                last_replay_error=CASE WHEN v_has_capture
                    THEN 'Capture sample remains incomplete after replay.'
                    ELSE 'Message is not currently eligible for a finalized capture bucket.' END
            WHERE raw_received_at=f.raw_received_at AND raw_message_id=f.raw_message_id;
        END IF;
    END LOOP;
END;
$$;

CREATE OR REPLACE PROCEDURE telemetry.run_failed_message_recovery_job(job_id INTEGER,config JSONB)
LANGUAGE plpgsql
AS $$
DECLARE
    v_limit INTEGER := 100;
BEGIN
    IF config IS NOT NULL AND config ? 'limit'
       AND NULLIF(btrim(config->>'limit'),'') IS NOT NULL THEN
        v_limit := (config->>'limit')::INTEGER;
    END IF;
    CALL telemetry.recover_failed_raw_messages(v_limit);
END;
$$;

-- ---------------------------------------------------------------------------
-- 7. Timescale lifecycle and schedules.
-- ---------------------------------------------------------------------------
SELECT remove_retention_policy('telemetry.raw_messages',if_exists=>TRUE);
SELECT add_retention_policy('telemetry.raw_messages',INTERVAL '48 hours');

-- Failure quarantine remains 30 days; restate idempotently.
SELECT remove_retention_policy('telemetry.raw_message_failures',if_exists=>TRUE);
SELECT add_retention_policy('telemetry.raw_message_failures',INTERVAL '30 days');

DO $$
DECLARE
    r RECORD;
    v_job_id INTEGER;
BEGIN
    FOR r IN
        SELECT job_id FROM timescaledb_information.jobs
        WHERE proc_schema='telemetry' AND proc_name='run_normalization_job'
    LOOP
        PERFORM alter_job(r.job_id,
            schedule_interval=>INTERVAL '5 minutes',
            max_runtime=>INTERVAL '5 minutes',
            max_retries=>3,
            retry_period=>INTERVAL '1 minute',
            scheduled=>TRUE,
            config=>jsonb_build_object('overlap','20 minutes'));
    END LOOP;

    SELECT job_id INTO v_job_id
    FROM timescaledb_information.jobs
    WHERE proc_schema='telemetry' AND proc_name='run_raw_receipt_state_job'
    ORDER BY job_id LIMIT 1;
    IF v_job_id IS NULL THEN
        SELECT add_job('telemetry.run_raw_receipt_state_job',INTERVAL '1 minute',
                       config=>jsonb_build_object('overlap','2 minutes')) INTO v_job_id;
    END IF;
    PERFORM alter_job(v_job_id,schedule_interval=>INTERVAL '1 minute',
                      max_runtime=>INTERVAL '1 minute',max_retries=>3,
                      retry_period=>INTERVAL '1 minute',scheduled=>TRUE,
                      config=>jsonb_build_object('overlap','2 minutes'));

    SELECT job_id INTO v_job_id
    FROM timescaledb_information.jobs
    WHERE proc_schema='telemetry' AND proc_name='run_failed_message_recovery_job'
    ORDER BY job_id LIMIT 1;
    IF v_job_id IS NULL THEN
        SELECT add_job('telemetry.run_failed_message_recovery_job',INTERVAL '1 hour',
                       config=>jsonb_build_object('limit',100)) INTO v_job_id;
    END IF;
    PERFORM alter_job(v_job_id,schedule_interval=>INTERVAL '1 hour',
                      max_runtime=>INTERVAL '10 minutes',max_retries=>1,
                      retry_period=>INTERVAL '15 minutes',scheduled=>TRUE,
                      config=>jsonb_build_object('limit',100));
END;
$$;

ALTER TABLE telemetry.capture_bucket_samples OWNER TO ems_admin;
ALTER TABLE telemetry.device_raw_receipt_state OWNER TO ems_admin;
REVOKE ALL ON telemetry.capture_bucket_samples,telemetry.device_raw_receipt_state FROM PUBLIC;
GRANT SELECT ON telemetry.capture_bucket_samples,telemetry.device_raw_receipt_state TO ems_readonly,grafana_reader;
GRANT SELECT,INSERT,UPDATE,DELETE ON telemetry.capture_bucket_samples,telemetry.device_raw_receipt_state TO ems_admin;

COMMENT ON PROCEDURE telemetry.recover_failed_raw_messages(INTEGER) IS
'Hourly bounded recovery/replay for quarantined failures. Original failure rows remain auditable; recovered rows are marked RECOVERED instead of deleted.';
