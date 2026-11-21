-- ============================================================================
-- Migration 330
-- Reports -> Create report: (1) a product-owner-approved RETROSPECTIVE AHU
-- reporting baseline, and (2) on-demand generation in the customer portal for
-- Site Admins and WiseWatts Admins (ADR-025 Amendment 1; planning package
-- revision 4.2, decisions A112-A117).
--
-- WHY
--   (1) The product owner approved (2026-11-21) treating the currently approved
--       AHU reporting configuration of Radisson Blu Coimbatore as effective
--       from 1 October 2026, superseding A17/A18 FOR THIS CONFIGURATION ONLY.
--       Settings remain never back-dated through the normal path
--       (analytics.add_asset_report_setting is unchanged and still rejects a
--       past date). The baseline is a configuration-history backfill: it is
--       recorded, audited and labelled as a WiseWatts-approved retrospective
--       reporting baseline -- NOT verified historical hotel operating practice.
--   (2) On-demand generation moves into the customer portal (Reports -> Create
--       report) for active ADMIN-role users with access to the site (Site
--       Admins and WiseWatts Admins). Operators and Viewers stay view and
--       download only. Refines A107.
--
-- WHAT THIS MIGRATION DOES NOT DO (A114, A115)
--   * It creates no report, no attempt and changes no schedule or resume time.
--     Applying the baseline never generates a report. Historical reports are
--     generated only when an authorised user explicitly requests a period.
--   * It applies no baseline itself: the baseline is applied afterwards, once,
--     by a WiseWatts Admin calling apply_site_report_retrospective_baseline
--     with the exact setting versions being back-dated (separate, explicitly
--     authorised operation; postgres/maintenance/330_coimbatore_retrospective_baseline_apply.sql).
--
-- OBJECTS (owned by ems_admin)
--   analytics.site_report_retrospective_baselines   one approved baseline per site
--   analytics.asset_report_setting_versions.retrospective_baseline_id (new, nullable)
--   analytics.apply_site_report_retrospective_baseline   ems_app (WiseWatts Admin)
--   analytics.get_site_report_retrospective_baselines    ems_app (report worker)
--   analytics.site_report_can_generate                   internal helper
--   analytics.request_portal_site_report                 ems_customer_api + ems_app
--   analytics.site_report_read_identity_problem          replaced (requester rule widened)
--   analytics.list_portal_site_reports                   re-created with retrospective_baseline
--
-- RULES ENFORCED HERE (never only in the UI)
--   Baseline: WiseWatts Admin only; one per site; effective date in the past
--   (site time) and at most 180 days back; only HVAC_AHU roster assets; the
--   caller names EXACTLY the setting versions currently in force for every
--   AHU (setpoint, schedule, thresholds), each of which must be its asset's
--   and key's EARLIEST active version (no recorded history is overridden);
--   values are copied unchanged; approval reference, approver and statement
--   are mandatory; every inserted version and the baseline are audited.
--   Portal generation: active ADMIN role + site access, never the site's
--   automation account; period must have ended; an existing ACTIVE report gets
--   a NEW version (previous versions stay); a report in the recycle bin is
--   refused; at most 3 user-requested attempts queued per site.
--
-- Staging/test only (A106). Rollback:
-- postgres/maintenance/330_site_report_retrospective_baseline_rollback.sql.
-- ============================================================================

DO $pre$
BEGIN
    IF to_regclass('analytics.site_reports') IS NULL
       OR to_regprocedure('analytics.site_report_ensure(uuid, text, date)') IS NULL
       OR to_regprocedure('analytics.list_portal_site_reports(bigint, uuid, text, integer)') IS NULL THEN
        RAISE EXCEPTION 'Migration 330 precondition failed: migration 328/329 objects are missing.';
    END IF;
    IF to_regclass('analytics.site_report_retrospective_baselines') IS NOT NULL THEN
        RAISE EXCEPTION 'Migration 330 precondition failed: analytics.site_report_retrospective_baselines already exists.';
    END IF;
