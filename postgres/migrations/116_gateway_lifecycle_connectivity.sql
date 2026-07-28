-- Epic 6: gateway lifecycle and derived connectivity status (Story 6.3)

CREATE TABLE IF NOT EXISTS config.gateway_connectivity_policy (
    policy_id SMALLINT PRIMARY KEY DEFAULT 1 CHECK (policy_id = 1),
    online_threshold_seconds INTEGER NOT NULL DEFAULT 300
        CHECK (online_threshold_seconds BETWEEN 30 AND 86400),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

INSERT INTO config.gateway_connectivity_policy(policy_id, online_threshold_seconds)
VALUES (1, 300)
ON CONFLICT (policy_id) DO NOTHING;

CREATE OR REPLACE FUNCTION admin.update_gateway_lifecycle(
    p_actor_portal_user_id BIGINT,
    p_gateway_id UUID,
    p_lifecycle_status TEXT,
    p_change_reason TEXT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO pg_catalog, admin, metadata
AS $function$
DECLARE
    v_actor_username TEXT;
    v_gateway metadata.gateways%ROWTYPE;
    v_new_status TEXT := upper(btrim(p_lifecycle_status));
    v_reason TEXT := nullif(btrim(p_change_reason), '');
    v_audit_id UUID := gen_random_uuid();
    v_result JSONB;
BEGIN
    SELECT username INTO v_actor_username
    FROM admin.portal_users
    WHERE portal_user_id = p_actor_portal_user_id AND is_active = TRUE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Active portal actor was not found.' USING ERRCODE='42501';
    END IF;
    IF NOT admin.portal_user_has_permission(p_actor_portal_user_id, 'gateway.manage') THEN
        RAISE EXCEPTION 'Portal actor is not authorized to manage gateways.' USING ERRCODE='42501';
    END IF;

    SELECT * INTO v_gateway FROM metadata.gateways WHERE id = p_gateway_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Gateway was not found.' USING ERRCODE='22023';
    END IF;
    IF NOT admin.portal_user_can_access_site(p_actor_portal_user_id, v_gateway.site_id) THEN
        RAISE EXCEPTION 'Portal actor cannot access the gateway site.' USING ERRCODE='42501';
    END IF;
    IF v_new_status NOT IN ('REGISTERED','COMMISSIONING','INACTIVE','DECOMMISSIONED') THEN
        RAISE EXCEPTION 'Select a valid gateway lifecycle status.' USING ERRCODE='22023';
    END IF;
    IF v_gateway.lifecycle_status = 'DECOMMISSIONED' AND v_new_status <> 'DECOMMISSIONED' THEN
        RAISE EXCEPTION 'A decommissioned gateway cannot be reactivated through routine administration.' USING ERRCODE='22023';
    END IF;
    IF v_gateway.lifecycle_status = v_new_status THEN
        RAISE EXCEPTION 'Select a lifecycle status different from the current status.' USING ERRCODE='22023';
    END IF;
    IF v_new_status = 'DECOMMISSIONED' AND EXISTS (
        SELECT 1 FROM metadata.devices d
        WHERE d.gateway_id = p_gateway_id
          AND coalesce(d.lifecycle_status, 'REGISTERED') NOT IN ('INACTIVE','DECOMMISSIONED')
    ) THEN
        RAISE EXCEPTION 'Deactivate or decommission active devices before decommissioning this gateway.' USING ERRCODE='22023';
    END IF;

    UPDATE metadata.gateways SET lifecycle_status = v_new_status WHERE id = p_gateway_id;

    v_result := jsonb_build_object(
        'success', TRUE, 'entity_type', 'GATEWAY', 'entity_id', p_gateway_id,
        'gateway_id', p_gateway_id, 'organization_id', v_gateway.organization_id,
        'site_id', v_gateway.site_id, 'previous_lifecycle_status', v_gateway.lifecycle_status,
        'lifecycle_status', v_new_status, 'change_reason', v_reason,
        'audit_transaction_id', v_audit_id
    );

    INSERT INTO admin.onboarding_audit(id, requested_by, request_payload, result_payload)
    VALUES (
        v_audit_id, v_actor_username,
        jsonb_build_object(
            'operation','UPDATE_GATEWAY_LIFECYCLE', 'actor_portal_user_id',p_actor_portal_user_id,
            'gateway_id',p_gateway_id, 'organization_id',v_gateway.organization_id,
            'site_id',v_gateway.site_id, 'previous_lifecycle_status',v_gateway.lifecycle_status,
            'lifecycle_status',v_new_status, 'change_reason',v_reason
        ), v_result
    );
    RETURN v_result;
END;
$function$;

DROP FUNCTION IF EXISTS admin.list_accessible_gateways(BIGINT);

CREATE OR REPLACE FUNCTION admin.list_accessible_gateways(p_actor_portal_user_id BIGINT)
RETURNS TABLE(
    organization_id UUID, organization_code TEXT, organization_name TEXT,
    site_id UUID, site_code TEXT, site_name TEXT,
    gateway_id UUID, gateway_name TEXT, external_id TEXT,
    gateway_model_id UUID, gateway_vendor TEXT, gateway_model TEXT, gateway_protocol TEXT,
    building_id UUID, building_name TEXT, floor_id UUID, floor_name TEXT,
    space_id UUID, space_name TEXT, lifecycle_status TEXT,
    connectivity_status TEXT, last_seen_at TIMESTAMPTZ, online_threshold_seconds INTEGER
)
LANGUAGE SQL STABLE SECURITY DEFINER
SET search_path TO pg_catalog, admin, metadata, telemetry, config
AS $function$
WITH policy AS (
    SELECT online_threshold_seconds FROM config.gateway_connectivity_policy WHERE policy_id = 1
), last_seen AS (
    SELECT ds.gateway_id,
           max(coalesce(ds.last_successful_communication, ds.source_timestamp, ds.received_at)) AS last_seen_at
    FROM telemetry.device_status ds
    WHERE ds.gateway_id IS NOT NULL
    GROUP BY ds.gateway_id
)
SELECT g.organization_id,o.code,o.name,g.site_id,s.code,s.name,
       g.id,g.name,g.external_id,g.gateway_model_id,gm.vendor,gm.model,gm.protocol,
       g.building_id,b.name,g.floor_id,f.name,g.space_id,sp.name,g.lifecycle_status,
       CASE WHEN ls.last_seen_at IS NULL THEN 'NEVER_SEEN'
            WHEN ls.last_seen_at >= now() - make_interval(secs => p.online_threshold_seconds) THEN 'ONLINE'
            ELSE 'OFFLINE' END,
       ls.last_seen_at, p.online_threshold_seconds
FROM metadata.gateways g
JOIN metadata.organizations o ON o.id=g.organization_id
JOIN metadata.sites s ON s.id=g.site_id
LEFT JOIN metadata.gateway_models gm ON gm.id=g.gateway_model_id
LEFT JOIN metadata.buildings b ON b.id=g.building_id
LEFT JOIN metadata.floors f ON f.id=g.floor_id
LEFT JOIN metadata.spaces sp ON sp.id=g.space_id
CROSS JOIN policy p
LEFT JOIN last_seen ls ON ls.gateway_id=g.id
WHERE admin.portal_user_can_access_site(p_actor_portal_user_id,g.site_id)
ORDER BY o.name,s.name,g.name;
$function$;

ALTER FUNCTION admin.update_gateway_lifecycle(BIGINT,UUID,TEXT,TEXT) OWNER TO ems_admin;
ALTER FUNCTION admin.list_accessible_gateways(BIGINT) OWNER TO ems_admin;
REVOKE ALL ON FUNCTION admin.update_gateway_lifecycle(BIGINT,UUID,TEXT,TEXT) FROM PUBLIC;
REVOKE ALL ON FUNCTION admin.list_accessible_gateways(BIGINT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION admin.update_gateway_lifecycle(BIGINT,UUID,TEXT,TEXT) TO ems_app;
GRANT EXECUTE ON FUNCTION admin.list_accessible_gateways(BIGINT) TO ems_app;
