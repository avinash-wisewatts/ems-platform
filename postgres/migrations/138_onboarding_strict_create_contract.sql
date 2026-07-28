BEGIN;

-- Preserve the proven writer, but place a strict interactive contract in front
-- of it. The wrapper rejects duplicates before the legacy idempotent writer can
-- reuse or update an existing record.
DO $$
BEGIN
    IF to_regprocedure('admin.onboard_energy_asset_legacy_upsert(jsonb,text)') IS NULL THEN
        IF to_regprocedure('admin.onboard_energy_asset(jsonb,text)') IS NULL THEN
            RAISE EXCEPTION 'admin.onboard_energy_asset(jsonb,text) is missing';
        END IF;
        ALTER FUNCTION admin.onboard_energy_asset(jsonb,text)
            RENAME TO onboard_energy_asset_legacy_upsert;
    END IF;
END;
$$;

CREATE OR REPLACE FUNCTION admin.onboard_energy_asset(
    p_request jsonb,
    p_requested_by text DEFAULT CURRENT_USER
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, admin, metadata, config
AS $$
DECLARE
    v_org_mode text := upper(coalesce(nullif(btrim(p_request #>> '{organization,mode}'), ''), 'CREATE_NEW'));
    v_site_mode text := upper(coalesce(nullif(btrim(p_request #>> '{site,mode}'), ''), 'CREATE_NEW'));
    v_location_mode text := upper(coalesce(nullif(btrim(p_request #>> '{location,mode}'), ''), 'SITE_ONLY'));
    v_gateway_mode text := upper(coalesce(nullif(btrim(p_request #>> '{gateway,mode}'), ''), 'CREATE_NEW'));
    v_device_mode text := upper(coalesce(nullif(btrim(p_request #>> '{device,mode}'), ''), 'CREATE_NEW'));
    v_asset_mode text := upper(coalesce(nullif(btrim(p_request #>> '{asset,mode}'), ''), 'CREATE_NEW'));

    v_org_id uuid;
    v_site_id uuid;
    v_building_id uuid;
    v_floor_id uuid;
    v_gateway_id uuid;
    v_device_id uuid;
    v_asset_id uuid;

    v_org_name text := nullif(btrim(p_request #>> '{organization,name}'), '');
    v_org_code text := upper(nullif(btrim(p_request #>> '{organization,code}'), ''));
    v_site_name text := nullif(btrim(p_request #>> '{site,name}'), '');
    v_site_code text := upper(nullif(btrim(p_request #>> '{site,code}'), ''));
    v_building_name text := nullif(btrim(p_request #>> '{location,building_name}'), '');
    v_building_code text := upper(nullif(btrim(p_request #>> '{location,building_code}'), ''));
    v_floor_name text := nullif(btrim(p_request #>> '{location,floor_name}'), '');
    v_floor_code text := upper(nullif(btrim(p_request #>> '{location,floor_code}'), ''));
    v_space_name text := nullif(btrim(p_request #>> '{location,space_name}'), '');
    v_space_code text := upper(nullif(btrim(p_request #>> '{location,space_code}'), ''));
    v_gateway_external_id text := upper(nullif(btrim(p_request #>> '{gateway,external_id}'), ''));
    v_device_external_id text := upper(nullif(btrim(p_request #>> '{device,external_id}'), ''));
    v_identifier_type text := upper(nullif(btrim(p_request #>> '{device,identifier,type}'), ''));
    v_identifier_value text := nullif(btrim(p_request #>> '{device,identifier,value}'), '');
    v_asset_name text := nullif(btrim(p_request #>> '{asset,name}'), '');
    v_relationship_type text := upper(nullif(btrim(p_request #>> '{asset,relationship_type}'), ''));
    v_result jsonb;
BEGIN
    IF p_request IS NULL OR jsonb_typeof(p_request) <> 'object' THEN
        RAISE EXCEPTION 'Onboarding request must be a JSON object'
            USING ERRCODE = '22023';
    END IF;

    BEGIN
        v_org_id := nullif(coalesce(
            p_request #>> '{organization,id}',
            p_request #>> '{organization,existing_organization_id}'
        ), '')::uuid;
        v_site_id := nullif(coalesce(
            p_request #>> '{site,id}',
            p_request #>> '{site,existing_site_id}'
        ), '')::uuid;
        v_gateway_id := nullif(coalesce(
            p_request #>> '{gateway,id}',
            p_request #>> '{gateway,existing_gateway_id}'
        ), '')::uuid;
        v_device_id := nullif(coalesce(
            p_request #>> '{device,id}',
            p_request #>> '{device,existing_device_id}'
        ), '')::uuid;
        v_asset_id := nullif(coalesce(
            p_request #>> '{asset,id}',
            p_request #>> '{asset,existing_asset_id}'
        ), '')::uuid;
    EXCEPTION WHEN invalid_text_representation THEN
        RAISE EXCEPTION 'One or more selected records are invalid.'
            USING ERRCODE = '22023';
    END;

    -- Serialize competing interactive creates by natural identity. This closes
    -- the race between duplicate preflight and the existing writer.
    IF v_org_mode = 'CREATE_NEW' THEN
        PERFORM pg_advisory_xact_lock(hashtextextended('onboarding:org:code:' || coalesce(v_org_code, ''), 0));
        PERFORM pg_advisory_xact_lock(hashtextextended('onboarding:org:name:' || lower(coalesce(v_org_name, '')), 0));

        IF EXISTS (SELECT 1 FROM metadata.organizations o WHERE upper(btrim(o.code)) = v_org_code) THEN
            RAISE EXCEPTION 'An organization with code % already exists. Choose Use existing organization.', v_org_code
                USING ERRCODE = '23505', CONSTRAINT = 'onboarding_organization_code_unique';
        END IF;
        IF EXISTS (SELECT 1 FROM metadata.organizations o WHERE lower(btrim(o.name)) = lower(v_org_name)) THEN
            RAISE EXCEPTION 'An organization named % already exists. Choose Use existing organization.', v_org_name
                USING ERRCODE = '23505', CONSTRAINT = 'onboarding_organization_name_unique';
        END IF;
    ELSIF v_org_id IS NULL THEN
        RAISE EXCEPTION 'Select an existing organization.' USING ERRCODE = '22023';
    END IF;

    IF v_site_mode = 'CREATE_NEW' AND v_org_mode = 'USE_EXISTING' THEN
        PERFORM pg_advisory_xact_lock(hashtextextended('onboarding:site:code:' || v_org_id::text || ':' || coalesce(v_site_code, ''), 0));
        PERFORM pg_advisory_xact_lock(hashtextextended('onboarding:site:name:' || v_org_id::text || ':' || lower(coalesce(v_site_name, '')), 0));
        IF EXISTS (SELECT 1 FROM metadata.sites s WHERE s.organization_id = v_org_id AND upper(btrim(s.code)) = v_site_code) THEN
            RAISE EXCEPTION 'A site with code % already exists in this organization. Choose Use existing site.', v_site_code
                USING ERRCODE = '23505', CONSTRAINT = 'onboarding_site_code_unique';
        END IF;
        IF EXISTS (SELECT 1 FROM metadata.sites s WHERE s.organization_id = v_org_id AND lower(btrim(s.name)) = lower(v_site_name)) THEN
            RAISE EXCEPTION 'A site named % already exists in this organization. Choose Use existing site.', v_site_name
                USING ERRCODE = '23505', CONSTRAINT = 'onboarding_site_name_unique';
        END IF;
    ELSIF v_site_mode = 'USE_EXISTING' AND v_site_id IS NULL THEN
        RAISE EXCEPTION 'Select an existing site.' USING ERRCODE = '22023';
    END IF;

    IF v_location_mode = 'CREATE_LOCATION' AND v_site_mode = 'USE_EXISTING' THEN
        PERFORM pg_advisory_xact_lock(hashtextextended('onboarding:building:code:' || v_site_id::text || ':' || coalesce(v_building_code, ''), 0));
        IF EXISTS (SELECT 1 FROM metadata.buildings b WHERE b.site_id = v_site_id AND upper(btrim(b.code)) = v_building_code) THEN
            RAISE EXCEPTION 'A building with code % already exists at this site. Choose the existing location.', v_building_code
                USING ERRCODE = '23505', CONSTRAINT = 'onboarding_building_code_unique';
        END IF;
        IF EXISTS (SELECT 1 FROM metadata.buildings b WHERE b.site_id = v_site_id AND lower(btrim(b.name)) = lower(v_building_name)) THEN
            RAISE EXCEPTION 'A building named % already exists at this site. Choose the existing location.', v_building_name
                USING ERRCODE = '23505', CONSTRAINT = 'onboarding_building_name_unique';
        END IF;
    END IF;

    IF v_gateway_mode = 'CREATE_NEW' AND v_org_mode = 'USE_EXISTING' THEN
        PERFORM pg_advisory_xact_lock(hashtextextended('onboarding:gateway:external:' || v_org_id::text || ':' || coalesce(v_gateway_external_id, ''), 0));
        IF EXISTS (
            SELECT 1 FROM metadata.gateways g
            WHERE g.organization_id = v_org_id
              AND upper(btrim(coalesce(g.external_id, ''))) = v_gateway_external_id
        ) THEN
            RAISE EXCEPTION 'Gateway external ID % already exists. Choose Use existing gateway.', v_gateway_external_id
                USING ERRCODE = '23505', CONSTRAINT = 'onboarding_gateway_external_id_unique';
        END IF;
    ELSIF v_gateway_mode = 'USE_EXISTING' AND v_gateway_id IS NULL THEN
        RAISE EXCEPTION 'Select an existing gateway.' USING ERRCODE = '22023';
    END IF;

    IF v_device_mode = 'CREATE_NEW' THEN
        IF v_org_mode = 'USE_EXISTING' THEN
            PERFORM pg_advisory_xact_lock(hashtextextended('onboarding:device:external:' || v_org_id::text || ':' || coalesce(v_device_external_id, ''), 0));
            IF EXISTS (
                SELECT 1 FROM metadata.devices d
                WHERE d.organization_id = v_org_id
                  AND upper(btrim(coalesce(d.external_id, ''))) = v_device_external_id
            ) THEN
                RAISE EXCEPTION 'Device external ID % already exists. Choose Use existing device.', v_device_external_id
                    USING ERRCODE = '23505', CONSTRAINT = 'onboarding_device_external_id_unique';
            END IF;
        END IF;

        PERFORM pg_advisory_xact_lock(hashtextextended('onboarding:device:identifier:' || coalesce(v_identifier_type, '') || ':' || lower(coalesce(v_identifier_value, '')), 0));
        IF EXISTS (
            SELECT 1 FROM metadata.device_identifiers di
            WHERE upper(di.identifier_type) = v_identifier_type
              AND CASE WHEN v_identifier_type = 'MQTT_UID'
                       THEN lower(di.identifier_value) = lower(v_identifier_value)
                       ELSE di.identifier_value = v_identifier_value END
        ) THEN
            RAISE EXCEPTION 'Device identifier %:% already exists. Choose the existing device.', v_identifier_type, v_identifier_value
                USING ERRCODE = '23505', CONSTRAINT = 'onboarding_device_identifier_unique';
        END IF;
    ELSIF v_device_id IS NULL THEN
        RAISE EXCEPTION 'Select an existing device.' USING ERRCODE = '22023';
    END IF;

    IF v_asset_mode = 'CREATE_NEW' AND v_org_mode = 'USE_EXISTING' AND v_site_mode = 'USE_EXISTING' THEN
        PERFORM pg_advisory_xact_lock(hashtextextended('onboarding:asset:name:' || v_org_id::text || ':' || v_site_id::text || ':' || lower(coalesce(v_asset_name, '')), 0));
        IF EXISTS (
            SELECT 1 FROM metadata.assets a
            WHERE a.organization_id = v_org_id
              AND a.site_id = v_site_id
              AND a.parent_asset_id IS NULL
              AND lower(btrim(a.name)) = lower(v_asset_name)
        ) THEN
            RAISE EXCEPTION 'An asset named % already exists at this site. Choose Use existing asset.', v_asset_name
                USING ERRCODE = '23505', CONSTRAINT = 'onboarding_asset_name_unique';
        END IF;
    ELSIF v_asset_mode = 'USE_EXISTING' AND v_asset_id IS NULL THEN
        RAISE EXCEPTION 'Select an existing asset.' USING ERRCODE = '22023';
    END IF;

    IF v_asset_mode = 'USE_EXISTING' AND v_device_mode = 'USE_EXISTING' AND EXISTS (
        SELECT 1 FROM metadata.asset_devices ad
        WHERE ad.asset_id = v_asset_id
          AND ad.device_id = v_device_id
          AND ad.relationship_type = v_relationship_type
    ) THEN
        RAISE EXCEPTION 'This device already has the selected relationship with this asset.'
            USING ERRCODE = '23505', CONSTRAINT = 'onboarding_asset_device_relationship_unique';
    END IF;

    v_result := admin.onboard_energy_asset_legacy_upsert(p_request, p_requested_by);

    RETURN v_result || jsonb_build_object(
        'entity_outcomes', jsonb_build_object(
            'organization', CASE WHEN v_org_mode = 'CREATE_NEW' THEN 'CREATED' ELSE 'USED_EXISTING' END,
            'site', CASE WHEN v_site_mode = 'CREATE_NEW' THEN 'CREATED' ELSE 'USED_EXISTING' END,
            'location', CASE WHEN v_location_mode = 'CREATE_LOCATION' THEN 'CREATED'
                             WHEN v_location_mode = 'USE_EXISTING_SPACE' THEN 'USED_EXISTING'
                             ELSE 'SITE_ONLY' END,
            'gateway', CASE WHEN v_gateway_mode = 'CREATE_NEW' THEN 'CREATED' ELSE 'USED_EXISTING' END,
            'device', CASE WHEN v_device_mode = 'CREATE_NEW' THEN 'CREATED' ELSE 'USED_EXISTING' END,
            'asset', CASE WHEN v_asset_mode = 'CREATE_NEW' THEN 'CREATED' ELSE 'USED_EXISTING' END
        )
    );
END;
$$;

ALTER FUNCTION admin.onboard_energy_asset(jsonb,text) OWNER TO ems_admin;
REVOKE ALL ON FUNCTION admin.onboard_energy_asset(jsonb,text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION admin.onboard_energy_asset(jsonb,text) TO ems_app;

-- Expand immediate validation so every CREATE_NEW identity that can collide is
-- rejected on its own wizard step. Existing-record selectors remain scope
-- filtered in the UI and are rechecked here for tampered requests.
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
    v_id uuid;
    v_exists boolean;
    v_category uuid;
    v_building_id uuid;
    v_floor_id uuid;
BEGIN
    SELECT * INTO v_actor FROM admin.portal_users
    WHERE portal_user_id = p_actor_portal_user_id AND is_active;
    IF NOT FOUND THEN
        RETURN jsonb_build_object('valid',false,'field',p_field,'code','NOT_AUTHORIZED','message','Your session is no longer authorized.');
    END IF;

    IF p_draft_token IS NOT NULL THEN
        SELECT payload INTO v_payload FROM admin.onboarding_drafts
        WHERE draft_token = p_draft_token AND owner_portal_user_id = p_actor_portal_user_id AND status = 'DRAFT';
        IF NOT FOUND THEN
            RETURN jsonb_build_object('valid',false,'field',p_field,'code','DRAFT_NOT_FOUND','message','The onboarding draft is no longer available.');
        END IF;
    END IF;

    BEGIN
        v_org_id := coalesce(nullif(v_payload#>>'{organization,existing_organization_id}','')::uuid, nullif(p_form->>'existing_organization_id','')::uuid);
        v_site_id := coalesce(nullif(v_payload#>>'{site,existing_site_id}','')::uuid, nullif(p_form->>'existing_site_id','')::uuid);
        v_gateway_id := coalesce(nullif(v_payload#>>'{gateway,existing_gateway_id}','')::uuid, nullif(p_form->>'existing_gateway_id','')::uuid);
        v_building_id := nullif(p_form->>'building_id','')::uuid;
        v_floor_id := nullif(p_form->>'floor_id','')::uuid;
    EXCEPTION WHEN invalid_text_representation THEN
        RETURN jsonb_build_object('valid',false,'field',p_field,'code','INVALID_SELECTION','message','Select a valid record.');
    END;

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
        IF v_exists THEN RETURN jsonb_build_object('valid',false,'field',p_field,'code','DUPLICATE_NAME','message','An organization with this name already exists. Choose Use existing organization.'); END IF;
    ELSIF p_field = 'existing_site_id' THEN
        BEGIN v_id := p_value::uuid; EXCEPTION WHEN invalid_text_representation THEN v_id := NULL; END;
        SELECT EXISTS(SELECT 1 FROM metadata.sites s WHERE s.id=v_id AND s.organization_id=v_org_id AND s.is_active) INTO v_exists;
        IF NOT v_exists THEN RETURN jsonb_build_object('valid',false,'field',p_field,'code','INVALID_SITE','message','Select an active site belonging to the chosen organization.'); END IF;
    ELSIF p_field = 'site_code' AND v_org_id IS NOT NULL THEN
        SELECT EXISTS(SELECT 1 FROM metadata.sites s WHERE s.organization_id=v_org_id AND upper(btrim(s.code))=upper(btrim(p_value))) INTO v_exists;
        IF v_exists THEN RETURN jsonb_build_object('valid',false,'field',p_field,'code','DUPLICATE_CODE','message','This site code already exists in the organization. Choose Use existing site.'); END IF;
    ELSIF p_field = 'site_name' AND v_org_id IS NOT NULL THEN
        SELECT EXISTS(SELECT 1 FROM metadata.sites s WHERE s.organization_id=v_org_id AND lower(btrim(s.name))=lower(btrim(p_value))) INTO v_exists;
        IF v_exists THEN RETURN jsonb_build_object('valid',false,'field',p_field,'code','DUPLICATE_NAME','message','A site with this name already exists in the organization. Choose Use existing site.'); END IF;
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
        SELECT EXISTS(SELECT 1 FROM metadata.buildings b WHERE b.site_id=v_site_id AND upper(btrim(b.code))=upper(btrim(p_value))) INTO v_exists;
        IF v_exists THEN RETURN jsonb_build_object('valid',false,'field',p_field,'code','DUPLICATE_CODE','message','This building code already exists at the site. Choose the existing location.'); END IF;
    ELSIF p_field = 'building_name' AND v_site_id IS NOT NULL THEN
        SELECT EXISTS(SELECT 1 FROM metadata.buildings b WHERE b.site_id=v_site_id AND lower(btrim(b.name))=lower(btrim(p_value))) INTO v_exists;
        IF v_exists THEN RETURN jsonb_build_object('valid',false,'field',p_field,'code','DUPLICATE_NAME','message','A building with this name already exists at the site. Choose the existing location.'); END IF;
    ELSIF p_field = 'floor_code' AND v_building_id IS NOT NULL THEN
        SELECT EXISTS(SELECT 1 FROM metadata.floors f WHERE f.building_id=v_building_id AND upper(btrim(f.code))=upper(btrim(p_value))) INTO v_exists;
        IF v_exists THEN RETURN jsonb_build_object('valid',false,'field',p_field,'code','DUPLICATE_CODE','message','This floor code already exists in the building.'); END IF;
    ELSIF p_field = 'space_code' AND v_floor_id IS NOT NULL THEN
        SELECT EXISTS(SELECT 1 FROM metadata.spaces sp WHERE sp.floor_id=v_floor_id AND upper(btrim(sp.code))=upper(btrim(p_value))) INTO v_exists;
        IF v_exists THEN RETURN jsonb_build_object('valid',false,'field',p_field,'code','DUPLICATE_CODE','message','This space code already exists on the floor.'); END IF;
    ELSIF p_field = 'gateway_external_id' AND v_org_id IS NOT NULL THEN
        SELECT EXISTS(SELECT 1 FROM metadata.gateways g WHERE g.organization_id=v_org_id AND upper(btrim(coalesce(g.external_id,'')))=upper(btrim(p_value))) INTO v_exists;
        IF v_exists THEN RETURN jsonb_build_object('valid',false,'field',p_field,'code','DUPLICATE_EXTERNAL_ID','message','This gateway external ID already exists. Choose Use existing gateway.'); END IF;
    ELSIF p_field = 'existing_gateway_id' THEN
        BEGIN v_id := p_value::uuid; EXCEPTION WHEN invalid_text_representation THEN v_id := NULL; END;
        SELECT EXISTS(SELECT 1 FROM metadata.gateways g WHERE g.id=v_id AND g.organization_id=v_org_id AND g.site_id=v_site_id AND g.lifecycle_status NOT IN ('INACTIVE','DECOMMISSIONED')) INTO v_exists;
        IF NOT v_exists THEN RETURN jsonb_build_object('valid',false,'field',p_field,'code','INVALID_GATEWAY','message','Select an active gateway belonging to the chosen site.'); END IF;
    ELSIF p_field = 'device_external_id' AND v_org_id IS NOT NULL THEN
        SELECT EXISTS(SELECT 1 FROM metadata.devices d WHERE d.organization_id=v_org_id AND upper(btrim(coalesce(d.external_id,'')))=upper(btrim(p_value))) INTO v_exists;
        IF v_exists THEN RETURN jsonb_build_object('valid',false,'field',p_field,'code','DUPLICATE_EXTERNAL_ID','message','This device external ID already exists. Choose Use existing device.'); END IF;
    ELSIF p_field = 'new_identifier_value' THEN
        SELECT EXISTS(SELECT 1 FROM metadata.device_identifiers di WHERE upper(di.identifier_type)=upper(coalesce(p_form->>'new_identifier_type','MQTT_UID')) AND CASE WHEN upper(coalesce(p_form->>'new_identifier_type','MQTT_UID'))='MQTT_UID' THEN lower(di.identifier_value)=lower(btrim(p_value)) ELSE di.identifier_value=btrim(p_value) END) INTO v_exists;
        IF v_exists THEN RETURN jsonb_build_object('valid',false,'field',p_field,'code','DUPLICATE_IDENTIFIER','message','This device identifier already exists. Choose the existing device.'); END IF;
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
    ELSIF p_field = 'asset_name' AND v_org_id IS NOT NULL AND v_site_id IS NOT NULL THEN
        SELECT EXISTS(SELECT 1 FROM metadata.assets a WHERE a.organization_id=v_org_id AND a.site_id=v_site_id AND a.parent_asset_id IS NULL AND lower(btrim(a.name))=lower(btrim(p_value))) INTO v_exists;
        IF v_exists THEN RETURN jsonb_build_object('valid',false,'field',p_field,'code','DUPLICATE_NAME','message','An asset with this name already exists at the site. Choose Use existing asset.'); END IF;
    END IF;

    RETURN jsonb_build_object('valid',true,'field',p_field,'code','OK','message','');
END;
$$;

ALTER FUNCTION admin.validate_onboarding_field(bigint,uuid,text,text,text,jsonb) OWNER TO ems_admin;
REVOKE ALL ON FUNCTION admin.validate_onboarding_field(bigint,uuid,text,text,text,jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION admin.validate_onboarding_field(bigint,uuid,text,text,text,jsonb) TO ems_app;

COMMIT;
