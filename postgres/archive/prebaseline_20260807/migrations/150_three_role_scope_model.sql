-- Replace the legacy four-role authorization model with:
--
-- Roles:
--   ADMIN
--   OPERATOR
--   VIEWER
--
-- Independent access scopes:
--   GLOBAL
--   ORGANIZATION
--   SELECTED_SITES
--
-- This migration must remain atomic. It may not be applied until all affected
-- authorization functions below have been replaced and the final safety stop
-- has been removed.

-- ============================================================================
-- Temporarily remove deferred scope triggers during controlled data conversion.
-- They are recreated after their functions use the new scope model.
-- ============================================================================

DROP TRIGGER IF EXISTS
    portal_user_scope_integrity_assignment
    ON admin.portal_user_site_access;

DROP TRIGGER IF EXISTS
    portal_user_site_assignment_validate
    ON admin.portal_user_site_access;

DROP TRIGGER IF EXISTS
    portal_user_scope_integrity_user
    ON admin.portal_users;


-- ============================================================================
-- Relax legacy role/scope checks before converting existing identities.
-- ============================================================================

ALTER TABLE admin.portal_users
    DROP CONSTRAINT IF EXISTS portal_users_access_scope_mode_valid;

ALTER TABLE admin.portal_users
    DROP CONSTRAINT IF EXISTS portal_users_role_organization_scope_valid;

ALTER TABLE admin.portal_users
    DROP CONSTRAINT IF EXISTS portal_users_role_code_valid;


-- ============================================================================
-- Canonical role definitions.
-- ============================================================================

INSERT INTO config.portal_role_definitions
(
    role_code,
    display_name,
    description,
    sort_order,
    is_assignable
)
VALUES
(
    'ADMIN',
    'Administrator',
    (
        'Performs administrative operations permitted by the assigned '
        'access scope. GLOBAL administrators manage the EMS platform; '
        'organization and selected-site administrators manage only their '
        'authorized tenant scope.'
    ),
    10,
    TRUE
),
(
    'OPERATOR',
    'Operator',
    (
        'Performs permitted operational, onboarding, commissioning, alert, '
        'and analytical activities within the assigned access scope.'
    ),
    20,
    TRUE
),
(
    'VIEWER',
    'Viewer',
    (
        'Provides read-only dashboard and report access within the assigned '
        'access scope.'
    ),
    30,
    TRUE
)
ON CONFLICT (role_code)
DO UPDATE SET
    display_name = EXCLUDED.display_name,
    description = EXCLUDED.description,
    sort_order = EXCLUDED.sort_order,
    is_assignable = EXCLUDED.is_assignable,
    updated_at = now();


-- ============================================================================
-- Convert existing users.
--
-- PLATFORM_ADMIN -> ADMIN + GLOBAL
-- ORG_ADMIN      -> ADMIN + existing tenant scope
-- OPERATOR       -> unchanged role, preserve valid scope
-- VIEWER         -> unchanged role, preserve valid scope
-- ============================================================================

UPDATE admin.portal_users
SET
    role_code = CASE
        WHEN role_code IN ('PLATFORM_ADMIN', 'ORG_ADMIN')
            THEN 'ADMIN'
        ELSE role_code
    END,
    access_scope_mode = CASE
        WHEN role_code = 'PLATFORM_ADMIN'
            THEN 'GLOBAL'
        WHEN access_scope_mode IS NULL
             AND organization_id IS NOT NULL
            THEN 'ORGANIZATION'
        ELSE access_scope_mode
    END,
    organization_id = CASE
        WHEN role_code = 'PLATFORM_ADMIN'
            THEN NULL
        ELSE organization_id
    END,
    updated_at = clock_timestamp()
WHERE role_code IN (
    'PLATFORM_ADMIN',
    'ORG_ADMIN',
    'OPERATOR',
    'VIEWER'
);


-- GLOBAL and ORGANIZATION scopes must not retain selected-site assignments.

DELETE FROM admin.portal_user_site_access AS assignment
USING admin.portal_users AS portal_user
WHERE portal_user.portal_user_id = assignment.portal_user_id
  AND portal_user.access_scope_mode IN (
      'GLOBAL',
      'ORGANIZATION'
  );


-- ============================================================================
-- Declarative role-to-permission mappings.
-- ============================================================================

DELETE FROM config.portal_role_permissions
WHERE role_code IN (
    'PLATFORM_ADMIN',
    'ORG_ADMIN',
    'ADMIN',
    'OPERATOR',
    'VIEWER'
);


-- ADMIN receives the complete permission catalog.

INSERT INTO config.portal_role_permissions
(
    role_code,
    permission_code
)
SELECT
    'ADMIN',
    permission.permission_code
FROM config.portal_permission_definitions AS permission;


-- OPERATOR receives operational permissions only.

INSERT INTO config.portal_role_permissions
(
    role_code,
    permission_code
)
VALUES
    ('OPERATOR', 'site.manage'),
    ('OPERATOR', 'location.manage'),
    ('OPERATOR', 'asset.manage'),
    ('OPERATOR', 'gateway.manage'),
    ('OPERATOR', 'device.manage'),
    ('OPERATOR', 'relationship.manage'),
    ('OPERATOR', 'metering_policy.manage'),
    ('OPERATOR', 'commissioning.execute'),
    ('OPERATOR', 'alert.acknowledge'),
    ('OPERATOR', 'dashboard.view'),
    ('OPERATOR', 'report.export');


-- VIEWER remains read-only.

INSERT INTO config.portal_role_permissions
(
    role_code,
    permission_code
)
VALUES
    ('VIEWER', 'dashboard.view'),
    ('VIEWER', 'report.export');


DELETE FROM config.portal_role_definitions
WHERE role_code IN (
    'PLATFORM_ADMIN',
    'ORG_ADMIN'
);


-- ============================================================================
-- Strict canonical constraints.
-- ============================================================================

ALTER TABLE admin.portal_users
    ADD CONSTRAINT portal_users_role_code_valid
    CHECK (
        role_code IN (
            'ADMIN',
            'OPERATOR',
            'VIEWER'
        )
    );


ALTER TABLE admin.portal_users
    ADD CONSTRAINT portal_users_role_organization_scope_valid
    CHECK (
        (
            access_scope_mode = 'GLOBAL'
            AND organization_id IS NULL
        )
        OR
        (
            access_scope_mode IN (
                'ORGANIZATION',
                'SELECTED_SITES'
            )
            AND organization_id IS NOT NULL
        )
    );


ALTER TABLE admin.portal_users
    ADD CONSTRAINT portal_users_access_scope_mode_valid
    CHECK (
        access_scope_mode IN (
            'GLOBAL',
            'ORGANIZATION',
            'SELECTED_SITES'
        )
    );


COMMENT ON COLUMN admin.portal_users.role_code IS
'Portal capability role: ADMIN, OPERATOR, or VIEWER.';


COMMENT ON COLUMN admin.portal_users.organization_id IS
'Organization boundary for ORGANIZATION and SELECTED_SITES scopes. NULL for GLOBAL scope.';


COMMENT ON COLUMN admin.portal_users.access_scope_mode IS
'Independent authorization reach: GLOBAL, ORGANIZATION, or SELECTED_SITES.';


COMMENT ON TABLE config.portal_role_permissions IS
'Declarative role-to-permission mappings. Role controls capability; portal-user scope controls reach.';


-- ============================================================================
-- The 24 scope-aware function replacements will be inserted below.
-- ============================================================================

-- FUNCTION_REPLACEMENTS_BEGIN


-- ============================================================================
-- Scope foundation
-- ============================================================================

CREATE OR REPLACE FUNCTION admin.validate_portal_user_site_assignment()
RETURNS TRIGGER
LANGUAGE plpgsql
SET search_path TO pg_catalog, admin, metadata
AS $function$
DECLARE
    v_user_organization_id UUID;
    v_access_scope_mode TEXT;
    v_site_organization_id UUID;
BEGIN
    SELECT
        portal_user.organization_id,
        portal_user.access_scope_mode
    INTO
        v_user_organization_id,
        v_access_scope_mode
    FROM admin.portal_users AS portal_user
    WHERE portal_user.portal_user_id = NEW.portal_user_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION
            'Portal user for site assignment was not found.';
    END IF;

    IF v_access_scope_mode IS DISTINCT FROM 'SELECTED_SITES' THEN
        RAISE EXCEPTION
            'Site assignments require SELECTED_SITES scope.';
    END IF;

    IF v_user_organization_id IS NULL THEN
        RAISE EXCEPTION
            'SELECTED_SITES scope requires an organization.';
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
SECURITY DEFINER
SET search_path TO pg_catalog, admin, metadata
AS $function$
DECLARE
    v_portal_user_id BIGINT;
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
        portal_user.organization_id,
        portal_user.access_scope_mode
    INTO
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
      AND (
          v_organization_id IS NULL
          OR site_record.organization_id
             IS DISTINCT FROM v_organization_id
      );

    IF v_invalid_assignment_count <> 0 THEN
        RAISE EXCEPTION
            'Portal user has a site assignment outside its organization.';
    END IF;

    IF v_access_scope_mode = 'GLOBAL' THEN
        IF v_organization_id IS NOT NULL
           OR v_assignment_count <> 0 THEN
            RAISE EXCEPTION
                'GLOBAL scope requires no organization and no site assignments.';
        END IF;

    ELSIF v_access_scope_mode = 'ORGANIZATION' THEN
        IF v_organization_id IS NULL THEN
            RAISE EXCEPTION
                'ORGANIZATION scope requires an organization.';
        END IF;

        IF v_assignment_count <> 0 THEN
            RAISE EXCEPTION
                'ORGANIZATION scope must not store site assignments.';
        END IF;

    ELSIF v_access_scope_mode = 'SELECTED_SITES' THEN
        IF v_organization_id IS NULL THEN
            RAISE EXCEPTION
                'SELECTED_SITES scope requires an organization.';
        END IF;

        IF v_assignment_count = 0 THEN
            RAISE EXCEPTION
                'SELECTED_SITES scope requires at least one site.';
        END IF;

    ELSE
        RAISE EXCEPTION
            'Portal user has an invalid access scope.';
    END IF;

    RETURN NULL;
END;
$function$;


CREATE OR REPLACE FUNCTION admin.portal_user_can_access_site
(
    p_portal_user_id BIGINT,
    p_site_id UUID
)
RETURNS BOOLEAN
LANGUAGE SQL
SECURITY DEFINER
STABLE
SET search_path TO pg_catalog, admin, metadata
AS $function$
    SELECT COALESCE(
        (
            SELECT
                CASE
                    WHEN portal_user.access_scope_mode = 'GLOBAL'
                        THEN TRUE

                    WHEN portal_user.organization_id
                         IS DISTINCT FROM site_record.organization_id
                        THEN FALSE

                    WHEN portal_user.access_scope_mode = 'ORGANIZATION'
                        THEN TRUE

                    WHEN portal_user.access_scope_mode = 'SELECTED_SITES'
                        THEN EXISTS (
                            SELECT 1
                            FROM admin.portal_user_site_access AS assignment
                            WHERE assignment.portal_user_id =
                                portal_user.portal_user_id
                              AND assignment.site_id =
                                site_record.id
                        )

                    ELSE FALSE
                END
            FROM admin.portal_users AS portal_user
            JOIN metadata.sites AS site_record
              ON site_record.id = p_site_id
            WHERE portal_user.portal_user_id = p_portal_user_id
              AND portal_user.is_active = TRUE
        ),
        FALSE
    );
$function$;


CREATE OR REPLACE FUNCTION admin.list_accessible_sites
(
    p_portal_user_id BIGINT
)
RETURNS TABLE
(
    id UUID,
    organization_id UUID,
    organization_code TEXT,
    organization_name TEXT,
    site_code TEXT,
    site_name TEXT,
    timezone TEXT,
    address JSONB,
    is_active BOOLEAN
)
LANGUAGE SQL
SECURITY DEFINER
STABLE
SET search_path TO pg_catalog, admin, metadata
AS $function$
    SELECT
        site_record.id,
        site_record.organization_id,
        organization_record.code AS organization_code,
        organization_record.name AS organization_name,
        site_record.code AS site_code,
        site_record.name AS site_name,
        site_record.timezone,
        site_record.address,
        site_record.is_active
    FROM metadata.sites AS site_record
    JOIN metadata.organizations AS organization_record
      ON organization_record.id = site_record.organization_id
    JOIN admin.portal_users AS portal_user
      ON portal_user.portal_user_id = p_portal_user_id
    WHERE portal_user.is_active = TRUE
      AND site_record.is_active = TRUE
      AND (
          portal_user.access_scope_mode = 'GLOBAL'
          OR (
              portal_user.organization_id =
                  site_record.organization_id
              AND (
                  portal_user.access_scope_mode = 'ORGANIZATION'
                  OR (
                      portal_user.access_scope_mode = 'SELECTED_SITES'
                      AND EXISTS (
                          SELECT 1
                          FROM admin.portal_user_site_access AS assignment
                          WHERE assignment.portal_user_id =
                              portal_user.portal_user_id
                            AND assignment.site_id =
                                site_record.id
                      )
                  )
              )
          )
      )
    ORDER BY
        organization_record.name,
        site_record.name,
        site_record.code,
        site_record.id;
$function$;


ALTER FUNCTION admin.validate_portal_user_site_assignment()
    OWNER TO ems_admin;

ALTER FUNCTION admin.enforce_portal_user_site_scope()
    OWNER TO ems_admin;

ALTER FUNCTION admin.portal_user_can_access_site(BIGINT, UUID)
    OWNER TO ems_admin;

ALTER FUNCTION admin.list_accessible_sites(BIGINT)
    OWNER TO ems_admin;


REVOKE ALL
ON FUNCTION admin.validate_portal_user_site_assignment()
FROM PUBLIC;

REVOKE ALL
ON FUNCTION admin.enforce_portal_user_site_scope()
FROM PUBLIC;

REVOKE ALL
ON FUNCTION admin.portal_user_can_access_site(BIGINT, UUID)
FROM PUBLIC;

