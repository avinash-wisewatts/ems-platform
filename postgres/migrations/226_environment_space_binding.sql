-- ============================================================================
-- Migration 226
-- Phase 3 (Domain-general Measurement Proof) -- first qualifying real domain:
-- AirSense / environmental sensing.
--
-- Source of record:
--   docs/DDS/analytics-platform-future-state-architecture.md (frozen), esp.
--     * B.3 Subject = Asset | Space (optional; "often none")
--     * B.5 telemetry.environment_measurements "gains a space_id column ...
--       populated at routing time ... directly via space_points for a
--       space-mounted sensor with no owning asset"
--   docs/DDS/analytics-platform-future-state-architecture-implementation-
--     roadmap.md, "Phase 3", and the final Phase 3 implementation-readiness
--     checkpoint that approved exactly this scope.
--
-- What this migration does (the entire approved Phase 3 delta):
--   1. Adds telemetry.environment_measurements.space_id UUID
--      (nullable, no default, FK -> metadata.spaces(id)). No index -- the
--      readiness review removed the proposed partial index: nothing filters
--      on space_id yet (no view, panel or query), so a partial index on a
--      column that is 100% NULL has no consumer. Add it in the phase that
--      introduces the first space-filtered consumer.
--   2. CREATE OR REPLACE telemetry.load_environment_measurements_incremental
--      (interval, interval) -- the deployed migration-207 body reproduced
--      verbatim, plus exactly three additive edits:
--        (a) one correlated scalar sub-select resolving space_id from
--            metadata.space_points, point-in-time and tenant-guarded;
--        (b) space_id = COALESCE(s.space_id, t.space_id) added to the
--            UPDATE ... SET list (mirrors the existing asset_id line --
--            never clears an existing value);
--        (c) space_id added to the INSERT column list and its SELECT.
--      Every other statement -- the p_overlap / p_max_window validation,
--      the pg_try_advisory_xact_lock, the pipeline_state RUNNING / SUCCESS /
--      FAILED / SKIPPED_LOCKED / NO_SOURCE_DATA handling, the checkpoint
--      keying on normalized_points.platform_received_at, the migration-207
--      p_max_window bound, the LEAST(p_overlap, 1 minute) clamp, the
--      window_events / full_resolution / resolve_site_capture_bucket /
--      ranked pipeline, the sample_rank = 1 + closed-bucket filter, the
--      correction-deadline-guarded UPDATE, the
--      ON CONFLICT (bucket_start, device_id) DO NOTHING INSERT, and the
--      EXCEPTION WHEN OTHERS -> FAILED -> RAISE contract -- is reproduced
--      byte-for-byte from the currently deployed definition.
--
-- Deliberately NOT changed:
--   * quality_code stays NULL (the loader still projects NULL::SMALLINT).
--     No grounded integer encoding for *_measurements.quality_code exists
--     anywhere on origin/staging (the energy loader leaves it NULL too), so
--     a fold here would be an invented taxonomy. Deferred as a separate,
--     uniform slice.
--   * No historical backfill of space_id -- every pre-226 row keeps
--     space_id = NULL. A postcondition asserts this migration inserted no
--     non-NULL space_id.
--   * telemetry.run_environment_routing_job / job 69 / job 70 / every CAGG
--     (ca_environment_15min, ca_environment_hourly) / environment_daily /
--     telemetry.reconcile_environment_daily / analytics.v_environment_* --
--     untouched. No job is registered, enabled, rescheduled or reconfigured.
--   * The entire energy subsystem -- distinct procedures, tables, jobs,
--     views. A postcondition asserts the energy loader body still does not
--     reference space_id.
--   * metadata.space_points / metadata.spaces -- read only. No Space row is
--     created and no logical point is bound to a Space by this migration.
--
-- Known limitation (documented, not a defect of this migration):
--   metadata.space_points (migration 224) keys a binding on logical_point_id
--   alone, and metadata.logical_points is a GLOBAL vendor-neutral vocabulary
--   (uq_logical_points_name), not per-device. A binding of e.g. ENV_TEMPERATURE
--   to a Space therefore applies platform-wide, and the migration-224
--   exclusion constraint ex_space_points_no_overlap forbids two concurrent
--   Space bindings for one logical point. For the single commissioned AirSense
--   device this resolves correctly; per-device Space attribution for a
--   multi-device environmental fleet needs a space_points.device_id column (or
--   equivalent) and is out of scope here. Because no space_points row exists
--   today, the live steady-state result of this migration is space_id = NULL.
--
-- Rollback: postgres/maintenance/226_environment_space_binding_rollback.sql
--   -- dependency-checked, no CASCADE, restores the verbatim migration-207
--   loader body. Not run as part of this migration.
--
-- Transaction: the forward migration runner (scripts/apply_migrations.sh)
--   wraps this file in a single BEGIN/COMMIT with its ledger insert; this
--   file therefore contains no BEGIN/COMMIT of its own (matches migrations
--   223/224/225).
-- ============================================================================


