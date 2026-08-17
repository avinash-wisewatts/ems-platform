BEGIN;

-- =====================================================================
-- Supplemental phase reactive/apparent power historian.
--
-- Existing canonical energy CAGGs are intentionally left untouched
-- because they have a large production dependency tree.
--
-- Source timestamp:
--   telemetry.energy_measurements.bucket_start
--
-- Measurements:
--   reactive_power_l1/l2/l3_var
--   apparent_power_l1/l2/l3_va
--
-- Statistics:
--   AVG / MIN / MAX
-- =====================================================================


-- =====================================================================
-- 1 MINUTE
-- =====================================================================

CREATE MATERIALIZED VIEW telemetry.ca_energy_phase_power_1min
WITH (timescaledb.continuous)
AS
SELECT
    time_bucket(
        INTERVAL '1 minute',
        bucket_start
    ) AS bucket_start,

    organization_id,
    site_id,
    device_id,

    COUNT(*)::bigint AS sample_count,

    AVG(reactive_power_l1_var)
        AS reactive_power_l1_var_avg,
    MIN(reactive_power_l1_var)
        AS reactive_power_l1_var_min,
    MAX(reactive_power_l1_var)
        AS reactive_power_l1_var_max,

    AVG(reactive_power_l2_var)
        AS reactive_power_l2_var_avg,
    MIN(reactive_power_l2_var)
        AS reactive_power_l2_var_min,
    MAX(reactive_power_l2_var)
        AS reactive_power_l2_var_max,

    AVG(reactive_power_l3_var)
        AS reactive_power_l3_var_avg,
    MIN(reactive_power_l3_var)
        AS reactive_power_l3_var_min,
    MAX(reactive_power_l3_var)
        AS reactive_power_l3_var_max,

    AVG(apparent_power_l1_va)
        AS apparent_power_l1_va_avg,
    MIN(apparent_power_l1_va)
        AS apparent_power_l1_va_min,
    MAX(apparent_power_l1_va)
        AS apparent_power_l1_va_max,

    AVG(apparent_power_l2_va)
        AS apparent_power_l2_va_avg,
    MIN(apparent_power_l2_va)
        AS apparent_power_l2_va_min,
    MAX(apparent_power_l2_va)
        AS apparent_power_l2_va_max,

    AVG(apparent_power_l3_va)
        AS apparent_power_l3_va_avg,
    MIN(apparent_power_l3_va)
        AS apparent_power_l3_va_min,
    MAX(apparent_power_l3_va)
        AS apparent_power_l3_va_max

FROM telemetry.energy_measurements

GROUP BY
    time_bucket(
        INTERVAL '1 minute',
        bucket_start
    ),
    organization_id,
    site_id,
    device_id

WITH NO DATA;


SELECT add_continuous_aggregate_policy(
    'telemetry.ca_energy_phase_power_1min'::regclass,
    start_offset      => INTERVAL '2 days',
    end_offset        => INTERVAL '1 minute',
    schedule_interval => INTERVAL '1 minute'
);

ALTER MATERIALIZED VIEW telemetry.ca_energy_phase_power_1min
SET (
    timescaledb.compress = TRUE,
    timescaledb.compress_segmentby =
        'organization_id,site_id,device_id',
    timescaledb.compress_orderby =
        'bucket_start DESC'
);

SELECT add_compression_policy(
    'telemetry.ca_energy_phase_power_1min'::regclass,
    INTERVAL '7 days'
);

SELECT add_retention_policy(
    'telemetry.ca_energy_phase_power_1min'::regclass,
    INTERVAL '180 days'
);



-- =====================================================================
-- 5 MINUTES
-- =====================================================================

