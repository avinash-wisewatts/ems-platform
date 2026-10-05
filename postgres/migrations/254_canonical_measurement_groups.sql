-- ============================================================================
-- Migration 254
-- Canonical Measurement Groups (ADR-018 Amendment 2 correction, "v3" design
-- checkpoint) -- the semantic-foundation prerequisite the Asset Point
-- Assignment Save function needs to enforce "one confirmed source device
-- per Asset per governed measurement set," approved this session.
--
-- Scope, explicit (per the approved design; nothing beyond this list):
--   * config.canonical_measurement_groups -- new, small, closed lookup
--     table. Each row is the actual ENFORCEMENT unit: "every confirmed
--     asset_points row whose parameter belongs to this group must come
--     from the same device." Distinct from, and independent of, the
--     existing config.point_categories (Amendment 5's DISPLAY grouping,
--     "grouped by measurement/category" in the Assign Data Points UI) --
--     display categories are explicitly NOT touched by this migration.
--   * config.parameters.measurement_group_id -- new, nullable FK. NULL
--     means "not governed by the one-source-per-Asset rule" (Current,
--     Voltage... no: Current/Voltage ARE governed, see below --
--     NULL means e.g. environmental/diagnostic/still-ambiguous points).
--   * The required missing config.parameters coverage this rule depends
--     on: ACTIVE_POWER (previously had NO config.parameters row at all --
--     verified: migration 223 mapped REACTIVE_POWER/APPARENT_POWER but
--     never ACTIVE_POWER), plus the missing _TOTAL logical_point mappings
--     for REACTIVE_POWER_TOTAL, APPARENT_POWER_TOTAL, APPARENT_ENERGY_TOTAL
--     (each already had a config.parameters row for its L1/L2/L3 siblings;
--     only the _TOTAL qualifier mapping was missing from migration 223).
--   * Exactly the 7 approved groups, and exactly the parameter->group
--     mappings decided this session (see table below). No group beyond
--     these 7 is created. No parameter outside the approved list is
--     assigned a group -- everything else (the still-ambiguous reactive-
--     energy points, pulse/raw/status points, all environmental/AirSense
--     points) is left with measurement_group_id NULL, unchanged, exactly
--     as migration 223 already left them parameter_id NULL.
--
-- Why NOT a single generic "one device per family" rule (explicit design
-- decision, not an oversight): Energy is NOT one enforcement unit -- Import,
-- Export, and Apparent Energy are three independently-sourceable
-- measurements (different devices may supply each). Power, Power Quality,
-- Voltage, and Current each ARE one enforcement unit spanning multiple
-- parameters (e.g. Active/Reactive/Apparent Power, including every phase/
-- total qualifier of each, must all come from one device). This migration
-- represents that by making the GROUP the unit of enforcement (not a
-- parameter, not a coarser "family") and letting the DATA carry the
-- differing granularity -- three groups for Energy, one group each for
-- Power/PQ/Voltage/Current -- rather than branching on family in code.
-- The future Save function's enforcement query is therefore one uniform
-- "at most one distinct device per (asset, measurement_group)" check, with
-- no special-casing: see the design report this migration implements.
--
-- Explicitly NOT in this migration (deferred, per the approved scope):
--   * config.point_categories / parameter_category_id changes (display
--     grouping remains exactly as migration 223 left it -- including
--     CURRENT_THD's still-open 'Current' categorization, which is a
--     separate, still-undecided display question, decoupled from this
--     migration's now-settled enforcement-group answer for the same
--     point).
--   * The Asset Point Assignment Save/write function itself.
--   * Commissioning-trigger / backfill state machine.
--   * Any staging deployment.
--
-- Pre-implementation verification performed this session (read-only,
-- local repository only -- see the accompanying report for the session
-- transcript): searched every asset-scoped analytics view/function,
-- Demand/Power/PQ calculation, and existing test for an assumption that an
-- Asset can have multiple SIMULTANEOUS confirmed Voltage or Current
-- sources. Finding: no such assumption exists anywhere in the repository.
-- The only asset-scoped view carrying Voltage/Current fields,
-- analytics.v_grafana_asset_electrical_samples (postgres/ddl/134,
-- postgres/migrations/015), already resolves through exactly ONE device --
-- the asset's PRIMARY_METER, which is schema-enforced 1:1 per asset
-- (ASSET_AND_DEVICE_UNIQUE) -- so it cannot structurally return two
-- devices' Voltage/Current for one asset today. It is already an
-- ADR-018-Amendment-4 "Class B" object (destined to move from a
-- PRIMARY_METER join to asset_points-based attribution); this migration's
-- VOLTAGE/CURRENT groups make that future redesign well-defined (exactly
-- one confirmed device per group) rather than introducing any new
-- conflict. Demand/Power calculations (migrations 250/251) key only on
-- Active/Reactive/Apparent Power and Energy points, never Voltage/Current.
-- Live telemetry streaming (app/src/live_main.py) is device-scoped, not
-- asset-aggregated. No test in scripts/test asserts multi-device Voltage/
-- Current behavior for one asset. No conflicting assumption found.
--
-- Rollback: DROP FUNCTION/constraint additions are all additive and
-- nullable; a rollback would ALTER TABLE config.parameters DROP COLUMN
-- measurement_group_id, DROP TABLE config.canonical_measurement_groups,
-- and revert the config.parameters/logical_points rows this migration
-- inserts/updates to their migration-223 state (ACTIVE_POWER row removed;
-- REACTIVE_POWER_TOTAL/APPARENT_POWER_TOTAL/APPARENT_ENERGY_TOTAL
-- logical_points reset to parameter_id/qualifier NULL). Not run as part of
-- this migration.
-- ============================================================================