REVOKE ALL
ON FUNCTION admin.list_accessible_sites(BIGINT)
FROM PUBLIC;


GRANT EXECUTE
ON FUNCTION admin.portal_user_can_access_site(BIGINT, UUID)
TO ems_app;

GRANT EXECUTE
ON FUNCTION admin.list_accessible_sites(BIGINT)
TO ems_app;


-- ============================================================================
-- Recreate scope-integrity triggers.
-- ============================================================================

CREATE TRIGGER portal_user_site_assignment_validate
BEFORE INSERT OR UPDATE
ON admin.portal_user_site_access
FOR EACH ROW
EXECUTE FUNCTION admin.validate_portal_user_site_assignment();


CREATE CONSTRAINT TRIGGER portal_user_scope_integrity_user
AFTER INSERT OR UPDATE
ON admin.portal_users
DEFERRABLE INITIALLY DEFERRED
FOR EACH ROW
EXECUTE FUNCTION admin.enforce_portal_user_site_scope();


CREATE CONSTRAINT TRIGGER portal_user_scope_integrity_assignment
AFTER INSERT OR UPDATE OR DELETE
ON admin.portal_user_site_access
DEFERRABLE INITIALLY DEFERRED
FOR EACH ROW
EXECUTE FUNCTION admin.enforce_portal_user_site_scope();


COMMENT ON FUNCTION admin.enforce_portal_user_site_scope() IS
'Validates GLOBAL, ORGANIZATION, and SELECTED_SITES portal-user scope invariants as a controlled SECURITY DEFINER trigger.';

-- SCOPE_FOUNDATION_END




-- ============================================================================
-- Scope containment helper used by controlled user-management functions.
-- ============================================================================

CREATE OR REPLACE FUNCTION admin.portal_user_scope_contains_user
(
    p_actor_portal_user_id BIGINT,
    p_target_portal_user_id BIGINT
)
RETURNS BOOLEAN
LANGUAGE SQL
SECURITY DEFINER
STABLE
SET search_path TO pg_catalog, admin
AS $function$
    WITH actor AS (
        SELECT role_code, organization_id, access_scope_mode
        FROM admin.portal_users
        WHERE portal_user_id = p_actor_portal_user_id
          AND is_active
    ),
    target AS (
        SELECT role_code, organization_id, access_scope_mode
        FROM admin.portal_users
        WHERE portal_user_id = p_target_portal_user_id
    )
    SELECT COALESCE((
        SELECT
            a.role_code = 'ADMIN'
            AND (
                a.access_scope_mode = 'GLOBAL'
                OR (
                    a.access_scope_mode = 'ORGANIZATION'
                    AND t.access_scope_mode <> 'GLOBAL'
                    AND a.organization_id = t.organization_id
                )
                OR (
                    a.access_scope_mode = 'SELECTED_SITES'
                    AND t.access_scope_mode = 'SELECTED_SITES'
                    AND a.organization_id = t.organization_id
                    AND NOT EXISTS (
                        SELECT 1
                        FROM admin.portal_user_site_access target_site
                        WHERE target_site.portal_user_id = p_target_portal_user_id
                          AND NOT EXISTS (
                              SELECT 1
                              FROM admin.portal_user_site_access actor_site
                              WHERE actor_site.portal_user_id = p_actor_portal_user_id
                                AND actor_site.site_id = target_site.site_id
                          )
                    )
                )
            )
        FROM actor a CROSS JOIN target t
    ), FALSE);
$function$;


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
        SELECT 1 FROM admin.portal_users
        WHERE portal_user_id = p_actor_portal_user_id
          AND is_active AND role_code = 'ADMIN'
    ) THEN
        RAISE EXCEPTION 'Portal actor is not authorized to manage users.'
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
        COALESCE(array_agg(a.site_id ORDER BY a.site_id)
            FILTER (WHERE a.site_id IS NOT NULL), ARRAY[]::UUID[]),
        target.is_active,
        target.created_at,
        target.updated_at
    FROM admin.portal_users target
    LEFT JOIN admin.portal_user_site_access a
      ON a.portal_user_id = target.portal_user_id
    WHERE admin.portal_user_scope_contains_user(
        p_actor_portal_user_id, target.portal_user_id
    )
    GROUP BY target.portal_user_id
    ORDER BY target.display_name, target.username, target.portal_user_id;
END;
$function$;


DROP FUNCTION IF EXISTS admin.create_managed_portal_user(BIGINT,TEXT,TEXT,TEXT,TEXT,TEXT,UUID);
CREATE OR REPLACE FUNCTION admin.create_managed_portal_user
(
    p_actor_portal_user_id BIGINT,
    p_username TEXT,
    p_display_name TEXT,
    p_email TEXT,
    p_password_hash TEXT,
    p_role_code TEXT,
    p_access_scope_mode TEXT,
    p_organization_id UUID,
    p_site_ids UUID[]
)
RETURNS BIGINT
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO pg_catalog, admin, metadata
AS $function$
DECLARE
    v_actor admin.portal_users%ROWTYPE;
    v_portal_user_id BIGINT;
    v_site_ids UUID[];
    v_invalid_count BIGINT;
BEGIN
    SELECT * INTO v_actor FROM admin.portal_users
    WHERE portal_user_id = p_actor_portal_user_id AND is_active;

    IF NOT FOUND OR v_actor.role_code <> 'ADMIN' THEN
        RAISE EXCEPTION 'Portal actor is not authorized to create users.'
            USING ERRCODE = '42501';
    END IF;

    IF p_role_code NOT IN ('ADMIN','OPERATOR','VIEWER') THEN
        RAISE EXCEPTION 'Invalid portal role.' USING ERRCODE = '22023';
    END IF;

    SELECT COALESCE(array_agg(DISTINCT x ORDER BY x), ARRAY[]::UUID[])
      INTO v_site_ids
      FROM unnest(COALESCE(p_site_ids, ARRAY[]::UUID[])) x
     WHERE x IS NOT NULL;

    IF p_access_scope_mode = 'GLOBAL' THEN
        IF p_organization_id IS NOT NULL OR cardinality(v_site_ids) <> 0 THEN
            RAISE EXCEPTION 'GLOBAL scope requires no organization and no site assignments.';
        END IF;
    ELSIF p_access_scope_mode = 'ORGANIZATION' THEN
        IF p_organization_id IS NULL OR cardinality(v_site_ids) <> 0 THEN
            RAISE EXCEPTION 'ORGANIZATION scope requires an organization and no site assignments.';
        END IF;
    ELSIF p_access_scope_mode = 'SELECTED_SITES' THEN
        IF p_organization_id IS NULL OR cardinality(v_site_ids) = 0 THEN
            RAISE EXCEPTION 'SELECTED_SITES scope requires an organization and at least one site.';
        END IF;
    ELSE
        RAISE EXCEPTION 'Invalid portal access scope mode.' USING ERRCODE = '22023';
    END IF;

    IF v_actor.access_scope_mode = 'ORGANIZATION' AND (
        p_access_scope_mode = 'GLOBAL'
        OR p_organization_id IS DISTINCT FROM v_actor.organization_id
    ) THEN
        RAISE EXCEPTION 'Target scope is outside the actor organization.' USING ERRCODE='42501';
    ELSIF v_actor.access_scope_mode = 'SELECTED_SITES' THEN
        IF p_access_scope_mode <> 'SELECTED_SITES'
           OR p_organization_id IS DISTINCT FROM v_actor.organization_id
           OR EXISTS (
                SELECT 1 FROM unnest(v_site_ids) requested(site_id)
                WHERE NOT EXISTS (
                    SELECT 1 FROM admin.portal_user_site_access actor_site
                    WHERE actor_site.portal_user_id = p_actor_portal_user_id
                      AND actor_site.site_id = requested.site_id
                )
           ) THEN
            RAISE EXCEPTION 'Target scope is outside the actor selected sites.' USING ERRCODE='42501';
        END IF;
    END IF;

    SELECT count(*) INTO v_invalid_count
    FROM unnest(v_site_ids) requested(site_id)
    LEFT JOIN metadata.sites s ON s.id=requested.site_id
      AND s.organization_id=p_organization_id AND s.is_active
    WHERE s.id IS NULL;
    IF v_invalid_count <> 0 THEN
        RAISE EXCEPTION 'Every selected site must be active and belong to the target organization.';
    END IF;

    INSERT INTO admin.portal_users
    (username,display_name,email,password_hash,role_code,organization_id,access_scope_mode,created_by)
    VALUES
    (lower(btrim(p_username)),btrim(p_display_name),NULLIF(btrim(p_email),''),p_password_hash,
     p_role_code,p_organization_id,p_access_scope_mode,p_actor_portal_user_id::TEXT)
    RETURNING portal_user_id INTO v_portal_user_id;

    IF p_access_scope_mode = 'SELECTED_SITES' THEN
        INSERT INTO admin.portal_user_site_access(portal_user_id,site_id,created_by_portal_user_id)
        SELECT v_portal_user_id, x, p_actor_portal_user_id FROM unnest(v_site_ids) x;
    END IF;

    INSERT INTO admin.portal_user_audit
    (actor_portal_user_id,target_portal_user_id,organization_id,event_type,new_role_code,event_payload)
    VALUES
    (p_actor_portal_user_id,v_portal_user_id,p_organization_id,'USER_CREATED',p_role_code,
     jsonb_build_object('username',lower(btrim(p_username)),'display_name',btrim(p_display_name),
       'email',NULLIF(btrim(p_email),''),'access_scope_mode',p_access_scope_mode,
       'site_ids',to_jsonb(v_site_ids),'is_active',TRUE));

    RETURN v_portal_user_id;
END;
$function$;


DROP FUNCTION IF EXISTS admin.change_managed_portal_user_role(BIGINT,BIGINT,TEXT,UUID);
CREATE OR REPLACE FUNCTION admin.change_managed_portal_user_role
(
    p_actor_portal_user_id BIGINT,
    p_target_portal_user_id BIGINT,
    p_new_role_code TEXT
)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO pg_catalog, admin
AS $function$
DECLARE
    v_previous_role TEXT;
    v_org UUID;
BEGIN
    IF p_new_role_code NOT IN ('ADMIN','OPERATOR','VIEWER') THEN
        RAISE EXCEPTION 'Invalid portal role.' USING ERRCODE='22023';
    END IF;
    IF NOT admin.portal_user_scope_contains_user(p_actor_portal_user_id,p_target_portal_user_id) THEN
        RAISE EXCEPTION 'Portal actor is not authorized to change this user role.' USING ERRCODE='42501';
    END IF;
    SELECT role_code,organization_id INTO v_previous_role,v_org
    FROM admin.portal_users WHERE portal_user_id=p_target_portal_user_id FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'Target portal user was not found.'; END IF;
    UPDATE admin.portal_users SET role_code=p_new_role_code,updated_at=clock_timestamp()
    WHERE portal_user_id=p_target_portal_user_id;
    IF v_previous_role IS DISTINCT FROM p_new_role_code THEN
        INSERT INTO admin.portal_user_audit
        (actor_portal_user_id,target_portal_user_id,organization_id,event_type,previous_role_code,new_role_code,event_payload)
        VALUES(p_actor_portal_user_id,p_target_portal_user_id,v_org,'USER_ROLE_CHANGED',v_previous_role,p_new_role_code,'{}'::jsonb);
    END IF;
END;
$function$;


DROP FUNCTION IF EXISTS admin.set_managed_portal_user_access_scope(BIGINT,BIGINT,TEXT,UUID[]);
CREATE OR REPLACE FUNCTION admin.set_managed_portal_user_access_scope
(
    p_actor_portal_user_id BIGINT,
    p_target_portal_user_id BIGINT,
    p_access_scope_mode TEXT,
    p_organization_id UUID,
    p_site_ids UUID[]
)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO pg_catalog, admin, metadata
AS $function$
DECLARE
    v_actor admin.portal_users%ROWTYPE;
    v_target admin.portal_users%ROWTYPE;
    v_previous_sites UUID[];
    v_sites UUID[];
    v_invalid BIGINT;
