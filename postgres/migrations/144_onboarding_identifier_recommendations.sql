-- Migration 144
-- Return available scoped identifier recommendations during onboarding
-- instead of rejecting duplicate machine identifiers.

BEGIN;

CREATE OR REPLACE FUNCTION admin.validate_onboarding_field(
    p_actor_portal_user_id bigint,
    p_draft_token uuid,
    p_step text,
    p_field text,
    p_value text,
    p_form jsonb DEFAULT '{}'::jsonb
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, admin, metadata, config
AS $$
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

    IF v_actor.role_code <> 'PLATFORM_ADMIN' AND v_org_id IS DISTINCT FROM v_actor.organization_id THEN
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
        SELECT EXISTS(SELECT 1 FROM metadata.organizations o WHERE o.id=v_id AND o.is_active AND (v_actor.role_code='PLATFORM_ADMIN' OR v_actor.organization_id=o.id)) INTO v_exists;
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
$$;

ALTER FUNCTION admin.validate_onboarding_field(
    BIGINT,
    UUID,
    TEXT,
    TEXT,
    TEXT,
    JSONB
)
OWNER TO ems_admin;

REVOKE ALL ON FUNCTION admin.validate_onboarding_field(
    BIGINT,
    UUID,
    TEXT,
    TEXT,
    TEXT,
    JSONB
)
FROM PUBLIC;

GRANT EXECUTE ON FUNCTION admin.validate_onboarding_field(
    BIGINT,
    UUID,
    TEXT,
    TEXT,
    TEXT,
    JSONB
)
TO ems_app;

COMMIT;
