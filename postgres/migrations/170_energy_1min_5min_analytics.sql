-- ============================================================================
-- Canonical EMS energy analytics at 1-minute and 5-minute resolution.
--
-- Source:
--   telemetry.energy_measurements
--
-- Principles:
--   * Cumulative meter registers are represented by MIN/MAX, never SUM.
--   * Consumption is calculated between consecutive register snapshots.
--   * Existing profile semantics, reset handling, rollover handling and
--     effective-dated interval-quality rules are reused.
--   * Historical resolution eligibility is resolved for every bucket using
--     config.telemetry_capture_policies through
--     telemetry.resolve_site_capture_bucket().
--   * One-minute analytics require source capture <= 60 seconds.
--   * Five-minute analytics require source capture <= 300 seconds.
--
-- Lifecycle:
--   telemetry.ca_energy_1min
--     Refresh: every 1 minute
--     Compression: after 7 days
--     Retention: 180 days
--
--   telemetry.ca_energy_5min
--     Refresh: every 5 minutes
--     Compression: after 7 days
--     Retention: 2 years
-- ============================================================================



-- === ONE-MINUTE CONTINUOUS AGGREGATE ===

CREATE MATERIALIZED VIEW IF NOT EXISTS telemetry.ca_energy_1min
WITH
(
    timescaledb.continuous
)
AS

