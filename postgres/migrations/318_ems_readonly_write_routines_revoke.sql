-- ============================================================================
-- Migration 318
-- ems_readonly loses EXECUTE on the ten write-capable SECURITY DEFINER
-- routines outside schema admin
--
-- Read-only production inventory (2026-11-04): besides the admin grants
-- removed by 316 / 317, ems_readonly -- the operators' read-only
-- investigation login -- can EXECUTE ten VOLATILE SECURITY DEFINER routines
-- (they run as ems_admin) that write:
--
--   analytics.refresh_energy_consumption_1min(timestamptz, timestamptz)    rewrites persisted tiers
--   analytics.refresh_energy_consumption_5min(timestamptz, timestamptz)
--   analytics.refresh_energy_consumption_15min(timestamptz, timestamptz)
--   analytics.refresh_energy_consumption_hourly(timestamptz, timestamptz)
--   analytics.refresh_energy_consumption_daily(timestamptz, timestamptz)
--   telemetry.refresh_environment_daily(timestamptz, timestamptz)
--   telemetry.ingest_live_rtdata(text, jsonb, timestamptz)                 writes live state
--   config.ensure_asset_demand_policy_for_site()                           trigger function
--   telemetry.capture_telegraf_mqtt_insert()                               trigger function
--   telemetry.set_energy_measurement_asset_id()                            trigger function
--
-- Nothing connects as ems_readonly for these: the refreshes run inside jobs
-- as their owner, live-telemetry calls ingest_live_rtdata as ems_app, and
-- trigger functions are not EXECUTE-checked when their triggers fire.
-- Staging and test grant ems_readonly none of them: a no-op there.
--
-- Precheck (catalog-driven): every VOLATILE SECURITY DEFINER routine outside
-- admin and the system / extension schemas that ems_readonly can execute
-- through an explicit grant must be one of these ten; anything else is
-- unreviewed drift and stops the migration rather than being left behind or
-- revoked blindly. ems_readonly must also be a member of no role, so that
-- no inherited EXECUTE escapes these explicit-ACL checks.
--
-- Only ems_readonly's EXECUTE on these ten changes. Every other privilege of
-- every role on every routine, relation, column and schema is kept and
-- compared against full before / after snapshots -- including ems_readonly's
-- SELECT on analytics / telemetry / metadata / config and its EXECUTE on
-- read-only (STABLE / IMMUTABLE) functions, and ems_app's EXECUTE on
-- ingest_live_rtdata. No body, owner, setting, table, role, job or data
-- change.
--
-- Production-scoped; requires 317. Rollback (not expected; it reopens the
-- exposure): GRANT EXECUTE ON FUNCTION <each routine above> TO ems_readonly;
-- ============================================================================

CREATE TEMP TABLE migration_318_routines (signature text PRIMARY KEY) ON COMMIT DROP;
INSERT INTO migration_318_routines (signature) VALUES
    ('analytics.refresh_energy_consumption_1min(timestamp with time zone,timestamp with time zone)'),
    ('analytics.refresh_energy_consumption_5min(timestamp with time zone,timestamp with time zone)'),
    ('analytics.refresh_energy_consumption_15min(timestamp with time zone,timestamp with time zone)'),
    ('analytics.refresh_energy_consumption_hourly(timestamp with time zone,timestamp with time zone)'),
    ('analytics.refresh_energy_consumption_daily(timestamp with time zone,timestamp with time zone)'),
    ('telemetry.refresh_environment_daily(timestamp with time zone,timestamp with time zone)'),
    ('telemetry.ingest_live_rtdata(text,jsonb,timestamp with time zone)'),
    ('config.ensure_asset_demand_policy_for_site()'),
    ('telemetry.capture_telegraf_mqtt_insert()'),
    ('telemetry.set_energy_measurement_asset_id()');

DO $pre$
DECLARE
    v_bad text;
