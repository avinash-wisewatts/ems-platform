-- ============================================================================
-- Migration 221
-- Query-plan fix for telemetry.load_normalized_points_incremental()'s
-- selected_elements CTE: access telemetry.raw_messages on its FULL primary
-- key (received_at, id) AND bound rm.received_at to the loader's own
-- (v_window_start, v_window_end] window, instead of joining on id alone.
--
-- Root cause (production forensic, 2026-08-29/30; job 1000 paused for
-- investigation): a bounded normalization run took ~6m42s for a 5-minute
-- forward window (42,630 rows) and a 1-minute forward window still ran
-- >5m43s before it was cancelled -- runtime does NOT scale with the
-- watermark window. The window-independent floor cost is in the
-- tmp_normalized_batch build. selected_elements does:
--
--     FROM tmp_selected_samples s
--     JOIN telemetry.raw_messages rm
--       ON rm.id = s.raw_message_id
--     CROSS JOIN LATERAL jsonb_array_elements(rm.payload -> 'rtdata') ...
--
-- telemetry.raw_messages is a hypertable whose only indexes are the
-- PRIMARY KEY (received_at, id) and raw_messages_received_at_idx
-- (received_at DESC). Neither can serve an id-only equality, so the planner
-- produces a full Parallel Append over every raw_messages chunk (including a
-- ColumnarScan decompression of the compressed chunk) feeding a Hash Join,
-- then jsonb_array_elements-expands every row (~7.8 rtdata elements each),
-- then a DISTINCT ON sort that spills to temp files (IO/DataFileRead +
-- IO/BufFileRead observed live). Every invocation pays this regardless of
-- how little raw telemetry the window actually contains.
--
-- Production EXPLAIN (no ANALYZE), read-only, this session:
--   ON rm.id = s.raw_message_id
--     -> Hash Join (Hash Cond: rm.id = s.raw_message_id)
--          -> Parallel Append (rows=290533)
--               -> Custom Scan (ColumnarScan) on _hyper_3_248_chunk
--               -> Parallel Index Only Scan "260_raw_messages_pkey"
--               -> Parallel Index Only Scan "268_raw_messages_pkey"
--
-- This is the same pathology class migration 202 diagnosed and fixed for the
-- sibling recovery path (telemetry.recover_failed_raw_messages ->
-- telemetry.normalized_points_for_recovery_candidate), whose header records:
--   "the raw-row lookup is filtered by (received_at, raw_message_id) against
--    telemetry.raw_messages directly ... exactly matching the raw_messages
--    primary key (received_at, id) -- a single-chunk, single-row point
--    lookup instead of a chunk-wide compressed scan".
-- The main forward loader (migration 009, unchanged in this respect by
-- 010/202/205; 210-215 do not touch it) never received that treatment.
-- Migration 212 bounded the wrapper's forward window but the loader's
-- floor cost is > max_runtime regardless of the bound, so 212 exposed the
-- problem rather than causing it.
--
-- CHANGE (surgical; the migration-205 procedure body verbatim except this one
-- spot inside selected_elements, and one ANALYZE):
--     JOIN telemetry.raw_messages rm
--       ON rm.id = s.raw_message_id
--   becomes
--     JOIN telemetry.raw_messages rm
--       ON rm.received_at = s.raw_received_at
--      AND rm.id = s.raw_message_id
--      AND rm.received_at > v_window_start
--      AND rm.received_at <= v_window_end
--
-- The composite-key equality (rm.received_at = s.raw_received_at) alone is
-- NOT sufficient: staging EXPLAIN (ANALYZE, BUFFERS) against representative
-- data (500k+ telemetry.capture_bucket_samples rows, the same 3-chunk /
-- 1-compressed raw_messages shape as production), with and without a fresh
-- ANALYZE, and also a CROSS JOIN LATERAL rewrite, all still produce a
-- Parallel Hash Join over the full Parallel Append of every raw_messages
-- chunk (~16-21 s), because s.raw_received_at is a join column, not a
-- plan-time chunk-exclusion constant, and the planner costs ~1k parameterised
-- raw_messages_pkey probes (across a hypertable with a compressed chunk)
-- above one full parallel scan. Adding the literal (v_window_start,
-- v_window_end] range -- the loader's OWN already-computed plpgsql variables,
-- the identical bound raw_resolved applies one CTE earlier -- gives the
-- planner constants it can use for chunk exclusion. Staging, same 20-minute
-- bucket window:
--   BEFORE (id-only)                        : Parallel Hash Join over Parallel
--     Append of all 3 chunks (ColumnarScan decompress of the compressed
--     chunk), 255,162 raw rows, ~1.57M buffers, 16,013 ms.
--   AFTER (composite key + received_at range): Nested Loop -> Index Scan on
--     _hyper_1_244_chunk (the one in-window chunk) by received_at, then
--     capture_bucket_samples_raw_idx probe per row; the compressed chunk and
--     the older chunk are EXCLUDED; ~140k buffers, 810 ms (~20x faster).
--   Equivalence: the count of expanded (sample x rtdata-element) rows is
--   identical either way (9,138 = 9,138 over the sampled window).
--
-- WHY EQUIVALENT (no row selected, dropped, or reordered changes)
--   * tmp_selected_samples is SELECT s.* FROM telemetry.capture_bucket_samples
--     s JOIN tmp_capture_candidates ..., so s.raw_received_at and
--     s.raw_message_id are the capture_bucket_samples columns of the same
--     name. Both are NOT NULL (telemetry.capture_bucket_samples DDL).
--   * capture_bucket_samples.raw_received_at is written (this same loader,
--     INSERT ... SELECT c.raw_received_at ...) from tmp_capture_candidates,
--     whose raw_received_at is "eligible.received_at" == the source
--     telemetry.raw_messages.received_at for that raw_message_id (it flows
--     unchanged from telemetry.v_rtdata -> raw_resolved -> ... -> the
--     DISTINCT ON projection "received_at AS raw_received_at"). Likewise
--     capture_bucket_samples.raw_message_id == telemetry.raw_messages.id.
--   * telemetry.raw_messages PRIMARY KEY is (received_at, id): for any given
--     s.raw_message_id there is exactly one rm row, and its rm.received_at is
--     by construction equal to s.raw_received_at. The composite equality
--     removes/adds zero rows.
--   * rm.received_at > v_window_start AND rm.received_at <= v_window_end is
--     the SAME predicate raw_resolved already applied when it selected these
--     candidates from telemetry.v_rtdata one CTE earlier (WHERE r.received_at
--     > v_window_start AND r.received_at <= v_window_end). Every raw_message
--     SELECTED in the current run therefore already satisfies it -- adding it
--     to the second raw access selects zero fewer of them.
--   * The ONE observable nuance: a pre-existing telemetry.capture_bucket_
--     samples row with status='FAILED' from an earlier run can be re-matched
--     into tmp_selected_samples via (site_id, bucket_start, device_id) while
--     carrying its own older raw_received_at. If that raw_received_at is
--     <= v_window_start it no longer resolves an rm row and the sample stays
--     FAILED -- but it was already FAILED (0 normalized points), the
--     status-update step re-derives FAILED whenever point_count = 0, and a
--     re-expansion over the identical stale raw would produce the identical
--     result, so the persisted outcome (status='FAILED', no normalized_points
--     row) is unchanged. SELECTED (fresh-this-run) samples always have their
--     raw in (v_window_start, v_window_end].
--   * Nothing downstream of selected_elements is touched: profile_mappings /
--     device_mappings / candidate_mappings / preferred_mappings (DISTINCT ON
--     tie-break unchanged) / extracted_values / the normalized_points,
--     capture_bucket_samples, device_point_state, device_telemetry_state and
--     pipeline_state writes are byte-for-byte the migration-205 body.
--
-- Fresh planner statistics on telemetry.capture_bucket_samples are required
-- for the planner to actually choose the nested-loop path over a hash join:
-- production shows pg_stat_user_tables.last_analyze IS NULL for that table
-- and its last autoanalyze predates the incident. One ANALYZE is issued
-- here; ongoing autoanalyze tuning for that table is a separate follow-up
-- (as is the capture_bucket_samples prune job, the migration-202-style
-- preferred_mappings early-filter, and the v_dynamic_overlap policy-floor
-- scope -- NONE of which are in this migration).
--
-- NOT changed by this migration:
--   procedure signature telemetry.load_normalized_points_incremental(
--     p_overlap INTERVAL DEFAULT INTERVAL '5 minutes',
--     p_max_window INTERVAL DEFAULT NULL) -- arity and defaults unchanged,
--     no DROP, CREATE OR REPLACE only;
--   the advisory lock (pg_try_advisory_xact_lock / SKIPPED_LOCKED),
--   the FOR UPDATE checkpoint read, the RUNNING/SUCCESS/NO_SOURCE_DATA/
--   FAILED pipeline_state handling, the single-transaction boundary (no
--   intermediate COMMIT), the EXCEPTION WHEN OTHERS -> FAILED -> RAISE
--   rollback, the p_overlap / v_dynamic_overlap / late-arrival-horizon
--   computation, the migration-205 LEAST(v_window_end,
--   v_previous_checkpoint + p_max_window) bound, the 48h bounded first run;
--   telemetry.run_normalization_job (migration 212 wrapper), job 1000's
--   schedule / max_runtime / max_retries / retry_period / scheduled / config
--   (config.max_window is NOT touched -- this is not a max_window change);
--   telemetry.normalized_points / telemetry.raw_messages /
--   telemetry.capture_bucket_samples schemas, indexes, retention;
--   postgres/ddl/41_incremental_normalization_loader.sql and
--   postgres/jobs/42_normalization_background_job.sql (canonical files --
--   migrations 205 and 212 set the precedent of not re-issuing the canonical
--   ddl/jobs file when a migration redefines this procedure/wrapper);
--   the routing jobs, energy consumption, demand, environment_daily,
--   reconciliation (213), v_pipeline_health (214), any CAGG or its policies,
--   Grafana, application/API code;
--   ownership / SECURITY / search_path / ACL of any object (CREATE OR
--   REPLACE preserves them).
-- ============================================================================

