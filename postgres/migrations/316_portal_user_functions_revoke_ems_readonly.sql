-- ============================================================================
-- Migration 316
-- Remove ems_readonly EXECUTE from the portal-user management and
-- authentication functions
--
-- On production, ems_readonly holds bulk pre-baseline EXECUTE grants on admin
-- functions (parity audit 2026-10-23; read-only check 2026-11-04: 98 of 110).
-- Every function below is SECURITY DEFINER (runs as ems_admin) except the
-- validate trigger function, and takes the acting portal user as a plain
-- argument -- so a database login as ems_readonly could create portal users,
-- change their role, status or access scope, reset passwords (after 315),
-- read password hashes, or record login successes / failures (lockout), by
-- naming an administrator's id. Staging and the test database already have
-- no ems_readonly grant on any of them; there this migration is a no-op.
--
--   admin.create_managed_portal_user(bigint, text, text, text, text, text, text, uuid, uuid[])
--   admin.change_managed_portal_user_role(bigint, bigint, text)
--   admin.set_managed_portal_user_active(bigint, bigint, boolean)
--   admin.set_managed_portal_user_access_scope(bigint, bigint, text, uuid, uuid[])
--   admin.update_managed_portal_user_details(bigint, bigint, text, text)      (315)
--   admin.reset_managed_portal_user_password(bigint, bigint, text)            (315)
--   admin.change_own_portal_user_password(bigint, text)                       (315)
--   admin.list_manageable_portal_users(bigint)
--   admin.portal_user_scope_contains_user(bigint, bigint)
--   admin.get_portal_user_for_authentication(text)       returns the password hash
--   admin.record_portal_login_failure(bigint)            drives the lockout
--   admin.record_portal_login_success(bigint)
--   admin.enforce_portal_user_site_scope()               trigger function
--   admin.validate_portal_user_site_assignment()         trigger function
--
-- Only ems_readonly loses EXECUTE. Every other grant (ems_admin, ems_app,
-- ems_customer_api where 314 granted it) is kept exactly; no body, owner,
-- SECURITY DEFINER setting, search_path, table, role or data changes. 315's
-- three new functions never had an ems_readonly grant (production has no
-- default privileges); they are listed so the end state is asserted for all.
-- Trigger functions are not EXECUTE-checked when a trigger fires.
--
-- Not in scope (separate review): the read-only authorization predicates
-- (portal_user_has_permission, portal_user_can_access_site / _asset), the
-- other admin functions ems_readonly can execute on production, and its
-- SELECT on admin.portal_users (which includes password_hash).
--
-- Requires 315 (its three functions must exist). Production-scoped.
-- Rollback (not expected; it reopens the exposure):
--   GRANT EXECUTE ON FUNCTION <each function above> TO ems_readonly;
-- ============================================================================

CREATE TEMP TABLE migration_316_functions (signature text PRIMARY KEY) ON COMMIT DROP;
INSERT INTO migration_316_functions (signature) VALUES
    ('admin.create_managed_portal_user(bigint,text,text,text,text,text,text,uuid,uuid[])'),
    ('admin.change_managed_portal_user_role(bigint,bigint,text)'),
    ('admin.set_managed_portal_user_active(bigint,bigint,boolean)'),
    ('admin.set_managed_portal_user_access_scope(bigint,bigint,text,uuid,uuid[])'),
    ('admin.update_managed_portal_user_details(bigint,bigint,text,text)'),
    ('admin.reset_managed_portal_user_password(bigint,bigint,text)'),
    ('admin.change_own_portal_user_password(bigint,text)'),
    ('admin.list_manageable_portal_users(bigint)'),
    ('admin.portal_user_scope_contains_user(bigint,bigint)'),
    ('admin.get_portal_user_for_authentication(text)'),
    ('admin.record_portal_login_failure(bigint)'),
    ('admin.record_portal_login_success(bigint)'),
    ('admin.enforce_portal_user_site_scope()'),
    ('admin.validate_portal_user_site_assignment()');

