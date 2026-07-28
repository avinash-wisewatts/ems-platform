-- Epic 6: independent gateway management (Stories 6.1 and 6.2)

ALTER TABLE metadata.gateways
    ADD COLUMN IF NOT EXISTS building_id UUID
        REFERENCES metadata.buildings(id) ON DELETE SET NULL,
    ADD COLUMN IF NOT EXISTS floor_id UUID
        REFERENCES metadata.floors(id) ON DELETE SET NULL;

CREATE INDEX IF NOT EXISTS gateways_building_id_idx
    ON metadata.gateways(building_id);
CREATE INDEX IF NOT EXISTS gateways_floor_id_idx
    ON metadata.gateways(floor_id);

CREATE OR REPLACE FUNCTION metadata.validate_gateway_physical_location()
RETURNS TRIGGER
LANGUAGE plpgsql
SET search_path TO pg_catalog, metadata, admin
AS $function$
DECLARE
    v_site_organization_id UUID;
BEGIN
    SELECT organization_id INTO v_site_organization_id
    FROM metadata.sites WHERE id = NEW.site_id;
    IF v_site_organization_id IS DISTINCT FROM NEW.organization_id THEN
        RAISE EXCEPTION 'Gateway organization does not match its site.' USING ERRCODE='23514';
    END IF;
    IF NEW.building_id IS NOT NULL AND NOT EXISTS (
        SELECT 1 FROM metadata.buildings b
        WHERE b.id=NEW.building_id AND b.site_id=NEW.site_id
          AND b.organization_id=NEW.organization_id
    ) THEN
        RAISE EXCEPTION 'Gateway building does not belong to its organization and site.' USING ERRCODE='23514';
    END IF;
    IF NEW.floor_id IS NOT NULL AND NOT EXISTS (
        SELECT 1 FROM metadata.floors f
        JOIN metadata.buildings b ON b.id=f.building_id
        WHERE f.id=NEW.floor_id AND b.site_id=NEW.site_id
          AND f.organization_id=NEW.organization_id
          AND (NEW.building_id IS NULL OR b.id=NEW.building_id)
    ) THEN
        RAISE EXCEPTION 'Gateway floor does not belong to its selected building and site.' USING ERRCODE='23514';
    END IF;
    IF NEW.space_id IS NOT NULL AND NOT EXISTS (
        SELECT 1 FROM metadata.spaces sp
        JOIN metadata.floors f ON f.id=sp.floor_id
        JOIN metadata.buildings b ON b.id=f.building_id
        WHERE sp.id=NEW.space_id AND b.site_id=NEW.site_id
          AND sp.organization_id=NEW.organization_id
          AND (NEW.floor_id IS NULL OR f.id=NEW.floor_id)
          AND (NEW.building_id IS NULL OR b.id=NEW.building_id)
    ) THEN
        RAISE EXCEPTION 'Gateway space does not belong to its selected floor and site.' USING ERRCODE='23514';
    END IF;
    RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS trg_validate_gateway_physical_location
    ON metadata.gateways;
CREATE TRIGGER trg_validate_gateway_physical_location
BEFORE INSERT OR UPDATE OF organization_id, site_id, building_id, floor_id, space_id
ON metadata.gateways
FOR EACH ROW EXECUTE FUNCTION metadata.validate_gateway_physical_location();

