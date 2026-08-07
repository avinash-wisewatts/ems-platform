CREATE OR REPLACE FUNCTION admin.list_manageable_sites(p_actor_portal_user_id BIGINT)
RETURNS TABLE(
    site_id UUID,
    organization_id UUID,
    organization_code TEXT,
    organization_name TEXT,
    site_code TEXT,
    site_name TEXT,
    timezone TEXT,
    address JSONB,
    lifecycle_status TEXT,
    is_active BOOLEAN,
    created_at TIMESTAMPTZ,
    updated_at TIMESTAMPTZ
)
LANGUAGE SQL
SECURITY DEFINER
STABLE
SET search_path TO pg_catalog, admin, metadata
AS $function$
    SELECT
        s.id,
        s.organization_id,
        o.code,
        o.name,
        s.code,
        s.name,
        s.timezone,
        COALESCE(s.address, '{}'::jsonb),
        s.lifecycle_status,
        s.is_active,
        s.created_at,
        s.updated_at
    FROM metadata.sites AS s
    JOIN metadata.organizations AS o ON o.id = s.organization_id
    JOIN admin.portal_users AS u
      ON u.portal_user_id = p_actor_portal_user_id
     AND u.is_active = TRUE
    WHERE
        u.access_scope_mode = 'GLOBAL'
        OR (
            u.organization_id = s.organization_id
            AND (
                u.access_scope_mode = 'ORGANIZATION'
                OR (
                    u.access_scope_mode = 'SELECTED_SITES'
                    AND EXISTS (
                        SELECT 1
                        FROM admin.portal_user_site_access AS a
                        WHERE a.portal_user_id = u.portal_user_id
                          AND a.site_id = s.id
                    )
                )
            )
        )
    ORDER BY o.name, s.name, s.code, s.id;
$function$;

CREATE OR REPLACE FUNCTION admin.get_site_workspace(
    p_actor_portal_user_id BIGINT,
    p_site_id UUID
)
RETURNS JSONB
LANGUAGE SQL
SECURITY DEFINER
STABLE
SET search_path TO pg_catalog, admin, metadata
AS $function$
    SELECT to_jsonb(site_row)
    FROM admin.list_manageable_sites(p_actor_portal_user_id) AS site_row
    WHERE site_row.site_id = p_site_id;
$function$;

