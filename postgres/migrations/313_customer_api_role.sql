-- ============================================================================
-- Migration 313
-- Least-privilege database role for the customer API (ADR-023)
--
-- The customer API (src.customer_main) serves the customer host's /api/v1
-- and /auth endpoints. Every database call it makes is one of the 44
-- customer-facing SECURITY DEFINER functions below (owner ems_admin, pinned
-- search_path): sign-in (get / record success / record failure), the
-- portal-scoped Analytics reads that re-derive tenant scope from
-- p_portal_user_id (admin.portal_user_can_access_site / _asset /
-- analytics.portal_user_can_access_space), and the Reports export jobs. It
-- reads no table or view directly.
--
-- This migration creates ems_customer_api with exactly that: USAGE on the
-- admin and analytics schemas and EXECUTE on those functions (every
-- overload). No table, view, sequence or other routine privilege; no
-- membership in any role. It replaces ems_app (about 159 grants, including
-- administration writes) for the customer API only; ems_app and every other
-- role, function body, owner, table, job and row are unchanged.
--
-- The role is created NOLOGIN, so it cannot be used to connect until an
-- operator enables it (a separately approved step; no secret in the
-- repository):
--     ALTER ROLE ems_customer_api LOGIN PASSWORD '<from the secret store>';
--
-- Scope: staging and test only (postgres/migration_environment_scope.csv);
-- production keeps its current roles until the customer/staff separation is
-- approved there.
--
-- Rollback: REVOKE ALL ON ALL FUNCTIONS IN SCHEMA admin, analytics FROM
-- ems_customer_api; REVOKE USAGE ON SCHEMA admin, analytics FROM
-- ems_customer_api; DROP ROLE ems_customer_api;
-- ============================================================================

CREATE TEMP TABLE migration_313_functions (qualified_name text PRIMARY KEY) ON COMMIT DROP;

INSERT INTO migration_313_functions (qualified_name) VALUES
    -- sign-in (src.auth.repository)
    ('admin.get_portal_user_for_authentication'),
    ('admin.record_portal_login_success'),
    ('admin.record_portal_login_failure'),
    -- portal scope and hierarchy (src.analytics_api_service)
    ('admin.list_accessible_sites'),
    ('admin.list_accessible_assets'),
    ('admin.portal_user_can_access_site'),
    ('admin.portal_user_can_access_asset'),
    ('admin.get_portal_asset_live_state'),
    ('analytics.portal_user_can_access_space'),
    ('analytics.list_portal_site_spaces'),
    -- Analytics API reads (src.analytics_api_service, src.analytics_trends_service)
    ('analytics.get_portal_site_energy_consumption'),
    ('analytics.get_portal_site_energy_consumption_periodic'),
    ('analytics.get_portal_site_energy_consumption_evidence'),
    ('analytics.get_portal_site_energy_availability'),
    ('analytics.get_portal_site_energy_typical_reference'),
    ('analytics.get_portal_site_demand_series'),
    ('analytics.get_portal_site_current_demand'),
    ('analytics.get_portal_site_power_quality_series'),
    ('analytics.get_portal_site_telemetry_freshness'),
    ('analytics.get_portal_site_alerts'),
    ('analytics.get_portal_alert_detail'),
    ('analytics.get_portal_space_measurement_series'),
    ('analytics.get_portal_asset_energy_series'),
    ('analytics.get_portal_asset_energy_intervals'),
    ('analytics.get_portal_asset_demand_series'),
    ('analytics.get_portal_asset_current_demand'),
    ('analytics.get_portal_asset_power_trend'),
    ('analytics.get_portal_asset_point_series'),
    ('analytics.get_portal_analytics_catalog'),
    ('analytics.get_portal_analytics_energy_availability'),
    ('analytics.get_portal_analytics_point_availability'),
    ('analytics.get_analytics_energy_resolution_floors'),
    ('analytics.get_analytics_point_resolution_floors'),
    -- Reports export (src.report_export_service, src.report_export_worker; migrations 309 / 312)
    ('analytics.create_portal_report_export_job'),
    ('analytics.list_portal_report_export_jobs'),
    ('analytics.get_portal_report_export_job'),
    ('analytics.retry_portal_report_export_job'),
    ('analytics.get_portal_report_export_file'),
    ('analytics.get_portal_asset_measurements_1m'),
    ('analytics.claim_report_export_job'),
    ('analytics.extend_report_export_lease'),
    ('analytics.complete_report_export_job'),
    ('analytics.fail_report_export_job'),
    ('analytics.purge_report_exports');

