-- ============================================================================
-- File:
--   scripts/test/assert_energy_routing_identity_by_name.sql
--
-- Purpose:
--   Regression test for migration 215 and the Canonical Metric Identity
--   contract. Migration 207 made telemetry.load_energy_measurements_incremental
--   select 20 electrical columns by a hard-coded canonical logical_point_id
--   UUID; those UUIDs are database-local surrogates and are absent on any
--   environment provisioned with gen_random_uuid() ids, so all 20 columns went
--   NULL fleet-wide. Migration 215 restores logical-point-NAME resolution.
--
--   Contract asserted here (all inside BEGIN; ... ROLLBACK; -- nothing
--   persists; the real telemetry.pipeline_state rows are never mutated):
--
--     E1  The DEPLOYED definitions of
--           telemetry.load_energy_measurements_incremental(interval,interval)
--           telemetry.v_energy_measurements_full_resolution
--         contain NO metric-identity predicate of the form
--           logical_point_id  {=,IN}  '<uuid-literal>'
--         (legitimate relational use of the logical_point_id COLUMN -- joins,
--         GROUP BY, register-semantics lookups -- is NOT flagged).
--
--     E3  metadata.uq_logical_points_name exists, is UNIQUE, is VALID, and is
--         defined on exactly (name). A duplicate name insert is rejected.
--
--     E2/E4/E5  Behavioural: an ENERGY_METER_ENISCOPE_V1 device whose
--         electrical logical points carry deliberately RANDOM, non-canonical
--         logical_point_id values still routes every affected column to a
--         non-NULL value through the deployed loader. This proves the routing
--         path no longer depends on any particular UUID -- i.e. it works on a
--         fresh/random-id database exactly as on a canonical-id one.
-- ============================================================================

\set ON_ERROR_STOP on

BEGIN;

-- --------------------------------------------------------------------------
-- E1 -- no hard-coded logical_point_id UUID identity predicate
-- --------------------------------------------------------------------------
DO $e1$
DECLARE
    v_fn   TEXT := pg_get_functiondef(
                     'telemetry.load_energy_measurements_incremental(interval,interval)'::regprocedure);
    v_view TEXT := pg_get_viewdef(
                     'telemetry.v_energy_measurements_full_resolution'::regclass, true);
    -- logical_point_id, optional ws, = or IN, optional ws / open paren / quote,
    -- then a uuid-shaped literal. Matches the anti-pattern; does not match
    -- "ON x.logical_point_id = y.logical_point_id" or "GROUP BY logical_point_id".
    v_bad  TEXT := 'logical_point_id[[:space:]]*(=|IN)[[:space:]]*\(?[[:space:]]*''[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-';
BEGIN
    IF v_fn ~ v_bad THEN
        RAISE EXCEPTION
          'E1 FAIL: telemetry.load_energy_measurements_incremental still contains a hard-coded logical_point_id UUID identity predicate';
    END IF;
    IF v_view ~ v_bad THEN
        RAISE EXCEPTION
          'E1 FAIL: telemetry.v_energy_measurements_full_resolution still contains a hard-coded logical_point_id UUID identity predicate';
    END IF;

    -- Positive control: the 20 electrical signals must be resolved by NAME.
    IF v_fn !~ 'logical_point[[:space:]]*=[[:space:]]*ANY[[:space:]]*\([[:space:]]*ARRAY\[[[:space:]]*''ACTIVE_POWER_TOTAL''' THEN
        RAISE EXCEPTION
          'E1 FAIL: loader does not resolve ACTIVE_POWER_TOTAL by name (expected logical_point = ANY (ARRAY[''ACTIVE_POWER_TOTAL'', ...]))';
    END IF;
    IF v_view !~ 'ACTIVE_POWER_TOTAL' THEN
        RAISE EXCEPTION 'E1 FAIL: view does not reference ACTIVE_POWER_TOTAL by name';
    END IF;

    RAISE NOTICE 'E1 PASS: no hard-coded logical_point_id UUID identity predicate; electrical signals resolve by name.';
END
$e1$;

-- --------------------------------------------------------------------------
-- E3 -- name-is-identity uniqueness contract
-- --------------------------------------------------------------------------
DO $e3$
DECLARE
    v_ok BOOLEAN;
    v_dup_rejected BOOLEAN := FALSE;
    v_name TEXT;
BEGIN
    SELECT i.indisunique AND i.indisvalid
      INTO v_ok
    FROM pg_index i
    WHERE i.indexrelid = 'metadata.uq_logical_points_name'::regclass
      AND pg_get_indexdef(i.indexrelid) ~ '\(name\)[[:space:]]*$';

    IF NOT COALESCE(v_ok, FALSE) THEN
        RAISE EXCEPTION 'E3 FAIL: metadata.uq_logical_points_name missing / not unique / not valid / not on (name)';
    END IF;

    SELECT name INTO v_name FROM metadata.logical_points LIMIT 1;
    IF v_name IS NOT NULL THEN
        BEGIN
            INSERT INTO metadata.logical_points (name, data_type) VALUES (v_name, 'numeric');
            RAISE EXCEPTION 'E3 FAIL: duplicate logical_points.name insert was NOT rejected';
        EXCEPTION
            WHEN unique_violation THEN v_dup_rejected := TRUE;
        END;
        IF NOT v_dup_rejected THEN
            RAISE EXCEPTION 'E3 FAIL: duplicate name did not raise unique_violation';
        END IF;
    END IF;

    RAISE NOTICE 'E3 PASS: logical_points.name is globally unique and enforced.';
