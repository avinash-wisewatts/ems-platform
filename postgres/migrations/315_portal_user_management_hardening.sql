-- ============================================================================
-- Migration 315
-- Portal user management: self-protection, scope containment, details edit,
-- password reset and own-password change (EMS Web App Admin -> Users)
--
-- The EMS Web App's Admin -> Users screen manages the SAME identities, roles
-- and access scopes as the Administration App (admin.portal_users,
-- ADMIN / OPERATOR / VIEWER x GLOBAL / ORGANIZATION / SELECTED_SITES) through
-- the SAME controlled SECURITY DEFINER functions. This migration closes the
-- gaps those functions had and adds the three operations that did not exist:
--
--   admin.change_managed_portal_user_role      (replaced, same signature)
--       + an actor may not change their own role
--   admin.set_managed_portal_user_active        (replaced, same signature)
--       + an actor may not deactivate / reactivate themselves
--       + an unknown target is refused (was a silent no-op)
--   admin.set_managed_portal_user_access_scope  (replaced, same signature)
--       + an actor may not change their own scope
--       + the TARGET must currently be inside the actor's scope
--         (admin.portal_user_scope_contains_user). Before this, an
--         ORGANIZATION administrator could move a user of ANOTHER
--         organization -- or a GLOBAL user -- into their own organization:
--         the function checked only the requested new scope.
--   admin.update_managed_portal_user_details    (new)
--       display name and e-mail of a user inside the actor's scope; audited
--       USER_DETAILS_CHANGED
--   admin.reset_managed_portal_user_password    (new)
--       an administrator sets a new (temporary) Argon2id hash for another
--       user inside their scope, clearing the failed-login lockout; audited
--       USER_PASSWORD_RESET. Never for oneself (use the own-password change,
--       which requires the current password in the application). Another
--       ADMIN's password only by a WiseWatts staff (GLOBAL) administrator.
--   admin.change_own_portal_user_password       (new)
--       an active user replaces their own hash after the application has
--       verified the current password; audited USER_PASSWORD_CHANGED
--
-- Concurrency: every actor/target function locks both portal_users rows (in
-- id order) BEFORE the scope check, so a concurrent role / scope / status
-- change cannot slip between the check and the update (the check then reads
-- committed, locked state), and two administrators acting on each other
-- cannot deadlock.
--
-- Every function: SECURITY DEFINER, pinned search_path, owner ems_admin, no
-- PUBLIC EXECUTE, EXECUTE to ems_app (the Administration App) only -- never
-- to ems_customer_api (ADR-023: the customer API performs no administration).
-- Password hashes must be Argon2id ('$argon2id$...'): plaintext can never be
-- stored by mistake. No hash or password is ever written to the audit trail.
-- Where migration 314 is applied, its trigger portal_users_revoke_sessions
-- revokes every customer session of an account whose password or status
-- changes -- whichever function makes the change.
--
-- Unchanged: the role / permission catalog, admin.portal_users and its
-- constraints, list_manageable_portal_users, create_managed_portal_user,
-- authentication, every grant on the replaced functions (CREATE OR REPLACE
-- keeps owner and ACL), every table, job and row.
--
-- Behaviour change for the Administration App's existing Users pages: an
-- administrator can no longer change their own role, scope or status there
-- either (it is the same database function). That is intended: a GLOBAL
-- administrator demoting or deactivating themselves was previously possible
-- and could leave a tenant without an administrator.
--
-- Scope: staging and test (postgres/migration_environment_scope.csv);
-- production needs a separate approval.
--
-- Rollback: previous application image first, then re-create the three
-- replaced functions from postgres/migrations/001_ems_platform_baseline_20260807.sql
-- (lines 27129-27255, "Scope-aware function replacements") and
-- DROP FUNCTION the three new ones.
-- ============================================================================


-- ----------------------------------------------------------------------------
-- Role change: unchanged rules + no self-change.
-- ----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION admin.change_managed_portal_user_role
(
    p_actor_portal_user_id BIGINT,
    p_target_portal_user_id BIGINT,
    p_new_role_code TEXT
)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO pg_catalog, admin
AS $function$
DECLARE
    v_previous_role TEXT;
    v_org UUID;
