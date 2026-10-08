-- ============================================================================
-- Migration 291
-- Environment routing loader: bound its UPDATE to the correctable bucket range
-- so it stops decompressing every compressed telemetry.environment_measurements
-- chunk on every run.
--
-- WHY
--   telemetry.load_environment_measurements_incremental (job: run_environment_
--   routing_job) refreshes already-routed rows with
--       UPDATE telemetry.environment_measurements t ... FROM tmp_environment_candidates s
--       WHERE t.bucket_start = s.bucket_start AND t.device_id = s.device_id ...
--         AND v_now <= s.correction_deadline;
--   Nothing bounds t.bucket_start by a value the executor can apply to the
--   compressed batches, so TimescaleDB decompresses every compressed batch of
--   the hypertable on every run, however small the window. Once the compressed
--   rows exceed timescaledb.max_tuples_decompressed_per_dml_transaction
--   (100000), every run fails. Staging, 2026-10-08 10:04 IST: the daily
--   compression took the compressed rows from 73,414 to 109,092 (4 chunks:
--   3,210 + 40,074 + 30,130 + 35,678), every run failed with "tuples
--   decompressed: 109092", and TimescaleDB paused job 1012. Production carries
--   the same body (since release Stage 1) with about 43,600 compressed rows,
--   growing about 10,000 a week.
--
-- WHAT (only this; everything else in the body is byte-for-byte unchanged,
-- proven by the postconditions)
--     SELECT min(bucket_start) INTO v_update_floor
--     FROM tmp_environment_candidates
--     WHERE v_now <= correction_deadline;
--     IF v_update_floor IS NOT NULL THEN
--       UPDATE ... WHERE t.bucket_start >= v_update_floor AND <unchanged predicates>;
--       GET DIAGNOSTICS v_updated = ROW_COUNT;
--     END IF;
--   plus the declaration of v_update_floor.
--
-- SEMANTICS
--   * Exactly equivalent. The UPDATE already requires v_now <= s.correction_
--     deadline and t.bucket_start = s.bucket_start, so every row it can change
--     has bucket_start >= the earliest such candidate's bucket_start. The new
--     predicate removes nothing the UPDATE could have changed; when no
--     candidate is still correctable the UPDATE could change nothing, so it is
--     skipped and v_updated stays 0. The INSERT ... ON CONFLICT DO NOTHING is
--     unchanged (its conflict check is per key, already bounded).
--   * correction_deadline = bucket_start + capture_interval_seconds +
--     late_arrival_tolerance_seconds, i.e. minutes after the bucket, so the
--     floor is always recent and well inside the uncompressed chunk
--     (environment_measurements compresses after 7 days).
--   * The protection does not depend on plan-time chunk exclusion: TimescaleDB
--     filters compressed batches at execution with the bucket_start min/max
--     metadata (bucket_start is the compression order-by column, asserted
--     below). Verified with EXPLAIN ANALYZE under plan_cache_mode =
--     force_generic_plan: unbounded 4,000 tuples decompressed, bounded none.
--   * No runtime-dynamic SQL (generator contract), no planner setting changed.
--
-- SOURCES
--   Body: the offline generator's committed artifact
--   scripts/codegen/generated/load_environment_measurements_incremental.generated.sql,
--   regenerated from the updated template
--   scripts/codegen/templates/load_environment_measurements_incremental.sql.tmpl
--   (previous live CR-normalized md5 a3820ee221be9d535e5a357f2d946c52, the migration-267 body;
--   new CR-normalized md5 d0708b46eb9ab81a6b2cc37ee0d85ef5).
--   Tests: app/tests/test_environment_loader_bounded_update.py and
--   app/tests/test_routing_generator_contract.py.
-- ============================================================================


-- ----------------------------------------------------------------------------
-- 1. Preconditions: exact source body, and bucket_start is the compression
--    order-by column (the execution-time batch filter relies on it).
-- ----------------------------------------------------------------------------
DO $pre$
BEGIN
    IF (SELECT md5(replace(prosrc, E'\r', '')) FROM pg_proc
        WHERE oid = 'telemetry.load_environment_measurements_incremental(interval,interval)'::regprocedure)
       IS DISTINCT FROM 'a3820ee221be9d535e5a357f2d946c52' THEN
        RAISE EXCEPTION 'Migration 291 precondition failed: load_environment_measurements_incremental differs from the expected (migration 267) body.';
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM timescaledb_information.compression_settings
        WHERE hypertable_schema = 'telemetry' AND hypertable_name = 'environment_measurements'
          AND attname = 'bucket_start' AND orderby_column_index IS NOT NULL
    ) THEN
        RAISE EXCEPTION 'Migration 291 precondition failed: telemetry.environment_measurements is not compressed with bucket_start as an order-by column.';
    END IF;
