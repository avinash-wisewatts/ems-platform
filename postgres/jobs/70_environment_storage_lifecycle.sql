-- ============================================================================
-- File:
--   70_environment_storage_lifecycle.sql
--
-- Purpose:
--   Configure production storage lifecycle for raw environmental telemetry.
--
-- Hypertable:
--   telemetry.environment_measurements
--
-- Policies:
--   - 7-day chunks
--   - Compression after 7 days
--   - Retention after 2 years
--
-- Compression layout:
--   Segment by:
--     organization_id, site_id, device_id
--
--   Order by:
--     received_at DESC
--
-- Design notes:
--   - Segmenting by tenant/site/device supports common Grafana filters.
--   - Ordering by time supports efficient range scans.
--   - Recent data remains row-oriented for ingestion and updates.
--   - Historical chunks are compressed for lower storage cost.
-- ============================================================================


-- ----------------------------------------------------------------------------
-- 1. Keep the hypertable chunk interval at seven days.
-- ----------------------------------------------------------------------------

SELECT set_chunk_time_interval
(
    'telemetry.environment_measurements'::REGCLASS,
    INTERVAL '7 days'
);


-- ----------------------------------------------------------------------------
-- 2. Configure TimescaleDB compression.
-- ----------------------------------------------------------------------------

ALTER TABLE telemetry.environment_measurements
SET
(
    timescaledb.compress,
    timescaledb.compress_segmentby =
        'organization_id,site_id,device_id',
    timescaledb.compress_orderby =
        'received_at DESC'
);


-- ----------------------------------------------------------------------------
-- 3. Replace any existing compression policy.
-- ----------------------------------------------------------------------------

SELECT remove_compression_policy
(
    'telemetry.environment_measurements'::REGCLASS,
    if_exists => TRUE
);


SELECT add_compression_policy
(
    'telemetry.environment_measurements'::REGCLASS,
    compress_after => INTERVAL '7 days',
    if_not_exists => TRUE,
    schedule_interval => INTERVAL '1 day'
);


-- ----------------------------------------------------------------------------
-- 4. Replace any existing retention policy.
-- ----------------------------------------------------------------------------

SELECT remove_retention_policy
(
    'telemetry.environment_measurements'::REGCLASS,
    if_exists => TRUE
);


SELECT add_retention_policy
(
    'telemetry.environment_measurements'::REGCLASS,
    drop_after => INTERVAL '2 years',
    if_not_exists => TRUE,
    schedule_interval => INTERVAL '1 day'
);
