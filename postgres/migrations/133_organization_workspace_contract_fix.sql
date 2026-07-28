BEGIN;

CREATE OR REPLACE FUNCTION admin.get_organization_workspace(
    p_actor_portal_user_id BIGINT,
    p_organization_id UUID
) RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, admin, metadata
AS $$
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

    IF v_actor.role_code <> 'PLATFORM_ADMIN'
       AND v_actor.organization_id IS DISTINCT FROM p_organization_id THEN
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
$$;

CREATE OR REPLACE FUNCTION admin.create_organization_workspace(
    p_actor_portal_user_id BIGINT,
    p_requested_by TEXT,
    p_name TEXT,
    p_code TEXT,
    p_legal_name TEXT,
    p_timezone TEXT,
    p_locale TEXT,
    p_lifecycle_status TEXT,
    p_primary_contact JSONB,
    p_address JSONB,
    p_notes TEXT
) RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, admin, metadata
AS $$
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

    IF NOT FOUND OR v_actor.role_code <> 'PLATFORM_ADMIN' THEN
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
$$;

CREATE OR REPLACE FUNCTION admin.update_organization_workspace(
    p_actor_portal_user_id BIGINT,
    p_organization_id UUID,
    p_name TEXT,
    p_legal_name TEXT,
    p_timezone TEXT,
    p_locale TEXT,
    p_lifecycle_status TEXT,
    p_primary_contact JSONB,
    p_address JSONB,
    p_notes TEXT
) RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, admin, metadata
AS $$
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

    IF NOT FOUND OR v_actor.role_code <> 'PLATFORM_ADMIN' THEN
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
$$;

ALTER FUNCTION admin.get_organization_workspace(BIGINT, UUID)
    OWNER TO ems_admin;

ALTER FUNCTION admin.create_organization_workspace(
    BIGINT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, JSONB, JSONB, TEXT
) OWNER TO ems_admin;

ALTER FUNCTION admin.update_organization_workspace(
    BIGINT, UUID, TEXT, TEXT, TEXT, TEXT, TEXT, JSONB, JSONB, TEXT
) OWNER TO ems_admin;

REVOKE ALL ON FUNCTION admin.get_organization_workspace(BIGINT, UUID)
    FROM PUBLIC;

REVOKE ALL ON FUNCTION admin.create_organization_workspace(
    BIGINT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, JSONB, JSONB, TEXT
) FROM PUBLIC;

REVOKE ALL ON FUNCTION admin.update_organization_workspace(
    BIGINT, UUID, TEXT, TEXT, TEXT, TEXT, TEXT, JSONB, JSONB, TEXT
) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION admin.get_organization_workspace(BIGINT, UUID)
    TO ems_app;

GRANT EXECUTE ON FUNCTION admin.create_organization_workspace(
    BIGINT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, JSONB, JSONB, TEXT
) TO ems_app;

GRANT EXECUTE ON FUNCTION admin.update_organization_workspace(
    BIGINT, UUID, TEXT, TEXT, TEXT, TEXT, TEXT, JSONB, JSONB, TEXT
) TO ems_app;

COMMIT;
