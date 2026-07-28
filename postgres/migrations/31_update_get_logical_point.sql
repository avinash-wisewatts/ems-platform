/*
===============================================================================
31_update_get_logical_point.sql

Purpose
-------
Updates telemetry.get_logical_point() to resolve logical points using
Device Profiles instead of per-device field mappings.

Old path:
Device → metadata.device_field_mapping → logical_points

New path:
Device → profile_id → config.profile_field_mapping → logical_points
===============================================================================
*/

CREATE OR REPLACE FUNCTION telemetry.get_logical_point
(
    p_device_uid TEXT,
    p_logical_point TEXT
)

RETURNS TABLE
(
    reveived_at TIMESTAMP,
    device_uid TEXT,
    logical_point TEXT,
    value NUMERIC
)

LANGUAGE SQL

AS
$$

SELECT

    r.received_at,

    r.device_uid,

    lp.name,

    (
        r.payload ->> pfm.raw_field_name
    )::numeric

FROM telemetry.v_rtdata r

JOIN metadata.devices d
    ON d.external_id = r.device_uid

JOIN config.profile_field_mapping pfm
    ON pfm.profile_id = d.profile_id

JOIN metadata.logical_points lp
    ON lp.id = pfm.logical_point_id

WHERE
    r.device_uid = p_device_uid
AND lp.name = p_logical_point

ORDER BY r.received_at DESC

LIMIT 1;

$$;
