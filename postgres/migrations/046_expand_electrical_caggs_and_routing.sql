-- ============================================================================
-- Migration 046
-- Expand electrical rollup coverage and add dynamic-resolution routing for
-- non-energy (point-in-time) trend charts
--
-- Purpose:
--   Add voltage_ln_avg_v, neutral_current_a, and the three voltage-THD
--   columns to the 15-minute/hourly rollup layer, then wire up the same
--   <=24h/<=14d/>14d dynamic routing already used for energy
--   (migrations 044/045) to a new asset-parameterized electrical trend
--   contract, so Active Power / Voltage / Current / Power Factor &
--   Frequency / THD panels can route the same way energy panels do.
--
-- Why a supplemental continuous aggregate instead of dropping and
-- recreating telemetry.ca_energy_15min / ca_energy_hourly:
--   Those two CAGGs have 19 dependent views across 5 levels (demand KPIs,
--   peak-demand daily/monthly, load-profile-by-hour-of-day, site energy
--   balance, and the legacy analytics.v_grafana_asset_energy_intervals
--   view still granted to grafana_reader). TimescaleDB continuous
--   aggregates cannot have columns added via ALTER -- only by drop and
--   recreate -- and dropping either CAGG would CASCADE through that
--   entire tree. Migration 178 hit this identical situation adding phase
--   reactive/apparent power and deliberately left the canonical energy
--   CAGGs untouched, creating a separate supplemental CAGG instead. This
--   migration follows that same established precedent:
--     telemetry.ca_energy_electrical_ext_15min
--     telemetry.ca_energy_electrical_ext_hourly
--   keyed identically to (and refreshed/compressed on the same schedule
--   as) their base counterparts, holding only the newly-requested
--   columns. analytics.v_energy_15min / v_energy_hourly are updated with
--   CREATE OR REPLACE VIEW, appending the new columns at the end of the
--   SELECT list -- Postgres requires existing columns to stay in place
--   for CREATE OR REPLACE VIEW, so this is non-breaking for all 19
--   existing dependents; none of them need to change.
--
-- Backfill:
--   telemetry.refresh_continuous_aggregate() cannot be called inside an
--   explicit transaction block, and this repo's migration runner always
--   wraps migration files in BEGIN/COMMIT -- so the historical backfill
--   for the two new CAGGs is NOT in this file. It must be run as a
--   separate, non-transactional command immediately after this migration
--   is applied:
--
--     CALL refresh_continuous_aggregate('telemetry.ca_energy_electrical_ext_15min', NULL, NULL);
--     CALL refresh_continuous_aggregate('telemetry.ca_energy_electrical_ext_hourly', NULL, NULL);
--
-- New objects:
--   telemetry.ca_energy_electrical_ext_15min / _hourly
--     Supplemental continuous aggregates (see above).
--
--   analytics.v_energy_15min / v_energy_hourly
--     CREATE OR REPLACE, appending the new columns.
--
--   analytics.resolve_grafana_electrical_routing_resolution(from, to)
--     Pure tier-selection helper, same <=24h/<=14d/>14d thresholds as
--     analytics.resolve_grafana_energy_routing_resolution (migration 045),
--     returning which source to read from: native / 15m / 1h.
--
--   analytics.get_grafana_asset_electrical_trend(...)
--     Single-asset routing contract: <=24h reads
--     analytics.v_grafana_asset_electrical_samples (native), <=14d reads
--     analytics.v_energy_15min, >14d reads analytics.v_energy_hourly.
--     Returns one representative value per metric per bucket (native
--     value, or _avg for the two rollup tiers) -- min/max remain
--     available directly on v_energy_15min/v_energy_hourly for anyone
--     building a banded chart later; this contract mirrors the single-
--     value-per-bucket shape analytics.get_grafana_asset_energy_intervals
--     already established.
--
--   analytics.get_grafana_assets_electrical_trend(...)
--     Multi-asset fan-out with the same 10-asset-max safeguard as
--     analytics.get_grafana_assets_energy_intervals (migration 044).
-- ============================================================================


-- ----------------------------------------------------------------------------
-- 1. Supplemental 15-minute electrical continuous aggregate.
-- ----------------------------------------------------------------------------

