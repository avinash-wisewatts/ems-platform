BEGIN;

-- ============================================================================
-- Durable multi-page onboarding drafts
--
-- Each step writes only to this draft record. Production metadata is created
-- atomically later by admin.onboard_energy_asset().
-- ============================================================================

CREATE TABLE IF NOT EXISTS admin.onboarding_drafts
(
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),

    -- Browser-safe opaque identifier used between wizard pages.
    draft_token uuid NOT NULL UNIQUE DEFAULT gen_random_uuid(),

    -- Current wizard position.
    current_step text NOT NULL DEFAULT 'organization',

    -- DRAFT, SUBMITTED, CANCELLED, or EXPIRED.
    status text NOT NULL DEFAULT 'DRAFT',

    -- Accumulated validated wizard data.
    payload jsonb NOT NULL DEFAULT '{}'::jsonb,

    requested_by text NOT NULL,

    created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    updated_at timestamptz NOT NULL DEFAULT clock_timestamp(),

    -- Prevent abandoned drafts from living forever.
    expires_at timestamptz NOT NULL
        DEFAULT clock_timestamp() + interval '7 days',

    CONSTRAINT onboarding_drafts_current_step_check
        CHECK
        (
            current_step IN
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

    CONSTRAINT onboarding_drafts_status_check
        CHECK
        (
            status IN
            (
                'DRAFT',
                'SUBMITTED',
                'CANCELLED',
                'EXPIRED'
            )
        ),

    CONSTRAINT onboarding_drafts_payload_object_check
        CHECK (jsonb_typeof(payload) = 'object')
);

CREATE INDEX IF NOT EXISTS onboarding_drafts_status_expiry_idx
    ON admin.onboarding_drafts
    (
        status,
        expires_at
    );

COMMENT ON TABLE admin.onboarding_drafts IS
    'Durable server-side state for the multi-page EMS onboarding wizard.';

COMMENT ON COLUMN admin.onboarding_drafts.payload IS
    'Validated partial onboarding request accumulated across wizard steps.';


-- ============================================================================
-- Read one active draft
-- ============================================================================

CREATE OR REPLACE FUNCTION admin.get_onboarding_draft(
    p_draft_token uuid
)
RETURNS TABLE
(
    draft_token uuid,
    current_step text,
    status text,
    payload jsonb,
    created_at timestamptz,
    updated_at timestamptz,
    expires_at timestamptz
)
LANGUAGE sql
SECURITY DEFINER
SET search_path = pg_catalog, admin
AS $function$
    SELECT
        draft.draft_token,
        draft.current_step,
        draft.status,
        draft.payload,
        draft.created_at,
        draft.updated_at,
        draft.expires_at
    FROM admin.onboarding_drafts AS draft
    WHERE draft.draft_token = p_draft_token
      AND draft.status = 'DRAFT'
      AND draft.expires_at > clock_timestamp();
$function$;


-- ============================================================================
-- Create or update a draft step
--
-- jsonb_set replaces one top-level wizard module while preserving all other
-- completed modules.
-- ============================================================================

CREATE OR REPLACE FUNCTION admin.save_onboarding_draft_step(
    p_draft_token uuid,
    p_step text,
    p_step_payload jsonb,
    p_next_step text,
    p_requested_by text
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, admin
AS $function$
DECLARE
    v_draft_token uuid;
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
        RAISE EXCEPTION 'Unsupported onboarding step: %', p_step;
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
        RAISE EXCEPTION 'Unsupported next onboarding step: %', p_next_step;
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
            requested_by
        )
        VALUES
        (
            p_next_step,
            jsonb_build_object(p_step, p_step_payload),
            btrim(p_requested_by)
        )
        RETURNING onboarding_drafts.draft_token
        INTO v_draft_token;
    ELSE
        UPDATE admin.onboarding_drafts AS draft
        SET
            payload = jsonb_set(
                draft.payload,
                ARRAY[p_step],
                p_step_payload,
                TRUE
            ),
            current_step = p_next_step,
            requested_by = btrim(p_requested_by),
            updated_at = clock_timestamp(),
            expires_at = clock_timestamp() + interval '7 days'
        WHERE draft.draft_token = p_draft_token
          AND draft.status = 'DRAFT'
          AND draft.expires_at > clock_timestamp()
        RETURNING draft.draft_token
        INTO v_draft_token;

        IF v_draft_token IS NULL THEN
            RAISE EXCEPTION
                'Onboarding draft was not found or has expired.';
        END IF;
    END IF;

    RETURN v_draft_token;
END;
$function$;


-- ============================================================================
-- Least-privilege grants
-- ============================================================================

REVOKE ALL ON TABLE admin.onboarding_drafts FROM PUBLIC;
REVOKE ALL ON FUNCTION admin.get_onboarding_draft(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION admin.save_onboarding_draft_step(
    uuid,
    text,
    jsonb,
    text,
    text
) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION admin.get_onboarding_draft(uuid)
    TO ems_app;

GRANT EXECUTE ON FUNCTION admin.save_onboarding_draft_step(
    uuid,
    text,
    jsonb,
    text,
    text
) TO ems_app;

COMMIT;
