BEGIN;

CREATE OR REPLACE FUNCTION admin.submit_onboarding_draft
(
    p_draft_token uuid,
    p_requested_by text DEFAULT current_user
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
BEGIN
    IF p_draft_token IS NULL THEN
        RAISE EXCEPTION
            'Onboarding draft token is required.';
    END IF;

    v_requested_by :=
        COALESCE(
            NULLIF(btrim(p_requested_by), ''),
            current_user
        );

    SELECT draft.payload
    INTO v_draft_payload
    FROM admin.onboarding_drafts AS draft
    WHERE draft.draft_token = p_draft_token
      AND draft.status = 'DRAFT'
      AND draft.current_step = 'review'
      AND draft.expires_at > clock_timestamp()
    FOR UPDATE;

    IF v_draft_payload IS NULL THEN
        RAISE EXCEPTION
            'Onboarding draft was not found, has expired, is incomplete, or was already submitted.';
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

    v_device_payload :=
        COALESCE(
            v_draft_payload -> 'device',
            '{}'::jsonb
        );

    v_identifier_payload :=
        COALESCE(
            v_device_payload -> 'identifier',
            '{}'::jsonb
        );

    IF jsonb_typeof(v_identifier_payload) <> 'object' THEN
        RAISE EXCEPTION
            'Draft device identifier must be a JSON object.';
    END IF;

    v_request_payload :=
        jsonb_set(
            v_draft_payload,
            '{device}',
            v_device_payload - 'identifier',
            true
        );

    v_request_payload :=
        jsonb_set(
            v_request_payload,
            '{identifier}',
            v_identifier_payload,
            true
        );

    v_request_payload :=
        v_request_payload - 'review';

    v_result :=
        admin.onboard_energy_asset(
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
      AND draft.status = 'DRAFT';

    IF NOT FOUND THEN
        RAISE EXCEPTION
            'Onboarding draft status changed during submission.';
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
ON FUNCTION admin.submit_onboarding_draft(uuid, text)
FROM PUBLIC;

GRANT EXECUTE
ON FUNCTION admin.submit_onboarding_draft(uuid, text)
TO ems_app;

COMMIT;