CREATE MATERIALIZED VIEW telemetry.ca_energy_phase_power_5min
WITH (timescaledb.continuous)
AS
SELECT
    time_bucket(
        INTERVAL '5 minutes',
        bucket_start
    ) AS bucket_start,

    organization_id,
    site_id,
    device_id,

    COUNT(*)::bigint AS sample_count,

    AVG(reactive_power_l1_var) AS reactive_power_l1_var_avg,
    MIN(reactive_power_l1_var) AS reactive_power_l1_var_min,
    MAX(reactive_power_l1_var) AS reactive_power_l1_var_max,

    AVG(reactive_power_l2_var) AS reactive_power_l2_var_avg,
    MIN(reactive_power_l2_var) AS reactive_power_l2_var_min,
    MAX(reactive_power_l2_var) AS reactive_power_l2_var_max,

    AVG(reactive_power_l3_var) AS reactive_power_l3_var_avg,
    MIN(reactive_power_l3_var) AS reactive_power_l3_var_min,
    MAX(reactive_power_l3_var) AS reactive_power_l3_var_max,

    AVG(apparent_power_l1_va) AS apparent_power_l1_va_avg,
    MIN(apparent_power_l1_va) AS apparent_power_l1_va_min,
    MAX(apparent_power_l1_va) AS apparent_power_l1_va_max,

    AVG(apparent_power_l2_va) AS apparent_power_l2_va_avg,
    MIN(apparent_power_l2_va) AS apparent_power_l2_va_min,
    MAX(apparent_power_l2_va) AS apparent_power_l2_va_max,

    AVG(apparent_power_l3_va) AS apparent_power_l3_va_avg,
    MIN(apparent_power_l3_va) AS apparent_power_l3_va_min,
    MAX(apparent_power_l3_va) AS apparent_power_l3_va_max

FROM telemetry.energy_measurements

GROUP BY
    time_bucket(
        INTERVAL '5 minutes',
        bucket_start
    ),
    organization_id,
    site_id,
    device_id

WITH NO DATA;


SELECT add_continuous_aggregate_policy(
    'telemetry.ca_energy_phase_power_5min'::regclass,
    start_offset      => INTERVAL '7 days',
    end_offset        => INTERVAL '1 minute',
    schedule_interval => INTERVAL '5 minutes'
);

ALTER MATERIALIZED VIEW telemetry.ca_energy_phase_power_5min
SET (
    timescaledb.compress = TRUE,
    timescaledb.compress_segmentby =
        'organization_id,site_id,device_id',
    timescaledb.compress_orderby =
        'bucket_start DESC'
);

SELECT add_compression_policy(
    'telemetry.ca_energy_phase_power_5min'::regclass,
    INTERVAL '7 days'
);

SELECT add_retention_policy(
    'telemetry.ca_energy_phase_power_5min'::regclass,
    INTERVAL '2 years'
);



-- =====================================================================
-- 15 MINUTES
-- =====================================================================

CREATE MATERIALIZED VIEW telemetry.ca_energy_phase_power_15min
WITH (timescaledb.continuous)
AS
SELECT
    time_bucket(
        INTERVAL '15 minutes',
        bucket_start
    ) AS bucket_start,

    organization_id,
    site_id,
    device_id,

    COUNT(*)::bigint AS sample_count,

    AVG(reactive_power_l1_var) AS reactive_power_l1_var_avg,
    MIN(reactive_power_l1_var) AS reactive_power_l1_var_min,
    MAX(reactive_power_l1_var) AS reactive_power_l1_var_max,

    AVG(reactive_power_l2_var) AS reactive_power_l2_var_avg,
    MIN(reactive_power_l2_var) AS reactive_power_l2_var_min,
    MAX(reactive_power_l2_var) AS reactive_power_l2_var_max,

    AVG(reactive_power_l3_var) AS reactive_power_l3_var_avg,
    MIN(reactive_power_l3_var) AS reactive_power_l3_var_min,
    MAX(reactive_power_l3_var) AS reactive_power_l3_var_max,

    AVG(apparent_power_l1_va) AS apparent_power_l1_va_avg,
    MIN(apparent_power_l1_va) AS apparent_power_l1_va_min,
    MAX(apparent_power_l1_va) AS apparent_power_l1_va_max,

    AVG(apparent_power_l2_va) AS apparent_power_l2_va_avg,
    MIN(apparent_power_l2_va) AS apparent_power_l2_va_min,
    MAX(apparent_power_l2_va) AS apparent_power_l2_va_max,

    AVG(apparent_power_l3_va) AS apparent_power_l3_va_avg,
    MIN(apparent_power_l3_va) AS apparent_power_l3_va_min,
    MAX(apparent_power_l3_va) AS apparent_power_l3_va_max

