-- ============================================================================
-- File:
--   77_energy_register_semantics.sql
--
-- Epic:
--   Epic 4 — Core Energy Analytics
--
-- Story:
--   4.1 — Formalize import/export register semantics
--
-- Purpose:
--   Define how cumulative energy registers emitted by each device profile must
--   be interpreted before interval consumption is calculated.
--
-- Architectural role:
--
--   config.profile_field_mapping answers:
--
--       Which raw field maps to which logical point?
--
--   config.energy_register_semantics answers:
--
--       How must that logical point behave as a cumulative energy register?
--
-- Units:
--
--   source_unit_symbol:
--       Unit emitted by the device profile after normalization.
--
--   normalized_unit_symbol:
--       Unit stored in telemetry.energy_measurements.
--
--   scale_to_normalized_unit:
--       Multiplier applied during routing.
--
--       Example:
--           Wh -> Wh = 1
--
-- Reliability:
--
--   This contract explicitly documents counter direction, rollover handling,
--   reset behavior, flow meaning, and a conservative profile-level maximum
--   interval delta.
--
--   Story 4.2 will introduce device/site-specific quality-rule overrides.
-- ============================================================================


CREATE TABLE IF NOT EXISTS config.energy_register_semantics
(
    id UUID PRIMARY KEY
        DEFAULT gen_random_uuid(),

    profile_id UUID NOT NULL
        REFERENCES config.device_profiles(id)
        ON DELETE CASCADE,

    logical_point_id UUID NOT NULL
        REFERENCES metadata.logical_points(id),

    source_unit_symbol TEXT NOT NULL,

    normalized_unit_symbol TEXT NOT NULL,

    scale_to_normalized_unit NUMERIC(24, 9) NOT NULL,

    counter_direction TEXT NOT NULL,

    rollover_behavior TEXT NOT NULL,

    rollover_value NUMERIC(30, 9),

    reset_behavior TEXT NOT NULL,

    flow_interpretation TEXT NOT NULL,

    expected_max_interval_delta NUMERIC(30, 9) NOT NULL,

    is_active BOOLEAN NOT NULL
        DEFAULT TRUE,

    created_at TIMESTAMPTZ NOT NULL
        DEFAULT now(),

    updated_at TIMESTAMPTZ NOT NULL
        DEFAULT now(),

    CONSTRAINT uq_energy_register_semantics_profile_point
        UNIQUE
        (
            profile_id,
            logical_point_id
        ),

    CONSTRAINT ck_energy_register_scale_positive
        CHECK
        (
            scale_to_normalized_unit > 0
        ),

    CONSTRAINT ck_energy_register_counter_direction
        CHECK
        (
            counter_direction IN
            (
                'INCREASING',
                'DECREASING',
                'BIDIRECTIONAL'
            )
        ),

    CONSTRAINT ck_energy_register_rollover_behavior
        CHECK
        (
            rollover_behavior IN
            (
                'NONE',
                'FIXED_MODULUS',
                'DEVICE_DEFINED'
            )
        ),

    CONSTRAINT ck_energy_register_rollover_value
        CHECK
        (
            (
                rollover_behavior = 'FIXED_MODULUS'
                AND rollover_value IS NOT NULL
                AND rollover_value > 0
            )
            OR
            (
                rollover_behavior <> 'FIXED_MODULUS'
                AND rollover_value IS NULL
            )
        ),

    CONSTRAINT ck_energy_register_reset_behavior
        CHECK
        (
            reset_behavior IN
            (
                'REJECT_DELTA',
                'ACCEPT_FROM_ZERO',
                'FLAG_ONLY'
            )
        ),

    CONSTRAINT ck_energy_register_flow_interpretation
        CHECK
        (
            flow_interpretation IN
            (
                'GRID_IMPORT',
                'GRID_EXPORT',
                'REACTIVE_IMPORT',
                'REACTIVE_EXPORT',
                'APPARENT_TOTAL',
                'GENERATION',
                'SITE_CONSUMPTION'
            )
        ),

    CONSTRAINT ck_energy_register_expected_delta_positive
        CHECK
        (
            expected_max_interval_delta > 0
        ),

    CONSTRAINT ck_energy_register_unit_symbols_not_blank
        CHECK
        (
            btrim(source_unit_symbol) <> ''
            AND btrim(normalized_unit_symbol) <> ''
        )
);