CREATE MATERIALIZED VIEW IF NOT EXISTS telemetry.ca_energy_electrical_ext_15min
WITH
(
    timescaledb.continuous
)
AS

SELECT
    time_bucket
    (
        INTERVAL '15 minutes',
        bucket_start
    ) AS bucket_start,

    organization_id,
    site_id,
    device_id,

    COUNT(*)::BIGINT AS sample_count,

    AVG(voltage_ln_avg_v)
        AS voltage_ln_avg_v_avg,

    MIN(voltage_ln_avg_v)
        AS voltage_ln_avg_v_min,

    MAX(voltage_ln_avg_v)
        AS voltage_ln_avg_v_max,

    AVG(neutral_current_a)
        AS neutral_current_a_avg,

    MIN(neutral_current_a)
        AS neutral_current_a_min,

    MAX(neutral_current_a)
        AS neutral_current_a_max,

    AVG(voltage_thd_l1_percent)
        AS voltage_thd_l1_percent_avg,

    MAX(voltage_thd_l1_percent)
        AS voltage_thd_l1_percent_max,

    AVG(voltage_thd_l2_percent)
        AS voltage_thd_l2_percent_avg,

    MAX(voltage_thd_l2_percent)
        AS voltage_thd_l2_percent_max,

    AVG(voltage_thd_l3_percent)
        AS voltage_thd_l3_percent_avg,

    MAX(voltage_thd_l3_percent)
        AS voltage_thd_l3_percent_max

FROM telemetry.energy_measurements

GROUP BY
    1,
    organization_id,
    site_id,
    device_id

WITH NO DATA;


SELECT add_continuous_aggregate_policy
(
    'telemetry.ca_energy_electrical_ext_15min'::REGCLASS,

    start_offset      => INTERVAL '2 days',
    end_offset        => INTERVAL '1 minute',
    schedule_interval => INTERVAL '5 minutes',

    if_not_exists     => TRUE
);


ALTER MATERIALIZED VIEW telemetry.ca_energy_electrical_ext_15min
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
    'telemetry.ca_energy_electrical_ext_15min'::REGCLASS,
    compress_after    => INTERVAL '7 days',
    if_not_exists     => TRUE,
    schedule_interval => INTERVAL '1 day',
    timezone          => 'Asia/Kolkata'
);


-- ----------------------------------------------------------------------------
-- 2. Supplemental hourly electrical continuous aggregate.
-- ----------------------------------------------------------------------------

CREATE MATERIALIZED VIEW IF NOT EXISTS telemetry.ca_energy_electrical_ext_hourly
WITH
(
    timescaledb.continuous
)
AS

SELECT
    time_bucket(
        INTERVAL '1 hour',
        bucket_start
    ) AS bucket_start,

    organization_id,
    site_id,
    device_id,

    COUNT(*)::BIGINT AS sample_count,

    AVG(voltage_ln_avg_v)
        AS voltage_ln_avg_v_avg,

    MIN(voltage_ln_avg_v)
        AS voltage_ln_avg_v_min,

    MAX(voltage_ln_avg_v)
        AS voltage_ln_avg_v_max,

    AVG(neutral_current_a)
        AS neutral_current_a_avg,

    MIN(neutral_current_a)
        AS neutral_current_a_min,

    MAX(neutral_current_a)
        AS neutral_current_a_max,

    AVG(voltage_thd_l1_percent)
        AS voltage_thd_l1_percent_avg,

    MAX(voltage_thd_l1_percent)
        AS voltage_thd_l1_percent_max,

    AVG(voltage_thd_l2_percent)
        AS voltage_thd_l2_percent_avg,

    MAX(voltage_thd_l2_percent)
        AS voltage_thd_l2_percent_max,

    AVG(voltage_thd_l3_percent)
        AS voltage_thd_l3_percent_avg,

    MAX(voltage_thd_l3_percent)
        AS voltage_thd_l3_percent_max

FROM telemetry.energy_measurements

GROUP BY
    1,
    organization_id,
    site_id,
    device_id

WITH NO DATA;


