-- ============================================================================
-- WiseWatts EMS
-- Least-privilege Telegraf database permissions
--
-- Canonical ingestion route:
--   MQTT -> Telegraf -> public.mqtt_staging
--
-- Telegraf may insert telemetry into the immutable landing table, but it may
-- not read, update, delete, truncate, alter, or write directly to downstream
-- normalization and domain tables.
-- ============================================================================

-- Allow the login role to resolve objects in the public schema.
GRANT USAGE ON SCHEMA public TO telegraf_writer;

-- Remove any broad or previously introduced table privileges.
REVOKE ALL PRIVILEGES
ON TABLE telemetry.telegraf_ingest
FROM telegraf_writer;

REVOKE ALL PRIVILEGES
ON TABLE telemetry.mqtt_staging
FROM telegraf_writer;

REVOKE ALL PRIVILEGES
ON TABLE public.mqtt_staging
FROM telegraf_writer;

-- Telegraf requires INSERT only on the canonical landing table.
GRANT INSERT
ON TABLE public.mqtt_staging
TO telegraf_writer;

COMMENT ON TABLE public.mqtt_staging IS
'Immutable canonical Telegraf MQTT landing table containing ingestion timestamp, tags JSONB, and fields JSONB.';
