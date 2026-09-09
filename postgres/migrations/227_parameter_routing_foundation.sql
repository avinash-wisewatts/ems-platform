-- ============================================================================
-- Migration 227
-- Phase 4 (Routing Architecture) -- declarative parameter routing foundation,
-- proven on the first qualifying real domain: AirSense / environmental sensing.
--
-- Source of record:
--   docs/DDS/analytics-platform-future-state-architecture.md (frozen), esp.
--     * B.6 point 4 -- "Routing into any of the above becomes table-driven,
--       not hardcoded ... a small, offline, CI-time generator reads
--       config.parameter_routing and emits the actual CREATE OR REPLACE
--       PROCEDURE ... not runtime-dynamic SQL".
--   docs/DDS/analytics-platform-future-state-architecture-implementation-
--     roadmap.md, "Phase 4 -- Routing Architecture".
--   The Phase 4 design checkpoint and its follow-up decision:
--     * seed the 12 genuine AirSense logical-point routing mappings as
--       FK-backed config.parameter_routing rows;
--     * the legacy pre-rename source name BATTERY_VOLTAGE (no metadata.
--       logical_points row, no config.parameters row) is preserved ONLY as an
--       explicit compatibility alias on the DEVICE_BATTERY_VOLTAGE row's
--       legacy_source_aliases -- it is NOT a routing row and NOT a semantic
--       identity;
--     * parity bar: token/behavioural equivalence with an enumerated
--       whitespace diff (approved), not raw pg_get_functiondef string identity.
--
-- What this migration does (the entire approved Phase 4 slice):
--   1. Creates config.parameter_routing -- the declarative column-mapping
--      layer: (profile_id, logical_point_id) -> (destination_table,
--      destination_column, value_transform), with an optional parameter_id
--      for semantic traceability and an optional legacy_source_aliases[] for
--      pre-rename compatibility source names. Configuration table, no
--      organization_id (tenant scope is carried by the telemetry rows the
--      generated procedure processes, exactly as before). GRANT SELECT to
--      ems_app / ems_admin only, matching config.parameters (migration 223).
--   2. Seeds exactly the 12 genuine ENVIRONMENT_SENSOR_AIRSENSE_V1 routing
--      mappings, resolving logical_point_id by name (metadata.logical_points
--      .name is the portable identity -- migration 215) and parameter_id by
--      config.parameters.code (LEFT JOIN: 6 mapped, 6 deliberately NULL).
--      The DEVICE_BATTERY_VOLTAGE row carries legacy_source_aliases =
--      ARRAY['BATTERY_VOLTAGE'].
--   3. CREATE OR REPLACE telemetry.load_environment_measurements_incremental
--      (interval, interval) with the body EMITTED BY the offline generator
--      scripts/codegen/generate_routing_procedure.py from
--      scripts/codegen/routing/environment_measurements.routing.json +
--      scripts/codegen/templates/load_environment_measurements_incremental
--      .sql.tmpl. The generated body is behaviourally identical to the
--      deployed migration-226 body: same 12 routed logical points -> same 12
--      destination columns, same casts (DOUBLE PRECISION / ROUND(...)::INTEGER),
--      same legacy BATTERY_VOLTAGE alias on battery_voltage_v, same
--      window_events / CROSS JOIN LATERAL (... OFFSET 0) / MATERIALIZED plan
--      shape, same migration-226 point-in-time tenant-guarded Space
--      resolution, same p_max_window bound, same LEAST(p_overlap,1 minute),
--      same correction-deadline-guarded UPDATE, same ON CONFLICT DO NOTHING
--      INSERT, same EXCEPTION -> FAILED -> RAISE. The token stream of the
--      procedure body is identical to migration 226's; the only differences
--      are line wrapping in six name/column lists and one appended sentence
--      on COMMENT ON PROCEDURE recording the generator provenance. No
--      config.parameter_routing row is read at run time -- the routing table
--      is consumed only by the offline generator.
--
-- Deliberately NOT changed:
--   * quality_code stays NULL (NULL::SMALLINT in the loader) -- no quality
--     vocabulary is introduced here. Unchanged from migration 226.
--   * No historical backfill. config.parameter_routing is new; no telemetry
--     row is written or altered by this migration.
--   * No Space binding is created; metadata.space_points / metadata.spaces /
--     metadata.assets.space_id are untouched. Phase 3 behaviour is preserved
--     verbatim inside the generated body.
--   * telemetry.run_environment_routing_job / job 1012 -- untouched. The
--     procedure signature is unchanged so no re-registration is possible.
--   * The entire energy subsystem -- telemetry.load_energy_measurements_
--     incremental, telemetry.energy_measurements, config.energy_register_
--     semantics, telemetry.run_energy_routing_job / job 1001, every ca_energy_*
--     CAGG, every analytics.energy_consumption_*, analytics.demand_*. A
--     postcondition asserts the energy loader body does not reference
--     config.parameter_routing or space_id and still references its own
--     domain table.
--   * telemetry.v_environment_measurements_route / telemetry.
--     v_energy_measurements_route -- not referenced by this migration.
--
-- Rollback: postgres/maintenance/227_parameter_routing_foundation_rollback.sql
--   -- dependency-checked, no CASCADE, safe if this migration was never
--   applied. Restores the verbatim migration-226 loader body and drops
--   config.parameter_routing. Not run as part of this migration.
--
-- Transaction: the forward migration runner (scripts/apply_migrations.sh)
--   wraps this file in a single BEGIN/COMMIT with its ledger insert; this
--   file therefore contains no BEGIN/COMMIT of its own (matches migrations
--   223/224/225/226).
-- ============================================================================


