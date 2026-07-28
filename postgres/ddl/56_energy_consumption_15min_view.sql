-- ============================================================================
-- File:
--   56_energy_consumption_15min_view.sql
--
-- Purpose:
--   Derive interval energy consumption from cumulative meter registers.
--
-- Source:
--   telemetry.ca_energy_15min
--
-- Calculation:
--
--   interval consumption =
--       current cumulative register
--       -
--       previous cumulative register
--
-- Reliability protections:
--
--   INITIAL:
--     No previous register exists. Consumption is NULL.
--
--   RESET:
--     Current register is lower than the previous register. This may indicate
--     meter reset, rollover, replacement, reconfiguration or bad source data.
--     Consumption is NULL rather than creating a negative value.
--
--   GAP:
--     More than 30 minutes elapsed between buckets. The register delta is still
--     preserved because cumulative meters capture energy across the gap, but
--     consumers can distinguish it from a normal 15-minute interval.
--
--   GOOD:
--     Normal non-negative register progression with no large time gap.
--
-- Units:
--
--   Source aggregate registers are stored in Wh.
--   Grafana-facing consumption fields are exposed in both Wh and kWh.
--
-- Multi-tenancy:
--
--   Every row includes grafana_org_id and must be filtered in Grafana using:
--
--       WHERE grafana_org_id = ${__org.id}
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
        ) AS previous_export_register_wh

    FROM metadata.grafana_organization_map gom

    JOIN telemetry.ca_energy_15min ca
      ON ca.organization_id = gom.organization_id

    WHERE gom.is_active = TRUE
),

classified AS
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

        CASE
            WHEN previous_import_register_wh IS NULL
                THEN NULL

            WHEN import_register_wh IS NULL
                THEN NULL

            WHEN import_register_wh < previous_import_register_wh
                THEN NULL

            ELSE
                import_register_wh - previous_import_register_wh
        END AS import_consumption_wh,

        CASE
            WHEN previous_export_register_wh IS NULL
                THEN NULL

            WHEN export_register_wh IS NULL
                THEN NULL

            WHEN export_register_wh < previous_export_register_wh
                THEN NULL

            ELSE
                export_register_wh - previous_export_register_wh
        END AS export_consumption_wh,

        CASE
            WHEN previous_import_register_wh IS NULL
                THEN 'INITIAL'

            WHEN import_register_wh IS NULL
                THEN 'MISSING_REGISTER'

            WHEN import_register_wh < previous_import_register_wh
                THEN 'RESET'

            WHEN bucket_start - previous_bucket_start >
                 INTERVAL '30 minutes'
                THEN 'GAP'

            ELSE 'GOOD'
        END AS import_quality_code,

        CASE
            WHEN previous_export_register_wh IS NULL
                THEN 'INITIAL'

            WHEN export_register_wh IS NULL
                THEN 'MISSING_REGISTER'

            WHEN export_register_wh < previous_export_register_wh
                THEN 'RESET'

            WHEN bucket_start - previous_bucket_start >
                 INTERVAL '30 minutes'
                THEN 'GAP'

            ELSE 'GOOD'
        END AS export_quality_code

    FROM ordered_registers
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

    c.import_consumption_wh,
    c.import_consumption_wh / 1000.0
        AS import_consumption_kwh,

    c.import_quality_code,

    c.export_register_wh,
    c.previous_export_register_wh,

    c.export_consumption_wh,
    c.export_consumption_wh / 1000.0
        AS export_consumption_kwh,

    c.export_quality_code,

    CASE
        WHEN c.import_quality_code = 'RESET'
          OR c.export_quality_code = 'RESET'
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
'Reset-aware and gap-aware 15-minute import/export consumption derived from cumulative energy registers.';


-- Grafana receives access only through the approved analytics schema.
REVOKE ALL ON analytics.v_energy_consumption_15min FROM PUBLIC;

GRANT SELECT
ON analytics.v_energy_consumption_15min
TO grafana_reader;
