-- ============================================================================
-- File:
--   64_environment_sensor_extensions.sql
--
-- Purpose:
--   Extend the generic environmental telemetry contract with:
--
--     ENV_ILLUMINANCE_LUX
--     OCCUPANCY_ACTIVITY
--
-- Verified Eniscope raw fields:
--
--     LL  -> ENV_ILLUMINANCE_LUX
--     PIR -> OCCUPANCY_ACTIVITY
--
-- Notes:
--
--   LL is treated as illuminance in lux based on the device payload semantics.
--
--   PIR currently emits numeric values such as 490 rather than a Boolean
--   occupied/unoccupied state. Therefore the raw numeric value is preserved as
--   OCCUPANCY_ACTIVITY without applying an unverified threshold.
--
--   A derived occupancy-state layer can be added later after the PIR behavior
--   and threshold semantics are validated.
-- ============================================================================


-- ----------------------------------------------------------------------------
-- 1. Create the lux engineering unit.
-- ----------------------------------------------------------------------------

INSERT INTO config.engineering_units
(
    symbol,
    description
)
SELECT
    'lux',
    'Illuminance in lux'

WHERE NOT EXISTS
(
    SELECT 1
    FROM config.engineering_units
    WHERE symbol = 'lux'
);


-- ----------------------------------------------------------------------------
-- 2. Create the illuminance logical point.
-- ----------------------------------------------------------------------------

INSERT INTO metadata.logical_points
(
    name,
    description,
    unit_id,
    data_type
)
SELECT
    'ENV_ILLUMINANCE_LUX',
    'Ambient illuminance reported by an environmental sensor.',
    eu.id,
    'numeric'
FROM config.engineering_units eu
WHERE eu.symbol = 'lux'

ON CONFLICT (name)
DO UPDATE
SET
    description = EXCLUDED.description,
    unit_id = EXCLUDED.unit_id,
    data_type = EXCLUDED.data_type;


-- ----------------------------------------------------------------------------
-- 3. Create the occupancy-activity logical point.
--
-- No engineering unit is assigned because the source PIR scale is not yet
-- confirmed as seconds, counts, intensity, or another vendor-specific measure.
-- ----------------------------------------------------------------------------

INSERT INTO metadata.logical_points
(
    name,
    description,
    unit_id,
    data_type
)
VALUES
(
    'OCCUPANCY_ACTIVITY',
    'Raw numeric occupancy or motion activity reported by a PIR sensor.',
    NULL,
    'numeric'
)

ON CONFLICT (name)
DO UPDATE
SET
    description = EXCLUDED.description,
    unit_id = EXCLUDED.unit_id,
    data_type = EXCLUDED.data_type;


-- ----------------------------------------------------------------------------
-- 4. Validate both logical points.
-- ----------------------------------------------------------------------------

DO
$$
DECLARE
    v_lux_point_count INTEGER;
    v_occupancy_point_count INTEGER;
BEGIN
    SELECT COUNT(*)
    INTO v_lux_point_count
    FROM metadata.logical_points lp

    JOIN config.engineering_units eu
      ON eu.id = lp.unit_id

    WHERE lp.name = 'ENV_ILLUMINANCE_LUX'
      AND eu.symbol = 'lux';


    SELECT COUNT(*)
    INTO v_occupancy_point_count
    FROM metadata.logical_points lp

    WHERE lp.name = 'OCCUPANCY_ACTIVITY'
      AND lp.unit_id IS NULL;


    IF v_lux_point_count <> 1 THEN
        RAISE EXCEPTION
            'ENV_ILLUMINANCE_LUX validation failed';
    END IF;


    IF v_occupancy_point_count <> 1 THEN
        RAISE EXCEPTION
            'OCCUPANCY_ACTIVITY validation failed';
    END IF;
END;
$$;