-- ----------------------------------------------------------------------------
-- 1. Additive column + FK. Nullable, no default -> ADD COLUMN is metadata-only
--    on PostgreSQL; ADD CONSTRAINT ... FOREIGN KEY validates existing rows,
--    which are all NULL, so validation is trivial. NULL space_id rows skip the
--    FK check (MATCH SIMPLE), so there is no per-row overhead while unbound.
-- ----------------------------------------------------------------------------

ALTER TABLE telemetry.environment_measurements
    ADD COLUMN IF NOT EXISTS space_id UUID;

ALTER TABLE telemetry.environment_measurements
    DROP CONSTRAINT IF EXISTS environment_measurements_space_id_fkey;

ALTER TABLE telemetry.environment_measurements
    ADD CONSTRAINT environment_measurements_space_id_fkey
    FOREIGN KEY (space_id) REFERENCES metadata.spaces(id);

COMMENT ON COLUMN telemetry.environment_measurements.space_id IS
'Phase 3 (migration 226): the Space this environmental reading is about, resolved at routing time from metadata.space_points (point-in-time, tenant-guarded). NULL when there is no effective binding, when the applicable bindings are ambiguous, or for any row written before this migration. Populated going forward only -- never backfilled.';


-- ----------------------------------------------------------------------------
-- 2. Loader: deployed migration-207 body + the three additive edits.
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
            'ENV_TEMPERATURE','ENV_RELATIVE_HUMIDITY','ENV_ILLUMINANCE_LUX',
            'OCCUPANCY_ACTIVITY','OCCUPANCY_SECONDS_SINCE_LAST_PIR_EVENT',
            'PULSE_INPUT_1_RAW','EXTERNAL_SENSOR_INPUT_1_RAW','EXTERNAL_SENSOR_INPUT_2_RAW',
            'EXTERNAL_SENSOR_INPUT_3_RAW','EXTERNAL_SENSOR_INPUT_4_RAW',
            'DEVICE_BATTERY_VOLTAGE','BATTERY_VOLTAGE','DEVICE_STATUS_CODE'
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
      'ENV_TEMPERATURE','ENV_RELATIVE_HUMIDITY','ENV_ILLUMINANCE_LUX',
      'OCCUPANCY_ACTIVITY','OCCUPANCY_SECONDS_SINCE_LAST_PIR_EVENT',
      'PULSE_INPUT_1_RAW','EXTERNAL_SENSOR_INPUT_1_RAW','EXTERNAL_SENSOR_INPUT_2_RAW',
      'EXTERNAL_SENSOR_INPUT_3_RAW','EXTERNAL_SENSOR_INPUT_4_RAW',
      'DEVICE_BATTERY_VOLTAGE','BATTERY_VOLTAGE','DEVICE_STATUS_CODE'
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
                       'ENV_TEMPERATURE','ENV_RELATIVE_HUMIDITY','ENV_ILLUMINANCE_LUX',
                       'OCCUPANCY_ACTIVITY','OCCUPANCY_SECONDS_SINCE_LAST_PIR_EVENT',
                       'PULSE_INPUT_1_RAW','EXTERNAL_SENSOR_INPUT_1_RAW','EXTERNAL_SENSOR_INPUT_2_RAW',
                       'EXTERNAL_SENSOR_INPUT_3_RAW','EXTERNAL_SENSOR_INPUT_4_RAW',
                       'DEVICE_BATTERY_VOLTAGE','BATTERY_VOLTAGE','DEVICE_STATUS_CODE'
                   )
               )
                 AND sp.effective_range @> COALESCE(ranked.source_timestamp, ranked.received_at)
                 AND sps.organization_id = ranked.organization_id
               HAVING count(DISTINCT sp.space_id) = 1
           ) AS space_id,
           COALESCE(ranked.capture_interval_seconds,ranked.measurement_interval_seconds) AS measurement_interval_seconds,
           ranked.quality_code,ranked.is_estimated,ranked.temperature_c,ranked.humidity_percent,
           ranked.pressure_hpa,ranked.co2_ppm,ranked.voc_ppb,ranked.battery_voltage_v,
           ranked.signal_strength_dbm,ranked.illuminance_lux,ranked.occupancy_activity,
           ranked.raw_archive_id,ranked.seconds_since_last_pir_event,ranked.pulse_input_1_raw,
           ranked.external_input_1_raw,ranked.external_input_2_raw,ranked.external_input_3_raw,
           ranked.external_input_4_raw,ranked.device_status_code,
           ranked.bucket_start + make_interval(secs => ranked.capture_interval_seconds)
             + make_interval(secs => ranked.late_arrival_tolerance_seconds) AS correction_deadline
    FROM ranked
    JOIN window_events we
      ON we.device_id=ranked.device_id AND we.event_time=ranked.source_timestamp
    WHERE ranked.sample_rank=1
      AND ranked.bucket_start + make_interval(secs => COALESCE(ranked.capture_interval_seconds,1)) <= v_now;

    CREATE UNIQUE INDEX ON tmp_environment_candidates(bucket_start,device_id);

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
    WHERE t.bucket_start=s.bucket_start
      AND t.device_id=s.device_id
      AND COALESCE(s.source_timestamp,s.received_at) >
          COALESCE(t.source_timestamp,t.received_at,'-infinity'::TIMESTAMPTZ)
      AND v_now <= s.correction_deadline;
    GET DIAGNOSTICS v_updated = ROW_COUNT;

    INSERT INTO telemetry.environment_measurements
    (
      bucket_start, received_at, source_timestamp,
      organization_id, site_id, gateway_id, device_id, asset_id, space_id,
      measurement_interval_seconds, quality_code, is_estimated,
      temperature_c, humidity_percent, pressure_hpa, co2_ppm, voc_ppb,
      battery_voltage_v, signal_strength_dbm, illuminance_lux, occupancy_activity,
      raw_archive_id, seconds_since_last_pir_event, pulse_input_1_raw,
      external_input_1_raw, external_input_2_raw, external_input_3_raw,
      external_input_4_raw, device_status_code
    )
    SELECT
      s.bucket_start, s.received_at, s.source_timestamp,
      s.organization_id, s.site_id, s.gateway_id, s.device_id, s.asset_id, s.space_id,
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
$procedure$;

