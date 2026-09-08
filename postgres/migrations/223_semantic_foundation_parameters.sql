-- ============================================================================
-- Migration 223
-- Phase 1 (Semantic Foundation) of the EMS Analytics Platform future-state
-- architecture (docs/DDS/analytics-platform-future-state-architecture.md,
-- §B.3; roadmap docs/DDS/analytics-platform-future-state-architecture-
-- implementation-roadmap.md, "Phase 1 -- Semantic Foundation").
--
-- Purpose
-- -------------------------------------------------------------------------
-- Introduce Parameter as a canonical registry of measurement MEANING
-- (e.g. "Current", "Temperature"), distinct from metadata.logical_points,
-- which today conflates meaning with point-level qualifiers (CURRENT_L1 vs
-- CURRENT_L2 vs CURRENT_TOTAL are one parameter, three qualified points).
-- Adds:
--   * config.parameters                       (new)
--   * metadata.logical_points.parameter_id    (new, nullable FK)
--   * metadata.logical_points.qualifier       (new, nullable)
-- and backfills both for the evidence-backed subset of the two live
-- profiles' logical points (ENERGY_METER_ENISCOPE_V1,
-- ENVIRONMENT_SENSOR_AIRSENSE_V1), per
-- docs/platform-manual/reference/telemetry-field-catalog.md (the confirmed-
-- live 50-point Eniscope enumeration) and the AirSense field-semantics
-- comments in postgres/ddl/117_expand_environment_sensor_profile_and_
-- storage.sql / postgres/seeds/reference/65_environment_sensor_profile.sql.
--
-- No routing, loader, job, Grafana, or application code is touched.
-- parameter_id/qualifier are new, nullable, currently-unread columns --
-- nothing downstream resolves through them yet, so this migration carries
-- zero behavioral risk to ingestion or analytics.
--
-- Scope discipline (deliberately narrower than the roadmap doc's fuller
-- Phase 1 backend bullet -- see design-checkpoint discussion; the roadmap's
-- config.value_kind / aggregation_method / direction_of_good /
-- interpolation_policy / is_derived, config.parameter_asset_type_
-- applicability, and new config.status_definitions rows are NOT part of
-- this migration; none is needed to satisfy the stated Phase 1 exit
-- criterion -- "a read-only query resolves logical_point -> parameter +
-- qualifier purely from configuration" -- and each would be a half-built
-- invariant with no consumer to validate against until Phase 2/6 supplies
-- the other half. Revisit then, not here.):
--   * config.parameters carries only: code, name, description, unit_id,
--     parameter_category_id, created_at, updated_at.
--   * parameter_category_id repurposes the existing, currently-unused
--     config.point_categories table (per the frozen architecture doc)
--     rather than inventing a new one.
--   * Mapping coverage is evidence-backed and intentionally partial: 42 of
--     the 50 live Eniscope points and 6 of the 12 AirSense points are
--     mapped; the rest are left with parameter_id/qualifier = NULL because
--     their meaning (not merely their unit/scale) is undocumented or
--     genuinely direction-ambiguous. See the per-field rationale below.
--     Coverage completeness is explicitly NOT the acceptance criterion.
--
-- Deferred/unmapped, by reason (documented per the design-checkpoint
-- discussion, not guessed):
--   * Reactive-energy REGISTER fields (ENERGY_REACTIVE_ENERGY_L1/L2/L3,
--     ENERGY_REACTIVE_EXPORT_L1/L2/L3, ENERGY_REACTIVE_EXPORT_TOTAL --
--     7 points): active energy explicitly labels both IMPORT and EXPORT;
--     reactive energy labels only EXPORT and leaves a bare, unlabeled
--     register with no confirming source for which direction it
--     represents. Genuinely ambiguous -- left unmapped.
--   * PULSE_COUNT (1 Eniscope point) and PULSE_INPUT_1_RAW /
--     EXTERNAL_SENSOR_INPUT_{1..4}_RAW (5 AirSense points): the source
--     documentation itself says these are generic pulse/analog inputs
--     whose physical meaning depends on what is wired to them --
--     installation-dependent, not a fixed EMS concept. Left unmapped.
--   * DEVICE_STATUS_CODE (1 AirSense point): an undocumented vendor status
--     code (no decode table for what any value means) and conceptually
--     device-health/diagnostic metadata, not a physical measurement.
--     Left unmapped.
--   * OCCUPANCY_ACTIVITY (PIR, AirSense) is the one deliberate exception to
--     "unit unknown => unmapped": postgres/seeds/reference/
--     64_environment_sensor_extensions.sql's own comment confirms the
--     MEANING (occupancy/motion activity) while explicitly deferring only
--     the numeric scale ("not yet confirmed as seconds, counts, intensity,
--     or another vendor-specific measure"). Mapped with unit_id = NULL;
--     the scale/unit remains a separately tracked open item, not invented.
--
-- Rollback: see postgres/maintenance/223_rollback_semantic_foundation_
-- parameters.sql -- a controlled, dependency-checked reversal, not a bare
-- DROP ... CASCADE. Not run as part of this migration.
-- ============================================================================


-- ----------------------------------------------------------------------------
-- 1. New reference-data rows this migration's Parameter catalogue needs.
--    Additive, idempotent, same idiom as the existing seeds (e.g. 'lux',
--    'deg', 'count', 's' were each added the same way as new sensor types
--    arrived).
-- ----------------------------------------------------------------------------

INSERT INTO config.engineering_units (symbol, description)
VALUES
    ('VAR',  'Reactive power in volt-amperes reactive'),
    ('VA',   'Apparent power in volt-amperes'),
    ('kVAh', 'Apparent energy in kilovolt-ampere-hours')
ON CONFLICT (symbol) DO UPDATE
SET description = EXCLUDED.description;

INSERT INTO config.point_categories (name, description)
VALUES
    ('Illuminance', 'Ambient light level measurement'),
    ('Occupancy',   'Occupancy or motion activity measurement')
ON CONFLICT (name) DO NOTHING;


-- ----------------------------------------------------------------------------
-- 2. config.parameters -- canonical measurement-meaning registry.
-- ----------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS config.parameters (
    id                     UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    code                   TEXT NOT NULL,
    name                   TEXT NOT NULL,
    description            TEXT,
    unit_id                UUID REFERENCES config.engineering_units(id),
    parameter_category_id  UUID REFERENCES config.point_categories(id),
    created_at             TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at             TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE UNIQUE INDEX IF NOT EXISTS uq_parameters_code
    ON config.parameters (code);

COMMENT ON TABLE config.parameters IS
'Phase 1 semantic foundation: canonical measurement meaning (e.g. CURRENT, TEMPERATURE), distinct from metadata.logical_points, which represents point-level occurrences and phase/axis qualifiers of a parameter. Added by migration 223.';

GRANT SELECT ON config.parameters TO ems_app, ems_admin;


-- ----------------------------------------------------------------------------
-- 3. metadata.logical_points.parameter_id / qualifier.
--    Both nullable; every existing row starts NULL/NULL and every existing
--    consumer of logical_points continues to read name/unit_id/id unchanged.
-- ----------------------------------------------------------------------------

ALTER TABLE metadata.logical_points
    ADD COLUMN IF NOT EXISTS parameter_id UUID REFERENCES config.parameters(id),
    ADD COLUMN IF NOT EXISTS qualifier    TEXT;

ALTER TABLE metadata.logical_points
    DROP CONSTRAINT IF EXISTS chk_logical_points_qualifier_requires_parameter;

ALTER TABLE metadata.logical_points
    ADD CONSTRAINT chk_logical_points_qualifier_requires_parameter
    CHECK (qualifier IS NULL OR parameter_id IS NOT NULL);

-- A given (parameter, qualifier) pair may be claimed by at most one logical
-- point -- e.g. CURRENT_L1 and CURRENT_L2 are different qualifiers of one
-- parameter, never duplicates of the same one. COALESCE(qualifier,'') gives
-- NULL-qualifier parameters (single-instance measurements) the same
-- uniqueness guarantee, mirroring the existing
-- metadata.device_models_vendor_model_ci_uq idiom for a nullable uniqueness
-- column.
CREATE UNIQUE INDEX IF NOT EXISTS uq_logical_points_parameter_qualifier
    ON metadata.logical_points (parameter_id, COALESCE(qualifier, ''))
    WHERE parameter_id IS NOT NULL;

COMMENT ON COLUMN metadata.logical_points.parameter_id IS
'Phase 1 semantic foundation (migration 223): canonical measurement meaning this point instance belongs to. NULL = not yet mapped (intentionally, for genuinely ambiguous/undocumented points, or simply not yet evaluated).';
COMMENT ON COLUMN metadata.logical_points.qualifier IS
'Phase 1 semantic foundation (migration 223): distinguishes repeated simultaneous instances of the same physical measurement (L1/L2/L3/NEUTRAL/TOTAL/L12/L23/L31/AVG). Never used to encode "which instance of a repeated piece of equipment" -- that is a Subject/AssetPoint binding (Phase 2), not a qualifier.';


-- ----------------------------------------------------------------------------
-- 4. Parameter catalogue (18 rows): 12 Eniscope-derived, 6 AirSense-derived.
--    Idempotent by code; unit_id/parameter_category_id resolved by natural
--    key so re-running is a no-op once applied.
-- ----------------------------------------------------------------------------

INSERT INTO config.parameters (code, name, description, unit_id, parameter_category_id)
SELECT v.code, v.name, v.description, eu.id, pc.id
FROM (VALUES
    -- Eniscope (ENERGY_METER_ENISCOPE_V1)
    ('CURRENT',          'Current',                       'Electrical current magnitude, per phase, neutral, or total.',              'A',    'Current'),
    ('CURRENT_THD',       'Current Total Harmonic Distortion', 'Total harmonic distortion of current, per phase or total.',           '%',    'Current'),
    ('VOLTAGE_LINE_NEUTRAL', 'Voltage (Line-Neutral)',     'Phase-to-neutral voltage, per phase or averaged.',                         'V',    'Voltage'),
    ('VOLTAGE_LINE_LINE', 'Voltage (Line-Line)',            'Phase-to-phase voltage, per phase pair or averaged.',                     'V',    'Voltage'),
    ('ENERGY_IMPORT',     'Active Energy Import',           'Accumulated active energy imported from the grid, per phase or total.',   'kWh',  'Energy'),
    ('ENERGY_EXPORT',     'Active Energy Export',           'Accumulated active energy exported to the grid, per phase or total.',     'kWh',  'Energy'),
    ('REACTIVE_POWER',    'Reactive Power',                 'Instantaneous reactive power, per phase.',                                 'VAR',  NULL),
    ('APPARENT_POWER',    'Apparent Power',                 'Instantaneous apparent power, per phase.',                                 'VA',   NULL),
    ('APPARENT_ENERGY',   'Apparent Energy',                'Accumulated apparent energy, per phase.',                                  'kVAh', 'Energy'),
    ('POWER_FACTOR',      'Power Factor',                   'Ratio of real to apparent power, per phase or total. Dimensionless.',      NULL,   NULL),
    ('FREQUENCY',         'Frequency',                      'Electrical supply frequency.',                                             'Hz',   NULL),
    ('PHASE_ANGLE',       'Phase Angle',                     'Voltage/current phase angle, per phase.',                                 'deg',  NULL),
    -- AirSense (ENVIRONMENT_SENSOR_AIRSENSE_V1)
    ('TEMPERATURE',       'Temperature',                     'Ambient temperature.',                                                     'degC', 'Temperature'),
    ('HUMIDITY',          'Relative Humidity',              'Ambient relative humidity.',                                               '%',    'Humidity'),
    ('ILLUMINANCE',       'Illuminance',                     'Ambient light level.',                                                     'lux',  'Illuminance'),
    ('BATTERY_VOLTAGE',   'Battery Voltage',                'Device power-supply battery voltage (device health/diagnostic, not a mains measurement).', 'V', 'Voltage'),
    ('OCCUPANCY_TIME_SINCE_LAST_EVENT', 'Time Since Last Occupancy Event', 'Elapsed time since the most recent PIR occupancy event.',   's',    NULL),
    ('OCCUPANCY_ACTIVITY', 'Occupancy Activity',            'Raw occupancy/motion activity level from a PIR sensor. Meaning confirmed; numeric scale/unit not yet confirmed by vendor documentation -- deliberately left unitless rather than invented.', NULL, 'Occupancy')
) AS v(code, name, description, unit_symbol, category_name)
LEFT JOIN config.engineering_units eu ON eu.symbol = v.unit_symbol
LEFT JOIN config.point_categories pc ON pc.name = v.category_name
ON CONFLICT (code) DO UPDATE
SET name                  = EXCLUDED.name,
    description           = EXCLUDED.description,
    unit_id               = EXCLUDED.unit_id,
    parameter_category_id = EXCLUDED.parameter_category_id,
    updated_at            = now();


-- ----------------------------------------------------------------------------
-- 5. Mapping backfill (48 rows): metadata.logical_points.name -> Parameter
--    code + qualifier. Only evidence-backed points are listed here; every
--    other logical_point keeps parameter_id/qualifier = NULL untouched.
-- ----------------------------------------------------------------------------

UPDATE metadata.logical_points lp
SET parameter_id = p.id,
    qualifier    = m.qualifier
FROM (VALUES
    -- Current
    ('CURRENT_L1', 'CURRENT', 'L1'), ('CURRENT_L2', 'CURRENT', 'L2'), ('CURRENT_L3', 'CURRENT', 'L3'),
    ('CURRENT_NEUTRAL', 'CURRENT', 'NEUTRAL'), ('CURRENT_TOTAL', 'CURRENT', 'TOTAL'),
    ('CURRENT_THD_L1', 'CURRENT_THD', 'L1'), ('CURRENT_THD_L2', 'CURRENT_THD', 'L2'),
    ('CURRENT_THD_L3', 'CURRENT_THD', 'L3'), ('CURRENT_THD_TOTAL', 'CURRENT_THD', 'TOTAL'),
    -- Voltage
    ('VOLTAGE_L1', 'VOLTAGE_LINE_NEUTRAL', 'L1'), ('VOLTAGE_L2', 'VOLTAGE_LINE_NEUTRAL', 'L2'),
    ('VOLTAGE_L3', 'VOLTAGE_LINE_NEUTRAL', 'L3'), ('VOLTAGE_LN_AVG', 'VOLTAGE_LINE_NEUTRAL', 'AVG'),
    ('VOLTAGE_L12', 'VOLTAGE_LINE_LINE', 'L12'), ('VOLTAGE_L23', 'VOLTAGE_LINE_LINE', 'L23'),
    ('VOLTAGE_L31', 'VOLTAGE_LINE_LINE', 'L31'), ('VOLTAGE_LL_AVG', 'VOLTAGE_LINE_LINE', 'AVG'),
    -- Active energy
    ('ENERGY_IMPORT_L1', 'ENERGY_IMPORT', 'L1'), ('ENERGY_IMPORT_L2', 'ENERGY_IMPORT', 'L2'),
    ('ENERGY_IMPORT_L3', 'ENERGY_IMPORT', 'L3'), ('ENERGY_IMPORT_TOTAL', 'ENERGY_IMPORT', 'TOTAL'),
    ('ENERGY_EXPORT_L1', 'ENERGY_EXPORT', 'L1'), ('ENERGY_EXPORT_L2', 'ENERGY_EXPORT', 'L2'),
    ('ENERGY_EXPORT_L3', 'ENERGY_EXPORT', 'L3'), ('ENERGY_EXPORT_TOTAL', 'ENERGY_EXPORT', 'TOTAL'),
    -- Reactive/apparent power (instantaneous -- no directional ambiguity)
    ('ENERGY_REACTIVE_POWER_L1', 'REACTIVE_POWER', 'L1'), ('ENERGY_REACTIVE_POWER_L2', 'REACTIVE_POWER', 'L2'),
    ('ENERGY_REACTIVE_POWER_L3', 'REACTIVE_POWER', 'L3'),
    ('ENERGY_APPARENT_POWER_L1', 'APPARENT_POWER', 'L1'), ('ENERGY_APPARENT_POWER_L2', 'APPARENT_POWER', 'L2'),
    ('ENERGY_APPARENT_POWER_L3', 'APPARENT_POWER', 'L3'),
    -- Apparent energy (single register per phase -- no import/export split exists for this field)
    ('ENERGY_APPARENT_ENERGY_L1', 'APPARENT_ENERGY', 'L1'), ('ENERGY_APPARENT_ENERGY_L2', 'APPARENT_ENERGY', 'L2'),
    ('ENERGY_APPARENT_ENERGY_L3', 'APPARENT_ENERGY', 'L3'),
    -- Power quality
    ('POWER_FACTOR_L1', 'POWER_FACTOR', 'L1'), ('POWER_FACTOR_L2', 'POWER_FACTOR', 'L2'),
    ('POWER_FACTOR_L3', 'POWER_FACTOR', 'L3'), ('POWER_FACTOR_TOTAL', 'POWER_FACTOR', 'TOTAL'),
    ('FREQUENCY', 'FREQUENCY', NULL),
    ('PHASE_ANGLE_L1', 'PHASE_ANGLE', 'L1'), ('PHASE_ANGLE_L2', 'PHASE_ANGLE', 'L2'), ('PHASE_ANGLE_L3', 'PHASE_ANGLE', 'L3'),
    -- AirSense
    ('ENV_TEMPERATURE', 'TEMPERATURE', NULL),
    ('ENV_RELATIVE_HUMIDITY', 'HUMIDITY', NULL),
    ('ENV_ILLUMINANCE_LUX', 'ILLUMINANCE', NULL),
    ('DEVICE_BATTERY_VOLTAGE', 'BATTERY_VOLTAGE', NULL),
    ('OCCUPANCY_SECONDS_SINCE_LAST_PIR_EVENT', 'OCCUPANCY_TIME_SINCE_LAST_EVENT', NULL),
    ('OCCUPANCY_ACTIVITY', 'OCCUPANCY_ACTIVITY', NULL)
) AS m(logical_point_name, parameter_code, qualifier)
JOIN config.parameters p ON p.code = m.parameter_code
WHERE lp.name = m.logical_point_name;


-- ----------------------------------------------------------------------------
-- 6. Postconditions -- fail the transaction loudly on any drift from the
--    intended end state, per the migration 198/199/219 "fail loudly on
--    partial reference data" discipline. A typo'd logical_point/parameter
--    name here would otherwise silently update zero rows.
-- ----------------------------------------------------------------------------

DO $$
DECLARE
    v_parameter_count INTEGER;
    v_mapped_count    INTEGER;
    v_unmapped_names  TEXT[];
BEGIN
    SELECT count(*) INTO v_parameter_count
    FROM config.parameters
    WHERE code IN (
        'CURRENT','CURRENT_THD','VOLTAGE_LINE_NEUTRAL','VOLTAGE_LINE_LINE',
        'ENERGY_IMPORT','ENERGY_EXPORT','REACTIVE_POWER','APPARENT_POWER',
        'APPARENT_ENERGY','POWER_FACTOR','FREQUENCY','PHASE_ANGLE',
        'TEMPERATURE','HUMIDITY','ILLUMINANCE','BATTERY_VOLTAGE',
        'OCCUPANCY_TIME_SINCE_LAST_EVENT','OCCUPANCY_ACTIVITY'
    );
    IF v_parameter_count <> 18 THEN
        RAISE EXCEPTION
            'Migration 223 postcondition failed: expected 18 config.parameters rows, found %', v_parameter_count;
    END IF;

    SELECT array_agg(expected.name) INTO v_unmapped_names
    FROM (VALUES
        ('CURRENT_L1'),('CURRENT_L2'),('CURRENT_L3'),('CURRENT_NEUTRAL'),('CURRENT_TOTAL'),
        ('CURRENT_THD_L1'),('CURRENT_THD_L2'),('CURRENT_THD_L3'),('CURRENT_THD_TOTAL'),
        ('VOLTAGE_L1'),('VOLTAGE_L2'),('VOLTAGE_L3'),('VOLTAGE_LN_AVG'),
        ('VOLTAGE_L12'),('VOLTAGE_L23'),('VOLTAGE_L31'),('VOLTAGE_LL_AVG'),
        ('ENERGY_IMPORT_L1'),('ENERGY_IMPORT_L2'),('ENERGY_IMPORT_L3'),('ENERGY_IMPORT_TOTAL'),
        ('ENERGY_EXPORT_L1'),('ENERGY_EXPORT_L2'),('ENERGY_EXPORT_L3'),('ENERGY_EXPORT_TOTAL'),
        ('ENERGY_REACTIVE_POWER_L1'),('ENERGY_REACTIVE_POWER_L2'),('ENERGY_REACTIVE_POWER_L3'),
        ('ENERGY_APPARENT_POWER_L1'),('ENERGY_APPARENT_POWER_L2'),('ENERGY_APPARENT_POWER_L3'),
        ('ENERGY_APPARENT_ENERGY_L1'),('ENERGY_APPARENT_ENERGY_L2'),('ENERGY_APPARENT_ENERGY_L3'),
        ('POWER_FACTOR_L1'),('POWER_FACTOR_L2'),('POWER_FACTOR_L3'),('POWER_FACTOR_TOTAL'),
        ('FREQUENCY'),
        ('PHASE_ANGLE_L1'),('PHASE_ANGLE_L2'),('PHASE_ANGLE_L3'),
        ('ENV_TEMPERATURE'),('ENV_RELATIVE_HUMIDITY'),('ENV_ILLUMINANCE_LUX'),
        ('DEVICE_BATTERY_VOLTAGE'),('OCCUPANCY_SECONDS_SINCE_LAST_PIR_EVENT'),('OCCUPANCY_ACTIVITY')
    ) AS expected(name)
    WHERE NOT EXISTS (
        SELECT 1 FROM metadata.logical_points lp
        WHERE lp.name = expected.name AND lp.parameter_id IS NOT NULL
    );

    IF v_unmapped_names IS NOT NULL THEN
        RAISE EXCEPTION
            'Migration 223 postcondition failed: these intended logical points were not mapped (missing logical_point row, or name/code typo): %', v_unmapped_names;
    END IF;

    SELECT count(*) INTO v_mapped_count
    FROM metadata.logical_points
    WHERE parameter_id IS NOT NULL;
    IF v_mapped_count <> 48 THEN
        RAISE EXCEPTION
            'Migration 223 postcondition failed: expected exactly 48 mapped logical_points (intentional partial coverage), found %', v_mapped_count;
    END IF;

    -- Regression guard: intentionally-unmapped points must still be NULL --
    -- proves this migration did not accidentally widen coverage beyond the
    -- evidence-backed set above.
    IF EXISTS (
        SELECT 1 FROM metadata.logical_points
        WHERE name IN (
            'PULSE_COUNT',
            'PULSE_INPUT_1_RAW',
            'EXTERNAL_SENSOR_INPUT_1_RAW','EXTERNAL_SENSOR_INPUT_2_RAW',
            'EXTERNAL_SENSOR_INPUT_3_RAW','EXTERNAL_SENSOR_INPUT_4_RAW',
            'DEVICE_STATUS_CODE',
            'ENERGY_REACTIVE_ENERGY_L1','ENERGY_REACTIVE_ENERGY_L2','ENERGY_REACTIVE_ENERGY_L3',
            'ENERGY_REACTIVE_EXPORT_L1','ENERGY_REACTIVE_EXPORT_L2','ENERGY_REACTIVE_EXPORT_L3',
            'ENERGY_REACTIVE_EXPORT_TOTAL'
        )
        AND parameter_id IS NOT NULL
    ) THEN
        RAISE EXCEPTION
            'Migration 223 postcondition failed: an intentionally-unmapped logical point was unexpectedly mapped.';
    END IF;
END;
$$;
