-- ============================================================================
-- File:
--   scripts/test/assert_parameter_routing_foundation.sql
--
-- Purpose:
--   Regression / acceptance test for migration 227 (Phase 4 -- declarative
--   parameter routing foundation, proven on AirSense / environmental sensing).
--   Migration 227 adds config.parameter_routing and CREATE OR REPLACEs
--   telemetry.load_environment_measurements_incremental(interval, interval)
--   with a body EMITTED by the offline generator
--   scripts/codegen/generate_routing_procedure.py from config.parameter_routing.
--
--   Contracts proved, all against a synthetic, rollback-only fixture:
--     1.  config.parameter_routing exists with the expected columns, PK, the
--         two UNIQUE constraints, the three CHECK constraints, three FKs, and
--         GRANT SELECT to ems_app.
--     2.  Exactly the 12 genuine ENVIRONMENT_SENSOR_AIRSENSE_V1 mappings are
--         seeded, all active, all -> telemetry.environment_measurements, each
--         (logical_point -> destination_column, value_transform) exactly as
--         intended.
--     3.  parameter_id: exactly 6 rows carry one, each equal to the
--         config.parameters row for the intended code (migration 223).
--     4.  Legacy alias: exactly one row (DEVICE_BATTERY_VOLTAGE) carries
--         legacy_source_aliases = {BATTERY_VOLTAGE}; BATTERY_VOLTAGE is NOT a
--         metadata.logical_points row and NOT its own routing row.
--     5.  Duplicate / ambiguous / malformed routing rows are rejected by the
--         DB (unique + check violations).
--     6.  Tenant safety: config.parameter_routing has no organization_id;
--         ems_app has SELECT but not INSERT / UPDATE / DELETE; the generated
--         loader keeps organization_id per row and the org-guarded Space
--         sub-select.
--     7.  Generated routing integrity: the env loader body carries the
--         BATTERY_VOLTAGE legacy alias, the parameterised LATERAL probe
--         (CROSS JOIN LATERAL ... OFFSET 0, MATERIALIZED), no EXECUTE /
--         format( (no runtime-dynamic SQL), and does NOT read
--         config.parameter_routing at run time.
--     8.  Target-column mapping: a real AirSense device emitting all 12
--         canonical points routes each value into the intended column with
--         the intended cast (ROUND(...)::INTEGER for
--         seconds_since_last_pir_event and device_status_code; ::DOUBLE
--         PRECISION otherwise); a reading published under the legacy name
--         BATTERY_VOLTAGE still lands in battery_voltage_v.
--     9.  Space behaviour preserved: with no binding the routed row's
--         space_id is NULL (the full Space matrix is in
--         assert_environment_space_binding.sql, re-run unchanged against this
--         same generated procedure).
--    10.  quality_code is written NULL (no quality vocabulary introduced).
--    11.  Idempotency: re-running the same bounded window changes nothing.
--    12.  Bounded watermark: p_max_window still caps the checkpoint at
--         previous_checkpoint + window; NULL still advances to the true max.
--    13.  Energy safety: the energy loader body references neither
--         config.parameter_routing nor space_id and still targets
--         telemetry.energy_measurements.
--    14.  Gate B -- generated / migration-226 behavioural parity: the same
--         fixture routed through the generated loader and through the
--         verbatim migration-226 loader body produces byte-identical
--         telemetry.environment_measurements rows (EXCEPT both ways is empty).
--
--   Everything runs inside BEGIN; ... ROLLBACK; -- no fixture data and no
--   shared telemetry.pipeline_state change persists.
--
-- Failure behavior:
--   Any assertion raises; ON_ERROR_STOP=1 in the .sh wrapper fails the runner.
-- ============================================================================

BEGIN;

-- ----------------------------------------------------------------------------
-- Part 1 -- structural + content contracts (1-4, 7, 13).
-- ----------------------------------------------------------------------------
DO $struct$
DECLARE
    v_n    INTEGER;
    v_bad  TEXT[];
    v_ener TEXT;
    v_env  TEXT;
BEGIN
    IF to_regclass('config.parameter_routing') IS NULL THEN
        RAISE EXCEPTION 'C1 FAILED: config.parameter_routing does not exist.';
    END IF;
    IF EXISTS (SELECT 1 FROM information_schema.columns
               WHERE table_schema='config' AND table_name='parameter_routing'
                 AND column_name='organization_id') THEN
        RAISE EXCEPTION 'C1/C6 FAILED: config.parameter_routing unexpectedly has an organization_id column.';
    END IF;
    IF EXISTS (
        SELECT 1 FROM (VALUES
            ('id'),('profile_id'),('logical_point_id'),('parameter_id'),
            ('destination_table'),('destination_column'),('value_transform'),
            ('legacy_source_aliases'),('is_active'),('created_at'),('updated_at')
        ) AS c(name)
        WHERE NOT EXISTS (SELECT 1 FROM information_schema.columns
                          WHERE table_schema='config' AND table_name='parameter_routing'
                            AND column_name=c.name)
    ) THEN
        RAISE EXCEPTION 'C1 FAILED: config.parameter_routing is missing an expected column.';
    END IF;

    IF EXISTS (
        SELECT 1 FROM (VALUES
            ('uq_parameter_routing_point'),
            ('uq_parameter_routing_destination'),
            ('ck_parameter_routing_destination_table'),
            ('ck_parameter_routing_value_transform'),
            ('ck_parameter_routing_legacy_aliases_clean')
        ) AS k(name)
        WHERE NOT EXISTS (SELECT 1 FROM pg_constraint
                          WHERE conrelid='config.parameter_routing'::regclass AND conname=k.name)
    ) THEN
        RAISE EXCEPTION 'C1 FAILED: config.parameter_routing is missing an expected constraint.';
    END IF;
    IF (SELECT count(*) FROM pg_constraint
        WHERE conrelid='config.parameter_routing'::regclass AND contype='f') <> 3 THEN
        RAISE EXCEPTION 'C1 FAILED: expected 3 FOREIGN KEY constraints on config.parameter_routing.';
    END IF;

    IF NOT has_table_privilege('ems_app', 'config.parameter_routing', 'SELECT') THEN
        RAISE EXCEPTION 'C1/C6 FAILED: ems_app cannot SELECT config.parameter_routing.';
    END IF;
    IF has_table_privilege('ems_app', 'config.parameter_routing', 'INSERT')
       OR has_table_privilege('ems_app', 'config.parameter_routing', 'UPDATE')
       OR has_table_privilege('ems_app', 'config.parameter_routing', 'DELETE') THEN
        RAISE EXCEPTION 'C6 FAILED: ems_app has a write privilege on config.parameter_routing.';
    END IF;

    SELECT count(*) INTO v_n
    FROM config.parameter_routing pr
    JOIN config.device_profiles dp ON dp.id=pr.profile_id
    WHERE dp.profile_code='ENVIRONMENT_SENSOR_AIRSENSE_V1';
    IF v_n <> 12 THEN
        RAISE EXCEPTION 'C2 FAILED: expected 12 AirSense routing rows, found %.', v_n;
    END IF;
    IF EXISTS (SELECT 1 FROM config.parameter_routing
               WHERE NOT is_active OR destination_table <> 'telemetry.environment_measurements') THEN
        RAISE EXCEPTION 'C2 FAILED: an AirSense routing row is inactive or mis-targeted.';
    END IF;

    SELECT array_agg(want.lp ORDER BY want.lp) INTO v_bad
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
    ) AS want(lp, dcol, xf)
    JOIN metadata.logical_points lp ON lp.name=want.lp
    WHERE NOT EXISTS (
        SELECT 1 FROM config.parameter_routing pr
        WHERE pr.logical_point_id=lp.id AND pr.destination_column=want.dcol AND pr.value_transform=want.xf
    );
    IF v_bad IS NOT NULL THEN
        RAISE EXCEPTION 'C2 FAILED: mappings not as intended for: %.', v_bad;
    END IF;

    SELECT count(*) INTO v_n FROM config.parameter_routing WHERE parameter_id IS NOT NULL;
    IF v_n <> 6 THEN
        RAISE EXCEPTION 'C3 FAILED: expected 6 routing rows with a parameter_id, found %.', v_n;
    END IF;
    SELECT array_agg(want.lp ORDER BY want.lp) INTO v_bad
    FROM (VALUES
        ('ENV_TEMPERATURE','TEMPERATURE'),
        ('ENV_RELATIVE_HUMIDITY','HUMIDITY'),
        ('ENV_ILLUMINANCE_LUX','ILLUMINANCE'),
        ('DEVICE_BATTERY_VOLTAGE','BATTERY_VOLTAGE'),
        ('OCCUPANCY_ACTIVITY','OCCUPANCY_ACTIVITY'),
        ('OCCUPANCY_SECONDS_SINCE_LAST_PIR_EVENT','OCCUPANCY_TIME_SINCE_LAST_EVENT')
    ) AS want(lp, pcode)
    JOIN metadata.logical_points lp ON lp.name=want.lp
    JOIN config.parameters p ON p.code=want.pcode
    WHERE NOT EXISTS (
        SELECT 1 FROM config.parameter_routing pr
        WHERE pr.logical_point_id=lp.id AND pr.parameter_id=p.id
    );
    IF v_bad IS NOT NULL THEN
        RAISE EXCEPTION 'C3 FAILED: parameter_id not correct for: %.', v_bad;
    END IF;

    SELECT count(*) INTO v_n FROM config.parameter_routing WHERE legacy_source_aliases IS NOT NULL;
    IF v_n <> 1 THEN
        RAISE EXCEPTION 'C4 FAILED: expected exactly 1 row with legacy_source_aliases, found %.', v_n;
    END IF;
    IF NOT EXISTS (
        SELECT 1 FROM config.parameter_routing pr
        JOIN metadata.logical_points lp ON lp.id=pr.logical_point_id
        WHERE lp.name='DEVICE_BATTERY_VOLTAGE' AND pr.legacy_source_aliases=ARRAY['BATTERY_VOLTAGE']
    ) THEN
        RAISE EXCEPTION 'C4 FAILED: the BATTERY_VOLTAGE alias is not on the DEVICE_BATTERY_VOLTAGE row.';
    END IF;
    IF EXISTS (SELECT 1 FROM metadata.logical_points WHERE name='BATTERY_VOLTAGE') THEN
        RAISE EXCEPTION 'C4 FAILED: BATTERY_VOLTAGE exists as a metadata.logical_points row (must not).';
    END IF;

    v_env := pg_get_functiondef('telemetry.load_environment_measurements_incremental(interval,interval)'::regprocedure);
    IF position('''BATTERY_VOLTAGE'',''DEVICE_BATTERY_VOLTAGE''' IN v_env) = 0 THEN
        RAISE EXCEPTION 'C7 FAILED: env loader lost the BATTERY_VOLTAGE legacy compatibility alias.';
    END IF;
    IF position('CROSS JOIN LATERAL' IN v_env)=0 OR position('OFFSET 0' IN v_env)=0 OR position('MATERIALIZED' IN v_env)=0 THEN
        RAISE EXCEPTION 'C7 FAILED: env loader lost the parameterised LATERAL probe shape.';
    END IF;
    IF position('EXECUTE ' IN v_env)<>0 OR position('format(' IN v_env)<>0 THEN
        RAISE EXCEPTION 'C7 FAILED: env loader contains runtime-dynamic SQL.';
    END IF;
    IF position('config.parameter_routing' IN v_env)<>0 THEN
        RAISE EXCEPTION 'C7 FAILED: env loader reads config.parameter_routing at run time.';
    END IF;
    IF position('sps.organization_id = ranked.organization_id' IN v_env)=0 THEN
        RAISE EXCEPTION 'C6 FAILED: env loader lost the org-guard on the Space sub-select.';
    END IF;

    v_ener := pg_get_functiondef('telemetry.load_energy_measurements_incremental(interval,interval)'::regprocedure);
    IF position('config.parameter_routing' IN v_ener)<>0 THEN
        RAISE EXCEPTION 'C13 FAILED: energy loader references config.parameter_routing.';
    END IF;
    IF position('space_id' IN v_ener)<>0 THEN
        RAISE EXCEPTION 'C13 FAILED: energy loader references space_id.';
    END IF;
    IF position('telemetry.energy_measurements' IN v_ener)=0 THEN
        RAISE EXCEPTION 'C13 FAILED: energy loader no longer targets telemetry.energy_measurements.';
    END IF;

    RAISE NOTICE 'C1-C4, C7, C13 passed: table shape, 12 mappings, parameter_id, legacy alias, generated-body integrity, energy safety.';
