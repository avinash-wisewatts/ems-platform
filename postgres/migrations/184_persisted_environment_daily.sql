BEGIN;

-- ============================================================================
-- Persisted site-local daily environment historian.
--
-- Source:
--   telemetry.environment_measurements
--
-- Rationale:
--   * daily boundaries must follow metadata.sites.timezone;
--   * daily AVG must be calculated from native samples, not AVG(hourly AVG);
--   * pressure / CO2 / VOC / signal strength retain MIN/MAX/sample counts even
--     though the older 15-minute CAGG does not expose all of them;
--   * daily history is intentionally durable beyond native retention.
-- ============================================================================


CREATE TABLE telemetry.environment_daily
(
    bucket_start TIMESTAMPTZ NOT NULL,

    observation_date DATE NOT NULL,
    site_timezone   TEXT NOT NULL,

    organization_id UUID NOT NULL,
    site_id         UUID NOT NULL,
    gateway_id      UUID,
    device_id       UUID NOT NULL,
    asset_id        UUID,

    sample_count BIGINT NOT NULL,

    temperature_c_avg DOUBLE PRECISION,
    temperature_c_min DOUBLE PRECISION,
    temperature_c_max DOUBLE PRECISION,
    temperature_sample_count BIGINT NOT NULL,

    humidity_percent_avg DOUBLE PRECISION,
    humidity_percent_min DOUBLE PRECISION,
    humidity_percent_max DOUBLE PRECISION,
    humidity_sample_count BIGINT NOT NULL,

    illuminance_lux_avg DOUBLE PRECISION,
    illuminance_lux_min DOUBLE PRECISION,
    illuminance_lux_max DOUBLE PRECISION,
    illuminance_sample_count BIGINT NOT NULL,

    occupancy_activity_avg DOUBLE PRECISION,
    occupancy_activity_min DOUBLE PRECISION,
    occupancy_activity_max DOUBLE PRECISION,
    occupancy_sample_count BIGINT NOT NULL,

    battery_voltage_v_avg DOUBLE PRECISION,
    battery_voltage_v_min DOUBLE PRECISION,
    battery_voltage_v_max DOUBLE PRECISION,
    battery_sample_count BIGINT NOT NULL,

    pressure_hpa_avg DOUBLE PRECISION,
    pressure_hpa_min DOUBLE PRECISION,
    pressure_hpa_max DOUBLE PRECISION,
    pressure_sample_count BIGINT NOT NULL,

    co2_ppm_avg DOUBLE PRECISION,
    co2_ppm_min DOUBLE PRECISION,
    co2_ppm_max DOUBLE PRECISION,
    co2_sample_count BIGINT NOT NULL,

    voc_ppb_avg DOUBLE PRECISION,
    voc_ppb_min DOUBLE PRECISION,
    voc_ppb_max DOUBLE PRECISION,
    voc_sample_count BIGINT NOT NULL,

    signal_strength_dbm_avg DOUBLE PRECISION,
    signal_strength_dbm_min DOUBLE PRECISION,
    signal_strength_dbm_max DOUBLE PRECISION,
    signal_strength_sample_count BIGINT NOT NULL,

    first_source_bucket TIMESTAMPTZ,
    last_source_bucket  TIMESTAMPTZ,

    calculated_at TIMESTAMPTZ NOT NULL
        DEFAULT clock_timestamp(),

    PRIMARY KEY
    (
        device_id,
        bucket_start
    )
);


COMMENT ON TABLE telemetry.environment_daily IS
'Durable site-local daily environment historian calculated directly from native environment measurements with sample-weighted daily statistics.';


COMMENT ON COLUMN telemetry.environment_daily.bucket_start IS
'UTC instant corresponding to local midnight for observation_date in site_timezone.';


COMMENT ON COLUMN telemetry.environment_daily.occupancy_activity_avg IS
'Average native occupancy activity value for the local day. Consumers should interpret occupancy according to point semantics rather than as a generic analog quantity.';


SELECT create_hypertable
(
    'telemetry.environment_daily',
    'bucket_start',
    if_not_exists => TRUE,
    migrate_data  => TRUE
);


CREATE INDEX
    ix_environment_daily_org_site_date
ON telemetry.environment_daily
(
    organization_id,
    site_id,
    observation_date DESC
);


CREATE INDEX
    ix_environment_daily_device_time
ON telemetry.environment_daily
(
    device_id,
    bucket_start DESC
);


-- ============================================================================
-- REFRESH FUNCTION
-- ============================================================================

CREATE OR REPLACE FUNCTION telemetry.refresh_environment_daily
(
    p_from TIMESTAMPTZ,
    p_to   TIMESTAMPTZ
)
RETURNS BIGINT
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO
    pg_catalog,
    telemetry,
    metadata
AS $function$

DECLARE
    v_affected BIGINT := 0;