BEGIN
    -- Each target exists and is what the inventory says: SECURITY DEFINER,
    -- VOLATILE, owned by ems_admin.
    SELECT string_agg(r.signature, ', ' ORDER BY r.signature)
      INTO v_bad
      FROM migration_318_routines AS r
      LEFT JOIN pg_proc AS p ON p.oid = to_regprocedure(r.signature)
     WHERE p.oid IS NULL
        OR NOT p.prosecdef
        OR p.provolatile <> 'v'
        OR pg_get_userbyid(p.proowner) <> 'ems_admin';
    IF v_bad IS NOT NULL THEN
        RAISE EXCEPTION 'Migration 318 precondition failed: missing, not SECURITY DEFINER, not VOLATILE or not owned by ems_admin: %', v_bad;
    END IF;

    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'ems_app') THEN
        RAISE EXCEPTION 'Migration 318 precondition failed: role ems_app does not exist';
    END IF;

    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'ems_readonly') THEN
        -- 317 first: no explicit ems_readonly grant left on any admin routine.
        IF EXISTS (SELECT 1
                     FROM pg_proc AS p
                     JOIN pg_namespace AS n ON n.oid = p.pronamespace
                    CROSS JOIN LATERAL aclexplode(p.proacl) AS a
                    WHERE n.nspname = 'admin' AND a.grantee = 'ems_readonly'::regrole) THEN
            RAISE EXCEPTION 'Migration 318 precondition failed: migration 317 is not applied';
        END IF;

        -- Its privileges are its own (production inventory: no memberships).
        -- A role membership could hand it EXECUTE that the explicit-ACL check
        -- below cannot see; review that first rather than proceed.
        SELECT string_agg(pg_get_userbyid(m.roleid), ', ' ORDER BY 1)
          INTO v_bad
          FROM pg_auth_members AS m
         WHERE m.member = 'ems_readonly'::regrole;
        IF v_bad IS NOT NULL THEN
            RAISE EXCEPTION 'Migration 318 precondition failed: ems_readonly is a member of role(s) %; review the privileges it inherits first', v_bad;
        END IF;

        -- Catalog-driven: no unreviewed write-capable routine outside admin.
        SELECT string_agg(p.oid::regprocedure::text, ', ' ORDER BY 1)
          INTO v_bad
          FROM pg_proc AS p
          JOIN pg_namespace AS n ON n.oid = p.pronamespace
         WHERE n.nspname NOT IN ('admin', 'pg_catalog', 'information_schema')
           AND n.nspname NOT LIKE 'pg\_%'
           AND n.nspname NOT LIKE '\_timescaledb%' AND n.nspname NOT LIKE 'timescaledb%'
           AND p.prosecdef
           AND p.provolatile = 'v'
           AND NOT EXISTS (SELECT 1 FROM pg_depend AS d
                            WHERE d.classid = 'pg_proc'::regclass AND d.objid = p.oid AND d.deptype = 'e')
           AND EXISTS (SELECT 1 FROM aclexplode(p.proacl) AS a WHERE a.grantee = 'ems_readonly'::regrole)
           AND p.oid::regprocedure::text NOT IN (SELECT signature FROM migration_318_routines);
        IF v_bad IS NOT NULL THEN
            RAISE EXCEPTION 'Migration 318 precondition failed: unreviewed write-capable SECURITY DEFINER routine(s) executable by ems_readonly: %', v_bad;
        END IF;
    END IF;
END
$pre$;

-- Full snapshots of every privilege that must NOT change.
CREATE TEMP TABLE migration_318_routines_before ON COMMIT DROP AS
SELECT p.oid,
       ARRAY(SELECT a::text
               FROM unnest(coalesce(p.proacl, acldefault('f', p.proowner))) AS a
              WHERE p.oid::regprocedure::text NOT IN (SELECT signature FROM migration_318_routines)
                 OR a::text NOT LIKE 'ems_readonly=%'
              ORDER BY 1) AS kept_acl,
       md5(p.prosrc) AS body,
       p.proowner,
       p.prosecdef,
       p.provolatile,
       p.proconfig
  FROM pg_proc AS p
  JOIN pg_namespace AS n ON n.oid = p.pronamespace
 WHERE n.nspname NOT LIKE 'pg\_%' AND n.nspname <> 'information_schema'
   AND n.nspname NOT LIKE '\_timescaledb%' AND n.nspname NOT LIKE 'timescaledb%';