BEGIN
    IF p_new_role_code NOT IN ('ADMIN', 'OPERATOR', 'VIEWER') THEN
        RAISE EXCEPTION 'Invalid portal role.' USING ERRCODE = '22023';
    END IF;

    IF p_actor_portal_user_id = p_target_portal_user_id THEN
        RAISE EXCEPTION 'Portal users cannot change their own role.'
            USING ERRCODE = '42501';
    END IF;

    -- Lock the actor and target rows first (in id order, so two
    -- administrators acting on each other cannot deadlock): the scope check
    -- below then sees committed state that cannot change before the update.
    PERFORM 1
       FROM admin.portal_users
      WHERE portal_user_id IN (p_actor_portal_user_id, p_target_portal_user_id)
      ORDER BY portal_user_id
        FOR UPDATE;

    IF NOT admin.portal_user_scope_contains_user(
        p_actor_portal_user_id, p_target_portal_user_id
    ) THEN
        RAISE EXCEPTION 'Portal actor is not authorized to change this user role.'
            USING ERRCODE = '42501';
    END IF;

    SELECT role_code, organization_id
      INTO v_previous_role, v_org
      FROM admin.portal_users
     WHERE portal_user_id = p_target_portal_user_id
       FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Target portal user was not found.' USING ERRCODE = '22023';
    END IF;

    UPDATE admin.portal_users
       SET role_code = p_new_role_code,
           updated_at = clock_timestamp()
     WHERE portal_user_id = p_target_portal_user_id;

    IF v_previous_role IS DISTINCT FROM p_new_role_code THEN
        INSERT INTO admin.portal_user_audit
        (actor_portal_user_id, target_portal_user_id, organization_id, event_type,
         previous_role_code, new_role_code, event_payload)
        VALUES
        (p_actor_portal_user_id, p_target_portal_user_id, v_org, 'USER_ROLE_CHANGED',
         v_previous_role, p_new_role_code, '{}'::jsonb);
    END IF;
END;
$function$;


-- ----------------------------------------------------------------------------
-- Activation status: unchanged rules + no self-change + unknown target refused.
-- ----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION admin.set_managed_portal_user_active
(
    p_actor_portal_user_id BIGINT,
    p_target_portal_user_id BIGINT,
    p_is_active BOOLEAN
)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO pg_catalog, admin
AS $function$
DECLARE
    v_org UUID;
    v_before BOOLEAN;
BEGIN
    IF p_is_active IS NULL THEN
        RAISE EXCEPTION 'Invalid user status.' USING ERRCODE = '22023';
    END IF;

    IF p_actor_portal_user_id = p_target_portal_user_id THEN
        RAISE EXCEPTION 'Portal users cannot change their own account status.'
            USING ERRCODE = '42501';
    END IF;

    -- Lock the actor and target rows first (in id order, so two
    -- administrators acting on each other cannot deadlock): the scope check
    -- below then sees committed state that cannot change before the update.
    PERFORM 1
       FROM admin.portal_users
      WHERE portal_user_id IN (p_actor_portal_user_id, p_target_portal_user_id)
      ORDER BY portal_user_id
        FOR UPDATE;

    IF NOT admin.portal_user_scope_contains_user(
        p_actor_portal_user_id, p_target_portal_user_id
    ) THEN
        RAISE EXCEPTION 'Portal actor is not authorized to change this user status.'
            USING ERRCODE = '42501';
    END IF;

    SELECT organization_id, is_active
      INTO v_org, v_before
      FROM admin.portal_users
     WHERE portal_user_id = p_target_portal_user_id
       FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Target portal user was not found.' USING ERRCODE = '22023';
    END IF;

    UPDATE admin.portal_users
       SET is_active = p_is_active,
           updated_at = clock_timestamp()
     WHERE portal_user_id = p_target_portal_user_id;

    IF v_before IS DISTINCT FROM p_is_active THEN
        INSERT INTO admin.portal_user_audit
        (actor_portal_user_id, target_portal_user_id, organization_id, event_type, event_payload)
        VALUES
        (p_actor_portal_user_id, p_target_portal_user_id, v_org, 'USER_STATUS_CHANGED',
         jsonb_build_object('previous_is_active', v_before, 'new_is_active', p_is_active));
    END IF;
