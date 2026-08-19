-- ============================================================================
-- Migration 030
-- Correct five-minute total-register semantic binding
--
-- The five-minute consumption compatibility view previously joined active
-- GRID_IMPORT / GRID_EXPORT semantics only by profile and flow. Profiles may
-- legitimately define phase-specific and TOTAL register semantics, so that
-- join could multiply rows.
--
-- Bind the five-minute consumption view explicitly to the canonical TOTAL
-- import/export logical points. No reporting architecture or Grafana read
-- contract is changed here.
-- ============================================================================

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
     AND import_sem.logical_point_id =
         (
             SELECT lp.id
             FROM metadata.logical_points lp
             WHERE lp.name = 'ENERGY_IMPORT_TOTAL'
             LIMIT 1
         )
     AND import_sem.is_active = TRUE

    LEFT JOIN config.energy_register_semantics export_sem
      ON export_sem.profile_id =
         ordered_registers.profile_id
     AND export_sem.flow_interpretation =
         'GRID_EXPORT'
     AND export_sem.logical_point_id =
         (
             SELECT lp.id
             FROM metadata.logical_points lp
             WHERE lp.name = 'ENERGY_EXPORT_TOTAL'
             LIMIT 1
         )
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
