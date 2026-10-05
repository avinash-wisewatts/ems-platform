-- ============================================================================
-- Migration 262
-- Data Point display-category correction (Admin Portal, ADR-018 Amendment
-- 5 grouping): ACTIVE_POWER_TOTAL should render under "Power" and
-- POWER_FACTOR_TOTAL under "Power Quality" in the Assign Data Points UI,
-- instead of falling into the "Other" bucket.
--
-- Inspection performed before this migration (read-only, against the live
-- schema):
--   * Display categories are config.point_categories, reached via
--     config.parameters.parameter_category_id (migration 223's Phase 1
--     semantic foundation). This is a DIFFERENT, independent concept from
--     config.parameters.measurement_group_id (migration 254's
--     canonical_measurement_groups, the enforcement rule for "one
--     confirmed source device per Asset per group") -- the two columns
--     were deliberately decoupled for exactly this reason (see migration
--     254's own header: "display categories remain separate"). This
--     migration touches ONLY parameter_category_id; measurement_group_id
--     is asserted unchanged in the postconditions below.
--   * admin.list_asset_point_assignment_candidates (migration 253) already
--     joins config.parameters -> config.point_categories and returns
--     point_category_name; app/src/main.py's _group_point_candidates_by_
--     device already groups by that value, falling back to "Other" when
--     it is NULL. No application code change is needed -- populating the
--     reference data is sufficient.
--   * config.point_categories already has a 'Power' row (seeded in
--     postgres/seeds/reference/05_lookup_tables.sql), but migration 223
--     never assigned it to ACTIVE_POWER (which had no config.parameters
--     row at all until migration 254 added it) or to any other parameter
--     -- confirmed live: zero parameters currently reference it.
--   * config.point_categories has NO 'Power Quality' row at all -- this
--     migration adds it, matching the seed/migration-223 idiom exactly
--     (INSERT ... ON CONFLICT (name) DO NOTHING).
--
-- Scope, explicit and minimal, matching exactly what was asked -- no
-- other parameter (REACTIVE_POWER, APPARENT_POWER, FREQUENCY, PHASE_ANGLE,
-- CURRENT_THD, ...) is touched. Their display-category question remains
-- the open product decision already on record from the semantic-
-- foundation design report; this migration does not silently resolve it.
-- ============================================================================


-- ----------------------------------------------------------------------------
-- 1. The missing 'Power Quality' display category. Idempotent, same idiom
--    as migration 223's own point_categories inserts.
-- ----------------------------------------------------------------------------

INSERT INTO config.point_categories (name, description)
VALUES ('Power Quality', 'Power quality measurements (power factor, frequency, phase angle, harmonics)')
ON CONFLICT (name) DO NOTHING;


-- ----------------------------------------------------------------------------
-- 2. ACTIVE_POWER -> Power; POWER_FACTOR -> Power Quality. Only
--    parameter_category_id is written; measurement_group_id (migration
--    254's enforcement rule) is untouched.
-- ----------------------------------------------------------------------------

UPDATE config.parameters p
SET parameter_category_id = pc.id,
    updated_at = now()
FROM config.point_categories pc
WHERE p.code = 'ACTIVE_POWER'
  AND pc.name = 'Power';

UPDATE config.parameters p
SET parameter_category_id = pc.id,
    updated_at = now()
FROM config.point_categories pc
WHERE p.code = 'POWER_FACTOR'
  AND pc.name = 'Power Quality';


-- ----------------------------------------------------------------------------
-- 3. Postconditions.
-- ----------------------------------------------------------------------------

DO $post$
DECLARE
    v_active_power_category TEXT;
    v_power_factor_category TEXT;
    v_active_power_group TEXT;
    v_power_factor_group TEXT;
    v_stray_count INTEGER;
BEGIN
    SELECT pc.name INTO v_active_power_category
    FROM config.parameters p LEFT JOIN config.point_categories pc ON pc.id = p.parameter_category_id
    WHERE p.code = 'ACTIVE_POWER';
    IF v_active_power_category IS DISTINCT FROM 'Power' THEN
        RAISE EXCEPTION 'Migration 262 postcondition failed: expected ACTIVE_POWER display category Power, got %', v_active_power_category;
    END IF;

    SELECT pc.name INTO v_power_factor_category
    FROM config.parameters p LEFT JOIN config.point_categories pc ON pc.id = p.parameter_category_id
    WHERE p.code = 'POWER_FACTOR';
    IF v_power_factor_category IS DISTINCT FROM 'Power Quality' THEN
        RAISE EXCEPTION 'Migration 262 postcondition failed: expected POWER_FACTOR display category Power Quality, got %', v_power_factor_category;
    END IF;

    -- The canonical enforcement rule (migration 254) must be completely
    -- unaffected by this display-only change.
    SELECT cmg.code INTO v_active_power_group
    FROM config.parameters p LEFT JOIN config.canonical_measurement_groups cmg ON cmg.id = p.measurement_group_id
    WHERE p.code = 'ACTIVE_POWER';
    IF v_active_power_group IS DISTINCT FROM 'POWER' THEN
        RAISE EXCEPTION 'Migration 262 postcondition failed: ACTIVE_POWER measurement_group_id changed unexpectedly (now %), this migration must not touch enforcement.', v_active_power_group;
    END IF;

    SELECT cmg.code INTO v_power_factor_group
    FROM config.parameters p LEFT JOIN config.canonical_measurement_groups cmg ON cmg.id = p.measurement_group_id
    WHERE p.code = 'POWER_FACTOR';
    IF v_power_factor_group IS DISTINCT FROM 'POWER_QUALITY' THEN
        RAISE EXCEPTION 'Migration 262 postcondition failed: POWER_FACTOR measurement_group_id changed unexpectedly (now %), this migration must not touch enforcement.', v_power_factor_group;
    END IF;

    -- Regression guard: no OTHER parameter was widened into these two
    -- categories by this migration (proves scope stayed exactly as
    -- intended -- only ACTIVE_POWER and POWER_FACTOR were assigned).
    SELECT count(*) INTO v_stray_count
    FROM config.parameters p
    JOIN config.point_categories pc ON pc.id = p.parameter_category_id
    WHERE pc.name IN ('Power', 'Power Quality')
      AND p.code NOT IN ('ACTIVE_POWER', 'POWER_FACTOR');
    IF v_stray_count > 0 THEN
        RAISE EXCEPTION 'Migration 262 postcondition failed: % unexpected parameter(s) assigned to Power/Power Quality beyond ACTIVE_POWER/POWER_FACTOR.', v_stray_count;
    END IF;

    RAISE NOTICE 'Migration 262: all postconditions passed (ACTIVE_POWER -> Power, POWER_FACTOR -> Power Quality; canonical measurement groups unchanged; no other parameter touched).';
END;
$post$;
