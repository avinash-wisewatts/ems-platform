-- ============================================================================
-- File: 13_03_logical_points_electrical_baseline.sql
-- Purpose: Deterministic-UUID baseline for the 20 pre-rename ENERGY_*
--          electrical logical points consumed by migration
--          174_canonical_electrical_logical_point_names.sql.
--
-- Migration 174 renames these 20 rows in place (UUID identities do not
-- change) and requires each exact (UUID, name) pair to already exist. This
-- seed plants them with their known-good identities so the migration is
-- reproducible on any freshly built database, not only on a database that
-- happens to share history with an already-provisioned production instance.
-- ============================================================================


INSERT INTO metadata.logical_points
(
    id,
    name,
    description,
    unit_id,
    data_type
)

SELECT
    v.id,
    v.name,
    v.description,
    u.id,
    v.data_type

FROM
(
VALUES

(
'adf4c51a-6c14-4e65-9f02-b37d363001f6'::uuid,
'ENERGY_ACTIVE_POWER_L1',
'Phase L1 active power',
'kW',
'numeric'
),

(
'b331d9ef-82fa-4e4e-b081-3582e0f5d51c'::uuid,
'ENERGY_ACTIVE_POWER_L2',
'Phase L2 active power',
'kW',
'numeric'
),

(
'6868ab67-7cf8-4ec3-b6d7-4119d1c7da9b'::uuid,
'ENERGY_ACTIVE_POWER_L3',
'Phase L3 active power',
'kW',
'numeric'
),

(
'44652ee7-57fb-4174-b4e9-4992323056fd'::uuid,
'ENERGY_ACTIVE_POWER_TOTAL',
'Total active power',
'kW',
'numeric'
),

(
'dee482f7-32cb-466f-a7c8-51491dc36b8c'::uuid,
'ENERGY_APPARENT_POWER_L1',
'Phase L1 apparent power',
'kVA',
'numeric'
),

(
'e2800629-bf0c-48f9-8174-7935618e7f90'::uuid,
'ENERGY_APPARENT_POWER_L2',
'Phase L2 apparent power',
'kVA',
'numeric'
),

(
'40f1773e-6cf2-4a07-b25c-545151278989'::uuid,
'ENERGY_APPARENT_POWER_L3',
'Phase L3 apparent power',
'kVA',
'numeric'
),

(
'56b6ce2a-acf8-48be-8674-87f4e61d7e12'::uuid,
'ENERGY_APPARENT_POWER_TOTAL',
'Total apparent power',
'kVA',
'numeric'
),

(
'61e3efa2-a04c-4157-ae99-a875157f0062'::uuid,
'ENERGY_REACTIVE_POWER_L1',
'Phase L1 reactive power',
'kvar',
'numeric'
),

(
'6a7b7c26-b004-4569-9c75-defd53a9b3e4'::uuid,
'ENERGY_REACTIVE_POWER_L2',
'Phase L2 reactive power',
'kvar',
'numeric'
),

(
'29777d90-4210-40a8-8632-0732d0f41a6b'::uuid,
'ENERGY_REACTIVE_POWER_L3',
'Phase L3 reactive power',
'kvar',
'numeric'
),

(
'df16db14-0d1d-45f0-b637-5d55ee621227'::uuid,
'ENERGY_REACTIVE_POWER_TOTAL',
'Total reactive power',
'kvar',
'numeric'
),

(
'8abbdfcf-de76-43b8-8c1c-30b67f3e6a06'::uuid,
'ENERGY_APPARENT_ENERGY_L1',
'Phase L1 apparent energy',
'kVAh',
'numeric'
),

(
'25cee3e3-1249-44ea-862d-aafe4cd1c42b'::uuid,
'ENERGY_APPARENT_ENERGY_L2',
'Phase L2 apparent energy',
'kVAh',
'numeric'
),

(
'59a34763-7c77-49e2-a92a-65635ebd5956'::uuid,
'ENERGY_APPARENT_ENERGY_L3',
'Phase L3 apparent energy',
'kVAh',
'numeric'
),

(
'2e13ca70-a769-47d0-89e3-68396e7bcd6e'::uuid,
'ENERGY_APPARENT_ENERGY_TOTAL',
'Total apparent energy',
'kVAh',
'numeric'
),

(
'cb060b6c-6f28-4951-92fd-02ab0226bd6c'::uuid,
'ENERGY_REACTIVE_ENERGY_L1',
'Phase L1 reactive energy import',
'kvarh',
'numeric'
),

(
'65e814aa-bbb5-4b11-aa51-fa234ffbd2d7'::uuid,
'ENERGY_REACTIVE_ENERGY_L2',
'Phase L2 reactive energy import',
'kvarh',
'numeric'
),

(
'b3947e8e-2c64-4bd1-8603-89eb351afbd9'::uuid,
'ENERGY_REACTIVE_ENERGY_L3',
'Phase L3 reactive energy import',
'kvarh',
'numeric'
),

(
'361ddb03-2d71-4b8a-aec5-c016ed61376d'::uuid,
'ENERGY_REACTIVE_ENERGY_TOTAL',
'Total reactive energy import',
'kvarh',
'numeric'
)

) AS v
(
id,
name,
description,
unit,
data_type
)

JOIN config.engineering_units u
ON u.symbol = v.unit

ON CONFLICT DO NOTHING;