END
$pre$;


-- ----------------------------------------------------------------------------
-- 2. Environment loader: the regenerated offline-generator artifact, verbatim.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE telemetry.load_environment_measurements_incremental(IN p_overlap interval DEFAULT '00:15:00'::interval, IN p_max_window interval DEFAULT NULL)
 LANGUAGE plpgsql
AS $procedure$
DECLARE
    v_pipeline_name CONSTANT TEXT := 'environment_measurements';
    v_previous_checkpoint TIMESTAMPTZ;
    v_window_start TIMESTAMPTZ;
    v_window_end TIMESTAMPTZ;
    v_updated BIGINT := 0;
    v_inserted BIGINT := 0;
    v_lock_acquired BOOLEAN;
    v_now TIMESTAMPTZ := clock_timestamp();
    v_update_floor TIMESTAMPTZ;
BEGIN
    IF p_overlap IS NULL OR p_overlap < INTERVAL '0 seconds' THEN
        RAISE EXCEPTION 'p_overlap must be zero or positive';
    END IF;

    -- Migration 207: reject a non-positive explicit bound. NULL (the
    -- default, and what a direct/manual invocation passes) means "no
    -- bound" -- byte-for-byte the pre-207 behaviour.
    IF p_max_window IS NOT NULL AND p_max_window <= INTERVAL '0 seconds' THEN
        RAISE EXCEPTION 'p_max_window must be positive when supplied; received %', p_max_window;
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

    -- Migration 267: bound the window-end lookup to recent event_time so it only
    -- reads uncompressed chunks (normalized_points compress_after = 1 day). The
    -- bounded max can only be lower than the global max, which delays -- never
    -- skips -- rows; the global lookup remains the fallback when no row has a
    -- recent event_time.
    SELECT max(platform_received_at) INTO v_window_end
    FROM telemetry.normalized_points
    WHERE platform_received_at IS NOT NULL
      AND event_time >= now() - INTERVAL '1 day';
    IF v_window_end IS NULL THEN
      SELECT max(platform_received_at) INTO v_window_end
      FROM telemetry.normalized_points
      WHERE platform_received_at IS NOT NULL;
    END IF;
    IF v_window_end IS NULL THEN
        UPDATE telemetry.pipeline_state
        SET last_completed_at=clock_timestamp(), last_inserted_rows=0,
            last_status='NO_SOURCE_DATA', updated_at=now()
        WHERE pipeline_name=v_pipeline_name;
        RETURN;
    END IF;

    -- Migration 207: cap the forward processing boundary to the previous
    -- checkpoint plus p_max_window when a caller supplies one and a
    -- previous checkpoint already exists. NULL (the default) leaves
    -- v_window_end exactly as computed above -- byte-for-byte the
    -- pre-207 behaviour. See telemetry.load_energy_measurements_incremental
    -- for the full rationale; this is the identical bound applied to the
    -- environment routing loader. Advisory lock, checkpoint keying,
    -- overlap semantics, the routing/calculation SQL below, and the
    -- EXCEPTION-rolls-back-the-watermark contract are all unchanged.
    IF p_max_window IS NOT NULL AND v_previous_checkpoint IS NOT NULL THEN
        v_window_end := LEAST(v_window_end, v_previous_checkpoint + p_max_window);
    END IF;

    -- Route from newly received normalized rows. Late source timestamps are
    -- discovered by their new platform receipt timestamp, so the historical
    -- correction tolerance does not need to be rescanned every minute.
    p_overlap := LEAST(p_overlap, INTERVAL '1 minute');

    v_window_start := CASE WHEN v_previous_checkpoint IS NULL
                           THEN '-infinity'::TIMESTAMPTZ
                           ELSE v_previous_checkpoint - p_overlap END;

    CREATE TEMP TABLE tmp_environment_candidates ON COMMIT DROP AS
    WITH window_events AS MATERIALIZED
    (
      SELECT np.device_id,np.event_time,MAX(np.platform_received_at) AS platform_received_at
      FROM telemetry.normalized_points np
      JOIN metadata.devices d ON d.id=np.device_id
      JOIN config.device_profiles dp ON dp.id=d.profile_id
      WHERE np.platform_received_at > v_window_start
        AND np.platform_received_at <= v_window_end
        AND dp.profile_code='ENVIRONMENT_SENSOR_AIRSENSE_V1'
        AND np.logical_point IN
        (
            'ENV_TEMPERATURE',
            'ENV_RELATIVE_HUMIDITY',
            'ENV_ILLUMINANCE_LUX',
            'OCCUPANCY_ACTIVITY',
            'OCCUPANCY_SECONDS_SINCE_LAST_PIR_EVENT',
            'PULSE_INPUT_1_RAW',
            'EXTERNAL_SENSOR_INPUT_1_RAW',
            'EXTERNAL_SENSOR_INPUT_2_RAW',
            'EXTERNAL_SENSOR_INPUT_3_RAW',
            'EXTERNAL_SENSOR_INPUT_4_RAW',
            'DEVICE_BATTERY_VOLTAGE',
            'BATTERY_VOLTAGE',
            'DEVICE_STATUS_CODE'
        )
      GROUP BY np.device_id,np.event_time
    ),
    full_resolution AS MATERIALIZED
    (
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
FROM window_events we
CROSS JOIN LATERAL
(
  SELECT src_np.*
  FROM telemetry.normalized_points src_np
  WHERE src_np.device_id = we.device_id
    AND src_np.event_time = we.event_time
  OFFSET 0
) np
JOIN metadata.devices d ON d.id = np.device_id
JOIN config.device_profiles dp ON dp.id = d.profile_id
WHERE dp.profile_code = 'ENVIRONMENT_SENSOR_AIRSENSE_V1'
  AND np.logical_point IN
  (
      'ENV_TEMPERATURE',
      'ENV_RELATIVE_HUMIDITY',
      'ENV_ILLUMINANCE_LUX',
      'OCCUPANCY_ACTIVITY',
      'OCCUPANCY_SECONDS_SINCE_LAST_PIR_EVENT',
      'PULSE_INPUT_1_RAW',
      'EXTERNAL_SENSOR_INPUT_1_RAW',
      'EXTERNAL_SENSOR_INPUT_2_RAW',
      'EXTERNAL_SENSOR_INPUT_3_RAW',
      'EXTERNAL_SENSOR_INPUT_4_RAW',
      'DEVICE_BATTERY_VOLTAGE',
      'BATTERY_VOLTAGE',
      'DEVICE_STATUS_CODE'
  )
GROUP BY np.event_time, np.organization_id, np.site_id, np.gateway_id, np.device_id
    ),
    resolved AS
    (
      SELECT fr.*,b.policy_id,b.capture_interval_seconds,
             b.late_arrival_tolerance_seconds,b.bucket_start
      FROM full_resolution fr
      CROSS JOIN LATERAL telemetry.resolve_site_capture_bucket
        (fr.site_id,COALESCE(fr.source_timestamp,fr.received_at)) AS b
    ),
    ranked AS
    (
      SELECT resolved.*,
             row_number() OVER
             (
               PARTITION BY resolved.device_id,resolved.policy_id,resolved.bucket_start
               ORDER BY COALESCE(resolved.source_timestamp,resolved.received_at) DESC,
                        resolved.received_at DESC NULLS LAST
             ) AS sample_rank
      FROM resolved
    )
    SELECT ranked.bucket_start,
           COALESCE(we.platform_received_at,ranked.received_at) AS received_at,
           ranked.source_timestamp,ranked.organization_id,ranked.site_id,ranked.gateway_id,
           ranked.device_id,ranked.asset_id,
           -- Migration 226: point-in-time, tenant-guarded Space resolution.
           -- A correlated scalar sub-select over metadata.space_points for
           -- the environmental logical points, effective at this reading's
           -- event time, restricted to the same organization as the row.
           -- (array_agg(DISTINCT space_id))[1] ... HAVING count(DISTINCT ...) = 1:
           --   * exactly one applicable Space  -> that space_id
           --   * no applicable binding         -> no row -> NULL
           --   * two or more distinct Spaces   -> HAVING fails -> NULL (never guesses)
           -- (core PostgreSQL has no max()/min() aggregate for uuid, so the
           -- single value is taken from a DISTINCT array gated by the count.)
           -- Uses metadata.space_points' migration-224 effective_range
           -- (a generated [) tstzrange; effective_to IS NULL => 'infinity').
           -- No row fan-out of the outer query.
           (
               SELECT (array_agg(DISTINCT sp.space_id))[1]
               FROM metadata.space_points sp
               JOIN metadata.spaces sps ON sps.id = sp.space_id
               WHERE sp.logical_point_id IN
               (
                   SELECT lp.id
                   FROM metadata.logical_points lp
                   WHERE lp.name IN
                   (
                       'ENV_TEMPERATURE',
                       'ENV_RELATIVE_HUMIDITY',
                       'ENV_ILLUMINANCE_LUX',
                       'OCCUPANCY_ACTIVITY',
                       'OCCUPANCY_SECONDS_SINCE_LAST_PIR_EVENT',
                       'PULSE_INPUT_1_RAW',
                       'EXTERNAL_SENSOR_INPUT_1_RAW',
                       'EXTERNAL_SENSOR_INPUT_2_RAW',
                       'EXTERNAL_SENSOR_INPUT_3_RAW',
                       'EXTERNAL_SENSOR_INPUT_4_RAW',
                       'DEVICE_BATTERY_VOLTAGE',
                       'BATTERY_VOLTAGE',
                       'DEVICE_STATUS_CODE'
                   )
               )
                 AND sp.effective_range @> COALESCE(ranked.source_timestamp, ranked.received_at)
                 AND sps.organization_id = ranked.organization_id
                 -- Migration 228: scope Space resolution to the Point instance of
                 -- THIS device -- (device_id, logical_point_id) is the
                 -- config.device_point_configuration PK. metadata.logical_points
                 -- is a global vocabulary, so a fleet of identical devices shares
                 -- one logical_point_id; without this predicate every same-org
                 -- device would resolve to a single Space. asset_devices is
                 -- unrelated / unchanged.
                 AND sp.device_id = ranked.device_id
               HAVING count(DISTINCT sp.space_id) = 1
           ) AS space_id,
           COALESCE(ranked.capture_interval_seconds,ranked.measurement_interval_seconds) AS measurement_interval_seconds,
           ranked.quality_code,ranked.is_estimated,
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
           ranked.device_status_code,
           ranked.bucket_start + make_interval(secs => ranked.capture_interval_seconds)
             + make_interval(secs => ranked.late_arrival_tolerance_seconds) AS correction_deadline
    FROM ranked
    JOIN window_events we
      ON we.device_id=ranked.device_id AND we.event_time=ranked.source_timestamp
    WHERE ranked.sample_rank=1
      AND ranked.bucket_start + make_interval(secs => COALESCE(ranked.capture_interval_seconds,1)) <= v_now;

    CREATE UNIQUE INDEX ON tmp_environment_candidates(bucket_start,device_id);

    -- Migration 291: only candidates still inside their correction window
    -- (v_now <= correction_deadline) can be updated, so bound the UPDATE to
    -- the earliest such bucket_start. That keeps it out of compressed chunks,
    -- which it otherwise decompressed in full on every run.
    SELECT min(bucket_start) INTO v_update_floor
    FROM tmp_environment_candidates
    WHERE v_now <= correction_deadline;

    IF v_update_floor IS NOT NULL THEN
    UPDATE telemetry.environment_measurements t
    SET received_at=s.received_at,
        source_timestamp=s.source_timestamp,
        organization_id=s.organization_id,
        site_id=s.site_id,
        gateway_id=s.gateway_id,
        asset_id=COALESCE(s.asset_id,t.asset_id),
        space_id=COALESCE(s.space_id,t.space_id),
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
    WHERE t.bucket_start >= v_update_floor
      AND t.bucket_start=s.bucket_start
      AND t.device_id=s.device_id
      AND COALESCE(s.source_timestamp,s.received_at) >
          COALESCE(t.source_timestamp,t.received_at,'-infinity'::TIMESTAMPTZ)
      AND v_now <= s.correction_deadline;
    GET DIAGNOSTICS v_updated = ROW_COUNT;
    END IF;

    INSERT INTO telemetry.environment_measurements
    (
      bucket_start, received_at, source_timestamp,
      organization_id, site_id, gateway_id, device_id, asset_id, space_id,
      measurement_interval_seconds, quality_code, is_estimated,
      temperature_c,
      humidity_percent,
      pressure_hpa,
      co2_ppm,
      voc_ppb,
      battery_voltage_v,
      signal_strength_dbm,
      illuminance_lux,
      occupancy_activity,
      raw_archive_id,
      seconds_since_last_pir_event,
      pulse_input_1_raw,
      external_input_1_raw,
      external_input_2_raw,
      external_input_3_raw,
      external_input_4_raw,
      device_status_code
    )
    SELECT
      s.bucket_start, s.received_at, s.source_timestamp,
      s.organization_id, s.site_id, s.gateway_id, s.device_id, s.asset_id, s.space_id,
      s.measurement_interval_seconds, s.quality_code, s.is_estimated,
      s.temperature_c,
      s.humidity_percent,
      s.pressure_hpa,
      s.co2_ppm,
      s.voc_ppb,
      s.battery_voltage_v,
      s.signal_strength_dbm,
      s.illuminance_lux,
      s.occupancy_activity,
      s.raw_archive_id,
      s.seconds_since_last_pir_event,
      s.pulse_input_1_raw,
      s.external_input_1_raw,
      s.external_input_2_raw,
      s.external_input_3_raw,
      s.external_input_4_raw,
      s.device_status_code
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
$procedure$;

