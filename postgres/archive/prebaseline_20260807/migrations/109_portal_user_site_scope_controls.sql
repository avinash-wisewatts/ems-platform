-- Story 3.4: controlled site-scope assignment, integrity, and audit.

CREATE OR REPLACE FUNCTION admin.validate_portal_user_site_assignment()
RETURNS TRIGGER
LANGUAGE plpgsql
SET search_path TO pg_catalog, admin, metadata
AS $function$
DECLARE
    v_user_role TEXT;
    v_user_organization_id UUID;
    v_access_scope_mode TEXT;
    v_site_organization_id UUID;
BEGIN
    SELECT
        portal_user.role_code,
        portal_user.organization_id,
        portal_user.access_scope_mode
    INTO
        v_user_role,
        v_user_organization_id,
        v_access_scope_mode
    FROM admin.portal_users AS portal_user
    WHERE portal_user.portal_user_id = NEW.portal_user_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION
            'Portal user for site assignment was not found.';
    END IF;

    IF v_user_role = 'PLATFORM_ADMIN'
       OR v_access_scope_mode IS DISTINCT FROM 'SELECTED_SITES' THEN
        RAISE EXCEPTION
            'Site assignments require SELECTED_SITES tenant scope.';
    END IF;

    SELECT site_record.organization_id
    INTO v_site_organization_id
    FROM metadata.sites AS site_record
    WHERE site_record.id = NEW.site_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION
            'Assigned site was not found.';
    END IF;

    IF v_site_organization_id
       IS DISTINCT FROM v_user_organization_id THEN
        RAISE EXCEPTION
            'Assigned site must belong to the portal user organization.';
    END IF;

    RETURN NEW;
END;
$function$;


CREATE OR REPLACE FUNCTION admin.enforce_portal_user_site_scope()
RETURNS TRIGGER
LANGUAGE plpgsql
SET search_path TO pg_catalog, admin, metadata
AS $function$
DECLARE
    v_portal_user_id BIGINT;
    v_role_code TEXT;
    v_organization_id UUID;
    v_access_scope_mode TEXT;
    v_assignment_count BIGINT;
    v_invalid_assignment_count BIGINT;
BEGIN
    v_portal_user_id := COALESCE(
        NEW.portal_user_id,
        OLD.portal_user_id
    );

    SELECT
        portal_user.role_code,
        portal_user.organization_id,
        portal_user.access_scope_mode
    INTO
        v_role_code,
        v_organization_id,
        v_access_scope_mode
    FROM admin.portal_users AS portal_user
    WHERE portal_user.portal_user_id = v_portal_user_id;

    IF NOT FOUND THEN
        RETURN NULL;
    END IF;

    SELECT count(*)
    INTO v_assignment_count
    FROM admin.portal_user_site_access AS assignment
    WHERE assignment.portal_user_id = v_portal_user_id;

    SELECT count(*)
    INTO v_invalid_assignment_count
    FROM admin.portal_user_site_access AS assignment
    JOIN metadata.sites AS site_record
      ON site_record.id = assignment.site_id
    WHERE assignment.portal_user_id = v_portal_user_id
      AND site_record.organization_id
          IS DISTINCT FROM v_organization_id;

    IF v_invalid_assignment_count <> 0 THEN
        RAISE EXCEPTION
            'Portal user has a site assignment outside its organization.';
    END IF;

    IF v_role_code = 'PLATFORM_ADMIN' THEN
        IF v_organization_id IS NOT NULL
           OR v_access_scope_mode IS NOT NULL
           OR v_assignment_count <> 0 THEN
            RAISE EXCEPTION
                'PLATFORM_ADMIN must remain global and unscoped.';
        END IF;

        RETURN NULL;
    END IF;

    IF v_organization_id IS NULL THEN
        RAISE EXCEPTION
            'Tenant portal users require an organization.';
    END IF;

    IF v_access_scope_mode = 'ORGANIZATION' THEN
        IF v_assignment_count <> 0 THEN
            RAISE EXCEPTION
                'Organization-wide scope must not store site assignments.';
        END IF;
    ELSIF v_access_scope_mode = 'SELECTED_SITES' THEN
        IF v_assignment_count = 0 THEN
            RAISE EXCEPTION
                'Selected-sites scope requires at least one site.';
        END IF;
    ELSE
        RAISE EXCEPTION
            'Tenant portal user has an invalid access scope.';
    END IF;

    RETURN NULL;