-- ----------------------------------------------------------------------------
-- 1. New engineering unit for ACTIVE_POWER, matching the base-unit
--    convention migration 223 already used for its instantaneous-power
--    siblings (REACTIVE_POWER -> VAR, APPARENT_POWER -> VA, both base
--    units, not kilo-prefixed) -- same idiom as migration 223's own step 1.
-- ----------------------------------------------------------------------------

INSERT INTO config.engineering_units (symbol, description)
VALUES ('W', 'Instantaneous active (real) power in watts')
ON CONFLICT (symbol) DO UPDATE
SET description = EXCLUDED.description;


-- ----------------------------------------------------------------------------
-- 2. config.parameters -- the one genuinely missing row (ACTIVE_POWER).
--    parameter_category_id deliberately left NULL: display categorization
--    is out of scope for this migration (see header).
-- ----------------------------------------------------------------------------

INSERT INTO config.parameters (code, name, description, unit_id)
SELECT 'ACTIVE_POWER', 'Active Power',
       'Instantaneous active (real) power, per phase or total.',
       eu.id
FROM config.engineering_units eu
WHERE eu.symbol = 'W'
ON CONFLICT (code) DO UPDATE
SET name        = EXCLUDED.name,
    description = EXCLUDED.description,
    unit_id     = EXCLUDED.unit_id,
    updated_at  = now();


-- ----------------------------------------------------------------------------
-- 3. Backfill the logical_point mappings migration 223 missed: ACTIVE_POWER
--    (all 4 qualifiers, brand new parameter) and the three _TOTAL
--    qualifiers whose L1/L2/L3 siblings were already mapped by migration
--    223 (REACTIVE_POWER_TOTAL, APPARENT_POWER_TOTAL, APPARENT_ENERGY_TOTAL).
-- ----------------------------------------------------------------------------

UPDATE metadata.logical_points lp
SET parameter_id = p.id,
    qualifier    = m.qualifier
FROM (VALUES
    ('ACTIVE_POWER_L1',    'ACTIVE_POWER',    'L1'),
    ('ACTIVE_POWER_L2',    'ACTIVE_POWER',    'L2'),
    ('ACTIVE_POWER_L3',    'ACTIVE_POWER',    'L3'),
    ('ACTIVE_POWER_TOTAL', 'ACTIVE_POWER',    'TOTAL'),
    ('REACTIVE_POWER_TOTAL',  'REACTIVE_POWER',  'TOTAL'),
    ('APPARENT_POWER_TOTAL',  'APPARENT_POWER',  'TOTAL'),
    ('APPARENT_ENERGY_TOTAL', 'APPARENT_ENERGY', 'TOTAL')
) AS m(logical_point_name, parameter_code, qualifier)
JOIN config.parameters p ON p.code = m.parameter_code
WHERE lp.name = m.logical_point_name;


