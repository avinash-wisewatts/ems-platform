-- ============================================================================
-- File:
--   80_semantic_energy_consumption.sql
--
-- Epic:
--   Epic 4 — Core Energy Analytics
--
-- Story:
--   4.1 — Formalize import/export register semantics
--
-- Purpose:
--   Calculate import/export interval consumption using profile-level register
--   semantics rather than global assumptions.
--
-- Existing public column contracts are preserved so downstream asset,
-- daily, monthly and Grafana views remain compatible.
--
-- Quality classifications:
--
--   INITIAL:
--       No previous register exists.
--
--   MISSING_REGISTER:
--       Current register is absent.
--
--   CONFIG_MISSING:
--       The device profile has no active semantics for this register.
--
--   GOOD:
--       Valid progression within the configured plausibility ceiling.
--
--   GAP:
--       Valid cumulative-register delta across a gap over 30 minutes.
--       Story 4.2 will replace this fixed threshold with configurable rules.
--
--   ROLLOVER:
--       A valid FIXED_MODULUS rollover was resolved.
--
--   RESET_FROM_ZERO:
--       A decrease was accepted using reset_behavior = ACCEPT_FROM_ZERO.
--
--   RESET:
--       A decrease was rejected using reset_behavior = REJECT_DELTA or
--       FLAG_ONLY.
--
--   DIRECTION_ERROR:
--       Counter movement conflicts with the configured direction.
--
--   ROLLOVER_UNRESOLVED:
--       DEVICE_DEFINED rollover was declared without a database-resolvable
--       modulus.
--
--   IMPLAUSIBLE_DELTA:
--       Calculated delta exceeds expected_max_interval_delta.
-- ============================================================================


CREATE OR REPLACE VIEW analytics.v_energy_consumption_15min
WITH
(
    security_barrier = TRUE
)
AS

WITH ordered_registers AS
(
    SELECT
        gom.grafana_org_id,

        ca.bucket_start,
        ca.organization_id,
        ca.site_id,
        ca.device_id,

        d.profile_id,

        ca.sample_count,

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
        ) AS previous_export_register_wh,

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

    FROM metadata.grafana_organization_map gom

    JOIN telemetry.ca_energy_15min ca
      ON ca.organization_id = gom.organization_id

    JOIN metadata.devices d
      ON d.id = ca.device_id

    LEFT JOIN config.energy_register_semantics import_sem
      ON import_sem.profile_id = d.profile_id
     AND import_sem.flow_interpretation = 'GRID_IMPORT'
     AND import_sem.is_active = TRUE

    LEFT JOIN config.energy_register_semantics export_sem
      ON export_sem.profile_id = d.profile_id
     AND export_sem.flow_interpretation = 'GRID_EXPORT'
     AND export_sem.is_active = TRUE

    WHERE gom.is_active = TRUE
),