END;
$function$;


-- ----------------------------------------------------------------------------
-- Access scope: unchanged rules + no self-change + target containment.
-- ----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION admin.set_managed_portal_user_access_scope
(
    p_actor_portal_user_id BIGINT,
    p_target_portal_user_id BIGINT,
    p_access_scope_mode TEXT,
    p_organization_id UUID,
    p_site_ids UUID[]
)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO pg_catalog, admin, metadata
AS $function$
DECLARE
    v_actor admin.portal_users%ROWTYPE;
    v_target admin.portal_users%ROWTYPE;
    v_previous_sites UUID[];
    v_sites UUID[];
    v_invalid BIGINT;
BEGIN
    IF p_actor_portal_user_id = p_target_portal_user_id THEN
        RAISE EXCEPTION 'Portal users cannot change their own access scope.'
            USING ERRCODE = '42501';
    END IF;

    -- Lock the actor and target rows first (in id order, so two
    -- administrators acting on each other cannot deadlock): the scope check
    -- below then sees committed state that cannot change before the update.
    PERFORM 1
       FROM admin.portal_users
      WHERE portal_user_id IN (p_actor_portal_user_id, p_target_portal_user_id)
      ORDER BY portal_user_id
        FOR UPDATE;

    SELECT * INTO v_actor
      FROM admin.portal_users
     WHERE portal_user_id = p_actor_portal_user_id
       AND is_active;

    -- The target must be inside the actor's CURRENT scope before anything
    -- else is considered (cross-tenant moves are refused).
    IF v_actor.role_code IS DISTINCT FROM 'ADMIN'
       OR NOT admin.portal_user_scope_contains_user(
           p_actor_portal_user_id, p_target_portal_user_id
       ) THEN
        RAISE EXCEPTION 'Portal actor is not authorized to change user access scope.'
            USING ERRCODE = '42501';
    END IF;

    SELECT * INTO v_target
      FROM admin.portal_users
     WHERE portal_user_id = p_target_portal_user_id
       FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Target portal user was not found.' USING ERRCODE = '22023';
    END IF;

    SELECT COALESCE(array_agg(DISTINCT x ORDER BY x), ARRAY[]::UUID[])
      INTO v_sites
      FROM unnest(COALESCE(p_site_ids, ARRAY[]::UUID[])) x
     WHERE x IS NOT NULL;

    IF p_access_scope_mode = 'GLOBAL' THEN
        IF p_organization_id IS NOT NULL OR cardinality(v_sites) <> 0 THEN
            RAISE EXCEPTION 'GLOBAL scope requires no organization and no site assignments.';
        END IF;
    ELSIF p_access_scope_mode = 'ORGANIZATION' THEN
        IF p_organization_id IS NULL OR cardinality(v_sites) <> 0 THEN
            RAISE EXCEPTION 'ORGANIZATION scope requires an organization and no site assignments.';
        END IF;
    ELSIF p_access_scope_mode = 'SELECTED_SITES' THEN
        IF p_organization_id IS NULL OR cardinality(v_sites) = 0 THEN
            RAISE EXCEPTION 'SELECTED_SITES scope requires an organization and at least one site.';
        END IF;
    ELSE
        RAISE EXCEPTION 'Invalid portal access scope mode.' USING ERRCODE = '22023';
    END IF;

    IF v_actor.access_scope_mode = 'ORGANIZATION' AND (
        p_access_scope_mode = 'GLOBAL'
        OR p_organization_id IS DISTINCT FROM v_actor.organization_id
    ) THEN
        RAISE EXCEPTION 'Target scope is outside the actor organization.' USING ERRCODE = '42501';
    ELSIF v_actor.access_scope_mode = 'SELECTED_SITES' AND (
        p_access_scope_mode <> 'SELECTED_SITES'
        OR p_organization_id IS DISTINCT FROM v_actor.organization_id
        OR EXISTS (
            SELECT 1
              FROM unnest(v_sites) r(site_id)
             WHERE NOT EXISTS (
                 SELECT 1
                   FROM admin.portal_user_site_access a
                  WHERE a.portal_user_id = p_actor_portal_user_id
                    AND a.site_id = r.site_id
             )
        )
    ) THEN
        RAISE EXCEPTION 'Target scope is outside the actor selected sites.' USING ERRCODE = '42501';
    END IF;

    SELECT count(*) INTO v_invalid
      FROM unnest(v_sites) r(site_id)
      LEFT JOIN metadata.sites s
        ON s.id = r.site_id
       AND s.organization_id = p_organization_id
       AND s.is_active
     WHERE s.id IS NULL;

    IF v_invalid <> 0 THEN
        RAISE EXCEPTION 'Every selected site must be active and belong to the target organization.';
    END IF;

    SELECT COALESCE(array_agg(site_id ORDER BY site_id), ARRAY[]::UUID[])
      INTO v_previous_sites
      FROM admin.portal_user_site_access
     WHERE portal_user_id = p_target_portal_user_id;

    DELETE FROM admin.portal_user_site_access
     WHERE portal_user_id = p_target_portal_user_id;

    UPDATE admin.portal_users
       SET organization_id = p_organization_id,
           access_scope_mode = p_access_scope_mode,
           updated_at = clock_timestamp()
     WHERE portal_user_id = p_target_portal_user_id;

    IF p_access_scope_mode = 'SELECTED_SITES' THEN
        INSERT INTO admin.portal_user_site_access (portal_user_id, site_id, created_by_portal_user_id)
        SELECT p_target_portal_user_id, x, p_actor_portal_user_id
          FROM unnest(v_sites) x;
    END IF;

    INSERT INTO admin.portal_user_audit
    (actor_portal_user_id, target_portal_user_id, organization_id, event_type,
     previous_role_code, new_role_code, event_payload)
    VALUES
    (p_actor_portal_user_id, p_target_portal_user_id, p_organization_id, 'USER_SCOPE_CHANGED',
     v_target.role_code, v_target.role_code,
     jsonb_build_object(
         'previous_access_scope_mode', v_target.access_scope_mode,
         'new_access_scope_mode', p_access_scope_mode,
         'previous_organization_id', v_target.organization_id,
         'new_organization_id', p_organization_id,
         'previous_site_ids', to_jsonb(v_previous_sites),
         'new_site_ids', to_jsonb(v_sites)
     ));
