BEGIN;

-- =====================================================================
-- Persisted reset-aware energy consumption lifecycle
--
-- energy_consumption_1min
--   compression: after 7 days
--   retention:   180 days
--
-- energy_consumption_5min
--   compression: after 14 days
--   retention:   2 years
--
-- Recent chunks remain writable for recalculation / late-arrival handling.
-- =====================================================================


-- ---------------------------------------------------------------------
-- 1-minute reset-aware consumption
-- ---------------------------------------------------------------------

ALTER TABLE analytics.energy_consumption_1min
SET (
    timescaledb.compress = true,
    timescaledb.compress_segmentby =
        'organization_id,site_id,device_id',
    timescaledb.compress_orderby =
        'bucket_start DESC'
);


SELECT add_compression_policy(
    'analytics.energy_consumption_1min',
    INTERVAL '7 days',
    if_not_exists => true
);


SELECT add_retention_policy(
    'analytics.energy_consumption_1min',
    INTERVAL '180 days',
    if_not_exists => true
);


-- ---------------------------------------------------------------------
-- 5-minute reset-aware consumption
-- ---------------------------------------------------------------------

ALTER TABLE analytics.energy_consumption_5min
SET (
    timescaledb.compress = true,
    timescaledb.compress_segmentby =
        'organization_id,site_id,device_id',
    timescaledb.compress_orderby =
        'bucket_start DESC'
);


SELECT add_compression_policy(
    'analytics.energy_consumption_5min',
    INTERVAL '14 days',
    if_not_exists => true
);


SELECT add_retention_policy(
    'analytics.energy_consumption_5min',
    INTERVAL '2 years',
    if_not_exists => true
);


COMMIT;