END;
$pre$;


-- ----------------------------------------------------------------------------
-- 1. Baseline record and version link.
-- ----------------------------------------------------------------------------

CREATE TABLE analytics.site_report_retrospective_baselines
(
    id                  BIGSERIAL   PRIMARY KEY,
    site_id             UUID        NOT NULL UNIQUE REFERENCES analytics.site_report_profiles (site_id) ON DELETE CASCADE,
    effective_date      DATE        NOT NULL,
    effective_from      TIMESTAMPTZ NOT NULL,
    basis               TEXT        NOT NULL DEFAULT 'WISEWATTS_APPROVED_RETROSPECTIVE_BASELINE',
    approval_reference  TEXT        NOT NULL,
    approved_by         TEXT        NOT NULL,
    statement           TEXT        NOT NULL,
    recorded_by         BIGINT      NOT NULL REFERENCES admin.portal_users (portal_user_id),
    recorded_at         TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    CONSTRAINT site_report_retro_basis_chk CHECK (basis = 'WISEWATTS_APPROVED_RETROSPECTIVE_BASELINE'),
    CONSTRAINT site_report_retro_text_chk CHECK (
        char_length(btrim(approval_reference)) BETWEEN 1 AND 200
        AND char_length(btrim(approved_by)) BETWEEN 1 AND 200
        AND char_length(btrim(statement)) BETWEEN 1 AND 1000)
);
ALTER TABLE analytics.site_report_retrospective_baselines OWNER TO ems_admin;
ALTER SEQUENCE analytics.site_report_retrospective_baselines_id_seq OWNER TO ems_admin;
REVOKE ALL ON analytics.site_report_retrospective_baselines FROM PUBLIC, ems_app, grafana_reader;
DO $r$ BEGIN
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'ems_customer_api') THEN
        EXECUTE 'REVOKE ALL ON analytics.site_report_retrospective_baselines FROM ems_customer_api';
    END IF;
END $r$;
COMMENT ON TABLE analytics.site_report_retrospective_baselines IS
'Migration 330 (ADR-025 Amendment 1, A112): a product-owner-approved retrospective AHU reporting baseline -- the approved AHU settings treated as in force from effective_from (00:00 site time on effective_date). A WiseWatts-approved reporting baseline, NOT verified historical operating practice. One per site; never updated.';

ALTER TABLE analytics.asset_report_setting_versions
    ADD COLUMN retrospective_baseline_id BIGINT REFERENCES analytics.site_report_retrospective_baselines (id);
COMMENT ON COLUMN analytics.asset_report_setting_versions.retrospective_baseline_id IS
'Migration 330: set only on versions inserted by apply_site_report_retrospective_baseline (back-dated under an approved baseline, A112). NULL for every normally saved version, which can never be back-dated (A17, A18).';


-- ----------------------------------------------------------------------------
-- 2. Apply the retrospective baseline (WiseWatts Admin; once per site).
-- ----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION analytics.apply_site_report_retrospective_baseline(
    p_portal_user_id BIGINT, p_site_id UUID, p_effective_date DATE, p_source_version_ids BIGINT[],
    p_approval_reference TEXT, p_approved_by TEXT, p_statement TEXT
)
RETURNS TABLE (baseline_id BIGINT, version_id BIGINT, source_version_id BIGINT, asset_id UUID, setting_key TEXT,
               effective_from TIMESTAMPTZ)
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path TO pg_catalog, analytics, admin, metadata
AS $function$
DECLARE
    v_org UUID;
    v_tz TEXT;
    v_today DATE;
    v_from TIMESTAMPTZ;
    v_expected BIGINT[];
    v_given BIGINT[];
    v_baseline BIGINT;
    v_src analytics.asset_report_setting_versions%ROWTYPE;
    v_new analytics.asset_report_setting_versions%ROWTYPE;
    v_created JSONB := '[]'::jsonb;