COMMENT ON TABLE config.energy_register_semantics IS
'Profile-specific declarative semantics for cumulative energy registers.';


COMMENT ON COLUMN config.energy_register_semantics.profile_id IS
'Device profile whose mapped cumulative register uses these semantics.';


COMMENT ON COLUMN config.energy_register_semantics.logical_point_id IS
'Canonical cumulative-energy logical point governed by this contract.';


COMMENT ON COLUMN config.energy_register_semantics.source_unit_symbol IS
'Unit emitted by the mapped profile field after normalization, such as kWh.';


COMMENT ON COLUMN config.energy_register_semantics.normalized_unit_symbol IS
'Unit stored in the telemetry domain table, such as Wh.';


COMMENT ON COLUMN config.energy_register_semantics.scale_to_normalized_unit IS
'Multiplier converting the profile source unit into the telemetry storage unit.';


COMMENT ON COLUMN config.energy_register_semantics.counter_direction IS
'Expected progression of the cumulative counter.';


COMMENT ON COLUMN config.energy_register_semantics.rollover_behavior IS
'Whether and how the cumulative register rolls over.';


COMMENT ON COLUMN config.energy_register_semantics.rollover_value IS
'Counter modulus when rollover_behavior is FIXED_MODULUS.';


COMMENT ON COLUMN config.energy_register_semantics.reset_behavior IS
'How interval analytics must handle a counter decrease that is not a rollover.';


COMMENT ON COLUMN config.energy_register_semantics.flow_interpretation IS
'Physical interpretation of accumulated energy represented by the register.';


COMMENT ON COLUMN config.energy_register_semantics.expected_max_interval_delta IS
'Conservative profile-level maximum plausible interval delta, expressed in normalized_unit_symbol.';


CREATE INDEX IF NOT EXISTS idx_energy_register_semantics_profile
ON config.energy_register_semantics
(
    profile_id
)
WHERE is_active = TRUE;


CREATE INDEX IF NOT EXISTS idx_energy_register_semantics_logical_point
ON config.energy_register_semantics
(
    logical_point_id
)
WHERE is_active = TRUE;


-- ----------------------------------------------------------------------------
-- Seed the supported Eniscope energy-meter profile.
--
-- The existing system treats every counter decrease as a reset, so rollover is
-- declared NONE until device documentation confirms a fixed register modulus.
--
-- Conservative initial plausibility ceilings:
--
--   Active/reactive energy:
--       1,000,000 Wh or varh per analytics interval.
--
--   Apparent energy:
--       1,500,000 VAh per analytics interval.
--
-- These are profile defaults. Story 4.2 will support narrower site/device
-- overrides based on actual meter rating and expected sampling behavior.
-- ----------------------------------------------------------------------------

