-- Epic 4: independent site and physical-location administration.
--
-- Provides tenant-safe controlled writes for sites, buildings, floors, and
-- spaces, plus one hierarchy reader for administration pages and reusable
-- physical-location selectors.

CREATE OR REPLACE FUNCTION admin.portal_user_has_permission
(
    p_portal_user_id BIGINT,
    p_permission_code TEXT
)
RETURNS BOOLEAN
LANGUAGE SQL
SECURITY DEFINER
STABLE
SET search_path TO pg_catalog, admin, config
AS $function$
    SELECT EXISTS
    (
        SELECT 1
        FROM admin.portal_users AS portal_user
        JOIN config.portal_role_permissions AS role_permission
          ON role_permission.role_code = portal_user.role_code
        WHERE portal_user.portal_user_id = p_portal_user_id
          AND portal_user.is_active = TRUE
          AND role_permission.permission_code = p_permission_code
    );
$function$;


CREATE OR REPLACE FUNCTION metadata.prevent_site_organization_change()
RETURNS trigger
LANGUAGE plpgsql
SET search_path TO pg_catalog, metadata
AS $function$
BEGIN
    IF NEW.organization_id IS DISTINCT FROM OLD.organization_id THEN
        RAISE EXCEPTION
            'Site ownership cannot be changed.'
            USING ERRCODE = '23514';
    END IF;

    RETURN NEW;
END;
$function$;


DROP TRIGGER IF EXISTS sites_prevent_organization_change
    ON metadata.sites;

CREATE TRIGGER sites_prevent_organization_change
BEFORE UPDATE OF organization_id
ON metadata.sites
FOR EACH ROW
EXECUTE FUNCTION metadata.prevent_site_organization_change();