BEGIN
    SELECT r.organization_id, r.site_timezone INTO v_org, v_tz
    FROM analytics.site_report_require_staff(p_portal_user_id, p_site_id) AS r;
    IF NOT EXISTS (SELECT 1 FROM analytics.site_report_profiles WHERE site_id = p_site_id FOR UPDATE) THEN
        RAISE EXCEPTION 'site_report_not_enrolled' USING ERRCODE = 'P0002';
    END IF;
    IF EXISTS (SELECT 1 FROM analytics.site_report_retrospective_baselines WHERE site_id = p_site_id) THEN
        RAISE EXCEPTION 'report_baseline_exists' USING ERRCODE = '23505';
    END IF;
    IF btrim(COALESCE(p_approval_reference, '')) = '' OR btrim(COALESCE(p_approved_by, '')) = ''
       OR btrim(COALESCE(p_statement, '')) = '' THEN
        RAISE EXCEPTION 'report_baseline_approval_required' USING ERRCODE = '22023';
    END IF;
    v_today := (clock_timestamp() AT TIME ZONE v_tz)::date;
    IF p_effective_date IS NULL OR p_effective_date >= v_today OR p_effective_date < v_today - 180 THEN
        RAISE EXCEPTION 'report_baseline_invalid_date' USING ERRCODE = '22023';
    END IF;
    v_from := p_effective_date::timestamp AT TIME ZONE v_tz;

    -- The versions in force now for every HVAC_AHU roster asset.
    SELECT COALESCE(array_agg(c.id ORDER BY c.id), '{}') INTO v_expected
    FROM (
        SELECT DISTINCT ON (v.asset_id, v.setting_key) v.id
        FROM analytics.asset_report_setting_versions AS v
        JOIN analytics.site_report_assets AS a ON a.site_id = v.site_id AND a.asset_id = v.asset_id
        WHERE v.site_id = p_site_id AND a.report_group = 'HVAC_AHU' AND v.state = 'ACTIVE'
          AND v.effective_from <= clock_timestamp()
        ORDER BY v.asset_id, v.setting_key, v.effective_from DESC, v.id DESC
    ) AS c;
    SELECT COALESCE(array_agg(DISTINCT g ORDER BY g), '{}') INTO v_given FROM unnest(p_source_version_ids) AS g;
    IF cardinality(v_expected) = 0 OR v_given IS DISTINCT FROM v_expected
       OR cardinality(v_given) <> cardinality(p_source_version_ids) THEN
        RAISE EXCEPTION 'report_baseline_versions_mismatch: expected the % AHU setting versions currently in force',
            cardinality(v_expected) USING ERRCODE = '22023';
    END IF;

    INSERT INTO analytics.site_report_retrospective_baselines
        (site_id, effective_date, effective_from, approval_reference, approved_by, statement, recorded_by)
    VALUES (p_site_id, p_effective_date, v_from, btrim(p_approval_reference), btrim(p_approved_by), btrim(p_statement),
            p_portal_user_id)
    RETURNING id INTO v_baseline;

    FOR v_src IN SELECT * FROM analytics.asset_report_setting_versions WHERE id = ANY (v_given) ORDER BY id FOR UPDATE LOOP
        -- Never override recorded history: the source must be its asset's and
        -- key's earliest active version, and later than the baseline instant.
        IF v_src.effective_from <= v_from OR EXISTS (
            SELECT 1 FROM analytics.asset_report_setting_versions AS o
            WHERE o.asset_id = v_src.asset_id AND o.setting_key = v_src.setting_key AND o.state = 'ACTIVE'
              AND o.id <> v_src.id AND (o.effective_from, o.id) < (v_src.effective_from, v_src.id)) THEN
            RAISE EXCEPTION 'report_baseline_history_conflict: version % is not the earliest setting of its asset', v_src.id
                USING ERRCODE = '22023';
        END IF;
        INSERT INTO analytics.asset_report_setting_versions
            (site_id, asset_id, setting_key, value, effective_date, effective_from, created_by, retrospective_baseline_id)
        VALUES (v_src.site_id, v_src.asset_id, v_src.setting_key, v_src.value, p_effective_date, v_from,
                p_portal_user_id, v_baseline)
        RETURNING * INTO v_new;
        PERFORM analytics.site_report_audit(p_portal_user_id, v_org, p_site_id, 'REPORT_SETTING_RETROSPECTIVE',
                                            'ASSET_REPORT_SETTING', v_src.asset_id,
                                            jsonb_build_object('setting_key', v_src.setting_key, 'value', NULL),
                                            jsonb_build_object('setting_key', v_src.setting_key, 'value', v_src.value,
                                                               'effective_date', p_effective_date,
                                                               'effective_from', v_from, 'version_id', v_new.id,
                                                               'copied_from_version_id', v_src.id,
                                                               'retrospective_baseline_id', v_baseline));
        v_created := v_created || jsonb_build_object('version_id', v_new.id, 'source_version_id', v_src.id,
                                                     'asset_id', v_src.asset_id, 'setting_key', v_src.setting_key);
        baseline_id := v_baseline; version_id := v_new.id; source_version_id := v_src.id;
        asset_id := v_src.asset_id; setting_key := v_src.setting_key; effective_from := v_from;
        RETURN NEXT;
    END LOOP;

    PERFORM analytics.site_report_audit(p_portal_user_id, v_org, p_site_id, 'SITE_REPORT_RETROSPECTIVE_BASELINE',
                                        'SITE_REPORT_PROFILE', p_site_id, '{}'::jsonb,
                                        jsonb_build_object('baseline_id', v_baseline, 'effective_date', p_effective_date,
                                                           'effective_from', v_from,
                                                           'basis', 'WISEWATTS_APPROVED_RETROSPECTIVE_BASELINE',
                                                           'approval_reference', btrim(p_approval_reference),
                                                           'approved_by', btrim(p_approved_by),
                                                           'statement', btrim(p_statement),
                                                           'versions', v_created,
                                                           'reports_generated', 0));
