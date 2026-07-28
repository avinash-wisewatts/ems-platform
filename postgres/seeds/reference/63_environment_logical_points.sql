-- ============================================================================
-- File:
--   63_environment_logical_points.sql
--
-- Purpose:
--   Create the first validated environmental logical points for the Eniscope
--   Air Sense payload.
--
-- Verified raw mappings:
--
--   T1   -> ENV_TEMPERATURE
--   RH   -> ENV_RELATIVE_HUMIDITY
--   Vbat -> DEVICE_BATTERY_VOLTAGE
--
-- We intentionally do not create CO2, VOC, pressure, dew point, light-level,
-- occupancy, or IAQ points until their source semantics are confirmed.
-- ============================================================================


-- ----------------------------------------------------------------------------
-- 1. Protect logical-point names from accidental duplication.
-- ----------------------------------------------------------------------------

CREATE UNIQUE INDEX IF NOT EXISTS uq_logical_points_name
ON metadata.logical_points
(
    name
);


-- ----------------------------------------------------------------------------
-- 2. Temperature.
-- ----------------------------------------------------------------------------

INSERT INTO metadata.logical_points
(
    name,
    description,
    unit_id,
    data_type
)
SELECT
    'ENV_TEMPERATURE',
    'Ambient temperature reported by an environmental sensor.',
    eu.id,
    'numeric'
FROM config.engineering_units eu
WHERE eu.symbol = 'degC'

ON CONFLICT (name)
DO UPDATE
SET
    description =
        EXCLUDED.description,

    unit_id =
        EXCLUDED.unit_id,

    data_type =
        EXCLUDED.data_type;


-- ----------------------------------------------------------------------------
-- 3. Relative humidity.
-- ----------------------------------------------------------------------------

INSERT INTO metadata.logical_points
(
    name,
    description,
    unit_id,
    data_type
)
SELECT
    'ENV_RELATIVE_HUMIDITY',
    'Ambient relative humidity reported by an environmental sensor.',
    eu.id,
    'numeric'
FROM config.engineering_units eu
WHERE eu.symbol = '%'

ON CONFLICT (name)
DO UPDATE
SET
    description =
        EXCLUDED.description,

    unit_id =
        EXCLUDED.unit_id,

    data_type =
        EXCLUDED.data_type;


-- ----------------------------------------------------------------------------
-- 4. Sensor battery voltage.
-- ----------------------------------------------------------------------------

INSERT INTO metadata.logical_points
(
    name,
    description,
    unit_id,
    data_type
)
SELECT
    'DEVICE_BATTERY_VOLTAGE',
    'Battery voltage reported by a field sensor or telemetry device.',
    eu.id,
    'numeric'
FROM config.engineering_units eu
WHERE eu.symbol = 'V'

ON CONFLICT (name)
DO UPDATE
SET
    description =
        EXCLUDED.description,

    unit_id =
        EXCLUDED.unit_id,

    data_type =
        EXCLUDED.data_type;


-- ----------------------------------------------------------------------------
-- 5. Validate all required logical points and engineering units.
-- ----------------------------------------------------------------------------

DO
$$
DECLARE
    v_point_count INTEGER;
BEGIN
    SELECT COUNT(*)
    INTO v_point_count
    FROM metadata.logical_points lp

    JOIN config.engineering_units eu
      ON eu.id = lp.unit_id

    WHERE
    (
        lp.name = 'ENV_TEMPERATURE'
        AND eu.symbol = 'degC'
    )
    OR
    (
        lp.name = 'ENV_RELATIVE_HUMIDITY'
        AND eu.symbol = '%'
    )
    OR
    (
        lp.name = 'DEVICE_BATTERY_VOLTAGE'
        AND eu.symbol = 'V'
    );

    IF v_point_count <> 3 THEN
        RAISE EXCEPTION
            'Expected 3 validated environmental logical points, found %',
            v_point_count;
    END IF;
END;
$$;
