-- ============================================================================
-- Migration 202
-- Replace telemetry.recover_failed_raw_messages()'s use of the
-- general-purpose telemetry.v_normalized_points view with a narrowly-scoped,
-- early-filtered lookup for this one call site only.
--
-- Root cause (2026-08-26, live staging investigation): with migration 201's
-- supersession bound deployed and confirmed correct, telemetry.
-- recover_failed_raw_messages() STILL timed out at its 10-minute
-- max_runtime on every run, with zero backlog progress (identical
-- resolution_status counts before and after two consecutive real runs).
-- Live EXPLAIN (ANALYZE, BUFFERS) against real backlog candidates showed the
-- supersession check itself (migration 201) now costs only ~1.5-4.4s per
-- candidate. The dominant cost is the procedure's per-candidate lookup
-- against telemetry.v_normalized_points, observed live to run past 20+
-- minutes for a single candidate with IO/BufFileWrite and IPC/
-- MessageQueueSend wait events -- a disk-spilling, parallel-worker sort.
--
-- Mechanism: v_normalized_points' preferred_mappings CTE computes
-- SELECT DISTINCT ON (received_at, device_id, logical_point_id) ...
-- ORDER BY received_at, device_id, logical_point_id, mapping_priority
-- over the full candidate_mappings UNION ALL. The procedure's call site
-- filters on (raw_message_id, device_id, event_time) -- raw_message_id is
-- not part of the DISTINCT ON key, and event_time (COALESCE(source_
-- timestamp, received_at)) is a different expression than received_at, so
-- PostgreSQL cannot push either filter below the DISTINCT ON's implicit
-- sort. Every call must materialize and sort a much wider row set --
-- decompressed from telemetry.raw_messages' compressed chunks for backlog
-- candidates old enough to have been compressed -- before it can discard
-- everything except the one row actually needed.
--
-- Fix: telemetry.normalized_points_for_recovery_candidate(), a new,
-- narrowly-scoped SQL function used only by this one call site (the shared
-- telemetry.v_normalized_points view, and every other caller of it, are
-- unchanged). It reproduces the exact same pipeline -- resolved device ->
-- profile/device mappings -> DISTINCT ON dedup -> value extraction -- with
-- two provably safe changes:
--   (a) the raw-row lookup is filtered by (received_at, raw_message_id)
--       against telemetry.raw_messages directly, before the rtdata array is
--       even expanded, exactly matching the raw_messages primary key
--       (received_at, id) -- a single-chunk, single-row point lookup
--       instead of a chunk-wide compressed scan;
--   (b) the resolved-device join is additionally filtered to the one known
--       device_id.
-- Both are predicates on columns that (a) are not part of the DISTINCT ON
-- key, and (b) each raw_message_id/device_uid pairing already uniquely
-- determines both received_at (fixed by the raw_messages PK) and event_time
-- (COALESCE(source_timestamp, received_at), fixed per rtdata array element)
-- before any mapping/profile join runs -- so moving these filters earlier
-- only changes WHEN non-matching rows are discarded, never WHICH rows
-- survive to the DISTINCT ON, and the DISTINCT ON's tie-breaking order
-- (received_at, device_id, logical_point_id, mapping_priority -- profile
-- mapping beats device override on a tie) is reproduced verbatim. The
-- event_time filter is kept exactly where the original call site applied
-- it (after value extraction), unchanged, for maximal fidelity to the
-- existing structure.
--
-- Not changed by this migration: migration 201's supersession predicate,
-- migration 200's canonical-energy-read logic, p_limit, ORDER BY
-- raw_received_at, transaction/commit behavior, retry/backoff semantics,
-- failure classification, tenant/device identity resolution, advisory
-- locking, or the shared telemetry.v_normalized_points view (still used
-- unchanged by telemetry.load_normalized_points_incremental and any other
-- caller).
-- ============================================================================

BEGIN;

