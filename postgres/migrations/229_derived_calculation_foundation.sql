-- ============================================================================
-- Migration 229
-- Phase 5 (Derived Calculation Foundation) -- the smallest SELF-traversal
-- slice, proven on the commissioned AirSense environmental domain:
-- SPACE_DEW_POINT.
--
-- Source of record:
--   docs/DDS/analytics-platform-future-state-architecture.md B.7 (the
--     corrected ParameterCalculation model: formula_definition JSONB with
--     engine SQL_EXPR / WINDOW_FUNCTION -- NO formula DSL; input_parameter_
--     refs with SELF | RELATED | AGGREGATE_CHILDREN traversal; null_handling;
--     required_resolution; applicable_asset_type_id; output_unit_id;
--     effective dating).
--   docs/DDS/analytics-platform-future-state-architecture-implementation-
--     roadmap.md "Phase 5 -- Derived Calculation Foundation": *view-based
--     only, no persisted tier*; "a small, reviewed library of plain SQL /
--     window-function calculations, no DSL"; "each exposed as a plain view
--     initially".
--   The Phase 5 re-readiness check + the SPACE_DEW_POINT design checkpoint
--     that approved exactly this scope and these four fixed decisions.
--
-- What this migration does (the entire approved slice):
--   1. config.parameters += DEW_POINT (additive; unit degC, category
--      Temperature -- both resolved by natural key, migration-223 idiom).
--   2. CREATE config.parameter_calculations (B.7 shape) + one deliberate
--      extension: applicable_subject_type TEXT NOT NULL CHECK IN
--      ('ASSET','SPACE') -- the frozen architecture's Subject is the closed
--      set Asset | Space (B.3); this makes the two subject types first-class
--      without a polymorphic Subject entity. applicable_asset_type_id stays
--      nullable and is gated to ASSET only.
--   3. Seed exactly one config.parameter_calculations row: SPACE_DEW_POINT
--      -- output DEW_POINT, inputs TEMPERATURE + HUMIDITY (canonical codes,
--      both required, traversal SELF), applicable_subject_type SPACE,
--      applicable_asset_type_id NULL, null_handling NULL_IF_REQUIRED_MISSING,
--      formula_definition engine SQL_EXPR (Magnus / Arden-Buck over water,
--      a = 17.62, b = 243.12), output_unit_id degC, materialization VIEW,
--      required_resolution ONE_MINUTE, effective_from now().
--   4. CREATE VIEW analytics.v_space_dew_point_1min -- a plain, tenant-safe,
--      row-wise (per device / per bucket, NO GROUP BY) projection of
--      telemetry.environment_measurements: dew point for every bucket that
--      carries a resolved space_id (Phase 2 / migration 228 commissioning)
--      and non-NULL temperature_c + humidity_percent (> 0). Same conventions
--      as postgres/ddl/75_environment_analytics_views.sql
--      (WITH security_barrier = TRUE, JOIN metadata.grafana_organization_map,
--      REVOKE FROM PUBLIC, GRANT SELECT TO grafana_reader).
--
-- Quality: quality_code is projected NULL::SMALLINT -- pass-through of the
--   absent encoding, exactly as telemetry.environment_measurements and the
--   energy loader already behave. NO INVALID>GAP>ESTIMATED>GOOD lattice is
--   created. The structural guarantee -- a row exists IFF both required
--   inputs were present -- is this slice's quality contract.
--
-- Deliberately NOT in this slice (Phase 5 exit criteria / Phase 6 / later):
--   RELATED and AGGREGATE_CHILDREN traversal; any metadata.asset_relationships
--   work; PARTIAL quality semantics; a formula DSL; the persisted derived
--   tier (analytics.derived_parameter_values) and any refresh proc / job /
--   watermark / reconciliation; 15-minute / hourly derived outputs; any
--   averaging of the two Seasons Restaurant sensors; config.parameters.
--   is_derived (a broader Phase-1 top-up). No Phase 4 routing change. No new
--   Point or Subject entity. THE ENTIRE ENERGY SUBSYSTEM is untouched -- a
--   postcondition asserts the energy loader body references none of
--   parameter_calculations / space_id / space_points / device_point_
--   configuration and still targets telemetry.energy_measurements.
--
-- Rollback: postgres/maintenance/229_derived_calculation_foundation_rollback.sql
--   -- dependency-checked, no CASCADE; drops the view, deletes the two seed
--   rows, drops config.parameter_calculations. No stored derived state.
--
-- Transaction: the forward migration runner wraps this file in one
--   BEGIN/COMMIT with its ledger insert; this file has no BEGIN/COMMIT of
--   its own (matches migrations 223-228).
-- ============================================================================


