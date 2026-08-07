-- Story 14.4: tenant-safe operational reconciliation queue.

CREATE OR REPLACE FUNCTION admin.list_accessible_reconciliation_queue(
    p_actor_portal_user_id BIGINT,
    p_organization_id UUID DEFAULT NULL,
    p_site_id UUID DEFAULT NULL,
    p_issue_type TEXT DEFAULT NULL
)
RETURNS TABLE (
    issue_key TEXT,
    issue_type TEXT,
    severity TEXT,
    organization_id UUID,
    organization_name TEXT,
    site_id UUID,
    site_name TEXT,
    entity_type TEXT,
    entity_id UUID,
    entity_name TEXT,
    issue_status TEXT,
    issue_detail TEXT,
    action_path TEXT,
    action_label TEXT
)
LANGUAGE SQL
STABLE
SECURITY DEFINER
SET search_path TO pg_catalog, admin, metadata, analytics
AS $function$
WITH actor AS (
    SELECT pu.role_code, pu.organization_id
    FROM admin.portal_users pu
    WHERE pu.portal_user_id = p_actor_portal_user_id
      AND pu.is_active
),
coverage AS (
    SELECT
        'MISSING_PRIMARY_METER:' || c.asset_id::text AS issue_key,
        'MISSING_PRIMARY_METER'::text AS issue_type,
        'HIGH'::text AS severity,
        c.organization_id,
        o.name::text AS organization_name,
        c.site_id,
        c.site_name,
        'ASSET'::text AS entity_type,
        c.asset_id AS entity_id,
        c.asset_name AS entity_name,
        c.coverage_status AS issue_status,
        CASE
            WHEN c.coverage_status = 'MISSING_DIRECT_METER'
                THEN 'A qualifying PRIMARY_METER relationship is required.'
            ELSE format('%s required descendants remain unconfigured.', c.missing_required_descendant_count)
        END AS issue_detail,
        c.action_path,
        c.action_label
    FROM admin.list_accessible_asset_meter_coverage(p_actor_portal_user_id) c
    JOIN metadata.organizations o ON o.id = c.organization_id
    WHERE c.coverage_status IN ('MISSING_DIRECT_METER','MISSING_DESCENDANT_COVERAGE','PARTIALLY_CONFIGURED')
),
telemetry AS (
    SELECT
        t.telemetry_state || ':' || t.device_id::text AS issue_key,
        CASE WHEN t.telemetry_state = 'INVALID_PROFILE' THEN 'INVALID_PROFILE' ELSE 'UNMAPPED_TELEMETRY' END AS issue_type,
        CASE WHEN t.telemetry_state = 'INVALID_PROFILE' THEN 'HIGH' ELSE 'MEDIUM' END AS severity,
        t.organization_id,
        o.name::text AS organization_name,
        t.site_id,
        t.site_name,
        'DEVICE'::text AS entity_type,
        t.device_id AS entity_id,
        t.device_name AS entity_name,
        t.telemetry_state AS issue_status,
        CASE
            WHEN t.telemetry_state = 'INVALID_PROFILE' THEN t.profile_validation_result
            ELSE format('%s mapped points; %s required points.', t.mapped_point_count, t.required_point_count)
        END AS issue_detail,
        '/administration/devices'::text AS action_path,
        'Review device'::text AS action_label
    FROM admin.list_accessible_device_telemetry_availability(
        p_actor_portal_user_id, p_organization_id, p_site_id, NULL
    ) t
    JOIN metadata.organizations o ON o.id = t.organization_id
    WHERE t.telemetry_state IN ('INVALID_PROFILE','UNMAPPED')
),
unassigned AS (
    SELECT
        'UNASSIGNED_DEVICE:' || d.id::text AS issue_key,
        'UNASSIGNED_DEVICE'::text AS issue_type,
        'MEDIUM'::text AS severity,
        d.organization_id,
        o.name::text AS organization_name,
        g.site_id,
        s.name::text AS site_name,
        'DEVICE'::text AS entity_type,
        d.id AS entity_id,
        d.name::text AS entity_name,
        d.lifecycle_status::text AS issue_status,
        'The device has no active asset or site-energy assignment.'::text AS issue_detail,
        '/administration/relationships'::text AS action_path,
        'Assign device'::text AS action_label
    FROM metadata.devices d
    JOIN metadata.gateways g ON g.id = d.gateway_id
    JOIN metadata.sites s ON s.id = g.site_id
    JOIN metadata.organizations o ON o.id = d.organization_id
    WHERE d.lifecycle_status <> 'DECOMMISSIONED'
      AND admin.portal_user_can_access_site(p_actor_portal_user_id, g.site_id)
      AND NOT EXISTS (
          SELECT 1 FROM metadata.asset_devices ad
          WHERE ad.device_id = d.id
      )
      AND NOT EXISTS (
          SELECT 1 FROM config.site_energy_meter_roles semr
          WHERE semr.device_id = d.id AND semr.is_active
      )
),
locations AS (
    SELECT
        'INCOMPLETE_LOCATION:' || r.entity_type || ':' || r.entity_id::text AS issue_key,
        'INCOMPLETE_LOCATION'::text AS issue_type,
        'LOW'::text AS severity,
        r.organization_id,
        o.name::text AS organization_name,
        r.site_id,
        s.name::text AS site_name,
        r.entity_type,
        r.entity_id,
        r.entity_name,
        r.commissioning_status AS issue_status,
        'Commissioning reports a missing or invalid physical location.'::text AS issue_detail,
        CASE r.entity_type
            WHEN 'ASSET' THEN '/administration/assets'
            WHEN 'GATEWAY' THEN '/administration/gateways'
            ELSE '/administration/devices'
        END AS action_path,
        'Review location'::text AS action_label
    FROM admin.list_accessible_commissioning_readiness(p_actor_portal_user_id, NULL) r
    JOIN metadata.organizations o ON o.id = r.organization_id
    JOIN metadata.sites s ON s.id = r.site_id
    WHERE EXISTS (
        SELECT 1 FROM unnest(coalesce(r.blocking_reason_codes, ARRAY[]::text[]) || coalesce(r.warning_reason_codes, ARRAY[]::text[])) code
        WHERE code ILIKE '%LOCATION%'
    )
),
grafana AS (
    SELECT
        'FAILED_GRAFANA_PROVISIONING:' || o.id::text AS issue_key,
        'FAILED_GRAFANA_PROVISIONING'::text AS issue_type,
        'HIGH'::text AS severity,
        o.id AS organization_id,
        o.name::text AS organization_name,
        NULL::uuid AS site_id,
        NULL::text AS site_name,
        'ORGANIZATION'::text AS entity_type,
        o.id AS entity_id,
        o.name::text AS entity_name,
        gp.provisioning_status::text AS issue_status,
        coalesce(nullif(gp.last_error, ''), 'Grafana provisioning failed.')::text AS issue_detail,
        '/administration/organizations'::text AS action_path,
        'Reconcile Grafana'::text AS action_label
    FROM metadata.organizations o
    JOIN admin.grafana_organization_provisioning gp ON gp.organization_id = o.id
    CROSS JOIN actor a
    WHERE a.role_code = 'PLATFORM_ADMIN'
      AND gp.provisioning_status = 'FAILED'
),
queue AS (
    SELECT * FROM coverage
    UNION ALL SELECT * FROM telemetry
    UNION ALL SELECT * FROM unassigned
    UNION ALL SELECT * FROM locations
    UNION ALL SELECT * FROM grafana
)
SELECT q.*
FROM queue q
WHERE (p_organization_id IS NULL OR q.organization_id = p_organization_id)
  AND (p_site_id IS NULL OR q.site_id = p_site_id)
  AND (p_issue_type IS NULL OR q.issue_type = upper(btrim(p_issue_type)))
ORDER BY
    CASE q.severity WHEN 'HIGH' THEN 1 WHEN 'MEDIUM' THEN 2 ELSE 3 END,
    q.organization_name,
    q.site_name NULLS FIRST,
    q.entity_name;
$function$;

ALTER FUNCTION admin.list_accessible_reconciliation_queue(BIGINT,UUID,UUID,TEXT) OWNER TO ems_admin;
REVOKE ALL ON FUNCTION admin.list_accessible_reconciliation_queue(BIGINT,UUID,UUID,TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION admin.list_accessible_reconciliation_queue(BIGINT,UUID,UUID,TEXT) TO ems_app;
COMMENT ON FUNCTION admin.list_accessible_reconciliation_queue(BIGINT,UUID,UUID,TEXT) IS
'Tenant-safe read-only reconciliation queue for unassigned devices, telemetry/profile defects, missing metering coverage, location blockers, and platform-only Grafana failures.';
