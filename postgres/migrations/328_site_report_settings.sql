-- ============================================================================
-- Migration 328
-- Reports -> Create report: site enrolment, reporting roster and per-asset
-- reporting settings (ADR-025; planning package docs/07-features/create-report,
-- revision 4.1, decisions A2-A23, A88-A90).
--
-- WHY
--   The Radisson Blu Coimbatore weekly/monthly PDF report needs, per site, an
--   enrolment (with the dedicated automation account and the weekly/monthly
--   schedule switches), the WiseWatts-managed reporting asset list and groups,
--   and per-asset setpoints, operating schedules and AHU operating thresholds.
--   These were a JSON file and code constants in the reference tool; they are
--   now EMS data, maintained ONLY by WiseWatts Admins (active ADMIN, GLOBAL
--   scope) through the staff-only Administration App (A2-A4, A6, A12).
--
-- OBJECTS (owned by ems_admin; no table access for ems_app, grafana_reader or
-- ems_customer_api -- the staff diagnostic roles keep their existing default
-- read access to analytics, as for the migration 309 export tables)
--   analytics.site_report_profiles         one row per enrolled site
--   analytics.site_report_assets           reporting roster (asset, group, area)
--   analytics.asset_report_setting_versions append-only, effective-dated settings
--   SECURITY DEFINER functions, EXECUTE to ems_app only (the Administration App
--   and the report worker); customer-facing reads are in migration 329.
--
-- RULES ENFORCED HERE (never only in the UI)
--   * Every write requires an active ADMIN with GLOBAL scope who can access
--     the site (analytics.site_report_staff_admin + portal_user_can_access_site),
--     independent of EMS_ADMIN_STAFF_ONLY (A2, A3, A6, A7).
--   * Settings take effect today or later only. "Today" (site timezone) takes
--     effect at the actual save time (clock_timestamp()); a future date at 00:00
--     site time on that date; a past date is rejected with SQLSTATE 22023
--     report_setting_past_effective_date (A17-A19, A110). The caller never
--     supplies the effective time.
--   * Versions are never updated or deleted once effective; a future-dated
--     version may be withdrawn before it takes effect.
--   * Every change is audited in admin.audit_events (A22).
--   * The automation account must be an active ADMIN, SELECTED_SITES scope, in
--     the site's organization, whose ONLY site is this site (A88, A89, A108).
--
-- Staging/test only (postgres/migration_environment_scope.csv): Create report
-- is not approved for production (A106).
--
-- Rollback: postgres/maintenance/328_329_site_reports_rollback.sql (drops the
-- 329 objects first, then these; nothing else depends on them).
-- ============================================================================

DO $pre$
BEGIN
    IF to_regprocedure('admin.portal_user_can_access_site(bigint, uuid)') IS NULL THEN
        RAISE EXCEPTION 'Migration 328 precondition failed: admin.portal_user_can_access_site(bigint, uuid) is missing.';
    END IF;
    IF to_regclass('admin.audit_events') IS NULL OR to_regclass('admin.portal_user_site_access') IS NULL THEN
        RAISE EXCEPTION 'Migration 328 precondition failed: admin.audit_events / admin.portal_user_site_access missing.';
    END IF;
    IF to_regclass('analytics.site_report_profiles') IS NOT NULL
       OR to_regclass('analytics.site_report_assets') IS NOT NULL
       OR to_regclass('analytics.asset_report_setting_versions') IS NOT NULL THEN
        RAISE EXCEPTION 'Migration 328 precondition failed: a migration 328 table already exists.';
    END IF;
END;
$pre$;


-- ----------------------------------------------------------------------------
-- 1. Tables.
-- ----------------------------------------------------------------------------

CREATE TABLE analytics.site_report_profiles
(
    site_id                    UUID        PRIMARY KEY REFERENCES metadata.sites (id) ON DELETE CASCADE,
    organization_id            UUID        NOT NULL REFERENCES metadata.organizations (id),
    automation_portal_user_id  BIGINT      REFERENCES admin.portal_users (portal_user_id) ON DELETE SET NULL,
    weekly_enabled             BOOLEAN     NOT NULL DEFAULT TRUE,
    monthly_enabled            BOOLEAN     NOT NULL DEFAULT TRUE,
    weekly_resumed_at          TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    monthly_resumed_at         TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    weekly_changed_at          TIMESTAMPTZ,
    weekly_changed_by          BIGINT      REFERENCES admin.portal_users (portal_user_id) ON DELETE SET NULL,
    monthly_changed_at         TIMESTAMPTZ,
    monthly_changed_by         BIGINT      REFERENCES admin.portal_users (portal_user_id) ON DELETE SET NULL,
    enrolled_at                TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    enrolled_by                BIGINT      REFERENCES admin.portal_users (portal_user_id) ON DELETE SET NULL
);
ALTER TABLE analytics.site_report_profiles OWNER TO ems_admin;
REVOKE ALL ON analytics.site_report_profiles FROM PUBLIC, ems_app, grafana_reader;
DO $r$ BEGIN
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'ems_customer_api') THEN
        EXECUTE 'REVOKE ALL ON analytics.site_report_profiles FROM ems_customer_api';
    END IF;
END $r$;
COMMENT ON TABLE analytics.site_report_profiles IS
'Migration 328 (Create report, ADR-025): a site enrolled for weekly/monthly PDF reports. *_resumed_at: enrolment or latest resume; the scheduler never back-fills periods whose first attempt time is earlier (A70). automation_portal_user_id: the dedicated WiseWatts automation account used as the read identity for automatic reports (A88-A90, A108).';