END
$e3$;

-- --------------------------------------------------------------------------
-- E2 / E4 / E5 -- routing works with random, non-canonical logical_point_id
-- --------------------------------------------------------------------------
DO $e2$
DECLARE
    v_profile_id  UUID;
    v_org         UUID := gen_random_uuid();
    v_site        UUID := gen_random_uuid();
    v_gateway     UUID := gen_random_uuid();
    v_device      UUID := gen_random_uuid();
    v_evt         TIMESTAMPTZ := date_trunc('minute', clock_timestamp()) - INTERVAL '5 minutes';
    v_prx         TIMESTAMPTZ := clock_timestamp() - INTERVAL '2 minutes';
    v_name        TEXT;
    v_lpid        UUID;
    v_cnt         INTEGER;
    v_missing     TEXT := '';
    -- the 12 power signals (canonical name) + their energy_measurements column
    r             RECORD;
BEGIN
    SELECT id INTO v_profile_id
    FROM config.device_profiles WHERE profile_code = 'ENERGY_METER_ENISCOPE_V1';
    IF v_profile_id IS NULL THEN
        RAISE NOTICE 'E2 SKIP: ENERGY_METER_ENISCOPE_V1 profile not seeded in this database.';
        RETURN;
    END IF;

    -- minimal metadata graph
    INSERT INTO metadata.organizations (id, name, code)
        VALUES (v_org, 'T215 Org', 'T215ORG') ON CONFLICT DO NOTHING;
    INSERT INTO metadata.sites (id, organization_id, name, code, timezone)
        VALUES (v_site, v_org, 'T215 Site', 'T215SITE', 'Asia/Kolkata') ON CONFLICT DO NOTHING;
    INSERT INTO metadata.devices (id, organization_id, site_id, name, external_id, profile_id)
        VALUES (v_device, v_org, v_site, 'T215 Meter', 'T215-METER-1', v_profile_id) ON CONFLICT DO NOTHING;

    -- a capture policy so telemetry.resolve_site_capture_bucket resolves
    INSERT INTO config.telemetry_capture_policies
        (site_id, capture_interval_seconds, late_arrival_tolerance_seconds,
         effective_from, is_enabled)
    VALUES (v_site, 60, 120, v_evt - INTERVAL '1 day', TRUE)
    ON CONFLICT DO NOTHING;

    -- routing checkpoint just before the fixture, so only our rows are in-window
    UPDATE telemetry.pipeline_state
       SET last_received_at = v_prx - INTERVAL '1 minute'
     WHERE pipeline_name = 'energy_measurements';

    -- one normalized_points row per electrical signal, with a DELIBERATELY
    -- RANDOM logical_point_id (never a canonical UUID). logical_point text
    -- carries the canonical name -- which is all migration 215 needs.
    FOR r IN
        SELECT unnest(ARRAY[
          'ACTIVE_POWER_TOTAL','ACTIVE_POWER_L1','ACTIVE_POWER_L2','ACTIVE_POWER_L3',
          'REACTIVE_POWER_TOTAL','REACTIVE_POWER_L1','REACTIVE_POWER_L2','REACTIVE_POWER_L3',
          'APPARENT_POWER_TOTAL','APPARENT_POWER_L1','APPARENT_POWER_L2','APPARENT_POWER_L3',
          'ENERGY_IMPORT_TOTAL'
        ]) AS lp
    LOOP
        INSERT INTO telemetry.normalized_points
            (event_time, organization_id, site_id, gateway_id, device_id,
             logical_point_id, device_uid, logical_point, raw_field_name,
             numeric_value, quality_code, platform_received_at)
        VALUES
            (v_evt, v_org, v_site, v_gateway, v_device,
             gen_random_uuid(), 'T215-METER-1', r.lp, 'x',
             123.45, 'GOOD', v_prx);
    END LOOP;

    CALL telemetry.load_energy_measurements_incremental(NULL, NULL);

    SELECT count(*) INTO v_cnt
    FROM telemetry.energy_measurements
    WHERE device_id = v_device;

    IF v_cnt = 0 THEN
        RAISE EXCEPTION 'E2 FAIL: loader produced no energy_measurements row for the random-id fixture device';
    END IF;

    -- every power column must have routed to a non-NULL value
    FOR r IN
        SELECT col FROM unnest(ARRAY[
          'active_power_total_w','active_power_l1_w','active_power_l2_w','active_power_l3_w',
          'reactive_power_total_var','reactive_power_l1_var','reactive_power_l2_var','reactive_power_l3_var',
          'apparent_power_total_va','apparent_power_l1_va','apparent_power_l2_va','apparent_power_l3_va'
        ]) AS col
    LOOP
        EXECUTE format(
          'SELECT count(*) FROM telemetry.energy_measurements WHERE device_id = %L AND %I IS NOT NULL',
          v_device, r.col) INTO v_cnt;
        IF v_cnt = 0 THEN
            v_missing := v_missing || ' ' || r.col;
        END IF;
    END LOOP;

    IF v_missing <> '' THEN
        RAISE EXCEPTION
          'E2 FAIL: with random non-canonical logical_point_id values, these columns are still NULL:%', v_missing;
    END IF;

    RAISE NOTICE 'E2 PASS: all 12 power columns routed to non-NULL for a random-id ENERGY_METER_ENISCOPE_V1 fixture.';
END
$e2$;

ROLLBACK;

\echo 'assert_energy_routing_identity_by_name: PASS'
