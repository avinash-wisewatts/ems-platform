-- ============================================================================
-- File: 13_01_logical_points_energy_extension.sql
-- Purpose: Extend EMS logical points for advanced electrical measurements.
--
-- These are vendor-neutral concepts.
--
-- Vendor mappings:
--
-- Eniscope:
--      Q   -> ENERGY_REACTIVE_POWER_TOTAL
--      RE  -> ENERGY_REACTIVE_ENERGY_TOTAL
--      REx -> ENERGY_REACTIVE_EXPORT_TOTAL
--      S   -> ENERGY_APPARENT_POWER_TOTAL
--      AE  -> ENERGY_APPARENT_ENERGY_TOTAL
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

(
'ENERGY_REACTIVE_POWER_TOTAL',
'Total reactive power',
'kvar',
'numeric'
),

(
'ENERGY_REACTIVE_ENERGY_TOTAL',
'Total reactive energy import',
'kvarh',
'numeric'
),

(
'ENERGY_REACTIVE_EXPORT_TOTAL',
'Total reactive energy export',
'kvarh',
'numeric'
),

(
'ENERGY_APPARENT_POWER_TOTAL',
'Total apparent power',
'kVA',
'numeric'
),

(
'ENERGY_APPARENT_ENERGY_TOTAL',
'Total apparent energy',
'kVAh',
'numeric'
)

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
