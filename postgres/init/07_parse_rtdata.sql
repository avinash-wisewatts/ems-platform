-- ============================================================================
-- WiseWatts EMS
-- Phase 6
--
-- View:
--     telemetry.v_rtdata
--
-- Purpose
-- -------
-- One MQTT message may contain many telemetry records.
--
-- This view expands rtdata[] into one SQL row per telemetry record.
--
-- ============================================================================
CREATE SCHEMA IF NOT EXISTS telemetry;

CREATE OR REPLACE VIEW telemetry.v_rtdata AS

SELECT
    m.received_at,

    m.tags ->> 'topic'              AS mqtt_topic,

    r.value                         AS payload

FROM public.mqtt_staging m

CROSS JOIN LATERAL

jsonb_array_elements(

    (
        (m.fields ->> 'value')::jsonb
        -> 'rtdata'

    )

) AS r(value);