END;
$function$;

-- Report worker: the site's baseline and the versions it back-dated.
CREATE OR REPLACE FUNCTION analytics.get_site_report_retrospective_baselines(p_site_id UUID)
RETURNS TABLE (baseline_id BIGINT, effective_date DATE, effective_from TIMESTAMPTZ, basis TEXT, approval_reference TEXT,
               approved_by TEXT, statement TEXT, recorded_at TIMESTAMPTZ, version_ids BIGINT[])
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path TO pg_catalog, analytics
AS $function$
    SELECT b.id, b.effective_date, b.effective_from, b.basis, b.approval_reference, b.approved_by, b.statement,
           b.recorded_at,
           COALESCE((SELECT array_agg(v.id ORDER BY v.id) FROM analytics.asset_report_setting_versions AS v
                     WHERE v.retrospective_baseline_id = b.id), '{}')
    FROM analytics.site_report_retrospective_baselines AS b
    WHERE b.site_id = p_site_id;
$function$;


-- ----------------------------------------------------------------------------
-- 3. On-demand generation in the customer portal (A113).
-- ----------------------------------------------------------------------------

-- Active ADMIN-role user with access to the site (a Site Admin or a WiseWatts
-- Admin), never the site's automation account.
CREATE OR REPLACE FUNCTION analytics.site_report_can_generate(p_portal_user_id BIGINT, p_site_id UUID)
RETURNS BOOLEAN
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path TO pg_catalog, analytics, admin
AS $function$
    SELECT EXISTS (
        SELECT 1 FROM admin.portal_users AS u
        WHERE u.portal_user_id = p_portal_user_id AND u.is_active AND u.role_code = 'ADMIN'
    )
    AND admin.portal_user_can_access_site(p_portal_user_id, p_site_id)
    AND NOT EXISTS (SELECT 1 FROM analytics.site_report_profiles AS p
                    WHERE p.site_id = p_site_id AND p.automation_portal_user_id = p_portal_user_id);
