CREATE OR REPLACE FUNCTION admin.get_location_workspace
(
    p_actor_portal_user_id BIGINT,
    p_location_type TEXT,
    p_location_id UUID
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
STABLE
SET search_path TO pg_catalog, admin, metadata
AS $function$
DECLARE
    v_type TEXT := upper(btrim(p_location_type));
    v_result JSONB;
BEGIN
    IF v_type = 'BUILDING' THEN
        SELECT jsonb_build_object(
            'location_type','BUILDING','location_id',b.id,
            'location_name',b.name,'location_code',b.code,
            'organization_id',o.id,'organization_name',o.name,
            'site_id',s.id,'site_name',s.name,
            'parent_id',s.id,'parent_name',s.name,
            'created_at',b.created_at,'updated_at',b.updated_at
        ) INTO v_result
        FROM metadata.buildings b
        JOIN metadata.sites s ON s.id=b.site_id
        JOIN metadata.organizations o ON o.id=b.organization_id
        WHERE b.id=p_location_id
          AND admin.portal_user_can_access_site(p_actor_portal_user_id,s.id);
    ELSIF v_type = 'FLOOR' THEN
        SELECT jsonb_build_object(
            'location_type','FLOOR','location_id',f.id,
            'location_name',f.name,'location_code',f.code,
            'organization_id',o.id,'organization_name',o.name,
            'site_id',s.id,'site_name',s.name,
            'building_id',b.id,'building_name',b.name,
            'parent_id',b.id,'parent_name',b.name,
            'created_at',f.created_at,'updated_at',f.updated_at
        ) INTO v_result
        FROM metadata.floors f
        JOIN metadata.buildings b ON b.id=f.building_id
        JOIN metadata.sites s ON s.id=b.site_id
        JOIN metadata.organizations o ON o.id=f.organization_id
        WHERE f.id=p_location_id
          AND admin.portal_user_can_access_site(p_actor_portal_user_id,s.id);
    ELSIF v_type = 'SPACE' THEN
        SELECT jsonb_build_object(
            'location_type','SPACE','location_id',sp.id,
            'location_name',sp.name,'location_code',sp.code,
            'organization_id',o.id,'organization_name',o.name,
            'site_id',s.id,'site_name',s.name,
            'building_id',b.id,'building_name',b.name,
            'floor_id',f.id,'floor_name',f.name,
            'parent_id',f.id,'parent_name',f.name,
            'created_at',sp.created_at,'updated_at',sp.updated_at
        ) INTO v_result
        FROM metadata.spaces sp
        JOIN metadata.floors f ON f.id=sp.floor_id
        JOIN metadata.buildings b ON b.id=f.building_id
        JOIN metadata.sites s ON s.id=b.site_id
        JOIN metadata.organizations o ON o.id=sp.organization_id
        WHERE sp.id=p_location_id
          AND admin.portal_user_can_access_site(p_actor_portal_user_id,s.id);
    ELSE
        RETURN NULL;
    END IF;
    RETURN v_result;
END;
$function$;

CREATE OR REPLACE FUNCTION admin.update_location_workspace
(
    p_actor_portal_user_id BIGINT,
    p_location_type TEXT,
    p_location_id UUID,
    p_name TEXT,
    p_change_reason TEXT
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO pg_catalog, admin, metadata
AS $function$
DECLARE
    v_type TEXT := upper(btrim(p_location_type));
    v_name TEXT := btrim(p_name);
    v_reason TEXT := btrim(p_change_reason);
    v_site_id UUID;
    v_old_name TEXT;
    v_code TEXT;
    v_actor_username TEXT;
    v_audit_id UUID := gen_random_uuid();
    v_result JSONB;
BEGIN
    SELECT pu.username INTO v_actor_username
    FROM admin.portal_users pu
    WHERE pu.portal_user_id=p_actor_portal_user_id
      AND pu.is_active=TRUE;
    IF NOT FOUND OR NOT admin.portal_user_has_permission(p_actor_portal_user_id,'location.manage') THEN
        RAISE EXCEPTION 'Portal actor is not authorized to update locations.' USING ERRCODE='42501';
    END IF;
    IF v_name IS NULL OR v_name='' OR length(v_name)>200 THEN
        RAISE EXCEPTION 'Location name is required and must not exceed 200 characters.' USING ERRCODE='22023';
    END IF;
    IF v_reason IS NULL OR v_reason='' OR length(v_reason)>1000 THEN
        RAISE EXCEPTION 'Change reason is required and must not exceed 1000 characters.' USING ERRCODE='22023';
    END IF;

    IF v_type='BUILDING' THEN
        SELECT b.site_id,b.name,b.code INTO v_site_id,v_old_name,v_code FROM metadata.buildings b WHERE b.id=p_location_id;
    ELSIF v_type='FLOOR' THEN
        SELECT b.site_id,f.name,f.code INTO v_site_id,v_old_name,v_code
        FROM metadata.floors f JOIN metadata.buildings b ON b.id=f.building_id WHERE f.id=p_location_id;
    ELSIF v_type='SPACE' THEN
        SELECT b.site_id,sp.name,sp.code INTO v_site_id,v_old_name,v_code
        FROM metadata.spaces sp JOIN metadata.floors f ON f.id=sp.floor_id
        JOIN metadata.buildings b ON b.id=f.building_id WHERE sp.id=p_location_id;
    ELSE
        RAISE EXCEPTION 'Select a valid location type.' USING ERRCODE='22023';
    END IF;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Location was not found.' USING ERRCODE='22023';
    END IF;
    IF NOT admin.portal_user_can_access_site(p_actor_portal_user_id,v_site_id) THEN
        RAISE EXCEPTION 'Portal actor cannot access this location.' USING ERRCODE='42501';
    END IF;

    IF v_type='BUILDING' THEN UPDATE metadata.buildings SET name=v_name,updated_at=now() WHERE id=p_location_id;
    ELSIF v_type='FLOOR' THEN UPDATE metadata.floors SET name=v_name,updated_at=now() WHERE id=p_location_id;
    ELSE UPDATE metadata.spaces SET name=v_name,updated_at=now() WHERE id=p_location_id;
    END IF;

    v_result := jsonb_build_object('success',TRUE,'location_type',v_type,'location_id',p_location_id,'location_name',v_name,'location_code',v_code,'site_id',v_site_id,'audit_transaction_id',v_audit_id);
    INSERT INTO admin.onboarding_audit(id,requested_by,request_payload,result_payload)
    VALUES(v_audit_id,v_actor_username,jsonb_build_object('operation','UPDATE_LOCATION','actor_portal_user_id',p_actor_portal_user_id,'location_type',v_type,'location_id',p_location_id,'old_name',v_old_name,'new_name',v_name,'change_reason',v_reason),v_result);
    RETURN v_result;
END;
$function$;

ALTER FUNCTION admin.get_location_workspace(BIGINT,TEXT,UUID) OWNER TO ems_admin;
ALTER FUNCTION admin.update_location_workspace(BIGINT,TEXT,UUID,TEXT,TEXT) OWNER TO ems_admin;
REVOKE ALL ON FUNCTION admin.get_location_workspace(BIGINT,TEXT,UUID) FROM PUBLIC;
REVOKE ALL ON FUNCTION admin.update_location_workspace(BIGINT,TEXT,UUID,TEXT,TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION admin.get_location_workspace(BIGINT,TEXT,UUID) TO ems_app;
GRANT EXECUTE ON FUNCTION admin.update_location_workspace(BIGINT,TEXT,UUID,TEXT,TEXT) TO ems_app;