BEGIN;

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
        -- Migration 221: access telemetry.raw_messages on its full primary key
        -- (received_at, id) AND bound rm.received_at to the SAME
        -- (v_window_start, v_window_end] the candidate scan (raw_resolved,
        -- above) already applied. Both are provably lossless (see this
        -- migration's header) and together they let the planner do a
        -- single-chunk index range scan + a capture_bucket_samples_raw_idx
        -- probe per row, instead of a full-hypertable Parallel Append +
        -- ColumnarScan decompression + Hash Join on every invocation. The
        -- composite-key equality ALONE does not change the plan (verified by
        -- staging EXPLAIN (ANALYZE, BUFFERS) on representative data); the
        -- literal received_at range is what enables chunk exclusion.
        JOIN telemetry.raw_messages rm
          ON rm.received_at=s.raw_received_at
         AND rm.id=s.raw_message_id
         AND rm.received_at > v_window_start
         AND rm.received_at <= v_window_end
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
'Migration 205: p_max_window (default NULL) optionally caps the forward processing boundary to the previous checkpoint plus p_max_window, instead of always advancing all the way to max(telemetry.raw_messages.received_at). NULL preserves the exact prior behavior -- telemetry.run_normalization_job''s normal invocation is unaffected. Intended for manually catching up a stuck gap (e.g. after a period of repeated failures) in a sequence of small, individually-transactional calls: each bounded call either completes its capped window and durably advances the watermark, or rolls back completely, exactly like every existing call. No intermediate COMMIT is introduced; this is a bound on scope, not a change to transaction boundaries. '
'Migration 221: selected_elements now accesses telemetry.raw_messages on the full primary key (received_at, id) AND bounds rm.received_at to the loader''s own (v_window_start, v_window_end] window -- ON rm.received_at = s.raw_received_at AND rm.id = s.raw_message_id AND rm.received_at > v_window_start AND rm.received_at <= v_window_end -- instead of joining on id alone. Row-equivalent (s.raw_received_at is, by construction, the source raw_messages.received_at for s.raw_message_id, and the window range is the identical predicate raw_resolved already applied one CTE earlier), but it lets the planner do a single in-window chunk index range scan + a capture_bucket_samples_raw_idx probe per row instead of a full-hypertable Parallel Append + compressed-chunk decompression + Hash Join on every invocation (staging EXPLAIN (ANALYZE, BUFFERS): 16 s -> 0.8 s, ~20x; the composite key ALONE did not change the plan). Same class of fix as migration 202 for the sibling recovery path. Advisory lock / pipeline_state / single-transaction / EXCEPTION rollback / overlap / 205 bound are all unchanged.';

-- Migration 221: the planner needs current statistics on
-- telemetry.capture_bucket_samples (production: last_analyze IS NULL, last
-- autoanalyze predates the incident) to choose the parameterised nested-loop
-- Index Scan on raw_messages_pkey over a hash join. One-off; ANALYZE is
-- transaction-safe (unlike VACUUM).
ANALYZE telemetry.capture_bucket_samples;

COMMIT;