CREATE OR REPLACE FUNCTION admin.create_gateway(
    p_actor_portal_user_id BIGINT,
    p_organization_id UUID,
    p_site_id UUID,
    p_name TEXT,
    p_external_id TEXT,
    p_gateway_model_id UUID,
    p_lifecycle_status TEXT,
    p_building_id UUID DEFAULT NULL,
    p_floor_id UUID DEFAULT NULL,
    p_space_id UUID DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO pg_catalog, admin, metadata
AS $function$
DECLARE
    v_actor_username TEXT;
    v_name TEXT := btrim(p_name);
    v_external_id TEXT := upper(btrim(p_external_id));
    v_lifecycle TEXT := upper(btrim(p_lifecycle_status));
    v_gateway_id UUID;
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
        RAISE EXCEPTION 'Portal actor is not authorized to create gateways.' USING ERRCODE='42501';
    END IF;
    IF NOT EXISTS (
        SELECT 1 FROM metadata.sites s
        WHERE s.id=p_site_id AND s.organization_id=p_organization_id
          AND s.lifecycle_status IN ('DRAFT','ACTIVE')
    ) THEN
        RAISE EXCEPTION 'Select a draft or active site in the chosen organization.' USING ERRCODE='22023';
    END IF;
    IF NOT admin.portal_user_can_access_site(p_actor_portal_user_id, p_site_id) THEN
        RAISE EXCEPTION 'Portal actor cannot access the selected site.' USING ERRCODE='42501';
    END IF;
    IF v_name IS NULL OR v_name='' OR length(v_name)>200 THEN
        RAISE EXCEPTION 'Gateway name is required and must not exceed 200 characters.' USING ERRCODE='22023';
    END IF;
    IF v_external_id IS NULL OR v_external_id='' OR v_external_id !~ '^[A-Z0-9_]+$' OR length(v_external_id)>200 THEN
        RAISE EXCEPTION 'Gateway external ID may contain only letters, numbers, and underscores.' USING ERRCODE='22023';
    END IF;
    IF p_gateway_model_id IS NULL OR NOT EXISTS (
        SELECT 1 FROM metadata.gateway_models WHERE id=p_gateway_model_id
    ) THEN
        RAISE EXCEPTION 'Select a valid gateway model.' USING ERRCODE='22023';
    END IF;
    IF v_lifecycle NOT IN ('REGISTERED','COMMISSIONING','INACTIVE','DECOMMISSIONED') THEN
        RAISE EXCEPTION 'Select a valid gateway lifecycle status.' USING ERRCODE='22023';
    END IF;

    INSERT INTO metadata.gateways(
        organization_id, site_id, building_id, floor_id, space_id,
        gateway_model_id, name, external_id, lifecycle_status
    ) VALUES (
        p_organization_id, p_site_id, p_building_id, p_floor_id, p_space_id,
        p_gateway_model_id, v_name, v_external_id, v_lifecycle
    ) RETURNING id INTO v_gateway_id;

    v_result := jsonb_build_object(
        'success', TRUE, 'entity_type', 'GATEWAY',
        'entity_id', v_gateway_id, 'gateway_id', v_gateway_id,
        'organization_id', p_organization_id, 'site_id', p_site_id,
        'building_id', p_building_id, 'floor_id', p_floor_id,
        'space_id', p_space_id, 'gateway_model_id', p_gateway_model_id,
        'gateway_name', v_name, 'external_id', v_external_id,
        'lifecycle_status', v_lifecycle,
        'commissioning_status', 'NOT_STARTED',
        'validation_warnings', '[]'::jsonb,
        'blocking_conditions', '[]'::jsonb,
        'audit_transaction_id', v_audit_id
    );

    INSERT INTO admin.onboarding_audit(id, requested_by, request_payload, result_payload)
    VALUES (
        v_audit_id, v_actor_username,
        jsonb_build_object(
            'operation','CREATE_GATEWAY',
            'actor_portal_user_id',p_actor_portal_user_id,
            'organization_id',p_organization_id,'site_id',p_site_id,
            'building_id',p_building_id,'floor_id',p_floor_id,'space_id',p_space_id,
            'gateway_model_id',p_gateway_model_id,'name',v_name,
            'external_id',v_external_id,'lifecycle_status',v_lifecycle
        ), v_result
    );
    RETURN v_result;
EXCEPTION WHEN unique_violation THEN
    RAISE EXCEPTION 'A gateway with this external ID already exists in the organization.' USING ERRCODE='23505';
END;
$function$;

CREATE OR REPLACE FUNCTION admin.list_accessible_gateways(p_actor_portal_user_id BIGINT)
RETURNS TABLE(
    organization_id UUID, organization_code TEXT, organization_name TEXT,
    site_id UUID, site_code TEXT, site_name TEXT,
    gateway_id UUID, gateway_name TEXT, external_id TEXT,
    gateway_model_id UUID, gateway_vendor TEXT, gateway_model TEXT, gateway_protocol TEXT,
    building_id UUID, building_name TEXT, floor_id UUID, floor_name TEXT,
    space_id UUID, space_name TEXT, lifecycle_status TEXT
)
LANGUAGE SQL STABLE SECURITY DEFINER
SET search_path TO pg_catalog, admin, metadata
AS $function$
SELECT g.organization_id,o.code,o.name,g.site_id,s.code,s.name,
       g.id,g.name,g.external_id,g.gateway_model_id,gm.vendor,gm.model,gm.protocol,
       g.building_id,b.name,g.floor_id,f.name,g.space_id,sp.name,g.lifecycle_status
FROM metadata.gateways g
JOIN metadata.organizations o ON o.id=g.organization_id
JOIN metadata.sites s ON s.id=g.site_id
LEFT JOIN metadata.gateway_models gm ON gm.id=g.gateway_model_id
LEFT JOIN metadata.buildings b ON b.id=g.building_id
LEFT JOIN metadata.floors f ON f.id=g.floor_id
LEFT JOIN metadata.spaces sp ON sp.id=g.space_id
WHERE admin.portal_user_can_access_site(p_actor_portal_user_id,g.site_id)
ORDER BY o.name,s.name,g.name;
$function$;

ALTER FUNCTION metadata.validate_gateway_physical_location() OWNER TO ems_admin;
ALTER FUNCTION admin.create_gateway(BIGINT,UUID,UUID,TEXT,TEXT,UUID,TEXT,UUID,UUID,UUID) OWNER TO ems_admin;
ALTER FUNCTION admin.list_accessible_gateways(BIGINT) OWNER TO ems_admin;
REVOKE ALL ON FUNCTION metadata.validate_gateway_physical_location() FROM PUBLIC;
REVOKE ALL ON FUNCTION admin.create_gateway(BIGINT,UUID,UUID,TEXT,TEXT,UUID,TEXT,UUID,UUID,UUID) FROM PUBLIC;
REVOKE ALL ON FUNCTION admin.list_accessible_gateways(BIGINT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION admin.create_gateway(BIGINT,UUID,UUID,TEXT,TEXT,UUID,TEXT,UUID,UUID,UUID) TO ems_app;
GRANT EXECUTE ON FUNCTION admin.list_accessible_gateways(BIGINT) TO ems_app;