-- ----------------------------------------------------------------------------
-- 4. config.canonical_measurement_groups -- the enforcement-unit lookup.
--    Shape mirrors config.point_categories / config.asset_device_
--    relationship_types: a small, closed, named vocabulary that carries
--    its own display text (name) for direct use in the future Save
--    function's error messages, the same way migration 253's candidate
--    query already surfaces config.asset_device_relationship_types.name.
-- ----------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS config.canonical_measurement_groups (
    id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    code        TEXT NOT NULL,
    name        TEXT NOT NULL,
    description TEXT,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE UNIQUE INDEX IF NOT EXISTS uq_canonical_measurement_groups_code
    ON config.canonical_measurement_groups (code);

COMMENT ON TABLE config.canonical_measurement_groups IS
'ADR-018 Amendment 2 correction (v3 design, migration 254): the enforcement unit for "one confirmed source device per Asset." Every metadata.asset_points row whose logical_point resolves (via config.parameters.measurement_group_id) to the same group must come from the same device, for a given asset, at a given time. Independent of config.point_categories, which is a display-only concept (Amendment 5 grouping) and is not touched by this migration.';

INSERT INTO config.canonical_measurement_groups (code, name, description)
VALUES
    ('ENERGY_IMPORT',  'Energy Import',
     'Accumulated active energy imported from the grid. A distinct, independently-sourced Energy measurement -- may come from a different device than Export or Apparent Energy (ADR-018 Amendment 2 correction, v3).'),
    ('ENERGY_EXPORT',  'Energy Export',
     'Accumulated active energy exported to the grid. A distinct, independently-sourced Energy measurement -- may come from a different device than Import or Apparent Energy.'),
    ('ENERGY_APPARENT', 'Apparent Energy',
     'Accumulated apparent energy. A distinct, independently-sourced Energy measurement -- may come from a different device than Import or Export.'),
    ('POWER', 'Power',
     'Active, Reactive, and Apparent Power together, including every phase/total qualifier of each -- must all come from the same confirmed device for a given Asset.'),
    ('POWER_QUALITY', 'Power Quality',
     'Power Factor, Frequency, Phase Angle, and Current/Voltage THD together -- must all come from the same confirmed device for a given Asset.'),
    ('VOLTAGE', 'Voltage',
     'Line-to-neutral and line-to-line voltage, per phase or averaged -- must all come from the same confirmed device for a given Asset.'),
    ('CURRENT', 'Current',
     'Per-phase, neutral, and total current -- must all come from the same confirmed device for a given Asset. Does not include Current THD, which belongs to the Power Quality group.')
ON CONFLICT (code) DO UPDATE
SET name        = EXCLUDED.name,
    description = EXCLUDED.description,
    updated_at  = now();

GRANT SELECT ON config.canonical_measurement_groups TO ems_app, ems_admin;


-- ----------------------------------------------------------------------------
-- 5. config.parameters.measurement_group_id -- nullable FK, independent of
--    parameter_category_id.
-- ----------------------------------------------------------------------------

ALTER TABLE config.parameters
    ADD COLUMN IF NOT EXISTS measurement_group_id UUID
        REFERENCES config.canonical_measurement_groups(id);

COMMENT ON COLUMN config.parameters.measurement_group_id IS
'Migration 254 (ADR-018 Amendment 2 correction, v3): the canonical enforcement group this parameter belongs to for the "one confirmed source device per Asset" rule. NULL = not governed by that rule (e.g. environmental parameters, or a parameter deliberately left unclassified pending a product decision -- see migration 254 header). Independent of parameter_category_id, which is a display-only concept.';


-- ----------------------------------------------------------------------------
-- 6. Exact parameter -> group assignments approved this session. Every
--    parameter not listed here keeps measurement_group_id = NULL,
--    unchanged -- this UPDATE only ever narrows toward the approved list,
--    never widens beyond it.
-- ----------------------------------------------------------------------------

UPDATE config.parameters p
SET measurement_group_id = g.id,
    updated_at = now()
FROM (VALUES
    ('ENERGY_IMPORT',       'ENERGY_IMPORT'),
    ('ENERGY_EXPORT',       'ENERGY_EXPORT'),
    ('APPARENT_ENERGY',     'ENERGY_APPARENT'),
    ('ACTIVE_POWER',        'POWER'),
    ('REACTIVE_POWER',      'POWER'),
    ('APPARENT_POWER',      'POWER'),
    ('POWER_FACTOR',        'POWER_QUALITY'),
    ('FREQUENCY',           'POWER_QUALITY'),
    ('PHASE_ANGLE',         'POWER_QUALITY'),
    ('CURRENT_THD',         'POWER_QUALITY'),
    ('VOLTAGE_LINE_NEUTRAL','VOLTAGE'),
    ('VOLTAGE_LINE_LINE',   'VOLTAGE'),
    ('CURRENT',             'CURRENT')
) AS m(parameter_code, group_code)
JOIN config.canonical_measurement_groups g ON g.code = m.group_code
WHERE p.code = m.parameter_code;


-- ----------------------------------------------------------------------------
-- 7. Postconditions -- fail loudly on any drift from the intended end
--    state, per the migration 198/199/223/253 discipline.
-- ----------------------------------------------------------------------------

DO $post$
DECLARE
    v_group_count INTEGER;
    v_bad_group_mappings TEXT;
    v_unexpectedly_grouped TEXT;
    v_bad_point_mappings TEXT;
    v_dangling_count INTEGER;
BEGIN
    -- (a) exactly the 7 approved groups exist.
    SELECT count(*) INTO v_group_count
    FROM config.canonical_measurement_groups
    WHERE code IN ('ENERGY_IMPORT','ENERGY_EXPORT','ENERGY_APPARENT',
                    'POWER','POWER_QUALITY','VOLTAGE','CURRENT');
    IF v_group_count <> 7 THEN
        RAISE EXCEPTION 'Migration 254 postcondition failed: expected 7 config.canonical_measurement_groups rows, found %', v_group_count;
    END IF;

    -- (b) every approved parameter->group mapping resolved correctly.
    SELECT string_agg(expected.parameter_code || ' -> expected ' || expected.group_code || ', got ' || COALESCE(g.code, 'NULL'), '; ')
    INTO v_bad_group_mappings
    FROM (VALUES
        ('ENERGY_IMPORT','ENERGY_IMPORT'), ('ENERGY_EXPORT','ENERGY_EXPORT'),
        ('APPARENT_ENERGY','ENERGY_APPARENT'),
        ('ACTIVE_POWER','POWER'), ('REACTIVE_POWER','POWER'), ('APPARENT_POWER','POWER'),
        ('POWER_FACTOR','POWER_QUALITY'), ('FREQUENCY','POWER_QUALITY'),
        ('PHASE_ANGLE','POWER_QUALITY'), ('CURRENT_THD','POWER_QUALITY'),
        ('VOLTAGE_LINE_NEUTRAL','VOLTAGE'), ('VOLTAGE_LINE_LINE','VOLTAGE'),
        ('CURRENT','CURRENT')
    ) AS expected(parameter_code, group_code)
    LEFT JOIN config.parameters p ON p.code = expected.parameter_code
    LEFT JOIN config.canonical_measurement_groups g ON g.id = p.measurement_group_id
    WHERE g.code IS DISTINCT FROM expected.group_code;

    IF v_bad_group_mappings IS NOT NULL THEN
        RAISE EXCEPTION 'Migration 254 postcondition failed: parameter->group mapping(s) incorrect: %', v_bad_group_mappings;
    END IF;

    -- (c) regression guard: nothing outside the approved list was
    --     unexpectedly grouped (proves this migration did not widen
    --     scope beyond what was approved -- same discipline as migration
    --     223's own unmapped-points regression guard).
    SELECT string_agg(p.code, ', ') INTO v_unexpectedly_grouped
    FROM config.parameters p
    WHERE p.code IN ('TEMPERATURE','HUMIDITY','ILLUMINANCE','BATTERY_VOLTAGE',
                      'OCCUPANCY_ACTIVITY','OCCUPANCY_TIME_SINCE_LAST_EVENT')
      AND p.measurement_group_id IS NOT NULL;
    IF v_unexpectedly_grouped IS NOT NULL THEN
        RAISE EXCEPTION 'Migration 254 postcondition failed: ungoverned parameter(s) unexpectedly assigned a measurement_group_id: %', v_unexpectedly_grouped;
    END IF;

    -- (d) the newly-backfilled logical_point mappings resolved correctly.
    SELECT string_agg(expected.logical_point_name || ' -> expected ' || expected.parameter_code || '/' || expected.qualifier || ', got ' || COALESCE(p.code, 'NULL') || '/' || COALESCE(lp.qualifier, 'NULL'), '; ')
    INTO v_bad_point_mappings
    FROM (VALUES
        ('ACTIVE_POWER_L1', 'ACTIVE_POWER', 'L1'),
        ('ACTIVE_POWER_L2', 'ACTIVE_POWER', 'L2'),
        ('ACTIVE_POWER_L3', 'ACTIVE_POWER', 'L3'),
        ('ACTIVE_POWER_TOTAL', 'ACTIVE_POWER', 'TOTAL'),
        ('REACTIVE_POWER_TOTAL', 'REACTIVE_POWER', 'TOTAL'),
        ('APPARENT_POWER_TOTAL', 'APPARENT_POWER', 'TOTAL'),
        ('APPARENT_ENERGY_TOTAL', 'APPARENT_ENERGY', 'TOTAL')
    ) AS expected(logical_point_name, parameter_code, qualifier)
    LEFT JOIN metadata.logical_points lp ON lp.name = expected.logical_point_name
    LEFT JOIN config.parameters p ON p.id = lp.parameter_id
    WHERE p.code IS DISTINCT FROM expected.parameter_code
       OR lp.qualifier IS DISTINCT FROM expected.qualifier;

    IF v_bad_point_mappings IS NOT NULL THEN
        RAISE EXCEPTION 'Migration 254 postcondition failed: logical_point mapping(s) incorrect: %', v_bad_point_mappings;
    END IF;

    -- (e) no dangling FK: every logical_point with a measurement_group_id-
    --     bearing parameter actually resolves to a real group row.
    SELECT count(*) INTO v_dangling_count
    FROM config.parameters p
    LEFT JOIN config.canonical_measurement_groups g ON g.id = p.measurement_group_id
    WHERE p.measurement_group_id IS NOT NULL
      AND g.id IS NULL;
    IF v_dangling_count > 0 THEN
        RAISE EXCEPTION 'Migration 254 postcondition failed: % config.parameters row(s) have a measurement_group_id that does not resolve to a canonical_measurement_groups row', v_dangling_count;
    END IF;

    -- (f) display categories untouched: CURRENT_THD's parameter_category_id
    --     is exactly what migration 223 left it (still 'Current') -- proves
    --     this migration did not touch display categorization, per scope.
    IF EXISTS (
        SELECT 1
        FROM config.parameters p
        JOIN config.point_categories pc ON pc.id = p.parameter_category_id
        WHERE p.code = 'CURRENT_THD' AND pc.name <> 'Current'
    ) THEN
        RAISE EXCEPTION 'Migration 254 postcondition failed: CURRENT_THD parameter_category_id was unexpectedly changed -- display categories must remain untouched by this migration.';
    END IF;

    RAISE NOTICE 'Migration 254: all postconditions passed (7 canonical_measurement_groups seeded; measurement_group_id assigned per the approved v3 mapping; ACTIVE_POWER/REACTIVE_POWER_TOTAL/APPARENT_POWER_TOTAL/APPARENT_ENERGY_TOTAL logical_point coverage backfilled; display categories untouched).';
END;
$post$;
