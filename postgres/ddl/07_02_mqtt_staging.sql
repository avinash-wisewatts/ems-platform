-- ============================================================================
-- WiseWatts EMS
-- MQTT ingestion staging table
--
-- Purpose:
--   Landing zone between Telegraf MQTT collector and EMS semantic model.
--
-- Design:
--   Keep incoming MQTT payload unchanged.
--   Transformation happens later.
-- ============================================================================

CREATE TABLE IF NOT EXISTS telemetry.mqtt_staging
(
    id BIGINT GENERATED ALWAYS AS IDENTITY,

    received_at TIMESTAMPTZ NOT NULL DEFAULT now(),

    topic TEXT,

    qos SMALLINT,

    payload JSONB NOT NULL
);


SELECT create_hypertable(
    'telemetry.mqtt_staging',
    'received_at',
    if_not_exists => TRUE
);