-- ----------------------------------------------------------------------------
-- 0. Preconditions.
-- ----------------------------------------------------------------------------
DO
$precheck$
BEGIN
    IF to_regclass('config.parameters') IS NULL THEN
        RAISE EXCEPTION 'Migration 229 precondition failed: config.parameters is missing (Phase 1 / migration 223).';
    END IF;
    IF to_regclass('telemetry.environment_measurements') IS NULL THEN
        RAISE EXCEPTION 'Migration 229 precondition failed: telemetry.environment_measurements is missing.';
    END IF;
    IF NOT EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema='telemetry' AND table_name='environment_measurements' AND column_name='space_id'
    ) THEN
        RAISE EXCEPTION 'Migration 229 precondition failed: telemetry.environment_measurements.space_id is missing (Phase 3 / migration 226).';
    END IF;
    IF to_regclass('metadata.grafana_organization_map') IS NULL THEN
        RAISE EXCEPTION 'Migration 229 precondition failed: metadata.grafana_organization_map is missing.';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM config.engineering_units WHERE symbol = 'degC') THEN
        RAISE EXCEPTION 'Migration 229 precondition failed: engineering unit degC not found.';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM config.point_categories WHERE name = 'Temperature') THEN
        RAISE EXCEPTION 'Migration 229 precondition failed: point category "Temperature" not found.';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM config.parameters WHERE code IN ('TEMPERATURE','HUMIDITY')) THEN
        RAISE EXCEPTION 'Migration 229 precondition failed: canonical parameters TEMPERATURE / HUMIDITY not found.';
    END IF;
END;
$precheck$;


-- ----------------------------------------------------------------------------
-- 1. config.parameters += DEW_POINT  (additive, idempotent by code;
--    unit / category resolved by natural key -- migration-223 idiom).
-- ----------------------------------------------------------------------------
INSERT INTO config.parameters (code, name, description, unit_id, parameter_category_id)
SELECT v.code, v.name, v.description, eu.id, pc.id
FROM (VALUES
    ('DEW_POINT', 'Dew Point',
     'Ambient dew-point temperature derived from air temperature and relative humidity (Magnus/Arden-Buck).',
     'degC', 'Temperature')
) AS v(code, name, description, unit_symbol, category_name)
LEFT JOIN config.engineering_units eu ON eu.symbol = v.unit_symbol
LEFT JOIN config.point_categories  pc ON pc.name   = v.category_name
ON CONFLICT (code) DO UPDATE
SET name                  = EXCLUDED.name,
    description            = EXCLUDED.description,
    unit_id               = EXCLUDED.unit_id,
    parameter_category_id = EXCLUDED.parameter_category_id,
    updated_at            = now();