END;
$function$;


-- ----------------------------------------------------------------------------
-- New: display name / e-mail.
-- ----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION admin.update_managed_portal_user_details
(
    p_actor_portal_user_id BIGINT,
    p_target_portal_user_id BIGINT,
    p_display_name TEXT,
    p_email TEXT
)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO pg_catalog, admin
AS $function$
DECLARE
    v_target admin.portal_users%ROWTYPE;
    v_display_name TEXT := btrim(COALESCE(p_display_name, ''));
    v_email TEXT := NULLIF(btrim(COALESCE(p_email, '')), '');
BEGIN
    IF v_display_name = '' THEN
        RAISE EXCEPTION 'Full name is required.' USING ERRCODE = '22023';
    END IF;

    -- Lock the actor and target rows first (in id order, so two
    -- administrators acting on each other cannot deadlock): the scope check
    -- below then sees committed state that cannot change before the update.
    PERFORM 1
       FROM admin.portal_users
      WHERE portal_user_id IN (p_actor_portal_user_id, p_target_portal_user_id)
      ORDER BY portal_user_id
        FOR UPDATE;

    -- An administrator may edit their own details (a GLOBAL / ORGANIZATION
    -- scope contains itself); role, scope and status stay self-protected.
    IF NOT admin.portal_user_scope_contains_user(
        p_actor_portal_user_id, p_target_portal_user_id
    ) THEN
        RAISE EXCEPTION 'Portal actor is not authorized to change this user.'
            USING ERRCODE = '42501';
    END IF;

    SELECT * INTO v_target
      FROM admin.portal_users
     WHERE portal_user_id = p_target_portal_user_id
       FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Target portal user was not found.' USING ERRCODE = '22023';
    END IF;

    IF v_target.display_name IS NOT DISTINCT FROM v_display_name
       AND v_target.email IS NOT DISTINCT FROM v_email THEN
        RETURN;
    END IF;

    UPDATE admin.portal_users
       SET display_name = v_display_name,
           email = v_email,
           updated_at = clock_timestamp()
     WHERE portal_user_id = p_target_portal_user_id;

    INSERT INTO admin.portal_user_audit
    (actor_portal_user_id, target_portal_user_id, organization_id, event_type, event_payload)
    VALUES
    (p_actor_portal_user_id, p_target_portal_user_id, v_target.organization_id, 'USER_DETAILS_CHANGED',
     jsonb_build_object(
         'previous_display_name', v_target.display_name,
         'new_display_name', v_display_name,
         'previous_email', v_target.email,
         'new_email', v_email
     ));