COMMENT ON PROCEDURE telemetry.load_environment_measurements_incremental(interval, interval) IS
'Incrementally routes closed-bucket normalized environment telemetry into telemetry.environment_measurements. Checkpoint is telemetry.pipeline_state(''environment_measurements'').last_received_at, keyed on telemetry.normalized_points.platform_received_at; a pg_try_advisory_xact_lock serialises concurrent runs; the single transaction''s EXCEPTION handler re-RAISEs, so a caught failure rolls back the watermark with the data. '
'Migration 207: p_max_window (default NULL) optionally caps the forward processing boundary to previous_checkpoint + p_max_window instead of always advancing to max(telemetry.normalized_points.platform_received_at). NULL preserves the exact prior behaviour. The scheduled wrapper telemetry.run_environment_routing_job passes a bounded value (default 2 hours, config.max_window-overridable) so an unattended multi-hour backlog self-drains. No intermediate COMMIT is introduced. Mirrors migration 205 / telemetry.load_energy_measurements_incremental(). '
'Migration 226: additionally resolves telemetry.environment_measurements.space_id at routing time from metadata.space_points (point-in-time via effective_range, restricted to the row''s organization), writing NULL when there is no effective binding or when applicable bindings are ambiguous. All bounded-catch-up / watermark / overlap / correction-deadline / idempotency / advisory-lock behaviour is unchanged; quality_code is still written NULL. '
'Phase 4 (migration 227): this body is emitted by the offline generator scripts/codegen/generate_routing_procedure.py from config.parameter_routing (declarative spec scripts/codegen/routing/environment_measurements.routing.json), not hand-typed. It is behaviourally identical to the migration-226 body -- the same 12 routed logical points map to the same 12 destination columns with the same casts, the same legacy BATTERY_VOLTAGE compatibility alias feeds battery_voltage_v, and Space resolution, the watermark, bounded catch-up and the EXCEPTION contract are unchanged; only list/line formatting differs. No config.parameter_routing row is read at runtime.';



