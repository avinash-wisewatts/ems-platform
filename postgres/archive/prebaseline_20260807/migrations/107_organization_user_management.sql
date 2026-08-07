-- Story 3.3: controlled organization user management.
--
-- ems_app receives EXECUTE only. All authorization and organization-scope
-- checks are derived from the authenticated actor stored in portal_users.

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
    is_active BOOLEAN,
    created_at TIMESTAMPTZ,
    updated_at TIMESTAMPTZ
)
LANGUAGE plpgsql
SECURITY DEFINER
STABLE
SET search_path TO pg_catalog, admin
AS $function$
DECLARE
    v_actor_role TEXT;
    v_actor_organization_id UUID;
BEGIN
    SELECT
        actor.role_code,
        actor.organization_id
    INTO
        v_actor_role,
        v_actor_organization_id
    FROM admin.portal_users AS actor
    WHERE actor.portal_user_id = p_actor_portal_user_id
      AND actor.is_active = TRUE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Active portal actor was not found.';
    END IF;

    IF v_actor_role NOT IN ('PLATFORM_ADMIN', 'ORG_ADMIN') THEN
        RAISE EXCEPTION 'Portal actor is not authorized to manage users.';
    END IF;

    IF v_actor_role = 'ORG_ADMIN'
       AND v_actor_organization_id IS NULL THEN
        RAISE EXCEPTION 'Organization administrator has no organization scope.';
    END IF;

    RETURN QUERY
    SELECT
        target.portal_user_id,
        target.username,
        target.display_name,
        target.email,
        target.role_code,
        target.organization_id,
        target.is_active,
        target.created_at,
        target.updated_at
    FROM admin.portal_users AS target
    WHERE
        v_actor_role = 'PLATFORM_ADMIN'
        OR target.organization_id = v_actor_organization_id
    ORDER BY
        target.display_name,
        target.username,
        target.portal_user_id;
END;
$function$;


CREATE OR REPLACE FUNCTION admin.create_managed_portal_user
(
    p_actor_portal_user_id BIGINT,
    p_username TEXT,
    p_display_name TEXT,
    p_email TEXT,
    p_password_hash TEXT,
    p_role_code TEXT,
    p_organization_id UUID
)
RETURNS BIGINT
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO pg_catalog, admin
AS $function$
DECLARE
    v_actor_role TEXT;
    v_actor_organization_id UUID;
    v_target_organization_id UUID;
    v_portal_user_id BIGINT;
BEGIN
    SELECT
        actor.role_code,
        actor.organization_id
    INTO
        v_actor_role,
        v_actor_organization_id
    FROM admin.portal_users AS actor
    WHERE actor.portal_user_id = p_actor_portal_user_id
      AND actor.is_active = TRUE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Active portal actor was not found.';
    END IF;

    IF v_actor_role NOT IN ('PLATFORM_ADMIN', 'ORG_ADMIN') THEN
        RAISE EXCEPTION 'Portal actor is not authorized to create users.';
    END IF;

    IF p_role_code NOT IN (
        'PLATFORM_ADMIN',
        'ORG_ADMIN',
        'OPERATOR',
        'VIEWER'
    ) THEN
        RAISE EXCEPTION 'Invalid portal role.';
    END IF;

    IF v_actor_role = 'ORG_ADMIN' THEN
        IF v_actor_organization_id IS NULL THEN
            RAISE EXCEPTION
                'Organization administrator has no organization scope.';
        END IF;

        IF p_role_code = 'PLATFORM_ADMIN' THEN
            RAISE EXCEPTION
                'Organization administrators cannot assign PLATFORM_ADMIN.';
        END IF;

        IF p_organization_id IS DISTINCT FROM v_actor_organization_id THEN
            RAISE EXCEPTION
                'Organization administrators cannot create users in another organization.';
        END IF;

        v_target_organization_id := v_actor_organization_id;
    ELSE
        v_target_organization_id := p_organization_id;
    END IF;

    IF p_role_code = 'PLATFORM_ADMIN'
       AND v_target_organization_id IS NOT NULL THEN
        RAISE EXCEPTION
            'PLATFORM_ADMIN must not have an organization scope.';
    END IF;

    IF p_role_code <> 'PLATFORM_ADMIN'
       AND v_target_organization_id IS NULL THEN
        RAISE EXCEPTION
            'Tenant portal users require an organization scope.';
    END IF;

    INSERT INTO admin.portal_users
    (
        username,
        display_name,
        email,
        password_hash,
        role_code,
        organization_id,
        created_by
    )
    VALUES
    (
        lower(btrim(p_username)),
        btrim(p_display_name),
        NULLIF(btrim(p_email), ''),
        p_password_hash,
        p_role_code,
        v_target_organization_id,
        p_actor_portal_user_id::TEXT
    )
    RETURNING portal_user_id
    INTO v_portal_user_id;

    INSERT INTO admin.portal_user_audit
    (
        actor_portal_user_id,
        target_portal_user_id,
        organization_id,
        event_type,
        new_role_code,
        event_payload
    )
    VALUES
    (
        p_actor_portal_user_id,
        v_portal_user_id,
        v_target_organization_id,
        'USER_CREATED',
        p_role_code,
        jsonb_build_object(
            'username',
            lower(btrim(p_username)),
            'display_name',
            btrim(p_display_name),
            'email',
            NULLIF(btrim(p_email), ''),
            'is_active',
            TRUE
        )
    );

    RETURN v_portal_user_id;