END;
$function$;


DROP TRIGGER IF EXISTS
    portal_user_site_assignment_validate
    ON admin.portal_user_site_access;

CREATE TRIGGER portal_user_site_assignment_validate
BEFORE INSERT OR UPDATE
ON admin.portal_user_site_access
FOR EACH ROW
EXECUTE FUNCTION admin.validate_portal_user_site_assignment();


DROP TRIGGER IF EXISTS
    portal_user_scope_integrity_user
    ON admin.portal_users;

CREATE CONSTRAINT TRIGGER portal_user_scope_integrity_user
AFTER INSERT OR UPDATE
ON admin.portal_users
DEFERRABLE INITIALLY DEFERRED
FOR EACH ROW
EXECUTE FUNCTION admin.enforce_portal_user_site_scope();


DROP TRIGGER IF EXISTS
    portal_user_scope_integrity_assignment
    ON admin.portal_user_site_access;

CREATE CONSTRAINT TRIGGER portal_user_scope_integrity_assignment
AFTER INSERT OR UPDATE OR DELETE
ON admin.portal_user_site_access
DEFERRABLE INITIALLY DEFERRED
FOR EACH ROW
EXECUTE FUNCTION admin.enforce_portal_user_site_scope();


CREATE OR REPLACE FUNCTION admin.set_managed_portal_user_access_scope
(
    p_actor_portal_user_id BIGINT,
    p_target_portal_user_id BIGINT,
    p_access_scope_mode TEXT,
    p_site_ids UUID[]
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO pg_catalog, admin, metadata
AS $function$
DECLARE
    v_actor_role TEXT;
    v_actor_organization_id UUID;
    v_target_role TEXT;
    v_target_organization_id UUID;
    v_previous_access_scope_mode TEXT;
    v_previous_site_ids UUID[];
    v_normalized_site_ids UUID[];
    v_invalid_site_count BIGINT;
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
        RAISE EXCEPTION
            'Active portal actor was not found.';
    END IF;

    SELECT
        target.role_code,
        target.organization_id,
        target.access_scope_mode
    INTO
        v_target_role,
        v_target_organization_id,
        v_previous_access_scope_mode
    FROM admin.portal_users AS target
    WHERE target.portal_user_id = p_target_portal_user_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION
            'Target portal user was not found.';
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
            'Portal actor is not authorized to change user access scope.';
    END IF;

    IF v_target_role = 'PLATFORM_ADMIN' THEN
        RAISE EXCEPTION
            'PLATFORM_ADMIN cannot receive tenant or site scope.';
    END IF;

    IF v_target_organization_id IS NULL THEN
        RAISE EXCEPTION
            'Tenant portal users require an organization.';
    END IF;

    IF p_access_scope_mode NOT IN (
        'ORGANIZATION',
        'SELECTED_SITES'
    ) THEN
        RAISE EXCEPTION
            'Invalid portal access scope mode.';
    END IF;

    SELECT COALESCE(
        array_agg(
            DISTINCT supplied_site_id
            ORDER BY supplied_site_id
        ),
        ARRAY[]::UUID[]
    )
    INTO v_normalized_site_ids
    FROM unnest(
        COALESCE(
            p_site_ids,
            ARRAY[]::UUID[]
        )
    ) AS supplied(supplied_site_id)
    WHERE supplied_site_id IS NOT NULL;

    IF p_access_scope_mode = 'ORGANIZATION'
       AND cardinality(v_normalized_site_ids) <> 0 THEN
        RAISE EXCEPTION
            'Organization-wide scope must not include site assignments.';
    END IF;

    IF p_access_scope_mode = 'SELECTED_SITES'
       AND cardinality(v_normalized_site_ids) = 0 THEN
        RAISE EXCEPTION
            'Selected-sites scope requires at least one site.';
    END IF;

    SELECT count(*)
    INTO v_invalid_site_count
    FROM unnest(v_normalized_site_ids) AS requested(site_id)
    LEFT JOIN metadata.sites AS site_record
      ON site_record.id = requested.site_id
     AND site_record.is_active = TRUE
     AND site_record.organization_id =
         v_target_organization_id
    WHERE site_record.id IS NULL;

    IF v_invalid_site_count <> 0 THEN
        RAISE EXCEPTION
            'Every selected site must be active and belong to the target organization.';
    END IF;

    SELECT COALESCE(
        array_agg(
            assignment.site_id
            ORDER BY assignment.site_id
        ),
        ARRAY[]::UUID[]
    )
    INTO v_previous_site_ids
    FROM admin.portal_user_site_access AS assignment
    WHERE assignment.portal_user_id =
        p_target_portal_user_id;

    DELETE FROM admin.portal_user_site_access
    WHERE portal_user_id = p_target_portal_user_id;

    UPDATE admin.portal_users
    SET
        access_scope_mode = p_access_scope_mode,
        updated_at = clock_timestamp()
    WHERE portal_user_id = p_target_portal_user_id;

    IF p_access_scope_mode = 'SELECTED_SITES' THEN
        INSERT INTO admin.portal_user_site_access
        (
            portal_user_id,
            site_id,
            created_by_portal_user_id
        )
        SELECT
            p_target_portal_user_id,
            requested.site_id,
            p_actor_portal_user_id
        FROM unnest(v_normalized_site_ids)
            AS requested(site_id);
    END IF;

    IF v_previous_access_scope_mode
       IS DISTINCT FROM p_access_scope_mode
       OR v_previous_site_ids
          IS DISTINCT FROM v_normalized_site_ids THEN
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
            'USER_SCOPE_CHANGED',
            v_target_role,
            v_target_role,
            jsonb_build_object(
                'previous_access_scope_mode',
                v_previous_access_scope_mode,
                'new_access_scope_mode',
                p_access_scope_mode,
                'previous_site_ids',
                to_jsonb(v_previous_site_ids),
                'new_site_ids',
                to_jsonb(v_normalized_site_ids)
            )
        );
    END IF;
