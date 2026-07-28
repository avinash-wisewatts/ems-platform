BEGIN;

-- ============================================================================
-- Read one completed onboarding result.
--
-- This function is intentionally separate from admin.get_onboarding_draft().
-- Draft editing remains restricted to active DRAFT records, while submitted
-- results can be viewed through a read-only result page.
-- ============================================================================

CREATE OR REPLACE FUNCTION admin.get_submitted_onboarding_result
(
    p_draft_token uuid
)
RETURNS TABLE
(
    draft_token uuid,
    status text,
    requested_by text,
    created_at timestamptz,
    submitted_at timestamptz,
    payload jsonb,
    result jsonb
)
LANGUAGE sql
SECURITY DEFINER
SET search_path TO pg_catalog, admin
AS $function$
    SELECT
        draft.draft_token,
        draft.status,
        draft.requested_by,
        draft.created_at,
        NULLIF(
            draft.payload #>> '{review,submitted_at}',
            ''
        )::timestamptz AS submitted_at,
        draft.payload,
        draft.payload #> '{review,result}' AS result
    FROM admin.onboarding_drafts AS draft
    WHERE draft.draft_token = p_draft_token
      AND draft.status = 'SUBMITTED'
      AND draft.payload #> '{review,result}' IS NOT NULL;
$function$;

REVOKE ALL
ON FUNCTION admin.get_submitted_onboarding_result(uuid)
FROM PUBLIC;

GRANT EXECUTE
ON FUNCTION admin.get_submitted_onboarding_result(uuid)
TO ems_app;

COMMIT;
