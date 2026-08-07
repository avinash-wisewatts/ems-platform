-- ============================================================================
-- 32_fix_v_rtdata.sql
--
-- Repair telemetry.v_rtdata parsing layer
--
-- Purpose:
--     Convert Telegraf JSONB output into normalized telemetry rows.
--
-- Source:
--     public.mqtt_staging
--
-- Payload structure:
--
-- {
--   "value": "{\"rtdata\":[ {...}, {...} ]}"
-- }
--
-- Output:
--     One row per telemetry device payload.
--
-- ============================================================================


CREATE OR REPLACE VIEW telemetry.v_rtdata AS

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


FROM public.mqtt_staging m


CROSS JOIN LATERAL jsonb_array_elements(

    (
        m.fields ->> 'value'
    )::jsonb -> 'rtdata'

) r(value);
