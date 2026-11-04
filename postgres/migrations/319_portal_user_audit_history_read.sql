-- ============================================================================
-- Migration 319
-- Administration App: a portal user's audit history, read through one
-- controlled, actor-scoped function
--
-- The Administration App's Users pages show a user's change history
-- (admin.portal_user_audit: creation, role / scope / status / details
-- changes, password resets and own-password changes). The table is readable
-- by its owner only; ems_app has no SELECT on it and gets none. Instead:
--
--   admin.list_manageable_portal_user_audit(p_actor_portal_user_id,
--                                           p_target_portal_user_id,
--                                           p_limit)
--
-- SECURITY DEFINER, STABLE, search_path pinned, owner ems_admin, EXECUTE
-- ems_app only (never PUBLIC, ems_customer_api or ems_readonly). It applies
-- the same rule as every user-management function:
--
--   * the actor must be an active ADMIN (42501 otherwise);
--   * the target must be inside the actor's scope
--     (admin.portal_user_scope_contains_user); a target outside it and a
--     nonexistent one both return no rows.
--
-- Tenant isolation inside the history (a GLOBAL administrator may have moved
-- the user between organizations):
--
--   * GLOBAL actors (WiseWatts staff) see every row of the target;
--   * ORGANIZATION / SELECTED_SITES actors see only rows recorded for their
--     own organization, and never the organization / site identifiers in
--     the payload (previous_* / new_* organization and site ids are removed).
--
-- Payloads always pass admin.redact_audit_json (no password, token or
-- secret field -- none is written today; defence in depth). The actor's
-- display name is returned only when the caller may see that actor (the
-- caller itself, or a user inside the caller's scope); otherwise only
-- whether the actor was WiseWatts staff.
--
-- Read-only: no table, row, grant (other than this function's own), role or
-- job change. p_limit is clamped to 1..200 (default 50), newest first.
--
-- Production-applicable (not environment-scoped). Rollback (not expected):
-- DROP FUNCTION admin.list_manageable_portal_user_audit(BIGINT, BIGINT, INTEGER);
-- the application then shows the history as unavailable.
-- ============================================================================

DO $pre$
BEGIN
    IF to_regclass('admin.portal_user_audit') IS NULL
       OR to_regclass('admin.portal_users') IS NULL THEN
        RAISE EXCEPTION 'Migration 319 precondition failed: admin.portal_users / admin.portal_user_audit missing';
    END IF;
    IF to_regprocedure('admin.portal_user_scope_contains_user(bigint,bigint)') IS NULL
       OR to_regprocedure('admin.redact_audit_json(jsonb)') IS NULL THEN
        RAISE EXCEPTION 'Migration 319 precondition failed: admin.portal_user_scope_contains_user / admin.redact_audit_json missing';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'ems_app') THEN
        RAISE EXCEPTION 'Migration 319 precondition failed: role ems_app does not exist';
    END IF;
    IF to_regprocedure('admin.list_manageable_portal_user_audit(bigint,bigint,integer)') IS NOT NULL THEN
        RAISE EXCEPTION 'Migration 319 precondition failed: admin.list_manageable_portal_user_audit already exists';
    END IF;
END
$pre$;

CREATE FUNCTION admin.list_manageable_portal_user_audit
(
    p_actor_portal_user_id BIGINT,
    p_target_portal_user_id BIGINT,
    p_limit INTEGER DEFAULT 50
)
RETURNS TABLE
(
    audit_id UUID,
    created_at TIMESTAMPTZ,
    event_type TEXT,
    actor_portal_user_id BIGINT,
    actor_display_name TEXT,
    actor_is_staff BOOLEAN,
    previous_role_code TEXT,
    new_role_code TEXT,
    event_payload JSONB
)
LANGUAGE plpgsql
SECURITY DEFINER
STABLE
SET search_path TO pg_catalog, admin
AS $function$
DECLARE
    v_actor RECORD;
    v_limit INTEGER := LEAST(GREATEST(COALESCE(p_limit, 50), 1), 200);
BEGIN
    SELECT u.access_scope_mode, u.organization_id
      INTO v_actor
      FROM admin.portal_users AS u
     WHERE u.portal_user_id = p_actor_portal_user_id
       AND u.is_active
       AND u.role_code = 'ADMIN';

    IF NOT FOUND THEN
        RAISE EXCEPTION
            'Portal actor is not authorized to manage users.'
            USING ERRCODE = '42501';
    END IF;

    IF NOT admin.portal_user_scope_contains_user(p_actor_portal_user_id, p_target_portal_user_id) THEN
        RETURN;
    END IF;

    RETURN QUERY
    SELECT
        a.audit_id,
        a.created_at,
        a.event_type,
        CASE WHEN visible.ok THEN a.actor_portal_user_id END,
        CASE WHEN visible.ok THEN actor_user.display_name END,
        (actor_user.access_scope_mode = 'GLOBAL'),
        a.previous_role_code,
        a.new_role_code,
        CASE
            WHEN v_actor.access_scope_mode = 'GLOBAL'
                THEN admin.redact_audit_json(a.event_payload)
            ELSE admin.redact_audit_json(a.event_payload)
                 - 'previous_organization_id' - 'new_organization_id'
                 - 'previous_site_ids' - 'new_site_ids'
                 - 'organization_id' - 'site_ids'
        END
    FROM admin.portal_user_audit AS a
    JOIN admin.portal_users AS actor_user
      ON actor_user.portal_user_id = a.actor_portal_user_id
    CROSS JOIN LATERAL (
        SELECT (
            v_actor.access_scope_mode = 'GLOBAL'
            OR a.actor_portal_user_id = p_actor_portal_user_id
            OR admin.portal_user_scope_contains_user(p_actor_portal_user_id, a.actor_portal_user_id)
        ) AS ok
    ) AS visible
    WHERE a.target_portal_user_id = p_target_portal_user_id
      AND (
          v_actor.access_scope_mode = 'GLOBAL'
          OR a.organization_id IS NOT DISTINCT FROM v_actor.organization_id
      )
    ORDER BY a.created_at DESC, a.audit_id DESC
    LIMIT v_limit;
END;
$function$;

ALTER FUNCTION admin.list_manageable_portal_user_audit(BIGINT, BIGINT, INTEGER)
    OWNER TO ems_admin;

REVOKE ALL
ON FUNCTION admin.list_manageable_portal_user_audit(BIGINT, BIGINT, INTEGER)
FROM PUBLIC;

GRANT EXECUTE
ON FUNCTION admin.list_manageable_portal_user_audit(BIGINT, BIGINT, INTEGER)
TO ems_app;

COMMENT ON FUNCTION admin.list_manageable_portal_user_audit(BIGINT, BIGINT, INTEGER) IS
    'Migration 319: audit history of one portal user for an active ADMIN whose scope contains it '
    '(admin.portal_user_scope_contains_user). Non-GLOBAL actors see only their own organization''s rows, '
    'without organization / site ids; payloads redacted; actor named only when visible to the caller. '
    'EXECUTE ems_app only.';

DO $post$
BEGIN
    IF has_function_privilege('public', 'admin.list_manageable_portal_user_audit(bigint,bigint,integer)', 'EXECUTE') THEN
        RAISE EXCEPTION 'Migration 319 postcondition failed: PUBLIC can execute the audit history function';
    END IF;
    IF NOT has_function_privilege('ems_app', 'admin.list_manageable_portal_user_audit(bigint,bigint,integer)', 'EXECUTE') THEN
        RAISE EXCEPTION 'Migration 319 postcondition failed: ems_app cannot execute the audit history function';
    END IF;
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'ems_customer_api')
       AND has_function_privilege('ems_customer_api', 'admin.list_manageable_portal_user_audit(bigint,bigint,integer)', 'EXECUTE') THEN
        RAISE EXCEPTION 'Migration 319 postcondition failed: ems_customer_api can execute the audit history function';
    END IF;
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'ems_readonly')
       AND has_function_privilege('ems_readonly', 'admin.list_manageable_portal_user_audit(bigint,bigint,integer)', 'EXECUTE') THEN
        RAISE EXCEPTION 'Migration 319 postcondition failed: ems_readonly can execute the audit history function';
    END IF;
    IF has_table_privilege('ems_app', 'admin.portal_user_audit', 'SELECT') THEN
        RAISE EXCEPTION 'Migration 319 postcondition failed: ems_app has direct SELECT on admin.portal_user_audit';
    END IF;
END
$post$;