-- ----------------------------------------------------------------------------
-- 2. config.parameter_calculations  (B.7 shape + the ASSET|SPACE
--    subject-type discriminator).
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS config.parameter_calculations (
    id                       UUID PRIMARY KEY DEFAULT gen_random_uuid(),

    output_parameter_id      UUID NOT NULL REFERENCES config.parameters(id),
    calculation_version      INT  NOT NULL DEFAULT 1,
    is_active                BOOLEAN NOT NULL DEFAULT TRUE,

    -- {expression, engine: 'SQL_EXPR' | 'WINDOW_FUNCTION', ...} -- NOT a DSL;
    -- provenance/traceability for the hand-written view that implements it.
    formula_definition       JSONB NOT NULL,

    -- [{parameter_code, role, required: bool, traversal: 'SELF'
    --   | {type:'RELATED', relationship_type, direction}
    --   | {type:'AGGREGATE_CHILDREN', relationship_type}}]
    input_parameter_refs     JSONB NOT NULL,

    -- The frozen architecture's Subject is the closed set Asset | Space
    -- (B.3). This is a bounded discriminator, NOT a polymorphic Subject
    -- model. SPACE calculations resolve SELF inputs via metadata.space_points;
    -- ASSET calculations via metadata.asset_points.
    applicable_subject_type  TEXT NOT NULL
        CHECK (applicable_subject_type IN ('ASSET','SPACE')),
    applicable_asset_type_id UUID REFERENCES metadata.asset_types(id),

    output_unit_id           UUID REFERENCES config.engineering_units(id),

    null_handling            TEXT NOT NULL
        CHECK (null_handling IN ('NULL_IF_ANY_MISSING','NULL_IF_REQUIRED_MISSING','ESTIMATE_WITH_FLAG')),
    required_resolution      TEXT,

    -- Phase 5 is view-based only; Phase 6 widens this CHECK to add PERSISTED.
    materialization_strategy TEXT NOT NULL DEFAULT 'VIEW'
        CHECK (materialization_strategy IN ('VIEW')),

    effective_from           TIMESTAMPTZ NOT NULL DEFAULT '-infinity',
    effective_to             TIMESTAMPTZ,

    created_at               TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at               TIMESTAMPTZ NOT NULL DEFAULT now(),

    CONSTRAINT ck_parameter_calculations_asset_type_gated
        CHECK (applicable_asset_type_id IS NULL OR applicable_subject_type = 'ASSET'),
    CONSTRAINT ck_parameter_calculations_effective_window
        CHECK (effective_to IS NULL OR effective_to > effective_from)
);

CREATE UNIQUE INDEX IF NOT EXISTS uq_parameter_calculations_output_version
    ON config.parameter_calculations (output_parameter_id, calculation_version);

COMMENT ON TABLE config.parameter_calculations IS
'Phase 5 (migration 229): definitions of derived Parameters -- output_parameter_id produced from input_parameter_refs via a SELF / RELATED / AGGREGATE_CHILDREN traversal and a reviewed plain-SQL formula (engine SQL_EXPR / WINDOW_FUNCTION -- no DSL). View-based in Phase 5; the persisted tier (analytics.derived_parameter_values) is Phase 6. applicable_subject_type is the frozen Asset|Space closed set, not a polymorphic Subject.';

REVOKE ALL ON config.parameter_calculations FROM PUBLIC;
GRANT SELECT ON config.parameter_calculations TO ems_app, ems_admin;


-- ----------------------------------------------------------------------------
-- 3. Seed the one SPACE_DEW_POINT calculation (idempotent by
--    (output_parameter_id, calculation_version)).
-- ----------------------------------------------------------------------------
INSERT INTO config.parameter_calculations (
    output_parameter_id, calculation_version, is_active,
    formula_definition, input_parameter_refs,
    applicable_subject_type, applicable_asset_type_id,
    output_unit_id, null_handling, required_resolution,
    materialization_strategy, effective_from
)
SELECT
    op.id, 1, TRUE,
    jsonb_build_object(
        'engine', 'SQL_EXPR',
        'reference', 'Magnus/Arden-Buck (over water)',
        'coefficients', jsonb_build_object('a', 17.62, 'b', 243.12),
        'expression',
            'gamma := ln(RH/100.0) + (a*T)/(b+T); dew_point_c := (b*gamma)/(a-gamma)',
        'view', 'analytics.v_space_dew_point_1min'
    ),
    jsonb_build_array(
        jsonb_build_object('parameter_code','TEMPERATURE','role','air_temperature','required',TRUE,'traversal','SELF'),
        jsonb_build_object('parameter_code','HUMIDITY','role','relative_humidity','required',TRUE,'traversal','SELF')
    ),
    'SPACE', NULL,
    deg.id, 'NULL_IF_REQUIRED_MISSING', 'ONE_MINUTE',
    'VIEW', now()