COMMENT ON PROCEDURE telemetry.load_environment_measurements_incremental(interval, interval) IS
'Incrementally routes closed-bucket normalized environment telemetry into telemetry.environment_measurements. Checkpoint is telemetry.pipeline_state(''environment_measurements'').last_received_at, keyed on telemetry.normalized_points.platform_received_at; a pg_try_advisory_xact_lock serialises concurrent runs; the single transaction''s EXCEPTION handler re-RAISEs, so a caught failure rolls back the watermark with the data. '
'Migration 207: p_max_window (default NULL) optionally caps the forward processing boundary to previous_checkpoint + p_max_window instead of always advancing to max(telemetry.normalized_points.platform_received_at). NULL preserves the exact prior behaviour. The scheduled wrapper telemetry.run_environment_routing_job passes a bounded value (default 2 hours, config.max_window-overridable) so an unattended multi-hour backlog self-drains. No intermediate COMMIT is introduced. Mirrors migration 205 / telemetry.load_energy_measurements_incremental(). '
'Migration 226: additionally resolves telemetry.environment_measurements.space_id at routing time from metadata.space_points (point-in-time via effective_range, restricted to the row''s organization), writing NULL when there is no effective binding or when applicable bindings are ambiguous. All bounded-catch-up / watermark / overlap / correction-deadline / idempotency / advisory-lock behaviour is unchanged; quality_code is still written NULL.';


