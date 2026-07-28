-- ============================================================================
-- File: 07_01_telegraf_mqtt_staging.sql
-- Purpose: Canonical Telegraf PostgreSQL landing table.
--
-- Active ingestion path:
--
--   HiveMQ
--      |
--      v
--   Telegraf mqtt_consumer
--      |
--      v
--   public.mqtt_staging
--      |
--      v
--   telemetry.v_rtdata
--
-- Important:
--   This table shape is controlled by the Telegraf PostgreSQL output plugin
--   when tags_as_jsonb and fields_as_jsonb are enabled.
--
--   Do not rename or change these columns without updating:
--     - telegraf/config/telegraf.conf
--     - telemetry.v_rtdata
--     - telemetry normalization loaders
--
-- Time handling:
--   Telegraf writes an absolute ingestion timestamp.
--   TIMESTAMPTZ preserves that instant consistently across database session
--   time zones and prevents ingestion-lag calculations from shifting by the
--   PostgreSQL session time-zone offset.
-- ============================================================================

CREATE TABLE IF NOT EXISTS public.mqtt_staging
(
    received_at TIMESTAMPTZ,

    tags JSONB,

    fields JSONB
);


COMMENT ON TABLE public.mqtt_staging IS
    'Immutable Telegraf MQTT landing table containing ingestion timestamps, MQTT tags and raw JSON fields.';

COMMENT ON COLUMN public.mqtt_staging.received_at IS
    'Absolute ingestion timestamp written by Telegraf when the MQTT metric is received.';

COMMENT ON COLUMN public.mqtt_staging.tags IS
    'Telegraf tags encoded as JSONB, including the MQTT topic.';

COMMENT ON COLUMN public.mqtt_staging.fields IS
    'Telegraf fields encoded as JSONB, including the raw MQTT payload value.';


CREATE INDEX IF NOT EXISTS idx_mqtt_staging_received_at
    ON public.mqtt_staging (received_at);