$function$;

CREATE OR REPLACE FUNCTION analytics.request_portal_site_report(
    p_portal_user_id BIGINT, p_site_id UUID, p_report_type TEXT, p_period_start DATE
)
RETURNS TABLE (report_id UUID, attempt_id UUID, action TEXT, trigger TEXT)
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path TO pg_catalog, analytics, admin, metadata
AS $function$
DECLARE
    v_org UUID;
    v_tz TEXT;
    v_report analytics.site_reports%ROWTYPE;
    v_report_id UUID;
    v_attempt UUID;
    v_trigger TEXT;
    v_action TEXT;
BEGIN
    IF NOT analytics.site_report_can_generate(p_portal_user_id, p_site_id) THEN
        RAISE EXCEPTION 'site_report_generate_forbidden' USING ERRCODE = '42501';
    END IF;
    SELECT p.organization_id, COALESCE(NULLIF(s.timezone, ''), 'UTC') INTO v_org, v_tz
    FROM analytics.site_report_profiles AS p JOIN metadata.sites AS s ON s.id = p.site_id
    WHERE p.site_id = p_site_id FOR UPDATE OF p;
    IF v_org IS NULL THEN
        RAISE EXCEPTION 'site_report_not_enrolled' USING ERRCODE = 'P0002';
    END IF;
    IF p_report_type NOT IN ('WEEKLY', 'MONTHLY') OR p_period_start IS NULL THEN
        RAISE EXCEPTION 'site_report_invalid_type' USING ERRCODE = '22023';
    END IF;
    IF (SELECT count(*) FROM analytics.site_report_attempts AS a JOIN analytics.site_reports AS r ON r.id = a.report_id
        WHERE r.site_id = p_site_id AND a.identity_kind = 'USER' AND a.status IN ('PENDING', 'PROCESSING')) >= 3 THEN
        RAISE EXCEPTION 'site_report_queue_full' USING ERRCODE = '55000';
    END IF;

    SELECT * INTO v_report FROM analytics.site_reports AS r
    WHERE r.site_id = p_site_id AND r.report_type = p_report_type AND r.period_start_date = p_period_start
    FOR UPDATE;
    IF FOUND AND v_report.state = 'DELETED' THEN
        RAISE EXCEPTION 'site_report_in_recycle_bin' USING ERRCODE = '23505';
    END IF;

    IF FOUND AND v_report.state = 'ACTIVE' THEN
        -- A new version; every earlier version stays as it is (A79, A80).
        IF EXISTS (SELECT 1 FROM analytics.site_report_attempts AS a
                   WHERE a.report_id = v_report.id AND a.status IN ('PENDING', 'PROCESSING')) THEN
            RAISE EXCEPTION 'site_report_attempt_active' USING ERRCODE = '55000';
        END IF;
        v_report_id := v_report.id;
        v_trigger := 'REGENERATE';
        v_action := 'REGENERATE';
    ELSE
        v_report_id := analytics.site_report_ensure(p_site_id, p_report_type, p_period_start);
        SELECT * INTO v_report FROM analytics.site_reports AS r WHERE r.id = v_report_id;
        v_action := 'GENERATE';
    END IF;
    IF (v_report.period_end_date + 1)::timestamp AT TIME ZONE v_tz > clock_timestamp() THEN
        RAISE EXCEPTION 'site_report_period_not_ended' USING ERRCODE = '22023';
    END IF;
    IF v_trigger IS NULL THEN
        v_trigger := CASE WHEN (v_report.period_end_date + 1)::timestamp AT TIME ZONE v_tz
                               < clock_timestamp() - INTERVAL '12 hours' THEN 'HISTORICAL' ELSE 'MANUAL' END;
    END IF;
    INSERT INTO analytics.site_report_attempts (report_id, trigger, identity_kind, requested_by)
    VALUES (v_report_id, v_trigger, 'USER', p_portal_user_id)
    RETURNING id INTO v_attempt;
    PERFORM analytics.site_report_audit(p_portal_user_id, v_org, p_site_id,
                                        CASE WHEN v_action = 'GENERATE' THEN 'SITE_REPORT_GENERATE'
                                             ELSE 'SITE_REPORT_REGENERATE' END,
                                        'SITE_REPORT', v_report_id,
                                        jsonb_build_object('latest_version_id', v_report.latest_version_id),
                                        jsonb_build_object('report_type', p_report_type, 'period_start', p_period_start,
                                                           'trigger', v_trigger, 'attempt_id', v_attempt,
                                                           'channel', 'CUSTOMER_PORTAL'));
    RETURN QUERY SELECT v_report_id, v_attempt, v_action, v_trigger;
