-- ============================================================================
-- File:
--   scripts/test/staging_measure_raw_message_failure_capture_window.sql
--
-- Purpose:
--   Bounded, read-only performance measurement of the SAME per-row cost that
--   telemetry.capture_raw_message_failures_incremental (job 1068) pays inside
--   its raw_candidates/metrics/classified CTE chain, for ONE explicit,
--   operator-supplied time window -- WITHOUT executing the procedure's own
--   INSERT (so it can never write a telemetry.raw_message_failures row) and
--   WITHOUT ever running unbounded.
--
--   This exists to collect the staging performance evidence migration 243's
--   header says is still needed before any real config.max_window value is
--   chosen for job 1068 -- it does NOT choose that value itself.
--
-- Safeguards (all mandatory, all enforced in this file or its .sh wrapper):
--   1. The window is an explicit, operator-supplied [:'window_start',
--      :'window_end') pair -- never derived from telemetry.pipeline_state,
--      never "from the stuck checkpoint to now". The .sh wrapper REFUSES to
--      run without both being passed explicitly, and caps the window to 60
--      minutes.
--   2. SET LOCAL statement_timeout applies to this transaction only, so a
--      pathological plan is killed automatically rather than left to run
--      indefinitely (this is exactly the mechanism the investigating agent
--      had to invoke pg_cancel_backend for by hand on 2026-09-15 after a much
--      simpler ad-hoc probe ran past 2 minutes unbounded).
--   3. The whole script runs inside BEGIN ... ROLLBACK, and the query itself
--      is SELECT-only (the metrics/classified CTEs, reproduced from the
--      deployed migration-007/243 body) -- it never reaches the procedure's
--      INSERT INTO telemetry.raw_message_failures. Nothing this script does
--      can write a row, even if interrupted mid-statement.
--   4. Only aggregate counts are selected/returned (row counts by failure
--      code), never raw payloads -- keeps output small and avoids echoing
--      customer telemetry content into diagnostic output.
--   5. EXPLAIN (no ANALYZE) is the default query form; ANALYZE is only used
--      when the .sh wrapper is explicitly passed --analyze, and even then it
--      is still bounded by (1) and (2) above and still cannot write.
--
-- Usage: invoked only via staging_measure_raw_message_failure_capture_window.sh
-- (which sets :window_start / :window_end / :statement_timeout_ms / :explain_kw
-- as psql variables). Do not run this file directly with unset variables.
-- ============================================================================

\set ON_ERROR_STOP on

BEGIN;

SET LOCAL statement_timeout = :'statement_timeout_ms';

-- Belt-and-braces: fail loudly instead of silently scanning "everything" if
-- either bound was left unset by the caller.
DO $guard$
BEGIN
    IF :'window_start' IS NULL OR :'window_end' IS NULL THEN
        RAISE EXCEPTION 'window_start/window_end must both be supplied -- refusing to run an unbounded measurement';
    END IF;
    IF :'window_end'::timestamptz <= :'window_start'::timestamptz THEN
        RAISE EXCEPTION 'window_end (%) must be after window_start (%)', :'window_end', :'window_start';
    END IF;
    IF :'window_end'::timestamptz - :'window_start'::timestamptz > INTERVAL '60 minutes' THEN
        RAISE EXCEPTION 'window (% to %) exceeds the 60-minute safety cap for this measurement script', :'window_start', :'window_end';
    END IF;
END;
$guard$;

-- The measured query: read-only reproduction of migration 243's
-- raw_candidates/selected_messages/metrics/classified CTE chain, ending in an
-- aggregate count instead of the procedure's INSERT. Any structural change to
-- this shape in a future migration should be mirrored here so the
-- measurement stays representative.
EXPLAIN (ANALYZE :explain_kw, BUFFERS :explain_kw, TIMING :explain_kw, FORMAT TEXT)
WITH raw_candidates AS MATERIALIZED
(
    SELECT r.*
    FROM telemetry.raw_messages r
    WHERE r.received_at > :'window_start'::timestamptz
      AND r.received_at <= :'window_end'::timestamptz
),
selected_messages AS MATERIALIZED
(
    SELECT DISTINCT raw_received_at,raw_message_id
    FROM telemetry.capture_bucket_samples
    WHERE raw_received_at > :'window_start'::timestamptz
      AND raw_received_at <= :'window_end'::timestamptz
),
metrics AS
(
    SELECT
        r.received_at,r.id,r.payload,
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
SELECT failure_code, count(*) AS candidate_count
FROM classified
GROUP BY failure_code
ORDER BY candidate_count DESC;

ROLLBACK;
