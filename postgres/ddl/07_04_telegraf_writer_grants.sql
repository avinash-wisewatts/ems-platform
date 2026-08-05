-- ============================================================================
-- WiseWatts EMS
-- Least-privilege Telegraf database permissions
--
-- Canonical ingestion route:
--
--   MQTT
--      -> Telegraf
--      -> public.mqtt_staging insert-only adapter
--      -> SECURITY DEFINER capture function
--      -> telemetry.raw_messages
--
-- telegraf_writer must not have USAGE on the telemetry schema and must not
-- access telemetry.raw_messages or any downstream telemetry table directly.
-- ============================================================================

GRANT USAGE ON SCHEMA public TO telegraf_writer;

REVOKE USAGE ON SCHEMA telemetry FROM telegraf_writer;


-- Remove privileges from retired relations only when they happen to exist in
-- an upgraded database. Fresh deployments do not create these relations.
DO
$$
BEGIN
    IF to_regclass('telemetry.telegraf_ingest') IS NOT NULL THEN
        EXECUTE
            'REVOKE ALL PRIVILEGES ON TABLE telemetry.telegraf_ingest FROM telegraf_writer';
    END IF;

    IF to_regclass('telemetry.mqtt_staging') IS NOT NULL THEN
        EXECUTE
            'REVOKE ALL PRIVILEGES ON TABLE telemetry.mqtt_staging FROM telegraf_writer';
    END IF;
END;
$$;


REVOKE ALL PRIVILEGES
ON TABLE public.mqtt_staging
FROM PUBLIC;

REVOKE ALL PRIVILEGES
ON TABLE public.mqtt_staging
FROM telegraf_writer;

GRANT INSERT
ON TABLE public.mqtt_staging
TO telegraf_writer;

REVOKE ALL PRIVILEGES
ON TABLE telemetry.raw_messages
FROM telegraf_writer;


COMMENT ON VIEW public.mqtt_staging IS
'Insert-only Telegraf compatibility adapter. Messages are persisted by a SECURITY DEFINER trigger in telemetry.raw_messages.';