SELECT
    time_bucket
    (
        INTERVAL '1 minute',
        bucket_start
    ) AS bucket_start,

    organization_id,
    site_id,
    device_id,

    COUNT(*)::BIGINT AS sample_count,


    -- ------------------------------------------------------------------------
    -- Cumulative active-energy registers.
    -- ------------------------------------------------------------------------

    MAX(import_energy_total_wh)
        AS import_energy_total_wh_max,

    MIN(import_energy_total_wh)
        AS import_energy_total_wh_min,

    MAX(export_energy_total_wh)
        AS export_energy_total_wh_max,

    MIN(export_energy_total_wh)
        AS export_energy_total_wh_min,


    -- ------------------------------------------------------------------------
    -- Cumulative reactive/apparent-energy registers.
    -- ------------------------------------------------------------------------

    MAX(reactive_energy_total_varh)
        AS reactive_energy_total_varh_max,

    MIN(reactive_energy_total_varh)
        AS reactive_energy_total_varh_min,

    MAX(reactive_export_energy_total_varh)
        AS reactive_export_energy_total_varh_max,

    MIN(reactive_export_energy_total_varh)
        AS reactive_export_energy_total_varh_min,

    MAX(apparent_energy_total_vah)
        AS apparent_energy_total_vah_max,

    MIN(apparent_energy_total_vah)
        AS apparent_energy_total_vah_min,


    -- ------------------------------------------------------------------------
    -- Total active power.
    -- ------------------------------------------------------------------------

    AVG(active_power_total_w)
        AS active_power_total_w_avg,

    MIN(active_power_total_w)
        AS active_power_total_w_min,

    MAX(active_power_total_w)
        AS active_power_total_w_max,


    -- ------------------------------------------------------------------------
    -- Phase active power.
    -- ------------------------------------------------------------------------

    AVG(active_power_l1_w)
        AS active_power_l1_w_avg,

    AVG(active_power_l2_w)
        AS active_power_l2_w_avg,

    AVG(active_power_l3_w)
        AS active_power_l3_w_avg,


    -- ------------------------------------------------------------------------
    -- Reactive and apparent power.
    -- ------------------------------------------------------------------------

    AVG(reactive_power_total_var)
        AS reactive_power_total_var_avg,

    MIN(reactive_power_total_var)
        AS reactive_power_total_var_min,

    MAX(reactive_power_total_var)
        AS reactive_power_total_var_max,

    AVG(apparent_power_total_va)
        AS apparent_power_total_va_avg,

    MIN(apparent_power_total_va)
        AS apparent_power_total_va_min,

    MAX(apparent_power_total_va)
        AS apparent_power_total_va_max,


    -- ------------------------------------------------------------------------
    -- Voltage.
    -- ------------------------------------------------------------------------

    AVG(voltage_l1_v)
        AS voltage_l1_v_avg,

    MIN(voltage_l1_v)
        AS voltage_l1_v_min,

    MAX(voltage_l1_v)
        AS voltage_l1_v_max,

    AVG(voltage_l2_v)
        AS voltage_l2_v_avg,

    MIN(voltage_l2_v)
        AS voltage_l2_v_min,

    MAX(voltage_l2_v)
        AS voltage_l2_v_max,

    AVG(voltage_l3_v)
        AS voltage_l3_v_avg,

    MIN(voltage_l3_v)
        AS voltage_l3_v_min,

    MAX(voltage_l3_v)
        AS voltage_l3_v_max,


    -- ------------------------------------------------------------------------
    -- Current.
    -- ------------------------------------------------------------------------

    AVG(current_l1_a)
        AS current_l1_a_avg,

    MIN(current_l1_a)
        AS current_l1_a_min,

    MAX(current_l1_a)
        AS current_l1_a_max,

    AVG(current_l2_a)
        AS current_l2_a_avg,

    MIN(current_l2_a)
        AS current_l2_a_min,

    MAX(current_l2_a)
        AS current_l2_a_max,

    AVG(current_l3_a)
        AS current_l3_a_avg,

    MIN(current_l3_a)
        AS current_l3_a_min,

    MAX(current_l3_a)
        AS current_l3_a_max,


    -- ------------------------------------------------------------------------
    -- Power factor and frequency.
    -- ------------------------------------------------------------------------

    AVG(power_factor_total)
        AS power_factor_total_avg,

    MIN(power_factor_total)
        AS power_factor_total_min,

    MAX(power_factor_total)
        AS power_factor_total_max,

    AVG(frequency_hz)
        AS frequency_hz_avg,

    MIN(frequency_hz)
        AS frequency_hz_min,

    MAX(frequency_hz)
        AS frequency_hz_max,


    -- ------------------------------------------------------------------------
    -- Current THD.
    -- ------------------------------------------------------------------------

    AVG(current_thd_l1_percent)
        AS current_thd_l1_percent_avg,

    MAX(current_thd_l1_percent)
        AS current_thd_l1_percent_max,

    AVG(current_thd_l2_percent)
        AS current_thd_l2_percent_avg,

    MAX(current_thd_l2_percent)
        AS current_thd_l2_percent_max,

    AVG(current_thd_l3_percent)
        AS current_thd_l3_percent_avg,

    MAX(current_thd_l3_percent)
        AS current_thd_l3_percent_max,


    -- ------------------------------------------------------------------------
    -- Data availability.
    -- ------------------------------------------------------------------------

    COUNT(active_power_total_w)::BIGINT
        AS active_power_sample_count,

    COUNT(import_energy_total_wh)::BIGINT
        AS import_energy_sample_count,

    COUNT(voltage_l1_v)::BIGINT
        AS voltage_l1_sample_count,

    COUNT(current_l1_a)::BIGINT
        AS current_l1_sample_count

FROM telemetry.energy_measurements

GROUP BY
    time_bucket
    (
        INTERVAL '1 minute',
        bucket_start
    ),
    organization_id,
    site_id,
    device_id

WITH NO DATA;

SELECT add_continuous_aggregate_policy
(
    'telemetry.ca_energy_1min'::REGCLASS,
    start_offset      => INTERVAL '2 days',
    end_offset        => INTERVAL '1 minute',
    schedule_interval => INTERVAL '1 minute',
    if_not_exists     => TRUE
);

ALTER MATERIALIZED VIEW telemetry.ca_energy_1min
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
    'telemetry.ca_energy_1min'::REGCLASS,
    compress_after    => INTERVAL '7 days',
    if_not_exists     => TRUE,
    schedule_interval => INTERVAL '1 day',
    timezone          => 'Asia/Kolkata'
);