CREATE TABLE analytics.site_report_assets
(
    site_id        UUID        NOT NULL REFERENCES analytics.site_report_profiles (site_id) ON DELETE CASCADE,
    asset_id       UUID        NOT NULL REFERENCES metadata.assets (id) ON DELETE CASCADE,
    report_group   TEXT        NOT NULL,
    area           TEXT,
    display_order  INTEGER     NOT NULL DEFAULT 0,
    added_at       TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    added_by       BIGINT      REFERENCES admin.portal_users (portal_user_id) ON DELETE SET NULL,
    PRIMARY KEY (site_id, asset_id),
    CONSTRAINT site_report_assets_group_chk
        CHECK (report_group IN ('HVAC_CHILLERS', 'HVAC_PUMPS', 'HVAC_COOLING_TOWERS', 'HVAC_AHU', 'KITCHEN')),
    CONSTRAINT site_report_assets_area_chk
        CHECK ((report_group = 'HVAC_AHU' AND COALESCE(area, '') IN ('LOBBY', 'RESTAURANT', 'BANQUET_1', 'BANQUET_2', 'PRE_FUNCTION'))
               OR (report_group <> 'HVAC_AHU' AND area IS NULL))
);
ALTER TABLE analytics.site_report_assets OWNER TO ems_admin;
REVOKE ALL ON analytics.site_report_assets FROM PUBLIC, ems_app, grafana_reader;
DO $r$ BEGIN
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'ems_customer_api') THEN
        EXECUTE 'REVOKE ALL ON analytics.site_report_assets FROM ems_customer_api';
    END IF;
END $r$;
COMMENT ON TABLE analytics.site_report_assets IS
'Migration 328 (Create report): the WiseWatts-managed reporting asset list and groups of an enrolled site (A7, A8). Only GLOBAL ADMINs change it.';

CREATE TABLE analytics.asset_report_setting_versions
(
    id              BIGSERIAL   PRIMARY KEY,
    site_id         UUID        NOT NULL REFERENCES analytics.site_report_profiles (site_id) ON DELETE CASCADE,
    asset_id        UUID        NOT NULL REFERENCES metadata.assets (id) ON DELETE CASCADE,
    setting_key     TEXT        NOT NULL,
    value           JSONB       NOT NULL,
    effective_date  DATE        NOT NULL,
    effective_from  TIMESTAMPTZ NOT NULL,
    state           TEXT        NOT NULL DEFAULT 'ACTIVE',
    created_by      BIGINT      NOT NULL REFERENCES admin.portal_users (portal_user_id),
    created_at      TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    withdrawn_by    BIGINT      REFERENCES admin.portal_users (portal_user_id),
    withdrawn_at    TIMESTAMPTZ,
    CONSTRAINT asset_report_setting_key_chk
        CHECK (setting_key IN ('TEMPERATURE_SETPOINT', 'OPERATING_SCHEDULE', 'OPERATING_THRESHOLDS')),
    CONSTRAINT asset_report_setting_state_chk CHECK (state IN ('ACTIVE', 'WITHDRAWN')),
    CONSTRAINT asset_report_setting_withdrawn_chk
        CHECK ((state = 'WITHDRAWN') = (withdrawn_at IS NOT NULL AND withdrawn_by IS NOT NULL)),
    CONSTRAINT asset_report_setting_value_object_chk CHECK (jsonb_typeof(value) = 'object')
);
CREATE INDEX asset_report_setting_versions_lookup_idx
    ON analytics.asset_report_setting_versions (asset_id, setting_key, effective_from);
CREATE INDEX asset_report_setting_versions_site_idx
    ON analytics.asset_report_setting_versions (site_id, created_at DESC);
ALTER TABLE analytics.asset_report_setting_versions OWNER TO ems_admin;
REVOKE ALL ON analytics.asset_report_setting_versions FROM PUBLIC, ems_app, grafana_reader;
DO $r$ BEGIN
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'ems_customer_api') THEN
        EXECUTE 'REVOKE ALL ON analytics.asset_report_setting_versions FROM ems_customer_api';
    END IF;
END $r$;
ALTER SEQUENCE analytics.asset_report_setting_versions_id_seq OWNER TO ems_admin;
COMMENT ON TABLE analytics.asset_report_setting_versions IS
'Migration 328 (Create report): append-only, effective-dated per-asset reporting settings (A13-A23). effective_from = the save instant for a change effective today, 00:00 site time for a future date; past dates are rejected. The value in force at t is the ACTIVE version with the greatest effective_from <= t (latest created on a tie).';


-- ----------------------------------------------------------------------------
-- 2. Internal helpers (no EXECUTE grants).
-- ----------------------------------------------------------------------------

-- Active ADMIN with GLOBAL scope: a WiseWatts Admin (A2, A6).
CREATE OR REPLACE FUNCTION analytics.site_report_staff_admin(p_portal_user_id BIGINT)
RETURNS BOOLEAN
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path TO pg_catalog, admin
AS $function$
    SELECT EXISTS (
        SELECT 1 FROM admin.portal_users AS u
        WHERE u.portal_user_id = p_portal_user_id
          AND u.is_active
          AND u.role_code = 'ADMIN'
          AND u.access_scope_mode = 'GLOBAL'
    );
$function$;

