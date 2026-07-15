-- ============================================================================
-- WiseWatts EMS
-- Phase 6 - Ingestion Layer
--
-- Purpose:
-- Provide a stable application interface over the Telegraf-managed landing
-- table. No application code should query public.mqtt_staging directly.
-- ============================================================================

CREATE SCHEMA IF NOT EXISTS telemetry;

CREATE OR REPLACE VIEW telemetry.raw_messages AS
SELECT
    received_at,
    tag_id,
    field_id,
    tags,
    fields
FROM public.mqtt_staging;
