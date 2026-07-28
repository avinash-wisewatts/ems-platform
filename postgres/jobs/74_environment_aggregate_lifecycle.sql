-- ============================================================================
-- File:
--   74_environment_aggregate_lifecycle.sql
--
-- Purpose:
--   Configure compression and retention for environmental continuous
--   aggregates.
--
-- Policies:
--
--   telemetry.ca_environment_15min
--     compression after 7 days
--     retention after 2 years
--
--   telemetry.ca_environment_hourly
--     compression after 30 days
--     retention after 5 years
--
-- Compression layout:
--
--   segment by:
--     organization_id, site_id, device_id
--
--   order by:
--     bucket_start DESC
--
-- TimescaleDB continuous aggregates are compressed through their public
-- continuous-aggregate view names. TimescaleDB applies the settings to their
-- internal materialization hypertables.
-- ============================================================================


-- ----------------------------------------------------------------------------
-- 1. Fifteen-minute environmental aggregate.
-- ----------------------------------------------------------------------------

ALTER MATERIALIZED VIEW telemetry.ca_environment_15min
SET
(
    timescaledb.compress,
    timescaledb.compress_segmentby =
        'organization_id,site_id,device_id',
    timescaledb.compress_orderby =
        'bucket_start DESC'
);


SELECT remove_compression_policy
(
    'telemetry.ca_environment_15min',
    if_exists => TRUE
);


SELECT add_compression_policy
(
    'telemetry.ca_environment_15min',
    compress_after => INTERVAL '7 days',
    if_not_exists => TRUE,
    schedule_interval => INTERVAL '1 day'
);


SELECT remove_retention_policy
(
    'telemetry.ca_environment_15min',
    if_exists => TRUE
);


SELECT add_retention_policy
(
    'telemetry.ca_environment_15min',
    drop_after => INTERVAL '2 years',
    if_not_exists => TRUE,
    schedule_interval => INTERVAL '1 day'
);


-- ----------------------------------------------------------------------------
-- 2. Hourly environmental aggregate.
-- ----------------------------------------------------------------------------

ALTER MATERIALIZED VIEW telemetry.ca_environment_hourly
SET
(
    timescaledb.compress,
    timescaledb.compress_segmentby =
        'organization_id,site_id,device_id',
    timescaledb.compress_orderby =
        'bucket_start DESC'
);


SELECT remove_compression_policy
(
    'telemetry.ca_environment_hourly',
    if_exists => TRUE
);


SELECT add_compression_policy
(
    'telemetry.ca_environment_hourly',
    compress_after => INTERVAL '30 days',
    if_not_exists => TRUE,
    schedule_interval => INTERVAL '1 day'
);


SELECT remove_retention_policy
(
    'telemetry.ca_environment_hourly',
    if_exists => TRUE
);


SELECT add_retention_policy
(
    'telemetry.ca_environment_hourly',
    drop_after => INTERVAL '5 years',
    if_not_exists => TRUE,
    schedule_interval => INTERVAL '1 day'
);