END;
$function$;


-- ----------------------------------------------------------------------------
-- New: administrator password reset (never for oneself).
-- ----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION admin.reset_managed_portal_user_password
(
    p_actor_portal_user_id BIGINT,
    p_target_portal_user_id BIGINT,
    p_password_hash TEXT
)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO pg_catalog, admin
AS $function$
DECLARE
    v_org UUID;
    v_target_role TEXT;
BEGIN
    IF p_password_hash IS NULL OR p_password_hash NOT LIKE '$argon2id$%' THEN
        RAISE EXCEPTION 'A password hash in Argon2id format is required.' USING ERRCODE = '22023';
    END IF;

    IF p_actor_portal_user_id = p_target_portal_user_id THEN
        RAISE EXCEPTION 'Portal users cannot reset their own password; change it instead.'
            USING ERRCODE = '42501';
    END IF;

    -- Lock the actor and target rows first (in id order, so two
    -- administrators acting on each other cannot deadlock): the scope check
    -- below then sees committed state that cannot change before the update.
    PERFORM 1
       FROM admin.portal_users
      WHERE portal_user_id IN (p_actor_portal_user_id, p_target_portal_user_id)
      ORDER BY portal_user_id
        FOR UPDATE;

    IF NOT admin.portal_user_scope_contains_user(
        p_actor_portal_user_id, p_target_portal_user_id
    ) THEN
        RAISE EXCEPTION 'Portal actor is not authorized to reset this user password.'
            USING ERRCODE = '42501';
    END IF;

    SELECT organization_id, role_code INTO v_org, v_target_role
      FROM admin.portal_users
     WHERE portal_user_id = p_target_portal_user_id
       FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Target portal user was not found.' USING ERRCODE = '22023';
    END IF;

    -- Another administrator's password: WiseWatts staff (active GLOBAL
    -- ADMIN) only. A tenant administrator resetting a peer administrator
    -- would take over an account of equal standing in their organization.
    IF v_target_role = 'ADMIN' AND NOT EXISTS (
        SELECT 1
          FROM admin.portal_users actor
         WHERE actor.portal_user_id = p_actor_portal_user_id
           AND actor.is_active
           AND actor.role_code = 'ADMIN'
           AND actor.access_scope_mode = 'GLOBAL'
    ) THEN
        RAISE EXCEPTION 'Only WiseWatts staff administrators can reset another administrator''s password.'
            USING ERRCODE = '42501';
    END IF;

    UPDATE admin.portal_users
       SET password_hash = p_password_hash,
           password_changed_at = clock_timestamp(),
           failed_login_count = 0,
           locked_until = NULL,
           updated_at = clock_timestamp()
     WHERE portal_user_id = p_target_portal_user_id;

    INSERT INTO admin.portal_user_audit
    (actor_portal_user_id, target_portal_user_id, organization_id, event_type, event_payload)
    VALUES
    (p_actor_portal_user_id, p_target_portal_user_id, v_org, 'USER_PASSWORD_RESET',
     jsonb_build_object('lockout_cleared', TRUE));
END;
$function$;


-- ----------------------------------------------------------------------------
-- New: own password change (the application verifies the current password).
-- ----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION admin.change_own_portal_user_password
(
    p_portal_user_id BIGINT,
    p_password_hash TEXT
)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO pg_catalog, admin
AS $function$
DECLARE
    v_org UUID;
