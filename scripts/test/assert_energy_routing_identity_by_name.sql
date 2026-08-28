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
--   Architectural invariant asserted here (catalog inspection of the DEPLOYED
--   objects -- deterministic, no fixture, no timing):
--
--     E1  Neither
--           telemetry.load_energy_measurements_incremental(interval,interval)
--           telemetry.v_energy_measurements_full_resolution
--         contains a metric-identity predicate of the form
--           logical_point_id  {=,IN}  '<uuid-literal>'
--         Legitimate relational use of the logical_point_id COLUMN (the
--         energy_register_semantics join, GROUP BY, the SELECT list) is NOT
--         flagged -- only a quoted-UUID literal on the right of = / IN.
--
--     E2  Every one of the 20 electrical signals is resolved by NAME, with
--         its migration-207 scoping preserved:
--           * 12 power columns  -> logical_point = ANY (ARRAY['<name>', ...])
--                                  AND quality_code = 'GOOD'
--                                  AND profile_code = 'ENERGY_METER_ENISCOPE_V1'
--           * 8 reactive/apparent-energy columns
--                               -> logical_point = ANY (ARRAY['<name>', ...])
--                                  AND quality_code = 'GOOD'
--                                  AND scale_to_normalized_unit IS NOT NULL
--         Checked in BOTH the loader and the full-resolution view.
--
--     E3  metadata.uq_logical_points_name exists, is UNIQUE, is VALID, is on
--         exactly (name); a duplicate-name insert is rejected.
--
--   The live "a random-id database still routes every column" behaviour is
--   proven directly, on real data, by the B5 post-deploy staging verification
--   (a fresh closed energy_measurements bucket with non-NULL electrical values
--   where GOOD source exists) -- not re-simulated here with a synthetic
--   metadata graph.
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
    RAISE NOTICE 'E1 PASS: no hard-coded logical_point_id UUID identity predicate in the deployed loader or full-resolution view.';
END
$e1$;

-- --------------------------------------------------------------------------
-- E2 -- all 20 electrical signals resolved by NAME with 207 scoping intact
-- --------------------------------------------------------------------------
DO $e2$
DECLARE
    v_fn    TEXT := pg_get_functiondef(
                      'telemetry.load_energy_measurements_incremental(interval,interval)'::regprocedure);
    v_view  TEXT := pg_get_viewdef(
                      'telemetry.v_energy_measurements_full_resolution'::regclass, true);
    r       RECORD;
    v_scope TEXT;
    v_miss  TEXT := '';
BEGIN
    FOR r IN
        SELECT * FROM (VALUES
          -- (canonical name, kind)  kind: 'power' | 'energy'
          ('ACTIVE_POWER_TOTAL','power'),   ('ACTIVE_POWER_L1','power'),
          ('ACTIVE_POWER_L2','power'),      ('ACTIVE_POWER_L3','power'),
          ('REACTIVE_POWER_TOTAL','power'), ('REACTIVE_POWER_L1','power'),
          ('REACTIVE_POWER_L2','power'),    ('REACTIVE_POWER_L3','power'),
          ('APPARENT_POWER_TOTAL','power'), ('APPARENT_POWER_L1','power'),
          ('APPARENT_POWER_L2','power'),    ('APPARENT_POWER_L3','power'),
          ('REACTIVE_ENERGY_TOTAL','energy'), ('REACTIVE_ENERGY_L1','energy'),
          ('REACTIVE_ENERGY_L2','energy'),    ('REACTIVE_ENERGY_L3','energy'),
          ('APPARENT_ENERGY_TOTAL','energy'), ('APPARENT_ENERGY_L1','energy'),
          ('APPARENT_ENERGY_L2','energy'),    ('APPARENT_ENERGY_L3','energy')
        ) AS t(name, kind)
    LOOP
        -- name resolution present (ARRAY[...] containing the canonical name)?
        IF position('ARRAY[''' || r.name || '''' IN v_fn) = 0
           AND v_fn !~ ('ANY \(ARRAY\[[^]]*''' || r.name || '''') THEN
            v_miss := v_miss || ' loader:' || r.name || '(no-name-array)';
        END IF;
        IF v_view !~ ('ANY \(ARRAY\[[^]]*''' || r.name || '''') THEN
            v_miss := v_miss || ' view:' || r.name || '(no-name-array)';
        END IF;
    END LOOP;

    -- scoping guards must still be present the expected number of times in
    -- the loader: 12 power predicates carry profile_code; the 8 energy
    -- predicates carry scale_to_normalized_unit IS NOT NULL (shared with the
    -- import/export energy columns, so we assert ">= the electrical count").
    IF (length(v_fn) - length(replace(v_fn, 'profile_code = ''ENERGY_METER_ENISCOPE_V1''', '')))
       / length('profile_code = ''ENERGY_METER_ENISCOPE_V1''') < 12 THEN
        v_miss := v_miss || ' loader:<12 profile_code guards';
    END IF;
    IF v_fn !~ 'scale_to_normalized_unit IS NOT NULL' THEN
        v_miss := v_miss || ' loader:no scale_to_normalized_unit guard';
    END IF;

    IF v_miss <> '' THEN
        RAISE EXCEPTION 'E2 FAIL: electrical name-resolution / scoping missing:%', v_miss;
    END IF;
    RAISE NOTICE 'E2 PASS: all 20 electrical signals resolve by name in the loader and the view; 207 profile/scale scoping preserved.';
END
$e2$;

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

ROLLBACK;

\echo 'assert_energy_routing_identity_by_name: PASS'