CREATE OR REPLACE FUNCTION admin.create_site_workspace(
    p_actor_portal_user_id BIGINT,
    p_organization_id UUID,
    p_name TEXT,
    p_code TEXT,
    p_timezone TEXT,
    p_lifecycle_status TEXT,
    p_address JSONB
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO pg_catalog, admin, metadata, config
AS $function$
DECLARE
    v_actor admin.portal_users%ROWTYPE;
    v_name TEXT := btrim(p_name);
    v_code TEXT := upper(btrim(p_code));
    v_timezone TEXT := btrim(p_timezone);
    v_status TEXT := upper(btrim(p_lifecycle_status));
    v_site_id UUID;
    v_audit_id UUID := gen_random_uuid();
    v_result JSONB;
BEGIN
    SELECT * INTO v_actor
    FROM admin.portal_users
    WHERE portal_user_id = p_actor_portal_user_id
      AND is_active = TRUE;

    IF NOT FOUND OR NOT admin.portal_user_has_permission(p_actor_portal_user_id, 'site.manage') THEN
        RAISE EXCEPTION 'Portal actor is not authorized to create sites.' USING ERRCODE='42501';
    END IF;

    IF v_actor.access_scope_mode = 'SELECTED_SITES' THEN
        RAISE EXCEPTION 'Selected-site access cannot create a new site.' USING ERRCODE='42501';
    END IF;

    IF v_actor.access_scope_mode <> 'GLOBAL'
       AND v_actor.organization_id IS DISTINCT FROM p_organization_id THEN
        RAISE EXCEPTION 'Portal actor cannot create a site for another organization.' USING ERRCODE='42501';
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM metadata.organizations o
        WHERE o.id = p_organization_id AND o.is_active = TRUE
    ) THEN
        RAISE EXCEPTION 'Select an active organization.' USING ERRCODE='22023';
    END IF;

    IF v_name = '' OR length(v_name) > 200 THEN
        RAISE EXCEPTION 'Enter a site name of 200 characters or fewer.' USING ERRCODE='22023';
    END IF;
    IF v_code = '' OR length(v_code) > 100 OR v_code !~ '^[A-Z][A-Z0-9_]*$' THEN
        RAISE EXCEPTION 'Site code is invalid.' USING ERRCODE='22023';
    END IF;
    IF v_timezone = '' OR NOT EXISTS (SELECT 1 FROM pg_timezone_names WHERE name = v_timezone) THEN
        RAISE EXCEPTION 'Select a valid IANA timezone.' USING ERRCODE='22023';
    END IF;
    IF v_status NOT IN ('DRAFT','ACTIVE','INACTIVE','DECOMMISSIONED') THEN
        RAISE EXCEPTION 'Select a valid site lifecycle status.' USING ERRCODE='22023';
    END IF;

    BEGIN
        INSERT INTO metadata.sites(
            organization_id, name, code, timezone, address,
            lifecycle_status, is_active
        ) VALUES (
            p_organization_id, v_name, v_code, v_timezone,
            COALESCE(p_address, '{}'::jsonb), v_status,
            v_status = 'ACTIVE'
        ) RETURNING id INTO v_site_id;
    EXCEPTION WHEN unique_violation THEN
        RAISE EXCEPTION 'Site code % already exists in the selected organization.', v_code USING ERRCODE='23505';
    END;

    v_result := jsonb_build_object(
        'success', TRUE, 'entity_type', 'SITE', 'entity_id', v_site_id,
        'site_id', v_site_id, 'organization_id', p_organization_id,
        'site_name', v_name, 'site_code', v_code, 'timezone', v_timezone,
        'lifecycle_status', v_status, 'audit_transaction_id', v_audit_id
    );

    INSERT INTO admin.onboarding_audit(id, requested_by, request_payload, result_payload)
    VALUES (
        v_audit_id,
        v_actor.username,
        jsonb_build_object(
            'operation','CREATE_SITE','actor_portal_user_id',p_actor_portal_user_id,
            'organization_id',p_organization_id,'name',v_name,'code',v_code,
            'timezone',v_timezone,'lifecycle_status',v_status,'address',COALESCE(p_address,'{}'::jsonb)
        ),
        v_result
    );

    RETURN v_result;
END;
$function$;

