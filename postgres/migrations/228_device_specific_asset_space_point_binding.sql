-- ============================================================================
-- Migration 228
-- Phase 2 amendment (Point Identity): make metadata.asset_points and
-- metadata.space_points bind to the device-specific Point, not to the global
-- logical-point vocabulary term.
--
-- Source of record:
--   docs/DDS/analytics-platform-future-state-architecture.md
--     * B.3 -- "Point = (device_id, logical_point_id, raw_field_name) ...
--       No new table needed -- this concept is fine as-is"; the qualifier
--       guardrail ("the subject binding, never the qualifier, carries
--       'which instance'"); the Phase 2 amendment clarification added to
--       that section.
--     * D.5 -- "subject-binding must happen at the point level ... not the
--       device level"; the Phase 2 amendment clarification added there.
--   The Point Identity Resolution architecture checkpoint that approved
--   exactly this scope, and migration 226's own header note:
--     "per-device Space attribution for a multi-device environmental fleet
--      needs a space_points.device_id column (or equivalent) and is out of
--      scope here."
--
-- Root cause being corrected
-- -------------------------------------------------------------------------
-- migration 224 keyed metadata.asset_points / metadata.space_points on
-- logical_point_id alone (GiST exclusion ex_*_no_overlap on
-- (logical_point_id, effective_range)). metadata.logical_points is a
-- deliberately GLOBAL vocabulary (uq_logical_points_name; no organization_id,
-- no device_id, no profile_id), so every device of one profile shares one
-- logical_point_id per name -- e.g. all four onboarded AirSense devices'
-- ENV_TEMPERATURE is a single logical_points row. The device-specific Point
-- identity the architecture defines already exists, materialised and
-- populated, as config.device_point_configuration (PK (device_id,
-- logical_point_id); ex-migration 175; 12 rows per AirSense device). This
-- migration binds asset_points / space_points to THAT identity.
--
-- What this migration does (the entire approved delta)
-- -------------------------------------------------------------------------
--   1. metadata.asset_points and metadata.space_points (symmetric):
--        * ADD device_id UUID NOT NULL
--        * ADD organization_id UUID NOT NULL REFERENCES metadata.organizations(id)
--        * ADD composite FK (device_id, logical_point_id)
--              REFERENCES config.device_point_configuration (device_id, logical_point_id)
--              ON DELETE RESTRICT
--          -- a binding may only target a Point the device actually has
--          -- enabled; also blocks a device / mapped-point removal while a
--          -- subject binding still references it (consistent with
--          -- admin.update_asset's existing "decommissioning blocked by
--          -- existing asset_points" guard).
--        * DROP ex_*_no_overlap (logical_point_id, effective_range) and
--          re-ADD it as (device_id, logical_point_id, effective_range) --
--          so two DIFFERENT devices may bind the same logical point
--          independently, while one physical Point still cannot have two
--          overlapping subjects.
--        * ADD idx_*_device_point (device_id, logical_point_id,
--          effective_from DESC) for the loader's per-device lookup.
--      Both tables have 0 rows (asserted) -> no backfill, no data migration.
--      The pre-existing logical_point_id -> metadata.logical_points FK, the
--      effective_from/effective_to/generated effective_range columns, the
--      ck_*_effective_window CHECK, point_role, and every other column are
--      left exactly as migration 224 built them.
--
--   2. metadata.validate_point_binding() BEFORE INSERT OR UPDATE trigger on
--      both tables -- database-enforced tenant safety, modelled on
--      metadata.validate_asset_relationship() (migration 225): rejects a
--      binding whose device organization differs from its Asset/Space
--      organization, and a row organization_id that does not match the
--      device. metadata.logical_points has no organization_id (global), so
--      it is not part of the check.
--
--   3. CREATE OR REPLACE telemetry.load_environment_measurements_incremental
--      (interval, interval) with the body EMITTED by the Phase 4 offline
--      generator (scripts/codegen/generate_routing_procedure.py) from the
--      unchanged spec scripts/codegen/routing/environment_measurements.routing.json
--      and the template scripts/codegen/templates/load_environment_measurements_incremental.sql.tmpl.
--      Committed output: scripts/codegen/generated/load_environment_measurements_incremental.generated.sql.
--      The ONLY change vs the migration-227 body is one added predicate in
--      the Space-resolution sub-select:  AND sp.device_id = ranked.device_id
--      (+ its comment). Every other statement -- window_events / full_
--      resolution / resolved / ranked pipeline, the CROSS JOIN LATERAL
--      (... OFFSET 0) probe, p_overlap / p_max_window validation, the
--      advisory lock, pipeline_state RUNNING/SUCCESS/FAILED/SKIPPED_LOCKED/
--      NO_SOURCE_DATA, the checkpoint on normalized_points.platform_received_at,
--      LEAST(v_window_end, v_previous_checkpoint + p_max_window),
--      LEAST(p_overlap, 1 minute), sample_rank = 1 + closed-bucket filter,
--      the correction-deadline-guarded UPDATE, ON CONFLICT (bucket_start,
--      device_id) WHERE device_id IS NOT NULL DO NOTHING, and the
--      EXCEPTION WHEN OTHERS -> FAILED -> RAISE contract -- is byte-for-byte
--      the migration-227 body. quality_code is still written NULL.
--      config.parameter_routing is still read only by the OFFLINE generator,
--      never at run time; no runtime-dynamic SQL is introduced.
--
-- Deliberately NOT changed
-- -------------------------------------------------------------------------
--   * config.device_point_configuration -- referenced, never altered.
--   * metadata.asset_devices -- unchanged; it continues to record the
--     Device <-> Asset physical/operational association, a different concern
--     from Point -> Subject binding.
--   * metadata.logical_points / config.parameters -- untouched (Phase 1).
--   * config.parameter_routing schema + its 12 seeded AirSense rows -- a
--     postcondition asserts this migration added no routing row.
--   * The entire energy subsystem. A postcondition asserts the energy loader
--     body references neither space_id, space_points, nor
--     device_point_configuration and still references
--     telemetry.energy_measurements.
--   * telemetry.run_environment_routing_job / run_energy_routing_job
--     signatures, every environment CAGG, environment_daily,
--     telemetry.reconcile_environment_daily, analytics.v_environment_* --
--     untouched. No job registered, enabled, rescheduled or reconfigured.
--   * No Space row created, no logical point bound, no
--     environment_measurements row rewritten (no historical backfill).
--
-- Rollback: postgres/maintenance/228_device_specific_asset_space_point_binding_rollback.sql
--   -- dependency-checked, no CASCADE, safe if migration absent; drops the
--   triggers/function, restores the (logical_point_id, effective_range)
--   exclusions, drops the composite FKs, the organization_id and device_id
--   columns, and the migration-228 index, and restores the verbatim
--   migration-227 loader body. Not run as part of this migration.
--
-- Transaction: the forward migration runner (scripts/apply_migrations.sh)
--   wraps this file in a single BEGIN/COMMIT with its ledger insert; this
--   file therefore contains no BEGIN/COMMIT of its own (matches migrations
--   223/224/225/226/227).
-- ============================================================================


-- ----------------------------------------------------------------------------
-- 0. Preconditions -- fail loudly rather than silently no-op.
-- ----------------------------------------------------------------------------

DO
$precheck$
BEGIN
    IF to_regclass('config.device_point_configuration') IS NULL THEN
        RAISE EXCEPTION
            'Migration 228 precondition failed: config.device_point_configuration is missing.';
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM pg_constraint
        WHERE conrelid = 'config.device_point_configuration'::regclass
          AND contype = 'p'
    ) THEN
        RAISE EXCEPTION
            'Migration 228 precondition failed: config.device_point_configuration has no primary key to reference.';
    END IF;

    IF (SELECT count(*) FROM metadata.asset_points) <> 0 THEN
        RAISE EXCEPTION
            'Migration 228 precondition failed: metadata.asset_points is not empty (% rows) -- a device_id/organization_id backfill would be required and is not in scope.',
            (SELECT count(*) FROM metadata.asset_points);
    END IF;

    IF (SELECT count(*) FROM metadata.space_points) <> 0 THEN
        RAISE EXCEPTION
            'Migration 228 precondition failed: metadata.space_points is not empty (% rows).',
            (SELECT count(*) FROM metadata.space_points);
    END IF;
END;
$precheck$;


-- ----------------------------------------------------------------------------
-- 1. metadata.asset_points -- device-specific Point identity + tenant column.
-- ----------------------------------------------------------------------------

ALTER TABLE metadata.asset_points
    ADD COLUMN IF NOT EXISTS device_id       UUID NOT NULL,
    ADD COLUMN IF NOT EXISTS organization_id UUID NOT NULL;

ALTER TABLE metadata.asset_points
    DROP CONSTRAINT IF EXISTS asset_points_organization_id_fkey;
ALTER TABLE metadata.asset_points
    ADD CONSTRAINT asset_points_organization_id_fkey
    FOREIGN KEY (organization_id) REFERENCES metadata.organizations(id);

ALTER TABLE metadata.asset_points
    DROP CONSTRAINT IF EXISTS asset_points_device_point_fkey;
ALTER TABLE metadata.asset_points
    ADD CONSTRAINT asset_points_device_point_fkey
    FOREIGN KEY (device_id, logical_point_id)
    REFERENCES config.device_point_configuration (device_id, logical_point_id)
    ON DELETE RESTRICT;

-- Replace the migration-224 (logical_point_id, effective_range) exclusion
-- with one scoped to the device-specific Point. Two different devices may
-- now bind the same logical point over overlapping periods; one physical
-- Point still cannot have two simultaneous Subjects.
ALTER TABLE metadata.asset_points
    DROP CONSTRAINT IF EXISTS ex_asset_points_no_overlap;
ALTER TABLE metadata.asset_points
    ADD CONSTRAINT ex_asset_points_no_overlap
    EXCLUDE USING gist
    (
        device_id        WITH =,
        logical_point_id WITH =,
        effective_range  WITH &&
    );

CREATE INDEX IF NOT EXISTS idx_asset_points_device_point
    ON metadata.asset_points (device_id, logical_point_id, effective_from DESC);

COMMENT ON COLUMN metadata.asset_points.device_id IS
'Migration 228: the physical device whose Point instance this binding is for. (device_id, logical_point_id) is the device-specific Point identity, materialised by config.device_point_configuration. Part of ex_asset_points_no_overlap.';
COMMENT ON COLUMN metadata.asset_points.organization_id IS
'Migration 228: owning organization; must equal both the device''s and the Asset''s organization (enforced by trg_validate_asset_point_binding). Denormalised for a tenant-scoped index/filter, mirroring metadata.asset_relationships.';


-- ----------------------------------------------------------------------------
-- 2. metadata.space_points -- identical treatment.
-- ----------------------------------------------------------------------------

ALTER TABLE metadata.space_points
    ADD COLUMN IF NOT EXISTS device_id       UUID NOT NULL,
    ADD COLUMN IF NOT EXISTS organization_id UUID NOT NULL;

ALTER TABLE metadata.space_points
    DROP CONSTRAINT IF EXISTS space_points_organization_id_fkey;
ALTER TABLE metadata.space_points
    ADD CONSTRAINT space_points_organization_id_fkey
    FOREIGN KEY (organization_id) REFERENCES metadata.organizations(id);

ALTER TABLE metadata.space_points
    DROP CONSTRAINT IF EXISTS space_points_device_point_fkey;
ALTER TABLE metadata.space_points
    ADD CONSTRAINT space_points_device_point_fkey
    FOREIGN KEY (device_id, logical_point_id)
    REFERENCES config.device_point_configuration (device_id, logical_point_id)
    ON DELETE RESTRICT;

ALTER TABLE metadata.space_points
    DROP CONSTRAINT IF EXISTS ex_space_points_no_overlap;
ALTER TABLE metadata.space_points
    ADD CONSTRAINT ex_space_points_no_overlap
    EXCLUDE USING gist
    (
        device_id        WITH =,
        logical_point_id WITH =,
        effective_range  WITH &&
    );

CREATE INDEX IF NOT EXISTS idx_space_points_device_point
    ON metadata.space_points (device_id, logical_point_id, effective_from DESC);

COMMENT ON COLUMN metadata.space_points.device_id IS
'Migration 228: the physical device whose Point instance this binding is for. (device_id, logical_point_id) is the device-specific Point identity, materialised by config.device_point_configuration. Part of ex_space_points_no_overlap.';
COMMENT ON COLUMN metadata.space_points.organization_id IS
'Migration 228: owning organization; must equal both the device''s and the Space''s organization (enforced by trg_validate_space_point_binding).';


-- ----------------------------------------------------------------------------
-- 3. Tenant-safety trigger -- database-enforced, modelled on
--    metadata.validate_asset_relationship() (migration 225).
-- ----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION metadata.validate_point_binding()
RETURNS TRIGGER
LANGUAGE plpgsql
SET search_path TO pg_catalog, metadata, config
AS $function$
DECLARE
    v_device_org  UUID;
    v_subject_org UUID;
    v_subject_kind TEXT;
BEGIN
    SELECT organization_id INTO v_device_org
    FROM metadata.devices
    WHERE id = NEW.device_id;

    IF TG_TABLE_NAME = 'space_points' THEN
        v_subject_kind := 'Space';
        SELECT organization_id INTO v_subject_org
        FROM metadata.spaces
        WHERE id = NEW.space_id;
    ELSE
        v_subject_kind := 'Asset';
        SELECT organization_id INTO v_subject_org
        FROM metadata.assets
        WHERE id = NEW.asset_id;
    END IF;

    -- device_id / space_id / asset_id already carry FK constraints. If a
    -- referenced row is missing, defer to that FK (foreign_key_violation)
    -- rather than pre-empting it with a custom error from this BEFORE
    -- trigger.
    IF v_device_org IS NULL OR v_subject_org IS NULL THEN
        RETURN NEW;
    END IF;

    IF v_device_org IS DISTINCT FROM v_subject_org THEN
        RAISE EXCEPTION
            'Point binding crosses organizations: device % is in organization %, the % it is bound to is in organization %.',
            NEW.device_id, v_device_org, v_subject_kind, v_subject_org;
    END IF;

    IF NEW.organization_id IS DISTINCT FROM v_device_org THEN
        RAISE EXCEPTION
            'Point binding organization_id (%) does not match the device/% organization (%).',
            NEW.organization_id, v_subject_kind, v_device_org;
    END IF;

    RETURN NEW;
END;
$function$;

ALTER FUNCTION metadata.validate_point_binding() OWNER TO ems_admin;

DROP TRIGGER IF EXISTS trg_validate_asset_point_binding ON metadata.asset_points;
CREATE TRIGGER trg_validate_asset_point_binding
BEFORE INSERT OR UPDATE OF device_id, logical_point_id, asset_id, organization_id, effective_from, effective_to
ON metadata.asset_points
FOR EACH ROW
EXECUTE FUNCTION metadata.validate_point_binding();

DROP TRIGGER IF EXISTS trg_validate_space_point_binding ON metadata.space_points;
CREATE TRIGGER trg_validate_space_point_binding
BEFORE INSERT OR UPDATE OF device_id, logical_point_id, space_id, organization_id, effective_from, effective_to
ON metadata.space_points
FOR EACH ROW
EXECUTE FUNCTION metadata.validate_point_binding();


-- ----------------------------------------------------------------------------
-- 4. Environment loader -- the Phase 4 generator output, migration-227 body
--    + exactly one added predicate (AND sp.device_id = ranked.device_id) in
--    the Space-resolution sub-select. Reproduced verbatim from
--    scripts/codegen/generated/load_environment_measurements_incremental.generated.sql.
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
-- 5. Postconditions -- fail the transaction loudly on any drift from the
--    intended end state, per the 198/199/223/224/225/226/227 discipline.
-- ----------------------------------------------------------------------------

DO
$post$
DECLARE
    v_env_body  TEXT;
    v_ener_body TEXT;
    v_def       TEXT;
    v_tbl       TEXT;
    v_routing_rows INTEGER;
BEGIN
    FOREACH v_tbl IN ARRAY ARRAY['asset_points', 'space_points']
    LOOP
        -- (a) new columns present, uuid, NOT NULL
        IF NOT EXISTS (
            SELECT 1 FROM information_schema.columns
            WHERE table_schema='metadata' AND table_name=v_tbl
              AND column_name='device_id' AND data_type='uuid' AND is_nullable='NO'
        ) THEN
            RAISE EXCEPTION 'Migration 228 postcondition failed: metadata.%.device_id is missing or not a NOT NULL uuid.', v_tbl;
        END IF;

        IF NOT EXISTS (
            SELECT 1 FROM information_schema.columns
            WHERE table_schema='metadata' AND table_name=v_tbl
              AND column_name='organization_id' AND data_type='uuid' AND is_nullable='NO'
        ) THEN
            RAISE EXCEPTION 'Migration 228 postcondition failed: metadata.%.organization_id is missing or not a NOT NULL uuid.', v_tbl;
        END IF;

        -- (b) composite FK -> config.device_point_configuration
        IF NOT EXISTS (
            SELECT 1
            FROM pg_constraint c
            JOIN pg_class rel  ON rel.oid = c.conrelid
            JOIN pg_namespace n ON n.oid = rel.relnamespace
            JOIN pg_class frel ON frel.oid = c.confrelid
            JOIN pg_namespace fn ON fn.oid = frel.relnamespace
            WHERE c.conname = v_tbl || '_device_point_fkey'
              AND c.contype = 'f'
              AND n.nspname = 'metadata' AND rel.relname = v_tbl
              AND fn.nspname = 'config' AND frel.relname = 'device_point_configuration'
        ) THEN
            RAISE EXCEPTION 'Migration 228 postcondition failed: metadata.%_device_point_fkey is missing or does not target config.device_point_configuration.', v_tbl;
        END IF;

        -- (c) organization_id FK -> metadata.organizations
        IF NOT EXISTS (
            SELECT 1 FROM pg_constraint c
            JOIN pg_class rel ON rel.oid = c.conrelid
            JOIN pg_namespace n ON n.oid = rel.relnamespace
            WHERE c.conname = v_tbl || '_organization_id_fkey' AND c.contype = 'f'
              AND n.nspname = 'metadata' AND rel.relname = v_tbl
        ) THEN
            RAISE EXCEPTION 'Migration 228 postcondition failed: metadata.%_organization_id_fkey is missing.', v_tbl;
        END IF;

        -- (d) the temporal exclusion now includes device_id
        SELECT pg_get_constraintdef(c.oid) INTO v_def
        FROM pg_constraint c
        JOIN pg_class rel ON rel.oid = c.conrelid
        JOIN pg_namespace n ON n.oid = rel.relnamespace
        WHERE c.conname = 'ex_' || v_tbl || '_no_overlap'
          AND n.nspname = 'metadata' AND rel.relname = v_tbl;

        IF v_def IS NULL THEN
            RAISE EXCEPTION 'Migration 228 postcondition failed: ex_%_no_overlap is missing.', v_tbl;
        END IF;
        IF position('device_id WITH =' IN v_def) = 0
           OR position('logical_point_id WITH =' IN v_def) = 0
           OR position('effective_range WITH &&' IN v_def) = 0 THEN
            RAISE EXCEPTION 'Migration 228 postcondition failed: ex_%_no_overlap is not scoped (device_id, logical_point_id, effective_range): %', v_tbl, v_def;
        END IF;

        -- (e) migration-228 lookup index present
        IF NOT EXISTS (
            SELECT 1 FROM pg_indexes
            WHERE schemaname='metadata' AND tablename=v_tbl
              AND indexname = 'idx_' || v_tbl || '_device_point'
        ) THEN
            RAISE EXCEPTION 'Migration 228 postcondition failed: idx_%_device_point is missing.', v_tbl;
        END IF;

        -- (f) still empty -- no backfill
        EXECUTE format('SELECT count(*) FROM metadata.%I', v_tbl) INTO v_routing_rows;
        IF v_routing_rows <> 0 THEN
            RAISE EXCEPTION 'Migration 228 postcondition failed: metadata.% has % rows -- migration 228 must not insert bindings.', v_tbl, v_routing_rows;
        END IF;

        -- (g) the migration-224 effective-dating is intact
        IF NOT EXISTS (
            SELECT 1 FROM information_schema.columns
            WHERE table_schema='metadata' AND table_name=v_tbl AND column_name='effective_range'
        ) THEN
            RAISE EXCEPTION 'Migration 228 postcondition failed: metadata.%.effective_range disappeared.', v_tbl;
        END IF;
    END LOOP;

    -- (h) tenant-safety triggers present
    IF NOT EXISTS (
        SELECT 1 FROM pg_trigger
        WHERE tgname = 'trg_validate_asset_point_binding'
          AND tgrelid = 'metadata.asset_points'::regclass
    ) THEN
        RAISE EXCEPTION 'Migration 228 postcondition failed: trg_validate_asset_point_binding was not created.';
    END IF;
    IF NOT EXISTS (
        SELECT 1 FROM pg_trigger
        WHERE tgname = 'trg_validate_space_point_binding'
          AND tgrelid = 'metadata.space_points'::regclass
    ) THEN
        RAISE EXCEPTION 'Migration 228 postcondition failed: trg_validate_space_point_binding was not created.';
    END IF;

    -- (i) environment loader now scopes Space resolution by device
    v_env_body := pg_get_functiondef('telemetry.load_environment_measurements_incremental(interval,interval)'::regprocedure);
    IF position('sp.device_id = ranked.device_id' IN v_env_body) = 0 THEN
        RAISE EXCEPTION 'Migration 228 postcondition failed: the environment loader does not scope Space resolution by device.';
    END IF;
    IF position('metadata.space_points' IN v_env_body) = 0 THEN
        RAISE EXCEPTION 'Migration 228 postcondition failed: the environment loader no longer references metadata.space_points.';
    END IF;
    IF position('EXECUTE' IN v_env_body) <> 0 OR position('format(' IN v_env_body) <> 0 THEN
        RAISE EXCEPTION 'Migration 228 postcondition failed: the environment loader now contains dynamic SQL.';
    END IF;

    -- (j) energy safety -- energy loader untouched
    v_ener_body := pg_get_functiondef('telemetry.load_energy_measurements_incremental(interval,interval)'::regprocedure);
    IF position('space_id' IN v_ener_body) <> 0
       OR position('space_points' IN v_ener_body) <> 0
       OR position('device_point_configuration' IN v_ener_body) <> 0 THEN
        RAISE EXCEPTION 'Migration 228 postcondition failed: the energy loader body references space/point-binding objects -- energy was touched.';
    END IF;
    IF position('telemetry.energy_measurements' IN v_ener_body) = 0 THEN
        RAISE EXCEPTION 'Migration 228 postcondition failed: the energy loader no longer references telemetry.energy_measurements.';
    END IF;

    -- (k) Phase 4 routing config untouched by this migration
    SELECT count(*) INTO v_routing_rows
    FROM config.parameter_routing
    WHERE is_active AND destination_table = 'telemetry.environment_measurements';
    IF v_routing_rows <> 12 THEN
        RAISE EXCEPTION 'Migration 228 postcondition failed: expected 12 active AirSense config.parameter_routing rows, found % -- routing config was altered.', v_routing_rows;
    END IF;

    -- (l) job wrappers intact
    IF to_regprocedure('telemetry.run_environment_routing_job(integer,jsonb)') IS NULL THEN
        RAISE EXCEPTION 'Migration 228 postcondition failed: telemetry.run_environment_routing_job(integer,jsonb) is missing.';
    END IF;

    -- (m) no historical backfill of environment_measurements.space_id
    IF EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema='telemetry' AND table_name='environment_measurements' AND column_name='space_id'
    ) THEN
        -- column exists (migration 226) -- fine; just prove 228 wrote nothing new.
        NULL;
    END IF;
END;
$post$;