CREATE TEMP TABLE migration_318_relations_before ON COMMIT DROP AS
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
   AND c.relkind IN ('r', 'p', 'v', 'm', 'f', 'S');

CREATE TEMP TABLE migration_318_schemas_before ON COMMIT DROP AS
SELECT n.oid, n.nspacl::text AS nspacl
  FROM pg_namespace AS n;

DO $revoke$
DECLARE
    v_signature text;
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'ems_readonly') THEN
        RAISE NOTICE 'Migration 318: role ems_readonly does not exist; nothing to revoke';
        RETURN;
    END IF;
    FOR v_signature IN SELECT signature FROM migration_318_routines ORDER BY signature LOOP
        EXECUTE format('REVOKE EXECUTE ON FUNCTION %s FROM ems_readonly', to_regprocedure(v_signature));
    END LOOP;
END
$revoke$;

DO $post$
DECLARE
    v_bad text;
BEGIN
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'ems_readonly') THEN
        -- ems_readonly executes none of the ten (explicitly or through PUBLIC).
        SELECT string_agg(signature, ', ' ORDER BY signature)
          INTO v_bad
          FROM migration_318_routines
         WHERE has_function_privilege('ems_readonly', to_regprocedure(signature), 'EXECUTE');
        IF v_bad IS NOT NULL THEN
            RAISE EXCEPTION 'Migration 318 postcondition failed: ems_readonly still executes %', v_bad;
        END IF;
    END IF;

    -- Every other privilege, body, owner and setting is unchanged.
    SELECT string_agg(b.oid::regprocedure::text, ', ' ORDER BY 1)
      INTO v_bad
      FROM migration_318_routines_before AS b
      JOIN pg_proc AS p ON p.oid = b.oid
     WHERE ARRAY(SELECT a::text
                   FROM unnest(coalesce(p.proacl, acldefault('f', p.proowner))) AS a
                  ORDER BY 1) IS DISTINCT FROM b.kept_acl
        OR md5(p.prosrc) <> b.body
        OR p.proowner <> b.proowner
        OR p.prosecdef <> b.prosecdef
        OR p.provolatile <> b.provolatile
        OR p.proconfig IS DISTINCT FROM b.proconfig;
    IF v_bad IS NOT NULL THEN
        RAISE EXCEPTION 'Migration 318 postcondition failed: another grant / body / owner / setting changed on %', v_bad;
    END IF;

    SELECT string_agg(b.oid::regclass::text, ', ' ORDER BY 1)
      INTO v_bad
      FROM migration_318_relations_before AS b
      JOIN pg_class AS c ON c.oid = b.oid
     WHERE c.relacl::text IS DISTINCT FROM b.relacl
        OR ARRAY(SELECT a.attname || ':' || coalesce(a.attacl::text, '')
                   FROM pg_attribute AS a
                  WHERE a.attrelid = c.oid AND a.attnum > 0 AND NOT a.attisdropped
                  ORDER BY a.attnum) IS DISTINCT FROM b.column_acls;
    IF v_bad IS NOT NULL THEN
        RAISE EXCEPTION 'Migration 318 postcondition failed: table / column privileges changed on %', v_bad;
    END IF;

    IF EXISTS (SELECT 1
                 FROM migration_318_schemas_before AS b
                 JOIN pg_namespace AS n ON n.oid = b.oid
                WHERE n.nspacl::text IS DISTINCT FROM b.nspacl) THEN
        RAISE EXCEPTION 'Migration 318 postcondition failed: a schema privilege changed';
    END IF;

    -- live-telemetry keeps its ingest path.
    IF NOT has_function_privilege('ems_app', 'telemetry.ingest_live_rtdata(text,jsonb,timestamp with time zone)', 'EXECUTE') THEN
        RAISE EXCEPTION 'Migration 318 postcondition failed: ems_app cannot execute telemetry.ingest_live_rtdata';
    END IF;
END
$post$;