END;
$function$;


CREATE OR REPLACE FUNCTION admin.change_managed_portal_user_role
(
    p_actor_portal_user_id BIGINT,
    p_target_portal_user_id BIGINT,
    p_new_role_code TEXT,
    p_new_organization_id UUID
)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO pg_catalog, admin
AS $function$
DECLARE
    v_actor_role TEXT;
    v_actor_organization_id UUID;
    v_previous_role_code TEXT;
    v_previous_organization_id UUID;
    v_target_organization_id UUID;
BEGIN
    SELECT
        actor.role_code,
        actor.organization_id
    INTO
        v_actor_role,
        v_actor_organization_id
    FROM admin.portal_users AS actor
    WHERE actor.portal_user_id = p_actor_portal_user_id
      AND actor.is_active = TRUE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Active portal actor was not found.';
    END IF;

    SELECT
        target.role_code,
        target.organization_id
    INTO
        v_previous_role_code,
        v_previous_organization_id
    FROM admin.portal_users AS target
    WHERE target.portal_user_id = p_target_portal_user_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Target portal user was not found.';
    END IF;

    IF p_new_role_code NOT IN (
        'PLATFORM_ADMIN',
        'ORG_ADMIN',
        'OPERATOR',
        'VIEWER'
    ) THEN
        RAISE EXCEPTION 'Invalid portal role.';
    END IF;

    IF v_actor_role = 'ORG_ADMIN' THEN
        IF v_actor_organization_id IS NULL THEN
            RAISE EXCEPTION
                'Organization administrator has no organization scope.';
        END IF;

        IF v_previous_organization_id
           IS DISTINCT FROM v_actor_organization_id THEN
            RAISE EXCEPTION
                'Organization administrators cannot manage users in another organization.';
        END IF;

        IF p_new_role_code = 'PLATFORM_ADMIN' THEN
            RAISE EXCEPTION
                'Organization administrators cannot assign PLATFORM_ADMIN.';
        END IF;

        IF p_new_organization_id
           IS DISTINCT FROM v_actor_organization_id THEN
            RAISE EXCEPTION
                'Organization administrators cannot move users to another organization.';
        END IF;

        v_target_organization_id := v_actor_organization_id;
    ELSIF v_actor_role = 'PLATFORM_ADMIN' THEN
        v_target_organization_id := p_new_organization_id;
    ELSE
        RAISE EXCEPTION
            'Portal actor is not authorized to change user roles.';
    END IF;

    IF p_new_role_code = 'PLATFORM_ADMIN'
       AND v_target_organization_id IS NOT NULL THEN
        RAISE EXCEPTION
            'PLATFORM_ADMIN must not have an organization scope.';
    END IF;

    IF p_new_role_code <> 'PLATFORM_ADMIN'
       AND v_target_organization_id IS NULL THEN
        RAISE EXCEPTION
            'Tenant portal users require an organization scope.';
    END IF;

    UPDATE admin.portal_users AS target
    SET
        role_code = p_new_role_code,
        organization_id = v_target_organization_id,
        updated_at = clock_timestamp()
    WHERE target.portal_user_id = p_target_portal_user_id;

    IF v_previous_role_code IS DISTINCT FROM p_new_role_code
       OR v_previous_organization_id
          IS DISTINCT FROM v_target_organization_id THEN
        INSERT INTO admin.portal_user_audit
        (
            actor_portal_user_id,
            target_portal_user_id,
            organization_id,
            event_type,
            previous_role_code,
            new_role_code,
            event_payload
        )
        VALUES
        (
            p_actor_portal_user_id,
            p_target_portal_user_id,
            v_target_organization_id,
            'USER_ROLE_CHANGED',
            v_previous_role_code,
            p_new_role_code,
            jsonb_build_object(
                'previous_organization_id',
                v_previous_organization_id,
                'new_organization_id',
                v_target_organization_id
            )
        );
    END IF;