raw_calculation AS
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

        -- --------------------------------------------------------------------
        -- Import candidate delta before plausibility classification.
        -- --------------------------------------------------------------------

        CASE
            WHEN previous_import_register_wh IS NULL
              OR import_register_wh IS NULL
              OR import_counter_direction IS NULL
                THEN NULL

            WHEN import_counter_direction = 'INCREASING'
             AND import_register_wh >= previous_import_register_wh
                THEN import_register_wh - previous_import_register_wh

            WHEN import_counter_direction = 'DECREASING'
             AND import_register_wh <= previous_import_register_wh
                THEN previous_import_register_wh - import_register_wh

            WHEN import_counter_direction = 'BIDIRECTIONAL'
                THEN ABS
                (
                    import_register_wh -
                    previous_import_register_wh
                )

            WHEN import_counter_direction = 'INCREASING'
             AND import_register_wh < previous_import_register_wh
             AND import_rollover_behavior = 'FIXED_MODULUS'
                THEN
                    import_rollover_value
                    -
                    previous_import_register_wh
                    +
                    import_register_wh

            WHEN import_counter_direction = 'INCREASING'
             AND import_register_wh < previous_import_register_wh
             AND import_rollover_behavior = 'NONE'
             AND import_reset_behavior = 'ACCEPT_FROM_ZERO'
                THEN import_register_wh

            ELSE NULL
        END AS import_candidate_delta_wh,

        -- --------------------------------------------------------------------
        -- Export candidate delta before plausibility classification.
        -- --------------------------------------------------------------------

        CASE
            WHEN previous_export_register_wh IS NULL
              OR export_register_wh IS NULL
              OR export_counter_direction IS NULL
                THEN NULL

            WHEN export_counter_direction = 'INCREASING'
             AND export_register_wh >= previous_export_register_wh
                THEN export_register_wh - previous_export_register_wh

            WHEN export_counter_direction = 'DECREASING'
             AND export_register_wh <= previous_export_register_wh
                THEN previous_export_register_wh - export_register_wh

            WHEN export_counter_direction = 'BIDIRECTIONAL'
                THEN ABS
                (
                    export_register_wh -
                    previous_export_register_wh
                )

            WHEN export_counter_direction = 'INCREASING'
             AND export_register_wh < previous_export_register_wh
             AND export_rollover_behavior = 'FIXED_MODULUS'
                THEN
                    export_rollover_value
                    -
                    previous_export_register_wh
                    +
                    export_register_wh

            WHEN export_counter_direction = 'INCREASING'
             AND export_register_wh < previous_export_register_wh
             AND export_rollover_behavior = 'NONE'
             AND export_reset_behavior = 'ACCEPT_FROM_ZERO'
                THEN export_register_wh

            ELSE NULL
        END AS export_candidate_delta_wh

    FROM ordered_registers
),

