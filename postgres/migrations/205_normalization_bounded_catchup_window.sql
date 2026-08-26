-- ============================================================================
-- Migration 205
-- Add an optional p_max_window parameter to telemetry.load_normalized_points_
-- incremental(), letting a caller cap how far forward one invocation
-- advances, without changing any other behavior.
--
-- Root cause (2026-08-26, investigated as a separate incident from the
-- recovery/migration-204 work -- unrelated to it: telemetry.raw_messages
-- has continued receiving data without interruption throughout, and job
-- 1000's own failure history and last successful run both predate migration
-- 204's deployment by hours to days): telemetry.run_normalization_job (job
-- 1000) stopped succeeding after 2026-08-26 08:21:06 and was subsequently
-- disabled (scheduled=false). telemetry.load_normalized_points_incremental()
-- always computes its forward processing boundary as
-- `SELECT max(received_at) FROM telemetry.raw_messages` -- i.e. "catch up
-- to right now" -- with no parameter to bound it, and runs as one
-- transaction with no intermediate commit (its EXCEPTION handler records a
-- diagnostic into telemetry.pipeline_state but then RAISEs the original
-- error, so even a caught failure rolls back everything, including the
-- pipeline_state watermark). Once the gap between the last checkpoint and
-- "now" grew wide enough that one pass could no longer finish inside the
-- job's 5-minute max_runtime, every subsequent attempt was structurally
-- guaranteed to fail too: each retry faces an equal-or-wider window than
-- the last, with zero durable progress possible from any single attempt.
--
-- Fix: telemetry.load_normalized_points_incremental() gains one new,
-- optional parameter, p_max_window INTERVAL DEFAULT NULL. When it is NULL
-- (the default -- every existing call site, including the unmodified
-- telemetry.run_normalization_job wrapper, is unaffected), the forward
-- boundary is computed exactly as before: `max(received_at) FROM
-- telemetry.raw_messages`. When a caller supplies p_max_window AND a
-- previous checkpoint already exists, the forward boundary is additionally
-- capped to `v_previous_checkpoint + p_max_window`, via a single LEAST(...)
-- applied after the existing computation -- letting an operator manually
-- catch up a large, stuck gap in a sequence of bounded, individually
-- transactional calls (each either fully completes its capped window and
-- durably advances the watermark, or rolls back completely, exactly as
-- today) instead of attempting the entire backlog as one unbounded,
-- multi-hour transaction.
--
-- This migration does not add any intermediate COMMIT to the procedure, does
-- not change the advisory-lock behavior, does not change the existing
-- p_overlap/late-arrival-horizon semantics, does not change any downstream
-- schema, consumer, Grafana query, or analytics API, and does not touch
-- telemetry.run_normalization_job, job 1000's schedule/config, or any other
-- job. Every statement in the procedure body besides the forward-boundary
-- computation is byte-for-byte identical to the deployed migration 010
-- definition.
-- ============================================================================

BEGIN;

