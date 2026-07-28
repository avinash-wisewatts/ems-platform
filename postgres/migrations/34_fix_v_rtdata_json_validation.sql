-- ============================================================================
-- 34_fix_v_rtdata_json_validation.sql
--
-- Purpose:
--     Harden telemetry parsing against malformed MQTT payloads.
--
--     mqtt_staging is the immutable landing zone.
--     Invalid messages must not break telemetry processing.
--
-- ============================================================================


CREATE OR REPLACE VIEW telemetry.v_rtdata AS

WITH valid_messages AS
(
    SELECT

        received_at,

        tags,

        (fields ->> 'value')::jsonb AS payload_json

    FROM public.mqtt_staging

    WHERE

        fields ->> 'value' IS NOT NULL

        AND

        fields ->> 'value' LIKE '{%'

)

SELECT

    m.received_at,

    m.tags ->> 'topic' AS mqtt_topic,

    r.value ->> 'uid' AS device_uid,

    r.value ->> 'did' AS device_identifier,

    CASE

        WHEN r.value ->> 'ts' IS NOT NULL

        THEN to_timestamp(
            (r.value ->> 'ts')::double precision
        )

        ELSE NULL

    END AS source_timestamp,

    r.value AS payload


FROM valid_messages m


CROSS JOIN LATERAL jsonb_array_elements(

    m.payload_json -> 'rtdata'

) r(value)


WHERE

    jsonb_typeof(
        m.payload_json -> 'rtdata'
    ) = 'array';