-- ----------------------------------------------------------------------------
-- 3. Postconditions -- fail the transaction loudly on any drift from the
--    intended end state, per the migration 198/199/219/223/224 discipline.
-- ----------------------------------------------------------------------------

DO $$
DECLARE
    v_env_body  TEXT;
    v_ener_body TEXT;
    v_nonnull   BIGINT;
BEGIN
    -- (a) column present, uuid, nullable
    IF NOT EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema='telemetry' AND table_name='environment_measurements'
          AND column_name='space_id' AND data_type='uuid' AND is_nullable='YES'
    ) THEN
        RAISE EXCEPTION 'Migration 226 postcondition failed: telemetry.environment_measurements.space_id is missing or not a nullable uuid.';
    END IF;

    -- (b) FK present, targets metadata.spaces
    IF NOT EXISTS (
        SELECT 1
        FROM pg_constraint c
        JOIN pg_class rel ON rel.oid = c.conrelid
        JOIN pg_namespace n ON n.oid = rel.relnamespace
        JOIN pg_class frel ON frel.oid = c.confrelid
        JOIN pg_namespace fn ON fn.oid = frel.relnamespace
        WHERE c.conname='environment_measurements_space_id_fkey'
          AND c.contype='f'
          AND n.nspname='telemetry' AND rel.relname='environment_measurements'
          AND fn.nspname='metadata' AND frel.relname='spaces'
    ) THEN
        RAISE EXCEPTION 'Migration 226 postcondition failed: environment_measurements_space_id_fkey is missing or does not target metadata.spaces.';
    END IF;

    -- (c) the environment loader body now references space_points (guards a
    --     silent no-op CREATE OR REPLACE)
    v_env_body := pg_get_functiondef('telemetry.load_environment_measurements_incremental(interval,interval)'::regprocedure);
    IF position('metadata.space_points' IN v_env_body) = 0 THEN
        RAISE EXCEPTION 'Migration 226 postcondition failed: the environment loader body does not reference metadata.space_points.';
    END IF;

    -- (d) energy safety: the energy loader body must NOT reference space_id
    --     (proves migration 226 did not touch it) and must still reference
    --     its own domain table.
    v_ener_body := pg_get_functiondef('telemetry.load_energy_measurements_incremental(interval,interval)'::regprocedure);
    IF position('space_id' IN v_ener_body) <> 0 THEN
        RAISE EXCEPTION 'Migration 226 postcondition failed: the energy loader body unexpectedly references space_id -- energy was touched.';
    END IF;
    IF position('telemetry.energy_measurements' IN v_ener_body) = 0 THEN
        RAISE EXCEPTION 'Migration 226 postcondition failed: the energy loader body no longer references telemetry.energy_measurements.';
    END IF;

    -- (e) no historical backfill occurred
    SELECT count(*) INTO v_nonnull FROM telemetry.environment_measurements WHERE space_id IS NOT NULL;
    IF v_nonnull <> 0 THEN
        RAISE EXCEPTION 'Migration 226 postcondition failed: % environment_measurements rows have a non-NULL space_id -- migration 226 must not backfill.', v_nonnull;
    END IF;

    -- (f) no job was registered, enabled, rescheduled or reconfigured by this
    --     migration -- the environment routing job proc signature is unchanged
    --     so no re-registration is possible; assert the wrapper still exists.
    IF to_regprocedure('telemetry.run_environment_routing_job(integer,jsonb)') IS NULL THEN
        RAISE EXCEPTION 'Migration 226 postcondition failed: telemetry.run_environment_routing_job(integer,jsonb) is missing.';
    END IF;
END;
$$;