SELECT add_retention_policy
(
    'telemetry.ca_energy_1min'::REGCLASS,
    drop_after        => INTERVAL '180 days',
    if_not_exists     => TRUE,
    schedule_interval => INTERVAL '1 day',
    timezone          => 'Asia/Kolkata'
);



-- === FIVE-MINUTE CONTINUOUS AGGREGATE ===

CREATE MATERIALIZED VIEW IF NOT EXISTS telemetry.ca_energy_5min
WITH
(
    timescaledb.continuous
)
AS

SELECT
    time_bucket
    (
        INTERVAL '5 minutes',
        bucket_start
    ) AS bucket_start,

    organization_id,
    site_id,
    device_id,

    COUNT(*)::BIGINT AS sample_count,


    -- ------------------------------------------------------------------------
    -- Cumulative active-energy registers.
    -- ------------------------------------------------------------------------

    MAX(import_energy_total_wh)
        AS import_energy_total_wh_max,

    MIN(import_energy_total_wh)
        AS import_energy_total_wh_min,

    MAX(export_energy_total_wh)
        AS export_energy_total_wh_max,

    MIN(export_energy_total_wh)
        AS export_energy_total_wh_min,


    -- ------------------------------------------------------------------------
    -- Cumulative reactive/apparent-energy registers.
    -- ------------------------------------------------------------------------

    MAX(reactive_energy_total_varh)
        AS reactive_energy_total_varh_max,

    MIN(reactive_energy_total_varh)
        AS reactive_energy_total_varh_min,

    MAX(reactive_export_energy_total_varh)
        AS reactive_export_energy_total_varh_max,

    MIN(reactive_export_energy_total_varh)
        AS reactive_export_energy_total_varh_min,

    MAX(apparent_energy_total_vah)
        AS apparent_energy_total_vah_max,

    MIN(apparent_energy_total_vah)
        AS apparent_energy_total_vah_min,


    -- ------------------------------------------------------------------------
    -- Total active power.
    -- ------------------------------------------------------------------------

    AVG(active_power_total_w)
        AS active_power_total_w_avg,

    MIN(active_power_total_w)
        AS active_power_total_w_min,

    MAX(active_power_total_w)
        AS active_power_total_w_max,


    -- ------------------------------------------------------------------------
    -- Phase active power.
    -- ------------------------------------------------------------------------

    AVG(active_power_l1_w)
        AS active_power_l1_w_avg,

    AVG(active_power_l2_w)
        AS active_power_l2_w_avg,

    AVG(active_power_l3_w)
        AS active_power_l3_w_avg,


    -- ------------------------------------------------------------------------
    -- Reactive and apparent power.
    -- ------------------------------------------------------------------------

    AVG(reactive_power_total_var)
        AS reactive_power_total_var_avg,

    MIN(reactive_power_total_var)
        AS reactive_power_total_var_min,

    MAX(reactive_power_total_var)
        AS reactive_power_total_var_max,

    AVG(apparent_power_total_va)
        AS apparent_power_total_va_avg,

    MIN(apparent_power_total_va)
        AS apparent_power_total_va_min,

    MAX(apparent_power_total_va)
        AS apparent_power_total_va_max,


    -- ------------------------------------------------------------------------
    -- Voltage.
    -- ------------------------------------------------------------------------

    AVG(voltage_l1_v)
        AS voltage_l1_v_avg,

    MIN(voltage_l1_v)
        AS voltage_l1_v_min,

    MAX(voltage_l1_v)
        AS voltage_l1_v_max,

    AVG(voltage_l2_v)
        AS voltage_l2_v_avg,

    MIN(voltage_l2_v)
        AS voltage_l2_v_min,

    MAX(voltage_l2_v)
        AS voltage_l2_v_max,

    AVG(voltage_l3_v)
        AS voltage_l3_v_avg,

    MIN(voltage_l3_v)
        AS voltage_l3_v_min,

    MAX(voltage_l3_v)
        AS voltage_l3_v_max,


    -- ------------------------------------------------------------------------
    -- Current.
    -- ------------------------------------------------------------------------

    AVG(current_l1_a)
        AS current_l1_a_avg,

    MIN(current_l1_a)
        AS current_l1_a_min,

    MAX(current_l1_a)
        AS current_l1_a_max,

    AVG(current_l2_a)
        AS current_l2_a_avg,

    MIN(current_l2_a)
        AS current_l2_a_min,

    MAX(current_l2_a)
        AS current_l2_a_max,

    AVG(current_l3_a)
        AS current_l3_a_avg,

    MIN(current_l3_a)
        AS current_l3_a_min,

    MAX(current_l3_a)
        AS current_l3_a_max,


    -- ------------------------------------------------------------------------
    -- Power factor and frequency.
    -- ------------------------------------------------------------------------

    AVG(power_factor_total)
        AS power_factor_total_avg,

    MIN(power_factor_total)
        AS power_factor_total_min,

    MAX(power_factor_total)
        AS power_factor_total_max,

    AVG(frequency_hz)
        AS frequency_hz_avg,

    MIN(frequency_hz)
        AS frequency_hz_min,

    MAX(frequency_hz)
        AS frequency_hz_max,


    -- ------------------------------------------------------------------------
    -- Current THD.
    -- ------------------------------------------------------------------------

    AVG(current_thd_l1_percent)
        AS current_thd_l1_percent_avg,

    MAX(current_thd_l1_percent)
        AS current_thd_l1_percent_max,

    AVG(current_thd_l2_percent)
        AS current_thd_l2_percent_avg,

    MAX(current_thd_l2_percent)
        AS current_thd_l2_percent_max,

    AVG(current_thd_l3_percent)
        AS current_thd_l3_percent_avg,

    MAX(current_thd_l3_percent)
        AS current_thd_l3_percent_max,


    -- ------------------------------------------------------------------------
    -- Data availability.
    -- ------------------------------------------------------------------------

    COUNT(active_power_total_w)::BIGINT
        AS active_power_sample_count,

    COUNT(import_energy_total_wh)::BIGINT
        AS import_energy_sample_count,

    COUNT(voltage_l1_v)::BIGINT
        AS voltage_l1_sample_count,

    COUNT(current_l1_a)::BIGINT
        AS current_l1_sample_count