CREATE FUNCTION telemetry.normalized_points_for_recovery_candidate
(
    p_raw_received_at TIMESTAMPTZ,
    p_raw_message_id BIGINT,
    p_device_id UUID,
    p_event_time TIMESTAMPTZ
)
RETURNS TABLE
(
    received_at TIMESTAMPTZ,
    event_time TIMESTAMPTZ,
    source_timestamp TIMESTAMPTZ,
    organization_id UUID,
    site_id UUID,
    gateway_id UUID,
    device_id UUID,
    device_uid TEXT,
    device_identifier TEXT,
    mqtt_topic TEXT,
    logical_point_id UUID,
    logical_point TEXT,
    data_type TEXT,
    raw_field_name TEXT,
    raw_value TEXT,
    numeric_value NUMERIC,
    quality_code TEXT,
    mapping_source TEXT,
    payload JSONB,
    raw_message_id BIGINT
)
LANGUAGE sql
STABLE
AS $function$
WITH candidate_raw AS
(
    -- Exact telemetry.raw_messages primary key (received_at, id) lookup --
    -- prunes to a single chunk and row before any decompression, instead of
    -- v_normalized_points' unfiltered scan of every message in the chunk.
    SELECT
        m.received_at,
        m.id AS raw_message_id,
        m.source_topic AS mqtt_topic,
        m.payload
    FROM telemetry.raw_messages m
    WHERE m.received_at = p_raw_received_at
      AND m.id = p_raw_message_id
      AND jsonb_typeof(m.payload -> 'rtdata') = 'array'
),
candidate_elements AS
(
    -- Same array expansion and source_timestamp derivation as
    -- telemetry.v_rtdata, scoped to the one already-located raw message.
    SELECT
        cr.received_at,
        cr.raw_message_id,
        cr.mqtt_topic,
        r.value ->> 'uid' AS device_uid,
        r.value ->> 'did' AS device_identifier,
        CASE
            WHEN r.value ->> 'ts' IS NULL THEN NULL::TIMESTAMPTZ
            WHEN pg_input_is_valid(r.value ->> 'ts', 'double precision')
                THEN to_timestamp((r.value ->> 'ts')::DOUBLE PRECISION)
            ELSE NULL::TIMESTAMPTZ
        END AS source_timestamp,
        r.value AS payload
    FROM candidate_raw cr
    CROSS JOIN LATERAL jsonb_array_elements(cr.payload -> 'rtdata') AS r(value)
),
resolved_device AS
(
    -- Same identity resolution as v_normalized_points' resolved_devices,
    -- with the already-known device_id applied here rather than after the
    -- mapping joins and DISTINCT ON below.
    SELECT
        ce.received_at,
        ce.raw_message_id,
        COALESCE(ce.source_timestamp, ce.received_at) AS event_time,
        ce.source_timestamp,
        ce.mqtt_topic,
        ce.device_uid,
        ce.device_identifier,
        ce.payload,
        d.id AS device_id,
        d.organization_id,
        d.gateway_id,
        g.site_id,
        d.profile_id
    FROM candidate_elements ce
    JOIN metadata.device_identifiers di
      ON di.identifier_type = 'MQTT_UID'
     AND lower(di.identifier_value) = lower(ce.device_uid)
    JOIN metadata.devices d
      ON d.id = di.device_id
    LEFT JOIN metadata.gateways g
      ON g.id = d.gateway_id
    WHERE ce.device_uid IS NOT NULL
      AND d.id = p_device_id
),
profile_mappings AS
(
    SELECT
        rd.received_at, rd.raw_message_id, rd.event_time, rd.source_timestamp, rd.mqtt_topic,
        rd.organization_id, rd.site_id, rd.gateway_id, rd.device_id, rd.device_uid, rd.device_identifier, rd.payload,
        pfm.logical_point_id, lp.name AS logical_point, lp.data_type,
        pfm.raw_field_name, pfm.json_path, pfm.transform_expression,
        1 AS mapping_priority, 'DEVICE_PROFILE'::TEXT AS mapping_source
    FROM resolved_device rd
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
        rd.received_at, rd.raw_message_id, rd.event_time, rd.source_timestamp, rd.mqtt_topic,
        rd.organization_id, rd.site_id, rd.gateway_id, rd.device_id, rd.device_uid, rd.device_identifier, rd.payload,
        dfm.logical_point_id, lp.name AS logical_point, lp.data_type,
        dfm.raw_field_name, NULL::TEXT AS json_path, NULL::TEXT AS transform_expression,
        2 AS mapping_priority, 'DEVICE_OVERRIDE'::TEXT AS mapping_source
    FROM resolved_device rd
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
    -- Identical DISTINCT ON key and tie-break ORDER BY as
    -- telemetry.v_normalized_points' preferred_mappings -- profile mapping
    -- (priority 1) wins over device override (priority 2) on a tie, exactly
    -- as before. The input here is already scoped to one raw message and
    -- one device, so this DISTINCT ON operates over at most a handful of
    -- rows (one per mapped logical point) instead of every message in the
    -- chunk.
    SELECT DISTINCT ON
    (
        received_at,
        device_id,
        logical_point_id
    )
        received_at, raw_message_id, event_time, source_timestamp, mqtt_topic,
        organization_id, site_id, gateway_id, device_id, device_uid, device_identifier, payload,
        logical_point_id, logical_point, data_type, raw_field_name, json_path, transform_expression,
        mapping_priority, mapping_source
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
FROM extracted_values
-- Applied last, in exactly the same place the original call site applied
-- it (WHERE source_np.event_time=s.event_time, after the view's full
-- pipeline) -- kept here rather than pushed into resolved_device for
-- maximal fidelity to the original structure being replaced.
WHERE event_time = p_event_time;
$function$;

COMMENT ON FUNCTION telemetry.normalized_points_for_recovery_candidate IS
'Narrowly-scoped replacement for telemetry.v_normalized_points, used only by telemetry.recover_failed_raw_messages() (migration 202). Reproduces the shared view''s exact pipeline and DISTINCT ON (received_at, device_id, logical_point_id) tie-break (profile mapping beats device override), but pushes the already-known raw_message_id/device_id identity down to the telemetry.raw_messages primary-key lookup and the resolved-device join, before the DISTINCT ON runs -- avoiding the chunk-wide materialization/decompression the shared view pays for every call. Not used by any other caller; telemetry.v_normalized_points itself is unchanged.';

CREATE OR REPLACE PROCEDURE telemetry.recover_failed_raw_messages(IN p_limit integer DEFAULT 100)
LANGUAGE plpgsql
AS $procedure$
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
              -- Supersession search, bounded to the candidate bucket's own
              -- late-arrival tolerance window -- see COMMENT ON COLUMN
              -- config.telemetry_capture_policies.late_arrival_tolerance_seconds
              -- (migration 201) for the full semantic definition. Both
              -- bounds are resolved per-candidate from ce (bucket_start,
              -- deadline), never from now() or the candidate's own age, so
              -- an old failed message still gets a full, correctly-scoped
              -- search here -- it is only ever disqualified from recovery
              -- above by replay_attempt_count<5, never by this predicate.
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
                AND r2.received_at>=ce.bucket_start
                AND r2.received_at<=ce.deadline
                AND ROW
                    (COALESCE(r2.source_timestamp,r2.received_at),r2.received_at,r2.raw_message_id)
                    > ROW(ce.event_time,ce.received_at,ce.raw_message_id)
          )
        ON CONFLICT (site_id,bucket_start,device_id) DO NOTHING;

        -- Materialize any replay-selected samples from this raw packet.
        -- Migration 202: telemetry.normalized_points_for_recovery_candidate()
        -- replaces telemetry.v_normalized_points here -- see that function's
        -- COMMENT and migration 202's header for the full rationale and
        -- semantic-equivalence argument. Every other consumer of
        -- telemetry.v_normalized_points is unaffected.
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
            SELECT source_np.*
            FROM telemetry.normalized_points_for_recovery_candidate
            (
                s.raw_received_at,s.raw_message_id,s.device_id,s.event_time
            ) source_np
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
$procedure$;

-- Ownership and grants on the procedure are preserved as-is by
-- CREATE OR REPLACE PROCEDURE. The new function defaults to SECURITY
-- INVOKER (matching recover_failed_raw_messages' own security context,
-- confirmed prosecdef=false on the live procedure) and inherits standard
-- EXECUTE grants; no explicit GRANT is needed since it is only called from
-- within this SECURITY INVOKER procedure by roles that already hold SELECT
-- on every table it queries (all already queried directly elsewhere in
-- this same procedure body, or already granted for other telemetry
-- pipeline procedures in this schema).

COMMIT;