END;
$struct$;

-- ----------------------------------------------------------------------------
-- Part 2 -- constraint rejection (5). Each violating write is attempted in a
-- sub-block and must raise.
-- ----------------------------------------------------------------------------
DO $reject$
DECLARE
    v_prof UUID;
    v_lp   UUID;
    v_ok   BOOLEAN;
BEGIN
    SELECT id INTO v_prof FROM config.device_profiles WHERE profile_code='ENVIRONMENT_SENSOR_AIRSENSE_V1';
    SELECT id INTO v_lp   FROM metadata.logical_points WHERE name='ENV_TEMPERATURE';

    v_ok := FALSE;
    BEGIN
        INSERT INTO config.parameter_routing (profile_id, logical_point_id, destination_table, destination_column, value_transform)
        VALUES (v_prof, v_lp, 'telemetry.environment_measurements', 'temperature_c_dup', 'DOUBLE_PRECISION');
    EXCEPTION WHEN unique_violation THEN v_ok := TRUE;
    END;
    IF NOT v_ok THEN RAISE EXCEPTION 'C5 FAILED: duplicate (profile, logical_point) was accepted.'; END IF;

    v_ok := FALSE;
    BEGIN
        INSERT INTO config.parameter_routing (profile_id, logical_point_id, destination_table, destination_column, value_transform)
        SELECT v_prof, lp2.id, 'telemetry.environment_measurements', 'temperature_c', 'DOUBLE_PRECISION'
        FROM metadata.logical_points lp2 WHERE lp2.name='ENV_RELATIVE_HUMIDITY';
    EXCEPTION WHEN unique_violation THEN v_ok := TRUE;
    END;
    IF NOT v_ok THEN RAISE EXCEPTION 'C5 FAILED: duplicate destination column was accepted.'; END IF;

    v_ok := FALSE;
    BEGIN
        INSERT INTO config.parameter_routing (profile_id, logical_point_id, destination_table, destination_column, value_transform)
        SELECT v_prof, lp2.id, 'telemetry.environment_measurements', 'zzz', 'MULTIPLY_BY_SCALE'
        FROM metadata.logical_points lp2 WHERE lp2.name='ENV_RELATIVE_HUMIDITY';
    EXCEPTION WHEN check_violation THEN v_ok := TRUE;
    END;
    IF NOT v_ok THEN RAISE EXCEPTION 'C5 FAILED: an unknown value_transform was accepted.'; END IF;

    v_ok := FALSE;
    BEGIN
        INSERT INTO config.parameter_routing (profile_id, logical_point_id, destination_table, destination_column, value_transform)
        SELECT v_prof, lp2.id, 'telemetry.energy_measurements', 'zzz', 'DOUBLE_PRECISION'
        FROM metadata.logical_points lp2 WHERE lp2.name='ENV_RELATIVE_HUMIDITY';
    EXCEPTION WHEN check_violation THEN v_ok := TRUE;
    END;
    IF NOT v_ok THEN RAISE EXCEPTION 'C5 FAILED: a non-allowlisted destination_table was accepted.'; END IF;

    v_ok := FALSE;
    BEGIN
        INSERT INTO config.parameter_routing (profile_id, logical_point_id, destination_table, destination_column, value_transform, legacy_source_aliases)
        SELECT v_prof, lp2.id, 'telemetry.environment_measurements', 'zzz2', 'DOUBLE_PRECISION', ARRAY['']::text[]
        FROM metadata.logical_points lp2 WHERE lp2.name='ENV_RELATIVE_HUMIDITY';
    EXCEPTION WHEN check_violation THEN v_ok := TRUE;
    END;
    IF NOT v_ok THEN RAISE EXCEPTION 'C5 FAILED: a malformed legacy_source_aliases was accepted.'; END IF;

    RAISE NOTICE 'C5 passed: duplicate / ambiguous / malformed routing rows are rejected by the DB.';