BEGIN
    IF p_password_hash IS NULL OR p_password_hash NOT LIKE '$argon2id$%' THEN
        RAISE EXCEPTION 'A password hash in Argon2id format is required.' USING ERRCODE = '22023';
    END IF;

    SELECT organization_id INTO v_org
      FROM admin.portal_users
     WHERE portal_user_id = p_portal_user_id
       AND is_active
       FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Portal user is not active.' USING ERRCODE = '42501';
    END IF;

    UPDATE admin.portal_users
       SET password_hash = p_password_hash,
           password_changed_at = clock_timestamp(),
           updated_at = clock_timestamp()
     WHERE portal_user_id = p_portal_user_id;

    INSERT INTO admin.portal_user_audit
    (actor_portal_user_id, target_portal_user_id, organization_id, event_type, event_payload)
    VALUES
    (p_portal_user_id, p_portal_user_id, v_org, 'USER_PASSWORD_CHANGED', '{}'::jsonb);
END;
$function$;


-- ----------------------------------------------------------------------------
-- Ownership and grants (replaced functions keep theirs).
-- ----------------------------------------------------------------------------

ALTER FUNCTION admin.update_managed_portal_user_details(BIGINT, BIGINT, TEXT, TEXT) OWNER TO ems_admin;
ALTER FUNCTION admin.reset_managed_portal_user_password(BIGINT, BIGINT, TEXT) OWNER TO ems_admin;
ALTER FUNCTION admin.change_own_portal_user_password(BIGINT, TEXT) OWNER TO ems_admin;

REVOKE ALL ON FUNCTION admin.update_managed_portal_user_details(BIGINT, BIGINT, TEXT, TEXT) FROM PUBLIC;
REVOKE ALL ON FUNCTION admin.reset_managed_portal_user_password(BIGINT, BIGINT, TEXT) FROM PUBLIC;
REVOKE ALL ON FUNCTION admin.change_own_portal_user_password(BIGINT, TEXT) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION admin.update_managed_portal_user_details(BIGINT, BIGINT, TEXT, TEXT) TO ems_app;
GRANT EXECUTE ON FUNCTION admin.reset_managed_portal_user_password(BIGINT, BIGINT, TEXT) TO ems_app;
GRANT EXECUTE ON FUNCTION admin.change_own_portal_user_password(BIGINT, TEXT) TO ems_app;


-- ----------------------------------------------------------------------------
-- Postconditions.
-- ----------------------------------------------------------------------------

DO $post$
DECLARE
    v_signature TEXT;
BEGIN
    FOREACH v_signature IN ARRAY ARRAY[
        'admin.change_managed_portal_user_role(bigint, bigint, text)',
        'admin.set_managed_portal_user_active(bigint, bigint, boolean)',
        'admin.set_managed_portal_user_access_scope(bigint, bigint, text, uuid, uuid[])',
        'admin.update_managed_portal_user_details(bigint, bigint, text, text)',
        'admin.reset_managed_portal_user_password(bigint, bigint, text)',
        'admin.change_own_portal_user_password(bigint, text)'
    ] LOOP
        IF NOT has_function_privilege('ems_app', v_signature, 'EXECUTE') THEN
            RAISE EXCEPTION 'Migration 315 postcondition failed: ems_app cannot execute %', v_signature;
        END IF;

        IF EXISTS (
            SELECT 1
              FROM pg_proc p
             CROSS JOIN LATERAL aclexplode(COALESCE(p.proacl, acldefault('f', p.proowner))) a
             WHERE p.oid = v_signature::regprocedure
               AND a.grantee = 0
               AND a.privilege_type = 'EXECUTE'
        ) THEN
            RAISE EXCEPTION 'Migration 315 postcondition failed: PUBLIC can execute %', v_signature;
        END IF;

        IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'ems_customer_api')
           AND has_function_privilege('ems_customer_api', v_signature, 'EXECUTE') THEN
            RAISE EXCEPTION 'Migration 315 postcondition failed: ems_customer_api can execute %', v_signature;
        END IF;

        IF NOT EXISTS (
            SELECT 1
              FROM pg_proc p
             WHERE p.oid = v_signature::regprocedure
               AND p.prosecdef
               AND p.proconfig IS NOT NULL
               AND EXISTS (SELECT 1 FROM unnest(p.proconfig) c WHERE c LIKE 'search_path=%')
        ) THEN
            RAISE EXCEPTION 'Migration 315 postcondition failed: % is not SECURITY DEFINER with a pinned search_path', v_signature;
        END IF;
    END LOOP;
END
$post$;
