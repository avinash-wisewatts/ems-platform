-- ============================================================================
-- Migration 243
-- Bounded catch-up window for job 1068 (telemetry.run_raw_message_failure_
-- capture_job / telemetry.capture_raw_message_failures_incremental).
--
-- Root cause (staging, 2026-09-04 through 2026-09-15 investigation; job 1068
-- currently disabled -- see docs/10-operations/incident-history.md): the
-- deployed telemetry.capture_raw_message_failures_incremental (as redefined
-- by migration 007, the current live body -- baseline migrations 001/003/006
-- are all superseded) always computes its forward boundary as
--     v_window_end := LEAST(v_normalized_checkpoint, clock_timestamp()-p_grace)
-- with NO cap on how far v_window_start (v_previous_checkpoint - p_overlap)
-- can trail behind it. When the gap between the checkpoint and "now" grows
-- wider than the job's 5-minute max_runtime, every attempt faces an
-- equal-or-wider window and can make zero durable progress -- exactly the
-- job-1000 stall migration 205 fixed, and the same failure mode: TimescaleDB
-- killed run after run for exceeding max_runtime until job 1068 hit its
-- max_retries and was auto-unscheduled ("Job 1068 unscheduled as max_retries
-- reached 3, consecutive failures 709", 2026-09-04 12:22:38).
--
-- Fix, mirroring migrations 205 (loader gains an optional bound) + 212
-- (wrapper always supplies a validated, config-overridable bound) for job
-- 1000, applied here as one migration since both procedures already exist:
--   1. telemetry.capture_raw_message_failures_incremental gains a third,
--      optional parameter, p_max_window INTERVAL DEFAULT NULL. When NULL
--      (the default), the forward boundary is computed exactly as today --
--      any direct/manual CALL that does not pass a third argument, or passes
--      NULL explicitly, is completely unaffected. When supplied together
--      with an existing checkpoint, the boundary is additionally capped via
--      one LEAST(...), applied after the existing computation, identical in
--      shape to migration 205's fix. The prior two-argument signature is
--      DROPped first (not merely CREATE OR REPLACEd) because CREATE OR
--      REPLACE cannot change arity -- it would instead create a second,
--      overloaded signature, making the existing two-argument call site
--      ambiguous at call time. This is the same DROP-then-CREATE-OR-REPLACE
--      step migration 205 used for the identical reason.
--   2. telemetry.run_raw_message_failure_capture_job (job 1068's TimescaleDB
--      action) now derives v_max_window from config->>'max_window' (falling
--      back to a placeholder default -- see the note below), validates it is
--      a positive interval before calling the loader (RAISE EXCEPTION
--      otherwise, leaving the checkpoint untouched), and ALWAYS passes it as
--      the loader's third argument. It never passes NULL. The wrapper does
--      NOT duplicate the loader's advisory lock / pipeline_state / RUNNING-
--      SUCCESS-FAILED handling / single-transaction / EXCEPTION->RAISE
--      rollback -- all of that stays exactly where it already lives, in the
--      loader, unchanged by this migration.
--
-- On the placeholder default value: unlike migration 212 (which shipped a
-- provisional-but-live 2-hour default for job 1000, later tunable via
-- alter_job with no code change), this migration deliberately does NOT pick
-- a value informed by any staging measurement -- none has been collected for
-- this procedure. INTERVAL '15 minutes' below is a syntactically-required
-- placeholder only (the parameter must have some compilable default), chosen
-- conservatively small precisely because it is unmeasured; it is explicitly
-- NOT a performance recommendation. It is fully overridable via
-- config.max_window (alter_job, no code change) once staging evidence exists
-- -- exactly the mechanism migration 212 established.
--
-- NOT touched by this migration:
--   - job 1068's live TimescaleDB schedule/config: this migration does NOT
--     alter_job job 1068 in any way (no config.max_window merge, no
--     scheduled=>true). Unlike migration 212 section 2, there is
--     deliberately no DO block here that writes config.max_window into the
--     job's stored configuration. Job 1068 remains exactly as it is today
--     (scheduled=false, no max_window key in its config) until an explicit,
--     separately-authorized change sets a measured value and re-enables it.
--   - telemetry.recover_failed_raw_messages / job 1077 (untouched -- no
--     change to its supersession search, retry/backoff, or p_limit
--     semantics).
--   - the failure-classification / produced_point_count detection logic
--     inside capture_raw_message_failures_incremental (the metrics/sel/res
--     CTEs, lines carried forward verbatim below). A read-only design study
--     for this fix proposed replacing this check with a lookup against
--     telemetry.normalized_points keyed on (platform_received_at,
--     raw_message_id). That proposal was based on a stale reading of the
--     pre-migration-006 procedure body and is NOT implemented here:
--     migration 006's own header states the reason explicitly --
--     "normalized_points deduplicates on (event_time, device_id,
--     logical_point_id) and may move raw_message_id/platform_received_at
--     lineage to a newer replay. Failure capture therefore must not infer
--     missing telemetry from mutable lineage." The live procedure (since
--     migration 007) already checks produced output via EXISTS against
--     telemetry.normalized_points on (device_id, event_time,
--     logical_point_id) -- the row's stable identity, matching the existing
--     UNIQUE index uq_normalized_points_identity -- specifically to avoid
--     the false-negative failure mode the design study's proposal would
--     have reintroduced. Only the window-boundary computation is changed by
--     this migration; every other line of the procedure body is carried
--     forward unchanged from migration 007's definition.
--   - telemetry.raw_messages / telemetry.raw_message_failures schemas, any
--     index, any retention/compression policy, Grafana, application/API
--     code, or the ownership/SECURITY/search_path/ACL of either procedure
--     (CREATE OR REPLACE preserves them).
-- ============================================================================