-- ----------------------------------------------------------------------------
-- 1. config.parameter_routing -- declarative column-mapping layer.
--    Configuration table (no tenant column). One row per (profile, logical
--    point) that a domain routing loader pivots into a wide measurement
--    column. Consumed OFFLINE by scripts/codegen/generate_routing_procedure.py
--    -- never read at run time by any procedure.
-- ----------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS config.parameter_routing (
    id                     UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    profile_id             UUID NOT NULL REFERENCES config.device_profiles(id),
    logical_point_id       UUID NOT NULL REFERENCES metadata.logical_points(id),
    parameter_id           UUID REFERENCES config.parameters(id),
    destination_table      TEXT NOT NULL,
    destination_column     TEXT NOT NULL,
    value_transform        TEXT NOT NULL DEFAULT 'IDENTITY',
    legacy_source_aliases  TEXT[],
    is_active              BOOLEAN NOT NULL DEFAULT TRUE,
    created_at             TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at             TIMESTAMPTZ NOT NULL DEFAULT now(),

    CONSTRAINT uq_parameter_routing_point
        UNIQUE (profile_id, logical_point_id),
    CONSTRAINT uq_parameter_routing_destination
        UNIQUE (profile_id, destination_table, destination_column),
    CONSTRAINT ck_parameter_routing_destination_table
        CHECK (destination_table IN ('telemetry.environment_measurements')),
    CONSTRAINT ck_parameter_routing_value_transform
        CHECK (value_transform IN ('IDENTITY', 'DOUBLE_PRECISION', 'ROUND_INTEGER')),
    CONSTRAINT ck_parameter_routing_legacy_aliases_clean
        CHECK (
            legacy_source_aliases IS NULL
            OR (
                array_length(legacy_source_aliases, 1) >= 1
                AND array_position(legacy_source_aliases, NULL) IS NULL
                AND NOT ('' = ANY (legacy_source_aliases))
            )
        )
);

COMMENT ON TABLE config.parameter_routing IS
'Phase 4 (migration 227): declarative telemetry-routing column map. One row per (device profile, logical point) that a domain routing loader pivots into a wide measurement-table column. Consumed OFFLINE by scripts/codegen/generate_routing_procedure.py, which emits the CREATE OR REPLACE PROCEDURE body -- never read at run time. Not tenant-scoped: the generated procedure carries organization_id per row exactly as the hand-written one did.';
COMMENT ON COLUMN config.parameter_routing.parameter_id IS
'Optional link to the canonical config.parameters meaning (migration 223). NULL where the source logical point has no evidence-backed parameter mapping yet. Not required for routing; carried for semantic traceability and the future accounting-role rule.';
COMMENT ON COLUMN config.parameter_routing.value_transform IS
'How the pivoted numeric value is cast into the destination column: IDENTITY (no cast), DOUBLE_PRECISION (::DOUBLE PRECISION), ROUND_INTEGER (ROUND(...)::INTEGER). Not a formula/expression -- no arithmetic, no DSL.';
COMMENT ON COLUMN config.parameter_routing.legacy_source_aliases IS
'Pre-rename source names that the destination column''s pivot still accepts defensively (e.g. BATTERY_VOLTAGE before it was renamed DEVICE_BATTERY_VOLTAGE). Compatibility only: these are NOT metadata.logical_points rows, NOT config.parameters, and NOT separate config.parameter_routing rows.';

GRANT SELECT ON config.parameter_routing TO ems_app, ems_admin;