FROM telemetry.energy_measurements

GROUP BY
    time_bucket
    (
        INTERVAL '5 minutes',
        bucket_start
    ),
    organization_id,
    site_id,
    device_id

WITH NO DATA;

SELECT add_continuous_aggregate_policy
(
    'telemetry.ca_energy_5min'::REGCLASS,
    start_offset      => INTERVAL '7 days',
    end_offset        => INTERVAL '1 minute',
    schedule_interval => INTERVAL '5 minutes',
    if_not_exists     => TRUE
);

ALTER MATERIALIZED VIEW telemetry.ca_energy_5min
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
    'telemetry.ca_energy_5min'::REGCLASS,
    compress_after    => INTERVAL '7 days',
    if_not_exists     => TRUE,
    schedule_interval => INTERVAL '1 day',
    timezone          => 'Asia/Kolkata'
);

SELECT add_retention_policy
(
    'telemetry.ca_energy_5min'::REGCLASS,
    drop_after        => INTERVAL '2 years',
    if_not_exists     => TRUE,
    schedule_interval => INTERVAL '1 day',
    timezone          => 'Asia/Kolkata'
);



-- === ONE-MINUTE CONSUMPTION VIEW ===

CREATE OR REPLACE VIEW analytics.v_energy_consumption_1min
WITH
(
    security_barrier = TRUE
)
AS

