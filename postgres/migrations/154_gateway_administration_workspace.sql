CREATE OR REPLACE FUNCTION admin.get_gateway_workspace
(
    p_actor_portal_user_id BIGINT,
    p_gateway_id UUID
)
RETURNS JSONB
LANGUAGE SQL
SECURITY DEFINER
STABLE
SET search_path TO pg_catalog, admin, metadata, telemetry, config
AS $function$
WITH gateway_row AS (
    SELECT
        g.id AS gateway_id,
        g.organization_id,
        o.code AS organization_code,
        o.name AS organization_name,
        g.site_id,
        s.code AS site_code,
        s.name AS site_name,
        g.building_id,
        b.name AS building_name,
        g.floor_id,
        f.name AS floor_name,
        g.space_id,
        sp.name AS space_name,
        g.gateway_model_id,
        gm.vendor AS gateway_vendor,
        gm.model AS gateway_model,
        gm.protocol AS gateway_protocol,
        g.name AS gateway_name,
        g.external_id,
        g.lifecycle_status,
        g.created_at,
        (SELECT count(*) FROM metadata.devices d WHERE d.gateway_id=g.id) AS device_count,
        (SELECT max(coalesce(ds.last_successful_communication,ds.source_timestamp,ds.received_at))
           FROM telemetry.device_status ds WHERE ds.gateway_id=g.id) AS last_seen_at,
        (SELECT online_threshold_seconds FROM config.gateway_connectivity_policy WHERE policy_id=1) AS threshold
    FROM metadata.gateways g
    JOIN metadata.organizations o ON o.id=g.organization_id
    JOIN metadata.sites s ON s.id=g.site_id
    LEFT JOIN metadata.gateway_models gm ON gm.id=g.gateway_model_id
    LEFT JOIN metadata.buildings b ON b.id=g.building_id
    LEFT JOIN metadata.floors f ON f.id=g.floor_id
    LEFT JOIN metadata.spaces sp ON sp.id=g.space_id
    WHERE g.id=p_gateway_id
      AND admin.portal_user_can_access_site(p_actor_portal_user_id,g.site_id)
)
SELECT jsonb_build_object(
    'gateway_id',gateway_id,'organization_id',organization_id,
    'organization_code',organization_code,'organization_name',organization_name,
    'site_id',site_id,'site_code',site_code,'site_name',site_name,
    'building_id',building_id,'building_name',building_name,
    'floor_id',floor_id,'floor_name',floor_name,'space_id',space_id,'space_name',space_name,
    'gateway_model_id',gateway_model_id,'gateway_vendor',gateway_vendor,
    'gateway_model',gateway_model,'gateway_protocol',gateway_protocol,
    'gateway_name',gateway_name,'external_id',external_id,
    'lifecycle_status',lifecycle_status,'created_at',created_at,
    'device_count',device_count,'last_seen_at',last_seen_at,
    'connectivity_status',CASE WHEN last_seen_at IS NULL THEN 'NEVER_SEEN'
      WHEN last_seen_at >= now()-make_interval(secs=>threshold) THEN 'ONLINE' ELSE 'OFFLINE' END
)
FROM gateway_row;
$function$;

