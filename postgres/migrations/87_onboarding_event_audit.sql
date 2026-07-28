BEGIN;

-- ============================================================================
-- Append-only onboarding wizard event log.
--
-- This table complements admin.onboarding_audit:
--
--   admin.onboarding_audit
--       Records successful production onboarding requests and results.
--
--   admin.onboarding_event_audit
--       Records wizard lifecycle events such as draft creation, step saves,
--       submission success, and submission failure.
--
-- The application role receives no direct table privileges.
-- All writes occur through SECURITY DEFINER functions.
-- ============================================================================

CREATE TABLE IF NOT EXISTS admin.onboarding_event_audit
(
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),

    draft_token uuid,

    event_type text NOT NULL,

    step_name text,

    actor text NOT NULL,

    event_context jsonb NOT NULL DEFAULT '{}'::jsonb,

    created_at timestamptz NOT NULL DEFAULT clock_timestamp(),

    CONSTRAINT onboarding_event_audit_event_type_check
        CHECK
        (
            event_type IN
            (
                'DRAFT_CREATED',
                'STEP_SAVED',
                'SUBMISSION_SUCCEEDED',
                'SUBMISSION_FAILED'
            )
        ),

    CONSTRAINT onboarding_event_audit_step_name_check
        CHECK
        (
            step_name IS NULL
            OR step_name IN
            (
                'organization',
                'site',
                'location',
                'gateway',
                'device',
                'asset',
                'review'
            )
        ),

    CONSTRAINT onboarding_event_audit_context_object_check
        CHECK
        (
            jsonb_typeof(event_context) = 'object'
        )
);

CREATE INDEX IF NOT EXISTS
    idx_onboarding_event_audit_draft_created
ON admin.onboarding_event_audit
(
    draft_token,
    created_at DESC
);

CREATE INDEX IF NOT EXISTS
    idx_onboarding_event_audit_type_created
ON admin.onboarding_event_audit
(
    event_type,
    created_at DESC
);

-- ============================================================================
-- Controlled append function.
-- ============================================================================

CREATE OR REPLACE FUNCTION admin.log_onboarding_event
(
    p_draft_token uuid,
    p_event_type text,
    p_step_name text,
    p_actor text,
    p_event_context jsonb DEFAULT '{}'::jsonb
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO pg_catalog, admin
AS $function$
DECLARE
    v_event_id uuid;
    v_event_type text;
    v_step_name text;
    v_actor text;
    v_context jsonb;
BEGIN
    v_event_type := upper(btrim(p_event_type));
    v_step_name := lower(NULLIF(btrim(p_step_name), ''));
    v_actor := COALESCE(
        NULLIF(btrim(p_actor), ''),
        current_user
    );
    v_context := COALESCE(
        p_event_context,
        '{}'::jsonb
    );

    IF v_event_type NOT IN
    (
        'DRAFT_CREATED',
        'STEP_SAVED',
        'SUBMISSION_SUCCEEDED',
        'SUBMISSION_FAILED'
    ) THEN
        RAISE EXCEPTION
            'Unsupported onboarding event type: %',
            v_event_type;
    END IF;

    IF v_step_name IS NOT NULL
       AND v_step_name NOT IN
       (
           'organization',
           'site',
           'location',
           'gateway',
           'device',
           'asset',
           'review'
       )
    THEN
        RAISE EXCEPTION
            'Unsupported onboarding step name: %',
            v_step_name;
    END IF;

    IF jsonb_typeof(v_context) <> 'object' THEN
        RAISE EXCEPTION
            'Onboarding event context must be a JSON object.';
    END IF;

    INSERT INTO admin.onboarding_event_audit
    (
        draft_token,
        event_type,
        step_name,
        actor,
        event_context
    )
    VALUES
    (
        p_draft_token,
        v_event_type,
        v_step_name,
        v_actor,
        v_context
    )
    RETURNING id
    INTO v_event_id;

    RETURN v_event_id;
END;
$function$;

REVOKE ALL
ON TABLE admin.onboarding_event_audit
FROM PUBLIC;

REVOKE ALL
ON TABLE admin.onboarding_event_audit
FROM ems_app;

REVOKE ALL
ON FUNCTION admin.log_onboarding_event(
    uuid,
    text,
    text,
    text,
    jsonb
)
FROM PUBLIC;

GRANT EXECUTE
ON FUNCTION admin.log_onboarding_event(
    uuid,
    text,
    text,
    text,
    jsonb
)
TO ems_app;

-- ============================================================================
-- Read-only administrative view.
-- The application role is not granted access yet. This will be used by the
-- future onboarding history page after authenticated RBAC is implemented.
-- ============================================================================

CREATE OR REPLACE VIEW admin.v_onboarding_event_audit
AS
SELECT
    event.id,
    event.draft_token,
    event.event_type,
    event.step_name,
    event.actor,
    event.event_context,
    event.created_at
FROM admin.onboarding_event_audit AS event;

REVOKE ALL
ON admin.v_onboarding_event_audit
FROM PUBLIC;

COMMIT;