END;
$reject$;

-- ----------------------------------------------------------------------------
-- Part 3 -- behavioural: target-column mapping + casts + legacy alias +
-- quality NULL + Space NULL + idempotency + bounded watermark (8-12).
-- Fixture rows + fixed literal ids so the Gate B block (Part 4) can rebuild
-- the same expectation without sharing PL/pgSQL locals.
-- ----------------------------------------------------------------------------
DO $behav$
DECLARE
    org_1   UUID := 'e7000000-0000-0000-0000-0000000000a1';
    site_1  UUID := 'e7000000-0000-0000-0000-0000000000b1';
    bldg_1  UUID := 'e7000000-0000-0000-0000-0000000000c1';
    floor_1 UUID := 'e7000000-0000-0000-0000-0000000000d1';
    space_1 UUID := 'e7000000-0000-0000-0000-0000000000e1';
    gw_1    UUID := 'e7000000-0000-0000-0000-0000000000f1';
    dev_1   UUID := 'e7000000-0000-0000-0000-000000000011';
    prof    UUID;
    e1      TIMESTAMPTZ := date_trunc('minute', now()) - INTERVAL '2 hours';
    e2      TIMESTAMPTZ := date_trunc('minute', now()) - INTERVAL '105 minutes';
    r       telemetry.environment_measurements%ROWTYPE;
    v_ckpt  TIMESTAMPTZ;
    v_max   TIMESTAMPTZ;
