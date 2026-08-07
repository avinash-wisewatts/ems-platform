BEGIN;

-- ============================================================================
-- Ownership-aware active draft lookup
--
-- The caller supplies the authenticated portal user ID and role captured in
-- the signed session. The function independently verifies both against the
-- current portal_users row. This causes deactivated accounts and stale role
-- sessions to fail closed.
--
-- SUPER_ADMIN may access all drafts. Other authenticated roles may access only
-- drafts whose stable owner_portal_user_id matches their portal identity.
-- ============================================================================

CREATE OR REPLACE FUNCTION admin.get_onboarding_draft
(
    p_draft_token uuid,
    p_portal_user_id bigint,
    p_role_code text
)
RETURNS TABLE
(
    draft_token uuid,
    current_step text,
    status text,
    payload jsonb,
    requested_by text,
    owner_portal_user_id bigint,
    created_at timestamptz,
    updated_at timestamptz,
    expires_at timestamptz
)
LANGUAGE sql
SECURITY DEFINER
STABLE
SET search_path TO pg_catalog, admin
AS $function$
    SELECT
        draft.draft_token,
        draft.current_step,
        draft.status,
        draft.payload,
        draft.requested_by,
        draft.owner_portal_user_id,
        draft.created_at,
        draft.updated_at,
        draft.expires_at
    FROM admin.onboarding_drafts AS draft
    JOIN admin.portal_users AS portal_user
      ON portal_user.portal_user_id = p_portal_user_id
     AND portal_user.is_active = true
     AND portal_user.role_code = p_role_code
    WHERE draft.draft_token = p_draft_token
      AND draft.status = 'DRAFT'
      AND draft.expires_at > clock_timestamp()
      AND (
          portal_user.role_code = 'SUPER_ADMIN'
          OR draft.owner_portal_user_id =
             portal_user.portal_user_id
      );
$function$;


-- ============================================================================
-- Ownership-aware submitted result lookup
--
-- Submitted results follow the same ownership rule. This prevents an operator
-- from retrieving another operator's immutable result using only its UUID.
-- ============================================================================

CREATE OR REPLACE FUNCTION admin.get_submitted_onboarding_result
(
    p_draft_token uuid,
    p_portal_user_id bigint,
    p_role_code text
)
RETURNS TABLE
(
    draft_token uuid,
    status text,
    requested_by text,
    owner_portal_user_id bigint,
    created_at timestamptz,
    submitted_at timestamptz,
    payload jsonb,
    result jsonb
)
LANGUAGE sql
SECURITY DEFINER
STABLE
SET search_path TO pg_catalog, admin
AS $function$
    SELECT
        draft.draft_token,
        draft.status,
        draft.requested_by,
        draft.owner_portal_user_id,
        draft.created_at,
        NULLIF(
            draft.payload #>> '{review,submitted_at}',
            ''
        )::timestamptz AS submitted_at,
        draft.payload,
        draft.payload #> '{review,result}' AS result
    FROM admin.onboarding_drafts AS draft
    JOIN admin.portal_users AS portal_user
      ON portal_user.portal_user_id = p_portal_user_id
     AND portal_user.is_active = true
     AND portal_user.role_code = p_role_code
    WHERE draft.draft_token = p_draft_token
      AND draft.status = 'SUBMITTED'
      AND draft.payload #> '{review,result}' IS NOT NULL
      AND (
          portal_user.role_code = 'SUPER_ADMIN'
          OR draft.owner_portal_user_id =
             portal_user.portal_user_id
      );
$function$;


-- ============================================================================
-- Permission boundary
--
-- The legacy one-argument functions remain temporarily executable while the
-- FastAPI repository is migrated. They will be revoked after cutover.
-- ============================================================================

REVOKE ALL
ON FUNCTION admin.get_onboarding_draft(
    uuid,
    bigint,
    text
)
FROM PUBLIC;

REVOKE ALL
ON FUNCTION admin.get_submitted_onboarding_result(
    uuid,
    bigint,
    text
)
FROM PUBLIC;

GRANT EXECUTE
ON FUNCTION admin.get_onboarding_draft(
    uuid,
    bigint,
    text
)
TO ems_app;

GRANT EXECUTE
ON FUNCTION admin.get_submitted_onboarding_result(
    uuid,
    bigint,
    text
)
TO ems_app;

COMMIT;