-- ----------------------------------------------------------------------------
-- 2. Seed the 12 genuine ENVIRONMENT_SENSOR_AIRSENSE_V1 routing mappings.
--    logical_point_id resolved by name (metadata.logical_points.name is the
--    portable identity -- migration 215); parameter_id resolved by
--    config.parameters.code via LEFT JOIN (6 mapped, 6 intentionally NULL).
--    The legacy bare name BATTERY_VOLTAGE is an alias on the
--    DEVICE_BATTERY_VOLTAGE row -- never its own row.
-- ----------------------------------------------------------------------------

INSERT INTO config.parameter_routing
    (profile_id, logical_point_id, parameter_id, destination_table,
     destination_column, value_transform, legacy_source_aliases)
SELECT
    dp.id,
    lp.id,
    p.id,
    'telemetry.environment_measurements',
    v.destination_column,
    v.value_transform,
    v.legacy_source_aliases
FROM (VALUES
    ('ENV_TEMPERATURE',                        'TEMPERATURE',                     'temperature_c',                'DOUBLE_PRECISION', NULL::text[]),
    ('ENV_RELATIVE_HUMIDITY',                  'HUMIDITY',                        'humidity_percent',             'DOUBLE_PRECISION', NULL),
    ('ENV_ILLUMINANCE_LUX',                    'ILLUMINANCE',                     'illuminance_lux',              'DOUBLE_PRECISION', NULL),
    ('DEVICE_BATTERY_VOLTAGE',                 'BATTERY_VOLTAGE',                 'battery_voltage_v',            'DOUBLE_PRECISION', ARRAY['BATTERY_VOLTAGE']),
    ('OCCUPANCY_ACTIVITY',                     'OCCUPANCY_ACTIVITY',              'occupancy_activity',           'DOUBLE_PRECISION', NULL),
    ('OCCUPANCY_SECONDS_SINCE_LAST_PIR_EVENT', 'OCCUPANCY_TIME_SINCE_LAST_EVENT', 'seconds_since_last_pir_event', 'ROUND_INTEGER',    NULL),
    ('PULSE_INPUT_1_RAW',                      NULL,                             'pulse_input_1_raw',            'DOUBLE_PRECISION', NULL),
    ('EXTERNAL_SENSOR_INPUT_1_RAW',            NULL,                             'external_input_1_raw',         'DOUBLE_PRECISION', NULL),
    ('EXTERNAL_SENSOR_INPUT_2_RAW',            NULL,                             'external_input_2_raw',         'DOUBLE_PRECISION', NULL),
    ('EXTERNAL_SENSOR_INPUT_3_RAW',            NULL,                             'external_input_3_raw',         'DOUBLE_PRECISION', NULL),
    ('EXTERNAL_SENSOR_INPUT_4_RAW',            NULL,                             'external_input_4_raw',         'DOUBLE_PRECISION', NULL),
    ('DEVICE_STATUS_CODE',                     NULL,                             'device_status_code',           'ROUND_INTEGER',    NULL)
) AS v(logical_point_name, parameter_code, destination_column, value_transform, legacy_source_aliases)
JOIN config.device_profiles dp ON dp.profile_code = 'ENVIRONMENT_SENSOR_AIRSENSE_V1'
JOIN metadata.logical_points lp ON lp.name = v.logical_point_name
LEFT JOIN config.parameters p ON p.code = v.parameter_code
ON CONFLICT (profile_id, logical_point_id) DO NOTHING;


-- ----------------------------------------------------------------------------
-- 3. Loader: body emitted by scripts/codegen/generate_routing_procedure.py
--    from config.parameter_routing (spec + template). Behaviourally identical
--    to the deployed migration-226 body (token-stream identical; only list
--    line-wrapping and one appended COMMENT sentence differ). Committed
--    generator output:
--    scripts/codegen/generated/load_environment_measurements_incremental.generated.sql
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
-- 4. Postconditions -- fail the transaction loudly on any drift from the
--    intended end state, per the migration 198/199/219/223/224/226 discipline.
-- ----------------------------------------------------------------------------

DO $$
DECLARE
    v_row_count   INTEGER;
    v_mapped      INTEGER;
    v_alias_rows  INTEGER;
    v_bad         TEXT[];
    v_env_body    TEXT;
    v_ener_body   TEXT;