CREATE OR REPLACE FUNCTION admin.create_site
(
    p_actor_portal_user_id BIGINT,
    p_organization_id UUID,
    p_name TEXT,
    p_code TEXT,
    p_timezone TEXT,
    p_lifecycle_status TEXT
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO pg_catalog, admin, metadata, config
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

    IF v_actor_role <> 'PLATFORM_ADMIN' THEN
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

    IF length(v_code) > 100 OR v_code !~ '^[A-Z0-9_]+$' THEN
        RAISE EXCEPTION
            'Site code may contain only A-Z, 0-9, and underscore.'
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


CREATE OR REPLACE FUNCTION admin.create_building
(
    p_actor_portal_user_id BIGINT,
    p_site_id UUID,
    p_name TEXT,
    p_code TEXT
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO pg_catalog, admin, metadata, config
AS $function$
DECLARE
    v_actor_username TEXT;
    v_organization_id UUID;
    v_name TEXT := btrim(p_name);
    v_code TEXT := upper(btrim(p_code));
    v_building_id UUID;
    v_audit_id UUID := gen_random_uuid();
    v_request JSONB;
    v_result JSONB;
BEGIN
    SELECT portal_user.username
    INTO v_actor_username
    FROM admin.portal_users AS portal_user
    WHERE portal_user.portal_user_id = p_actor_portal_user_id
      AND portal_user.is_active = TRUE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Active portal actor was not found.'
            USING ERRCODE = '42501';
    END IF;

    IF NOT admin.portal_user_has_permission(
        p_actor_portal_user_id,
        'location.manage'
    ) THEN
        RAISE EXCEPTION
            'Portal actor is not authorized to create locations.'
            USING ERRCODE = '42501';
    END IF;

    SELECT site_record.organization_id
    INTO v_organization_id
    FROM metadata.sites AS site_record
    WHERE site_record.id = p_site_id
      AND site_record.is_active = TRUE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Select an active site.'
            USING ERRCODE = '22023';
    END IF;

    IF NOT admin.portal_user_can_access_site(
        p_actor_portal_user_id,
        p_site_id
    ) THEN
        RAISE EXCEPTION 'Portal actor cannot access the selected site.'
            USING ERRCODE = '42501';
    END IF;

    IF v_name IS NULL OR v_name = '' OR length(v_name) > 200 THEN
        RAISE EXCEPTION 'Building name is required and must not exceed 200 characters.'
            USING ERRCODE = '22023';
    END IF;

    IF v_code IS NULL
       OR v_code = ''
       OR length(v_code) > 100
       OR v_code !~ '^[A-Z][A-Z0-9_]*$' THEN
        RAISE EXCEPTION
            'Building code must start with A-Z and contain only A-Z, 0-9, and underscore.'
            USING ERRCODE = '22023';
    END IF;

    BEGIN
        INSERT INTO metadata.buildings
        (
            organization_id,
            site_id,
            name,
            code
        )
        VALUES
        (
            v_organization_id,
            p_site_id,
            v_name,
            v_code
        )
        RETURNING id INTO v_building_id;
    EXCEPTION
        WHEN unique_violation THEN
            RAISE EXCEPTION
                'Building code % already exists in the selected site.',
                v_code
                USING ERRCODE = '23505';
    END;

    v_request := jsonb_build_object
    (
        'operation', 'CREATE_BUILDING',
        'actor_portal_user_id', p_actor_portal_user_id,
        'site_id', p_site_id,
        'name', v_name,
        'code', v_code
    );

    v_result := jsonb_build_object
    (
        'success', TRUE,
        'entity_type', 'BUILDING',
        'entity_id', v_building_id,
        'lifecycle_status', NULL,
        'commissioning_status', NULL,
        'validation_warnings', '[]'::jsonb,
        'blocking_conditions', '[]'::jsonb,
        'audit_transaction_id', v_audit_id,
        'organization_id', v_organization_id,
        'site_id', p_site_id,
        'building_id', v_building_id,
        'building_code', v_code,
        'building_name', v_name
    );

    INSERT INTO admin.onboarding_audit
    (id, requested_by, request_payload, result_payload)
    VALUES
    (v_audit_id, v_actor_username, v_request, v_result);

    RETURN v_result;
END;
$function$;


CREATE OR REPLACE FUNCTION admin.create_floor
(
    p_actor_portal_user_id BIGINT,
    p_building_id UUID,
    p_name TEXT,
    p_code TEXT
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO pg_catalog, admin, metadata, config
AS $function$
DECLARE
    v_actor_username TEXT;
    v_organization_id UUID;
    v_site_id UUID;
    v_name TEXT := btrim(p_name);
    v_code TEXT := upper(btrim(p_code));
    v_floor_id UUID;
    v_audit_id UUID := gen_random_uuid();
    v_request JSONB;
    v_result JSONB;
BEGIN
    SELECT portal_user.username
    INTO v_actor_username
    FROM admin.portal_users AS portal_user
    WHERE portal_user.portal_user_id = p_actor_portal_user_id
      AND portal_user.is_active = TRUE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Active portal actor was not found.'
            USING ERRCODE = '42501';
    END IF;

    IF NOT admin.portal_user_has_permission(
        p_actor_portal_user_id,
        'location.manage'
    ) THEN
        RAISE EXCEPTION
            'Portal actor is not authorized to create locations.'
            USING ERRCODE = '42501';
    END IF;

    SELECT
        building.organization_id,
        building.site_id
    INTO
        v_organization_id,
        v_site_id
    FROM metadata.buildings AS building
    WHERE building.id = p_building_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Select a valid building.'
            USING ERRCODE = '22023';
    END IF;

    IF NOT admin.portal_user_can_access_site(
        p_actor_portal_user_id,
        v_site_id
    ) THEN
        RAISE EXCEPTION 'Portal actor cannot access the building site.'
            USING ERRCODE = '42501';
    END IF;

    IF v_name IS NULL OR v_name = '' OR length(v_name) > 200 THEN
        RAISE EXCEPTION 'Floor name is required and must not exceed 200 characters.'
            USING ERRCODE = '22023';
    END IF;

    IF v_code IS NULL
       OR v_code = ''
       OR length(v_code) > 100
       OR v_code !~ '^[A-Z][A-Z0-9_]*$' THEN
        RAISE EXCEPTION
            'Floor code must start with A-Z and contain only A-Z, 0-9, and underscore.'
            USING ERRCODE = '22023';
    END IF;

    BEGIN
        INSERT INTO metadata.floors
        (
            organization_id,
            building_id,
            name,
            code
        )
        VALUES
        (
            v_organization_id,
            p_building_id,
            v_name,
            v_code
        )
        RETURNING id INTO v_floor_id;
    EXCEPTION
        WHEN unique_violation THEN
            RAISE EXCEPTION
                'Floor code % already exists in the selected building.',
                v_code
                USING ERRCODE = '23505';
    END;

    v_request := jsonb_build_object
    (
        'operation', 'CREATE_FLOOR',
        'actor_portal_user_id', p_actor_portal_user_id,
        'building_id', p_building_id,
        'name', v_name,
        'code', v_code
    );

    v_result := jsonb_build_object
    (
        'success', TRUE,
        'entity_type', 'FLOOR',
        'entity_id', v_floor_id,
        'lifecycle_status', NULL,
        'commissioning_status', NULL,
        'validation_warnings', '[]'::jsonb,
        'blocking_conditions', '[]'::jsonb,
        'audit_transaction_id', v_audit_id,
        'organization_id', v_organization_id,
        'site_id', v_site_id,
        'building_id', p_building_id,
        'floor_id', v_floor_id,
        'floor_code', v_code,
        'floor_name', v_name
    );

    INSERT INTO admin.onboarding_audit
    (id, requested_by, request_payload, result_payload)
    VALUES
    (v_audit_id, v_actor_username, v_request, v_result);

    RETURN v_result;
END;
$function$;


CREATE OR REPLACE FUNCTION admin.create_space
(
    p_actor_portal_user_id BIGINT,
    p_floor_id UUID,
    p_name TEXT,
    p_code TEXT
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO pg_catalog, admin, metadata, config
AS $function$
DECLARE
    v_actor_username TEXT;
    v_organization_id UUID;
    v_building_id UUID;
    v_site_id UUID;
    v_name TEXT := btrim(p_name);
    v_code TEXT := upper(btrim(p_code));
    v_space_id UUID;
    v_audit_id UUID := gen_random_uuid();
    v_request JSONB;
    v_result JSONB;
BEGIN
    SELECT portal_user.username
    INTO v_actor_username
    FROM admin.portal_users AS portal_user
    WHERE portal_user.portal_user_id = p_actor_portal_user_id
      AND portal_user.is_active = TRUE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Active portal actor was not found.'
            USING ERRCODE = '42501';
    END IF;

    IF NOT admin.portal_user_has_permission(
        p_actor_portal_user_id,
        'location.manage'
    ) THEN
        RAISE EXCEPTION
            'Portal actor is not authorized to create locations.'
            USING ERRCODE = '42501';
    END IF;

    SELECT
        floor_record.organization_id,
        floor_record.building_id,
        building.site_id
    INTO
        v_organization_id,
        v_building_id,
        v_site_id
    FROM metadata.floors AS floor_record
    JOIN metadata.buildings AS building
      ON building.id = floor_record.building_id
    WHERE floor_record.id = p_floor_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Select a valid floor.'
            USING ERRCODE = '22023';
    END IF;

    IF NOT admin.portal_user_can_access_site(
        p_actor_portal_user_id,
        v_site_id
    ) THEN
        RAISE EXCEPTION 'Portal actor cannot access the floor site.'
            USING ERRCODE = '42501';
    END IF;

    IF v_name IS NULL OR v_name = '' OR length(v_name) > 200 THEN
        RAISE EXCEPTION 'Space name is required and must not exceed 200 characters.'
            USING ERRCODE = '22023';
    END IF;

    IF v_code IS NULL
       OR v_code = ''
       OR length(v_code) > 100
       OR v_code !~ '^[A-Z][A-Z0-9_]*$' THEN
        RAISE EXCEPTION
            'Space code must start with A-Z and contain only A-Z, 0-9, and underscore.'
            USING ERRCODE = '22023';
    END IF;

    BEGIN
        INSERT INTO metadata.spaces
        (
            organization_id,
            floor_id,
            name,
            code
        )
        VALUES
        (
            v_organization_id,
            p_floor_id,
            v_name,
            v_code
        )
        RETURNING id INTO v_space_id;
    EXCEPTION
        WHEN unique_violation THEN
            RAISE EXCEPTION
                'Space code % already exists in the selected floor.',
                v_code
                USING ERRCODE = '23505';
    END;

    v_request := jsonb_build_object
    (
        'operation', 'CREATE_SPACE',
        'actor_portal_user_id', p_actor_portal_user_id,
        'floor_id', p_floor_id,
        'name', v_name,
        'code', v_code
    );

    v_result := jsonb_build_object
    (
        'success', TRUE,
        'entity_type', 'SPACE',
        'entity_id', v_space_id,
        'lifecycle_status', NULL,
        'commissioning_status', NULL,
        'validation_warnings', '[]'::jsonb,
        'blocking_conditions', '[]'::jsonb,
        'audit_transaction_id', v_audit_id,
        'organization_id', v_organization_id,
        'site_id', v_site_id,
        'building_id', v_building_id,
        'floor_id', p_floor_id,
        'space_id', v_space_id,
        'space_code', v_code,
        'space_name', v_name
    );

    INSERT INTO admin.onboarding_audit
    (id, requested_by, request_payload, result_payload)
    VALUES
    (v_audit_id, v_actor_username, v_request, v_result);

    RETURN v_result;
END;
$function$;


CREATE OR REPLACE FUNCTION admin.list_accessible_physical_locations
(
    p_actor_portal_user_id BIGINT
)
RETURNS TABLE
(
    organization_id UUID,
    organization_code TEXT,
    organization_name TEXT,
    site_id UUID,
    site_code TEXT,
    site_name TEXT,
    building_id UUID,
    building_code TEXT,
    building_name TEXT,
    floor_id UUID,
    floor_code TEXT,
    floor_name TEXT,
    space_id UUID,
    space_code TEXT,
    space_name TEXT
)
LANGUAGE SQL
SECURITY DEFINER
STABLE
SET search_path TO pg_catalog, admin, metadata
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
    FROM admin.list_accessible_sites(p_actor_portal_user_id) AS accessible_site
    JOIN metadata.sites AS site_record
      ON site_record.id = accessible_site.id
    JOIN metadata.organizations AS organization_record
      ON organization_record.id = site_record.organization_id
    LEFT JOIN metadata.buildings AS building
      ON building.site_id = site_record.id
    LEFT JOIN metadata.floors AS floor_record
      ON floor_record.building_id = building.id
    LEFT JOIN metadata.spaces AS space_record
      ON space_record.floor_id = floor_record.id
    ORDER BY
        organization_record.name,
        site_record.name,
        building.name NULLS FIRST,
        floor_record.name NULLS FIRST,
        space_record.name NULLS FIRST;
$function$;


COMMENT ON FUNCTION admin.create_site(BIGINT, UUID, TEXT, TEXT, TEXT, TEXT) IS
'Creates one site independently under an authorized organization and records the shared entity result contract in the audit log.';

COMMENT ON FUNCTION admin.create_building(BIGINT, UUID, TEXT, TEXT) IS
'Creates one building under an accessible site and records the shared entity result contract in the audit log.';

COMMENT ON FUNCTION admin.create_floor(BIGINT, UUID, TEXT, TEXT) IS
'Creates one floor under an accessible building and records the shared entity result contract in the audit log.';

COMMENT ON FUNCTION admin.create_space(BIGINT, UUID, TEXT, TEXT) IS
'Creates one space under an accessible floor and records the shared entity result contract in the audit log.';

COMMENT ON FUNCTION admin.list_accessible_physical_locations(BIGINT) IS
'Lists the complete physical-location hierarchy for sites accessible to one active portal user.';


ALTER FUNCTION admin.portal_user_has_permission(BIGINT, TEXT)
    OWNER TO ems_admin;
ALTER FUNCTION metadata.prevent_site_organization_change()
    OWNER TO ems_admin;
ALTER FUNCTION admin.create_site(BIGINT, UUID, TEXT, TEXT, TEXT, TEXT)
    OWNER TO ems_admin;
ALTER FUNCTION admin.create_building(BIGINT, UUID, TEXT, TEXT)
    OWNER TO ems_admin;
ALTER FUNCTION admin.create_floor(BIGINT, UUID, TEXT, TEXT)
    OWNER TO ems_admin;
ALTER FUNCTION admin.create_space(BIGINT, UUID, TEXT, TEXT)
    OWNER TO ems_admin;
ALTER FUNCTION admin.list_accessible_physical_locations(BIGINT)
    OWNER TO ems_admin;


REVOKE ALL
    ON FUNCTION admin.portal_user_has_permission(BIGINT, TEXT)
    FROM PUBLIC;
REVOKE ALL
    ON FUNCTION admin.create_site(BIGINT, UUID, TEXT, TEXT, TEXT, TEXT)
    FROM PUBLIC;
REVOKE ALL
    ON FUNCTION admin.create_building(BIGINT, UUID, TEXT, TEXT)
    FROM PUBLIC;
REVOKE ALL
    ON FUNCTION admin.create_floor(BIGINT, UUID, TEXT, TEXT)
    FROM PUBLIC;
REVOKE ALL
    ON FUNCTION admin.create_space(BIGINT, UUID, TEXT, TEXT)
    FROM PUBLIC;
REVOKE ALL
    ON FUNCTION admin.list_accessible_physical_locations(BIGINT)
    FROM PUBLIC;


GRANT EXECUTE
    ON FUNCTION admin.create_site(BIGINT, UUID, TEXT, TEXT, TEXT, TEXT)
    TO ems_app;
GRANT EXECUTE
    ON FUNCTION admin.create_building(BIGINT, UUID, TEXT, TEXT)
    TO ems_app;
GRANT EXECUTE
    ON FUNCTION admin.create_floor(BIGINT, UUID, TEXT, TEXT)
    TO ems_app;
GRANT EXECUTE
    ON FUNCTION admin.create_space(BIGINT, UUID, TEXT, TEXT)
    TO ems_app;
GRANT EXECUTE
    ON FUNCTION admin.list_accessible_physical_locations(BIGINT)
    TO ems_app;
