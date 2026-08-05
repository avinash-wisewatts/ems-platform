-- RETIRED PROTOTYPE FILE — DO NOT EXECUTE.
-- This file is retained only for historical reference. Use
-- scripts/deploy_database.sh and docs/operations/TELEMETRY_PIPELINE.md.

CREATE SCHEMA IF NOT EXISTS telemetry;

CREATE OR REPLACE VIEW telemetry.v_rtdata AS

SELECT

    m.received_at,

    m.tags ->> 'topic'                           AS mqtt_topic,

    r.value ->> 'uid'                            AS device_uid,

    r.value ->> 'did'                            AS device_identifier,

    CASE
        WHEN (r.value ->> 'ts') IS NOT NULL
        THEN to_timestamp((r.value ->> 'ts')::double precision)
        ELSE NULL
    END                                          AS source_timestamp,

    r.value                                      AS payload

FROM public.mqtt_staging m

CROSS JOIN LATERAL

jsonb_array_elements(
    ((m.fields ->> 'value')::jsonb -> 'rtdata')
) AS r(value);