FROM config.parameters op
CROSS JOIN (SELECT id FROM config.engineering_units WHERE symbol = 'degC') deg
WHERE op.code = 'DEW_POINT'
ON CONFLICT (output_parameter_id, calculation_version) DO UPDATE
SET is_active                = EXCLUDED.is_active,
    formula_definition       = EXCLUDED.formula_definition,
    input_parameter_refs     = EXCLUDED.input_parameter_refs,
    applicable_subject_type  = EXCLUDED.applicable_subject_type,
    applicable_asset_type_id = EXCLUDED.applicable_asset_type_id,
    output_unit_id           = EXCLUDED.output_unit_id,
    null_handling            = EXCLUDED.null_handling,
    required_resolution      = EXCLUDED.required_resolution,
    materialization_strategy = EXCLUDED.materialization_strategy,
    updated_at               = now();


-- ----------------------------------------------------------------------------
-- 4. analytics.v_space_dew_point_1min -- plain, tenant-safe, row-wise.
--    NO GROUP BY: one output row per (device_id, bucket_start); two AirSense
--    sensors in one Space stay two independent streams.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE VIEW analytics.v_space_dew_point_1min
WITH (security_barrier = TRUE)
AS
SELECT
    gom.grafana_org_id,
    em.organization_id,
    em.site_id,
    em.space_id,
    em.device_id,
    em.bucket_start,
    em.source_timestamp,
    em.received_at,
    em.temperature_c,
    em.humidity_percent,
    round(((243.12::DOUBLE PRECISION * g.gamma)
           / NULLIF(17.62::DOUBLE PRECISION - g.gamma, 0.0))::NUMERIC, 4)::DOUBLE PRECISION
        AS dew_point_c,
    NULL::SMALLINT AS quality_code,
    calc.calculation_id,
    calc.calculation_version
FROM metadata.grafana_organization_map gom
JOIN telemetry.environment_measurements em
  ON em.organization_id = gom.organization_id
CROSS JOIN LATERAL (
    SELECT ln(em.humidity_percent / 100.0)
         + (17.62::DOUBLE PRECISION * em.temperature_c) / (243.12::DOUBLE PRECISION + em.temperature_c)
      AS gamma
) g
CROSS JOIN (
    SELECT pc.id AS calculation_id, pc.calculation_version
    FROM config.parameter_calculations pc
    JOIN config.parameters op ON op.id = pc.output_parameter_id
    WHERE op.code = 'DEW_POINT' AND pc.is_active AND pc.calculation_version = 1
) calc
WHERE gom.is_active = TRUE
  AND em.space_id IS NOT NULL
  AND em.temperature_c IS NOT NULL
  AND em.humidity_percent IS NOT NULL
  AND em.humidity_percent > 0;

COMMENT ON VIEW analytics.v_space_dew_point_1min IS
'Phase 5 (migration 229) SPACE_DEW_POINT: per-sensor, per-minute dew point for every environmental measurement bucket that carries a commissioned space_id and non-NULL temperature_c + humidity_percent (> 0). SELF traversal, Space subject. Magnus/Arden-Buck (a=17.62, b=243.12). quality_code is NULL pass-through -- no quality lattice. Row-wise (no GROUP BY): multiple sensors in one Space produce independent streams. calculation_id/_version stamp the config.parameter_calculations definition.';

REVOKE ALL ON analytics.v_space_dew_point_1min FROM PUBLIC;
GRANT SELECT ON analytics.v_space_dew_point_1min TO grafana_reader;