-- ----------------------------------------------------------------------------
-- 3. Postconditions: the new body is exactly the generated artifact, each
--    migration-291 fragment appears exactly once, and reverting the four
--    fragments gives back the migration-267 body byte for byte.
-- ----------------------------------------------------------------------------
DO $post$
DECLARE
    v_body TEXT;
BEGIN
    SELECT replace(prosrc, E'\r', '') INTO v_body FROM pg_proc
    WHERE oid = 'telemetry.load_environment_measurements_incremental(interval,interval)'::regprocedure;

    IF md5(v_body) IS DISTINCT FROM 'd0708b46eb9ab81a6b2cc37ee0d85ef5' THEN
        RAISE EXCEPTION 'Migration 291 postcondition failed: the loader body is not the expected migration-291 body (md5 %).', md5(v_body);
    END IF;

    IF (length(v_body) - length(replace(v_body, replace($n1$    v_now TIMESTAMPTZ := clock_timestamp();
    v_update_floor TIMESTAMPTZ;
$n1$, E'\r', ''), ''))) / length(replace($n1$    v_now TIMESTAMPTZ := clock_timestamp();
    v_update_floor TIMESTAMPTZ;
$n1$, E'\r', '')) <> 1 THEN
        RAISE EXCEPTION 'Migration 291 postcondition failed: fragment 1 of the bounded-UPDATE change is not present exactly once.';
    END IF;
    IF (length(v_body) - length(replace(v_body, replace($n2$    CREATE UNIQUE INDEX ON tmp_environment_candidates(bucket_start,device_id);

    -- Migration 291: only candidates still inside their correction window
    -- (v_now <= correction_deadline) can be updated, so bound the UPDATE to
    -- the earliest such bucket_start. That keeps it out of compressed chunks,
    -- which it otherwise decompressed in full on every run.
    SELECT min(bucket_start) INTO v_update_floor
    FROM tmp_environment_candidates
    WHERE v_now <= correction_deadline;

    IF v_update_floor IS NOT NULL THEN
    UPDATE telemetry.environment_measurements t
$n2$, E'\r', ''), ''))) / length(replace($n2$    CREATE UNIQUE INDEX ON tmp_environment_candidates(bucket_start,device_id);

    -- Migration 291: only candidates still inside their correction window
    -- (v_now <= correction_deadline) can be updated, so bound the UPDATE to
    -- the earliest such bucket_start. That keeps it out of compressed chunks,
    -- which it otherwise decompressed in full on every run.
    SELECT min(bucket_start) INTO v_update_floor
    FROM tmp_environment_candidates
    WHERE v_now <= correction_deadline;

    IF v_update_floor IS NOT NULL THEN
    UPDATE telemetry.environment_measurements t
$n2$, E'\r', '')) <> 1 THEN
        RAISE EXCEPTION 'Migration 291 postcondition failed: fragment 2 of the bounded-UPDATE change is not present exactly once.';
    END IF;
    IF (length(v_body) - length(replace(v_body, replace($n3$    WHERE t.bucket_start >= v_update_floor
      AND t.bucket_start=s.bucket_start
$n3$, E'\r', ''), ''))) / length(replace($n3$    WHERE t.bucket_start >= v_update_floor
      AND t.bucket_start=s.bucket_start
$n3$, E'\r', '')) <> 1 THEN
        RAISE EXCEPTION 'Migration 291 postcondition failed: fragment 3 of the bounded-UPDATE change is not present exactly once.';
    END IF;
    IF (length(v_body) - length(replace(v_body, replace($n4$    GET DIAGNOSTICS v_updated = ROW_COUNT;
    END IF;
$n4$, E'\r', ''), ''))) / length(replace($n4$    GET DIAGNOSTICS v_updated = ROW_COUNT;
    END IF;
$n4$, E'\r', '')) <> 1 THEN
        RAISE EXCEPTION 'Migration 291 postcondition failed: fragment 4 of the bounded-UPDATE change is not present exactly once.';
    END IF;

    IF md5(replace(replace(replace(replace(v_body,
            replace($n1$    v_now TIMESTAMPTZ := clock_timestamp();
    v_update_floor TIMESTAMPTZ;
$n1$, E'\r', ''),
            replace($o1$    v_now TIMESTAMPTZ := clock_timestamp();
$o1$, E'\r', '')),
            replace($n2$    CREATE UNIQUE INDEX ON tmp_environment_candidates(bucket_start,device_id);

    -- Migration 291: only candidates still inside their correction window
    -- (v_now <= correction_deadline) can be updated, so bound the UPDATE to
    -- the earliest such bucket_start. That keeps it out of compressed chunks,
    -- which it otherwise decompressed in full on every run.
    SELECT min(bucket_start) INTO v_update_floor
    FROM tmp_environment_candidates
    WHERE v_now <= correction_deadline;

    IF v_update_floor IS NOT NULL THEN
    UPDATE telemetry.environment_measurements t
$n2$, E'\r', ''),
            replace($o2$    CREATE UNIQUE INDEX ON tmp_environment_candidates(bucket_start,device_id);

    UPDATE telemetry.environment_measurements t
$o2$, E'\r', '')),
            replace($n3$    WHERE t.bucket_start >= v_update_floor
      AND t.bucket_start=s.bucket_start
$n3$, E'\r', ''),
            replace($o3$    WHERE t.bucket_start=s.bucket_start
$o3$, E'\r', '')),
            replace($n4$    GET DIAGNOSTICS v_updated = ROW_COUNT;
    END IF;
$n4$, E'\r', ''),
            replace($o4$    GET DIAGNOSTICS v_updated = ROW_COUNT;
$o4$, E'\r', ''))) IS DISTINCT FROM 'a3820ee221be9d535e5a357f2d946c52' THEN
        RAISE EXCEPTION 'Migration 291 postcondition failed: the loader changed outside the bounded-UPDATE fragments.';
    END IF;

    IF (SELECT pg_get_userbyid(proowner) FROM pg_proc
        WHERE oid = 'telemetry.load_environment_measurements_incremental(interval,interval)'::regprocedure) <> 'ems_admin' THEN
        RAISE EXCEPTION 'Migration 291 postcondition failed: the loader is no longer owned by ems_admin.';
    END IF;
END
$post$;