SELECT add_continuous_aggregate_policy
(
    'telemetry.ca_energy_electrical_ext_hourly'::REGCLASS,

    start_offset      => INTERVAL '7 days',
    end_offset        => INTERVAL '5 minutes',
    schedule_interval => INTERVAL '15 minutes',

    if_not_exists     => TRUE
);


ALTER MATERIALIZED VIEW telemetry.ca_energy_electrical_ext_hourly
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
    'telemetry.ca_energy_electrical_ext_hourly'::REGCLASS,
    compress_after    => INTERVAL '30 days',
    if_not_exists     => TRUE,
    schedule_interval => INTERVAL '1 day',
    timezone          => 'Asia/Kolkata'
);


-- ----------------------------------------------------------------------------
-- 3. Expose the new columns on the existing tenant-scoped 15-minute /
--    hourly views. Appended at the end of the SELECT list only -- every
--    pre-existing column keeps its name, type and position, so this is
--    non-breaking for all existing dependents of these two views.
-- ----------------------------------------------------------------------------

CREATE OR REPLACE VIEW analytics.v_energy_15min AS
SELECT
    gom.grafana_org_id,
    ca.*,
    ext.voltage_ln_avg_v_avg,
    ext.voltage_ln_avg_v_min,
    ext.voltage_ln_avg_v_max,
    ext.neutral_current_a_avg,
    ext.neutral_current_a_min,
    ext.neutral_current_a_max,
    ext.voltage_thd_l1_percent_avg,
    ext.voltage_thd_l1_percent_max,
    ext.voltage_thd_l2_percent_avg,
    ext.voltage_thd_l2_percent_max,
    ext.voltage_thd_l3_percent_avg,
    ext.voltage_thd_l3_percent_max
FROM metadata.grafana_organization_map gom
JOIN telemetry.ca_energy_15min ca
  ON ca.organization_id = gom.organization_id
LEFT JOIN telemetry.ca_energy_electrical_ext_15min ext
  ON ext.bucket_start = ca.bucket_start
 AND ext.organization_id = ca.organization_id
 AND ext.site_id = ca.site_id
 AND ext.device_id = ca.device_id
WHERE gom.is_active;


CREATE OR REPLACE VIEW analytics.v_energy_hourly AS
SELECT
    gom.grafana_org_id,
    ca.*,
    ext.voltage_ln_avg_v_avg,
    ext.voltage_ln_avg_v_min,
    ext.voltage_ln_avg_v_max,
    ext.neutral_current_a_avg,
    ext.neutral_current_a_min,
    ext.neutral_current_a_max,
    ext.voltage_thd_l1_percent_avg,
    ext.voltage_thd_l1_percent_max,
    ext.voltage_thd_l2_percent_avg,
    ext.voltage_thd_l2_percent_max,
    ext.voltage_thd_l3_percent_avg,
    ext.voltage_thd_l3_percent_max
FROM metadata.grafana_organization_map gom
JOIN telemetry.ca_energy_hourly ca
  ON ca.organization_id = gom.organization_id
LEFT JOIN telemetry.ca_energy_electrical_ext_hourly ext
  ON ext.bucket_start = ca.bucket_start
 AND ext.organization_id = ca.organization_id
 AND ext.site_id = ca.site_id
 AND ext.device_id = ca.device_id
WHERE gom.is_active;


REVOKE ALL ON analytics.v_energy_15min FROM PUBLIC;
REVOKE ALL ON analytics.v_energy_hourly FROM PUBLIC;

GRANT SELECT ON analytics.v_energy_15min TO ems_admin, ems_app, ems_readonly;
GRANT SELECT ON analytics.v_energy_hourly TO ems_admin, ems_app, ems_readonly;


-- ----------------------------------------------------------------------------
-- 4. Routing helper: same <=24h / <=14d / >14d thresholds as
--    analytics.resolve_grafana_energy_routing_resolution (migration 045),
--    returning which source to read from instead of a canonical-reader
--    resolution key.
-- ----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION analytics.resolve_grafana_electrical_routing_resolution(
    p_from TIMESTAMPTZ,
    p_to TIMESTAMPTZ
)
RETURNS TEXT
LANGUAGE SQL
IMMUTABLE
AS $function$
SELECT CASE
    WHEN p_to - p_from <= INTERVAL '24 hours' THEN 'native'
    WHEN p_to - p_from <= INTERVAL '14 days'  THEN '15m'
    ELSE '1h'
