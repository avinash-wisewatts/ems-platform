-- Migration 134: Hydrate existing organization data during onboarding submission.
-- Keeps the selected organization ID as the browser contract while resolving
-- canonical name/code/description and enforcing access in PostgreSQL.

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