BEGIN
    -- (a) table + key constraints present
    IF to_regclass('config.parameter_routing') IS NULL THEN
        RAISE EXCEPTION 'Migration 227 postcondition failed: config.parameter_routing was not created.';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'uq_parameter_routing_point'
                   AND conrelid = 'config.parameter_routing'::regclass) THEN
        RAISE EXCEPTION 'Migration 227 postcondition failed: uq_parameter_routing_point missing.';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'uq_parameter_routing_destination'
                   AND conrelid = 'config.parameter_routing'::regclass) THEN
        RAISE EXCEPTION 'Migration 227 postcondition failed: uq_parameter_routing_destination missing.';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'ck_parameter_routing_value_transform'
                   AND conrelid = 'config.parameter_routing'::regclass) THEN
        RAISE EXCEPTION 'Migration 227 postcondition failed: ck_parameter_routing_value_transform missing.';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'ck_parameter_routing_destination_table'
                   AND conrelid = 'config.parameter_routing'::regclass) THEN
        RAISE EXCEPTION 'Migration 227 postcondition failed: ck_parameter_routing_destination_table missing.';
    END IF;

    -- (b) exactly 12 active AirSense rows, all -> telemetry.environment_measurements
    SELECT count(*) INTO v_row_count
    FROM config.parameter_routing pr
    JOIN config.device_profiles dp ON dp.id = pr.profile_id
    WHERE dp.profile_code = 'ENVIRONMENT_SENSOR_AIRSENSE_V1';
    IF v_row_count <> 12 THEN
        RAISE EXCEPTION 'Migration 227 postcondition failed: expected 12 AirSense config.parameter_routing rows, found %.', v_row_count;
    END IF;
    IF EXISTS (SELECT 1 FROM config.parameter_routing WHERE NOT is_active
               OR destination_table <> 'telemetry.environment_measurements') THEN
        RAISE EXCEPTION 'Migration 227 postcondition failed: an AirSense routing row is inactive or points at the wrong table.';
    END IF;

    -- (c) the 12 (logical_point -> destination_column, value_transform) mappings are exactly as intended
    SELECT array_agg(want.lp_name ORDER BY want.lp_name) INTO v_bad
    FROM (VALUES
        ('ENV_TEMPERATURE','temperature_c','DOUBLE_PRECISION'),
        ('ENV_RELATIVE_HUMIDITY','humidity_percent','DOUBLE_PRECISION'),
        ('ENV_ILLUMINANCE_LUX','illuminance_lux','DOUBLE_PRECISION'),
        ('DEVICE_BATTERY_VOLTAGE','battery_voltage_v','DOUBLE_PRECISION'),
        ('OCCUPANCY_ACTIVITY','occupancy_activity','DOUBLE_PRECISION'),
        ('OCCUPANCY_SECONDS_SINCE_LAST_PIR_EVENT','seconds_since_last_pir_event','ROUND_INTEGER'),
        ('PULSE_INPUT_1_RAW','pulse_input_1_raw','DOUBLE_PRECISION'),
        ('EXTERNAL_SENSOR_INPUT_1_RAW','external_input_1_raw','DOUBLE_PRECISION'),
        ('EXTERNAL_SENSOR_INPUT_2_RAW','external_input_2_raw','DOUBLE_PRECISION'),
        ('EXTERNAL_SENSOR_INPUT_3_RAW','external_input_3_raw','DOUBLE_PRECISION'),
        ('EXTERNAL_SENSOR_INPUT_4_RAW','external_input_4_raw','DOUBLE_PRECISION'),
        ('DEVICE_STATUS_CODE','device_status_code','ROUND_INTEGER')
    ) AS want(lp_name, dcol, xf)
    JOIN metadata.logical_points lp ON lp.name = want.lp_name
    WHERE NOT EXISTS (
        SELECT 1 FROM config.parameter_routing pr
        WHERE pr.logical_point_id = lp.id
          AND pr.destination_column = want.dcol
          AND pr.value_transform = want.xf
    );
    IF v_bad IS NOT NULL THEN
        RAISE EXCEPTION 'Migration 227 postcondition failed: these logical points are not routed as intended: %.', v_bad;
    END IF;

    -- (d) exactly 6 rows carry a parameter_id (the evidence-backed AirSense mappings)
    SELECT count(*) INTO v_mapped FROM config.parameter_routing WHERE parameter_id IS NOT NULL;
    IF v_mapped <> 6 THEN
        RAISE EXCEPTION 'Migration 227 postcondition failed: expected 6 routing rows with a parameter_id, found %.', v_mapped;
    END IF;

    -- (e) the legacy alias appears on exactly one row, the DEVICE_BATTERY_VOLTAGE row, as {BATTERY_VOLTAGE}
    SELECT count(*) INTO v_alias_rows FROM config.parameter_routing WHERE legacy_source_aliases IS NOT NULL;
    IF v_alias_rows <> 1 THEN
        RAISE EXCEPTION 'Migration 227 postcondition failed: expected exactly 1 row with legacy_source_aliases, found %.', v_alias_rows;
    END IF;
    IF NOT EXISTS (
        SELECT 1 FROM config.parameter_routing pr
        JOIN metadata.logical_points lp ON lp.id = pr.logical_point_id
        WHERE lp.name = 'DEVICE_BATTERY_VOLTAGE'
          AND pr.legacy_source_aliases = ARRAY['BATTERY_VOLTAGE']
    ) THEN
        RAISE EXCEPTION 'Migration 227 postcondition failed: the BATTERY_VOLTAGE legacy alias is not on the DEVICE_BATTERY_VOLTAGE row.';
    END IF;
    -- BATTERY_VOLTAGE must NOT be a logical point or a routing row of its own
    IF EXISTS (SELECT 1 FROM metadata.logical_points WHERE name = 'BATTERY_VOLTAGE') THEN
        RAISE EXCEPTION 'Migration 227 postcondition failed: BATTERY_VOLTAGE unexpectedly exists as a metadata.logical_points row.';
    END IF;

    -- (f) the environment loader body: generated shape preserved
    v_env_body := pg_get_functiondef('telemetry.load_environment_measurements_incremental(interval,interval)'::regprocedure);
    IF position('metadata.space_points' IN v_env_body) = 0 THEN
        RAISE EXCEPTION 'Migration 227 postcondition failed: environment loader lost its Space resolution sub-select.';
    END IF;
    IF position('NULL::SMALLINT AS quality_code' IN v_env_body) = 0 THEN
        RAISE EXCEPTION 'Migration 227 postcondition failed: environment loader no longer writes quality_code = NULL.';
    END IF;
    IF position('CROSS JOIN LATERAL' IN v_env_body) = 0 OR position('OFFSET 0' IN v_env_body) = 0 THEN
        RAISE EXCEPTION 'Migration 227 postcondition failed: environment loader lost the parameterised LATERAL probe shape.';
    END IF;
    IF position('EXECUTE ' IN v_env_body) <> 0 OR position('format(' IN v_env_body) <> 0 THEN
        RAISE EXCEPTION 'Migration 227 postcondition failed: environment loader contains dynamic SQL (EXECUTE/format).';
    END IF;
    IF position('config.parameter_routing' IN v_env_body) <> 0 THEN
        RAISE EXCEPTION 'Migration 227 postcondition failed: environment loader reads config.parameter_routing at run time (must be generator-only).';
    END IF;
    IF position('ENV_TEMPERATURE' IN v_env_body) = 0 OR position('DEVICE_STATUS_CODE' IN v_env_body) = 0
       OR position('''BATTERY_VOLTAGE'',''DEVICE_BATTERY_VOLTAGE''' IN v_env_body) = 0 THEN
        RAISE EXCEPTION 'Migration 227 postcondition failed: environment loader is missing an expected routed name / legacy alias.';
    END IF;

    -- (g) energy safety: the energy loader was not touched by this migration
    v_ener_body := pg_get_functiondef('telemetry.load_energy_measurements_incremental(interval,interval)'::regprocedure);
    IF position('config.parameter_routing' IN v_ener_body) <> 0 THEN
        RAISE EXCEPTION 'Migration 227 postcondition failed: the energy loader references config.parameter_routing -- energy was touched.';
    END IF;
    IF position('space_id' IN v_ener_body) <> 0 THEN
        RAISE EXCEPTION 'Migration 227 postcondition failed: the energy loader references space_id -- energy was touched.';
    END IF;
    IF position('telemetry.energy_measurements' IN v_ener_body) = 0 THEN
        RAISE EXCEPTION 'Migration 227 postcondition failed: the energy loader no longer references telemetry.energy_measurements.';
    END IF;

    -- (h) routing jobs unchanged (signatures intact -> no re-registration possible)
    IF to_regprocedure('telemetry.run_environment_routing_job(integer,jsonb)') IS NULL THEN
        RAISE EXCEPTION 'Migration 227 postcondition failed: telemetry.run_environment_routing_job(integer,jsonb) is missing.';
    END IF;
    IF to_regprocedure('telemetry.run_energy_routing_job(integer,jsonb)') IS NULL THEN
        RAISE EXCEPTION 'Migration 227 postcondition failed: telemetry.run_energy_routing_job(integer,jsonb) is missing.';
    END IF;
END;
$$;
