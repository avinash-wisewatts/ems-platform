BEGIN;

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
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, admin, metadata
AS $$
DECLARE
    v_actor admin.portal_users%ROWTYPE;
    v_result JSONB;
    v_organization_id UUID;
BEGIN
    SELECT * INTO v_actor
      FROM admin.portal_users
     WHERE id = p_actor_portal_user_id
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
    ) INTO v_result;

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

ALTER FUNCTION admin.create_organization_workspace(
    BIGINT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, JSONB, JSONB, TEXT
) OWNER TO ems_admin;

REVOKE ALL ON FUNCTION admin.create_organization_workspace(
    BIGINT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, JSONB, JSONB, TEXT
) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION admin.create_organization_workspace(
    BIGINT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, JSONB, JSONB, TEXT
) TO ems_app;

GRANT EXECUTE ON FUNCTION admin.get_organization_workspace(BIGINT, UUID) TO ems_app;
GRANT EXECUTE ON FUNCTION admin.update_organization_workspace(
    BIGINT, UUID, TEXT, TEXT, TEXT, TEXT, TEXT, JSONB, JSONB, TEXT
) TO ems_app;

COMMIT;