WITH required_semantics
(
    profile_code,
    logical_point_name,
    source_unit_symbol,
    normalized_unit_symbol,
    scale_to_normalized_unit,
    counter_direction,
    rollover_behavior,
    rollover_value,
    reset_behavior,
    flow_interpretation,
    expected_max_interval_delta
)
AS
(
    VALUES
    (
        'ENERGY_METER_ENISCOPE_V1',
        'ENERGY_IMPORT_TOTAL',
        'Wh',
        'Wh',
        1.0,
        'INCREASING',
        'NONE',
        NULL::NUMERIC,
        'REJECT_DELTA',
        'GRID_IMPORT',
        1000000.0
    ),
    (
        'ENERGY_METER_ENISCOPE_V1',
        'ENERGY_EXPORT_TOTAL',
        'Wh',
        'Wh',
        1.0,
        'INCREASING',
        'NONE',
        NULL::NUMERIC,
        'REJECT_DELTA',
        'GRID_EXPORT',
        1000000.0
    ),
    (
        'ENERGY_METER_ENISCOPE_V1',
        'ENERGY_REACTIVE_ENERGY_TOTAL',
        'varh',
        'varh',
        1.0,
        'INCREASING',
        'NONE',
        NULL::NUMERIC,
        'REJECT_DELTA',
        'REACTIVE_IMPORT',
        1000000.0
    ),
    (
        'ENERGY_METER_ENISCOPE_V1',
        'ENERGY_REACTIVE_EXPORT_TOTAL',
        'varh',
        'varh',
        1.0,
        'INCREASING',
        'NONE',
        NULL::NUMERIC,
        'REJECT_DELTA',
        'REACTIVE_EXPORT',
        1000000.0
    ),
    (
        'ENERGY_METER_ENISCOPE_V1',
        'ENERGY_APPARENT_ENERGY_TOTAL',
        'VAh',
        'VAh',
        1.0,
        'INCREASING',
        'NONE',
        NULL::NUMERIC,
        'REJECT_DELTA',
        'APPARENT_TOTAL',
        1500000.0
    )
)
INSERT INTO config.energy_register_semantics
(
    profile_id,
    logical_point_id,
    source_unit_symbol,
    normalized_unit_symbol,
    scale_to_normalized_unit,
    counter_direction,
    rollover_behavior,
    rollover_value,
    reset_behavior,
    flow_interpretation,
    expected_max_interval_delta,
    is_active
)
SELECT
    dp.id,
    lp.id,
    rs.source_unit_symbol,
    rs.normalized_unit_symbol,
    rs.scale_to_normalized_unit,
    rs.counter_direction,
    rs.rollover_behavior,
    rs.rollover_value,
    rs.reset_behavior,
    rs.flow_interpretation,
    rs.expected_max_interval_delta,
    TRUE
FROM required_semantics rs
JOIN config.device_profiles dp
  ON dp.profile_code = rs.profile_code
JOIN metadata.logical_points lp
  ON lp.name = rs.logical_point_name
ON CONFLICT
(
    profile_id,
    logical_point_id
)
DO UPDATE
SET
    source_unit_symbol =
        EXCLUDED.source_unit_symbol,

    normalized_unit_symbol =
        EXCLUDED.normalized_unit_symbol,

    scale_to_normalized_unit =
        EXCLUDED.scale_to_normalized_unit,

    counter_direction =
        EXCLUDED.counter_direction,

    rollover_behavior =
        EXCLUDED.rollover_behavior,

    rollover_value =
        EXCLUDED.rollover_value,

    reset_behavior =
        EXCLUDED.reset_behavior,

    flow_interpretation =
        EXCLUDED.flow_interpretation,

    expected_max_interval_delta =
        EXCLUDED.expected_max_interval_delta,

    is_active =
        TRUE,

    updated_at =
        now();


-- ----------------------------------------------------------------------------
-- Human-readable contract view.
-- ----------------------------------------------------------------------------

CREATE OR REPLACE VIEW config.v_energy_register_semantics
AS
SELECT
    ers.id,

    dp.id AS profile_id,
    dp.profile_code,
    dp.profile_name,
    dp.manufacturer,
    dp.model,
    dp.firmware_version,

    lp.id AS logical_point_id,
    lp.name AS logical_point_name,
    lp.description AS logical_point_description,

    ers.source_unit_symbol,
    ers.normalized_unit_symbol,
    ers.scale_to_normalized_unit,

    ers.counter_direction,

    ers.rollover_behavior,
    ers.rollover_value,

    ers.reset_behavior,
    ers.flow_interpretation,

    ers.expected_max_interval_delta,

    ers.is_active,
    ers.created_at,
    ers.updated_at

FROM config.energy_register_semantics ers

JOIN config.device_profiles dp
  ON dp.id = ers.profile_id

JOIN metadata.logical_points lp
  ON lp.id = ers.logical_point_id;


COMMENT ON VIEW config.v_energy_register_semantics IS
'Human-readable profile and logical-point representation of cumulative energy-register semantics.';


REVOKE ALL
ON config.energy_register_semantics
FROM PUBLIC;


REVOKE ALL
ON config.v_energy_register_semantics
FROM PUBLIC;