-- Raises insufficient_privilege unless the caller is a WiseWatts Admin who
-- can access the site; returns the site's organization and timezone.
CREATE OR REPLACE FUNCTION analytics.site_report_require_staff(p_portal_user_id BIGINT, p_site_id UUID,
                                                              OUT organization_id UUID, OUT site_timezone TEXT)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO pg_catalog, analytics, admin, metadata
AS $function$
BEGIN
    IF NOT analytics.site_report_staff_admin(p_portal_user_id)
       OR NOT admin.portal_user_can_access_site(p_portal_user_id, p_site_id) THEN
        RAISE EXCEPTION 'site_report_forbidden' USING ERRCODE = '42501';
    END IF;
    SELECT s.organization_id, COALESCE(NULLIF(s.timezone, ''), 'UTC')
    INTO organization_id, site_timezone
    FROM metadata.sites AS s WHERE s.id = p_site_id;
    IF organization_id IS NULL THEN
        RAISE EXCEPTION 'site_report_site_not_found' USING ERRCODE = 'P0002';
    END IF;
END;
$function$;

CREATE OR REPLACE FUNCTION analytics.site_report_audit(
    p_actor BIGINT, p_organization_id UUID, p_site_id UUID, p_action TEXT, p_entity_type TEXT,
    p_entity_id UUID, p_previous JSONB, p_new JSONB
)
RETURNS VOID
LANGUAGE sql
VOLATILE
SECURITY DEFINER
SET search_path TO pg_catalog, admin
AS $function$
    INSERT INTO admin.audit_events (transaction_id, organization_id, site_id, actor_portal_user_id, actor_role,
                                    action, entity_type, entity_id, previous_values, new_values, result)
    VALUES (gen_random_uuid(), p_organization_id, p_site_id, p_actor,
            COALESCE((SELECT role_code FROM admin.portal_users WHERE portal_user_id = p_actor), 'SYSTEM'),
            p_action, p_entity_type, p_entity_id, COALESCE(p_previous, '{}'::jsonb), COALESCE(p_new, '{}'::jsonb),
            'SUCCEEDED');
$function$;

-- Why an account cannot be the automation identity (NULL = it can): an active
-- ADMIN, SELECTED_SITES scope, in the site's organization, whose ONLY site is
-- this site and who can access it (A88, A89, A108).
CREATE OR REPLACE FUNCTION analytics.site_report_automation_problem(p_portal_user_id BIGINT, p_site_id UUID)
RETURNS TEXT
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO pg_catalog, admin, metadata
AS $function$
DECLARE
    v_user admin.portal_users%ROWTYPE;
    v_org  UUID;
    v_sites UUID[];
BEGIN
    SELECT * INTO v_user FROM admin.portal_users WHERE portal_user_id = p_portal_user_id;
    IF NOT FOUND THEN
        RETURN 'account_not_found';
    END IF;
    IF NOT v_user.is_active THEN
        RETURN 'account_inactive';
    END IF;
    IF v_user.role_code <> 'ADMIN' THEN
        RETURN 'account_not_admin';
    END IF;
    IF v_user.access_scope_mode IS DISTINCT FROM 'SELECTED_SITES' THEN
        RETURN 'account_scope_not_selected_sites';
    END IF;
    SELECT organization_id INTO v_org FROM metadata.sites WHERE id = p_site_id;
    IF v_user.organization_id IS DISTINCT FROM v_org THEN
        RETURN 'account_wrong_organization';
    END IF;
    SELECT array_agg(site_id ORDER BY site_id) INTO v_sites
    FROM admin.portal_user_site_access WHERE portal_user_id = p_portal_user_id;
    IF v_sites IS DISTINCT FROM ARRAY[p_site_id] THEN
        RETURN 'account_not_restricted_to_site';
    END IF;
    IF NOT admin.portal_user_can_access_site(p_portal_user_id, p_site_id) THEN
        RETURN 'account_no_site_access';
    END IF;
    RETURN NULL;
END;
$function$;

-- Server-side validation of a setting value (the Administration App also
-- validates schedules with src.report_engine.schedules before calling).
CREATE OR REPLACE FUNCTION analytics.site_report_setting_problem(p_setting_key TEXT, p_value JSONB)
RETURNS TEXT
LANGUAGE plpgsql
IMMUTABLE
SET search_path TO pg_catalog
AS $function$
DECLARE
    v_num NUMERIC;
    v_off NUMERIC;
    v_standby NUMERIC;
    v_on NUMERIC;
    v_day TEXT;
