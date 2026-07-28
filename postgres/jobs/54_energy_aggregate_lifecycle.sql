-- ============================================================================
-- File:
--   54_energy_aggregate_lifecycle.sql
--
-- Purpose:
--   Configure compression and retention for the energy continuous aggregates.
--
-- Lifecycle:
--
--   telemetry.ca_energy_15min
--     Compress after: 7 days
--     Retain for:     2 years
--
--   telemetry.ca_energy_hourly
--     Compress after: 30 days
--     Retain for:     5 years
--
--   telemetry.ca_energy_daily
--     Compress after: 90 days
--     Retain:         indefinitely
--
-- Compression layout:
--
--   Segment by:
--     organization_id
--     site_id
--     device_id
--
--   Order by:
--     bucket_start DESC
--
-- Important:
--   Retention on the raw telemetry.energy_measurements hypertable is 90 days.
--   Continuous aggregates preserve their already materialized historical
--   results after raw chunks are removed.
--
--   Refresh windows must remain shorter than raw retention:
--
--     15-minute refresh start offset: 2 days
--     Hourly refresh start offset:    7 days
--     Daily refresh start offset:     30 days
--
--   All are safely within the 90-day raw retention window.
-- ============================================================================


-- ----------------------------------------------------------------------------
-- 1. Enable compression on the 15-minute continuous aggregate.
-- ----------------------------------------------------------------------------

ALTER MATERIALIZED VIEW telemetry.ca_energy_15min
SET
(
    timescaledb.compress = TRUE,

    timescaledb.compress_segmentby =
        'organization_id,site_id,device_id',

    timescaledb.compress_orderby =
        'bucket_start DESC'
);


SELECT add_compression_policy
(
    'telemetry.ca_energy_15min'::REGCLASS,

    compress_after    => INTERVAL '7 days',
    if_not_exists     => TRUE,
    schedule_interval => INTERVAL '1 day',
    timezone          => 'Asia/Kolkata'
);


SELECT add_retention_policy
(
    'telemetry.ca_energy_15min'::REGCLASS,

    drop_after        => INTERVAL '2 years',
    if_not_exists     => TRUE,
    schedule_interval => INTERVAL '1 day',
    timezone          => 'Asia/Kolkata'
);


-- ----------------------------------------------------------------------------
-- 2. Enable compression on the hourly continuous aggregate.
-- ----------------------------------------------------------------------------

ALTER MATERIALIZED VIEW telemetry.ca_energy_hourly
SET
(
    timescaledb.compress = TRUE,

    timescaledb.compress_segmentby =
        'organization_id,site_id,device_id',

    timescaledb.compress_orderby =
        'bucket_start DESC'
);


SELECT add_compression_policy
(
    'telemetry.ca_energy_hourly'::REGCLASS,

    compress_after    => INTERVAL '30 days',
    if_not_exists     => TRUE,
    schedule_interval => INTERVAL '1 day',
    timezone          => 'Asia/Kolkata'
);


SELECT add_retention_policy
(
    'telemetry.ca_energy_hourly'::REGCLASS,

    drop_after        => INTERVAL '5 years',
    if_not_exists     => TRUE,
    schedule_interval => INTERVAL '1 day',
    timezone          => 'Asia/Kolkata'
);


-- ----------------------------------------------------------------------------
-- 3. Enable compression on the daily continuous aggregate.
--
-- No retention policy is applied. Daily history is retained indefinitely until
-- a later business or regulatory decision changes this policy.
-- ----------------------------------------------------------------------------

ALTER MATERIALIZED VIEW telemetry.ca_energy_daily
SET
(
    timescaledb.compress = TRUE,

    timescaledb.compress_segmentby =
        'organization_id,site_id,device_id',

    timescaledb.compress_orderby =
        'bucket_start DESC'
);


SELECT add_compression_policy
(
    'telemetry.ca_energy_daily'::REGCLASS,

    compress_after    => INTERVAL '90 days',
    if_not_exists     => TRUE,
    schedule_interval => INTERVAL '1 day',
    timezone          => 'Asia/Kolkata'
);
