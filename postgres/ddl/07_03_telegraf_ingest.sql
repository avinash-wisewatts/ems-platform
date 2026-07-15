-- ============================================================================
-- WiseWatts EMS
-- Telegraf landing table
--
-- Purpose:
--   Accept raw MQTT messages from Telegraf.
--   SQL layer converts these into mqtt_staging JSONB.
-- ============================================================================

CREATE TABLE IF NOT EXISTS telemetry.telegraf_ingest
(
    id BIGINT GENERATED ALWAYS AS IDENTITY,

    received_at TIMESTAMPTZ NOT NULL DEFAULT now(),

    topic TEXT,

    value TEXT NOT NULL
);