CREATE OR REPLACE FUNCTION admin.update_site_workspace(
    p_actor_portal_user_id BIGINT,
    p_site_id UUID,
    p_name TEXT,
    p_timezone TEXT,
    p_lifecycle_status TEXT,
    p_address JSONB,
    p_change_reason TEXT
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO pg_catalog, admin, metadata
AS $function$
DECLARE
    v_before metadata.sites%ROWTYPE;
    v_name TEXT := btrim(p_name);
    v_timezone TEXT := btrim(p_timezone);
    v_status TEXT := upper(btrim(p_lifecycle_status));
    v_reason TEXT := btrim(p_change_reason);
    v_lifecycle JSONB;
    v_audit_id UUID := gen_random_uuid();
BEGIN
    IF NOT admin.portal_user_has_permission(p_actor_portal_user_id, 'site.manage')
       OR NOT admin.portal_user_can_access_site(p_actor_portal_user_id, p_site_id) THEN
        RAISE EXCEPTION 'Portal actor is not authorized to update this site.' USING ERRCODE='42501';
    END IF;

    SELECT * INTO v_before
    FROM metadata.sites
    WHERE id = p_site_id
    FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Site was not found.' USING ERRCODE='22023';
    END IF;

    IF v_name = '' OR length(v_name) > 200 THEN
        RAISE EXCEPTION 'Enter a site name of 200 characters or fewer.' USING ERRCODE='22023';
    END IF;
    IF v_timezone = '' OR NOT EXISTS (SELECT 1 FROM pg_timezone_names WHERE name = v_timezone) THEN
        RAISE EXCEPTION 'Select a valid IANA timezone.' USING ERRCODE='22023';
    END IF;
    IF v_status NOT IN ('DRAFT','ACTIVE','INACTIVE','DECOMMISSIONED') THEN
        RAISE EXCEPTION 'Select a valid site lifecycle status.' USING ERRCODE='22023';
    END IF;
    IF v_reason = '' THEN
        RAISE EXCEPTION 'Change reason is required.' USING ERRCODE='22023';
    END IF;

    UPDATE metadata.sites
    SET name = v_name,
        timezone = v_timezone,
        address = COALESCE(p_address, '{}'::jsonb),
        updated_at = clock_timestamp()
    WHERE id = p_site_id;

    IF v_status IS DISTINCT FROM v_before.lifecycle_status THEN
        v_lifecycle := admin.transition_entity_lifecycle(
            p_actor_portal_user_id, 'SITE', p_site_id, v_status, v_reason, FALSE
        );
        IF NOT COALESCE((v_lifecycle->>'success')::boolean, FALSE) THEN
            RAISE EXCEPTION '%', COALESCE(v_lifecycle->>'failure_reason', 'Lifecycle transition was rejected.') USING ERRCODE='22023';
        END IF;
    END IF;

    PERFORM admin.write_audit_event(
        v_audit_id, p_actor_portal_user_id, 'UPDATE_SITE', 'SITE', p_site_id,
        v_before.organization_id, p_site_id,
        jsonb_build_object('name',v_before.name,'timezone',v_before.timezone,'address',v_before.address),
        jsonb_build_object('name',v_name,'timezone',v_timezone,'address',COALESCE(p_address,'{}'::jsonb),'change_reason',v_reason),
        'SUCCEEDED', NULL
    );

    RETURN jsonb_build_object(
        'success', TRUE, 'entity_type', 'SITE', 'entity_id', p_site_id,
        'site_id', p_site_id, 'organization_id', v_before.organization_id,
        'lifecycle_status', v_status, 'audit_transaction_id', v_audit_id
    );
END;
$function$;

ALTER FUNCTION admin.list_manageable_sites(BIGINT) OWNER TO ems_admin;
ALTER FUNCTION admin.get_site_workspace(BIGINT,UUID) OWNER TO ems_admin;
ALTER FUNCTION admin.create_site_workspace(BIGINT,UUID,TEXT,TEXT,TEXT,TEXT,JSONB) OWNER TO ems_admin;
ALTER FUNCTION admin.update_site_workspace(BIGINT,UUID,TEXT,TEXT,TEXT,JSONB,TEXT) OWNER TO ems_admin;
REVOKE ALL ON FUNCTION admin.list_manageable_sites(BIGINT) FROM PUBLIC;
REVOKE ALL ON FUNCTION admin.get_site_workspace(BIGINT,UUID) FROM PUBLIC;
REVOKE ALL ON FUNCTION admin.create_site_workspace(BIGINT,UUID,TEXT,TEXT,TEXT,TEXT,JSONB) FROM PUBLIC;
REVOKE ALL ON FUNCTION admin.update_site_workspace(BIGINT,UUID,TEXT,TEXT,TEXT,JSONB,TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION admin.list_manageable_sites(BIGINT) TO ems_app;
GRANT EXECUTE ON FUNCTION admin.get_site_workspace(BIGINT,UUID) TO ems_app;
GRANT EXECUTE ON FUNCTION admin.create_site_workspace(BIGINT,UUID,TEXT,TEXT,TEXT,TEXT,JSONB) TO ems_app;
GRANT EXECUTE ON FUNCTION admin.update_site_workspace(BIGINT,UUID,TEXT,TEXT,TEXT,JSONB,TEXT) TO ems_app;
