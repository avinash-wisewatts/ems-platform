-- ============================================================================
-- 36_update_get_logical_point_identity.sql
--
-- Purpose:
--     Resolve telemetry devices through metadata.device_identifiers.
--
--     Removes dependency on devices.external_id.
--
-- ============================================================================

DROP FUNCTION IF EXISTS telemetry.get_logical_point(TEXT, TEXT);

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

    r.source_timestamp,

    r.device_uid,

    lp.name,

    (
        r.payload ->> dfm.raw_field_name
    )::numeric


FROM telemetry.v_rtdata r


JOIN metadata.device_identifiers di

    ON LOWER(di.identifier_value)=LOWER(r.device_uid)


JOIN metadata.devices d

    ON d.id = di.device_id


JOIN metadata.device_field_mapping dfm

    ON dfm.device_id = d.id


JOIN metadata.logical_points lp

    ON lp.id = dfm.logical_point_id


WHERE

    LOWER(r.device_uid)=LOWER(p_device_uid)

AND

    lp.name=p_logical_point


ORDER BY

    r.source_timestamp DESC NULLS LAST


LIMIT 1;

$$;
