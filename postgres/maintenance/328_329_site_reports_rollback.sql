-- ============================================================================
-- Rollback of migrations 329 and 328 (Reports -> Create report, ADR-025).
--
-- Drops every 329 object, then every 328 object, and removes both ledger rows.
-- DESTRUCTIVE: deletes all generated report PDFs, versions, attempts, the
-- site enrolment, the reporting roster and the per-asset reporting settings
-- (their audit events in admin.audit_events are kept). Run only with explicit
-- authorization, after deploying an application image without the Create
-- report feature (EMS_SITE_REPORTS_ENABLED off / report-worker stopped).
-- Nothing else depends on these objects; no CASCADE is used.
-- ============================================================================

BEGIN;

DO $pre$
BEGIN
    IF EXISTS (
        SELECT 1 FROM pg_depend AS d
        JOIN pg_class AS c ON c.oid = d.refobjid
        JOIN pg_namespace AS n ON n.oid = c.relnamespace
        WHERE n.nspname = 'analytics'
          AND c.relname IN ('site_reports', 'site_report_versions', 'site_report_files', 'site_report_attempts',
                            'site_report_profiles', 'site_report_assets', 'asset_report_setting_versions')
          AND d.deptype = 'n'
          AND d.classid = 'pg_rewrite'::regclass
    ) THEN
        RAISE EXCEPTION 'Rollback refused: a view depends on a Create report table.';
    END IF;
END;
$pre$;

DROP FUNCTION IF EXISTS analytics.list_portal_site_reports(bigint, uuid, text, integer);
DROP FUNCTION IF EXISTS analytics.list_portal_site_report_versions(bigint, uuid);
DROP FUNCTION IF EXISTS analytics.get_portal_site_report_file(bigint, uuid);
DROP FUNCTION IF EXISTS analytics.get_portal_site_report_schedule(bigint, uuid);
DROP FUNCTION IF EXISTS analytics.request_site_report_generation(bigint, uuid, text, date);
DROP FUNCTION IF EXISTS analytics.request_site_report_regeneration(bigint, uuid);
DROP FUNCTION IF EXISTS analytics.retry_site_report(bigint, uuid);
DROP FUNCTION IF EXISTS analytics.delete_site_report(bigint, uuid);
DROP FUNCTION IF EXISTS analytics.restore_site_report(bigint, uuid);
DROP FUNCTION IF EXISTS analytics.permanently_delete_site_report(bigint, uuid, boolean);
DROP FUNCTION IF EXISTS analytics.list_site_reports_admin(bigint, uuid, text);
DROP FUNCTION IF EXISTS analytics.list_site_report_attempts_admin(bigint, uuid);
DROP FUNCTION IF EXISTS analytics.list_site_report_versions_admin(bigint, uuid);
DROP FUNCTION IF EXISTS analytics.schedule_due_site_reports(timestamptz);
DROP FUNCTION IF EXISTS analytics.claim_site_report_attempt(text, interval);
DROP FUNCTION IF EXISTS analytics.extend_site_report_lease(uuid, text, interval);
DROP FUNCTION IF EXISTS analytics.defer_site_report_attempt(uuid, text, timestamptz, text);
DROP FUNCTION IF EXISTS analytics.complete_site_report_attempt(uuid, text, text, bytea, text, integer, boolean, boolean, jsonb, jsonb, text, interval);
DROP FUNCTION IF EXISTS analytics.fail_site_report_attempt(uuid, text, text, text, boolean);
DROP FUNCTION IF EXISTS analytics.purge_site_reports(timestamptz);
DROP FUNCTION IF EXISTS analytics.site_report_read_identity_problem(uuid);
DROP FUNCTION IF EXISTS analytics.site_report_display_status(uuid);
DROP FUNCTION IF EXISTS analytics.site_report_fail_attempt(uuid, text, text, boolean);
DROP FUNCTION IF EXISTS analytics.site_report_retry_delay(integer);
DROP FUNCTION IF EXISTS analytics.site_report_ensure(uuid, text, date);
DROP FUNCTION IF EXISTS analytics.site_report_manage_target(bigint, uuid);

ALTER TABLE analytics.site_reports DROP CONSTRAINT IF EXISTS site_reports_latest_version_fk;
DROP TABLE analytics.site_report_attempts;
DROP TABLE analytics.site_report_files;
DROP TABLE analytics.site_report_versions;
DROP TABLE analytics.site_reports;

DROP FUNCTION IF EXISTS analytics.enrol_site_report_profile(bigint, uuid);
DROP FUNCTION IF EXISTS analytics.set_site_report_automation_account(bigint, uuid, bigint);
DROP FUNCTION IF EXISTS analytics.set_site_report_schedule(bigint, uuid, text, boolean);
DROP FUNCTION IF EXISTS analytics.set_site_report_asset(bigint, uuid, uuid, text, text, integer);
DROP FUNCTION IF EXISTS analytics.remove_site_report_asset(bigint, uuid, uuid);
DROP FUNCTION IF EXISTS analytics.add_asset_report_setting(bigint, uuid, text, jsonb, date);
DROP FUNCTION IF EXISTS analytics.withdraw_asset_report_setting(bigint, bigint);
DROP FUNCTION IF EXISTS analytics.get_site_report_profile_admin(bigint, uuid);
DROP FUNCTION IF EXISTS analytics.list_site_report_assets_admin(bigint, uuid);
DROP FUNCTION IF EXISTS analytics.list_asset_report_settings_admin(bigint, uuid, uuid);
DROP FUNCTION IF EXISTS analytics.get_site_report_worker_settings(uuid);
DROP FUNCTION IF EXISTS analytics.site_report_automation_problem(bigint, uuid);
DROP FUNCTION IF EXISTS analytics.site_report_setting_problem(text, jsonb);
DROP FUNCTION IF EXISTS analytics.site_report_audit(bigint, uuid, uuid, text, text, uuid, jsonb, jsonb);
DROP FUNCTION IF EXISTS analytics.site_report_require_staff(bigint, uuid);
DROP FUNCTION IF EXISTS analytics.site_report_staff_admin(bigint);

DROP TABLE analytics.asset_report_setting_versions;
DROP TABLE analytics.site_report_assets;
DROP TABLE analytics.site_report_profiles;

DELETE FROM admin.schema_migrations WHERE migration_id IN ('329_site_reports', '328_site_report_settings');

DO $post$
BEGIN
    IF EXISTS (SELECT 1 FROM pg_proc AS p JOIN pg_namespace AS n ON n.oid = p.pronamespace
               WHERE n.nspname = 'analytics' AND (p.proname ~ 'site_report' OR p.proname ~ 'asset_report_setting')) THEN
        RAISE EXCEPTION 'Rollback postcondition failed: a Create report function remains.';
    END IF;
    RAISE NOTICE 'Migrations 329 and 328 rolled back.';
END;
$post$;

COMMIT;
