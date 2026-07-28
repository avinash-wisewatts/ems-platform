-- ============================================================================
-- File:
--   40_normalized_points_uniqueness.sql
--
-- Purpose:
--   Prevent duplicate normalized telemetry points.
--
-- Canonical identity:
--   event_time + device_id + logical_point_id
--
-- TimescaleDB requirement:
--   Every UNIQUE index on a hypertable must include the partitioning column.
--   telemetry.normalized_points is partitioned by event_time, so event_time is
--   included in this index.
--
-- Behaviour:
--   Future loaders can safely use:
--
--       ON CONFLICT (event_time, device_id, logical_point_id) DO NOTHING
--
-- This protects against:
--   - repeated MQTT messages
--   - loader retries
--   - Telegraf restarts
--   - overlapping processing windows
-- ============================================================================

CREATE UNIQUE INDEX IF NOT EXISTS uq_normalized_points_identity
ON telemetry.normalized_points
(
    event_time,
    device_id,
    logical_point_id
);