END;
$function$;


CREATE OR REPLACE FUNCTION admin.set_managed_portal_user_active
(
    p_actor_portal_user_id BIGINT,
    p_target_portal_user_id BIGINT,
    p_is_active BOOLEAN
)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO pg_catalog, admin
AS $function$
DECLARE
    v_actor_role TEXT;
    v_actor_organization_id UUID;
    v_target_organization_id UUID;
    v_previous_is_active BOOLEAN;
BEGIN
    SELECT
        actor.role_code,
        actor.organization_id
    INTO
        v_actor_role,
        v_actor_organization_id
    FROM admin.portal_users AS actor
    WHERE actor.portal_user_id = p_actor_portal_user_id
      AND actor.is_active = TRUE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Active portal actor was not found.';
    END IF;

    SELECT
        target.organization_id,
        target.is_active
    INTO
        v_target_organization_id,
        v_previous_is_active
    FROM admin.portal_users AS target
    WHERE target.portal_user_id = p_target_portal_user_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Target portal user was not found.';
    END IF;

    IF v_actor_role = 'ORG_ADMIN' THEN
        IF v_actor_organization_id IS NULL
           OR v_target_organization_id
              IS DISTINCT FROM v_actor_organization_id THEN
            RAISE EXCEPTION
                'Organization administrators cannot manage users in another organization.';
        END IF;
    ELSIF v_actor_role <> 'PLATFORM_ADMIN' THEN
        RAISE EXCEPTION
            'Portal actor is not authorized to change user status.';
    END IF;

    UPDATE admin.portal_users AS target
    SET
        is_active = p_is_active,
        updated_at = clock_timestamp()
    WHERE target.portal_user_id = p_target_portal_user_id;

    IF v_previous_is_active IS DISTINCT FROM p_is_active THEN
        INSERT INTO admin.portal_user_audit
        (
            actor_portal_user_id,
            target_portal_user_id,
            organization_id,
            event_type,
            event_payload
        )
        VALUES
        (
            p_actor_portal_user_id,
            p_target_portal_user_id,
            v_target_organization_id,
            'USER_STATUS_CHANGED',
            jsonb_build_object(
                'previous_is_active',
                v_previous_is_active,
                'new_is_active',
                p_is_active
            )
        );
    END IF;
END;
$function$;


ALTER FUNCTION admin.list_manageable_portal_users(BIGINT)
    OWNER TO ems_admin;

ALTER FUNCTION admin.create_managed_portal_user(
    BIGINT,
    TEXT,
    TEXT,
    TEXT,
    TEXT,
    TEXT,
    UUID
)
    OWNER TO ems_admin;

ALTER FUNCTION admin.change_managed_portal_user_role(
    BIGINT,
    BIGINT,
    TEXT,
    UUID
)
    OWNER TO ems_admin;

ALTER FUNCTION admin.set_managed_portal_user_active(
    BIGINT,
    BIGINT,
    BOOLEAN
)
    OWNER TO ems_admin;


REVOKE ALL
    ON FUNCTION admin.list_manageable_portal_users(BIGINT)
    FROM PUBLIC;

REVOKE ALL
    ON FUNCTION admin.create_managed_portal_user(
        BIGINT,
        TEXT,
        TEXT,
        TEXT,
        TEXT,
        TEXT,
        UUID
    )
    FROM PUBLIC;

REVOKE ALL
    ON FUNCTION admin.change_managed_portal_user_role(
        BIGINT,
        BIGINT,
        TEXT,
        UUID
    )
    FROM PUBLIC;

REVOKE ALL
    ON FUNCTION admin.set_managed_portal_user_active(
        BIGINT,
        BIGINT,
        BOOLEAN
    )
    FROM PUBLIC;


GRANT EXECUTE
    ON FUNCTION admin.list_manageable_portal_users(BIGINT)
    TO ems_app;

GRANT EXECUTE
    ON FUNCTION admin.create_managed_portal_user(
        BIGINT,
        TEXT,
        TEXT,
        TEXT,
        TEXT,
        TEXT,
        UUID
    )
    TO ems_app;

GRANT EXECUTE
    ON FUNCTION admin.change_managed_portal_user_role(
        BIGINT,
        BIGINT,
        TEXT,
        UUID
    )
    TO ems_app;

GRANT EXECUTE
    ON FUNCTION admin.set_managed_portal_user_active(
        BIGINT,
        BIGINT,
        BOOLEAN
    )
    TO ems_app;