END;
$function$;

-- The requester of a USER attempt must still be allowed to generate when the
-- attempt runs (WiseWatts Admin or Site Admin with site access); automatic
-- attempts are unchanged (A88-A90, A108).
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
    IF NOT analytics.site_report_can_generate(v_attempt.requested_by, v_site) THEN
        RETURN 'requester_not_authorized';
    END IF;
    RETURN NULL;
END;
$function$;

-- History gains retrospective_baseline: the latest version used settings
-- back-dated under an approved retrospective baseline (A116).
DROP FUNCTION analytics.list_portal_site_reports(bigint, uuid, text, integer);
CREATE FUNCTION analytics.list_portal_site_reports(
    p_portal_user_id BIGINT, p_site_id UUID, p_report_type TEXT, p_limit INTEGER
)
RETURNS TABLE (
    report_id UUID, report_type TEXT, period_start_date DATE, period_end_date DATE,
    comparison_start_date DATE, comparison_end_date DATE, status TEXT, status_reason TEXT,
    latest_version_id UUID, latest_version_no INTEGER, generated_at TIMESTAMPTZ, expires_at TIMESTAMPTZ,
    download_version_id UUID, incomplete_data BOOLEAN, comparison_incomplete BOOLEAN, coverage_summary JSONB,
    version_count INTEGER, retrospective_baseline BOOLEAN
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
           (SELECT count(*)::int FROM analytics.site_report_versions AS v WHERE v.report_id = r.id AND v.state <> 'PURGED'),
           COALESCE(jsonb_typeof(lv.settings_snapshot -> 'retrospective_baseline') = 'object', FALSE)
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


-- ----------------------------------------------------------------------------
-- 4. Ownership and grants.
-- ----------------------------------------------------------------------------

DO $grants$
DECLARE
    v_sig TEXT;
BEGIN
    FOREACH v_sig IN ARRAY ARRAY[
        'analytics.apply_site_report_retrospective_baseline(bigint, uuid, date, bigint[], text, text, text)',
        'analytics.get_site_report_retrospective_baselines(uuid)',
        'analytics.site_report_can_generate(bigint, uuid)',
        'analytics.request_portal_site_report(bigint, uuid, text, date)',
        'analytics.site_report_read_identity_problem(uuid)',
        'analytics.list_portal_site_reports(bigint, uuid, text, integer)'
    ] LOOP
        EXECUTE format('ALTER FUNCTION %s OWNER TO ems_admin', v_sig);
        EXECUTE format('REVOKE ALL ON FUNCTION %s FROM PUBLIC', v_sig);
    END LOOP;
    FOREACH v_sig IN ARRAY ARRAY[
        'analytics.apply_site_report_retrospective_baseline(bigint, uuid, date, bigint[], text, text, text)',
        'analytics.get_site_report_retrospective_baselines(uuid)',
        'analytics.request_portal_site_report(bigint, uuid, text, date)',
        'analytics.site_report_read_identity_problem(uuid)',
        'analytics.list_portal_site_reports(bigint, uuid, text, integer)'
    ] LOOP
        EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO ems_app', v_sig);
    END LOOP;
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'ems_customer_api') THEN
        EXECUTE 'GRANT EXECUTE ON FUNCTION analytics.list_portal_site_reports(bigint, uuid, text, integer) TO ems_customer_api';
        EXECUTE 'GRANT EXECUTE ON FUNCTION analytics.request_portal_site_report(bigint, uuid, text, date) TO ems_customer_api';
    END IF;