END;
$function$;


COMMENT ON FUNCTION analytics.resolve_grafana_electrical_routing_resolution(
    TIMESTAMPTZ,
    TIMESTAMPTZ
)
IS
'Maps a Grafana panel time range to an electrical-trend source: <=24h -> native (analytics.v_grafana_asset_electrical_samples), <=14d -> 15m (analytics.v_energy_15min), >14d -> 1h (analytics.v_energy_hourly). Same thresholds as analytics.resolve_grafana_energy_routing_resolution.';


-- ----------------------------------------------------------------------------
-- 5. Single-asset electrical trend routing contract.
-- ----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION analytics.get_grafana_asset_electrical_trend(
    p_grafana_org_id BIGINT,
    p_asset_id UUID,
    p_from TIMESTAMPTZ,
    p_to TIMESTAMPTZ
)
RETURNS TABLE (
    interval_start TIMESTAMPTZ,
    device_id UUID,
    device_name TEXT,
    active_power_kw DOUBLE PRECISION,
    voltage_l1_v DOUBLE PRECISION,
    voltage_l2_v DOUBLE PRECISION,
    voltage_l3_v DOUBLE PRECISION,
    voltage_ln_avg_v DOUBLE PRECISION,
    current_l1_a DOUBLE PRECISION,
    current_l2_a DOUBLE PRECISION,
    current_l3_a DOUBLE PRECISION,
    neutral_current_a DOUBLE PRECISION,
    power_factor_total DOUBLE PRECISION,
    frequency_hz DOUBLE PRECISION,
    current_thd_l1_percent DOUBLE PRECISION,
    current_thd_l2_percent DOUBLE PRECISION,
    current_thd_l3_percent DOUBLE PRECISION,
    voltage_thd_l1_percent DOUBLE PRECISION,
    voltage_thd_l2_percent DOUBLE PRECISION,
    voltage_thd_l3_percent DOUBLE PRECISION
)
LANGUAGE SQL
STABLE
SECURITY DEFINER
SET search_path TO
    pg_catalog,
    analytics,
    metadata,
    telemetry
AS $function$

WITH params AS (
    SELECT
        p_from AS range_from,
        p_to AS range_to,
        analytics.resolve_grafana_electrical_routing_resolution(p_from, p_to) AS resolution
    WHERE p_to > p_from
),

ctx AS (
    SELECT
        ad.device_id,
        d.name AS device_name
    FROM metadata.grafana_organization_map AS gom

    JOIN metadata.assets AS a
      ON a.organization_id = gom.organization_id

    JOIN metadata.asset_devices AS ad
      ON ad.asset_id = a.id
     AND ad.relationship_type = 'PRIMARY_METER'

    JOIN metadata.devices AS d
      ON d.id = ad.device_id

    WHERE gom.grafana_org_id = p_grafana_org_id
      AND gom.is_active
      AND a.id = p_asset_id

    LIMIT 1
)

SELECT
    e.sample_time,
    ctx.device_id,
    ctx.device_name,
    e.active_power_kw,
    e.voltage_l1_v,
    e.voltage_l2_v,
    e.voltage_l3_v,
    e.voltage_ln_avg_v,
    e.current_l1_a,
    e.current_l2_a,
    e.current_l3_a,
    e.neutral_current_a,
    e.power_factor_total,
    e.frequency_hz,
    e.current_thd_l1_percent,
    e.current_thd_l2_percent,
    e.current_thd_l3_percent,
    e.voltage_thd_l1_percent,
    e.voltage_thd_l2_percent,
    e.voltage_thd_l3_percent
FROM ctx
CROSS JOIN params
JOIN analytics.v_grafana_asset_electrical_samples AS e
  ON e.grafana_org_id = p_grafana_org_id
 AND e.asset_id = p_asset_id
 AND e.sample_time >= params.range_from
 AND e.sample_time <= params.range_to
WHERE params.resolution = 'native'