END;
$function$;


CREATE OR REPLACE FUNCTION admin.change_managed_portal_user_role
(
    p_actor_portal_user_id BIGINT,
    p_target_portal_user_id BIGINT,
    p_new_role_code TEXT,
    p_new_organization_id UUID
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO pg_catalog, admin
AS $function$
DECLARE
    v_actor_role TEXT;
    v_actor_organization_id UUID;
    v_previous_role_code TEXT;
    v_previous_organization_id UUID;
    v_previous_access_scope_mode TEXT;
    v_target_organization_id UUID;
    v_new_access_scope_mode TEXT;
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
        RAISE EXCEPTION
            'Active portal actor was not found.';
    END IF;

    SELECT
        target.role_code,
        target.organization_id,
        target.access_scope_mode
    INTO
        v_previous_role_code,
        v_previous_organization_id,
        v_previous_access_scope_mode
    FROM admin.portal_users AS target
    WHERE target.portal_user_id = p_target_portal_user_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION
            'Target portal user was not found.';
    END IF;

    IF p_new_role_code NOT IN (
        'PLATFORM_ADMIN',
        'ORG_ADMIN',
        'OPERATOR',
        'VIEWER'
    ) THEN
        RAISE EXCEPTION
            'Invalid portal role.';
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

        v_target_organization_id :=
            v_actor_organization_id;
    ELSIF v_actor_role = 'PLATFORM_ADMIN' THEN
        v_target_organization_id :=
            p_new_organization_id;
    ELSE
        RAISE EXCEPTION
            'Portal actor is not authorized to change user roles.';
    END IF;

    IF p_new_role_code = 'PLATFORM_ADMIN' THEN
        IF v_target_organization_id IS NOT NULL THEN
            RAISE EXCEPTION
                'PLATFORM_ADMIN must not have an organization scope.';
        END IF;

        v_new_access_scope_mode := NULL;
    ELSE
        IF v_target_organization_id IS NULL THEN
            RAISE EXCEPTION
                'Tenant portal users require an organization scope.';
        END IF;

        IF v_previous_role_code = 'PLATFORM_ADMIN'
           OR v_previous_organization_id
              IS DISTINCT FROM v_target_organization_id THEN
            v_new_access_scope_mode := 'ORGANIZATION';
        ELSE
            v_new_access_scope_mode :=
                COALESCE(
                    v_previous_access_scope_mode,
                    'ORGANIZATION'
                );
        END IF;
    END IF;

    IF p_new_role_code = 'PLATFORM_ADMIN'
       OR v_previous_organization_id
          IS DISTINCT FROM v_target_organization_id THEN
        DELETE FROM admin.portal_user_site_access
        WHERE portal_user_id = p_target_portal_user_id;
    END IF;

    UPDATE admin.portal_users AS target
    SET
        role_code = p_new_role_code,
        organization_id = v_target_organization_id,
        access_scope_mode = v_new_access_scope_mode,
        updated_at = clock_timestamp()
    WHERE target.portal_user_id =
        p_target_portal_user_id;

    IF v_previous_role_code
       IS DISTINCT FROM p_new_role_code
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
                v_target_organization_id,
                'previous_access_scope_mode',
                v_previous_access_scope_mode,
                'new_access_scope_mode',
                v_new_access_scope_mode
            )
        );
    END IF;