CREATE OR REPLACE FUNCTION admin.update_gateway_workspace
(
    p_actor_portal_user_id BIGINT,
    p_gateway_id UUID,
    p_gateway_name TEXT,
    p_gateway_model_id UUID,
    p_lifecycle_status TEXT,
    p_building_id UUID,
    p_floor_id UUID,
    p_space_id UUID,
    p_change_reason TEXT
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO pg_catalog, admin, metadata
AS $function$
DECLARE
    v_before metadata.gateways%ROWTYPE;
    v_name TEXT := btrim(p_gateway_name);
    v_status TEXT := upper(btrim(p_lifecycle_status));
    v_reason TEXT := btrim(p_change_reason);
    v_actor_username TEXT;
    v_audit_id UUID := gen_random_uuid();
    v_lifecycle JSONB;
    v_result JSONB;
BEGIN
    SELECT pu.username INTO v_actor_username
    FROM admin.portal_users pu
    WHERE pu.portal_user_id=p_actor_portal_user_id AND pu.is_active;
    IF NOT FOUND OR NOT admin.portal_user_has_permission(p_actor_portal_user_id,'gateway.manage') THEN
        RAISE EXCEPTION 'Portal actor is not authorized to update gateways.' USING ERRCODE='42501';
    END IF;

    SELECT * INTO v_before FROM metadata.gateways WHERE id=p_gateway_id FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'Gateway was not found.' USING ERRCODE='22023'; END IF;
    IF NOT admin.portal_user_can_access_site(p_actor_portal_user_id,v_before.site_id) THEN
        RAISE EXCEPTION 'Portal actor cannot access this gateway.' USING ERRCODE='42501';
    END IF;
    IF v_name='' OR length(v_name)>200 THEN
        RAISE EXCEPTION 'Gateway name is required and must not exceed 200 characters.' USING ERRCODE='22023';
    END IF;
    IF v_reason='' OR length(v_reason)>1000 THEN
        RAISE EXCEPTION 'Change reason is required and must not exceed 1000 characters.' USING ERRCODE='22023';
    END IF;
    IF v_status NOT IN ('REGISTERED','COMMISSIONING','ACTIVE','INACTIVE','DECOMMISSIONED') THEN
        RAISE EXCEPTION 'Select a valid gateway lifecycle status.' USING ERRCODE='22023';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM metadata.gateway_models gm WHERE gm.id=p_gateway_model_id) THEN
        RAISE EXCEPTION 'Select a valid gateway model.' USING ERRCODE='22023';
    END IF;
    IF p_floor_id IS NOT NULL AND p_building_id IS NULL THEN RAISE EXCEPTION 'A selected floor requires its building.' USING ERRCODE='22023'; END IF;
    IF p_space_id IS NOT NULL AND p_floor_id IS NULL THEN RAISE EXCEPTION 'A selected space requires its floor.' USING ERRCODE='22023'; END IF;
    IF p_building_id IS NOT NULL AND NOT EXISTS (SELECT 1 FROM metadata.buildings b WHERE b.id=p_building_id AND b.site_id=v_before.site_id) THEN RAISE EXCEPTION 'Selected building is not in the gateway site.' USING ERRCODE='22023'; END IF;
    IF p_floor_id IS NOT NULL AND NOT EXISTS (SELECT 1 FROM metadata.floors f JOIN metadata.buildings b ON b.id=f.building_id WHERE f.id=p_floor_id AND b.id=p_building_id AND b.site_id=v_before.site_id) THEN RAISE EXCEPTION 'Selected floor is not in the selected building.' USING ERRCODE='22023'; END IF;
    IF p_space_id IS NOT NULL AND NOT EXISTS (SELECT 1 FROM metadata.spaces sp WHERE sp.id=p_space_id AND sp.floor_id=p_floor_id) THEN RAISE EXCEPTION 'Selected space is not in the selected floor.' USING ERRCODE='22023'; END IF;

    UPDATE metadata.gateways
    SET name=v_name,gateway_model_id=p_gateway_model_id,
        building_id=p_building_id,floor_id=p_floor_id,space_id=p_space_id
    WHERE id=p_gateway_id;

    IF v_status IS DISTINCT FROM v_before.lifecycle_status THEN
        v_lifecycle := admin.transition_entity_lifecycle(
            p_actor_portal_user_id,'GATEWAY',p_gateway_id,v_status,v_reason,FALSE
        );
        IF NOT coalesce((v_lifecycle->>'success')::boolean,FALSE) THEN
            RAISE EXCEPTION '%',coalesce(v_lifecycle->>'failure_reason','Lifecycle transition was rejected.') USING ERRCODE='22023';
        END IF;
    END IF;

    v_result := jsonb_build_object('success',TRUE,'gateway_id',p_gateway_id,
        'lifecycle_status',v_status,'audit_transaction_id',v_audit_id);
    INSERT INTO admin.onboarding_audit(id,requested_by,request_payload,result_payload)
    VALUES(v_audit_id,v_actor_username,jsonb_build_object(
        'operation','UPDATE_GATEWAY','actor_portal_user_id',p_actor_portal_user_id,
        'gateway_id',p_gateway_id,'old_name',v_before.name,'new_name',v_name,
        'old_gateway_model_id',v_before.gateway_model_id,'new_gateway_model_id',p_gateway_model_id,
        'old_building_id',v_before.building_id,'new_building_id',p_building_id,
        'old_floor_id',v_before.floor_id,'new_floor_id',p_floor_id,
        'old_space_id',v_before.space_id,'new_space_id',p_space_id,
        'change_reason',v_reason),v_result);
    RETURN v_result;
END;
$function$;

ALTER FUNCTION admin.get_gateway_workspace(BIGINT,UUID) OWNER TO ems_admin;
ALTER FUNCTION admin.update_gateway_workspace(BIGINT,UUID,TEXT,UUID,TEXT,UUID,UUID,UUID,TEXT) OWNER TO ems_admin;
REVOKE ALL ON FUNCTION admin.get_gateway_workspace(BIGINT,UUID) FROM PUBLIC;
REVOKE ALL ON FUNCTION admin.update_gateway_workspace(BIGINT,UUID,TEXT,UUID,TEXT,UUID,UUID,UUID,TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION admin.get_gateway_workspace(BIGINT,UUID) TO ems_app;
GRANT EXECUTE ON FUNCTION admin.update_gateway_workspace(BIGINT,UUID,TEXT,UUID,TEXT,UUID,UUID,UUID,TEXT) TO ems_app;