BEGIN
    IF p_value IS NULL OR jsonb_typeof(p_value) <> 'object' THEN
        RETURN 'value must be an object';
    END IF;
    IF p_setting_key = 'TEMPERATURE_SETPOINT' THEN
        IF jsonb_typeof(p_value -> 'value_c') <> 'number' THEN
            RETURN 'setpoint must be a number';
        END IF;
        v_num := (p_value ->> 'value_c')::NUMERIC;
        IF v_num < 10 OR v_num > 35 OR (v_num * 2) <> trunc(v_num * 2) THEN
            RETURN 'setpoint must be between 10.0 and 35.0 °C in 0.5 °C steps';
        END IF;
    ELSIF p_setting_key = 'OPERATING_SCHEDULE' THEN
        IF NOT (p_value ? 'schedule') OR NOT (jsonb_typeof(p_value -> 'schedule') IN ('object', 'null')) THEN
            RETURN 'schedule must be an object or null';
        END IF;
        IF jsonb_typeof(p_value -> 'schedule') = 'object' THEN
            FOR v_day IN SELECT jsonb_object_keys(p_value -> 'schedule') LOOP
                IF v_day NOT IN ('Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat')
                   OR jsonb_typeof(p_value -> 'schedule' -> v_day) <> 'array' THEN
                    RETURN 'schedule days must be Sun..Sat with a list of intervals';
                END IF;
            END LOOP;
        END IF;
        IF jsonb_typeof(p_value -> 'calculate_out_of_hours') IS DISTINCT FROM 'boolean'
           OR jsonb_typeof(p_value -> 'confirmed_by_hotel') IS DISTINCT FROM 'boolean' THEN
            RETURN 'calculate_out_of_hours and confirmed_by_hotel must be true or false';
        END IF;
    ELSIF p_setting_key = 'OPERATING_THRESHOLDS' THEN
        IF jsonb_typeof(p_value -> 'off_kw') <> 'number' OR jsonb_typeof(p_value -> 'on_kw') <> 'number'
           OR jsonb_typeof(p_value -> 'standby_kw') NOT IN ('number', 'null')
           OR jsonb_typeof(p_value -> 'runtime_enabled') IS DISTINCT FROM 'boolean' THEN
            RETURN 'thresholds need numeric off_kw and on_kw, numeric or null standby_kw, boolean runtime_enabled';
        END IF;
        v_off := (p_value ->> 'off_kw')::NUMERIC;
        v_on := (p_value ->> 'on_kw')::NUMERIC;
        v_standby := (p_value ->> 'standby_kw')::NUMERIC;
        IF v_off < 0 OR v_on <= v_off OR (v_standby IS NOT NULL AND (v_standby <= v_off OR v_standby >= v_on)) THEN
            RETURN 'thresholds must satisfy 0 <= OFF < STANDBY < ON (STANDBY optional)';
        END IF;
    ELSE
        RETURN 'unknown setting';
    END IF;
    RETURN NULL;
END;
$function$;


-- ----------------------------------------------------------------------------
-- 3. Administration App functions (WiseWatts Admins only).
-- ----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION analytics.enrol_site_report_profile(p_portal_user_id BIGINT, p_site_id UUID)
RETURNS SETOF analytics.site_report_profiles
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path TO pg_catalog, analytics, admin
AS $function$
DECLARE
    v_org UUID;
    v_tz TEXT;
BEGIN
    SELECT r.organization_id, r.site_timezone INTO v_org, v_tz
    FROM analytics.site_report_require_staff(p_portal_user_id, p_site_id) AS r;
    IF EXISTS (SELECT 1 FROM analytics.site_report_profiles WHERE site_id = p_site_id) THEN
        RAISE EXCEPTION 'site_report_already_enrolled' USING ERRCODE = '23505';
    END IF;
    PERFORM analytics.site_report_audit(p_portal_user_id, v_org, p_site_id, 'SITE_REPORT_ENROL', 'SITE_REPORT_PROFILE',
                                        p_site_id, '{}'::jsonb,
                                        jsonb_build_object('weekly_enabled', TRUE, 'monthly_enabled', TRUE));
    RETURN QUERY
    INSERT INTO analytics.site_report_profiles (site_id, organization_id, enrolled_by)
    VALUES (p_site_id, v_org, p_portal_user_id)
    RETURNING *;
END;
$function$;

CREATE OR REPLACE FUNCTION analytics.set_site_report_automation_account(
    p_portal_user_id BIGINT, p_site_id UUID, p_automation_portal_user_id BIGINT
)
RETURNS SETOF analytics.site_report_profiles
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path TO pg_catalog, analytics, admin
AS $function$
DECLARE
    v_org UUID;
    v_tz TEXT;
    v_problem TEXT;
    v_previous BIGINT;
BEGIN
    SELECT r.organization_id, r.site_timezone INTO v_org, v_tz
    FROM analytics.site_report_require_staff(p_portal_user_id, p_site_id) AS r;
    SELECT automation_portal_user_id INTO v_previous FROM analytics.site_report_profiles WHERE site_id = p_site_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'site_report_not_enrolled' USING ERRCODE = 'P0002';
    END IF;
    IF p_automation_portal_user_id IS NOT NULL THEN
        v_problem := analytics.site_report_automation_problem(p_automation_portal_user_id, p_site_id);
        IF v_problem IS NOT NULL THEN
            RAISE EXCEPTION 'site_report_automation_account_invalid: %', v_problem USING ERRCODE = '22023';
        END IF;
    END IF;
    PERFORM analytics.site_report_audit(p_portal_user_id, v_org, p_site_id, 'SITE_REPORT_AUTOMATION_ACCOUNT_CHANGE',
                                        'SITE_REPORT_PROFILE', p_site_id,
                                        jsonb_build_object('automation_portal_user_id', v_previous),
                                        jsonb_build_object('automation_portal_user_id', p_automation_portal_user_id));
    RETURN QUERY
    UPDATE analytics.site_report_profiles
    SET automation_portal_user_id = p_automation_portal_user_id
    WHERE site_id = p_site_id
    RETURNING *;
END;
$function$;

-- Pause (p_enabled = false) or resume (true) one schedule. A resume sets
-- *_resumed_at = now, so the scheduler never back-fills earlier periods (A70).
CREATE OR REPLACE FUNCTION analytics.set_site_report_schedule(
    p_portal_user_id BIGINT, p_site_id UUID, p_report_type TEXT, p_enabled BOOLEAN
)
RETURNS SETOF analytics.site_report_profiles
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path TO pg_catalog, analytics, admin
AS $function$
DECLARE
    v_org UUID;
    v_tz TEXT;
    v_profile analytics.site_report_profiles%ROWTYPE;
    v_was BOOLEAN;