UNION ALL

SELECT
    f.bucket_start,
    ctx.device_id,
    ctx.device_name,
    f.active_power_total_w_avg / 1000.0,
    f.voltage_l1_v_avg,
    f.voltage_l2_v_avg,
    f.voltage_l3_v_avg,
    f.voltage_ln_avg_v_avg,
    f.current_l1_a_avg,
    f.current_l2_a_avg,
    f.current_l3_a_avg,
    f.neutral_current_a_avg,
    f.power_factor_total_avg,
    f.frequency_hz_avg,
    f.current_thd_l1_percent_avg,
    f.current_thd_l2_percent_avg,
    f.current_thd_l3_percent_avg,
    f.voltage_thd_l1_percent_avg,
    f.voltage_thd_l2_percent_avg,
    f.voltage_thd_l3_percent_avg
FROM ctx
CROSS JOIN params
JOIN analytics.v_energy_15min AS f
  ON f.grafana_org_id = p_grafana_org_id
 AND f.device_id = ctx.device_id
 AND f.bucket_start >= params.range_from
 AND f.bucket_start <= params.range_to
WHERE params.resolution = '15m'

UNION ALL

SELECT
    h.bucket_start,
    ctx.device_id,
    ctx.device_name,
    h.active_power_total_w_avg / 1000.0,
    h.voltage_l1_v_avg,
    h.voltage_l2_v_avg,
    h.voltage_l3_v_avg,
    h.voltage_ln_avg_v_avg,
    h.current_l1_a_avg,
    h.current_l2_a_avg,
    h.current_l3_a_avg,
    h.neutral_current_a_avg,
    h.power_factor_total_avg,
    h.frequency_hz_avg,
    h.current_thd_l1_percent_avg,
    h.current_thd_l2_percent_avg,
    h.current_thd_l3_percent_avg,
    h.voltage_thd_l1_percent_avg,
    h.voltage_thd_l2_percent_avg,
    h.voltage_thd_l3_percent_avg
FROM ctx
CROSS JOIN params
JOIN analytics.v_energy_hourly AS h
  ON h.grafana_org_id = p_grafana_org_id
 AND h.device_id = ctx.device_id
 AND h.bucket_start >= params.range_from
 AND h.bucket_start <= params.range_to
WHERE params.resolution = '1h'

ORDER BY 1;

$function$;


COMMENT ON FUNCTION analytics.get_grafana_asset_electrical_trend(
    BIGINT,
    UUID,
    TIMESTAMPTZ,
    TIMESTAMPTZ
)
IS
'Tenant-safe point-in-time electrical trend contract (active power, voltage, current, power factor, frequency, THD) with dynamic resolution routing: <=24h reads analytics.v_grafana_asset_electrical_samples (native), <=14d reads analytics.v_energy_15min, >14d reads analytics.v_energy_hourly. One representative value per metric per bucket (native value, or _avg for the two rollup tiers). Grafana organization ownership and PRIMARY_METER assignment are resolved before returning rows; an invalid range (p_to <= p_from) or unknown tenant/asset returns zero rows.';


ALTER FUNCTION analytics.get_grafana_asset_electrical_trend(
    BIGINT,
    UUID,
    TIMESTAMPTZ,
    TIMESTAMPTZ
)
OWNER TO ems_admin;


REVOKE ALL
ON FUNCTION analytics.get_grafana_asset_electrical_trend(
    BIGINT,
    UUID,
    TIMESTAMPTZ,
    TIMESTAMPTZ
)
FROM PUBLIC;


GRANT EXECUTE
ON FUNCTION analytics.get_grafana_asset_electrical_trend(
    BIGINT,
    UUID,
    TIMESTAMPTZ,
    TIMESTAMPTZ
)
TO
    ems_app,
    ems_readonly,
    grafana_reader;