BEGIN

    IF p_from IS NULL OR p_to IS NULL THEN
        RAISE EXCEPTION
            'p_from and p_to are required';
    END IF;

    IF p_to <= p_from THEN
        RAISE EXCEPTION
            'p_to (%) must be later than p_from (%)',
            p_to,
            p_from;
    END IF;


    INSERT INTO telemetry.environment_daily
    (
        bucket_start,
        observation_date,
        site_timezone,

        organization_id,
        site_id,
        gateway_id,
        device_id,
        asset_id,

        sample_count,

        temperature_c_avg,
        temperature_c_min,
        temperature_c_max,
        temperature_sample_count,

        humidity_percent_avg,
        humidity_percent_min,
        humidity_percent_max,
        humidity_sample_count,

        illuminance_lux_avg,
        illuminance_lux_min,
        illuminance_lux_max,
        illuminance_sample_count,

        occupancy_activity_avg,
        occupancy_activity_min,
        occupancy_activity_max,
        occupancy_sample_count,

        battery_voltage_v_avg,
        battery_voltage_v_min,
        battery_voltage_v_max,
        battery_sample_count,

        pressure_hpa_avg,
        pressure_hpa_min,
        pressure_hpa_max,
        pressure_sample_count,

        co2_ppm_avg,
        co2_ppm_min,
        co2_ppm_max,
        co2_sample_count,

        voc_ppb_avg,
        voc_ppb_min,
        voc_ppb_max,
        voc_sample_count,

        signal_strength_dbm_avg,
        signal_strength_dbm_min,
        signal_strength_dbm_max,
        signal_strength_sample_count,

        first_source_bucket,
        last_source_bucket,

        calculated_at
    )

    WITH localized AS
    (
        SELECT
            e.*,

            s.timezone AS site_timezone,

            (
                e.bucket_start
                AT TIME ZONE s.timezone
            )::DATE AS observation_date,

            (
                (
                    (
                        e.bucket_start
                        AT TIME ZONE s.timezone
                    )::DATE
                )::TIMESTAMP
                AT TIME ZONE s.timezone
            ) AS local_day_start,

            (
                (
                    (
                        (
                            e.bucket_start
                            AT TIME ZONE s.timezone
                        )::DATE
                        + 1
                    )::TIMESTAMP
                )
                AT TIME ZONE s.timezone
            ) AS local_day_end

        FROM telemetry.environment_measurements e

        JOIN metadata.sites s
          ON s.id = e.site_id
         AND s.organization_id =
             e.organization_id

        WHERE
            e.bucket_start >=
                p_from - INTERVAL '1 day'

            AND e.bucket_start <
                p_to
    )

    SELECT
        l.local_day_start,
        l.observation_date,
        l.site_timezone,

        l.organization_id,
        l.site_id,
        l.gateway_id,
        l.device_id,
        l.asset_id,

        COUNT(*)::BIGINT,

        AVG(l.temperature_c),
        MIN(l.temperature_c),
        MAX(l.temperature_c),
        COUNT(l.temperature_c)::BIGINT,

        AVG(l.humidity_percent),
        MIN(l.humidity_percent),
        MAX(l.humidity_percent),
        COUNT(l.humidity_percent)::BIGINT,

        AVG(l.illuminance_lux),
        MIN(l.illuminance_lux),
        MAX(l.illuminance_lux),
        COUNT(l.illuminance_lux)::BIGINT,

        AVG(l.occupancy_activity),
        MIN(l.occupancy_activity),
        MAX(l.occupancy_activity),
        COUNT(l.occupancy_activity)::BIGINT,

        AVG(l.battery_voltage_v),
        MIN(l.battery_voltage_v),
        MAX(l.battery_voltage_v),
        COUNT(l.battery_voltage_v)::BIGINT,

        AVG(l.pressure_hpa),
        MIN(l.pressure_hpa),
        MAX(l.pressure_hpa),
        COUNT(l.pressure_hpa)::BIGINT,

        AVG(l.co2_ppm),
        MIN(l.co2_ppm),
        MAX(l.co2_ppm),
        COUNT(l.co2_ppm)::BIGINT,

        AVG(l.voc_ppb),
        MIN(l.voc_ppb),
        MAX(l.voc_ppb),
        COUNT(l.voc_ppb)::BIGINT,

        AVG(l.signal_strength_dbm),
        MIN(l.signal_strength_dbm),
        MAX(l.signal_strength_dbm),
        COUNT(l.signal_strength_dbm)::BIGINT,

        MIN(l.bucket_start),
        MAX(l.bucket_start),

        clock_timestamp()

    FROM localized l

    WHERE
        l.local_day_end > p_from
        AND l.local_day_end <= p_to

    GROUP BY
        l.local_day_start,
        l.observation_date,
        l.site_timezone,

        l.organization_id,
        l.site_id,
        l.gateway_id,
        l.device_id,
        l.asset_id


    ON CONFLICT
    (
        device_id,
        bucket_start
    )
    DO UPDATE
    SET
        observation_date =
            EXCLUDED.observation_date,

        site_timezone =
            EXCLUDED.site_timezone,

        organization_id =
            EXCLUDED.organization_id,

        site_id =
            EXCLUDED.site_id,

        gateway_id =
            EXCLUDED.gateway_id,

        asset_id =
            EXCLUDED.asset_id,

        sample_count =
            EXCLUDED.sample_count,

        temperature_c_avg =
            EXCLUDED.temperature_c_avg,

        temperature_c_min =
            EXCLUDED.temperature_c_min,

        temperature_c_max =
            EXCLUDED.temperature_c_max,

        temperature_sample_count =
            EXCLUDED.temperature_sample_count,

        humidity_percent_avg =
            EXCLUDED.humidity_percent_avg,

        humidity_percent_min =
            EXCLUDED.humidity_percent_min,

        humidity_percent_max =
            EXCLUDED.humidity_percent_max,

        humidity_sample_count =
            EXCLUDED.humidity_sample_count,

        illuminance_lux_avg =
            EXCLUDED.illuminance_lux_avg,

        illuminance_lux_min =
            EXCLUDED.illuminance_lux_min,

        illuminance_lux_max =
            EXCLUDED.illuminance_lux_max,

        illuminance_sample_count =
            EXCLUDED.illuminance_sample_count,

        occupancy_activity_avg =
            EXCLUDED.occupancy_activity_avg,

        occupancy_activity_min =
            EXCLUDED.occupancy_activity_min,

        occupancy_activity_max =
            EXCLUDED.occupancy_activity_max,

        occupancy_sample_count =
            EXCLUDED.occupancy_sample_count,

        battery_voltage_v_avg =
            EXCLUDED.battery_voltage_v_avg,

        battery_voltage_v_min =
            EXCLUDED.battery_voltage_v_min,

        battery_voltage_v_max =
            EXCLUDED.battery_voltage_v_max,

        battery_sample_count =
            EXCLUDED.battery_sample_count,

        pressure_hpa_avg =
            EXCLUDED.pressure_hpa_avg,

        pressure_hpa_min =
            EXCLUDED.pressure_hpa_min,

        pressure_hpa_max =
            EXCLUDED.pressure_hpa_max,

        pressure_sample_count =
            EXCLUDED.pressure_sample_count,

        co2_ppm_avg =
            EXCLUDED.co2_ppm_avg,

        co2_ppm_min =
            EXCLUDED.co2_ppm_min,

        co2_ppm_max =
            EXCLUDED.co2_ppm_max,

        co2_sample_count =
            EXCLUDED.co2_sample_count,

        voc_ppb_avg =
            EXCLUDED.voc_ppb_avg,

        voc_ppb_min =
            EXCLUDED.voc_ppb_min,

        voc_ppb_max =
            EXCLUDED.voc_ppb_max,

        voc_sample_count =
            EXCLUDED.voc_sample_count,

        signal_strength_dbm_avg =
            EXCLUDED.signal_strength_dbm_avg,

        signal_strength_dbm_min =
            EXCLUDED.signal_strength_dbm_min,

        signal_strength_dbm_max =
            EXCLUDED.signal_strength_dbm_max,

        signal_strength_sample_count =
            EXCLUDED.signal_strength_sample_count,

        first_source_bucket =
            EXCLUDED.first_source_bucket,

        last_source_bucket =
            EXCLUDED.last_source_bucket,

        calculated_at =
            EXCLUDED.calculated_at;


    GET DIAGNOSTICS
        v_affected = ROW_COUNT;

    RETURN v_affected;