BEGIN;

-- ----------------------------------------------------------------------------
-- 1. telemetry.capture_raw_message_failures_incremental -- bounded forward
--    window via an optional third parameter. Every statement below is
--    byte-for-byte identical to the deployed migration-007 definition except
--    the new parameter, its validation, and the single LEAST(...) that caps
--    v_window_end when a caller supplies p_max_window and a previous
--    checkpoint already exists.
-- ----------------------------------------------------------------------------

DROP PROCEDURE IF EXISTS telemetry.capture_raw_message_failures_incremental(INTERVAL, INTERVAL);

CREATE OR REPLACE PROCEDURE telemetry.capture_raw_message_failures_incremental
(
    p_overlap    INTERVAL DEFAULT INTERVAL '15 minutes',
    p_grace      INTERVAL DEFAULT INTERVAL '20 minutes',
    p_max_window INTERVAL DEFAULT NULL
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
    -- Migration 243: validate the new parameter only. p_overlap/p_grace are
    -- unvalidated in the deployed migration-007 body (no RAISE EXCEPTION
    -- guard on either exists today) -- that is pre-existing behavior, not
    -- changed here.
    IF p_max_window IS NOT NULL AND p_max_window <= INTERVAL '0 seconds' THEN
        RAISE EXCEPTION 'p_max_window must be positive when supplied; received %', p_max_window;
    END IF;

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

    -- Migration 243: cap the forward processing boundary to the checkpoint
    -- plus p_max_window when a caller supplies one and a previous checkpoint
    -- already exists -- identical in shape to migration 205's fix for
    -- telemetry.load_normalized_points_incremental. NULL (the default, and
    -- what a direct/manual CALL continues to get unless it opts in) leaves
    -- v_window_end exactly as computed above, unchanged from migration 007.
    IF p_max_window IS NOT NULL AND v_previous_checkpoint IS NOT NULL THEN
        v_window_end := LEAST(v_window_end, v_previous_checkpoint + p_max_window);
    END IF;

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

COMMENT ON PROCEDURE telemetry.capture_raw_message_failures_incremental(INTERVAL, INTERVAL, INTERVAL) IS
'Captures malformed messages, unresolved rtdata elements, devices without profiles or enabled points, zero-output normalization, and partial normalization, evaluated against site-frequency selected normalization samples. Migration 243: p_max_window (default NULL) optionally caps the forward processing boundary to the previous checkpoint plus p_max_window, instead of always advancing all the way to LEAST(normalized checkpoint, now()-grace). NULL preserves the exact prior (migration 007) behavior for any direct/manual CALL. telemetry.run_raw_message_failure_capture_job always supplies a positive bound; it never passes NULL. produced_point_count is intentionally still derived from telemetry.normalized_points keyed on (device_id, event_time, logical_point_id) -- not (platform_received_at, raw_message_id) -- per migration 006''s explicit rejection of the latter (mutable lineage on supersession).';

-- ----------------------------------------------------------------------------
-- 2. telemetry.run_raw_message_failure_capture_job (job 1068's action) --
--    bounded forward window via config.max_window, mirroring migration 212's
--    treatment of job 1000's wrapper. Deployed body (baseline migration 001,
--    unchanged since) preserved verbatim except the max_window derivation,
--    its positive-only validation, and the third CALL argument.
-- ----------------------------------------------------------------------------

CREATE OR REPLACE PROCEDURE telemetry.run_raw_message_failure_capture_job
(
    job_id INTEGER,
    config JSONB
)
LANGUAGE plpgsql
AS
$$
DECLARE
    v_overlap    INTERVAL := INTERVAL '15 minutes';
    v_grace      INTERVAL := INTERVAL '20 minutes';
    -- Migration 243: syntactically-required placeholder only -- NOT a
    -- performance recommendation. No staging measurement has been collected
    -- for this procedure (unlike job 1000's migration-212 default, which
    -- likewise started provisional but was at least an informed guess for
    -- that job). Chosen conservatively small precisely because it is
    -- unmeasured. Overridable via config.max_window (alter_job, no code
    -- change) once staging evidence justifies a value; this migration does
    -- NOT set config.max_window on job 1068's live configuration.
    v_max_window INTERVAL := INTERVAL '15 minutes';
BEGIN
    IF config IS NOT NULL
       AND config ? 'overlap'
       AND NULLIF(btrim(config ->> 'overlap'), '') IS NOT NULL
    THEN
        v_overlap := (config ->> 'overlap')::INTERVAL;
    END IF;

    IF config IS NOT NULL
       AND config ? 'grace'
       AND NULLIF(btrim(config ->> 'grace'), '') IS NOT NULL
    THEN
        v_grace := (config ->> 'grace')::INTERVAL;
    END IF;

    -- Migration 243: bounded catch-up. The scheduled action ALWAYS passes a
    -- positive p_max_window so an unattended multi-day telemetry.raw_messages
    -- backlog self-drains over successive 5-minute runs rather than being
    -- attempted as one unbounded transaction that can make no durable
    -- progress once the gap exceeds max_runtime -- the exact mechanism that
    -- produced job 1068's 2026-09-04 auto-disable. Tunable via
    -- config.max_window (alter_job, no code change); never cleared to NULL
    -- through this wrapper. Unrestricted catch-up remains available by
    -- CALLing telemetry.capture_raw_message_failures_incremental(...)
    -- directly with only two arguments.
    IF config IS NOT NULL
       AND config ? 'max_window'
       AND NULLIF(btrim(config ->> 'max_window'), '') IS NOT NULL
    THEN
        v_max_window := (config ->> 'max_window')::INTERVAL;
    END IF;

    IF v_max_window IS NULL OR v_max_window <= INTERVAL '0 seconds' THEN
        RAISE EXCEPTION
            'Raw message failure capture job max_window must be a positive interval: %',
            v_max_window;
    END IF;

    CALL telemetry.capture_raw_message_failures_incremental
    (
        v_overlap,
        v_grace,
        v_max_window
    );
END;
$$;

COMMENT ON PROCEDURE telemetry.run_raw_message_failure_capture_job(INTEGER, JSONB) IS
'TimescaleDB background action that executes the incremental raw-message-failure capture loader. Migration 243: always passes a bounded p_max_window (placeholder default INTERVAL ''15 minutes'', unmeasured -- overridable via config.max_window with no code change) to telemetry.capture_raw_message_failures_incremental(), so an unattended backlog self-drains over successive 5-minute runs instead of being attempted as one unbounded transaction. Never passes NULL. Unrestricted forward catch-up remains available by CALLing the loader directly with two arguments. The advisory lock, telemetry.pipeline_state RUNNING/SUCCESS/FAILED handling, single-transaction boundary, and EXCEPTION->FAILED->RAISE rollback all remain in the loader and are unchanged. This migration does NOT alter_job job 1068''s live configuration or scheduled state -- config.max_window is not set on the live job by this migration, and the job remains disabled pending a separately-authorized change once staging performance evidence justifies a value.';

COMMIT;
