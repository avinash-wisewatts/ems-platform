BEGIN;

-- Migration 163
-- Align the strict onboarding wrapper with the established system-generated
-- identifier contract. Gateway, device, and asset external IDs are resolved by
-- the canonical writer through admin.recommend_available_identifier(). Building
-- codes are adjusted before the writer is called. Human display-name conflicts
-- and physical telemetry identifier conflicts remain strict.

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
        -- Building codes are system-generated identifiers. Resolve a collision
        -- instead of rejecting the onboarding transaction. Duplicate display
        -- names remain a deliberate USE_EXISTING decision below.
        v_building_code := admin.recommend_available_identifier(
            'BUILDING',
            v_building_code,
            v_org_id,
            v_site_id,
            NULL,
            NULL,
            NULL
        );
        p_request := jsonb_set(
            p_request,
            '{location,building_code}',
            to_jsonb(v_building_code),
            true
        );
        IF EXISTS (SELECT 1 FROM metadata.buildings b WHERE b.site_id = v_site_id AND lower(btrim(b.name)) = lower(v_building_name)) THEN
            RAISE EXCEPTION 'A building named % already exists at this site. Choose the existing location.', v_building_name
                USING ERRCODE = '23505', CONSTRAINT = 'onboarding_building_name_unique';
        END IF;
    END IF;

    IF v_gateway_mode = 'CREATE_NEW' AND v_org_mode = 'USE_EXISTING' THEN
        PERFORM pg_advisory_xact_lock(hashtextextended('onboarding:gateway:external:' || v_org_id::text || ':' || coalesce(v_gateway_external_id, ''), 0));
        -- Gateway external IDs are system-generated by the canonical writer.
        -- The writer resolves collisions with recommend_available_identifier().
        -- Keep the advisory lock so competing creates serialize safely.
    ELSIF v_gateway_mode = 'USE_EXISTING' AND v_gateway_id IS NULL THEN
        RAISE EXCEPTION 'Select an existing gateway.' USING ERRCODE = '22023';
    END IF;

    IF v_device_mode = 'CREATE_NEW' THEN
        IF v_org_mode = 'USE_EXISTING' THEN
            PERFORM pg_advisory_xact_lock(hashtextextended('onboarding:device:external:' || v_org_id::text || ':' || coalesce(v_device_external_id, ''), 0));
            -- Device external IDs are system-generated by the canonical writer.
            -- The writer resolves collisions with recommend_available_identifier().
            -- Device telemetry identifiers remain strict and are checked below.
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

COMMENT ON FUNCTION admin.onboard_energy_asset(jsonb,text) IS
    'Strict atomic onboarding contract: rejects duplicate human/telemetry identity while automatically resolving collisions in system-generated codes and external IDs.';

COMMIT;