WITH eligible_buckets AS
(
    SELECT
        ca.*
    FROM telemetry.ca_energy_1min ca

    CROSS JOIN LATERAL
    telemetry.resolve_site_capture_bucket
    (
        ca.site_id,
        ca.bucket_start
    ) capture_policy

    WHERE
        capture_policy.policy_id IS NOT NULL
        AND capture_policy.capture_interval_seconds
            <= 60
),

ordered_registers AS
(
    SELECT
        gom.grafana_org_id,

        ca.bucket_start,
        ca.organization_id,
        ca.site_id,
        ca.device_id,

        ca.sample_count,

        d.profile_id,
        d.external_id,
        d.name AS device_name,

        ca.import_energy_total_wh_max
            AS import_register_wh,

        ca.export_energy_total_wh_max
            AS export_register_wh,

        LAG(ca.bucket_start) OVER
        (
            PARTITION BY
                gom.grafana_org_id,
                ca.organization_id,
                ca.site_id,
                ca.device_id
            ORDER BY ca.bucket_start
        ) AS previous_bucket_start,

        LAG(ca.import_energy_total_wh_max) OVER
        (
            PARTITION BY
                gom.grafana_org_id,
                ca.organization_id,
                ca.site_id,
                ca.device_id
            ORDER BY ca.bucket_start
        ) AS previous_import_register_wh,

        LAG(ca.export_energy_total_wh_max) OVER
        (
            PARTITION BY
                gom.grafana_org_id,
                ca.organization_id,
                ca.site_id,
                ca.device_id
            ORDER BY ca.bucket_start
        ) AS previous_export_register_wh

    FROM eligible_buckets ca

    JOIN metadata.grafana_organization_map gom
      ON gom.organization_id = ca.organization_id
     AND gom.is_active = TRUE

    JOIN metadata.devices d
      ON d.id = ca.device_id
),

semantic_context AS
(
    SELECT
        ordered_registers.*,

        EXTRACT
        (
            EPOCH FROM
            (
                bucket_start - previous_bucket_start
            )
        ) / 60.0 AS elapsed_minutes,

        import_sem.counter_direction
            AS import_counter_direction,

        import_sem.rollover_behavior
            AS import_rollover_behavior,

        import_sem.rollover_value
            AS import_rollover_value,

        import_sem.reset_behavior
            AS import_reset_behavior,

        import_sem.expected_max_interval_delta
            AS import_expected_max_delta_wh,

        export_sem.counter_direction
            AS export_counter_direction,

        export_sem.rollover_behavior
            AS export_rollover_behavior,

        export_sem.rollover_value
            AS export_rollover_value,

        export_sem.reset_behavior
            AS export_reset_behavior,

        export_sem.expected_max_interval_delta
            AS export_expected_max_delta_wh

    FROM ordered_registers

    LEFT JOIN config.energy_register_semantics import_sem
      ON import_sem.profile_id =
         ordered_registers.profile_id
     AND import_sem.flow_interpretation =
         'GRID_IMPORT'
     AND import_sem.is_active = TRUE

    LEFT JOIN config.energy_register_semantics export_sem
      ON export_sem.profile_id =
         ordered_registers.profile_id
     AND export_sem.flow_interpretation =
         'GRID_EXPORT'
     AND export_sem.is_active = TRUE
)

SELECT
    sc.grafana_org_id,

    sc.bucket_start,
    sc.previous_bucket_start,
    sc.elapsed_minutes,

    sc.organization_id,
    sc.site_id,
    sc.device_id,

    sc.external_id,
    sc.device_name,

    sc.sample_count,

    sc.import_register_wh,
    sc.previous_import_register_wh,

    import_result.delta_wh
        AS import_consumption_wh,

    import_result.delta_wh / 1000.0
        AS import_consumption_kwh,

    import_result.quality_code
        AS import_quality_code,

    sc.export_register_wh,
    sc.previous_export_register_wh,

    export_result.delta_wh
        AS export_consumption_wh,

    export_result.delta_wh / 1000.0
        AS export_consumption_kwh,

    export_result.quality_code
        AS export_quality_code,

    (
        import_result.reset_detected
        OR export_result.reset_detected
    ) AS reset_detected,

    (
        import_result.quality_code = 'GAP'
        OR export_result.quality_code = 'GAP'
    ) AS gap_detected

