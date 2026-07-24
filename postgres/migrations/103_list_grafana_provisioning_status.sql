-- Story 2.3: least-privilege organization Grafana status listing.

CREATE OR REPLACE FUNCTION admin.list_grafana_provisioning_status()
RETURNS TABLE
(
    organization_id UUID,
    organization_code TEXT,
    organization_name TEXT,
    timezone TEXT,
    lifecycle_status TEXT,
    provisioning_status TEXT,
    grafana_org_id BIGINT,
    attempt_count INTEGER,
    last_attempt_at TIMESTAMPTZ,
    provisioned_at TIMESTAMPTZ,
    last_error TEXT
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, admin, metadata, config
AS $$
    SELECT
        organization.id AS organization_id,
        organization.code AS organization_code,
        organization.name AS organization_name,
        organization.timezone,
        organization.lifecycle_status,
        COALESCE(
            provisioning.provisioning_status,
            'NOT_STARTED'
        ) AS provisioning_status,
        provisioning.grafana_org_id,
        COALESCE(
            provisioning.attempt_count,
            0
        ) AS attempt_count,
        provisioning.last_attempt_at,
        provisioning.provisioned_at,
        provisioning.last_error
    FROM metadata.organizations organization
    LEFT JOIN admin.grafana_organization_provisioning provisioning
        ON provisioning.organization_id = organization.id
    ORDER BY
        organization.name,
        organization.code,
        organization.id;
$$;

ALTER FUNCTION admin.list_grafana_provisioning_status()
    OWNER TO ems_admin;

REVOKE ALL
    ON FUNCTION admin.list_grafana_provisioning_status()
    FROM PUBLIC;

GRANT EXECUTE
    ON FUNCTION admin.list_grafana_provisioning_status()
    TO ems_app;
