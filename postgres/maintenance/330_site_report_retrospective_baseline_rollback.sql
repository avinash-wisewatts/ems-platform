-- ============================================================================
-- Rollback of migration 330 (retrospective AHU baseline + customer-portal
-- on-demand generation, ADR-025 Amendment 1).
--
-- DESTRUCTIVE: deletes every setting version inserted under a retrospective
-- baseline and the baseline records (their audit events in admin.audit_events
-- are kept; published PDF versions and their settings snapshots are NOT
-- touched). Restores the migration 329 forms of list_portal_site_reports and
-- site_report_read_identity_problem (manual attempts again require a WiseWatts
-- Admin) and removes portal generation. Run only with explicit authorization,
-- after deploying an application image without the portal generation route.
-- Pending/processing USER attempts requested by a non-WiseWatts Admin will then
-- fail requester_not_authorized when claimed.
-- Run this BEFORE 328_329_site_reports_rollback.sql if both are needed.
-- ============================================================================

BEGIN;

DROP FUNCTION IF EXISTS analytics.request_portal_site_report(bigint, uuid, text, date);
DROP FUNCTION IF EXISTS analytics.apply_site_report_retrospective_baseline(bigint, uuid, date, bigint[], text, text, text);
DROP FUNCTION IF EXISTS analytics.get_site_report_retrospective_baselines(uuid);

DELETE FROM analytics.asset_report_setting_versions WHERE retrospective_baseline_id IS NOT NULL;
ALTER TABLE analytics.asset_report_setting_versions DROP COLUMN retrospective_baseline_id;
DROP TABLE analytics.site_report_retrospective_baselines;

-- Migration 329 form of the read identity rule.
CREATE OR REPLACE FUNCTION analytics.site_report_read_identity_problem(p_attempt_id UUID)
RETURNS TEXT
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO pg_catalog, analytics, admin
AS $function$
DECLARE
    v_attempt analytics.site_report_attempts%ROWTYPE;
    v_site UUID;
    v_automation BIGINT;
BEGIN
    SELECT * INTO v_attempt FROM analytics.site_report_attempts WHERE id = p_attempt_id;
    SELECT r.site_id, p.automation_portal_user_id INTO v_site, v_automation
    FROM analytics.site_reports AS r JOIN analytics.site_report_profiles AS p ON p.site_id = r.site_id
    WHERE r.id = v_attempt.report_id;
    IF v_attempt.identity_kind = 'AUTOMATION' THEN
        IF v_automation IS NULL THEN
            RETURN 'automation_account_not_set';
        END IF;
        RETURN analytics.site_report_automation_problem(v_automation, v_site);
    END IF;
    IF NOT analytics.site_report_staff_admin(v_attempt.requested_by)
       OR NOT admin.portal_user_can_access_site(v_attempt.requested_by, v_site) THEN
        RETURN 'requester_not_authorized';
    END IF;
    RETURN NULL;
END;
$function$;

DROP FUNCTION IF EXISTS analytics.site_report_can_generate(bigint, uuid);

-- Migration 329 form of the customer history read.
DROP FUNCTION analytics.list_portal_site_reports(bigint, uuid, text, integer);
CREATE FUNCTION analytics.list_portal_site_reports(
    p_portal_user_id BIGINT, p_site_id UUID, p_report_type TEXT, p_limit INTEGER
)
RETURNS TABLE (
    report_id UUID, report_type TEXT, period_start_date DATE, period_end_date DATE,
    comparison_start_date DATE, comparison_end_date DATE, status TEXT, status_reason TEXT,
    latest_version_id UUID, latest_version_no INTEGER, generated_at TIMESTAMPTZ, expires_at TIMESTAMPTZ,
    download_version_id UUID, incomplete_data BOOLEAN, comparison_incomplete BOOLEAN, coverage_summary JSONB,
    version_count INTEGER
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path TO pg_catalog, analytics, admin
AS $function$
    SELECT r.id, r.report_type, r.period_start_date, r.period_end_date, r.comparison_start_date, r.comparison_end_date,
           analytics.site_report_display_status(r.id),
           (SELECT COALESCE(a.wait_message, a.error_message) FROM analytics.site_report_attempts AS a
            WHERE a.report_id = r.id AND a.status <> 'CANCELLED' ORDER BY a.created_at DESC, a.id DESC LIMIT 1),
           lv.id, lv.version_no, lv.generated_at, lv.expires_at,
           (SELECT v.id FROM analytics.site_report_versions AS v WHERE v.report_id = r.id AND v.state = 'AVAILABLE'
            ORDER BY v.version_no DESC LIMIT 1),
           lv.incomplete_data, lv.comparison_incomplete,
           CASE WHEN lv.id IS NULL THEN NULL ELSE jsonb_build_object(
               'hvac_available_pct', lv.coverage -> 'current' -> 'hvac' -> 'available_pct',
               'hvac_measured_pct', lv.coverage -> 'current' -> 'hvac' -> 'measured_pct',
               'kitchen_available_pct', lv.coverage -> 'current' -> 'kitchen' -> 'available_pct',
               'kitchen_measured_pct', lv.coverage -> 'current' -> 'kitchen' -> 'measured_pct',
               'peak_coverage_pct', lv.coverage -> 'current' -> 'peak_coverage_pct') END,
           (SELECT count(*)::int FROM analytics.site_report_versions AS v WHERE v.report_id = r.id AND v.state <> 'PURGED')
    FROM analytics.site_reports AS r
    JOIN analytics.site_report_profiles AS p ON p.site_id = r.site_id
    LEFT JOIN analytics.site_report_versions AS lv ON lv.id = r.latest_version_id
    WHERE r.site_id = p_site_id
      AND r.state = 'ACTIVE'
      AND (p_report_type IS NULL OR r.report_type = p_report_type)
      AND admin.portal_user_can_access_site(p_portal_user_id, p_site_id)
    ORDER BY r.period_end_date DESC, r.report_type
    LIMIT LEAST(GREATEST(COALESCE(p_limit, 100), 1), 500);
$function$;

DO $grants$
BEGIN
    ALTER FUNCTION analytics.list_portal_site_reports(bigint, uuid, text, integer) OWNER TO ems_admin;
    ALTER FUNCTION analytics.site_report_read_identity_problem(uuid) OWNER TO ems_admin;
    REVOKE ALL ON FUNCTION analytics.list_portal_site_reports(bigint, uuid, text, integer) FROM PUBLIC;
    REVOKE ALL ON FUNCTION analytics.site_report_read_identity_problem(uuid) FROM PUBLIC;
    GRANT EXECUTE ON FUNCTION analytics.list_portal_site_reports(bigint, uuid, text, integer) TO ems_app;
    GRANT EXECUTE ON FUNCTION analytics.site_report_read_identity_problem(uuid) TO ems_app;
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'ems_customer_api') THEN
        GRANT EXECUTE ON FUNCTION analytics.list_portal_site_reports(bigint, uuid, text, integer) TO ems_customer_api;
    END IF;
END;
$grants$;

DELETE FROM admin.schema_migrations WHERE migration_id = '330_site_report_retrospective_baseline_and_portal_generation';

DO $post$
BEGIN
    IF to_regclass('analytics.site_report_retrospective_baselines') IS NOT NULL
       OR to_regprocedure('analytics.request_portal_site_report(bigint, uuid, text, date)') IS NOT NULL THEN
        RAISE EXCEPTION 'Rollback postcondition failed: a migration 330 object remains.';
    END IF;
    RAISE NOTICE 'Migration 330 rolled back.';
END;
$post$;

COMMIT;