FROM semantic_context sc

-- Resolve the rule at the bucket timestamp so historical analytics use the
-- configuration that was effective when the interval occurred.
CROSS JOIN LATERAL
config.resolve_interval_quality_rule
(
    sc.device_id,
    sc.bucket_start
) interval_rule

CROSS JOIN LATERAL
analytics.classify_energy_register_delta
(
    sc.import_register_wh,
    sc.previous_import_register_wh,
    sc.elapsed_minutes,
    sc.import_counter_direction,
    sc.import_rollover_behavior,
    sc.import_rollover_value,
    sc.import_reset_behavior,
    sc.import_expected_max_delta_wh,
    interval_rule.gap_threshold_minutes
) import_result

CROSS JOIN LATERAL
analytics.classify_energy_register_delta
(
    sc.export_register_wh,
    sc.previous_export_register_wh,
    sc.elapsed_minutes,
    sc.export_counter_direction,
    sc.export_rollover_behavior,
    sc.export_rollover_value,
    sc.export_reset_behavior,
    sc.export_expected_max_delta_wh,
    interval_rule.gap_threshold_minutes
) export_result;


COMMENT ON VIEW analytics.v_energy_consumption_1min IS
'Profile-semantic 1-minute import/export consumption using effective-dated hierarchical interval-quality rules and the authoritative register classifier.';


REVOKE ALL
ON analytics.v_energy_consumption_1min
FROM PUBLIC;


GRANT SELECT
ON analytics.v_energy_consumption_1min
TO grafana_reader;


-- === FIVE-MINUTE CONSUMPTION VIEW ===

CREATE OR REPLACE VIEW analytics.v_energy_consumption_5min
WITH
(
    security_barrier = TRUE
)
AS

WITH eligible_buckets AS
(
    SELECT
        ca.*
    FROM telemetry.ca_energy_5min ca

    CROSS JOIN LATERAL
    telemetry.resolve_site_capture_bucket
    (
        ca.site_id,
        ca.bucket_start
    ) capture_policy

    WHERE
        capture_policy.policy_id IS NOT NULL
        AND capture_policy.capture_interval_seconds
            <= 300
),

ordered_registers AS
(
    SELECT
        gom.grafana_org_id,

        ca.bucket_start,
        ca.organization_id,
        ca.site_id,
        ca.device_id,

        ca.sample_count,

        d.profile_id,
        d.external_id,
        d.name AS device_name,

        ca.import_energy_total_wh_max
            AS import_register_wh,

        ca.export_energy_total_wh_max
            AS export_register_wh,

        LAG(ca.bucket_start) OVER
        (
            PARTITION BY
                gom.grafana_org_id,
                ca.organization_id,
                ca.site_id,
                ca.device_id
            ORDER BY ca.bucket_start
        ) AS previous_bucket_start,

        LAG(ca.import_energy_total_wh_max) OVER
        (
            PARTITION BY
                gom.grafana_org_id,
                ca.organization_id,
                ca.site_id,
                ca.device_id
            ORDER BY ca.bucket_start
        ) AS previous_import_register_wh,

        LAG(ca.export_energy_total_wh_max) OVER
        (
            PARTITION BY
                gom.grafana_org_id,
                ca.organization_id,
                ca.site_id,
                ca.device_id
            ORDER BY ca.bucket_start
        ) AS previous_export_register_wh

    FROM eligible_buckets ca

    JOIN metadata.grafana_organization_map gom
      ON gom.organization_id = ca.organization_id
     AND gom.is_active = TRUE

    JOIN metadata.devices d
      ON d.id = ca.device_id
),