BEGIN
    SELECT * INTO v_actor FROM admin.portal_users
    WHERE portal_user_id=p_actor_portal_user_id AND is_active;
    SELECT * INTO v_target FROM admin.portal_users
    WHERE portal_user_id=p_target_portal_user_id FOR UPDATE;
    IF v_actor.role_code IS DISTINCT FROM 'ADMIN' OR v_target.portal_user_id IS NULL THEN
        RAISE EXCEPTION 'Portal actor is not authorized to change user access scope.' USING ERRCODE='42501';
    END IF;

    SELECT COALESCE(array_agg(DISTINCT x ORDER BY x),ARRAY[]::UUID[]) INTO v_sites
    FROM unnest(COALESCE(p_site_ids,ARRAY[]::UUID[])) x WHERE x IS NOT NULL;

    IF p_access_scope_mode='GLOBAL' THEN
        IF p_organization_id IS NOT NULL OR cardinality(v_sites)<>0 THEN RAISE EXCEPTION 'GLOBAL scope requires no organization and no site assignments.'; END IF;
    ELSIF p_access_scope_mode='ORGANIZATION' THEN
        IF p_organization_id IS NULL OR cardinality(v_sites)<>0 THEN RAISE EXCEPTION 'ORGANIZATION scope requires an organization and no site assignments.'; END IF;
    ELSIF p_access_scope_mode='SELECTED_SITES' THEN
        IF p_organization_id IS NULL OR cardinality(v_sites)=0 THEN RAISE EXCEPTION 'SELECTED_SITES scope requires an organization and at least one site.'; END IF;
    ELSE RAISE EXCEPTION 'Invalid portal access scope mode.'; END IF;

    IF v_actor.access_scope_mode='ORGANIZATION' AND (p_access_scope_mode='GLOBAL' OR p_organization_id IS DISTINCT FROM v_actor.organization_id) THEN
        RAISE EXCEPTION 'Target scope is outside the actor organization.' USING ERRCODE='42501';
    ELSIF v_actor.access_scope_mode='SELECTED_SITES' AND (
        p_access_scope_mode<>'SELECTED_SITES' OR p_organization_id IS DISTINCT FROM v_actor.organization_id
        OR EXISTS (SELECT 1 FROM unnest(v_sites) r(site_id) WHERE NOT EXISTS (
            SELECT 1 FROM admin.portal_user_site_access a WHERE a.portal_user_id=p_actor_portal_user_id AND a.site_id=r.site_id
        ))) THEN
        RAISE EXCEPTION 'Target scope is outside the actor selected sites.' USING ERRCODE='42501';
    END IF;

    SELECT count(*) INTO v_invalid FROM unnest(v_sites) r(site_id)
    LEFT JOIN metadata.sites s ON s.id=r.site_id AND s.organization_id=p_organization_id AND s.is_active
    WHERE s.id IS NULL;
    IF v_invalid<>0 THEN RAISE EXCEPTION 'Every selected site must be active and belong to the target organization.'; END IF;

    SELECT COALESCE(array_agg(site_id ORDER BY site_id),ARRAY[]::UUID[]) INTO v_previous_sites
    FROM admin.portal_user_site_access WHERE portal_user_id=p_target_portal_user_id;
    DELETE FROM admin.portal_user_site_access WHERE portal_user_id=p_target_portal_user_id;
    UPDATE admin.portal_users SET organization_id=p_organization_id,access_scope_mode=p_access_scope_mode,updated_at=clock_timestamp()
    WHERE portal_user_id=p_target_portal_user_id;
    IF p_access_scope_mode='SELECTED_SITES' THEN
        INSERT INTO admin.portal_user_site_access(portal_user_id,site_id,created_by_portal_user_id)
        SELECT p_target_portal_user_id,x,p_actor_portal_user_id FROM unnest(v_sites)x;
    END IF;
    INSERT INTO admin.portal_user_audit
    (actor_portal_user_id,target_portal_user_id,organization_id,event_type,previous_role_code,new_role_code,event_payload)
    VALUES(p_actor_portal_user_id,p_target_portal_user_id,p_organization_id,'USER_SCOPE_CHANGED',v_target.role_code,v_target.role_code,
      jsonb_build_object('previous_access_scope_mode',v_target.access_scope_mode,'new_access_scope_mode',p_access_scope_mode,
      'previous_organization_id',v_target.organization_id,'new_organization_id',p_organization_id,
      'previous_site_ids',to_jsonb(v_previous_sites),'new_site_ids',to_jsonb(v_sites)));
END;
$function$;


CREATE OR REPLACE FUNCTION admin.set_managed_portal_user_active
(p_actor_portal_user_id BIGINT,p_target_portal_user_id BIGINT,p_is_active BOOLEAN)
RETURNS VOID LANGUAGE plpgsql SECURITY DEFINER SET search_path TO pg_catalog,admin AS $function$
DECLARE v_org UUID; v_before BOOLEAN;
BEGIN
    IF NOT admin.portal_user_scope_contains_user(p_actor_portal_user_id,p_target_portal_user_id) THEN
        RAISE EXCEPTION 'Portal actor is not authorized to change this user status.' USING ERRCODE='42501';
    END IF;
    SELECT organization_id,is_active INTO v_org,v_before FROM admin.portal_users
    WHERE portal_user_id=p_target_portal_user_id FOR UPDATE;
    UPDATE admin.portal_users SET is_active=p_is_active,updated_at=clock_timestamp()
    WHERE portal_user_id=p_target_portal_user_id;
    IF v_before IS DISTINCT FROM p_is_active THEN
      INSERT INTO admin.portal_user_audit(actor_portal_user_id,target_portal_user_id,organization_id,event_type,event_payload)
      VALUES(p_actor_portal_user_id,p_target_portal_user_id,v_org,'USER_STATUS_CHANGED',
      jsonb_build_object('previous_is_active',v_before,'new_is_active',p_is_active));
    END IF;
END;$function$;