END;
$grants$;


-- ----------------------------------------------------------------------------
-- 5. Postconditions.
-- ----------------------------------------------------------------------------

DO $post$
DECLARE
    v_sig TEXT;
    v_role TEXT;
BEGIN
    FOR v_sig IN
        SELECT p.oid::regprocedure::text FROM pg_proc AS p JOIN pg_namespace AS n ON n.oid = p.pronamespace
        WHERE n.nspname = 'analytics' AND (p.proname ~ 'site_report' OR p.proname ~ 'asset_report_setting')
          AND p.proname NOT IN ('site_report_retry_delay', 'site_report_setting_problem')
    LOOP
        IF NOT EXISTS (
            SELECT 1 FROM pg_proc AS p JOIN pg_roles AS r ON r.oid = p.proowner
            WHERE p.oid = v_sig::regprocedure AND p.prosecdef AND r.rolname = 'ems_admin' AND p.proconfig IS NOT NULL
        ) THEN
            RAISE EXCEPTION 'Migration 330 postcondition failed: % is not SECURITY DEFINER / ems_admin / pinned search_path.', v_sig;
        END IF;
        IF has_function_privilege('public', v_sig, 'EXECUTE') THEN
            RAISE EXCEPTION 'Migration 330 postcondition failed: % is executable by PUBLIC.', v_sig;
        END IF;
        FOREACH v_role IN ARRAY ARRAY['grafana_reader', 'ems_readonly', 'ems_investigator'] LOOP
            IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = v_role) AND has_function_privilege(v_role, v_sig, 'EXECUTE') THEN
                RAISE EXCEPTION 'Migration 330 postcondition failed: % is executable by %.', v_sig, v_role;
            END IF;
        END LOOP;
        -- The customer API: the four read functions plus portal generation only.
        IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'ems_customer_api')
           AND has_function_privilege('ems_customer_api', v_sig, 'EXECUTE')
           AND v_sig NOT IN ('analytics.list_portal_site_reports(bigint,uuid,text,integer)',
                             'analytics.list_portal_site_report_versions(bigint,uuid)',
                             'analytics.get_portal_site_report_file(bigint,uuid)',
                             'analytics.get_portal_site_report_schedule(bigint,uuid)',
                             'analytics.request_portal_site_report(bigint,uuid,text,date)') THEN
            RAISE EXCEPTION 'Migration 330 postcondition failed: ems_customer_api can execute %.', v_sig;
        END IF;
    END LOOP;
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'ems_customer_api')
       AND has_function_privilege('ems_customer_api',
                                  'analytics.apply_site_report_retrospective_baseline(bigint, uuid, date, bigint[], text, text, text)',
                                  'EXECUTE') THEN
        RAISE EXCEPTION 'Migration 330 postcondition failed: the customer API can apply a retrospective baseline.';
    END IF;
    FOREACH v_role IN ARRAY ARRAY['ems_app', 'grafana_reader', 'ems_customer_api'] LOOP
        IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = v_role)
           AND has_table_privilege(v_role, 'analytics.site_report_retrospective_baselines', 'SELECT') THEN
            RAISE EXCEPTION 'Migration 330 postcondition failed: the baseline table is directly readable by %.', v_role;
        END IF;
    END LOOP;
    -- Applying this migration generates nothing (A114).
    RAISE NOTICE 'Migration 330: all postconditions passed (retrospective baseline table, portal generation for site admins).';
END;
$post$;