BEGIN
    SELECT r.organization_id, r.site_timezone INTO v_org, v_tz
    FROM analytics.site_report_require_staff(p_portal_user_id, p_site_id) AS r;
    IF p_report_type NOT IN ('WEEKLY', 'MONTHLY') OR p_enabled IS NULL THEN
        RAISE EXCEPTION 'site_report_invalid_schedule' USING ERRCODE = '22023';
    END IF;
    SELECT * INTO v_profile FROM analytics.site_report_profiles WHERE site_id = p_site_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'site_report_not_enrolled' USING ERRCODE = 'P0002';
    END IF;
    v_was := CASE WHEN p_report_type = 'WEEKLY' THEN v_profile.weekly_enabled ELSE v_profile.monthly_enabled END;
    IF v_was = p_enabled THEN
        RETURN QUERY SELECT * FROM analytics.site_report_profiles WHERE site_id = p_site_id;
        RETURN;
    END IF;
    PERFORM analytics.site_report_audit(p_portal_user_id, v_org, p_site_id,
                                        CASE WHEN p_enabled THEN 'SITE_REPORT_SCHEDULE_RESUME' ELSE 'SITE_REPORT_SCHEDULE_PAUSE' END,
                                        'SITE_REPORT_PROFILE', p_site_id,
                                        jsonb_build_object('report_type', p_report_type, 'enabled', v_was),
                                        jsonb_build_object('report_type', p_report_type, 'enabled', p_enabled));
    IF p_report_type = 'WEEKLY' THEN
        RETURN QUERY
        UPDATE analytics.site_report_profiles
        SET weekly_enabled = p_enabled, weekly_changed_at = clock_timestamp(), weekly_changed_by = p_portal_user_id,
            weekly_resumed_at = CASE WHEN p_enabled THEN clock_timestamp() ELSE weekly_resumed_at END
        WHERE site_id = p_site_id
        RETURNING *;
    ELSE
        RETURN QUERY
        UPDATE analytics.site_report_profiles
        SET monthly_enabled = p_enabled, monthly_changed_at = clock_timestamp(), monthly_changed_by = p_portal_user_id,
            monthly_resumed_at = CASE WHEN p_enabled THEN clock_timestamp() ELSE monthly_resumed_at END
        WHERE site_id = p_site_id
        RETURNING *;
    END IF;
END;
$function$;

CREATE OR REPLACE FUNCTION analytics.set_site_report_asset(
    p_portal_user_id BIGINT, p_site_id UUID, p_asset_id UUID, p_report_group TEXT, p_area TEXT, p_display_order INTEGER
)
RETURNS SETOF analytics.site_report_assets
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path TO pg_catalog, analytics, admin, metadata
AS $function$
DECLARE
    v_org UUID;
    v_tz TEXT;
    v_previous JSONB;
BEGIN
    SELECT r.organization_id, r.site_timezone INTO v_org, v_tz
    FROM analytics.site_report_require_staff(p_portal_user_id, p_site_id) AS r;
    IF NOT EXISTS (SELECT 1 FROM analytics.site_report_profiles WHERE site_id = p_site_id) THEN
        RAISE EXCEPTION 'site_report_not_enrolled' USING ERRCODE = 'P0002';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM metadata.assets WHERE id = p_asset_id AND site_id = p_site_id) THEN
        RAISE EXCEPTION 'site_report_asset_not_in_site' USING ERRCODE = '22023';
    END IF;
    SELECT to_jsonb(a) - 'site_id' - 'added_at' - 'added_by' INTO v_previous
    FROM analytics.site_report_assets AS a WHERE a.site_id = p_site_id AND a.asset_id = p_asset_id;
    PERFORM analytics.site_report_audit(p_portal_user_id, v_org, p_site_id, 'SITE_REPORT_ROSTER_CHANGE',
                                        'SITE_REPORT_ASSET', p_asset_id, COALESCE(v_previous, '{}'::jsonb),
                                        jsonb_build_object('asset_id', p_asset_id, 'report_group', p_report_group,
                                                           'area', p_area, 'display_order', COALESCE(p_display_order, 0)));
    RETURN QUERY
    INSERT INTO analytics.site_report_assets (site_id, asset_id, report_group, area, display_order, added_by)
    VALUES (p_site_id, p_asset_id, p_report_group, NULLIF(p_area, ''), COALESCE(p_display_order, 0), p_portal_user_id)
    ON CONFLICT (site_id, asset_id) DO UPDATE
        SET report_group = EXCLUDED.report_group, area = EXCLUDED.area, display_order = EXCLUDED.display_order
    RETURNING *;
END;
$function$;

CREATE OR REPLACE FUNCTION analytics.remove_site_report_asset(p_portal_user_id BIGINT, p_site_id UUID, p_asset_id UUID)
RETURNS BOOLEAN
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path TO pg_catalog, analytics, admin
AS $function$
DECLARE
    v_org UUID;
    v_tz TEXT;
    v_previous JSONB;
BEGIN
    SELECT r.organization_id, r.site_timezone INTO v_org, v_tz
    FROM analytics.site_report_require_staff(p_portal_user_id, p_site_id) AS r;
    DELETE FROM analytics.site_report_assets AS a
    WHERE a.site_id = p_site_id AND a.asset_id = p_asset_id
    RETURNING to_jsonb(a) - 'site_id' - 'added_at' - 'added_by' INTO v_previous;
    IF v_previous IS NULL THEN
        RETURN FALSE;
    END IF;
    PERFORM analytics.site_report_audit(p_portal_user_id, v_org, p_site_id, 'SITE_REPORT_ROSTER_CHANGE',
                                        'SITE_REPORT_ASSET', p_asset_id, v_previous, jsonb_build_object('removed', TRUE));
    RETURN TRUE;
