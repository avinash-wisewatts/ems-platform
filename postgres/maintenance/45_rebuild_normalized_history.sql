-- ============================================================================
-- File:
--   45_rebuild_normalized_history.sql
--
-- Purpose:
--   Rebuild telemetry.normalized_points after correcting MQTT UID-to-device
--   metadata resolution.
--
-- Source of truth:
--   public.mqtt_staging
--
-- Transactional behavior:
--   Run this script using psql -1. If normalization fails, the TRUNCATE and
--   pipeline-state reset are rolled back together.
--
-- Preconditions:
--   The TimescaleDB normalization background job must be paused.
-- ============================================================================


-- Remove rows attributed through the old proof-of-concept device identity.
TRUNCATE TABLE telemetry.normalized_points;


-- Reset the loader checkpoint so the next loader execution scans all retained
-- raw MQTT landing data.
UPDATE telemetry.pipeline_state
SET
    last_received_at = NULL,
    last_started_at = NULL,
    last_completed_at = NULL,
    last_inserted_rows = 0,
    last_status = 'NEVER_RUN',
    last_error = NULL,
    updated_at = now()
WHERE pipeline_name = 'normalized_points';


-- Rebuild the durable normalization layer from all retained raw messages.
CALL telemetry.load_normalized_points_incremental
(
    INTERVAL '15 minutes'
);