FROM telemetry.energy_measurements

GROUP BY
    time_bucket(
        INTERVAL '15 minutes',
        bucket_start
    ),
    organization_id,
    site_id,
    device_id

WITH NO DATA;


SELECT add_continuous_aggregate_policy(
    'telemetry.ca_energy_phase_power_15min'::regclass,
    start_offset      => INTERVAL '2 days',
    end_offset        => INTERVAL '1 minute',
    schedule_interval => INTERVAL '5 minutes'
);

ALTER MATERIALIZED VIEW telemetry.ca_energy_phase_power_15min
SET (
    timescaledb.compress = TRUE,
    timescaledb.compress_segmentby =
        'organization_id,site_id,device_id',
    timescaledb.compress_orderby =
        'bucket_start DESC'
);

SELECT add_compression_policy(
    'telemetry.ca_energy_phase_power_15min'::regclass,
    INTERVAL '7 days'
);

SELECT add_retention_policy(
    'telemetry.ca_energy_phase_power_15min'::regclass,
    INTERVAL '2 years'
);



-- =====================================================================
-- HOURLY
-- =====================================================================

CREATE MATERIALIZED VIEW telemetry.ca_energy_phase_power_hourly
WITH (timescaledb.continuous)
AS
SELECT
    time_bucket(
        INTERVAL '1 hour',
        bucket_start
    ) AS bucket_start,

    organization_id,
    site_id,
    device_id,

    COUNT(*)::bigint AS sample_count,

    AVG(reactive_power_l1_var) AS reactive_power_l1_var_avg,
    MIN(reactive_power_l1_var) AS reactive_power_l1_var_min,
    MAX(reactive_power_l1_var) AS reactive_power_l1_var_max,

    AVG(reactive_power_l2_var) AS reactive_power_l2_var_avg,
    MIN(reactive_power_l2_var) AS reactive_power_l2_var_min,
    MAX(reactive_power_l2_var) AS reactive_power_l2_var_max,

    AVG(reactive_power_l3_var) AS reactive_power_l3_var_avg,
    MIN(reactive_power_l3_var) AS reactive_power_l3_var_min,
    MAX(reactive_power_l3_var) AS reactive_power_l3_var_max,

    AVG(apparent_power_l1_va) AS apparent_power_l1_va_avg,
    MIN(apparent_power_l1_va) AS apparent_power_l1_va_min,
    MAX(apparent_power_l1_va) AS apparent_power_l1_va_max,

    AVG(apparent_power_l2_va) AS apparent_power_l2_va_avg,
    MIN(apparent_power_l2_va) AS apparent_power_l2_va_min,
    MAX(apparent_power_l2_va) AS apparent_power_l2_va_max,

    AVG(apparent_power_l3_va) AS apparent_power_l3_va_avg,
    MIN(apparent_power_l3_va) AS apparent_power_l3_va_min,
    MAX(apparent_power_l3_va) AS apparent_power_l3_va_max

FROM telemetry.energy_measurements

GROUP BY
    time_bucket(
        INTERVAL '1 hour',
        bucket_start
    ),
    organization_id,
    site_id,
    device_id

WITH NO DATA;


SELECT add_continuous_aggregate_policy(
    'telemetry.ca_energy_phase_power_hourly'::regclass,
    start_offset      => INTERVAL '7 days',
    end_offset        => INTERVAL '5 minutes',
    schedule_interval => INTERVAL '15 minutes'
);

ALTER MATERIALIZED VIEW telemetry.ca_energy_phase_power_hourly
SET (
    timescaledb.compress = TRUE,
    timescaledb.compress_segmentby =
        'organization_id,site_id,device_id',
    timescaledb.compress_orderby =
        'bucket_start DESC'
);

