BEGIN;

-- ============================================================================
-- Ownership-aware onboarding draft save
-- ============================================================================

CREATE OR REPLACE FUNCTION admin.save_onboarding_draft_step
(
    p_draft_token uuid,
    p_step text,
    p_step_payload jsonb,
    p_next_step text,
    p_portal_user_id bigint,
    p_role_code text,
    p_requested_by text
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO pg_catalog, admin
AS $function$
DECLARE
    v_draft_token uuid;
    v_event_type text;
    v_actor text;
    v_verified_username text;
BEGIN
    SELECT portal_user.username
    INTO v_verified_username
    FROM admin.portal_users AS portal_user
    WHERE portal_user.portal_user_id = p_portal_user_id
      AND portal_user.is_active = true
      AND portal_user.role_code = p_role_code;

    IF v_verified_username IS NULL THEN
        RAISE EXCEPTION
            'Authenticated portal identity is invalid or stale.';
    END IF;

    v_actor := COALESCE(
        NULLIF(btrim(p_requested_by), ''),
        v_verified_username
    );

    IF v_actor <> v_verified_username THEN
        RAISE EXCEPTION
            'Requested actor does not match authenticated portal identity.';
    END IF;

    IF p_role_code NOT IN ('SUPER_ADMIN', 'OPERATOR') THEN
        RAISE EXCEPTION
            'Portal role is not permitted to edit onboarding drafts.';
    END IF;

    IF p_step NOT IN (
        'organization',
        'site',
        'location',
        'gateway',
        'device',
        'asset',
        'review'
    ) THEN
        RAISE EXCEPTION
            'Unsupported onboarding step: %',
            p_step;
    END IF;

    IF p_next_step NOT IN (
        'organization',
        'site',
        'location',
        'gateway',
        'device',
        'asset',
        'review'
    ) THEN
        RAISE EXCEPTION
            'Unsupported next onboarding step: %',
            p_next_step;
    END IF;

    IF p_step_payload IS NULL
       OR jsonb_typeof(p_step_payload) <> 'object'
    THEN
        RAISE EXCEPTION
            'Onboarding step payload must be a JSON object.';
    END IF;

    IF p_draft_token IS NULL THEN
        INSERT INTO admin.onboarding_drafts
        (
            current_step,
            payload,
            requested_by,
            owner_portal_user_id
        )
        VALUES
        (
            p_next_step,
            jsonb_build_object(
                p_step,
                p_step_payload
            ),
            v_actor,
            p_portal_user_id
        )
        RETURNING onboarding_drafts.draft_token
        INTO v_draft_token;

        v_event_type := 'DRAFT_CREATED';

    ELSE
        UPDATE admin.onboarding_drafts AS draft
        SET
            payload = jsonb_set(
                draft.payload,
                ARRAY[p_step],
                p_step_payload,
                true
            ),
            current_step = p_next_step,
            requested_by = v_actor,
            updated_at = clock_timestamp(),
            expires_at =
                clock_timestamp() + interval '7 days'
        WHERE draft.draft_token = p_draft_token
          AND draft.status = 'DRAFT'
          AND draft.expires_at > clock_timestamp()
          AND (
              p_role_code = 'SUPER_ADMIN'
              OR draft.owner_portal_user_id =
                 p_portal_user_id
          )
        RETURNING draft.draft_token
        INTO v_draft_token;

        IF v_draft_token IS NULL THEN
            RAISE EXCEPTION
                'Onboarding draft was not found, expired, or is not owned by the authenticated user.';
        END IF;

        v_event_type := 'STEP_SAVED';
    END IF;

    PERFORM admin.log_onboarding_event(
        v_draft_token,
        v_event_type,
        p_step,
        v_actor,
        jsonb_build_object(
            'saved_step',
            p_step,
            'resulting_current_step',
            p_next_step,
            'saved_keys',
            COALESCE(
                (
                    SELECT jsonb_agg(key ORDER BY key)
                    FROM jsonb_object_keys(
                        p_step_payload
                    ) AS keys(key)
                ),
                '[]'::jsonb
            )
        )
    );

    RETURN v_draft_token;
END;
$function$;


-- ============================================================================
-- Ownership-aware final submission
-- ============================================================================

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
SET search_path TO pg_catalog, admin
AS $function$
DECLARE
    v_draft_payload jsonb;
    v_device_payload jsonb;
    v_identifier_payload jsonb;
    v_request_payload jsonb;
    v_result jsonb;
    v_requested_by text;
    v_verified_username text;
BEGIN
    IF p_draft_token IS NULL THEN
        RAISE EXCEPTION
            'Onboarding draft token is required.';
    END IF;

    SELECT portal_user.username
    INTO v_verified_username
    FROM admin.portal_users AS portal_user
    WHERE portal_user.portal_user_id = p_portal_user_id
      AND portal_user.is_active = true
      AND portal_user.role_code = p_role_code;

    IF v_verified_username IS NULL THEN
        RAISE EXCEPTION
            'Authenticated portal identity is invalid or stale.';
    END IF;

    IF p_role_code NOT IN ('SUPER_ADMIN', 'OPERATOR') THEN
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
          p_role_code = 'SUPER_ADMIN'
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
          p_role_code = 'SUPER_ADMIN'
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


REVOKE ALL
ON FUNCTION admin.save_onboarding_draft_step(
    uuid,
    text,
    jsonb,
    text,
    bigint,
    text,
    text
)
FROM PUBLIC;

REVOKE ALL
ON FUNCTION admin.submit_onboarding_draft(
    uuid,
    bigint,
    text,
    text
)
FROM PUBLIC;

GRANT EXECUTE
ON FUNCTION admin.save_onboarding_draft_step(
    uuid,
    text,
    jsonb,
    text,
    bigint,
    text,
    text
)
TO ems_app;

GRANT EXECUTE
ON FUNCTION admin.submit_onboarding_draft(
    uuid,
    bigint,
    text,
    text
)
TO ems_app;

COMMIT;