DO $pre$
DECLARE
    v_problem text;
BEGIN
    SELECT string_agg(f.qualified_name, ', ' ORDER BY f.qualified_name)
    INTO v_problem
    FROM migration_313_functions AS f
    WHERE NOT EXISTS (
        SELECT 1
        FROM pg_proc AS p
        JOIN pg_namespace AS n ON n.oid = p.pronamespace
        WHERE n.nspname || '.' || p.proname = f.qualified_name
    )
       OR EXISTS (
        SELECT 1
        FROM pg_proc AS p
        JOIN pg_namespace AS n ON n.oid = p.pronamespace
        WHERE n.nspname || '.' || p.proname = f.qualified_name
          AND NOT p.prosecdef
    );
    IF v_problem IS NOT NULL THEN
        RAISE EXCEPTION 'Migration 313 precondition failed: missing or not SECURITY DEFINER: %', v_problem;
    END IF;
END
$pre$;

DO $role$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'ems_customer_api') THEN
        CREATE ROLE ems_customer_api
            NOLOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT NOREPLICATION NOBYPASSRLS;
    END IF;
END
$role$;

COMMENT ON ROLE ems_customer_api IS
'ADR-023 / migration 313: customer API (src.customer_main). USAGE on schemas admin, analytics and EXECUTE on the customer-facing SECURITY DEFINER functions only (sign-in, portal-scoped Analytics reads, Reports export). Created NOLOGIN; an operator enables LOGIN with a password from the secret store.';

GRANT USAGE ON SCHEMA admin, analytics TO ems_customer_api;

DO $grant$
DECLARE
    v_signature regprocedure;
BEGIN
    FOR v_signature IN
        SELECT p.oid::regprocedure
        FROM pg_proc AS p
        JOIN pg_namespace AS n ON n.oid = p.pronamespace
        JOIN migration_313_functions AS f ON f.qualified_name = n.nspname || '.' || p.proname
        ORDER BY 1::text
    LOOP
        EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO ems_customer_api', v_signature);
    END LOOP;
END
$grant$;

DO $post$
DECLARE
    v_role pg_roles%ROWTYPE;
    v_missing text;
    v_extra text;
BEGIN
    SELECT * INTO v_role FROM pg_roles WHERE rolname = 'ems_customer_api';
    IF v_role.rolsuper OR v_role.rolbypassrls OR v_role.rolcreaterole OR v_role.rolcreatedb THEN
        RAISE EXCEPTION 'Migration 313 postcondition failed: ems_customer_api has elevated attributes';
    END IF;

    -- Every overload of every listed function is executable by the role.
    SELECT string_agg(p.oid::regprocedure::text, ', ')
    INTO v_missing
    FROM pg_proc AS p
    JOIN pg_namespace AS n ON n.oid = p.pronamespace
    JOIN migration_313_functions AS f ON f.qualified_name = n.nspname || '.' || p.proname
    WHERE NOT has_function_privilege('ems_customer_api', p.oid, 'EXECUTE');
    IF v_missing IS NOT NULL THEN
        RAISE EXCEPTION 'Migration 313 postcondition failed: EXECUTE missing on %', v_missing;
    END IF;

    -- No direct privilege on any table, view or sequence, and no role membership.
    SELECT string_agg(DISTINCT c.relnamespace::regnamespace || '.' || c.relname, ', ')
    INTO v_extra
    FROM pg_class AS c
    CROSS JOIN LATERAL aclexplode(c.relacl) AS acl
    WHERE c.relacl IS NOT NULL
      AND acl.grantee = (SELECT oid FROM pg_roles WHERE rolname = 'ems_customer_api');
    IF v_extra IS NOT NULL THEN
        RAISE EXCEPTION 'Migration 313 postcondition failed: ems_customer_api has relation privileges on %', v_extra;
    END IF;

    IF EXISTS (
        SELECT 1 FROM pg_auth_members
        WHERE member = (SELECT oid FROM pg_roles WHERE rolname = 'ems_customer_api')
    ) THEN
        RAISE EXCEPTION 'Migration 313 postcondition failed: ems_customer_api is a member of another role';
    END IF;
END
$post$;