SELECT add_compression_policy(
    'telemetry.ca_energy_phase_power_hourly'::regclass,
    INTERVAL '30 days'
);

SELECT add_retention_policy(
    'telemetry.ca_energy_phase_power_hourly'::regclass,
    INTERVAL '5 years'
);



-- =====================================================================
-- DAILY
-- =====================================================================

CREATE MATERIALIZED VIEW telemetry.ca_energy_phase_power_daily
WITH (timescaledb.continuous)
AS
SELECT
    time_bucket(
        INTERVAL '1 day',
        bucket_start,
        'Asia/Kolkata'
    ) AS bucket_start,

    organization_id,
    site_id,
    device_id,

    COUNT(*)::bigint AS sample_count,

    AVG(reactive_power_l1_var) AS reactive_power_l1_var_avg,
    MIN(reactive_power_l1_var) AS reactive_power_l1_var_min,
    MAX(reactive_power_l1_var) AS reactive_power_l1_var_max,

    AVG(reactive_power_l2_var) AS reactive_power_l2_var_avg,
    MIN(reactive_power_l2_var) AS reactive_power_l2_var_min,
    MAX(reactive_power_l2_var) AS reactive_power_l2_var_max,

    AVG(reactive_power_l3_var) AS reactive_power_l3_var_avg,
    MIN(reactive_power_l3_var) AS reactive_power_l3_var_min,
    MAX(reactive_power_l3_var) AS reactive_power_l3_var_max,

    AVG(apparent_power_l1_va) AS apparent_power_l1_va_avg,
    MIN(apparent_power_l1_va) AS apparent_power_l1_va_min,
    MAX(apparent_power_l1_va) AS apparent_power_l1_va_max,

    AVG(apparent_power_l2_va) AS apparent_power_l2_va_avg,
    MIN(apparent_power_l2_va) AS apparent_power_l2_va_min,
    MAX(apparent_power_l2_va) AS apparent_power_l2_va_max,

    AVG(apparent_power_l3_va) AS apparent_power_l3_va_avg,
    MIN(apparent_power_l3_va) AS apparent_power_l3_va_min,
    MAX(apparent_power_l3_va) AS apparent_power_l3_va_max

FROM telemetry.energy_measurements

GROUP BY
    time_bucket(
        INTERVAL '1 day',
        bucket_start,
        'Asia/Kolkata'
    ),
    organization_id,
    site_id,
    device_id

WITH NO DATA;


SELECT add_continuous_aggregate_policy(
    'telemetry.ca_energy_phase_power_daily'::regclass,
    start_offset      => INTERVAL '30 days',
    end_offset        => INTERVAL '1 hour',
    schedule_interval => INTERVAL '1 hour'
);

ALTER MATERIALIZED VIEW telemetry.ca_energy_phase_power_daily
SET (
    timescaledb.compress = TRUE,
    timescaledb.compress_segmentby =
        'organization_id,site_id,device_id',
    timescaledb.compress_orderby =
        'bucket_start DESC'
);

SELECT add_compression_policy(
    'telemetry.ca_energy_phase_power_daily'::regclass,
    INTERVAL '90 days'
);

-- No retention policy by design for daily long-term history.


COMMENT ON VIEW telemetry.ca_energy_phase_power_1min
IS 'Supplemental 1-minute phase reactive/apparent power historian.';

COMMENT ON VIEW telemetry.ca_energy_phase_power_5min
IS 'Supplemental 5-minute phase reactive/apparent power historian.';

COMMENT ON VIEW telemetry.ca_energy_phase_power_15min
IS 'Supplemental 15-minute phase reactive/apparent power historian.';

COMMENT ON VIEW telemetry.ca_energy_phase_power_hourly
IS 'Supplemental hourly phase reactive/apparent power historian.';

COMMENT ON VIEW telemetry.ca_energy_phase_power_daily
IS 'Supplemental long-term daily phase reactive/apparent power historian.';


COMMIT;
