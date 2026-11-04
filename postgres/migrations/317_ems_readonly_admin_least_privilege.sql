-- ============================================================================
-- Migration 317
-- ems_readonly least privilege on schema admin
--
-- ems_readonly is the operators' read-only investigation login
-- (docs/10-operations/monitoring.md). On production it still holds bulk
-- pre-baseline grants on schema admin (read-only checks 2026-11-04): EXECUTE
-- on 87 admin functions after 316 -- 44 of them SECURITY DEFINER writes
-- (onboarding, commissioning, create / update of organizations, sites,
-- assets, devices and gateways, lifecycle changes, Grafana provisioning,
-- demand and capture policy, write_audit_event) and the rest actor-scoped
-- reads that take the acting portal user as a plain argument -- and SELECT
-- on admin.portal_users including password_hash. No application, Grafana,
-- Telegraf, release or CI path connects as ems_readonly, and an
-- investigation role needs none of this. Staging and the test database have
-- none of these grants: there this migration is a no-op.
--
-- 1. REVOKE EXECUTE from ems_readonly on every admin function / procedure
--    whose ACL holds an explicit ems_readonly entry (catalog-driven, so no
--    function is missed). PUBLIC is untouched: a routine executable by
--    PUBLIC (admin.list_accessible_asset_device_relationships) stays so; the
--    application relies on it (see 308).
-- 2. REVOKE ALL on admin.portal_users (table and every column, including
--    password_hash and email) and on its id sequence from ems_readonly.
--
-- Kept exactly: every other privilege of every role on every relation,
-- routine and schema -- including ems_readonly's SELECT on the analytics,
-- telemetry, metadata and config objects and on the other admin tables and
-- views (reviewed separately: inventory 2026-11-04), ems_app's grants, and
-- ems_customer_api's. No body, owner, setting, table, role, job or data
-- change. Postconditions compare full before / after ACL snapshots.
--
-- Production-scoped; requires 315 and 316. Rollback (not expected; it
-- reopens the exposure): re-GRANT the revoked privileges to ems_readonly.
-- ============================================================================

DO $pre$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'ems_app') THEN
        RAISE EXCEPTION 'Migration 317 precondition failed: role ems_app does not exist';
    END IF;
    IF to_regclass('admin.portal_users') IS NULL THEN
        RAISE EXCEPTION 'Migration 317 precondition failed: admin.portal_users does not exist';
    END IF;
    IF to_regprocedure('admin.reset_managed_portal_user_password(bigint,bigint,text)') IS NULL THEN
        RAISE EXCEPTION 'Migration 317 precondition failed: migration 315 is not applied';
    END IF;
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'ems_readonly')
       AND has_function_privilege('ems_readonly', 'admin.reset_managed_portal_user_password(bigint,bigint,text)', 'EXECUTE') THEN
        RAISE EXCEPTION 'Migration 317 precondition failed: migration 316 is not applied';
    END IF;
END
$pre$;

-- Full snapshots of every privilege that must NOT change.
CREATE TEMP TABLE migration_317_routines_before ON COMMIT DROP AS
SELECT p.oid,
       ARRAY(SELECT a::text
               FROM unnest(coalesce(p.proacl, acldefault('f', p.proowner))) AS a
              WHERE n.nspname <> 'admin' OR a::text NOT LIKE 'ems_readonly=%'
              ORDER BY 1) AS kept_acl,
       md5(p.prosrc) AS body,
       p.proowner,
       p.prosecdef,
       p.proconfig
  FROM pg_proc AS p
  JOIN pg_namespace AS n ON n.oid = p.pronamespace
 WHERE n.nspname NOT LIKE 'pg\_%' AND n.nspname <> 'information_schema'
   AND n.nspname NOT LIKE '\_timescaledb%' AND n.nspname NOT LIKE 'timescaledb%';

CREATE TEMP TABLE migration_317_relations_before ON COMMIT DROP AS
SELECT c.oid,
       c.relacl::text AS relacl,
       ARRAY(SELECT a.attname || ':' || coalesce(a.attacl::text, '')
               FROM pg_attribute AS a
              WHERE a.attrelid = c.oid AND a.attnum > 0 AND NOT a.attisdropped
              ORDER BY a.attnum) AS column_acls
  FROM pg_class AS c
  JOIN pg_namespace AS n ON n.oid = c.relnamespace
 WHERE n.nspname NOT LIKE 'pg\_%' AND n.nspname <> 'information_schema'
   AND n.nspname NOT LIKE '\_timescaledb%' AND n.nspname NOT LIKE 'timescaledb%'
   AND c.relkind IN ('r', 'p', 'v', 'm', 'f', 'S')
   AND c.oid NOT IN ('admin.portal_users'::regclass, 'admin.portal_users_portal_user_id_seq'::regclass);

CREATE TEMP TABLE migration_317_schemas_before ON COMMIT DROP AS
SELECT n.oid, n.nspacl::text AS nspacl
  FROM pg_namespace AS n;