-- Replaced legacy authorization function: apply_grafana_reconciliation_mapping
CREATE OR REPLACE FUNCTION admin.apply_grafana_reconciliation_mapping(p_actor_portal_user_id bigint, p_organization_id uuid, p_grafana_org_id bigint, p_repair_reason text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'admin', 'metadata'
AS $function$
DECLARE
    v_role TEXT;
    v_scope_mode TEXT;
    v_existing_grafana_org_id BIGINT;
    v_owner_organization_id UUID;
    v_org_name TEXT;
    v_transaction_id UUID := gen_random_uuid();
BEGIN
    IF p_grafana_org_id IS NULL OR p_grafana_org_id <= 0 THEN
        RAISE EXCEPTION 'Grafana organization ID must be a positive integer.'
            USING ERRCODE = '22023';
    END IF;

    IF nullif(btrim(p_repair_reason), '') IS NULL THEN
        RAISE EXCEPTION 'A reconciliation repair reason is required.'
            USING ERRCODE = '22023';
    END IF;

    SELECT role_code, access_scope_mode INTO v_role, v_scope_mode
    FROM admin.portal_users
    WHERE portal_user_id = p_actor_portal_user_id
      AND is_active;

    IF v_role IS DISTINCT FROM 'ADMIN' OR v_scope_mode IS DISTINCT FROM 'GLOBAL' THEN
        RAISE EXCEPTION 'Only a platform administrator may reconcile Grafana tenants.'
            USING ERRCODE = '42501';
    END IF;

    SELECT name INTO v_org_name
    FROM metadata.organizations
    WHERE id = p_organization_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'EMS organization % does not exist.', p_organization_id
            USING ERRCODE = '23503';
    END IF;

    SELECT grafana_org_id INTO v_existing_grafana_org_id
    FROM metadata.grafana_organization_map
    WHERE organization_id = p_organization_id
      AND is_active;

    IF v_existing_grafana_org_id IS NOT NULL
       AND v_existing_grafana_org_id <> p_grafana_org_id THEN
        RAISE EXCEPTION
            'Automatic Grafana tenant reassignment is prohibited: EMS organization % is already mapped to Grafana org %.',
            p_organization_id, v_existing_grafana_org_id
            USING ERRCODE = '23505';
    END IF;

    SELECT organization_id INTO v_owner_organization_id
    FROM metadata.grafana_organization_map
    WHERE grafana_org_id = p_grafana_org_id
      AND is_active;

    IF v_owner_organization_id IS NOT NULL
       AND v_owner_organization_id <> p_organization_id THEN
        RAISE EXCEPTION
            'Automatic cross-tenant reassignment is prohibited: Grafana org % belongs to EMS organization %.',
            p_grafana_org_id, v_owner_organization_id
            USING ERRCODE = '23505';
    END IF;

    INSERT INTO metadata.grafana_organization_map(
        grafana_org_id, organization_id, is_active
    ) VALUES (
        p_grafana_org_id, p_organization_id, TRUE
    )
    ON CONFLICT (grafana_org_id) DO UPDATE SET
        is_active = TRUE,
        updated_at = clock_timestamp()
    WHERE metadata.grafana_organization_map.organization_id = EXCLUDED.organization_id;

    INSERT INTO admin.grafana_organization_provisioning(
        organization_id, provisioning_status, grafana_org_id,
        attempt_count, last_attempt_at, provisioned_at, last_error
    ) VALUES (
        p_organization_id, 'PROVISIONED', p_grafana_org_id,
        1, clock_timestamp(), clock_timestamp(), NULL
    )
    ON CONFLICT (organization_id) DO UPDATE SET
        provisioning_status = 'PROVISIONED',
        grafana_org_id = EXCLUDED.grafana_org_id,
        provisioned_at = clock_timestamp(),
        last_error = NULL,
        updated_at = clock_timestamp();

    PERFORM admin.write_audit_event(
        v_transaction_id,
        p_actor_portal_user_id,
        'RECONCILE_GRAFANA_TENANT',
        'ORGANIZATION',
        p_organization_id,
        p_organization_id,
        NULL,
        jsonb_build_object('grafana_org_id', v_existing_grafana_org_id),
        jsonb_build_object(
            'grafana_org_id', p_grafana_org_id,
            'organization_name', v_org_name,
            'repair_reason', btrim(p_repair_reason)
        ),
        'SUCCEEDED',
        NULL
    );

    RETURN jsonb_build_object(
        'success', TRUE,
        'organization_id', p_organization_id,
        'organization_name', v_org_name,
        'grafana_org_id', p_grafana_org_id,
        'reconciliation_status', 'REPAIRED',
        'audit_transaction_id', v_transaction_id
    );
END;
$function$;


-- Replaced legacy authorization function: create_organization_workspace
CREATE OR REPLACE FUNCTION admin.create_organization_workspace(p_actor_portal_user_id bigint, p_requested_by text, p_name text, p_code text, p_legal_name text, p_timezone text, p_locale text, p_lifecycle_status text, p_primary_contact jsonb, p_address jsonb, p_notes text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'admin', 'metadata'
AS $function$
DECLARE
    v_actor admin.portal_users%ROWTYPE;
    v_result JSONB;
    v_organization_id UUID;
BEGIN
    SELECT *
      INTO v_actor
      FROM admin.portal_users
     WHERE portal_user_id = p_actor_portal_user_id
       AND is_active;

    IF NOT FOUND OR v_actor.role_code <> 'ADMIN' OR v_actor.access_scope_mode <> 'GLOBAL' THEN
        RAISE EXCEPTION 'Only a platform administrator may create organizations.'
            USING ERRCODE = '42501';
    END IF;

    SELECT admin.create_organization(
        p_name,
        p_code,
        p_timezone,
        p_lifecycle_status,
        COALESCE(NULLIF(btrim(p_requested_by), ''), v_actor.username)
    )
    INTO v_result;

    v_organization_id := (v_result->>'organization_id')::uuid;

    UPDATE metadata.organizations
       SET legal_name = NULLIF(btrim(p_legal_name), ''),
           locale = COALESCE(NULLIF(btrim(p_locale), ''), 'en-US'),
           primary_contact = COALESCE(p_primary_contact, '{}'::jsonb),
           address = COALESCE(p_address, '{}'::jsonb),
           notes = NULLIF(btrim(p_notes), ''),
           updated_at = now()
     WHERE id = v_organization_id;

    RETURN admin.get_organization_workspace(
        p_actor_portal_user_id,
        v_organization_id
    );
END;
$function$;


-- Replaced legacy authorization function: create_site
CREATE OR REPLACE FUNCTION admin.create_site(p_actor_portal_user_id bigint, p_organization_id uuid, p_name text, p_code text, p_timezone text, p_lifecycle_status text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'admin', 'metadata', 'config'
AS $function$
DECLARE
    v_actor_username TEXT;
    v_actor_role TEXT;
    v_actor_organization_id UUID;
    v_actor_scope_mode TEXT;
    v_name TEXT := btrim(p_name);
    v_code TEXT := upper(btrim(p_code));
    v_timezone TEXT := btrim(p_timezone);
    v_status TEXT := upper(btrim(p_lifecycle_status));
    v_site_id UUID;
    v_audit_id UUID := gen_random_uuid();
    v_request JSONB;
    v_result JSONB;
BEGIN
    SELECT
        portal_user.username,
        portal_user.role_code,
        portal_user.organization_id,
        portal_user.access_scope_mode
    INTO
        v_actor_username,
        v_actor_role,
        v_actor_organization_id,
        v_actor_scope_mode
    FROM admin.portal_users AS portal_user
    WHERE portal_user.portal_user_id = p_actor_portal_user_id
      AND portal_user.is_active = TRUE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Active portal actor was not found.'
            USING ERRCODE = '42501';
    END IF;

    IF NOT admin.portal_user_has_permission(
        p_actor_portal_user_id,
        'site.manage'
    ) THEN
        RAISE EXCEPTION 'Portal actor is not authorized to create sites.'
            USING ERRCODE = '42501';
    END IF;

    IF p_organization_id IS NULL THEN
        RAISE EXCEPTION 'Select an organization.'
            USING ERRCODE = '22023';
    END IF;

    PERFORM 1
    FROM metadata.organizations AS organization_record
    WHERE organization_record.id = p_organization_id
      AND organization_record.is_active = TRUE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Select an active organization.'
            USING ERRCODE = '22023';
    END IF;

    IF v_actor_scope_mode <> 'GLOBAL' THEN
        IF v_actor_organization_id IS DISTINCT FROM p_organization_id THEN
            RAISE EXCEPTION
                'Portal actor cannot create a site for another organization.'
                USING ERRCODE = '42501';
        END IF;

        IF v_actor_scope_mode <> 'ORGANIZATION' THEN
            RAISE EXCEPTION
                'Selected-site access cannot create a new organization site.'
                USING ERRCODE = '42501';
        END IF;
    END IF;

    IF v_name IS NULL OR v_name = '' THEN
        RAISE EXCEPTION 'Site name is required.'
            USING ERRCODE = '22023';
    END IF;

    IF length(v_name) > 200 THEN
        RAISE EXCEPTION 'Site name must not exceed 200 characters.'
            USING ERRCODE = '22023';
    END IF;

    IF v_code IS NULL OR v_code = '' THEN
        RAISE EXCEPTION 'Site code is required.'
            USING ERRCODE = '22023';
    END IF;

    IF length(v_code) > 100 OR v_code !~ '^[A-Z][A-Z0-9_]*$' THEN
        RAISE EXCEPTION
            'Site code must start with A-Z and contain only A-Z, 0-9, and underscore.'
            USING ERRCODE = '22023';
    END IF;

    IF v_timezone IS NULL
       OR v_timezone = ''
       OR length(v_timezone) > 100
       OR NOT EXISTS
       (
           SELECT 1
           FROM pg_timezone_names
           WHERE name = v_timezone
       ) THEN
        RAISE EXCEPTION 'Select a valid IANA timezone.'
            USING ERRCODE = '22023';
    END IF;

    IF v_status NOT IN
       ('DRAFT', 'ACTIVE', 'INACTIVE', 'DECOMMISSIONED') THEN
        RAISE EXCEPTION 'Select a valid site lifecycle status.'
            USING ERRCODE = '22023';
    END IF;

    BEGIN
        INSERT INTO metadata.sites
        (
            organization_id,
            name,
            code,
            timezone,
            is_active,
            lifecycle_status
        )
        VALUES
        (
            p_organization_id,
            v_name,
            v_code,
            v_timezone,
            v_status = 'ACTIVE',
            v_status
        )
        RETURNING id INTO v_site_id;
    EXCEPTION
        WHEN unique_violation THEN
            RAISE EXCEPTION
                'Site code % already exists in the selected organization.',
                v_code
                USING ERRCODE = '23505';
    END;

    v_request := jsonb_build_object
    (
        'operation', 'CREATE_SITE',
        'actor_portal_user_id', p_actor_portal_user_id,
        'organization_id', p_organization_id,
        'name', v_name,
        'code', v_code,
        'timezone', v_timezone,
        'lifecycle_status', v_status
    );

    v_result := jsonb_build_object
    (
        'success', TRUE,
        'entity_type', 'SITE',
        'entity_id', v_site_id,
        'lifecycle_status', v_status,
        'commissioning_status', NULL,
        'validation_warnings', '[]'::jsonb,
        'blocking_conditions', '[]'::jsonb,
        'audit_transaction_id', v_audit_id,
        'organization_id', p_organization_id,
        'site_id', v_site_id,
        'site_code', v_code,
        'site_name', v_name,
        'timezone', v_timezone
    );

    INSERT INTO admin.onboarding_audit
    (
        id,
        requested_by,
        request_payload,
        result_payload
    )
    VALUES
    (
        v_audit_id,
        v_actor_username,
        v_request,
        v_result
    );

    RETURN v_result;
END;
$function$;


-- Replaced legacy authorization function: get_grafana_reconciliation_context
CREATE OR REPLACE FUNCTION admin.get_grafana_reconciliation_context(p_actor_portal_user_id bigint, p_organization_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'admin', 'metadata'
AS $function$
DECLARE
    v_role TEXT;
    v_scope_mode TEXT;
    v_result JSONB;
BEGIN
    SELECT role_code, access_scope_mode INTO v_role, v_scope_mode
    FROM admin.portal_users
    WHERE portal_user_id = p_actor_portal_user_id
      AND is_active;

    IF v_role IS DISTINCT FROM 'ADMIN' OR v_scope_mode IS DISTINCT FROM 'GLOBAL' THEN
        RAISE EXCEPTION 'Only a platform administrator may reconcile Grafana tenants.'
            USING ERRCODE = '42501';
    END IF;

    SELECT jsonb_build_object(
        'organization_id', o.id,
        'organization_code', o.code,
        'organization_name', o.name,
        'lifecycle_status', o.lifecycle_status,
        'mapped_grafana_org_id', gom.grafana_org_id,
        'provisioning_grafana_org_id', gp.grafana_org_id,
        'provisioning_status', coalesce(gp.provisioning_status, 'NOT_STARTED'),
        'database_mapping_mismatch', (
            gom.grafana_org_id IS NOT NULL
            AND gp.grafana_org_id IS DISTINCT FROM gom.grafana_org_id
        )
    )
    INTO v_result
    FROM metadata.organizations o
    LEFT JOIN metadata.grafana_organization_map gom
      ON gom.organization_id = o.id AND gom.is_active
    LEFT JOIN admin.grafana_organization_provisioning gp
      ON gp.organization_id = o.id
    WHERE o.id = p_organization_id;

    IF v_result IS NULL THEN
        RAISE EXCEPTION 'EMS organization % does not exist.', p_organization_id
            USING ERRCODE = '23503';
    END IF;

    RETURN v_result;
END;
$function$;


-- Replaced legacy authorization function: get_onboarding_draft
CREATE OR REPLACE FUNCTION admin.get_onboarding_draft(p_draft_token uuid, p_portal_user_id bigint, p_role_code text)
 RETURNS TABLE(draft_token uuid, current_step text, status text, payload jsonb, requested_by text, owner_portal_user_id bigint, created_at timestamp with time zone, updated_at timestamp with time zone, expires_at timestamp with time zone)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'admin'
AS $function$
    SELECT
        draft.draft_token,
        draft.current_step,
        draft.status,
        draft.payload,
        draft.requested_by,
        draft.owner_portal_user_id,
        draft.created_at,
        draft.updated_at,
        draft.expires_at
    FROM admin.onboarding_drafts AS draft
    JOIN admin.portal_users AS portal_user
      ON portal_user.portal_user_id = p_portal_user_id
     AND portal_user.is_active = true
     AND portal_user.role_code = p_role_code
    WHERE draft.draft_token = p_draft_token
      AND draft.status = 'DRAFT'
      AND draft.expires_at > clock_timestamp()
      AND (
          portal_user.access_scope_mode = 'GLOBAL'
          OR draft.owner_portal_user_id =
             portal_user.portal_user_id
      );
$function$;


-- Replaced legacy authorization function: get_organization_workspace
CREATE OR REPLACE FUNCTION admin.get_organization_workspace(p_actor_portal_user_id bigint, p_organization_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'admin', 'metadata'
AS $function$
DECLARE
    v_actor admin.portal_users%ROWTYPE;
    v_org metadata.organizations%ROWTYPE;
BEGIN
    SELECT *
      INTO v_actor
      FROM admin.portal_users
     WHERE portal_user_id = p_actor_portal_user_id
       AND is_active;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'The administration actor is not active.'
            USING ERRCODE = '42501';
    END IF;

    IF v_actor.role_code <> 'ADMIN' OR (v_actor.access_scope_mode <> 'GLOBAL'
       AND v_actor.organization_id IS DISTINCT FROM p_organization_id ) THEN
        RAISE EXCEPTION 'The organization is outside the administration scope.'
            USING ERRCODE = '42501';
    END IF;

    SELECT *
      INTO v_org
      FROM metadata.organizations
     WHERE id = p_organization_id;

    IF NOT FOUND THEN
        RETURN NULL;
    END IF;

    RETURN jsonb_build_object(
        'organization_id', v_org.id,
        'organization_name', v_org.name,
        'organization_code', v_org.code,
        'legal_name', v_org.legal_name,
        'timezone', v_org.timezone,
        'locale', v_org.locale,
        'lifecycle_status', v_org.lifecycle_status,
        'is_active', v_org.is_active,
        'primary_contact', v_org.primary_contact,
        'address', v_org.address,
        'notes', v_org.notes,
        'created_at', v_org.created_at,
        'updated_at', v_org.updated_at
    );
END;
$function$;


-- Replaced legacy authorization function: get_submitted_onboarding_result
CREATE OR REPLACE FUNCTION admin.get_submitted_onboarding_result(p_draft_token uuid, p_portal_user_id bigint, p_role_code text)
 RETURNS TABLE(draft_token uuid, status text, requested_by text, owner_portal_user_id bigint, created_at timestamp with time zone, submitted_at timestamp with time zone, payload jsonb, result jsonb)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'admin'
AS $function$
    SELECT
        draft.draft_token,
        draft.status,
        draft.requested_by,
        draft.owner_portal_user_id,
        draft.created_at,
        NULLIF(
            draft.payload #>> '{review,submitted_at}',
            ''
        )::timestamptz AS submitted_at,
        draft.payload,
        draft.payload #> '{review,result}' AS result
    FROM admin.onboarding_drafts AS draft
    JOIN admin.portal_users AS portal_user
      ON portal_user.portal_user_id = p_portal_user_id
     AND portal_user.is_active = true
     AND portal_user.role_code = p_role_code
    WHERE draft.draft_token = p_draft_token
      AND draft.status = 'SUBMITTED'
      AND draft.payload #> '{review,result}' IS NOT NULL
      AND (
          portal_user.access_scope_mode = 'GLOBAL'
          OR draft.owner_portal_user_id =
             portal_user.portal_user_id
      );
$function$;


-- Replaced legacy authorization function: list_accessible_audit_events
CREATE OR REPLACE FUNCTION admin.list_accessible_audit_events(p_actor_portal_user_id bigint, p_organization_id uuid DEFAULT NULL::uuid, p_site_id uuid DEFAULT NULL::uuid, p_entity_type text DEFAULT NULL::text, p_limit integer DEFAULT 200)
 RETURNS SETOF admin.audit_events
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'admin', 'metadata'
AS $function$
SELECT event_record.*
FROM admin.audit_events AS event_record
JOIN admin.portal_users AS actor
  ON actor.portal_user_id = p_actor_portal_user_id
 AND actor.is_active = TRUE
WHERE (p_organization_id IS NULL OR event_record.organization_id = p_organization_id)
  AND (p_site_id IS NULL OR event_record.site_id = p_site_id)
  AND (p_entity_type IS NULL OR event_record.entity_type = upper(btrim(p_entity_type)))
  AND (
      actor.access_scope_mode = 'GLOBAL'
      OR (
          event_record.site_id IS NOT NULL
          AND admin.portal_user_can_access_site(p_actor_portal_user_id, event_record.site_id)
      )
      OR (
          event_record.site_id IS NULL
          AND event_record.organization_id = actor.organization_id
      )
  )
ORDER BY event_record.occurred_at DESC
LIMIT LEAST(GREATEST(COALESCE(p_limit, 200), 1), 1000);
$function$;


-- Replaced legacy authorization function: list_accessible_physical_locations
CREATE OR REPLACE FUNCTION admin.list_accessible_physical_locations(p_actor_portal_user_id bigint)
 RETURNS TABLE(organization_id uuid, organization_code text, organization_name text, site_id uuid, site_code text, site_name text, building_id uuid, building_code text, building_name text, floor_id uuid, floor_code text, floor_name text, space_id uuid, space_code text, space_name text)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'admin', 'metadata'
AS $function$
    SELECT
        site_record.organization_id,
        organization_record.code AS organization_code,
        organization_record.name AS organization_name,
        site_record.id AS site_id,
        site_record.code AS site_code,
        site_record.name AS site_name,
        building.id AS building_id,
        building.code AS building_code,
        building.name AS building_name,
        floor_record.id AS floor_id,
        floor_record.code AS floor_code,
        floor_record.name AS floor_name,
        space_record.id AS space_id,
        space_record.code AS space_code,
        space_record.name AS space_name
    FROM metadata.sites AS site_record
    JOIN metadata.organizations AS organization_record
      ON organization_record.id =
          site_record.organization_id
    JOIN admin.portal_users AS portal_user
      ON portal_user.portal_user_id =
          p_actor_portal_user_id
    LEFT JOIN metadata.buildings AS building
      ON building.site_id = site_record.id
    LEFT JOIN metadata.floors AS floor_record
      ON floor_record.building_id = building.id
    LEFT JOIN metadata.spaces AS space_record
      ON space_record.floor_id = floor_record.id
    WHERE portal_user.is_active = TRUE
      AND site_record.lifecycle_status
          IN ('DRAFT', 'ACTIVE')
      AND
      (
          portal_user.access_scope_mode = 'GLOBAL'
          OR
          (
              portal_user.organization_id =
                  site_record.organization_id
              AND
              (
                  portal_user.access_scope_mode =
                      'ORGANIZATION'
                  OR
                  (
                      portal_user.access_scope_mode =
                          'SELECTED_SITES'
                      AND EXISTS
                      (
                          SELECT 1
                          FROM admin.portal_user_site_access
                              AS assignment
                          WHERE assignment.portal_user_id =
                              portal_user.portal_user_id
                            AND assignment.site_id =
                              site_record.id
                      )
                  )
              )
          )
      )
    ORDER BY
        organization_record.name,
        site_record.name,
        building.name NULLS FIRST,
        floor_record.name NULLS FIRST,
        space_record.name NULLS FIRST;
$function$;


-- Replaced legacy authorization function: list_accessible_reconciliation_queue
CREATE OR REPLACE FUNCTION admin.list_accessible_reconciliation_queue(p_actor_portal_user_id bigint, p_organization_id uuid DEFAULT NULL::uuid, p_site_id uuid DEFAULT NULL::uuid, p_issue_type text DEFAULT NULL::text)
 RETURNS TABLE(issue_key text, issue_type text, severity text, organization_id uuid, organization_name text, site_id uuid, site_name text, entity_type text, entity_id uuid, entity_name text, issue_status text, issue_detail text, action_path text, action_label text)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'admin', 'metadata', 'analytics'
AS $function$
WITH actor AS (
    SELECT pu.role_code, pu.organization_id, pu.access_scope_mode
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
    WHERE a.role_code = 'ADMIN' AND a.access_scope_mode = 'GLOBAL'
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


-- Replaced legacy authorization function: save_onboarding_draft_step
CREATE OR REPLACE FUNCTION admin.save_onboarding_draft_step(p_draft_token uuid, p_step text, p_step_payload jsonb, p_next_step text, p_portal_user_id bigint, p_role_code text, p_requested_by text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'admin'
AS $function$
DECLARE
    v_draft_token uuid;
    v_event_type text;
    v_actor text;
    v_verified_username text;
BEGIN
    SELECT portal_user.username
    INTO v_verified_username
    FROM admin.portal_users AS portal_user
    WHERE portal_user.portal_user_id = p_portal_user_id
      AND portal_user.is_active = true
      AND portal_user.role_code = p_role_code;

    IF v_verified_username IS NULL THEN
        RAISE EXCEPTION
            'Authenticated portal identity is invalid or stale.';
    END IF;

    v_actor := COALESCE(
        NULLIF(btrim(p_requested_by), ''),
        v_verified_username
    );

    IF v_actor <> v_verified_username THEN
        RAISE EXCEPTION
            'Requested actor does not match authenticated portal identity.';
    END IF;

    IF p_role_code NOT IN ('ADMIN', 'OPERATOR') THEN
        RAISE EXCEPTION
            'Portal role is not permitted to edit onboarding drafts.';
    END IF;

    IF p_step NOT IN (
        'organization',
        'site',
        'location',
        'gateway',
        'device',
        'asset',
        'review'
    ) THEN
        RAISE EXCEPTION
            'Unsupported onboarding step: %',
            p_step;
    END IF;

    IF p_next_step NOT IN (
        'organization',
        'site',
        'location',
        'gateway',
        'device',
        'asset',
        'review'
    ) THEN
        RAISE EXCEPTION
            'Unsupported next onboarding step: %',
            p_next_step;
    END IF;

    IF p_step_payload IS NULL
       OR jsonb_typeof(p_step_payload) <> 'object'
    THEN
        RAISE EXCEPTION
            'Onboarding step payload must be a JSON object.';
    END IF;

    IF p_draft_token IS NULL THEN
        INSERT INTO admin.onboarding_drafts
        (
            current_step,
            payload,
            requested_by,
            owner_portal_user_id
        )
        VALUES
        (
            p_next_step,
            jsonb_build_object(
                p_step,
                p_step_payload
            ),
            v_actor,
            p_portal_user_id
        )
        RETURNING onboarding_drafts.draft_token
        INTO v_draft_token;

        v_event_type := 'DRAFT_CREATED';

    ELSE
        UPDATE admin.onboarding_drafts AS draft
        SET
            payload = jsonb_set(
                draft.payload,
                ARRAY[p_step],
                p_step_payload,
                true
            ),
            current_step = p_next_step,
            requested_by = v_actor,
            updated_at = clock_timestamp(),
            expires_at =
                clock_timestamp() + interval '7 days'
        WHERE draft.draft_token = p_draft_token
          AND draft.status = 'DRAFT'
          AND draft.expires_at > clock_timestamp()
          AND (
              EXISTS (SELECT 1 FROM admin.portal_users scope_user WHERE scope_user.portal_user_id = p_portal_user_id AND scope_user.is_active AND scope_user.access_scope_mode = 'GLOBAL')
              OR draft.owner_portal_user_id =
                 p_portal_user_id
          )
        RETURNING draft.draft_token
        INTO v_draft_token;

        IF v_draft_token IS NULL THEN
            RAISE EXCEPTION
                'Onboarding draft was not found, expired, or is not owned by the authenticated user.';
        END IF;

        v_event_type := 'STEP_SAVED';
    END IF;

    PERFORM admin.log_onboarding_event(
        v_draft_token,
        v_event_type,
        p_step,
        v_actor,
        jsonb_build_object(
            'saved_step',
            p_step,
            'resulting_current_step',
            p_next_step,
            'saved_keys',
            COALESCE(
                (
                    SELECT jsonb_agg(key ORDER BY key)
                    FROM jsonb_object_keys(
                        p_step_payload
                    ) AS keys(key)
                ),
                '[]'::jsonb
            )
        )
    );

    RETURN v_draft_token;
END;
$function$;


-- Replaced legacy authorization function: submit_onboarding_draft
CREATE OR REPLACE FUNCTION admin.submit_onboarding_draft(p_draft_token uuid, p_portal_user_id bigint, p_role_code text, p_requested_by text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'admin', 'metadata'
AS $function$
DECLARE
    v_draft_payload jsonb;
    v_device_payload jsonb;
    v_identifier_payload jsonb;
    v_request_payload jsonb;
    v_result jsonb;
    v_requested_by text;
    v_verified_username text;
    v_actor_organization_id uuid;
    v_organization_payload jsonb;
    v_organization_mode text;
    v_existing_organization_id uuid;
    v_existing_organization_name text;
    v_existing_organization_code text;
    v_existing_organization_description text;
    v_site_payload jsonb;
    v_site_mode text;
    v_existing_site_id uuid;
    v_location_payload jsonb;
    v_location_mode text;
    v_existing_space_id uuid;
    v_gateway_payload jsonb;
    v_gateway_mode text;
    v_existing_gateway_id uuid;
    v_device_payload_existing jsonb;
    v_device_mode text;
    v_existing_device_id uuid;
    v_asset_payload jsonb;
    v_asset_mode text;
    v_existing_asset_id uuid;
BEGIN
    IF p_draft_token IS NULL THEN
        RAISE EXCEPTION
            'Onboarding draft token is required.';
    END IF;

    SELECT
        portal_user.username,
        portal_user.organization_id
    INTO
        v_verified_username,
        v_actor_organization_id
    FROM admin.portal_users AS portal_user
    WHERE portal_user.portal_user_id = p_portal_user_id
      AND portal_user.is_active = true
      AND portal_user.role_code = p_role_code;

    IF v_verified_username IS NULL THEN
        RAISE EXCEPTION
            'Authenticated portal identity is invalid or stale.';
    END IF;

    IF p_role_code NOT IN ('ADMIN', 'OPERATOR') THEN
        RAISE EXCEPTION
            'Portal role is not permitted to submit onboarding drafts.';
    END IF;

    v_requested_by := COALESCE(
        NULLIF(btrim(p_requested_by), ''),
        v_verified_username
    );

    IF v_requested_by <> v_verified_username THEN
        RAISE EXCEPTION
            'Requested actor does not match authenticated portal identity.';
    END IF;

    SELECT draft.payload
    INTO v_draft_payload
    FROM admin.onboarding_drafts AS draft
    WHERE draft.draft_token = p_draft_token
      AND draft.status = 'DRAFT'
      AND draft.current_step = 'review'
      AND draft.expires_at > clock_timestamp()
      AND (
          EXISTS (SELECT 1 FROM admin.portal_users scope_user WHERE scope_user.portal_user_id = p_portal_user_id AND scope_user.is_active AND scope_user.access_scope_mode = 'GLOBAL')
          OR draft.owner_portal_user_id =
             p_portal_user_id
      )
    FOR UPDATE;

    IF v_draft_payload IS NULL THEN
        RAISE EXCEPTION
            'Onboarding draft was not found, expired, incomplete, already submitted, or is not owned by the authenticated user.';
    END IF;

    IF NOT (
        v_draft_payload ? 'organization'
        AND v_draft_payload ? 'site'
        AND v_draft_payload ? 'location'
        AND v_draft_payload ? 'gateway'
        AND v_draft_payload ? 'device'
        AND v_draft_payload ? 'asset'
    ) THEN
        RAISE EXCEPTION
            'Onboarding draft is missing one or more required modules.';
    END IF;

    -- Existing-organization drafts intentionally store only the selected ID.
    -- Resolve canonical organization attributes at submission time so the
    -- browser never becomes authoritative for organization identity data.
    v_organization_payload := COALESCE(
        v_draft_payload -> 'organization',
        '{}'::jsonb
    );

    v_organization_mode := upper(
        COALESCE(
            NULLIF(btrim(v_organization_payload ->> 'mode'), ''),
            'CREATE_NEW'
        )
    );

    IF v_organization_mode = 'USE_EXISTING' THEN
        BEGIN
            v_existing_organization_id := (
                v_organization_payload ->> 'existing_organization_id'
            )::uuid;
        EXCEPTION
            WHEN invalid_text_representation THEN
                RAISE EXCEPTION
                    'Select a valid existing organization.'
                    USING ERRCODE = '22023';
        END;

        IF v_existing_organization_id IS NULL THEN
            RAISE EXCEPTION
                'Select an existing organization.'
                USING ERRCODE = '22023';
        END IF;

        SELECT
            organization.name,
            organization.code,
            organization.description
        INTO
            v_existing_organization_name,
            v_existing_organization_code,
            v_existing_organization_description
        FROM metadata.organizations AS organization
        WHERE organization.id = v_existing_organization_id
          AND organization.is_active = true;

        IF v_existing_organization_name IS NULL THEN
            RAISE EXCEPTION
                'The selected organization is unavailable or inactive.'
                USING ERRCODE = 'P0002';
        END IF;

        IF NOT EXISTS (SELECT 1 FROM admin.portal_users scope_user WHERE scope_user.portal_user_id = p_portal_user_id AND scope_user.is_active AND scope_user.access_scope_mode = 'GLOBAL')
           AND v_actor_organization_id IS DISTINCT FROM
               v_existing_organization_id THEN
            RAISE EXCEPTION
                'The selected organization is outside your access scope.'
                USING ERRCODE = '42501';
        END IF;

        v_organization_payload :=
            v_organization_payload
            || jsonb_build_object(
                'mode', 'USE_EXISTING',
                'existing_organization_id',
                    v_existing_organization_id,
                'id', v_existing_organization_id,
                'name', v_existing_organization_name,
                'code', v_existing_organization_code,
                'description',
                    COALESCE(
                        v_existing_organization_description,
                        ''
                    )
            );

        v_draft_payload := jsonb_set(
            v_draft_payload,
            '{organization}',
            v_organization_payload,
            true
        );
    END IF;

    -- Hydrate an existing site and enforce organization ownership.
    v_site_payload := COALESCE(v_draft_payload -> 'site', '{}'::jsonb);
    v_site_mode := upper(COALESCE(NULLIF(btrim(v_site_payload ->> 'mode'), ''), 'CREATE_NEW'));

    IF v_site_mode = 'USE_EXISTING' THEN
        BEGIN
            v_existing_site_id := (v_site_payload ->> 'existing_site_id')::uuid;
        EXCEPTION WHEN invalid_text_representation THEN
            RAISE EXCEPTION 'Select a valid existing site.' USING ERRCODE = '22023';
        END;

        IF v_existing_site_id IS NULL THEN
            RAISE EXCEPTION 'Select an existing site.' USING ERRCODE = '22023';
        END IF;

        SELECT v_site_payload || jsonb_build_object(
                   'mode', 'USE_EXISTING',
                   'existing_site_id', s.id,
                   'id', s.id,
                   'name', s.name,
                   'code', s.code,
                   'timezone', s.timezone,
                   'address', COALESCE(s.address, '{}'::jsonb)
               )
        INTO v_site_payload
        FROM metadata.sites AS s
        WHERE s.id = v_existing_site_id
          AND s.organization_id = v_existing_organization_id
          AND s.is_active = true;

        IF v_site_payload IS NULL THEN
            RAISE EXCEPTION 'The selected site is unavailable or outside the selected organization.'
                USING ERRCODE = 'P0002';
        END IF;

        v_draft_payload := jsonb_set(v_draft_payload, '{site}', v_site_payload, true);
    END IF;

    -- Hydrate the complete physical hierarchy when an existing space is used.
    v_location_payload := COALESCE(v_draft_payload -> 'location', '{}'::jsonb);
    v_location_mode := upper(COALESCE(NULLIF(btrim(v_location_payload ->> 'mode'), ''), 'SITE_ONLY'));

    IF v_location_mode = 'USE_EXISTING_SPACE' THEN
        BEGIN
            v_existing_space_id := (v_location_payload ->> 'existing_space_id')::uuid;
        EXCEPTION WHEN invalid_text_representation THEN
            RAISE EXCEPTION 'Select a valid existing space.' USING ERRCODE = '22023';
        END;

        SELECT v_location_payload || jsonb_build_object(
                   'mode', 'USE_EXISTING_SPACE',
                   'existing_space_id', sp.id,
                   'space_id', sp.id,
                   'space_name', sp.name,
                   'space_code', sp.code,
                   'floor_id', f.id,
                   'floor_name', f.name,
                   'floor_code', f.code,
                   'building_id', b.id,
                   'building_name', b.name,
                   'building_code', b.code
               )
        INTO v_location_payload
        FROM metadata.spaces AS sp
        JOIN metadata.floors AS f ON f.id = sp.floor_id
        JOIN metadata.buildings AS b ON b.id = f.building_id
        WHERE sp.id = v_existing_space_id
          AND sp.organization_id = v_existing_organization_id
          AND b.site_id = v_existing_site_id;

        IF v_location_payload IS NULL THEN
            RAISE EXCEPTION 'The selected space is unavailable or outside the selected site.'
                USING ERRCODE = 'P0002';
        END IF;

        v_draft_payload := jsonb_set(v_draft_payload, '{location}', v_location_payload, true);
    END IF;

    -- Hydrate an existing gateway and verify tenant/site ownership.
    v_gateway_payload := COALESCE(v_draft_payload -> 'gateway', '{}'::jsonb);
    v_gateway_mode := upper(COALESCE(NULLIF(btrim(v_gateway_payload ->> 'mode'), ''), 'CREATE_NEW'));

    IF v_gateway_mode = 'USE_EXISTING' THEN
        BEGIN
            v_existing_gateway_id := (v_gateway_payload ->> 'existing_gateway_id')::uuid;
        EXCEPTION WHEN invalid_text_representation THEN
            RAISE EXCEPTION 'Select a valid existing gateway.' USING ERRCODE = '22023';
        END;

        SELECT v_gateway_payload || jsonb_build_object(
                   'mode', 'USE_EXISTING',
                   'existing_gateway_id', g.id,
                   'id', g.id,
                   'name', g.name,
                   'external_id', g.external_id,
                   'vendor', COALESCE(gm.vendor, ''),
                   'model', COALESCE(gm.model, ''),
                   'protocol', COALESCE(gm.protocol, '')
               )
        INTO v_gateway_payload
        FROM metadata.gateways AS g
        LEFT JOIN metadata.gateway_models AS gm ON gm.id = g.gateway_model_id
        WHERE g.id = v_existing_gateway_id
          AND g.organization_id = v_existing_organization_id
          AND g.site_id = v_existing_site_id;

        IF v_gateway_payload IS NULL THEN
            RAISE EXCEPTION 'The selected gateway is unavailable or outside the selected site.'
                USING ERRCODE = 'P0002';
        END IF;

        v_draft_payload := jsonb_set(v_draft_payload, '{gateway}', v_gateway_payload, true);
    END IF;

    -- Hydrate an existing device and its canonical model/profile attributes.
    v_device_payload_existing := COALESCE(v_draft_payload -> 'device', '{}'::jsonb);
    v_device_mode := upper(COALESCE(NULLIF(btrim(v_device_payload_existing ->> 'mode'), ''), 'CREATE_NEW'));

    IF v_device_mode = 'USE_EXISTING' THEN
        BEGIN
            v_existing_device_id := (v_device_payload_existing ->> 'existing_device_id')::uuid;
        EXCEPTION WHEN invalid_text_representation THEN
            RAISE EXCEPTION 'Select a valid existing device.' USING ERRCODE = '22023';
        END;

        SELECT v_device_payload_existing || jsonb_build_object(
                   'mode', 'USE_EXISTING',
                   'existing_device_id', d.id,
                   'id', d.id,
                   'name', d.name,
                   'external_id', d.external_id,
                   'model_vendor', COALESCE(dm.vendor, ''),
                   'model', COALESCE(dm.model, ''),
                   'device_category_id', dm.device_category_id,
                   'firmware_version', COALESCE(d.firmware_version, ''),
                   'protocol', COALESCE(d.protocol, ''),
                   'profile_code', COALESCE(dp.profile_code, '')
               )
        INTO v_device_payload_existing
        FROM metadata.devices AS d
        LEFT JOIN metadata.device_models AS dm ON dm.id = d.device_model_id
        LEFT JOIN config.device_profiles AS dp ON dp.id = d.profile_id
        WHERE d.id = v_existing_device_id
          AND d.organization_id = v_existing_organization_id
          AND d.gateway_id = v_existing_gateway_id;

        IF v_device_payload_existing IS NULL THEN
            RAISE EXCEPTION 'The selected device is unavailable or outside the selected gateway.'
                USING ERRCODE = 'P0002';
        END IF;

        v_draft_payload := jsonb_set(v_draft_payload, '{device}', v_device_payload_existing, true);
    END IF;

    -- Hydrate an existing asset and verify tenant/site ownership.
    v_asset_payload := COALESCE(v_draft_payload -> 'asset', '{}'::jsonb);
    v_asset_mode := upper(COALESCE(NULLIF(btrim(v_asset_payload ->> 'mode'), ''), 'CREATE_NEW'));

    IF v_asset_mode = 'USE_EXISTING' THEN
        BEGIN
            v_existing_asset_id := (v_asset_payload ->> 'existing_asset_id')::uuid;
        EXCEPTION WHEN invalid_text_representation THEN
            RAISE EXCEPTION 'Select a valid existing asset.' USING ERRCODE = '22023';
        END;

        SELECT v_asset_payload || jsonb_build_object(
                   'mode', 'USE_EXISTING',
                   'existing_asset_id', a.id,
                   'id', a.id,
                   'name', a.name,
                   'asset_type_id', a.asset_type_id,
                   'metadata', COALESCE(a.metadata, '{}'::jsonb),
                   'metering_requirement', a.metering_requirement
               )
        INTO v_asset_payload
        FROM metadata.assets AS a
        WHERE a.id = v_existing_asset_id
          AND a.organization_id = v_existing_organization_id
          AND a.site_id = v_existing_site_id;

        IF v_asset_payload IS NULL THEN
            RAISE EXCEPTION 'The selected asset is unavailable or outside the selected site.'
                USING ERRCODE = 'P0002';
        END IF;

        v_draft_payload := jsonb_set(v_draft_payload, '{asset}', v_asset_payload, true);
    END IF;

    v_device_payload := COALESCE(
        v_draft_payload -> 'device',
        '{}'::jsonb
    );

    v_identifier_payload := COALESCE(
        v_device_payload -> 'identifier',
        '{}'::jsonb
    );

    IF jsonb_typeof(v_identifier_payload) <> 'object' THEN
        RAISE EXCEPTION
            'Draft device identifier must be a JSON object.';
    END IF;

    v_request_payload := jsonb_set(
        v_draft_payload,
        '{device}',
        v_device_payload - 'identifier',
        true
    );

    v_request_payload := jsonb_set(
        v_request_payload,
        '{identifier}',
        v_identifier_payload,
        true
    );

    v_request_payload :=
        v_request_payload - 'review';

    v_result := admin.onboard_energy_asset(
        v_request_payload,
        v_requested_by
    );

    UPDATE admin.onboarding_drafts AS draft
    SET
        status = 'SUBMITTED',
        current_step = 'review',
        payload = jsonb_set(
            draft.payload,
            '{review}',
            jsonb_build_object(
                'submitted_at',
                clock_timestamp(),
                'submitted_by',
                v_requested_by,
                'result',
                v_result
            ),
            true
        ),
        requested_by = v_requested_by,
        updated_at = clock_timestamp()
    WHERE draft.draft_token = p_draft_token
      AND draft.status = 'DRAFT'
      AND (
          EXISTS (SELECT 1 FROM admin.portal_users scope_user WHERE scope_user.portal_user_id = p_portal_user_id AND scope_user.is_active AND scope_user.access_scope_mode = 'GLOBAL')
          OR draft.owner_portal_user_id =
             p_portal_user_id
      );

    IF NOT FOUND THEN
        RAISE EXCEPTION
            'Onboarding draft status or ownership changed during submission.';
    END IF;

    PERFORM admin.log_onboarding_event(
        p_draft_token,
        'SUBMISSION_SUCCEEDED',
        'review',
        v_requested_by,
        jsonb_build_object(
            'organization_id',
            v_result ->> 'organization_id',
            'site_id',
            v_result ->> 'site_id',
            'gateway_id',
            v_result ->> 'gateway_id',
            'device_id',
            v_result ->> 'device_id',
            'asset_id',
            v_result ->> 'asset_id',
            'relationship_type',
            v_result ->> 'relationship_type'
        )
    );

    RETURN v_result;
END;
$function$;


-- Replaced legacy authorization function: transition_entity_lifecycle
CREATE OR REPLACE FUNCTION admin.transition_entity_lifecycle(p_actor_portal_user_id bigint, p_entity_type text, p_entity_id uuid, p_new_status text, p_change_reason text, p_allow_reactivation boolean DEFAULT false)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'admin', 'metadata'
AS $function$
DECLARE
    v_type TEXT := upper(btrim(p_entity_type));
    v_new TEXT := upper(btrim(p_new_status));
    v_current TEXT;
    v_org UUID;
    v_site UUID;
    v_role TEXT;
    v_scope_mode TEXT;
    v_permission TEXT;
    v_validation JSONB;
    v_transaction UUID := gen_random_uuid();
    v_result JSONB;
BEGIN
    IF nullif(btrim(p_change_reason),'') IS NULL THEN
        RAISE EXCEPTION 'Lifecycle change reason is required.' USING ERRCODE='22023';
    END IF;
    SELECT role_code, access_scope_mode INTO v_role, v_scope_mode FROM admin.portal_users
    WHERE portal_user_id=p_actor_portal_user_id AND is_active=TRUE;
    IF NOT FOUND THEN RAISE EXCEPTION 'Active portal actor was not found.' USING ERRCODE='42501'; END IF;

    v_permission := CASE v_type
        WHEN 'ORGANIZATION' THEN 'organization.manage'
        WHEN 'SITE' THEN 'site.manage'
        WHEN 'ASSET' THEN 'asset.manage'
        WHEN 'GATEWAY' THEN 'gateway.manage'
        WHEN 'DEVICE' THEN 'device.manage'
        ELSE NULL END;
    IF v_permission IS NULL OR NOT admin.portal_user_has_permission(p_actor_portal_user_id,v_permission) THEN
        RAISE EXCEPTION 'Portal actor is not authorized for this lifecycle operation.' USING ERRCODE='42501';
    END IF;

    CASE v_type
    WHEN 'ORGANIZATION' THEN
        SELECT lifecycle_status,id,NULL::uuid INTO v_current,v_org,v_site FROM metadata.organizations WHERE id=p_entity_id FOR UPDATE;
    WHEN 'SITE' THEN
        SELECT lifecycle_status,organization_id,id INTO v_current,v_org,v_site FROM metadata.sites WHERE id=p_entity_id FOR UPDATE;
    WHEN 'ASSET' THEN
        SELECT lifecycle_status,organization_id,site_id INTO v_current,v_org,v_site FROM metadata.assets WHERE id=p_entity_id FOR UPDATE;
    WHEN 'GATEWAY' THEN
        SELECT lifecycle_status,organization_id,site_id INTO v_current,v_org,v_site FROM metadata.gateways WHERE id=p_entity_id FOR UPDATE;
    WHEN 'DEVICE' THEN
        SELECT d.lifecycle_status,d.organization_id,g.site_id INTO v_current,v_org,v_site FROM metadata.devices d LEFT JOIN metadata.gateways g ON g.id=d.gateway_id WHERE d.id=p_entity_id FOR UPDATE OF d;
    ELSE
        RAISE EXCEPTION 'Unsupported lifecycle entity type: %',p_entity_type USING ERRCODE='22023';
    END CASE;
    IF NOT FOUND THEN RAISE EXCEPTION 'Lifecycle entity was not found.' USING ERRCODE='22023'; END IF;

    IF v_scope_mode <> 'GLOBAL' THEN
        IF v_site IS NOT NULL AND NOT admin.portal_user_can_access_site(p_actor_portal_user_id,v_site) THEN
            RAISE EXCEPTION 'Portal actor cannot access the entity site.' USING ERRCODE='42501';
        ELSIF v_site IS NULL AND NOT EXISTS (
            SELECT 1 FROM admin.portal_users u WHERE u.portal_user_id=p_actor_portal_user_id AND u.organization_id=v_org
        ) THEN
            RAISE EXCEPTION 'Portal actor cannot access the entity organization.' USING ERRCODE='42501';
        END IF;
    END IF;
    IF p_allow_reactivation AND v_scope_mode <> 'GLOBAL' THEN
        RAISE EXCEPTION 'Only a platform administrator may explicitly reactivate a decommissioned entity.' USING ERRCODE='42501';
    END IF;

    v_validation := admin.validate_lifecycle_transition(v_type,p_entity_id,v_current,v_new,p_allow_reactivation);
    IF NOT (v_validation->>'allowed')::boolean THEN
        PERFORM admin.write_audit_event(
            v_transaction,
            p_actor_portal_user_id,
            'LIFECYCLE_TRANSITION',
            v_type,
            p_entity_id,
            v_org,
            v_site,
            jsonb_build_object('lifecycle_status', v_current),
            jsonb_build_object(
                'lifecycle_status', v_new,
                'change_reason', btrim(p_change_reason)
            ),
            'REJECTED',
            v_validation->>'reason'
        );

        -- Do not raise here: an exception would roll back the audit event.
        RETURN jsonb_build_object(
            'success', false,
            'entity_type', v_type,
            'entity_id', p_entity_id,
            'organization_id', v_org,
            'site_id', v_site,
            'previous_lifecycle_status', v_current,
            'requested_lifecycle_status', v_new,
            'failure_reason', v_validation->>'reason',
            'dependencies', v_validation->'dependencies',
            'audit_transaction_id', v_transaction
        );
    END IF;

    CASE v_type
    WHEN 'ORGANIZATION' THEN UPDATE metadata.organizations SET lifecycle_status=v_new,is_active=(v_new<>'DECOMMISSIONED'),updated_at=now() WHERE id=p_entity_id;
    WHEN 'SITE' THEN UPDATE metadata.sites SET lifecycle_status=v_new,is_active=(v_new NOT IN ('INACTIVE','DECOMMISSIONED')),updated_at=now() WHERE id=p_entity_id;
    WHEN 'ASSET' THEN UPDATE metadata.assets SET lifecycle_status=v_new,status=lower(v_new),updated_at=now() WHERE id=p_entity_id;
    WHEN 'GATEWAY' THEN UPDATE metadata.gateways SET lifecycle_status=v_new WHERE id=p_entity_id;
    WHEN 'DEVICE' THEN UPDATE metadata.devices SET lifecycle_status=v_new,updated_at=now() WHERE id=p_entity_id;
    END CASE;

    PERFORM admin.write_audit_event(v_transaction,p_actor_portal_user_id,'LIFECYCLE_TRANSITION',v_type,p_entity_id,v_org,v_site,
        jsonb_build_object('lifecycle_status',v_current),
        jsonb_build_object('lifecycle_status',v_new,'change_reason',btrim(p_change_reason)),'SUCCEEDED',NULL);
    v_result := jsonb_build_object('success',true,'entity_type',v_type,'entity_id',p_entity_id,
        'organization_id',v_org,'site_id',v_site,'previous_lifecycle_status',v_current,
        'lifecycle_status',v_new,'dependencies',v_validation->'dependencies','audit_transaction_id',v_transaction);
    RETURN v_result;
END;
$function$;


-- Replaced legacy authorization function: update_organization_workspace
CREATE OR REPLACE FUNCTION admin.update_organization_workspace(p_actor_portal_user_id bigint, p_organization_id uuid, p_name text, p_legal_name text, p_timezone text, p_locale text, p_lifecycle_status text, p_primary_contact jsonb, p_address jsonb, p_notes text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'admin', 'metadata'
AS $function$
DECLARE
    v_actor admin.portal_users%ROWTYPE;
    v_before JSONB;
    v_after JSONB;
    v_status TEXT := upper(btrim(p_lifecycle_status));
BEGIN
    SELECT *
      INTO v_actor
      FROM admin.portal_users
     WHERE portal_user_id = p_actor_portal_user_id
       AND is_active;

    IF NOT FOUND OR v_actor.role_code <> 'ADMIN' OR v_actor.access_scope_mode <> 'GLOBAL' THEN
        RAISE EXCEPTION 'Only a platform administrator may edit organization settings.'
            USING ERRCODE = '42501';
    END IF;

    IF NULLIF(btrim(p_name), '') IS NULL THEN
        RAISE EXCEPTION 'Organization name is required.'
            USING ERRCODE = '22023';
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM pg_timezone_names
        WHERE name = btrim(p_timezone)
    ) THEN
        RAISE EXCEPTION 'Select a valid IANA timezone.'
            USING ERRCODE = '22023';
    END IF;

    IF v_status NOT IN (
        'DRAFT',
        'ACTIVE',
        'SUSPENDED',
        'DECOMMISSIONED'
    ) THEN
        RAISE EXCEPTION 'Select a valid lifecycle status.'
            USING ERRCODE = '22023';
    END IF;

    SELECT to_jsonb(o)
      INTO v_before
      FROM metadata.organizations o
     WHERE id = p_organization_id
     FOR UPDATE;

    IF v_before IS NULL THEN
        RAISE EXCEPTION 'Organization was not found.'
            USING ERRCODE = 'P0002';
    END IF;

    UPDATE metadata.organizations
       SET name = btrim(p_name),
           legal_name = NULLIF(btrim(p_legal_name), ''),
           timezone = btrim(p_timezone),
           locale = COALESCE(NULLIF(btrim(p_locale), ''), 'en-US'),
           lifecycle_status = v_status,
           is_active = (v_status = 'ACTIVE'),
           primary_contact = COALESCE(p_primary_contact, '{}'::jsonb),
           address = COALESCE(p_address, '{}'::jsonb),
           notes = NULLIF(btrim(p_notes), ''),
           updated_at = now()
     WHERE id = p_organization_id;

    SELECT admin.get_organization_workspace(
        p_actor_portal_user_id,
        p_organization_id
    )
    INTO v_after;

    INSERT INTO admin.onboarding_audit(
        requested_by,
        request_payload,
        result_payload
    )
    VALUES (
        v_actor.username,
        jsonb_build_object(
            'operation', 'UPDATE_ORGANIZATION',
            'organization_id', p_organization_id,
            'before', v_before
        ),
        jsonb_build_object(
            'success', true,
            'organization_id', p_organization_id,
            'after', v_after
        )
    );

    RETURN v_after;
END;
$function$;


-- Replaced legacy authorization function: validate_onboarding_field
CREATE OR REPLACE FUNCTION admin.validate_onboarding_field(p_actor_portal_user_id bigint, p_draft_token uuid, p_step text, p_field text, p_value text, p_form jsonb DEFAULT '{}'::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'admin', 'metadata', 'config'
AS $function$
DECLARE
    v_actor admin.portal_users%ROWTYPE;
    v_payload jsonb := '{}'::jsonb;
    v_org_id uuid;
    v_site_id uuid;
    v_gateway_id uuid;
    v_building_id uuid;
    v_floor_id uuid;
    v_id uuid;
    v_exists boolean;
    v_category uuid;
    v_org_code text;
    v_org_name text;
    v_site_code text;
    v_site_name text;
    v_gateway_external_id text;
BEGIN
    SELECT * INTO v_actor
    FROM admin.portal_users
    WHERE portal_user_id = p_actor_portal_user_id AND is_active;

    IF NOT FOUND THEN
        RETURN jsonb_build_object('valid',false,'field',p_field,'code','NOT_AUTHORIZED','message','Your session is no longer authorized.');
    END IF;

    IF p_draft_token IS NOT NULL THEN
        SELECT payload INTO v_payload
        FROM admin.onboarding_drafts
        WHERE draft_token = p_draft_token
          AND owner_portal_user_id = p_actor_portal_user_id
          AND status = 'DRAFT';
        IF NOT FOUND THEN
            RETURN jsonb_build_object('valid',false,'field',p_field,'code','DRAFT_NOT_FOUND','message','The onboarding draft is no longer available.');
        END IF;
    END IF;

    BEGIN
        v_org_id := coalesce(
            nullif(v_payload#>>'{organization,existing_organization_id}','')::uuid,
            nullif(p_form->>'existing_organization_id','')::uuid
        );
        v_site_id := coalesce(
            nullif(v_payload#>>'{site,existing_site_id}','')::uuid,
            nullif(p_form->>'existing_site_id','')::uuid
        );
        v_gateway_id := coalesce(
            nullif(v_payload#>>'{gateway,existing_gateway_id}','')::uuid,
            nullif(p_form->>'existing_gateway_id','')::uuid
        );
    EXCEPTION WHEN invalid_text_representation THEN
        RETURN jsonb_build_object('valid',false,'field',p_field,'code','INVALID_SELECTION','message','Select a valid record.');
    END;

    -- Resolve CREATE_NEW parent scopes against existing canonical rows solely
    -- for duplicate detection. This never converts CREATE_NEW into USE_EXISTING.
    v_org_code := upper(nullif(btrim(coalesce(p_form->>'organization_code', v_payload#>>'{organization,code}')),''));
    v_org_name := lower(nullif(btrim(coalesce(p_form->>'organization_name', v_payload#>>'{organization,name}')),''));
    IF v_org_id IS NULL THEN
        SELECT o.id INTO v_org_id
        FROM metadata.organizations o
        WHERE (v_org_code IS NOT NULL AND upper(btrim(o.code)) = v_org_code)
           OR (v_org_name IS NOT NULL AND lower(btrim(o.name)) = v_org_name)
        ORDER BY CASE WHEN v_org_code IS NOT NULL AND upper(btrim(o.code)) = v_org_code THEN 0 ELSE 1 END, o.created_at
        LIMIT 1;
    END IF;

    IF v_actor.access_scope_mode <> 'GLOBAL' AND v_org_id IS DISTINCT FROM v_actor.organization_id THEN
        v_org_id := v_actor.organization_id;
    END IF;

    v_site_code := upper(nullif(btrim(coalesce(p_form->>'site_code', v_payload#>>'{site,code}')),''));
    v_site_name := lower(nullif(btrim(coalesce(p_form->>'site_name', v_payload#>>'{site,name}')),''));
    IF v_site_id IS NULL AND v_org_id IS NOT NULL THEN
        SELECT s.id INTO v_site_id
        FROM metadata.sites s
        WHERE s.organization_id = v_org_id
          AND ((v_site_code IS NOT NULL AND upper(btrim(s.code)) = v_site_code)
            OR (v_site_name IS NOT NULL AND lower(btrim(s.name)) = v_site_name))
        ORDER BY CASE WHEN v_site_code IS NOT NULL AND upper(btrim(s.code)) = v_site_code THEN 0 ELSE 1 END, s.created_at
        LIMIT 1;
    END IF;

    v_gateway_external_id := upper(nullif(btrim(coalesce(p_form->>'gateway_external_id', v_payload#>>'{gateway,external_id}')),''));
    IF v_gateway_id IS NULL AND v_org_id IS NOT NULL AND v_gateway_external_id IS NOT NULL THEN
        SELECT g.id INTO v_gateway_id
        FROM metadata.gateways g
        WHERE g.organization_id = v_org_id
          AND upper(btrim(g.external_id)) = v_gateway_external_id
        ORDER BY g.created_at
        LIMIT 1;
    END IF;

    IF p_field IN ('organization_name','site_name','building_name','floor_name','space_name','gateway_name','device_name','asset_name')
       AND btrim(coalesce(p_value,'')) = '' THEN
        RETURN jsonb_build_object('valid',false,'field',p_field,'code','REQUIRED','message','This field is required.');
    END IF;

    IF p_field = 'existing_organization_id' THEN
        BEGIN v_id := p_value::uuid; EXCEPTION WHEN invalid_text_representation THEN v_id := NULL; END;
        SELECT EXISTS(SELECT 1 FROM metadata.organizations o WHERE o.id=v_id AND o.is_active AND (v_actor.access_scope_mode='GLOBAL' OR v_actor.organization_id=o.id)) INTO v_exists;
        IF NOT v_exists THEN RETURN jsonb_build_object('valid',false,'field',p_field,'code','INVALID_ORGANIZATION','message','Select an active organization within your access scope.'); END IF;
    ELSIF p_field = 'organization_code' THEN
        SELECT EXISTS(SELECT 1 FROM metadata.organizations o WHERE upper(btrim(o.code))=upper(btrim(p_value))) INTO v_exists;
        IF v_exists THEN RETURN jsonb_build_object('valid',false,'field',p_field,'code','DUPLICATE_CODE','message','This organization code already exists. Choose Use existing organization.'); END IF;
    ELSIF p_field = 'organization_name' THEN
        SELECT EXISTS(SELECT 1 FROM metadata.organizations o WHERE lower(btrim(o.name))=lower(btrim(p_value))) INTO v_exists;
        IF v_exists THEN RETURN jsonb_build_object('valid',false,'field',p_field,'code','DUPLICATE_NAME','message','This organization name already exists. Choose Use existing organization.'); END IF;
    ELSIF p_field = 'existing_site_id' THEN
        BEGIN v_id := p_value::uuid; EXCEPTION WHEN invalid_text_representation THEN v_id := NULL; END;
        SELECT EXISTS(SELECT 1 FROM metadata.sites s WHERE s.id=v_id AND s.organization_id=v_org_id AND s.is_active) INTO v_exists;
        IF NOT v_exists THEN RETURN jsonb_build_object('valid',false,'field',p_field,'code','INVALID_SITE','message','Select an active site belonging to the chosen organization.'); END IF;
    ELSIF p_field = 'site_code' AND v_org_id IS NOT NULL THEN
        SELECT EXISTS(SELECT 1 FROM metadata.sites s WHERE s.organization_id=v_org_id AND upper(btrim(s.code))=upper(btrim(p_value))) INTO v_exists;
        IF v_exists THEN RETURN jsonb_build_object('valid',false,'field',p_field,'code','DUPLICATE_CODE','message','This site code already exists. Choose Use existing site.'); END IF;
    ELSIF p_field = 'site_name' AND v_org_id IS NOT NULL THEN
        SELECT EXISTS(SELECT 1 FROM metadata.sites s WHERE s.organization_id=v_org_id AND lower(btrim(s.name))=lower(btrim(p_value))) INTO v_exists;
        IF v_exists THEN RETURN jsonb_build_object('valid',false,'field',p_field,'code','DUPLICATE_NAME','message','This site name already exists. Choose Use existing site.'); END IF;
    ELSIF p_field = 'existing_space_id' THEN
        BEGIN v_id := p_value::uuid; EXCEPTION WHEN invalid_text_representation THEN v_id := NULL; END;
        SELECT EXISTS(
            SELECT 1 FROM metadata.spaces sp
            JOIN metadata.floors f ON f.id=sp.floor_id
            JOIN metadata.buildings b ON b.id=f.building_id
            WHERE sp.id=v_id AND sp.organization_id=v_org_id AND b.site_id=v_site_id
        ) INTO v_exists;
        IF NOT v_exists THEN RETURN jsonb_build_object('valid',false,'field',p_field,'code','INVALID_LOCATION','message','Select a space belonging to the chosen site.'); END IF;
    ELSIF p_field = 'building_code' AND v_site_id IS NOT NULL THEN
        SELECT EXISTS(
            SELECT 1
            FROM metadata.buildings b
            WHERE b.site_id = v_site_id
              AND upper(btrim(b.code)) = upper(btrim(p_value))
        )
        INTO v_exists;

        IF v_exists THEN
            RETURN jsonb_build_object(
                'valid', true,
                'field', p_field,
                'code', 'IDENTIFIER_ADJUSTED',
                'message',
                    'That building code is already used in this site. '
                    || 'A unique code has been generated.',
                'recommended_value',
                    admin.recommend_available_identifier(
                        'BUILDING',
                        p_value,
                        v_org_id,
                        v_site_id,
                        NULL,
                        NULL,
                        NULL
                    )
            );
        END IF;
    ELSIF p_field = 'floor_code' AND v_site_id IS NOT NULL THEN
        SELECT b.id INTO v_building_id FROM metadata.buildings b WHERE b.site_id=v_site_id AND upper(btrim(b.code))=upper(btrim(coalesce(p_form->>'building_code',''))) LIMIT 1;
        IF v_building_id IS NOT NULL THEN
            SELECT EXISTS(SELECT 1 FROM metadata.floors f WHERE f.building_id=v_building_id AND upper(btrim(f.code))=upper(btrim(p_value))) INTO v_exists;
            IF v_exists THEN
                RETURN jsonb_build_object(
                    'valid', true,
                    'field', p_field,
                    'code', 'IDENTIFIER_ADJUSTED',
                    'message',
                        'That floor code is already used in this building. '
                        || 'A unique code has been generated.',
                    'recommended_value',
                        admin.recommend_available_identifier(
                            'FLOOR',
                            p_value,
                            v_org_id,
                            v_site_id,
                            v_building_id,
                            NULL,
                            NULL
                        )
                );
            END IF;
        END IF;
    ELSIF p_field = 'space_code' AND v_site_id IS NOT NULL THEN
        SELECT b.id INTO v_building_id FROM metadata.buildings b WHERE b.site_id=v_site_id AND upper(btrim(b.code))=upper(btrim(coalesce(p_form->>'building_code',''))) LIMIT 1;
        SELECT f.id INTO v_floor_id FROM metadata.floors f WHERE f.building_id=v_building_id AND upper(btrim(f.code))=upper(btrim(coalesce(p_form->>'floor_code',''))) LIMIT 1;
        IF v_floor_id IS NOT NULL THEN
            SELECT EXISTS(SELECT 1 FROM metadata.spaces sp WHERE sp.floor_id=v_floor_id AND upper(btrim(sp.code))=upper(btrim(p_value))) INTO v_exists;
            IF v_exists THEN
                RETURN jsonb_build_object(
                    'valid', true,
                    'field', p_field,
                    'code', 'IDENTIFIER_ADJUSTED',
                    'message',
                        'That space code is already used on this floor. '
                        || 'A unique code has been generated.',
                    'recommended_value',
                        admin.recommend_available_identifier(
                            'SPACE',
                            p_value,
                            v_org_id,
                            v_site_id,
                            v_building_id,
                            v_floor_id,
                            NULL
                        )
                );
            END IF;
        END IF;
    ELSIF p_field = 'gateway_external_id' THEN
        SELECT EXISTS(SELECT 1 FROM metadata.gateways g WHERE (v_org_id IS NULL OR g.organization_id=v_org_id) AND upper(btrim(g.external_id))=upper(btrim(p_value))) INTO v_exists;
        IF v_exists THEN
            RETURN jsonb_build_object(
                'valid', true,
                'field', p_field,
                'code', 'IDENTIFIER_ADJUSTED',
                'message',
                    'That gateway external ID is already used. '
                    || 'A unique ID has been generated.',
                'recommended_value',
                    admin.recommend_available_identifier(
                        'GATEWAY',
                        p_value,
                        v_org_id,
                        v_site_id,
                        NULL,
                        NULL,
                        NULL
                    )
            );
        END IF;
    ELSIF p_field = 'existing_gateway_id' THEN
        BEGIN v_id := p_value::uuid; EXCEPTION WHEN invalid_text_representation THEN v_id := NULL; END;
        SELECT EXISTS(SELECT 1 FROM metadata.gateways g WHERE g.id=v_id AND g.organization_id=v_org_id AND g.site_id=v_site_id AND g.lifecycle_status NOT IN ('INACTIVE','DECOMMISSIONED')) INTO v_exists;
        IF NOT v_exists THEN RETURN jsonb_build_object('valid',false,'field',p_field,'code','INVALID_GATEWAY','message','Select an active gateway belonging to the chosen site.'); END IF;
    ELSIF p_field = 'device_external_id' THEN
        SELECT EXISTS(SELECT 1 FROM metadata.devices d WHERE (v_org_id IS NULL OR d.organization_id=v_org_id) AND upper(btrim(d.external_id))=upper(btrim(p_value))) INTO v_exists;
        IF v_exists THEN
            RETURN jsonb_build_object(
                'valid', true,
                'field', p_field,
                'code', 'IDENTIFIER_ADJUSTED',
                'message',
                    'That device external ID is already used. '
                    || 'A unique ID has been generated.',
                'recommended_value',
                    admin.recommend_available_identifier(
                        'DEVICE',
                        p_value,
                        v_org_id,
                        v_site_id,
                        NULL,
                        NULL,
                        NULL
                    )
            );
        END IF;
    ELSIF p_field IN ('new_identifier_value', 'identifier_value') THEN
        SELECT EXISTS(SELECT 1 FROM metadata.device_identifiers di WHERE upper(di.identifier_type)=upper(coalesce(p_form->>'identifier_type','MQTT_UID')) AND (CASE WHEN upper(coalesce(p_form->>'identifier_type','MQTT_UID'))='MQTT_UID' THEN lower(di.identifier_value) ELSE di.identifier_value END)=(CASE WHEN upper(coalesce(p_form->>'identifier_type','MQTT_UID'))='MQTT_UID' THEN lower(btrim(p_value)) ELSE btrim(p_value) END)) INTO v_exists;
        IF v_exists THEN RETURN jsonb_build_object('valid',false,'field',p_field,'code','DUPLICATE_IDENTIFIER','message','This device identifier already exists. Choose Use existing device.'); END IF;
    ELSIF p_field = 'existing_device_id' THEN
        BEGIN v_id := p_value::uuid; EXCEPTION WHEN invalid_text_representation THEN v_id := NULL; END;
        SELECT EXISTS(SELECT 1 FROM metadata.devices d WHERE d.id=v_id AND d.organization_id=v_org_id AND d.gateway_id=v_gateway_id AND d.lifecycle_status NOT IN ('INACTIVE','DECOMMISSIONED')) INTO v_exists;
        IF NOT v_exists THEN RETURN jsonb_build_object('valid',false,'field',p_field,'code','INVALID_DEVICE','message','Select an active device belonging to the chosen gateway.'); END IF;
    ELSIF p_field = 'profile_code' THEN
        BEGIN v_category := nullif(p_form->>'device_category_id','')::uuid; EXCEPTION WHEN invalid_text_representation THEN v_category := NULL; END;
        SELECT EXISTS(SELECT 1 FROM admin.v_active_device_profiles p WHERE p.profile_code=p_value AND (v_category IS NULL OR v_category=ANY(p.device_category_ids))) INTO v_exists;
        IF NOT v_exists THEN RETURN jsonb_build_object('valid',false,'field',p_field,'code','INCOMPATIBLE_PROFILE','message','Choose a profile compatible with the selected device category.'); END IF;
    ELSIF p_field = 'existing_asset_id' THEN
        BEGIN v_id := p_value::uuid; EXCEPTION WHEN invalid_text_representation THEN v_id := NULL; END;
        SELECT EXISTS(SELECT 1 FROM metadata.assets a WHERE a.id=v_id AND a.organization_id=v_org_id AND a.site_id=v_site_id AND lower(coalesce(a.status,'active'))='active') INTO v_exists;
        IF NOT v_exists THEN RETURN jsonb_build_object('valid',false,'field',p_field,'code','INVALID_ASSET','message','Select an active asset belonging to the chosen site.'); END IF;
    ELSIF p_field = 'asset_external_id'
          AND v_org_id IS NOT NULL
          AND v_site_id IS NOT NULL THEN
        SELECT EXISTS(
            SELECT 1
            FROM metadata.assets a
            WHERE a.organization_id = v_org_id
              AND a.site_id = v_site_id
              AND upper(btrim(a.external_id))
                  = upper(btrim(p_value))
        )
        INTO v_exists;

        IF v_exists THEN
            RETURN jsonb_build_object(
                'valid', true,
                'field', p_field,
                'code', 'IDENTIFIER_ADJUSTED',
                'message',
                    'That asset external ID is already used in this site. '
                    || 'A unique ID has been generated.',
                'recommended_value',
                    admin.recommend_available_identifier(
                        'ASSET',
                        p_value,
                        v_org_id,
                        v_site_id,
                        NULL,
                        NULL,
                        NULL
                    )
            );
        END IF;

    ELSIF p_field = 'asset_name' THEN
        NULL;
    END IF;

    RETURN jsonb_build_object('valid',true,'field',p_field,'code','OK','message','');
END;
$function$;


-- Ownership and least-privilege execution boundary.
ALTER FUNCTION admin.apply_grafana_reconciliation_mapping(bigint,uuid,bigint,text) OWNER TO ems_admin;
REVOKE ALL ON FUNCTION admin.apply_grafana_reconciliation_mapping(bigint,uuid,bigint,text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION admin.apply_grafana_reconciliation_mapping(bigint,uuid,bigint,text) TO ems_app;
ALTER FUNCTION admin.change_managed_portal_user_role(bigint,bigint,text) OWNER TO ems_admin;
REVOKE ALL ON FUNCTION admin.change_managed_portal_user_role(bigint,bigint,text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION admin.change_managed_portal_user_role(bigint,bigint,text) TO ems_app;
ALTER FUNCTION admin.create_managed_portal_user(bigint,text,text,text,text,text,text,uuid,uuid[]) OWNER TO ems_admin;
REVOKE ALL ON FUNCTION admin.create_managed_portal_user(bigint,text,text,text,text,text,text,uuid,uuid[]) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION admin.create_managed_portal_user(bigint,text,text,text,text,text,text,uuid,uuid[]) TO ems_app;
ALTER FUNCTION admin.create_organization_workspace(bigint,text,text,text,text,text,text,text,jsonb,jsonb,text) OWNER TO ems_admin;
REVOKE ALL ON FUNCTION admin.create_organization_workspace(bigint,text,text,text,text,text,text,text,jsonb,jsonb,text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION admin.create_organization_workspace(bigint,text,text,text,text,text,text,text,jsonb,jsonb,text) TO ems_app;
ALTER FUNCTION admin.create_site(bigint,uuid,text,text,text,text) OWNER TO ems_admin;
REVOKE ALL ON FUNCTION admin.create_site(bigint,uuid,text,text,text,text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION admin.create_site(bigint,uuid,text,text,text,text) TO ems_app;
ALTER FUNCTION admin.get_grafana_reconciliation_context(bigint,uuid) OWNER TO ems_admin;
REVOKE ALL ON FUNCTION admin.get_grafana_reconciliation_context(bigint,uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION admin.get_grafana_reconciliation_context(bigint,uuid) TO ems_app;
ALTER FUNCTION admin.get_onboarding_draft(uuid,bigint,text) OWNER TO ems_admin;
REVOKE ALL ON FUNCTION admin.get_onboarding_draft(uuid,bigint,text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION admin.get_onboarding_draft(uuid,bigint,text) TO ems_app;
ALTER FUNCTION admin.get_organization_workspace(bigint,uuid) OWNER TO ems_admin;
REVOKE ALL ON FUNCTION admin.get_organization_workspace(bigint,uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION admin.get_organization_workspace(bigint,uuid) TO ems_app;
ALTER FUNCTION admin.get_submitted_onboarding_result(uuid,bigint,text) OWNER TO ems_admin;
REVOKE ALL ON FUNCTION admin.get_submitted_onboarding_result(uuid,bigint,text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION admin.get_submitted_onboarding_result(uuid,bigint,text) TO ems_app;
ALTER FUNCTION admin.list_accessible_audit_events(bigint,uuid,uuid,text,integer) OWNER TO ems_admin;
REVOKE ALL ON FUNCTION admin.list_accessible_audit_events(bigint,uuid,uuid,text,integer) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION admin.list_accessible_audit_events(bigint,uuid,uuid,text,integer) TO ems_app;
ALTER FUNCTION admin.list_accessible_physical_locations(bigint) OWNER TO ems_admin;
REVOKE ALL ON FUNCTION admin.list_accessible_physical_locations(bigint) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION admin.list_accessible_physical_locations(bigint) TO ems_app;
ALTER FUNCTION admin.list_accessible_reconciliation_queue(bigint,uuid,uuid,text) OWNER TO ems_admin;
REVOKE ALL ON FUNCTION admin.list_accessible_reconciliation_queue(bigint,uuid,uuid,text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION admin.list_accessible_reconciliation_queue(bigint,uuid,uuid,text) TO ems_app;
ALTER FUNCTION admin.list_accessible_sites(bigint) OWNER TO ems_admin;
REVOKE ALL ON FUNCTION admin.list_accessible_sites(bigint) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION admin.list_accessible_sites(bigint) TO ems_app;
ALTER FUNCTION admin.list_manageable_portal_users(bigint) OWNER TO ems_admin;
REVOKE ALL ON FUNCTION admin.list_manageable_portal_users(bigint) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION admin.list_manageable_portal_users(bigint) TO ems_app;
ALTER FUNCTION admin.portal_user_can_access_site(bigint,uuid) OWNER TO ems_admin;
REVOKE ALL ON FUNCTION admin.portal_user_can_access_site(bigint,uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION admin.portal_user_can_access_site(bigint,uuid) TO ems_app;
ALTER FUNCTION admin.save_onboarding_draft_step(uuid,text,jsonb,text,bigint,text,text) OWNER TO ems_admin;
REVOKE ALL ON FUNCTION admin.save_onboarding_draft_step(uuid,text,jsonb,text,bigint,text,text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION admin.save_onboarding_draft_step(uuid,text,jsonb,text,bigint,text,text) TO ems_app;
ALTER FUNCTION admin.set_managed_portal_user_access_scope(bigint,bigint,text,uuid,uuid[]) OWNER TO ems_admin;
REVOKE ALL ON FUNCTION admin.set_managed_portal_user_access_scope(bigint,bigint,text,uuid,uuid[]) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION admin.set_managed_portal_user_access_scope(bigint,bigint,text,uuid,uuid[]) TO ems_app;
ALTER FUNCTION admin.set_managed_portal_user_active(bigint,bigint,boolean) OWNER TO ems_admin;
REVOKE ALL ON FUNCTION admin.set_managed_portal_user_active(bigint,bigint,boolean) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION admin.set_managed_portal_user_active(bigint,bigint,boolean) TO ems_app;
ALTER FUNCTION admin.submit_onboarding_draft(uuid,bigint,text,text) OWNER TO ems_admin;
REVOKE ALL ON FUNCTION admin.submit_onboarding_draft(uuid,bigint,text,text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION admin.submit_onboarding_draft(uuid,bigint,text,text) TO ems_app;
ALTER FUNCTION admin.transition_entity_lifecycle(bigint,text,uuid,text,text,boolean) OWNER TO ems_admin;
REVOKE ALL ON FUNCTION admin.transition_entity_lifecycle(bigint,text,uuid,text,text,boolean) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION admin.transition_entity_lifecycle(bigint,text,uuid,text,text,boolean) TO ems_app;
ALTER FUNCTION admin.update_organization_workspace(bigint,uuid,text,text,text,text,text,jsonb,jsonb,text) OWNER TO ems_admin;
REVOKE ALL ON FUNCTION admin.update_organization_workspace(bigint,uuid,text,text,text,text,text,jsonb,jsonb,text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION admin.update_organization_workspace(bigint,uuid,text,text,text,text,text,jsonb,jsonb,text) TO ems_app;
ALTER FUNCTION admin.validate_onboarding_field(bigint,uuid,text,text,text,jsonb) OWNER TO ems_admin;
REVOKE ALL ON FUNCTION admin.validate_onboarding_field(bigint,uuid,text,text,text,jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION admin.validate_onboarding_field(bigint,uuid,text,text,text,jsonb) TO ems_app;
ALTER FUNCTION admin.portal_user_scope_contains_user(bigint,bigint) OWNER TO ems_admin;
REVOKE ALL ON FUNCTION admin.portal_user_scope_contains_user(bigint,bigint) FROM PUBLIC;
ALTER FUNCTION admin.validate_portal_user_site_assignment() OWNER TO ems_admin;
REVOKE ALL ON FUNCTION admin.validate_portal_user_site_assignment() FROM PUBLIC;
ALTER FUNCTION admin.enforce_portal_user_site_scope() OWNER TO ems_admin;
REVOKE ALL ON FUNCTION admin.enforce_portal_user_site_scope() FROM PUBLIC;

DO $assert_three_role_scope$
BEGIN
    IF EXISTS (SELECT 1 FROM admin.portal_users WHERE role_code NOT IN ('ADMIN','OPERATOR','VIEWER')) THEN
        RAISE EXCEPTION 'Migration 150 left an invalid portal role.';
    END IF;
    IF EXISTS (SELECT 1 FROM admin.portal_users WHERE access_scope_mode NOT IN ('GLOBAL','ORGANIZATION','SELECTED_SITES')) THEN
        RAISE EXCEPTION 'Migration 150 left an invalid access scope.';
    END IF;
    IF EXISTS (SELECT 1 FROM config.portal_role_definitions WHERE role_code IN ('PLATFORM_ADMIN','ORG_ADMIN')) THEN
        RAISE EXCEPTION 'Migration 150 left legacy role definitions.';
    END IF;
END;
$assert_three_role_scope$;

-- FUNCTION_REPLACEMENTS_END