-- ----------------------------------------------------------------------------
-- 6. Multi-asset fan-out, same 10-asset-max safeguard as
--    analytics.get_grafana_assets_energy_intervals (migration 044).
-- ----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION analytics.get_grafana_assets_electrical_trend(
    p_grafana_org_id BIGINT,
    p_asset_ids UUID[],
    p_from TIMESTAMPTZ,
    p_to TIMESTAMPTZ
)
RETURNS TABLE (
    asset_id UUID,
    interval_start TIMESTAMPTZ,
    device_id UUID,
    device_name TEXT,
    active_power_kw DOUBLE PRECISION,
    voltage_l1_v DOUBLE PRECISION,
    voltage_l2_v DOUBLE PRECISION,
    voltage_l3_v DOUBLE PRECISION,
    voltage_ln_avg_v DOUBLE PRECISION,
    current_l1_a DOUBLE PRECISION,
    current_l2_a DOUBLE PRECISION,
    current_l3_a DOUBLE PRECISION,
    neutral_current_a DOUBLE PRECISION,
    power_factor_total DOUBLE PRECISION,
    frequency_hz DOUBLE PRECISION,
    current_thd_l1_percent DOUBLE PRECISION,
    current_thd_l2_percent DOUBLE PRECISION,
    current_thd_l3_percent DOUBLE PRECISION,
    voltage_thd_l1_percent DOUBLE PRECISION,
    voltage_thd_l2_percent DOUBLE PRECISION,
    voltage_thd_l3_percent DOUBLE PRECISION
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO
    pg_catalog,
    analytics,
    metadata,
    telemetry
AS $function$
DECLARE
    v_asset_count INTEGER;
    v_asset_id UUID;
BEGIN
    v_asset_count := array_length(p_asset_ids, 1);

    IF p_asset_ids IS NULL OR v_asset_count IS NULL THEN
        RAISE EXCEPTION
            'p_asset_ids must contain at least one asset';
    END IF;

    IF v_asset_count > 10 THEN
        RAISE EXCEPTION
            'too many assets requested (%); a maximum of 10 assets is '
            'supported per multi-asset Grafana electrical trend query',
            v_asset_count;
    END IF;

    IF p_from IS NULL OR p_to IS NULL OR p_to <= p_from THEN
        RETURN;
    END IF;

    FOREACH v_asset_id IN ARRAY p_asset_ids
    LOOP
        RETURN QUERY
        SELECT
            v_asset_id,
            i.interval_start,
            i.device_id,
            i.device_name,
            i.active_power_kw,
            i.voltage_l1_v,
            i.voltage_l2_v,
            i.voltage_l3_v,
            i.voltage_ln_avg_v,
            i.current_l1_a,
            i.current_l2_a,
            i.current_l3_a,
            i.neutral_current_a,
            i.power_factor_total,
            i.frequency_hz,
            i.current_thd_l1_percent,
            i.current_thd_l2_percent,
            i.current_thd_l3_percent,
            i.voltage_thd_l1_percent,
            i.voltage_thd_l2_percent,
            i.voltage_thd_l3_percent
        FROM analytics.get_grafana_asset_electrical_trend(
            p_grafana_org_id,
            v_asset_id,
            p_from,
            p_to
        ) AS i;
    END LOOP;

    RETURN;
END;
$function$;


COMMENT ON FUNCTION analytics.get_grafana_assets_electrical_trend(
    BIGINT,
    UUID[],
    TIMESTAMPTZ,
    TIMESTAMPTZ
)
IS
'Multi-asset fan-out over analytics.get_grafana_asset_electrical_trend for multi-series Grafana panels. Rejects NULL/empty p_asset_ids and rejects more than 10 assets per call, identical safeguard to analytics.get_grafana_assets_energy_intervals.';


ALTER FUNCTION analytics.get_grafana_assets_electrical_trend(
    BIGINT,
    UUID[],
    TIMESTAMPTZ,
    TIMESTAMPTZ
)
OWNER TO ems_admin;


REVOKE ALL
ON FUNCTION analytics.get_grafana_assets_electrical_trend(
    BIGINT,
    UUID[],
    TIMESTAMPTZ,
    TIMESTAMPTZ
)
FROM PUBLIC;


GRANT EXECUTE
ON FUNCTION analytics.get_grafana_assets_electrical_trend(
    BIGINT,
    UUID[],
    TIMESTAMPTZ,
    TIMESTAMPTZ
)
TO
    ems_app,
    ems_readonly,
    grafana_reader;
