BEGIN;

CREATE OR REPLACE VIEW analytics.v_grafana_telemetry_capture_policies
WITH (security_barrier = true)
AS
SELECT
    gom.grafana_org_id,
    s.organization_id,
    p.site_id,
    p.capture_interval_seconds,
    p.effective_from,
    p.effective_to
FROM metadata.grafana_organization_map gom
JOIN metadata.sites s
  ON s.organization_id = gom.organization_id
JOIN config.telemetry_capture_policies p
  ON p.site_id = s.id
WHERE gom.is_active = true
  AND p.is_enabled = true;

COMMENT ON VIEW analytics.v_grafana_telemetry_capture_policies IS
'Tenant-safe Grafana contract exposing effective telemetry capture intervals by site. '
'Used for presentation-layer gap detection without granting Grafana direct access to config schema.';

ALTER VIEW analytics.v_grafana_telemetry_capture_policies
OWNER TO ems_admin;

REVOKE ALL
ON analytics.v_grafana_telemetry_capture_policies
FROM PUBLIC;

GRANT SELECT
ON analytics.v_grafana_telemetry_capture_policies
TO grafana_reader;

COMMIT;