DO $pre$
DECLARE
    v_missing text;
BEGIN
    SELECT string_agg(signature, ', ' ORDER BY signature)
      INTO v_missing
      FROM migration_316_functions
     WHERE to_regprocedure(signature) IS NULL;
    IF v_missing IS NOT NULL THEN
        RAISE EXCEPTION 'Migration 316 precondition failed: missing (is 315 applied?): %', v_missing;
    END IF;

    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'ems_app') THEN
        RAISE EXCEPTION 'Migration 316 precondition failed: role ems_app does not exist';
    END IF;
END
$pre$;

-- Every grant except ems_readonly's, per function, before the change.
CREATE TEMP TABLE migration_316_before ON COMMIT DROP AS
SELECT p.oid,
       f.signature,
       ARRAY(SELECT a::text
               FROM unnest(coalesce(p.proacl, acldefault('f', p.proowner))) AS a
              WHERE a::text NOT LIKE 'ems_readonly=%'
              ORDER BY 1) AS other_grants,
       md5(p.prosrc) AS body,
       p.proowner,
       p.prosecdef,
       p.proconfig
  FROM migration_316_functions AS f
  JOIN pg_proc AS p ON p.oid = to_regprocedure(f.signature);

DO $revoke$
DECLARE
    v_oid oid;
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'ems_readonly') THEN
        RAISE NOTICE 'Migration 316: role ems_readonly does not exist; nothing to revoke';
        RETURN;
    END IF;
    FOR v_oid IN SELECT oid FROM migration_316_before ORDER BY signature LOOP
        EXECUTE format('REVOKE EXECUTE ON FUNCTION %s FROM ems_readonly', v_oid::regprocedure);
    END LOOP;
END
$revoke$;

DO $post$
DECLARE
    v_bad text;
BEGIN
    SELECT string_agg(b.signature, ', ' ORDER BY b.signature)
      INTO v_bad
      FROM migration_316_before AS b
      JOIN pg_proc AS p ON p.oid = b.oid
     WHERE (EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'ems_readonly')
            AND has_function_privilege('ems_readonly', p.oid, 'EXECUTE'))
        OR ARRAY(SELECT a::text
                   FROM unnest(coalesce(p.proacl, acldefault('f', p.proowner))) AS a
                  ORDER BY 1) IS DISTINCT FROM b.other_grants
        OR md5(p.prosrc) <> b.body
        OR p.proowner <> b.proowner
        OR p.prosecdef <> b.prosecdef
        OR p.proconfig IS DISTINCT FROM b.proconfig;
    IF v_bad IS NOT NULL THEN
        RAISE EXCEPTION 'Migration 316 postcondition failed: ems_readonly still executes, or another grant / body / owner / setting changed on %', v_bad;
    END IF;

    -- The application keeps every function it calls.
    SELECT string_agg(s, ', ' ORDER BY s)
      INTO v_bad
      FROM unnest(ARRAY[
          'admin.create_managed_portal_user(bigint,text,text,text,text,text,text,uuid,uuid[])',
          'admin.change_managed_portal_user_role(bigint,bigint,text)',
          'admin.set_managed_portal_user_active(bigint,bigint,boolean)',
          'admin.set_managed_portal_user_access_scope(bigint,bigint,text,uuid,uuid[])',
          'admin.update_managed_portal_user_details(bigint,bigint,text,text)',
          'admin.reset_managed_portal_user_password(bigint,bigint,text)',
          'admin.change_own_portal_user_password(bigint,text)',
          'admin.list_manageable_portal_users(bigint)',
          'admin.get_portal_user_for_authentication(text)',
          'admin.record_portal_login_failure(bigint)',
          'admin.record_portal_login_success(bigint)'
      ]) AS s
     WHERE NOT has_function_privilege('ems_app', to_regprocedure(s), 'EXECUTE');
    IF v_bad IS NOT NULL THEN
        RAISE EXCEPTION 'Migration 316 postcondition failed: ems_app cannot execute %', v_bad;
    END IF;
END
$post$;