END;
$function$;

-- Adds a setting version. p_effective_date is the site-local date chosen in
-- the form; the effective time is computed here (A17-A19, A110).
CREATE OR REPLACE FUNCTION analytics.add_asset_report_setting(
    p_portal_user_id BIGINT, p_asset_id UUID, p_setting_key TEXT, p_value JSONB, p_effective_date DATE
)
RETURNS SETOF analytics.asset_report_setting_versions
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path TO pg_catalog, analytics, admin, metadata
AS $function$
DECLARE
    v_site UUID;
    v_org UUID;
    v_tz TEXT;
    v_today DATE;
    v_effective_from TIMESTAMPTZ;
    v_problem TEXT;
    v_previous JSONB;
    v_row analytics.asset_report_setting_versions%ROWTYPE;
BEGIN
    SELECT a.site_id INTO v_site FROM analytics.site_report_assets AS a WHERE a.asset_id = p_asset_id;
    IF v_site IS NULL THEN
        RAISE EXCEPTION 'site_report_asset_not_in_roster' USING ERRCODE = '22023';
    END IF;
    SELECT r.organization_id, r.site_timezone INTO v_org, v_tz
    FROM analytics.site_report_require_staff(p_portal_user_id, v_site) AS r;
    IF p_effective_date IS NULL THEN
        RAISE EXCEPTION 'report_setting_effective_date_required' USING ERRCODE = '22023';
    END IF;
    v_today := (clock_timestamp() AT TIME ZONE v_tz)::date;
    IF p_effective_date < v_today THEN
        RAISE EXCEPTION 'report_setting_past_effective_date' USING ERRCODE = '22023';
    ELSIF p_effective_date = v_today THEN
        v_effective_from := clock_timestamp();
    ELSE
        v_effective_from := p_effective_date::timestamp AT TIME ZONE v_tz;
    END IF;
    v_problem := analytics.site_report_setting_problem(p_setting_key, p_value);
    IF v_problem IS NOT NULL THEN
        RAISE EXCEPTION 'report_setting_invalid: %', v_problem USING ERRCODE = '22023';
    END IF;
    SELECT v.value INTO v_previous
    FROM analytics.asset_report_setting_versions AS v
    WHERE v.asset_id = p_asset_id AND v.setting_key = p_setting_key AND v.state = 'ACTIVE'
      AND v.effective_from <= v_effective_from
    ORDER BY v.effective_from DESC, v.id DESC
    LIMIT 1;
    INSERT INTO analytics.asset_report_setting_versions
        (site_id, asset_id, setting_key, value, effective_date, effective_from, created_by)
    VALUES (v_site, p_asset_id, p_setting_key, p_value, p_effective_date, v_effective_from, p_portal_user_id)
    RETURNING * INTO v_row;
    PERFORM analytics.site_report_audit(p_portal_user_id, v_org, v_site, 'REPORT_SETTING_CHANGE', 'ASSET_REPORT_SETTING',
                                        p_asset_id,
                                        jsonb_build_object('setting_key', p_setting_key, 'value', v_previous),
                                        jsonb_build_object('setting_key', p_setting_key, 'value', p_value,
                                                           'effective_date', p_effective_date,
                                                           'effective_from', v_effective_from, 'version_id', v_row.id));
    RETURN NEXT v_row;
END;
$function$;

-- Withdraws a future-dated version before it takes effect; never an effective one.
CREATE OR REPLACE FUNCTION analytics.withdraw_asset_report_setting(p_portal_user_id BIGINT, p_version_id BIGINT)
RETURNS SETOF analytics.asset_report_setting_versions
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path TO pg_catalog, analytics, admin
AS $function$
DECLARE
    v_row analytics.asset_report_setting_versions%ROWTYPE;
    v_org UUID;
    v_tz TEXT;
BEGIN
    SELECT * INTO v_row FROM analytics.asset_report_setting_versions WHERE id = p_version_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'report_setting_not_found' USING ERRCODE = 'P0002';
    END IF;
    SELECT r.organization_id, r.site_timezone INTO v_org, v_tz
    FROM analytics.site_report_require_staff(p_portal_user_id, v_row.site_id) AS r;
    IF v_row.state <> 'ACTIVE' OR v_row.effective_from <= clock_timestamp() THEN
        RAISE EXCEPTION 'report_setting_already_effective' USING ERRCODE = '22023';
    END IF;
    PERFORM analytics.site_report_audit(p_portal_user_id, v_org, v_row.site_id, 'REPORT_SETTING_WITHDRAW',
                                        'ASSET_REPORT_SETTING', v_row.asset_id,
                                        jsonb_build_object('version_id', v_row.id, 'setting_key', v_row.setting_key,
                                                           'value', v_row.value, 'effective_from', v_row.effective_from),
                                        jsonb_build_object('state', 'WITHDRAWN'));
    RETURN QUERY
    UPDATE analytics.asset_report_setting_versions
    SET state = 'WITHDRAWN', withdrawn_at = clock_timestamp(), withdrawn_by = p_portal_user_id
    WHERE id = p_version_id
    RETURNING *;
END;
$function$;