classified AS
(
    SELECT
        raw_calculation.*,

        -- --------------------------------------------------------------------
        -- Import quality classification.
        -- --------------------------------------------------------------------

        CASE
            WHEN previous_import_register_wh IS NULL
                THEN 'INITIAL'

            WHEN import_register_wh IS NULL
                THEN 'MISSING_REGISTER'

            WHEN import_counter_direction IS NULL
                THEN 'CONFIG_MISSING'

            WHEN import_counter_direction = 'INCREASING'
             AND import_register_wh < previous_import_register_wh
             AND import_rollover_behavior = 'DEVICE_DEFINED'
                THEN 'ROLLOVER_UNRESOLVED'

            WHEN import_counter_direction = 'INCREASING'
             AND import_register_wh < previous_import_register_wh
             AND import_rollover_behavior = 'FIXED_MODULUS'
             AND import_candidate_delta_wh >
                 import_expected_max_delta_wh
                THEN 'IMPLAUSIBLE_DELTA'

            WHEN import_counter_direction = 'INCREASING'
             AND import_register_wh < previous_import_register_wh
             AND import_rollover_behavior = 'FIXED_MODULUS'
                THEN 'ROLLOVER'

            WHEN import_counter_direction = 'INCREASING'
             AND import_register_wh < previous_import_register_wh
             AND import_rollover_behavior = 'NONE'
             AND import_reset_behavior = 'ACCEPT_FROM_ZERO'
             AND import_candidate_delta_wh >
                 import_expected_max_delta_wh
                THEN 'IMPLAUSIBLE_DELTA'

            WHEN import_counter_direction = 'INCREASING'
             AND import_register_wh < previous_import_register_wh
             AND import_rollover_behavior = 'NONE'
             AND import_reset_behavior = 'ACCEPT_FROM_ZERO'
                THEN 'RESET_FROM_ZERO'

            WHEN import_counter_direction = 'INCREASING'
             AND import_register_wh < previous_import_register_wh
                THEN 'RESET'

            WHEN import_counter_direction = 'DECREASING'
             AND import_register_wh > previous_import_register_wh
                THEN 'DIRECTION_ERROR'

            WHEN import_candidate_delta_wh >
                 import_expected_max_delta_wh
                THEN 'IMPLAUSIBLE_DELTA'

            WHEN bucket_start - previous_bucket_start >
                 INTERVAL '30 minutes'
                THEN 'GAP'

            ELSE 'GOOD'
        END AS import_quality_code,

        -- --------------------------------------------------------------------
        -- Export quality classification.
        -- --------------------------------------------------------------------

        CASE
            WHEN previous_export_register_wh IS NULL
                THEN 'INITIAL'

            WHEN export_register_wh IS NULL
                THEN 'MISSING_REGISTER'

            WHEN export_counter_direction IS NULL
                THEN 'CONFIG_MISSING'

            WHEN export_counter_direction = 'INCREASING'
             AND export_register_wh < previous_export_register_wh
             AND export_rollover_behavior = 'DEVICE_DEFINED'
                THEN 'ROLLOVER_UNRESOLVED'

            WHEN export_counter_direction = 'INCREASING'
             AND export_register_wh < previous_export_register_wh
             AND export_rollover_behavior = 'FIXED_MODULUS'
             AND export_candidate_delta_wh >
                 export_expected_max_delta_wh
                THEN 'IMPLAUSIBLE_DELTA'

            WHEN export_counter_direction = 'INCREASING'
             AND export_register_wh < previous_export_register_wh
             AND export_rollover_behavior = 'FIXED_MODULUS'
                THEN 'ROLLOVER'

            WHEN export_counter_direction = 'INCREASING'
             AND export_register_wh < previous_export_register_wh
             AND export_rollover_behavior = 'NONE'
             AND export_reset_behavior = 'ACCEPT_FROM_ZERO'
             AND export_candidate_delta_wh >
                 export_expected_max_delta_wh
                THEN 'IMPLAUSIBLE_DELTA'

            WHEN export_counter_direction = 'INCREASING'
             AND export_register_wh < previous_export_register_wh
             AND export_rollover_behavior = 'NONE'
             AND export_reset_behavior = 'ACCEPT_FROM_ZERO'
                THEN 'RESET_FROM_ZERO'

            WHEN export_counter_direction = 'INCREASING'
             AND export_register_wh < previous_export_register_wh
                THEN 'RESET'

            WHEN export_counter_direction = 'DECREASING'
             AND export_register_wh > previous_export_register_wh
                THEN 'DIRECTION_ERROR'

            WHEN export_candidate_delta_wh >
                 export_expected_max_delta_wh
                THEN 'IMPLAUSIBLE_DELTA'

            WHEN bucket_start - previous_bucket_start >
                 INTERVAL '30 minutes'
                THEN 'GAP'

            ELSE 'GOOD'
        END AS export_quality_code

    FROM raw_calculation
)

SELECT
    c.grafana_org_id,

    c.bucket_start,
    c.previous_bucket_start,
    c.elapsed_minutes,

    c.organization_id,
    c.site_id,
    c.device_id,

    d.external_id,
    d.name AS device_name,

    c.sample_count,

    c.import_register_wh,
    c.previous_import_register_wh,

    CASE
        WHEN c.import_quality_code IN
        (
            'GOOD',
            'GAP',
            'ROLLOVER',
            'RESET_FROM_ZERO'
        )
            THEN c.import_candidate_delta_wh
        ELSE NULL
    END AS import_consumption_wh,

    CASE
        WHEN c.import_quality_code IN
        (
            'GOOD',
            'GAP',
            'ROLLOVER',
            'RESET_FROM_ZERO'
        )
            THEN c.import_candidate_delta_wh / 1000.0
        ELSE NULL
    END AS import_consumption_kwh,

    c.import_quality_code,

    c.export_register_wh,
    c.previous_export_register_wh,

    CASE
        WHEN c.export_quality_code IN
        (
            'GOOD',
            'GAP',
            'ROLLOVER',
            'RESET_FROM_ZERO'
        )
            THEN c.export_candidate_delta_wh
        ELSE NULL
    END AS export_consumption_wh,

    CASE
        WHEN c.export_quality_code IN
        (
            'GOOD',
            'GAP',
            'ROLLOVER',
            'RESET_FROM_ZERO'
        )
            THEN c.export_candidate_delta_wh / 1000.0
        ELSE NULL
    END AS export_consumption_kwh,

    c.export_quality_code,

    CASE
        WHEN c.import_quality_code IN ('RESET', 'RESET_FROM_ZERO')
          OR c.export_quality_code IN ('RESET', 'RESET_FROM_ZERO')
            THEN TRUE
        ELSE FALSE
    END AS reset_detected,

    CASE
        WHEN c.import_quality_code = 'GAP'
          OR c.export_quality_code = 'GAP'
            THEN TRUE
        ELSE FALSE
    END AS gap_detected