semantic_context AS
(
    SELECT
        ordered_registers.*,

        EXTRACT
        (
            EPOCH FROM
            (
                bucket_start - previous_bucket_start
            )
        ) / 60.0 AS elapsed_minutes,

        import_sem.counter_direction
            AS import_counter_direction,

        import_sem.rollover_behavior
            AS import_rollover_behavior,

        import_sem.rollover_value
            AS import_rollover_value,

        import_sem.reset_behavior
            AS import_reset_behavior,

        import_sem.expected_max_interval_delta
            AS import_expected_max_delta_wh,

        export_sem.counter_direction
            AS export_counter_direction,

        export_sem.rollover_behavior
            AS export_rollover_behavior,

        export_sem.rollover_value
            AS export_rollover_value,

        export_sem.reset_behavior
            AS export_reset_behavior,

        export_sem.expected_max_interval_delta
            AS export_expected_max_delta_wh

    FROM ordered_registers

    LEFT JOIN config.energy_register_semantics import_sem
      ON import_sem.profile_id =
         ordered_registers.profile_id
     AND import_sem.flow_interpretation =
         'GRID_IMPORT'
     AND import_sem.is_active = TRUE

    LEFT JOIN config.energy_register_semantics export_sem
      ON export_sem.profile_id =
         ordered_registers.profile_id
     AND export_sem.flow_interpretation =
         'GRID_EXPORT'
     AND export_sem.is_active = TRUE
)

SELECT
    sc.grafana_org_id,

    sc.bucket_start,
    sc.previous_bucket_start,
    sc.elapsed_minutes,

    sc.organization_id,
    sc.site_id,
    sc.device_id,

    sc.external_id,
    sc.device_name,

    sc.sample_count,

    sc.import_register_wh,
    sc.previous_import_register_wh,

    import_result.delta_wh
        AS import_consumption_wh,

    import_result.delta_wh / 1000.0
        AS import_consumption_kwh,

    import_result.quality_code
        AS import_quality_code,

    sc.export_register_wh,
    sc.previous_export_register_wh,

    export_result.delta_wh
        AS export_consumption_wh,

    export_result.delta_wh / 1000.0
        AS export_consumption_kwh,

    export_result.quality_code
        AS export_quality_code,

    (
        import_result.reset_detected
        OR export_result.reset_detected
    ) AS reset_detected,

    (
        import_result.quality_code = 'GAP'
        OR export_result.quality_code = 'GAP'
    ) AS gap_detected

FROM semantic_context sc

-- Resolve the rule at the bucket timestamp so historical analytics use the
-- configuration that was effective when the interval occurred.
CROSS JOIN LATERAL
config.resolve_interval_quality_rule
(
    sc.device_id,
    sc.bucket_start
) interval_rule

CROSS JOIN LATERAL
analytics.classify_energy_register_delta
(
    sc.import_register_wh,
    sc.previous_import_register_wh,
    sc.elapsed_minutes,
    sc.import_counter_direction,
    sc.import_rollover_behavior,
    sc.import_rollover_value,
    sc.import_reset_behavior,
    sc.import_expected_max_delta_wh,
    interval_rule.gap_threshold_minutes
) import_result

CROSS JOIN LATERAL
analytics.classify_energy_register_delta
(
    sc.export_register_wh,
    sc.previous_export_register_wh,
    sc.elapsed_minutes,
    sc.export_counter_direction,
    sc.export_rollover_behavior,
    sc.export_rollover_value,
    sc.export_reset_behavior,
    sc.export_expected_max_delta_wh,
    interval_rule.gap_threshold_minutes
) export_result;


COMMENT ON VIEW analytics.v_energy_consumption_5min IS
'Profile-semantic 5-minute import/export consumption using effective-dated hierarchical interval-quality rules and the authoritative register classifier.';


REVOKE ALL
ON analytics.v_energy_consumption_5min
FROM PUBLIC;


GRANT SELECT
ON analytics.v_energy_consumption_5min
TO grafana_reader;
