-- 008_set_based_capture_selection_legacy_recovery.sql
-- Forward fix for 007: replace correlated per-element capture-policy resolution
-- with a set-based policy/bucket plan; close pre-007 failure history so it is
-- never treated as an automatic replay queue.

CREATE OR REPLACE PROCEDURE telemetry.load_normalized_points_incremental
(
    p_overlap INTERVAL DEFAULT INTERVAL '5 minutes'
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
    WITH raw_resolved AS MATERIALIZED
    (
        SELECT
            r.received_at,
            r.raw_message_id,
            COALESCE(r.source_timestamp,r.received_at) AS event_time,
            r.source_timestamp,
            r.device_uid,
            d.id AS device_id,
            g.site_id,
            COALESCE(s.timezone,'UTC') AS site_timezone
        FROM telemetry.v_rtdata r
        JOIN metadata.device_identifiers di
          ON di.identifier_type='MQTT_UID'
         AND lower(di.identifier_value)=lower(r.device_uid)
        JOIN metadata.devices d ON d.id=di.device_id
        JOIN metadata.gateways g ON g.id=d.gateway_id
        JOIN metadata.sites s ON s.id=g.site_id
        WHERE r.received_at > v_window_start
          AND r.received_at <= v_window_end
          AND d.profile_id IS NOT NULL
    ),
    policy_ranked AS MATERIALIZED
    (
        SELECT
            rr.*,
            p.id AS policy_id,
            p.capture_interval_seconds,
            p.late_arrival_tolerance_seconds,
            p.effective_from,
            row_number() OVER
            (
                PARTITION BY rr.raw_message_id,rr.device_id
                ORDER BY
                    (p.site_id IS NOT NULL) DESC,
                    p.effective_from DESC,
                    p.id DESC
            ) AS policy_rank
        FROM raw_resolved rr
        JOIN config.telemetry_capture_policies p
          ON p.is_enabled
         AND (p.site_id=rr.site_id OR p.site_id IS NULL)
         AND rr.event_time >= p.effective_from
         AND (p.effective_to IS NULL OR rr.event_time < p.effective_to)
    ),
    policy_resolved AS MATERIALIZED
    (
        SELECT
            pr.*,
            pr.event_time AT TIME ZONE pr.site_timezone AS local_event_time
        FROM policy_ranked pr
        WHERE pr.policy_rank=1
    ),
    bucketed AS MATERIALIZED
    (
        SELECT
            pr.*,
            date_trunc('day',pr.local_event_time)
            + make_interval
              (
                  secs =>
                      floor
                      (
                          extract
                          (
                              epoch FROM
                              (pr.local_event_time-date_trunc('day',pr.local_event_time))
                          )
                          / pr.capture_interval_seconds
                      )::INTEGER
                      * pr.capture_interval_seconds
              ) AS local_bucket_start
        FROM policy_resolved pr
    ),
    finalized AS MATERIALIZED
    (
        SELECT
            b.received_at,
            b.raw_message_id,
            b.event_time,
            b.source_timestamp,
            b.device_id,
            b.site_id,
            b.policy_id,
            b.capture_interval_seconds,
            b.late_arrival_tolerance_seconds,
            GREATEST
            (
                b.local_bucket_start AT TIME ZONE b.site_timezone,
                b.effective_from
            ) AS bucket_start
        FROM bucketed b
    ),
    eligible AS MATERIALIZED
    (
        SELECT
            f.*,
            f.bucket_start+make_interval(secs=>f.capture_interval_seconds) AS bucket_end,
            f.bucket_start+make_interval
            (
                secs=>f.capture_interval_seconds+f.late_arrival_tolerance_seconds
            ) AS finalization_deadline
        FROM finalized f
    )
    SELECT DISTINCT ON (site_id,bucket_start,device_id)
        site_id,device_id,policy_id,bucket_start,
        capture_interval_seconds,late_arrival_tolerance_seconds,
        source_timestamp,event_time,received_at AS raw_received_at,raw_message_id
    FROM eligible
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
-- Close historical pre-007 failure rows without calling them recovered or
-- permanent failures. They remain available under the existing 30-day
-- quarantine retention policy, but are excluded from automated replay.
-- ---------------------------------------------------------------------------
ALTER TABLE telemetry.raw_message_failures
    DROP CONSTRAINT IF EXISTS raw_message_failures_resolution_status_ck;

ALTER TABLE telemetry.raw_message_failures
    ADD CONSTRAINT raw_message_failures_resolution_status_ck
    CHECK (resolution_status IN
        ('OPEN','RETRY_PENDING','RECOVERED','PERMANENT_FAILURE','LEGACY_CLOSED'));

WITH cutover AS
(
    SELECT applied_at
    FROM admin.schema_migrations
    WHERE migration_id='007_site_frequency_normalization_recovery'
)
UPDATE telemetry.raw_message_failures f
SET resolution_status='LEGACY_CLOSED',
    resolved_at=COALESCE(f.resolved_at,clock_timestamp()),
    resolution_method=COALESCE(f.resolution_method,'LEGACY_PRE_007_HISTORY'),
    next_replay_at=NULL,
    last_replay_error=NULL
FROM cutover c
WHERE f.detected_at < c.applied_at
  AND f.resolution_status IN ('OPEN','RETRY_PENDING');

COMMENT ON PROCEDURE telemetry.load_normalized_points_incremental(INTERVAL) IS
'Processes closed site capture buckets in one shared batch using set-based policy resolution. For each site/bucket/device it selects the latest eligible source sample and expands only that selected sample into canonical logical points.';