END;
$function$;


DROP FUNCTION IF EXISTS
    admin.list_manageable_portal_users(BIGINT);

CREATE FUNCTION admin.list_manageable_portal_users
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
        RAISE EXCEPTION
            'Active portal actor was not found.';
    END IF;

    IF v_actor_role NOT IN (
        'PLATFORM_ADMIN',
        'ORG_ADMIN'
    ) THEN
        RAISE EXCEPTION
            'Portal actor is not authorized to manage users.';
    END IF;

    IF v_actor_role = 'ORG_ADMIN'
       AND v_actor_organization_id IS NULL THEN
        RAISE EXCEPTION
            'Organization administrator has no organization scope.';
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
            array_agg(
                assignment.site_id
                ORDER BY assignment.site_id
            ) FILTER (
                WHERE assignment.site_id IS NOT NULL
            ),
            ARRAY[]::UUID[]
        ) AS site_ids,
        target.is_active,
        target.created_at,
        target.updated_at
    FROM admin.portal_users AS target
    LEFT JOIN admin.portal_user_site_access AS assignment
      ON assignment.portal_user_id =
         target.portal_user_id
    WHERE
        v_actor_role = 'PLATFORM_ADMIN'
        OR target.organization_id =
           v_actor_organization_id
    GROUP BY
        target.portal_user_id,
        target.username,
        target.display_name,
        target.email,
        target.role_code,
        target.organization_id,
        target.access_scope_mode,
        target.is_active,
        target.created_at,
        target.updated_at
    ORDER BY
        target.display_name,
        target.username,
        target.portal_user_id;
END;
$function$;


ALTER FUNCTION
    admin.validate_portal_user_site_assignment()
    OWNER TO ems_admin;

ALTER FUNCTION
    admin.enforce_portal_user_site_scope()
    OWNER TO ems_admin;

ALTER FUNCTION
    admin.set_managed_portal_user_access_scope(
        BIGINT,
        BIGINT,
        TEXT,
        UUID[]
    )
    OWNER TO ems_admin;

ALTER FUNCTION
    admin.change_managed_portal_user_role(
        BIGINT,
        BIGINT,
        TEXT,
        UUID
    )
    OWNER TO ems_admin;

ALTER FUNCTION
    admin.list_manageable_portal_users(BIGINT)
    OWNER TO ems_admin;


REVOKE ALL
    ON FUNCTION admin.set_managed_portal_user_access_scope(
        BIGINT,
        BIGINT,
        TEXT,
        UUID[]
    )
    FROM PUBLIC;

REVOKE ALL
    ON FUNCTION admin.list_manageable_portal_users(BIGINT)
    FROM PUBLIC;

GRANT EXECUTE
    ON FUNCTION admin.set_managed_portal_user_access_scope(
        BIGINT,
        BIGINT,
        TEXT,
        UUID[]
    )
    TO ems_app;

GRANT EXECUTE
    ON FUNCTION admin.list_manageable_portal_users(BIGINT)
    TO ems_app;
