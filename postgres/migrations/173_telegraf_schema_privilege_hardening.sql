-- Harden the Telegraf ingestion privilege boundary.
--
-- Canonical ingestion flow:
--   telegraf_writer
--     -> INSERT on public.mqtt_staging
--     -> SECURITY DEFINER trigger function
--     -> telemetry.raw_messages
--
-- The Telegraf login role must not resolve or directly access objects in the
-- telemetry schema.

REVOKE USAGE
ON SCHEMA telemetry
FROM telegraf_writer;

GRANT USAGE
ON SCHEMA public
TO telegraf_writer;

REVOKE ALL PRIVILEGES
ON TABLE telemetry.raw_messages
FROM telegraf_writer;

REVOKE ALL PRIVILEGES
ON TABLE public.mqtt_staging
FROM telegraf_writer;

GRANT INSERT
ON TABLE public.mqtt_staging
TO telegraf_writer;

COMMENT ON VIEW public.mqtt_staging IS
'Insert-only Telegraf compatibility adapter. An INSTEAD OF INSERT trigger persists validated messages in telemetry.raw_messages; this view stores no rows.';
