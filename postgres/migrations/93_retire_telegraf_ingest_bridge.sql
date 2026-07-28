-- ============================================================================
-- WiseWatts EMS
-- Retire superseded Telegraf ingest bridge
--
-- Established canonical ingestion route:
--   MQTT -> Telegraf -> public.mqtt_staging
--
-- This migration removes the disconnected experimental trigger path:
--   telemetry.telegraf_ingest -> telemetry.mqtt_staging
--
-- Tables are intentionally retained for forensic review and controlled cleanup.
-- No telemetry data is deleted.
-- ============================================================================

BEGIN;

DROP TRIGGER IF EXISTS trg_forward_telegraf_ingest
ON telemetry.telegraf_ingest;

DROP FUNCTION IF EXISTS
telemetry.forward_telegraf_ingest_to_mqtt_staging();

COMMIT;
