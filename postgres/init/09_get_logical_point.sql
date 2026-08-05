-- RETIRED PROTOTYPE FILE — DO NOT EXECUTE.
-- This file is retained only for historical reference. Use
-- scripts/deploy_database.sh and docs/operations/TELEMETRY_PIPELINE.md.

-- ============================================================================
-- 09_get_logical_point.sql
--
-- Generic Logical Point Resolver
--
-- Purpose:
--     Resolve a logical point (CURRENT_L1, ACTIVE_POWER, etc.)
--     to the correct raw JSON field using metadata.
--
-- Architecture:
--
-- Device UID
--      ↓
-- metadata.devices
--      ↓
-- device_field_mapping
--      ↓
-- logical_points
--      ↓
-- payload JSON
--
-- ============================================================================

CREATE SCHEMA IF NOT EXISTS telemetry;

CREATE OR REPLACE FUNCTION telemetry.get_logical_point
(
    p_device_uid TEXT,
    p_logical_point TEXT
)

RETURNS TABLE
(
    event_time TIMESTAMPTZ,
    device_uid TEXT,
    logical_point TEXT,
    value NUMERIC
)

LANGUAGE SQL

AS
$$

SELECT

    r.event_time,

    r.device_uid,

    lp.name,

    (
        r.payload ->> dfm.raw_field_name
    )::numeric

FROM telemetry.v_rtdata r

JOIN metadata.devices d

    ON d.external_id = r.device_uid

JOIN metadata.device_field_mapping dfm

    ON dfm.device_id = d.id

JOIN metadata.logical_points lp

    ON lp.id = dfm.logical_point_id

WHERE

    r.device_uid = p_device_uid

AND lp.name = p_logical_point

ORDER BY r.event_time DESC

LIMIT 1;

$$;