BEGIN
    SELECT id INTO prof FROM config.device_profiles WHERE profile_code='ENVIRONMENT_SENSOR_AIRSENSE_V1';

    INSERT INTO metadata.organizations (id,name,code) VALUES (org_1,'PR4 Org','PR4_ORG');
    INSERT INTO metadata.sites (id,organization_id,name,code) VALUES (site_1,org_1,'PR4 Site','PR4_SITE');
    INSERT INTO metadata.buildings (id,organization_id,site_id,name,code) VALUES (bldg_1,org_1,site_1,'PR4 Bldg','PR4_BLDG');
    INSERT INTO metadata.floors (id,organization_id,building_id,name,code) VALUES (floor_1,org_1,bldg_1,'PR4 Floor','PR4_FLOOR');
    INSERT INTO metadata.spaces (id,organization_id,floor_id,name,code) VALUES (space_1,org_1,floor_1,'PR4 Space','PR4_SPACE');
    INSERT INTO metadata.gateways (id,organization_id,site_id,name,external_id) VALUES (gw_1,org_1,site_1,'PR4 GW','PR4-GW-1');
    INSERT INTO metadata.devices (id,organization_id,gateway_id,name,external_id,profile_id)
    VALUES (dev_1,org_1,gw_1,'PR4 AirSense','PR4-AIRSENSE-1',prof);
    INSERT INTO config.telemetry_capture_policies
        (site_id, capture_interval_seconds, alignment_mode, late_arrival_tolerance_seconds, effective_from, is_enabled)
    VALUES (site_1, 300, 'WALL_CLOCK', 900, e1 - INTERVAL '1 day', TRUE);

    -- Event e1: all 12 canonical AirSense points. ROUND_INTEGER sources chosen
    -- to prove rounding: 123.7 -> 124 ; 5.2 -> 5.
    INSERT INTO telemetry.normalized_points
        (event_time,organization_id,site_id,device_id,logical_point_id,device_uid,logical_point,numeric_value,quality_code,platform_received_at)
    SELECT e1,org_1,site_1,dev_1,lp.id,'PR4-AIRSENSE-1',v.name,v.val,'GOOD',e1
    FROM (VALUES
        ('ENV_TEMPERATURE',21.5),('ENV_RELATIVE_HUMIDITY',47.0),('ENV_ILLUMINANCE_LUX',311.0),
        ('DEVICE_BATTERY_VOLTAGE',3.62),('OCCUPANCY_ACTIVITY',9.0),
        ('OCCUPANCY_SECONDS_SINCE_LAST_PIR_EVENT',123.7),
        ('PULSE_INPUT_1_RAW',1001.0),('EXTERNAL_SENSOR_INPUT_1_RAW',10.0),
        ('EXTERNAL_SENSOR_INPUT_2_RAW',20.0),('EXTERNAL_SENSOR_INPUT_3_RAW',30.0),
        ('EXTERNAL_SENSOR_INPUT_4_RAW',40.0),('DEVICE_STATUS_CODE',5.2)
    ) AS v(name,val)
    JOIN metadata.logical_points lp ON lp.name=v.name;

    -- Event e2: only the LEGACY name BATTERY_VOLTAGE (no logical_points row -> use
    -- DEVICE_BATTERY_VOLTAGE's id for the FK, publish the legacy .logical_point text).
    INSERT INTO telemetry.normalized_points
        (event_time,organization_id,site_id,device_id,logical_point_id,device_uid,logical_point,numeric_value,quality_code,platform_received_at)
    SELECT e2,org_1,site_1,dev_1,lp.id,'PR4-AIRSENSE-1','BATTERY_VOLTAGE',3.91,'GOOD',e2
    FROM metadata.logical_points lp WHERE lp.name='DEVICE_BATTERY_VOLTAGE';

    UPDATE telemetry.pipeline_state SET last_received_at = e1 - INTERVAL '10 minutes'
    WHERE pipeline_name='environment_measurements';
    DROP TABLE IF EXISTS tmp_environment_candidates;
    CALL telemetry.load_environment_measurements_incremental(INTERVAL '15 minutes', NULL);

    SELECT * INTO r FROM telemetry.environment_measurements
    WHERE device_id=dev_1 AND source_timestamp=e1;
    IF NOT FOUND THEN RAISE EXCEPTION 'C8 FAILED: no routed row for event e1.'; END IF;
    IF r.temperature_c IS DISTINCT FROM 21.5 OR r.humidity_percent IS DISTINCT FROM 47.0
       OR r.illuminance_lux IS DISTINCT FROM 311.0 OR r.battery_voltage_v IS DISTINCT FROM 3.62
       OR r.occupancy_activity IS DISTINCT FROM 9.0
       OR r.pulse_input_1_raw IS DISTINCT FROM 1001.0
       OR r.external_input_1_raw IS DISTINCT FROM 10.0 OR r.external_input_2_raw IS DISTINCT FROM 20.0
       OR r.external_input_3_raw IS DISTINCT FROM 30.0 OR r.external_input_4_raw IS DISTINCT FROM 40.0 THEN
        RAISE EXCEPTION 'C8 FAILED: a DOUBLE_PRECISION column did not route its value.';
    END IF;
    IF r.seconds_since_last_pir_event IS DISTINCT FROM 124 THEN
        RAISE EXCEPTION 'C8 FAILED: ROUND_INTEGER cast for seconds_since_last_pir_event: expected 124, got %.', r.seconds_since_last_pir_event;
    END IF;
    IF r.device_status_code IS DISTINCT FROM 5 THEN
        RAISE EXCEPTION 'C8 FAILED: ROUND_INTEGER cast for device_status_code: expected 5, got %.', r.device_status_code;
    END IF;
    IF r.quality_code IS NOT NULL THEN
        RAISE EXCEPTION 'C10 FAILED: quality_code must be NULL, got %.', r.quality_code;
    END IF;
    IF r.space_id IS NOT NULL THEN
        RAISE EXCEPTION 'C9 FAILED: space_id must be NULL with no binding, got %.', r.space_id;
    END IF;
    IF r.organization_id IS DISTINCT FROM org_1 OR r.site_id IS DISTINCT FROM site_1
       OR r.device_id IS DISTINCT FROM dev_1 OR r.bucket_start IS NULL THEN
        RAISE EXCEPTION 'C8 FAILED: routed row lost tenant / bucket context.';
    END IF;

    SELECT * INTO r FROM telemetry.environment_measurements
    WHERE device_id=dev_1 AND source_timestamp=e2;
    IF NOT FOUND THEN RAISE EXCEPTION 'C8 FAILED: no routed row for the legacy-alias event e2.'; END IF;
    IF r.battery_voltage_v IS DISTINCT FROM 3.91 THEN
        RAISE EXCEPTION 'C8 FAILED: legacy BATTERY_VOLTAGE reading did not route into battery_voltage_v (got %).', r.battery_voltage_v;
    END IF;

    -- 11: idempotency
    UPDATE telemetry.pipeline_state SET last_received_at = e1 - INTERVAL '10 minutes'
    WHERE pipeline_name='environment_measurements';
    DROP TABLE IF EXISTS tmp_environment_candidates;
    CALL telemetry.load_environment_measurements_incremental(INTERVAL '15 minutes', NULL);
    IF (SELECT count(*) FROM telemetry.environment_measurements WHERE device_id=dev_1) <> 2 THEN
        RAISE EXCEPTION 'C11 FAILED: re-run changed the routed row count.';
    END IF;
    SELECT * INTO r FROM telemetry.environment_measurements WHERE device_id=dev_1 AND source_timestamp=e1;
    IF r.temperature_c IS DISTINCT FROM 21.5 OR r.seconds_since_last_pir_event IS DISTINCT FROM 124 THEN
        RAISE EXCEPTION 'C11 FAILED: re-run altered a routed value.';
    END IF;

    -- 12: bounded watermark
    UPDATE telemetry.pipeline_state SET last_received_at = e1 - INTERVAL '10 minutes'
    WHERE pipeline_name='environment_measurements';
    DROP TABLE IF EXISTS tmp_environment_candidates;
    CALL telemetry.load_environment_measurements_incremental(INTERVAL '15 minutes', INTERVAL '5 minutes');
    SELECT last_received_at INTO v_ckpt FROM telemetry.pipeline_state WHERE pipeline_name='environment_measurements';
    SELECT max(platform_received_at) INTO v_max FROM telemetry.normalized_points WHERE platform_received_at IS NOT NULL;
    IF v_ckpt >= v_max THEN
        RAISE EXCEPTION 'C12 FAILED: p_max_window did not cap the checkpoint (ckpt % >= max %).', v_ckpt, v_max;
    END IF;
    IF v_ckpt IS DISTINCT FROM ((e1 - INTERVAL '10 minutes') + INTERVAL '5 minutes') THEN
        RAISE EXCEPTION 'C12 FAILED: bounded checkpoint not at previous_checkpoint + p_max_window (got %).', v_ckpt;
    END IF;
    DROP TABLE IF EXISTS tmp_environment_candidates;
    CALL telemetry.load_environment_measurements_incremental(INTERVAL '15 minutes', NULL);
    SELECT last_received_at INTO v_ckpt FROM telemetry.pipeline_state WHERE pipeline_name='environment_measurements';
    IF v_ckpt IS DISTINCT FROM v_max THEN
        RAISE EXCEPTION 'C12 FAILED: NULL p_max_window did not advance the checkpoint to the true max.';
    END IF;
    RAISE NOTICE 'C8-C12 passed: target-column mapping + casts + legacy alias + quality NULL + Space NULL + idempotency + bounded watermark.';

    -- Snapshot the generated loader's output, then clear it for the Gate B re-run.
    DROP TABLE IF EXISTS gate_b_new;
    CREATE TEMP TABLE gate_b_new ON COMMIT DROP AS
        SELECT bucket_start, received_at, source_timestamp, organization_id, site_id, gateway_id,
               device_id, asset_id, space_id, measurement_interval_seconds, quality_code, is_estimated,
               temperature_c, humidity_percent, pressure_hpa, co2_ppm, voc_ppb, battery_voltage_v,
               signal_strength_dbm, illuminance_lux, occupancy_activity, raw_archive_id,
               seconds_since_last_pir_event, pulse_input_1_raw, external_input_1_raw, external_input_2_raw,
               external_input_3_raw, external_input_4_raw, device_status_code
        FROM telemetry.environment_measurements WHERE device_id=dev_1;
    DELETE FROM telemetry.environment_measurements WHERE device_id=dev_1;
    UPDATE telemetry.pipeline_state SET last_received_at = e1 - INTERVAL '10 minutes'
    WHERE pipeline_name='environment_measurements';
END;
$behav$;


-- ----------------------------------------------------------------------------
-- Part 4 -- Gate B: swap in the VERBATIM deployed migration-226 loader body
-- (top-level DDL, rolled back), re-route the identical fixture, and require a
-- row-for-row identical telemetry.environment_measurements result.
-- >>> begin verbatim migration-226 body (postgres/migrations/226_*.sql lines 111-413) <<<
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

-- >>> end verbatim migration-226 body <<<

DO $gate_b$
DECLARE
    dev_1  UUID := 'e7000000-0000-0000-0000-000000000011';
    e1     TIMESTAMPTZ := date_trunc('minute', now()) - INTERVAL '2 hours';
    v_diff BIGINT;
    v_new  BIGINT;
BEGIN
    DROP TABLE IF EXISTS tmp_environment_candidates;
    CALL telemetry.load_environment_measurements_incremental(INTERVAL '15 minutes', NULL);

    DROP TABLE IF EXISTS gate_b_old;
    CREATE TEMP TABLE gate_b_old ON COMMIT DROP AS
        SELECT bucket_start, received_at, source_timestamp, organization_id, site_id, gateway_id,
               device_id, asset_id, space_id, measurement_interval_seconds, quality_code, is_estimated,
               temperature_c, humidity_percent, pressure_hpa, co2_ppm, voc_ppb, battery_voltage_v,
               signal_strength_dbm, illuminance_lux, occupancy_activity, raw_archive_id,
               seconds_since_last_pir_event, pulse_input_1_raw, external_input_1_raw, external_input_2_raw,
               external_input_3_raw, external_input_4_raw, device_status_code
        FROM telemetry.environment_measurements WHERE device_id=dev_1;

    SELECT count(*) INTO v_diff FROM (
        (SELECT * FROM gate_b_new EXCEPT SELECT * FROM gate_b_old)
        UNION ALL
        (SELECT * FROM gate_b_old EXCEPT SELECT * FROM gate_b_new)
    ) d;
    SELECT count(*) INTO v_new FROM gate_b_new;

    IF v_new = 0 THEN
        RAISE EXCEPTION 'C14 FAILED (Gate B): the fixture produced no rows -- parity check is vacuous.';
    END IF;
    IF v_diff <> 0 THEN
        RAISE EXCEPTION 'C14 FAILED (Gate B): generated loader vs verbatim migration-226 loader differ by % row(s).', v_diff;
    END IF;
    RAISE NOTICE 'C14 passed (Gate B): generated loader is row-for-row identical to the verbatim migration-226 loader (% rows).', v_new;
END;
$gate_b$;

ROLLBACK;

SELECT 'assert_parameter_routing_foundation: all Phase 4 (migration 227) contracts passed (transaction rolled back).' AS result;