-- Administration App reads (WiseWatts Admins only).
CREATE OR REPLACE FUNCTION analytics.get_site_report_profile_admin(p_portal_user_id BIGINT, p_site_id UUID)
RETURNS TABLE (
    site_id UUID, organization_id UUID, enrolled BOOLEAN, automation_portal_user_id BIGINT,
    automation_username TEXT, automation_problem TEXT, weekly_enabled BOOLEAN, monthly_enabled BOOLEAN,
    weekly_resumed_at TIMESTAMPTZ, monthly_resumed_at TIMESTAMPTZ, weekly_changed_at TIMESTAMPTZ,
    monthly_changed_at TIMESTAMPTZ, enrolled_at TIMESTAMPTZ, site_timezone TEXT
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO pg_catalog, analytics, admin
AS $function$
DECLARE
    v_org UUID;
    v_tz TEXT;
BEGIN
    SELECT r.organization_id, r.site_timezone INTO v_org, v_tz
    FROM analytics.site_report_require_staff(p_portal_user_id, p_site_id) AS r;
    RETURN QUERY
    SELECT p_site_id, v_org, (p.site_id IS NOT NULL), p.automation_portal_user_id, u.username,
           CASE WHEN p.site_id IS NULL THEN NULL
                WHEN p.automation_portal_user_id IS NULL THEN 'account_not_set'
                ELSE analytics.site_report_automation_problem(p.automation_portal_user_id, p_site_id) END,
           COALESCE(p.weekly_enabled, FALSE), COALESCE(p.monthly_enabled, FALSE),
           p.weekly_resumed_at, p.monthly_resumed_at, p.weekly_changed_at, p.monthly_changed_at, p.enrolled_at, v_tz
    FROM (SELECT 1) AS one
    LEFT JOIN analytics.site_report_profiles AS p ON p.site_id = p_site_id
    LEFT JOIN admin.portal_users AS u ON u.portal_user_id = p.automation_portal_user_id;
END;
$function$;

CREATE OR REPLACE FUNCTION analytics.list_site_report_assets_admin(p_portal_user_id BIGINT, p_site_id UUID)
RETURNS TABLE (asset_id UUID, asset_name TEXT, report_group TEXT, area TEXT, display_order INTEGER, in_roster BOOLEAN)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO pg_catalog, analytics, metadata
AS $function$
BEGIN
    PERFORM analytics.site_report_require_staff(p_portal_user_id, p_site_id);
    RETURN QUERY
    SELECT a.id, a.name, r.report_group, r.area, COALESCE(r.display_order, 0), (r.asset_id IS NOT NULL)
    FROM metadata.assets AS a
    LEFT JOIN analytics.site_report_assets AS r ON r.asset_id = a.id AND r.site_id = p_site_id
    WHERE a.site_id = p_site_id
    ORDER BY (r.asset_id IS NULL), r.display_order, a.name;
END;
$function$;

CREATE OR REPLACE FUNCTION analytics.list_asset_report_settings_admin(p_portal_user_id BIGINT, p_site_id UUID, p_asset_id UUID)
RETURNS TABLE (
    id BIGINT, asset_id UUID, setting_key TEXT, value JSONB, effective_date DATE, effective_from TIMESTAMPTZ,
    state TEXT, created_by_username TEXT, created_at TIMESTAMPTZ, withdrawn_by_username TEXT, withdrawn_at TIMESTAMPTZ,
    in_force BOOLEAN
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO pg_catalog, analytics, admin
AS $function$
BEGIN
    PERFORM analytics.site_report_require_staff(p_portal_user_id, p_site_id);
    RETURN QUERY
    WITH current_versions AS (
        SELECT DISTINCT ON (v.asset_id, v.setting_key) v.id
        FROM analytics.asset_report_setting_versions AS v
        WHERE v.site_id = p_site_id AND v.state = 'ACTIVE' AND v.effective_from <= clock_timestamp()
        ORDER BY v.asset_id, v.setting_key, v.effective_from DESC, v.id DESC
    )
    SELECT v.id, v.asset_id, v.setting_key, v.value, v.effective_date, v.effective_from, v.state, cu.username,
           v.created_at, wu.username, v.withdrawn_at, (cv.id IS NOT NULL)
    FROM analytics.asset_report_setting_versions AS v
    LEFT JOIN current_versions AS cv ON cv.id = v.id
    LEFT JOIN admin.portal_users AS cu ON cu.portal_user_id = v.created_by
    LEFT JOIN admin.portal_users AS wu ON wu.portal_user_id = v.withdrawn_by
    WHERE v.site_id = p_site_id AND (p_asset_id IS NULL OR v.asset_id = p_asset_id)
    ORDER BY v.asset_id, v.setting_key, v.effective_from DESC, v.id DESC;
END;
$function$;

-- Report worker: the roster and every ACTIVE setting version of an enrolled site.
CREATE OR REPLACE FUNCTION analytics.get_site_report_worker_settings(p_site_id UUID)
RETURNS TABLE (asset_id UUID, asset_name TEXT, report_group TEXT, area TEXT, display_order INTEGER,
               setting_key TEXT, value JSONB, effective_from TIMESTAMPTZ, version_id BIGINT)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path TO pg_catalog, analytics, metadata
AS $function$
    SELECT r.asset_id, a.name, r.report_group, r.area, r.display_order,
           v.setting_key, v.value, v.effective_from, v.id
    FROM analytics.site_report_assets AS r
    JOIN metadata.assets AS a ON a.id = r.asset_id
    LEFT JOIN analytics.asset_report_setting_versions AS v
           ON v.asset_id = r.asset_id AND v.site_id = r.site_id AND v.state = 'ACTIVE'
    WHERE r.site_id = p_site_id
    ORDER BY r.display_order, a.name, v.setting_key, v.effective_from, v.id;
$function$;


-- ----------------------------------------------------------------------------
-- 4. Ownership and grants: EXECUTE to ems_app only (Administration App and
--    report worker). The helpers are callable only through these functions.
-- ----------------------------------------------------------------------------

DO $grants$
DECLARE
    v_sig TEXT;
BEGIN
    FOREACH v_sig IN ARRAY ARRAY[
        'analytics.site_report_staff_admin(bigint)',
        'analytics.site_report_require_staff(bigint, uuid)',
        'analytics.site_report_audit(bigint, uuid, uuid, text, text, uuid, jsonb, jsonb)',
        'analytics.site_report_automation_problem(bigint, uuid)',
        'analytics.site_report_setting_problem(text, jsonb)',
        'analytics.enrol_site_report_profile(bigint, uuid)',
        'analytics.set_site_report_automation_account(bigint, uuid, bigint)',
        'analytics.set_site_report_schedule(bigint, uuid, text, boolean)',
        'analytics.set_site_report_asset(bigint, uuid, uuid, text, text, integer)',
        'analytics.remove_site_report_asset(bigint, uuid, uuid)',
        'analytics.add_asset_report_setting(bigint, uuid, text, jsonb, date)',
        'analytics.withdraw_asset_report_setting(bigint, bigint)',
        'analytics.get_site_report_profile_admin(bigint, uuid)',
        'analytics.list_site_report_assets_admin(bigint, uuid)',
        'analytics.list_asset_report_settings_admin(bigint, uuid, uuid)',
        'analytics.get_site_report_worker_settings(uuid)'
    ] LOOP
        EXECUTE format('ALTER FUNCTION %s OWNER TO ems_admin', v_sig);
        EXECUTE format('REVOKE ALL ON FUNCTION %s FROM PUBLIC', v_sig);
    END LOOP;
    FOREACH v_sig IN ARRAY ARRAY[
        'analytics.enrol_site_report_profile(bigint, uuid)',
        'analytics.set_site_report_automation_account(bigint, uuid, bigint)',
        'analytics.set_site_report_schedule(bigint, uuid, text, boolean)',
        'analytics.set_site_report_asset(bigint, uuid, uuid, text, text, integer)',
        'analytics.remove_site_report_asset(bigint, uuid, uuid)',
        'analytics.add_asset_report_setting(bigint, uuid, text, jsonb, date)',
        'analytics.withdraw_asset_report_setting(bigint, bigint)',
        'analytics.get_site_report_profile_admin(bigint, uuid)',
        'analytics.list_site_report_assets_admin(bigint, uuid)',
        'analytics.list_asset_report_settings_admin(bigint, uuid, uuid)',
        'analytics.get_site_report_worker_settings(uuid)'
    ] LOOP
        EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO ems_app', v_sig);
    END LOOP;
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
        WHERE n.nspname = 'analytics'
          AND p.proname IN ('site_report_staff_admin', 'site_report_require_staff', 'site_report_audit',
                            'site_report_automation_problem', 'enrol_site_report_profile',
                            'set_site_report_automation_account', 'set_site_report_schedule', 'set_site_report_asset',
                            'remove_site_report_asset', 'add_asset_report_setting', 'withdraw_asset_report_setting',
                            'get_site_report_profile_admin', 'list_site_report_assets_admin',
                            'list_asset_report_settings_admin', 'get_site_report_worker_settings')
    LOOP
        IF NOT EXISTS (
            SELECT 1 FROM pg_proc AS p JOIN pg_roles AS r ON r.oid = p.proowner
            WHERE p.oid = v_sig::regprocedure AND p.prosecdef AND r.rolname = 'ems_admin' AND p.proconfig IS NOT NULL
        ) THEN
            RAISE EXCEPTION 'Migration 328 postcondition failed: % is not SECURITY DEFINER / ems_admin / pinned search_path.', v_sig;
        END IF;
        IF has_function_privilege('public', v_sig, 'EXECUTE') THEN
            RAISE EXCEPTION 'Migration 328 postcondition failed: % is executable by PUBLIC.', v_sig;
        END IF;
        FOREACH v_role IN ARRAY ARRAY['grafana_reader', 'ems_readonly', 'ems_investigator', 'ems_customer_api'] LOOP
            IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = v_role)
               AND has_function_privilege(v_role, v_sig, 'EXECUTE') THEN
                RAISE EXCEPTION 'Migration 328 postcondition failed: % is executable by %.', v_sig, v_role;
            END IF;
        END LOOP;
    END LOOP;
    FOREACH v_role IN ARRAY ARRAY['ems_app', 'grafana_reader', 'ems_customer_api'] LOOP
        IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = v_role) AND (
               has_table_privilege(v_role, 'analytics.site_report_profiles', 'SELECT')
            OR has_table_privilege(v_role, 'analytics.site_report_assets', 'SELECT')
            OR has_table_privilege(v_role, 'analytics.asset_report_setting_versions', 'SELECT')) THEN
            RAISE EXCEPTION 'Migration 328 postcondition failed: a reporting settings table is directly readable by %.', v_role;
        END IF;
    END LOOP;
    RAISE NOTICE 'Migration 328: all postconditions passed (site report profiles, roster, effective-dated settings; ems_app-only SECURITY DEFINER).';
END;
$post$;