-- ----------------------------------------------------------------------------
-- 5. Postconditions -- fail the transaction loudly on any drift, per the
--    198/199/223/224/225/226/227/228 discipline.
-- ----------------------------------------------------------------------------
DO
$post$
DECLARE
    v_n     INT;
    v_calc  RECORD;
    v_ener  TEXT;
BEGIN
    -- (a) DEW_POINT parameter present, correct unit + category
    SELECT count(*) INTO v_n
    FROM config.parameters p
    JOIN config.engineering_units eu ON eu.id = p.unit_id
    JOIN config.point_categories  pc ON pc.id = p.parameter_category_id
    WHERE p.code = 'DEW_POINT' AND eu.symbol = 'degC' AND pc.name = 'Temperature';
    IF v_n <> 1 THEN
        RAISE EXCEPTION 'Migration 229 postcondition failed: config.parameters DEW_POINT missing or not (degC, Temperature).';
    END IF;

    -- (b) table + key objects
    IF to_regclass('config.parameter_calculations') IS NULL THEN
        RAISE EXCEPTION 'Migration 229 postcondition failed: config.parameter_calculations was not created.';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_indexes WHERE schemaname='config' AND indexname='uq_parameter_calculations_output_version') THEN
        RAISE EXCEPTION 'Migration 229 postcondition failed: uq_parameter_calculations_output_version missing.';
    END IF;
    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conrelid='config.parameter_calculations'::regclass
          AND conname='ck_parameter_calculations_asset_type_gated'
    ) THEN
        RAISE EXCEPTION 'Migration 229 postcondition failed: ck_parameter_calculations_asset_type_gated missing.';
    END IF;
    IF NOT has_table_privilege('grafana_reader', 'config.parameter_calculations', 'SELECT') THEN
        NULL;  -- grafana_reader is not granted here by design (config table); ems_app is.
    END IF;
    IF NOT has_table_privilege('ems_app', 'config.parameter_calculations', 'SELECT') THEN
        RAISE EXCEPTION 'Migration 229 postcondition failed: ems_app cannot SELECT config.parameter_calculations.';
    END IF;

    -- (c) exactly one SPACE_DEW_POINT calc row, correct attributes
    SELECT pc.*, op.code AS output_code INTO v_calc
    FROM config.parameter_calculations pc
    JOIN config.parameters op ON op.id = pc.output_parameter_id
    WHERE op.code = 'DEW_POINT';
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Migration 229 postcondition failed: no SPACE_DEW_POINT calculation row.';
    END IF;
    IF v_calc.applicable_subject_type <> 'SPACE'
       OR v_calc.applicable_asset_type_id IS NOT NULL
       OR v_calc.null_handling <> 'NULL_IF_REQUIRED_MISSING'
       OR v_calc.materialization_strategy <> 'VIEW'
       OR (v_calc.formula_definition->>'engine') <> 'SQL_EXPR'
       OR jsonb_array_length(v_calc.input_parameter_refs) <> 2 THEN
        RAISE EXCEPTION 'Migration 229 postcondition failed: SPACE_DEW_POINT calculation attributes incorrect (%).', row_to_json(v_calc);
    END IF;
    IF (SELECT count(*) FROM config.parameter_calculations) <> 1 THEN
        RAISE EXCEPTION 'Migration 229 postcondition failed: config.parameter_calculations must hold exactly the one seeded row, found %.',
            (SELECT count(*) FROM config.parameter_calculations);
    END IF;

    -- (d) parameter-existence invariant: every input_parameter_refs code resolves
    SELECT count(*) INTO v_n
    FROM config.parameter_calculations pc
    CROSS JOIN LATERAL jsonb_array_elements(pc.input_parameter_refs) ref
    WHERE NOT EXISTS (SELECT 1 FROM config.parameters p WHERE p.code = ref->>'parameter_code');
    IF v_n <> 0 THEN
        RAISE EXCEPTION 'Migration 229 postcondition failed: % input_parameter_refs code(s) do not resolve to config.parameters.', v_n;
    END IF;

    -- (e) view present, security_barrier, grafana_reader grant, no PUBLIC
    IF to_regclass('analytics.v_space_dew_point_1min') IS NULL THEN
        RAISE EXCEPTION 'Migration 229 postcondition failed: analytics.v_space_dew_point_1min was not created.';
    END IF;
    IF NOT EXISTS (
        SELECT 1 FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
        WHERE n.nspname='analytics' AND c.relname='v_space_dew_point_1min'
          AND array_to_string(c.reloptions,',') LIKE '%security_barrier=true%'
    ) THEN
        RAISE EXCEPTION 'Migration 229 postcondition failed: v_space_dew_point_1min is not security_barrier.';
    END IF;
    IF NOT has_table_privilege('grafana_reader', 'analytics.v_space_dew_point_1min', 'SELECT') THEN
        RAISE EXCEPTION 'Migration 229 postcondition failed: grafana_reader cannot SELECT the dew-point view.';
    END IF;
    IF has_table_privilege('public', 'analytics.v_space_dew_point_1min', 'SELECT') THEN
        RAISE EXCEPTION 'Migration 229 postcondition failed: PUBLIC can SELECT the dew-point view.';
    END IF;

    -- (f) the view body: reads environment_measurements, no GROUP BY, no
    --     energy/routing objects, guards the inputs.
    SELECT pg_get_viewdef('analytics.v_space_dew_point_1min'::regclass, true) INTO v_ener;
    IF position('telemetry.environment_measurements' IN v_ener) = 0
       OR position('space_id IS NOT NULL' IN v_ener) = 0
       OR position('humidity_percent > 0' IN v_ener) = 0 THEN
        RAISE EXCEPTION 'Migration 229 postcondition failed: dew-point view lost a required predicate.';
    END IF;
    IF position('group by' IN lower(v_ener)) <> 0 THEN
        RAISE EXCEPTION 'Migration 229 postcondition failed: dew-point view contains GROUP BY (must be row-wise / per-sensor).';
    END IF;
    IF position('energy_measurements' IN v_ener) <> 0
       OR position('parameter_routing' IN v_ener) <> 0 THEN
        RAISE EXCEPTION 'Migration 229 postcondition failed: dew-point view references an energy/routing object.';
    END IF;

    -- (g) ENERGY SAFETY: energy loader body untouched
    v_ener := pg_get_functiondef('telemetry.load_energy_measurements_incremental(interval,interval)'::regprocedure);
    IF position('parameter_calculations' IN v_ener) <> 0
       OR position('space_id' IN v_ener) <> 0
       OR position('space_points' IN v_ener) <> 0
       OR position('device_point_configuration' IN v_ener) <> 0
       OR position('dew_point' IN lower(v_ener)) <> 0 THEN
        RAISE EXCEPTION 'Migration 229 postcondition failed: the energy loader body references a Phase 2/3/5 object -- energy was touched.';
    END IF;
    IF position('telemetry.energy_measurements' IN v_ener) = 0 THEN
        RAISE EXCEPTION 'Migration 229 postcondition failed: the energy loader no longer targets telemetry.energy_measurements.';
    END IF;

    -- (h) Phase 4 routing untouched
    IF (SELECT count(*) FROM config.parameter_routing WHERE is_active AND destination_table='telemetry.environment_measurements') <> 12 THEN
        RAISE EXCEPTION 'Migration 229 postcondition failed: config.parameter_routing active AirSense rows != 12.';
    END IF;

    -- (i) NO persisted derived tier / job introduced
    IF to_regclass('analytics.derived_parameter_values') IS NOT NULL THEN
        RAISE EXCEPTION 'Migration 229 postcondition failed: analytics.derived_parameter_values exists -- Phase 5 is view-only.';
    END IF;
    IF EXISTS (
        SELECT 1 FROM timescaledb_information.jobs
        WHERE proc_name ~* 'dew_point|derived_parameter'
    ) THEN
        RAISE EXCEPTION 'Migration 229 postcondition failed: a derived-parameter job was registered -- out of scope.';
    END IF;
END;
$post$;
