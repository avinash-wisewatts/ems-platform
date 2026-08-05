CREATE OR REPLACE FUNCTION admin.list_manageable_portal_users
(
    p_actor_portal_user_id BIGINT
)
RETURNS TABLE
(
    portal_user_id BIGINT,
    username TEXT,
    display_name TEXT,
    email TEXT,
    role_code TEXT,
    organization_id UUID,
    access_scope_mode TEXT,
    site_ids UUID[],
    is_active BOOLEAN,
    created_at TIMESTAMPTZ,
    updated_at TIMESTAMPTZ
)
LANGUAGE plpgsql
SECURITY DEFINER
STABLE
SET search_path TO pg_catalog, admin
AS $function$
BEGIN
    IF NOT EXISTS (
        SELECT 1
        FROM admin.portal_users AS actor
        WHERE actor.portal_user_id = p_actor_portal_user_id
          AND actor.is_active
          AND actor.role_code = 'ADMIN'
    ) THEN
        RAISE EXCEPTION
            'Portal actor is not authorized to manage users.'
            USING ERRCODE = '42501';
    END IF;

    RETURN QUERY
    SELECT
        target.portal_user_id,
        target.username,
        target.display_name,
        target.email,
        target.role_code,
        target.organization_id,
        target.access_scope_mode,
        COALESCE(
            array_agg(access.site_id ORDER BY access.site_id)
                FILTER (WHERE access.site_id IS NOT NULL),
            ARRAY[]::UUID[]
        ),
        target.is_active,
        target.created_at,
        target.updated_at
    FROM admin.portal_users AS target
    LEFT JOIN admin.portal_user_site_access AS access
      ON access.portal_user_id = target.portal_user_id
    WHERE admin.portal_user_scope_contains_user(
        p_actor_portal_user_id,
        target.portal_user_id
    )
    GROUP BY target.portal_user_id
    ORDER BY
        target.display_name,
        target.username,
        target.portal_user_id;
END;
$function$;

ALTER FUNCTION admin.list_manageable_portal_users(BIGINT)
    OWNER TO ems_admin;

REVOKE ALL
ON FUNCTION admin.list_manageable_portal_users(BIGINT)
FROM PUBLIC;

GRANT EXECUTE
ON FUNCTION admin.list_manageable_portal_users(BIGINT)
TO ems_app;
