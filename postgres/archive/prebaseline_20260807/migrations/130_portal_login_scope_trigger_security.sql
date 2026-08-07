-- Preserve portal login and scoped-user updates under the least-privilege app role.
-- The trigger must read protected admin tables using its controlled owner privileges.

ALTER FUNCTION admin.enforce_portal_user_site_scope()
    OWNER TO ems_admin;

ALTER FUNCTION admin.enforce_portal_user_site_scope()
    SECURITY DEFINER;

ALTER FUNCTION admin.enforce_portal_user_site_scope()
    SET search_path TO pg_catalog, admin, metadata;

REVOKE ALL ON FUNCTION admin.enforce_portal_user_site_scope()
    FROM PUBLIC;

COMMENT ON FUNCTION admin.enforce_portal_user_site_scope() IS
    'Validates portal-user organization and site scope as a controlled SECURITY DEFINER trigger so least-privilege application updates, including login-success tracking, can commit safely.';
