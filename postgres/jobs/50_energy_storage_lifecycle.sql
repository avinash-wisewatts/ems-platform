-- ============================================================================
-- File:
--   50_energy_storage_lifecycle.sql
--
-- Purpose:
--   Configure the TimescaleDB storage lifecycle for the durable energy-domain
--   hypertable.
--
-- Policy:
--
--   Future chunk interval:  1 day
--   Compress after:         7 days
--   Retain raw telemetry:   90 days
--
-- Existing chunks:
--   Changing the hypertable chunk interval affects newly created chunks only.
--   Existing 7-day chunks remain valid and will still be handled by the
--   compression and retention policies.
--
-- Compression layout:
--
--   Segment by:
--     organization_id
--     site_id
--     device_id
--
--   Order by:
--     received_at DESC
--
-- Segmenting by tenant and device improves tenant-filtered and device-filtered
-- Grafana queries. Ordering by time supports time-range scans.
--
-- Retention:
--   Raw wide energy rows are retained for 90 days. Continuous aggregates
--   created in the following migrations will retain longer-term history.
-- ============================================================================


-- ----------------------------------------------------------------------------
-- 1. Use one-day chunks for future energy telemetry.
-- ----------------------------------------------------------------------------

SELECT set_chunk_time_interval
(
    'telemetry.energy_measurements'::REGCLASS,
    INTERVAL '1 day'
);


-- ----------------------------------------------------------------------------
-- 2. Enable TimescaleDB compression and define the physical layout.
--
-- Although TimescaleDB 2.28 also exposes the newer columnstore API, the
-- traditional compression policy remains fully supported and integrates with
-- timescaledb_information.jobs and chunks.is_compressed.
-- ----------------------------------------------------------------------------

ALTER TABLE telemetry.energy_measurements
SET
(
    timescaledb.compress = TRUE,

    timescaledb.compress_segmentby =
        'organization_id,site_id,device_id',

    timescaledb.compress_orderby =
        'received_at DESC'
);


-- ----------------------------------------------------------------------------
-- 3. Add or preserve a compression policy.
--
-- if_not_exists => TRUE makes this safe to rerun.
-- ----------------------------------------------------------------------------

SELECT add_compression_policy
(
    'telemetry.energy_measurements'::REGCLASS,
    compress_after    => INTERVAL '7 days',
    if_not_exists     => TRUE,
    schedule_interval => INTERVAL '1 day',
    timezone          => 'Asia/Kolkata'
);


-- ----------------------------------------------------------------------------
-- 4. Add or preserve a retention policy.
--
-- Chunks whose complete time range is older than 90 days will be removed.
-- ----------------------------------------------------------------------------

SELECT add_retention_policy
(
    'telemetry.energy_measurements'::REGCLASS,
    drop_after        => INTERVAL '90 days',
    if_not_exists     => TRUE,
    schedule_interval => INTERVAL '1 day',
    timezone          => 'Asia/Kolkata'
);
