BEGIN;

CREATE OR REPLACE FUNCTION admin.save_onboarding_draft_step
(
    p_draft_token uuid,
    p_step text,
    p_step_payload jsonb,
    p_next_step text,
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
BEGIN
    IF p_step NOT IN
    (
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

    IF p_next_step NOT IN
    (
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

    v_actor := COALESCE(
        NULLIF(btrim(p_requested_by), ''),
        current_user
    );

    IF p_draft_token IS NULL THEN
        INSERT INTO admin.onboarding_drafts
        (
            current_step,
            payload,
            requested_by
        )
        VALUES
        (
            p_next_step,
            jsonb_build_object(
                p_step,
                p_step_payload
            ),
            v_actor
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
        RETURNING draft.draft_token
        INTO v_draft_token;

        IF v_draft_token IS NULL THEN
            RAISE EXCEPTION
                'Onboarding draft was not found or has expired.';
        END IF;

        v_event_type := 'STEP_SAVED';
    END IF;

    PERFORM admin.log_onboarding_event(
        v_draft_token,
        v_event_type,
        p_step,
        v_actor,
        jsonb_build_object(
            -- The step whose data was validated and persisted.
            'saved_step',
            p_step,

            -- The wizard state after the save operation completed.
            'resulting_current_step',
            p_next_step,

            -- Field names only; values are deliberately omitted from this
            -- event log to avoid duplicating potentially sensitive payloads.
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

REVOKE ALL
ON FUNCTION admin.save_onboarding_draft_step(
    uuid,
    text,
    jsonb,
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
    text
)
TO ems_app;

COMMIT;