FROM classified c

JOIN metadata.devices d
  ON d.id = c.device_id;


COMMENT ON VIEW analytics.v_energy_consumption_15min IS
'Profile-semantic, rollover-aware, reset-aware and plausibility-qualified 15-minute import/export consumption.';


REVOKE ALL
ON analytics.v_energy_consumption_15min
FROM PUBLIC;


GRANT SELECT
ON analytics.v_energy_consumption_15min
TO grafana_reader;


-- ----------------------------------------------------------------------------
-- Update daily inclusion rules without changing the existing column contract.
-- ----------------------------------------------------------------------------

CREATE OR REPLACE VIEW analytics.v_energy_consumption_daily
WITH
(
    security_barrier = TRUE
)
AS
SELECT
    grafana_org_id,

    date_trunc(
        'day',
        bucket_start AT TIME ZONE 'Asia/Kolkata'
    )::DATE AS consumption_date,

    organization_id,
    site_id,
    device_id,

    external_id,
    device_name,

    SUM(import_consumption_kwh) FILTER
    (
        WHERE import_quality_code IN
        (
            'GOOD',
            'GAP',
            'ROLLOVER',
            'RESET_FROM_ZERO'
        )
    ) AS import_consumption_kwh,

    SUM(export_consumption_kwh) FILTER
    (
        WHERE export_quality_code IN
        (
            'GOOD',
            'GAP',
            'ROLLOVER',
            'RESET_FROM_ZERO'
        )
    ) AS export_consumption_kwh,

    COUNT(*) FILTER
    (
        WHERE import_quality_code IN
        (
            'GOOD',
            'GAP',
            'ROLLOVER',
            'RESET_FROM_ZERO'
        )
    ) AS valid_import_intervals,

    COUNT(*) FILTER
    (
        WHERE export_quality_code IN
        (
            'GOOD',
            'GAP',
            'ROLLOVER',
            'RESET_FROM_ZERO'
        )
    ) AS valid_export_intervals,

    COUNT(*) FILTER
    (
        WHERE import_quality_code IN ('RESET', 'RESET_FROM_ZERO')
           OR export_quality_code IN ('RESET', 'RESET_FROM_ZERO')
    ) AS reset_interval_count,

    COUNT(*) FILTER
    (
        WHERE import_quality_code = 'GAP'
           OR export_quality_code = 'GAP'
    ) AS gap_interval_count,

    MIN(bucket_start) AS first_bucket_start,
    MAX(bucket_start) AS last_bucket_start

FROM analytics.v_energy_consumption_15min

GROUP BY
    grafana_org_id,
    consumption_date,
    organization_id,
    site_id,
    device_id,
    external_id,
    device_name;


COMMENT ON VIEW analytics.v_energy_consumption_daily IS
'Daily semantic-aware import and export energy consumption by tenant, site and device.';


REVOKE ALL
ON analytics.v_energy_consumption_daily
FROM PUBLIC;


GRANT SELECT
ON analytics.v_energy_consumption_daily
TO grafana_reader;