END;

$function$;


COMMENT ON FUNCTION telemetry.refresh_environment_daily(
    TIMESTAMPTZ,
    TIMESTAMPTZ
) IS
'Refreshes completed site-local environment days directly from telemetry.environment_measurements.';


REVOKE ALL
ON FUNCTION telemetry.refresh_environment_daily(
    TIMESTAMPTZ,
    TIMESTAMPTZ
)
FROM PUBLIC;


-- ============================================================================
-- JOB
-- ============================================================================

CREATE OR REPLACE PROCEDURE telemetry.run_environment_daily_job
(
    job_id INTEGER,
    config JSONB
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO
    pg_catalog,
    telemetry
AS $procedure$

DECLARE
    v_lookback INTERVAL :=
        INTERVAL '8 days';

    v_to   TIMESTAMPTZ;
    v_from TIMESTAMPTZ;
BEGIN

    IF config ? 'lookback' THEN
        v_lookback :=
            (config ->> 'lookback')::INTERVAL;
    END IF;

    IF v_lookback <= INTERVAL '0 seconds' THEN
        RAISE EXCEPTION
            'environment daily lookback must be positive';
    END IF;

    v_to :=
        clock_timestamp();

    v_from :=
        v_to - v_lookback;

    PERFORM
        telemetry.refresh_environment_daily
        (
            v_from,
            v_to
        );

END;

$procedure$;


SELECT add_job
(
    'telemetry.run_environment_daily_job',
    INTERVAL '1 hour',
    config => '{"lookback":"8 days"}'::JSONB
);


-- ============================================================================
-- LIFECYCLE
-- ============================================================================

ALTER TABLE telemetry.environment_daily
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
    'telemetry.environment_daily',
    INTERVAL '90 days'
);

-- Intentionally no retention policy.
-- Daily environmental history is the durable low-resolution layer.


COMMIT;
