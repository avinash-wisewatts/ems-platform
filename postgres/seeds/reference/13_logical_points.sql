-- ============================================================================
-- File: 13_logical_points.sql
-- Purpose: EMS semantic measurement dictionary.
--
-- These are vendor-neutral logical points.
--
-- Device mappings should map:
--
--      Vendor Field
--            |
--            v
--      logical_points
--            |
--            v
--      telemetry tables
--
-- ============================================================================


INSERT INTO metadata.logical_points
(
    name,
    description,
    unit_id,
    data_type
)

SELECT
    v.name,
    v.description,
    u.id,
    v.data_type

FROM
(
VALUES

('ENERGY_IMPORT_TOTAL',
 'Total imported active energy',
 'kWh',
 'numeric'),

('ENERGY_EXPORT_TOTAL',
 'Total exported active energy',
 'kWh',
 'numeric'),


('VOLTAGE_L1',
 'Phase 1 voltage',
 'V',
 'numeric'),

('VOLTAGE_L2',
 'Phase 2 voltage',
 'V',
 'numeric'),

('VOLTAGE_L3',
 'Phase 3 voltage',
 'V',
 'numeric'),


('CURRENT_L1',
 'Phase 1 current',
 'A',
 'numeric'),

('CURRENT_L2',
 'Phase 2 current',
 'A',
 'numeric'),

('CURRENT_L3',
 'Phase 3 current',
 'A',
 'numeric'),


('POWER_FACTOR_TOTAL',
 'System power factor',
 'none',
 'numeric'),

('FREQUENCY',
 'Electrical frequency',
 'Hz',
 'numeric'),


('CURRENT_THD_L1',
 'Phase 1 current total harmonic distortion',
 '%',
 'numeric'),

('CURRENT_THD_L2',
 'Phase 2 current total harmonic distortion',
 '%',
 'numeric'),

('CURRENT_THD_L3',
 'Phase 3 current total harmonic distortion',
 '%',
 'numeric')


) AS v
(
name,
description,
unit,
data_type
)

JOIN config.engineering_units u
ON u.symbol = v.unit

ON CONFLICT DO NOTHING;
