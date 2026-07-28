-- Migration 135: Hydrate the complete existing onboarding hierarchy.
-- Existing selections remain ID-only in the browser; PostgreSQL reloads
-- canonical organization, site, location, gateway, device, and asset data.

BEGIN;

CREATE OR REPLACE FUNCTION admin.submit_onboarding_draft
(
    p_draft_token uuid,
    p_portal_user_id bigint,
    p_role_code text,
    p_requested_by text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO pg_catalog, admin, metadata
AS $function$
DECLARE
    v_draft_payload jsonb;
    v_device_payload jsonb;
    v_identifier_payload jsonb;
    v_request_payload jsonb;
    v_result jsonb;
    v_requested_by text;
    v_verified_username text;
    v_actor_organization_id uuid;
    v_organization_payload jsonb;
    v_organization_mode text;
    v_existing_organization_id uuid;
    v_existing_organization_name text;
    v_existing_organization_code text;
    v_existing_organization_description text;
    v_site_payload jsonb;
    v_site_mode text;
    v_existing_site_id uuid;
    v_location_payload jsonb;
    v_location_mode text;
    v_existing_space_id uuid;
    v_gateway_payload jsonb;
    v_gateway_mode text;
    v_existing_gateway_id uuid;
    v_device_payload_existing jsonb;
    v_device_mode text;
    v_existing_device_id uuid;
    v_asset_payload jsonb;
    v_asset_mode text;
    v_existing_asset_id uuid;
BEGIN
    IF p_draft_token IS NULL THEN
        RAISE EXCEPTION
            'Onboarding draft token is required.';
    END IF;

    SELECT
        portal_user.username,
        portal_user.organization_id
    INTO
        v_verified_username,
        v_actor_organization_id
    FROM admin.portal_users AS portal_user
    WHERE portal_user.portal_user_id = p_portal_user_id
      AND portal_user.is_active = true
      AND portal_user.role_code = p_role_code;

    IF v_verified_username IS NULL THEN
        RAISE EXCEPTION
            'Authenticated portal identity is invalid or stale.';
    END IF;

    IF p_role_code NOT IN ('PLATFORM_ADMIN', 'ORG_ADMIN', 'OPERATOR') THEN
        RAISE EXCEPTION
            'Portal role is not permitted to submit onboarding drafts.';
    END IF;

    v_requested_by := COALESCE(
        NULLIF(btrim(p_requested_by), ''),
        v_verified_username
    );

    IF v_requested_by <> v_verified_username THEN
        RAISE EXCEPTION
            'Requested actor does not match authenticated portal identity.';
    END IF;

    SELECT draft.payload
    INTO v_draft_payload
    FROM admin.onboarding_drafts AS draft
    WHERE draft.draft_token = p_draft_token
      AND draft.status = 'DRAFT'
      AND draft.current_step = 'review'
      AND draft.expires_at > clock_timestamp()
      AND (
          p_role_code = 'PLATFORM_ADMIN'
          OR draft.owner_portal_user_id =
             p_portal_user_id
      )
    FOR UPDATE;

    IF v_draft_payload IS NULL THEN
        RAISE EXCEPTION
            'Onboarding draft was not found, expired, incomplete, already submitted, or is not owned by the authenticated user.';
    END IF;

    IF NOT (
        v_draft_payload ? 'organization'
        AND v_draft_payload ? 'site'
        AND v_draft_payload ? 'location'
        AND v_draft_payload ? 'gateway'
        AND v_draft_payload ? 'device'
        AND v_draft_payload ? 'asset'
    ) THEN
        RAISE EXCEPTION
            'Onboarding draft is missing one or more required modules.';
    END IF;

    -- Existing-organization drafts intentionally store only the selected ID.
    -- Resolve canonical organization attributes at submission time so the
    -- browser never becomes authoritative for organization identity data.
    v_organization_payload := COALESCE(
        v_draft_payload -> 'organization',
        '{}'::jsonb
    );

    v_organization_mode := upper(
        COALESCE(
            NULLIF(btrim(v_organization_payload ->> 'mode'), ''),
            'CREATE_NEW'
        )
    );

    IF v_organization_mode = 'USE_EXISTING' THEN
        BEGIN
            v_existing_organization_id := (
                v_organization_payload ->> 'existing_organization_id'
            )::uuid;
        EXCEPTION
            WHEN invalid_text_representation THEN
                RAISE EXCEPTION
                    'Select a valid existing organization.'
                    USING ERRCODE = '22023';
        END;

        IF v_existing_organization_id IS NULL THEN
            RAISE EXCEPTION
                'Select an existing organization.'
                USING ERRCODE = '22023';
        END IF;

        SELECT
            organization.name,
            organization.code,
            organization.description
        INTO
            v_existing_organization_name,
            v_existing_organization_code,
            v_existing_organization_description
        FROM metadata.organizations AS organization
        WHERE organization.id = v_existing_organization_id
          AND organization.is_active = true;

        IF v_existing_organization_name IS NULL THEN
            RAISE EXCEPTION
                'The selected organization is unavailable or inactive.'
                USING ERRCODE = 'P0002';
        END IF;

        IF p_role_code <> 'PLATFORM_ADMIN'
           AND v_actor_organization_id IS DISTINCT FROM
               v_existing_organization_id THEN
            RAISE EXCEPTION
                'The selected organization is outside your access scope.'
                USING ERRCODE = '42501';
        END IF;

        v_organization_payload :=
            v_organization_payload
            || jsonb_build_object(
                'mode', 'USE_EXISTING',
                'existing_organization_id',
                    v_existing_organization_id,
                'id', v_existing_organization_id,
                'name', v_existing_organization_name,
                'code', v_existing_organization_code,
                'description',
                    COALESCE(
                        v_existing_organization_description,
                        ''
                    )
            );

        v_draft_payload := jsonb_set(
            v_draft_payload,
            '{organization}',
            v_organization_payload,
            true
        );
    END IF;

    -- Hydrate an existing site and enforce organization ownership.
    v_site_payload := COALESCE(v_draft_payload -> 'site', '{}'::jsonb);
    v_site_mode := upper(COALESCE(NULLIF(btrim(v_site_payload ->> 'mode'), ''), 'CREATE_NEW'));

    IF v_site_mode = 'USE_EXISTING' THEN
        BEGIN
            v_existing_site_id := (v_site_payload ->> 'existing_site_id')::uuid;
        EXCEPTION WHEN invalid_text_representation THEN
            RAISE EXCEPTION 'Select a valid existing site.' USING ERRCODE = '22023';
        END;

        IF v_existing_site_id IS NULL THEN
            RAISE EXCEPTION 'Select an existing site.' USING ERRCODE = '22023';
        END IF;

        SELECT v_site_payload || jsonb_build_object(
                   'mode', 'USE_EXISTING',
                   'existing_site_id', s.id,
                   'id', s.id,
                   'name', s.name,
                   'code', s.code,
                   'timezone', s.timezone,
                   'address', COALESCE(s.address, '{}'::jsonb)
               )
        INTO v_site_payload
        FROM metadata.sites AS s
        WHERE s.id = v_existing_site_id
          AND s.organization_id = v_existing_organization_id
          AND s.is_active = true;

        IF v_site_payload IS NULL THEN
            RAISE EXCEPTION 'The selected site is unavailable or outside the selected organization.'
                USING ERRCODE = 'P0002';
        END IF;

        v_draft_payload := jsonb_set(v_draft_payload, '{site}', v_site_payload, true);
    END IF;

    -- Hydrate the complete physical hierarchy when an existing space is used.
    v_location_payload := COALESCE(v_draft_payload -> 'location', '{}'::jsonb);
    v_location_mode := upper(COALESCE(NULLIF(btrim(v_location_payload ->> 'mode'), ''), 'SITE_ONLY'));

    IF v_location_mode = 'USE_EXISTING_SPACE' THEN
        BEGIN
            v_existing_space_id := (v_location_payload ->> 'existing_space_id')::uuid;
        EXCEPTION WHEN invalid_text_representation THEN
            RAISE EXCEPTION 'Select a valid existing space.' USING ERRCODE = '22023';
        END;

        SELECT v_location_payload || jsonb_build_object(
                   'mode', 'USE_EXISTING_SPACE',
                   'existing_space_id', sp.id,
                   'space_id', sp.id,
                   'space_name', sp.name,
                   'space_code', sp.code,
                   'floor_id', f.id,
                   'floor_name', f.name,
                   'floor_code', f.code,
                   'building_id', b.id,
                   'building_name', b.name,
                   'building_code', b.code
               )
        INTO v_location_payload
        FROM metadata.spaces AS sp
        JOIN metadata.floors AS f ON f.id = sp.floor_id
        JOIN metadata.buildings AS b ON b.id = f.building_id
        WHERE sp.id = v_existing_space_id
          AND sp.organization_id = v_existing_organization_id
          AND b.site_id = v_existing_site_id;

        IF v_location_payload IS NULL THEN
            RAISE EXCEPTION 'The selected space is unavailable or outside the selected site.'
                USING ERRCODE = 'P0002';
        END IF;

        v_draft_payload := jsonb_set(v_draft_payload, '{location}', v_location_payload, true);
    END IF;

    -- Hydrate an existing gateway and verify tenant/site ownership.
    v_gateway_payload := COALESCE(v_draft_payload -> 'gateway', '{}'::jsonb);
    v_gateway_mode := upper(COALESCE(NULLIF(btrim(v_gateway_payload ->> 'mode'), ''), 'CREATE_NEW'));

    IF v_gateway_mode = 'USE_EXISTING' THEN
        BEGIN
            v_existing_gateway_id := (v_gateway_payload ->> 'existing_gateway_id')::uuid;
        EXCEPTION WHEN invalid_text_representation THEN
            RAISE EXCEPTION 'Select a valid existing gateway.' USING ERRCODE = '22023';
        END;

        SELECT v_gateway_payload || jsonb_build_object(
                   'mode', 'USE_EXISTING',
                   'existing_gateway_id', g.id,
                   'id', g.id,
                   'name', g.name,
                   'external_id', g.external_id,
                   'vendor', COALESCE(gm.vendor, ''),
                   'model', COALESCE(gm.model, ''),
                   'protocol', COALESCE(gm.protocol, '')
               )
        INTO v_gateway_payload
        FROM metadata.gateways AS g
        LEFT JOIN metadata.gateway_models AS gm ON gm.id = g.gateway_model_id
        WHERE g.id = v_existing_gateway_id
          AND g.organization_id = v_existing_organization_id
          AND g.site_id = v_existing_site_id;

        IF v_gateway_payload IS NULL THEN
            RAISE EXCEPTION 'The selected gateway is unavailable or outside the selected site.'
                USING ERRCODE = 'P0002';
        END IF;

        v_draft_payload := jsonb_set(v_draft_payload, '{gateway}', v_gateway_payload, true);
    END IF;

    -- Hydrate an existing device and its canonical model/profile attributes.
    v_device_payload_existing := COALESCE(v_draft_payload -> 'device', '{}'::jsonb);
    v_device_mode := upper(COALESCE(NULLIF(btrim(v_device_payload_existing ->> 'mode'), ''), 'CREATE_NEW'));

    IF v_device_mode = 'USE_EXISTING' THEN
        BEGIN
            v_existing_device_id := (v_device_payload_existing ->> 'existing_device_id')::uuid;
        EXCEPTION WHEN invalid_text_representation THEN
            RAISE EXCEPTION 'Select a valid existing device.' USING ERRCODE = '22023';
        END;

        SELECT v_device_payload_existing || jsonb_build_object(
                   'mode', 'USE_EXISTING',
                   'existing_device_id', d.id,
                   'id', d.id,
                   'name', d.name,
                   'external_id', d.external_id,
                   'model_vendor', COALESCE(dm.vendor, ''),
                   'model', COALESCE(dm.model, ''),
                   'device_category_id', dm.device_category_id,
                   'firmware_version', COALESCE(d.firmware_version, ''),
                   'protocol', COALESCE(d.protocol, ''),
                   'profile_code', COALESCE(dp.profile_code, '')
               )
        INTO v_device_payload_existing
        FROM metadata.devices AS d
        LEFT JOIN metadata.device_models AS dm ON dm.id = d.device_model_id
        LEFT JOIN config.device_profiles AS dp ON dp.id = d.profile_id
        WHERE d.id = v_existing_device_id
          AND d.organization_id = v_existing_organization_id
          AND d.gateway_id = v_existing_gateway_id;

        IF v_device_payload_existing IS NULL THEN
            RAISE EXCEPTION 'The selected device is unavailable or outside the selected gateway.'
                USING ERRCODE = 'P0002';
        END IF;

        v_draft_payload := jsonb_set(v_draft_payload, '{device}', v_device_payload_existing, true);
    END IF;

    -- Hydrate an existing asset and verify tenant/site ownership.
    v_asset_payload := COALESCE(v_draft_payload -> 'asset', '{}'::jsonb);
    v_asset_mode := upper(COALESCE(NULLIF(btrim(v_asset_payload ->> 'mode'), ''), 'CREATE_NEW'));

    IF v_asset_mode = 'USE_EXISTING' THEN
        BEGIN
            v_existing_asset_id := (v_asset_payload ->> 'existing_asset_id')::uuid;
        EXCEPTION WHEN invalid_text_representation THEN
            RAISE EXCEPTION 'Select a valid existing asset.' USING ERRCODE = '22023';
        END;

        SELECT v_asset_payload || jsonb_build_object(
                   'mode', 'USE_EXISTING',
                   'existing_asset_id', a.id,
                   'id', a.id,
                   'name', a.name,
                   'asset_type_id', a.asset_type_id,
                   'metadata', COALESCE(a.metadata, '{}'::jsonb),
                   'metering_requirement', a.metering_requirement
               )
        INTO v_asset_payload
        FROM metadata.assets AS a
        WHERE a.id = v_existing_asset_id
          AND a.organization_id = v_existing_organization_id
          AND a.site_id = v_existing_site_id;

        IF v_asset_payload IS NULL THEN
            RAISE EXCEPTION 'The selected asset is unavailable or outside the selected site.'
                USING ERRCODE = 'P0002';
        END IF;

        v_draft_payload := jsonb_set(v_draft_payload, '{asset}', v_asset_payload, true);
    END IF;

    v_device_payload := COALESCE(
        v_draft_payload -> 'device',
        '{}'::jsonb
    );

    v_identifier_payload := COALESCE(
        v_device_payload -> 'identifier',
        '{}'::jsonb
    );

    IF jsonb_typeof(v_identifier_payload) <> 'object' THEN
        RAISE EXCEPTION
            'Draft device identifier must be a JSON object.';
    END IF;

    v_request_payload := jsonb_set(
        v_draft_payload,
        '{device}',
        v_device_payload - 'identifier',
        true
    );

    v_request_payload := jsonb_set(
        v_request_payload,
        '{identifier}',
        v_identifier_payload,
        true
    );

    v_request_payload :=
        v_request_payload - 'review';

    v_result := admin.onboard_energy_asset(
        v_request_payload,
        v_requested_by
    );

    UPDATE admin.onboarding_drafts AS draft
    SET
        status = 'SUBMITTED',
        current_step = 'review',
        payload = jsonb_set(
            draft.payload,
            '{review}',
            jsonb_build_object(
                'submitted_at',
                clock_timestamp(),
                'submitted_by',
                v_requested_by,
                'result',
                v_result
            ),
            true
        ),
        requested_by = v_requested_by,
        updated_at = clock_timestamp()
    WHERE draft.draft_token = p_draft_token
      AND draft.status = 'DRAFT'
      AND (
          p_role_code = 'PLATFORM_ADMIN'
          OR draft.owner_portal_user_id =
             p_portal_user_id
      );

    IF NOT FOUND THEN
        RAISE EXCEPTION
            'Onboarding draft status or ownership changed during submission.';
    END IF;

    PERFORM admin.log_onboarding_event(
        p_draft_token,
        'SUBMISSION_SUCCEEDED',
        'review',
        v_requested_by,
        jsonb_build_object(
            'organization_id',
            v_result ->> 'organization_id',
            'site_id',
            v_result ->> 'site_id',
            'gateway_id',
            v_result ->> 'gateway_id',
            'device_id',
            v_result ->> 'device_id',
            'asset_id',
            v_result ->> 'asset_id',
            'relationship_type',
            v_result ->> 'relationship_type'
        )
    );

    RETURN v_result;
END;
$function$;


ALTER FUNCTION admin.submit_onboarding_draft(uuid, bigint, text, text)
    OWNER TO ems_admin;

REVOKE ALL ON FUNCTION admin.submit_onboarding_draft(
    uuid, bigint, text, text
) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION admin.submit_onboarding_draft(
    uuid, bigint, text, text
) TO ems_app;

COMMIT;