-- CREATE OR REPLACE does not replace a procedure of a different arity -- it
-- would instead create a second, overloaded signature alongside the existing
-- one-argument procedure, making every existing single-argument call
-- (including telemetry.run_normalization_job's) ambiguous and erroring at
-- call time. The prior one-argument signature must be dropped explicitly
-- before the two-argument replacement is created.
DROP PROCEDURE IF EXISTS telemetry.load_normalized_points_incremental(INTERVAL);

CREATE OR REPLACE PROCEDURE telemetry.load_normalized_points_incremental
(
    p_overlap INTERVAL DEFAULT INTERVAL '5 minutes',
    p_max_window INTERVAL DEFAULT NULL
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

    IF p_max_window IS NOT NULL AND p_max_window <= INTERVAL '0 seconds' THEN
        RAISE EXCEPTION 'p_max_window must be positive when supplied; received %',p_max_window;
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

    -- Migration 205: cap the forward processing boundary to the checkpoint
    -- plus p_max_window when a caller supplies one and a previous checkpoint
    -- already exists. NULL (the default, and what every existing caller
    -- including telemetry.run_normalization_job passes) leaves v_window_end
    -- exactly as computed above -- unchanged from migration 010.
    IF p_max_window IS NOT NULL AND v_previous_checkpoint IS NOT NULL THEN
        v_window_end := LEAST(v_window_end, v_previous_checkpoint + p_max_window);
    END IF;

    -- Bound the replay/look-back horizon to policies that can still affect
    -- the current checkpoint. Historical policy rows remain authoritative for
    -- their event-time ranges, but once a policy's effective window plus its
    -- own capture/late-arrival horizon is fully behind the checkpoint, it must
    -- no longer inflate every future normalization scan.
    SELECT make_interval(secs => GREATEST(
               COALESCE(max(capture_interval_seconds+late_arrival_tolerance_seconds),0),
               extract(epoch FROM p_overlap)::INTEGER
           ))
      INTO v_dynamic_overlap
    FROM config.telemetry_capture_policies p
    WHERE p.is_enabled
      AND p.effective_from <= v_window_end
      AND (
            v_previous_checkpoint IS NULL
            OR p.effective_to IS NULL
            OR p.effective_to
               + make_interval(
                   secs => p.capture_interval_seconds
                         + p.late_arrival_tolerance_seconds
                 ) >= v_previous_checkpoint
          );

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
    WITH selected_elements AS MATERIALIZED
    (
        SELECT
            rm.received_at,
            rm.id AS raw_message_id,
            COALESCE(x.source_timestamp,rm.received_at) AS event_time,
            x.source_timestamp,
            rm.source_topic AS mqtt_topic,
            e.value ->> 'uid' AS device_uid,
            e.value ->> 'did' AS device_identifier,
            e.value AS payload,
            d.id AS device_id,
            d.organization_id,
            d.gateway_id,
            g.site_id,
            d.profile_id
        FROM tmp_selected_samples s
        JOIN telemetry.raw_messages rm
          ON rm.id=s.raw_message_id
        JOIN metadata.devices d
          ON d.id=s.device_id
        LEFT JOIN metadata.gateways g
          ON g.id=d.gateway_id
        JOIN metadata.device_identifiers di
          ON di.device_id=d.id
         AND di.identifier_type='MQTT_UID'
        CROSS JOIN LATERAL jsonb_array_elements(rm.payload -> 'rtdata') AS e(value)
        CROSS JOIN LATERAL
        (
            SELECT CASE
                WHEN e.value ->> 'ts' IS NULL THEN NULL::TIMESTAMPTZ
                WHEN pg_input_is_valid(e.value ->> 'ts','double precision')
                    THEN to_timestamp((e.value ->> 'ts')::DOUBLE PRECISION)
                ELSE NULL::TIMESTAMPTZ
            END AS source_timestamp
        ) x
        WHERE jsonb_typeof(rm.payload -> 'rtdata')='array'
          AND lower(e.value ->> 'uid')=lower(di.identifier_value)
          AND COALESCE(x.source_timestamp,rm.received_at)=s.event_time
    ),
    profile_mappings AS MATERIALIZED
    (
        SELECT
            se.*,
            pfm.logical_point_id,
            lp.name AS logical_point,
            lp.data_type,
            pfm.raw_field_name,
            pfm.json_path,
            pfm.transform_expression,
            1 AS mapping_priority,
            'DEVICE_PROFILE'::TEXT AS mapping_source
        FROM selected_elements se
        JOIN config.profile_field_mapping pfm
          ON pfm.profile_id=se.profile_id
        JOIN config.device_point_configuration dpc
          ON dpc.device_id=se.device_id
         AND dpc.logical_point_id=pfm.logical_point_id
         AND dpc.is_enabled
        JOIN metadata.logical_points lp
          ON lp.id=pfm.logical_point_id
        WHERE se.profile_id IS NOT NULL
    ),
    device_mappings AS MATERIALIZED
    (
        SELECT
            se.*,
            dfm.logical_point_id,
            lp.name AS logical_point,
            lp.data_type,
            dfm.raw_field_name,
            NULL::TEXT AS json_path,
            NULL::TEXT AS transform_expression,
            2 AS mapping_priority,
            'DEVICE_OVERRIDE'::TEXT AS mapping_source
        FROM selected_elements se
        JOIN metadata.device_field_mapping dfm
          ON dfm.device_id=se.device_id
        JOIN config.device_point_configuration dpc
          ON dpc.device_id=se.device_id
         AND dpc.logical_point_id=dfm.logical_point_id
         AND dpc.is_enabled
        JOIN metadata.logical_points lp
          ON lp.id=dfm.logical_point_id
    ),
    candidate_mappings AS MATERIALIZED
    (
        SELECT * FROM profile_mappings
        UNION ALL
        SELECT * FROM device_mappings
    ),
    preferred_mappings AS MATERIALIZED
    (
        SELECT DISTINCT ON (raw_message_id,device_id,event_time,logical_point_id)
            *
        FROM candidate_mappings
        ORDER BY raw_message_id,device_id,event_time,logical_point_id,mapping_priority
    ),
    extracted_values AS MATERIALIZED
    (
        SELECT
            pm.*,
            CASE
                WHEN pm.json_path IS NULL
                    THEN pm.payload ->> pm.raw_field_name
                ELSE jsonb_path_query_first(pm.payload,pm.json_path::jsonpath) #>> '{}'
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
            WHEN raw_value IS NULL THEN NULL::NUMERIC
            WHEN raw_value ~ '^[[:space:]]*[+-]?(([0-9]+([.][0-9]*)?)|([.][0-9]+))([eE][+-]?[0-9]+)?[[:space:]]*$'
                THEN btrim(raw_value)::NUMERIC
            ELSE NULL::NUMERIC
        END AS numeric_value,
        CASE
            WHEN raw_value IS NULL THEN 'MISSING'::TEXT
            WHEN data_type='numeric'
             AND raw_value !~ '^[[:space:]]*[+-]?(([0-9]+([.][0-9]*)?)|([.][0-9]+))([eE][+-]?[0-9]+)?[[:space:]]*$'
                THEN 'INVALID_NUMERIC'::TEXT
            ELSE 'GOOD'::TEXT
        END AS quality_code,
        mapping_source,
        payload,
        raw_message_id
    FROM extracted_values;

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

COMMENT ON PROCEDURE telemetry.load_normalized_points_incremental(INTERVAL, INTERVAL) IS
'Processes closed site capture buckets in one shared batch. Selected raw device samples are expanded directly through enabled mappings; raw replay look-back ignores capture policies whose effective window plus capture/late-arrival horizon is fully behind the current checkpoint. '
'Migration 205: p_max_window (default NULL) optionally caps the forward processing boundary to the previous checkpoint plus p_max_window, instead of always advancing all the way to max(telemetry.raw_messages.received_at). NULL preserves the exact prior behavior -- telemetry.run_normalization_job''s normal invocation is unaffected. Intended for manually catching up a stuck gap (e.g. after a period of repeated failures) in a sequence of small, individually-transactional calls: each bounded call either completes its capped window and durably advances the watermark, or rolls back completely, exactly like every existing call. No intermediate COMMIT is introduced; this is a bound on scope, not a change to transaction boundaries.';

COMMIT;