DO $revoke$
DECLARE
    v_routine regprocedure;
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'ems_readonly') THEN
        RAISE NOTICE 'Migration 317: role ems_readonly does not exist; nothing to revoke';
        RETURN;
    END IF;

    FOR v_routine IN
        SELECT p.oid::regprocedure
          FROM pg_proc AS p
          JOIN pg_namespace AS n ON n.oid = p.pronamespace
         WHERE n.nspname = 'admin'
           AND EXISTS (SELECT 1
                         FROM aclexplode(p.proacl) AS a
                        WHERE a.grantee = 'ems_readonly'::regrole)
         ORDER BY 1::text
    LOOP
        EXECUTE format('REVOKE EXECUTE ON ROUTINE %s FROM ems_readonly', v_routine);
    END LOOP;

    REVOKE ALL ON TABLE admin.portal_users FROM ems_readonly;
    REVOKE ALL ON SEQUENCE admin.portal_users_portal_user_id_seq FROM ems_readonly;
END
$revoke$;

DO $post$
DECLARE
    v_bad text;
BEGIN
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'ems_readonly') THEN
        -- No explicit ems_readonly entry on any admin routine; nothing beyond PUBLIC.
        SELECT string_agg(p.oid::regprocedure::text, ', ' ORDER BY 1)
          INTO v_bad
          FROM pg_proc AS p
          JOIN pg_namespace AS n ON n.oid = p.pronamespace
         WHERE n.nspname = 'admin'
           AND (EXISTS (SELECT 1 FROM aclexplode(p.proacl) AS a WHERE a.grantee = 'ems_readonly'::regrole)
                OR (has_function_privilege('ems_readonly', p.oid, 'EXECUTE')
                    AND NOT has_function_privilege('public', p.oid, 'EXECUTE')));
        IF v_bad IS NOT NULL THEN
            RAISE EXCEPTION 'Migration 317 postcondition failed: ems_readonly still executes %', v_bad;
        END IF;

        -- No access to admin.portal_users at all (table, any column, sequence).
        IF has_table_privilege('ems_readonly', 'admin.portal_users', 'SELECT, INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER')
           OR has_any_column_privilege('ems_readonly', 'admin.portal_users', 'SELECT, INSERT, UPDATE, REFERENCES')
           OR has_sequence_privilege('ems_readonly', 'admin.portal_users_portal_user_id_seq', 'USAGE, SELECT, UPDATE') THEN
            RAISE EXCEPTION 'Migration 317 postcondition failed: ems_readonly can still access admin.portal_users';
        END IF;
    END IF;

    -- Every other privilege, body, owner and setting is unchanged.
    SELECT string_agg(b.oid::regprocedure::text, ', ' ORDER BY 1)
      INTO v_bad
      FROM migration_317_routines_before AS b
      JOIN pg_proc AS p ON p.oid = b.oid
      JOIN pg_namespace AS n ON n.oid = p.pronamespace
     WHERE ARRAY(SELECT a::text
                   FROM unnest(coalesce(p.proacl, acldefault('f', p.proowner))) AS a
                  ORDER BY 1) IS DISTINCT FROM b.kept_acl
        OR md5(p.prosrc) <> b.body
        OR p.proowner <> b.proowner
        OR p.prosecdef <> b.prosecdef
        OR p.proconfig IS DISTINCT FROM b.proconfig;
    IF v_bad IS NOT NULL THEN
        RAISE EXCEPTION 'Migration 317 postcondition failed: another grant / body / owner / setting changed on %', v_bad;
    END IF;

    SELECT string_agg(b.oid::regclass::text, ', ' ORDER BY 1)
      INTO v_bad
      FROM migration_317_relations_before AS b
      JOIN pg_class AS c ON c.oid = b.oid
     WHERE c.relacl::text IS DISTINCT FROM b.relacl
        OR ARRAY(SELECT a.attname || ':' || coalesce(a.attacl::text, '')
                   FROM pg_attribute AS a
                  WHERE a.attrelid = c.oid AND a.attnum > 0 AND NOT a.attisdropped
                  ORDER BY a.attnum) IS DISTINCT FROM b.column_acls;
    IF v_bad IS NOT NULL THEN
        RAISE EXCEPTION 'Migration 317 postcondition failed: table / column privileges changed on %', v_bad;
    END IF;

    IF EXISTS (SELECT 1
                 FROM migration_317_schemas_before AS b
                 JOIN pg_namespace AS n ON n.oid = b.oid
                WHERE n.nspacl::text IS DISTINCT FROM b.nspacl) THEN
        RAISE EXCEPTION 'Migration 317 postcondition failed: a schema privilege changed';
    END IF;

    -- The application keeps every portal-user function it calls.
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
        RAISE EXCEPTION 'Migration 317 postcondition failed: ems_app cannot execute %', v_bad;
    END IF;
END
$post$;
