CREATE OR REPLACE PROCEDURE telemetry.load_normalized_points()
LANGUAGE SQL
AS
$$

INSERT INTO telemetry.normalized_points
(
    event_time,
    organization_id,
    site_id,
    gateway_id,
    device_id,
    logical_point_id,
    device_uid,
    logical_point,
    raw_field_name,
    raw_value,
    numeric_value,
    quality_code,
    mapping_source,
    payload
)
SELECT
    event_time,
    organization_id,
    site_id,
    gateway_id,
    device_id,
    logical_point_id,
    device_uid,
    logical_point,
    raw_field_name,
    raw_value,
    numeric_value,
    quality_code,
    mapping_source,
    payload
FROM telemetry.v_normalized_points;

$$;
