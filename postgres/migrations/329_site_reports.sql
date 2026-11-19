-- ============================================================================
-- Migration 329
-- Reports -> Create report: report records, immutable PDF versions, files,
-- generation attempts, scheduling, retention and the recycle bin (ADR-025;
-- planning package revision 4.1, decisions A61-A87, A107-A111, status set).
--
-- OBJECTS (owned by ems_admin; no table access for ems_app, grafana_reader or
-- ems_customer_api)
--   analytics.site_reports              one row per (site, type, period)  (A73)
--   analytics.site_report_versions      immutable PDF versions, 60-day expiry each (A78-A80)
--   analytics.site_report_files         PDF bytes of a version (EMS DB file storage, as migration 309; A77)
--   analytics.site_report_attempts      every generation attempt (A72)
--
-- FUNCTIONS (SECURITY DEFINER, pinned search_path)
--   customer-facing reads, EXECUTE to ems_customer_api (where it exists) and
--   ems_app; read-only, site-scoped (A5, A107):
--     analytics.list_portal_site_reports, analytics.list_portal_site_report_versions,
--     analytics.get_portal_site_report_file, analytics.get_portal_site_report_schedule
--   WiseWatts Admin management, EXECUTE to ems_app only, each re-checking an
--   active ADMIN with GLOBAL scope and site access (A6, A107, A111):
--     request_site_report_generation, request_site_report_regeneration,
--     retry_site_report, delete_site_report, restore_site_report,
--     permanently_delete_site_report, list_site_reports_admin,
--     list_site_report_attempts_admin
--   report worker, EXECUTE to ems_app only (A91):
--     schedule_due_site_reports, claim_site_report_attempt,
--     extend_site_report_lease, defer_site_report_attempt,
--     complete_site_report_attempt, fail_site_report_attempt,
--     purge_site_reports, site_report_read_identity_problem
--
-- STATUS (A6, status set): an ACTIVE report shows Pending (an attempt waits),
-- Processing (an attempt runs), Failed (the latest attempt failed) or
-- Generated (a validated version exists; optional "Incomplete data" label).
-- Publication inserts the version, its file and the latest pointer in one
-- transaction, only while the worker holds the lease (A74-A76).
--
-- RETENTION (A78, A81-A87): each version expires 60 days after it was
-- generated. Delete moves the whole report to the recycle bin; each version is
-- then purged at the earlier of deletion + 7 days and its own expiry; restore
-- (within 7 days) never extends expiry. A WiseWatts Admin may permanently
-- delete a report ONLY while it is in the recycle bin, with explicit
-- confirmation (A111); the function refuses any other report.
--
-- Staging/test only (A106). Rollback:
-- postgres/maintenance/328_329_site_reports_rollback.sql.
-- ============================================================================

DO $pre$
BEGIN
    IF to_regclass('analytics.site_report_profiles') IS NULL
       OR to_regprocedure('analytics.site_report_require_staff(bigint, uuid)') IS NULL THEN
        RAISE EXCEPTION 'Migration 329 precondition failed: migration 328 objects are missing.';
    END IF;
    IF to_regclass('analytics.site_reports') IS NOT NULL THEN
        RAISE EXCEPTION 'Migration 329 precondition failed: analytics.site_reports already exists.';
    END IF;
END;
$pre$;


-- ----------------------------------------------------------------------------
-- 1. Tables.
-- ----------------------------------------------------------------------------

CREATE TABLE analytics.site_reports
(
    id                     UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    organization_id        UUID        NOT NULL REFERENCES metadata.organizations (id),
    site_id                UUID        NOT NULL REFERENCES analytics.site_report_profiles (site_id) ON DELETE CASCADE,
    report_type            TEXT        NOT NULL,
    period_start_date      DATE        NOT NULL,
    period_end_date        DATE        NOT NULL,
    comparison_start_date  DATE        NOT NULL,
    comparison_end_date    DATE        NOT NULL,
    latest_version_id      UUID,
    state                  TEXT        NOT NULL DEFAULT 'ACTIVE',
    deleted_at             TIMESTAMPTZ,
    deleted_by             BIGINT      REFERENCES admin.portal_users (portal_user_id),
    purged_at              TIMESTAMPTZ,
    created_at             TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    CONSTRAINT site_reports_type_chk CHECK (report_type IN ('WEEKLY', 'MONTHLY')),
    CONSTRAINT site_reports_state_chk CHECK (state IN ('ACTIVE', 'DELETED', 'PURGED')),
    CONSTRAINT site_reports_deleted_chk CHECK ((state = 'DELETED') <= (deleted_at IS NOT NULL)),
    CONSTRAINT site_reports_period_chk CHECK (
        period_end_date >= period_start_date AND comparison_end_date = period_start_date - 1
        AND (report_type <> 'WEEKLY' OR (extract(isodow FROM period_start_date) = 7
                                         AND period_end_date = period_start_date + 6
                                         AND comparison_start_date = period_start_date - 7))
        AND (report_type <> 'MONTHLY' OR (extract(day FROM period_start_date) = 1
                                          AND period_end_date = (period_start_date + INTERVAL '1 month' - INTERVAL '1 day')::date
                                          AND comparison_start_date = (period_start_date - INTERVAL '1 month')::date))),
    CONSTRAINT site_reports_unique UNIQUE (site_id, report_type, period_start_date)
);
CREATE INDEX site_reports_site_period_idx ON analytics.site_reports (site_id, period_start_date DESC);

CREATE TABLE analytics.site_report_versions
(
    id                         UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    report_id                  UUID        NOT NULL REFERENCES analytics.site_reports (id) ON DELETE CASCADE,
    version_no                 INTEGER     NOT NULL,
    generated_at               TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    generated_by               BIGINT      REFERENCES admin.portal_users (portal_user_id),
    automation_portal_user_id  BIGINT      REFERENCES admin.portal_users (portal_user_id),
    trigger                    TEXT        NOT NULL,
    expires_at                 TIMESTAMPTZ NOT NULL,
    purge_at                   TIMESTAMPTZ,
    state                      TEXT        NOT NULL DEFAULT 'AVAILABLE',
    incomplete_data            BOOLEAN     NOT NULL,
    comparison_incomplete      BOOLEAN     NOT NULL,
    coverage                   JSONB       NOT NULL,
    settings_snapshot          JSONB       NOT NULL,
    engine_version             TEXT        NOT NULL,
    file_name                  TEXT        NOT NULL,
    file_size_bytes            BIGINT      NOT NULL,
    sha256                     TEXT        NOT NULL,
    page_count                 INTEGER     NOT NULL,
    CONSTRAINT site_report_versions_state_chk CHECK (state IN ('AVAILABLE', 'EXPIRED', 'PURGED')),
    CONSTRAINT site_report_versions_expiry_chk CHECK (expires_at > generated_at),
    CONSTRAINT site_report_versions_sha_chk CHECK (sha256 ~ '^[0-9a-f]{64}$'),
    CONSTRAINT site_report_versions_unique UNIQUE (report_id, version_no)
);
ALTER TABLE analytics.site_reports
    ADD CONSTRAINT site_reports_latest_version_fk FOREIGN KEY (latest_version_id)
    REFERENCES analytics.site_report_versions (id) DEFERRABLE INITIALLY DEFERRED;

CREATE TABLE analytics.site_report_files
(
    version_id  UUID  PRIMARY KEY REFERENCES analytics.site_report_versions (id) ON DELETE CASCADE,
    content     BYTEA NOT NULL,
    CONSTRAINT site_report_files_pdf_chk CHECK (substring(content FROM 1 FOR 5) = '\x255044462d'::bytea)
);

CREATE TABLE analytics.site_report_attempts
(
    id                            UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    report_id                     UUID        NOT NULL REFERENCES analytics.site_reports (id) ON DELETE CASCADE,
    trigger                       TEXT        NOT NULL,
    identity_kind                 TEXT        NOT NULL,
    status                        TEXT        NOT NULL DEFAULT 'PENDING',
    not_before                    TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    retry_no                      INTEGER     NOT NULL DEFAULT 0,
    retry_of                      UUID        REFERENCES analytics.site_report_attempts (id) ON DELETE SET NULL,
    requested_by                  BIGINT      REFERENCES admin.portal_users (portal_user_id),
    read_identity_portal_user_id  BIGINT      REFERENCES admin.portal_users (portal_user_id),
    worker_id                     TEXT,
    lease_expires_at              TIMESTAMPTZ,
    created_at                    TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    started_at                    TIMESTAMPTZ,
    finished_at                   TIMESTAMPTZ,
    wait_message                  TEXT,
    error_code                    TEXT,
    error_message                 TEXT,
    version_id                    UUID        REFERENCES analytics.site_report_versions (id) ON DELETE SET NULL,
    CONSTRAINT site_report_attempts_trigger_chk
        CHECK (trigger IN ('AUTOMATIC', 'MANUAL', 'HISTORICAL', 'REGENERATE', 'RETRY_AUTO', 'RETRY_MANUAL')),
    CONSTRAINT site_report_attempts_identity_chk CHECK (identity_kind IN ('AUTOMATION', 'USER')),
    CONSTRAINT site_report_attempts_status_chk CHECK (status IN ('PENDING', 'PROCESSING', 'SUCCEEDED', 'FAILED', 'CANCELLED')),
    CONSTRAINT site_report_attempts_retry_chk CHECK (retry_no BETWEEN 0 AND 3),
    CONSTRAINT site_report_attempts_error_chk CHECK (char_length(error_message) <= 500),
    CONSTRAINT site_report_attempts_user_chk CHECK (identity_kind = 'AUTOMATION' OR requested_by IS NOT NULL)
);
CREATE UNIQUE INDEX site_report_attempts_one_active_idx
    ON analytics.site_report_attempts (report_id) WHERE status IN ('PENDING', 'PROCESSING');
CREATE INDEX site_report_attempts_due_idx
    ON analytics.site_report_attempts (not_before) WHERE status IN ('PENDING', 'PROCESSING');
CREATE INDEX site_report_attempts_report_idx ON analytics.site_report_attempts (report_id, created_at DESC);

DO $owner$
DECLARE
    v_table TEXT;
BEGIN
    FOREACH v_table IN ARRAY ARRAY['analytics.site_reports', 'analytics.site_report_versions',
                                   'analytics.site_report_files', 'analytics.site_report_attempts'] LOOP
        EXECUTE format('ALTER TABLE %s OWNER TO ems_admin', v_table);
        EXECUTE format('REVOKE ALL ON %s FROM PUBLIC, ems_app, grafana_reader', v_table);
        IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'ems_customer_api') THEN
            EXECUTE format('REVOKE ALL ON %s FROM ems_customer_api', v_table);
        END IF;
    END LOOP;
END;
$owner$;

COMMENT ON TABLE analytics.site_reports IS
'Migration 329 (Create report, ADR-025): one weekly or monthly report per site and period (A73). state ACTIVE / DELETED (recycle bin) / PURGED (tombstone after permanent deletion). latest_version_id: the most recent published version.';
COMMENT ON TABLE analytics.site_report_versions IS
'Migration 329: an immutable, validated PDF version (A79, A80). expires_at = generated_at + 60 days, never changed (A78, A86). purge_at: set while the report is in the recycle bin = least(expires_at, deleted_at + 7 days) (A85).';
COMMENT ON TABLE analytics.site_report_attempts IS
'Migration 329: every generation attempt with trigger, read identity, status, retry number, reason and resulting version (A72). At most one PENDING/PROCESSING attempt per report.';


-- ----------------------------------------------------------------------------
-- 2. Helpers.
-- ----------------------------------------------------------------------------

-- Display status of a report (Pending / Processing / Failed / Generated).
CREATE OR REPLACE FUNCTION analytics.site_report_display_status(p_report_id UUID)
RETURNS TEXT
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path TO pg_catalog, analytics
AS $function$
    SELECT CASE
        WHEN EXISTS (SELECT 1 FROM analytics.site_report_attempts WHERE report_id = p_report_id AND status = 'PROCESSING') THEN 'PROCESSING'
        WHEN EXISTS (SELECT 1 FROM analytics.site_report_attempts WHERE report_id = p_report_id AND status = 'PENDING') THEN 'PENDING'
        WHEN (SELECT status FROM analytics.site_report_attempts WHERE report_id = p_report_id AND status <> 'CANCELLED'
              ORDER BY created_at DESC, id DESC LIMIT 1) = 'FAILED' THEN 'FAILED'
        WHEN (SELECT latest_version_id FROM analytics.site_reports WHERE id = p_report_id) IS NOT NULL THEN 'GENERATED'
        ELSE 'PENDING'
    END;
$function$;

-- Retry delay after the n-th automatic retry (A68): 15, 30, 60 minutes.
CREATE OR REPLACE FUNCTION analytics.site_report_retry_delay(p_retry_no INTEGER)
RETURNS INTERVAL
LANGUAGE sql
IMMUTABLE
SET search_path TO pg_catalog
AS $function$
    SELECT CASE p_retry_no WHEN 1 THEN INTERVAL '15 minutes' WHEN 2 THEN INTERVAL '30 minutes'
                           WHEN 3 THEN INTERVAL '60 minutes' ELSE NULL END;
$function$;

-- Marks an attempt FAILED and, when retryable and fewer than 3 retries were
-- used, queues the next automatic retry (A68).
CREATE OR REPLACE FUNCTION analytics.site_report_fail_attempt(
    p_attempt_id UUID, p_code TEXT, p_message TEXT, p_retryable BOOLEAN
)
RETURNS VOID
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path TO pg_catalog, analytics
AS $function$
DECLARE
    v_attempt analytics.site_report_attempts%ROWTYPE;
BEGIN
    UPDATE analytics.site_report_attempts
    SET status = 'FAILED', finished_at = clock_timestamp(), error_code = left(p_code, 100),
        error_message = left(p_message, 500), worker_id = NULL, lease_expires_at = NULL, wait_message = NULL
    WHERE id = p_attempt_id
    RETURNING * INTO v_attempt;
    IF p_retryable AND v_attempt.retry_no < 3
       AND (SELECT state FROM analytics.site_reports WHERE id = v_attempt.report_id) = 'ACTIVE' THEN
        INSERT INTO analytics.site_report_attempts
            (report_id, trigger, identity_kind, status, not_before, retry_no, retry_of, requested_by)
        VALUES (v_attempt.report_id, 'RETRY_AUTO', v_attempt.identity_kind, 'PENDING',
                clock_timestamp() + analytics.site_report_retry_delay(v_attempt.retry_no + 1),
                v_attempt.retry_no + 1, v_attempt.id, v_attempt.requested_by);
    END IF;
END;
$function$;

-- Creates the report row for (site, type, period) if missing, or reactivates
-- a PURGED tombstone; computes and checks the period. Returns the report id.
CREATE OR REPLACE FUNCTION analytics.site_report_ensure(p_site_id UUID, p_report_type TEXT, p_period_start DATE)
RETURNS UUID
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path TO pg_catalog, analytics
AS $function$
DECLARE
    v_id UUID;
    v_state TEXT;
    v_end DATE;
    v_cmp_start DATE;
BEGIN
    IF p_report_type = 'WEEKLY' THEN
        IF extract(isodow FROM p_period_start) <> 7 THEN
            RAISE EXCEPTION 'site_report_invalid_period: a weekly period starts on a Sunday' USING ERRCODE = '22023';
        END IF;
        v_end := p_period_start + 6;
        v_cmp_start := p_period_start - 7;
    ELSIF p_report_type = 'MONTHLY' THEN
        IF extract(day FROM p_period_start) <> 1 THEN
            RAISE EXCEPTION 'site_report_invalid_period: a monthly period starts on the 1st' USING ERRCODE = '22023';
        END IF;
        v_end := (p_period_start + INTERVAL '1 month' - INTERVAL '1 day')::date;
        v_cmp_start := (p_period_start - INTERVAL '1 month')::date;
    ELSE
        RAISE EXCEPTION 'site_report_invalid_type' USING ERRCODE = '22023';
    END IF;
    SELECT id, state INTO v_id, v_state FROM analytics.site_reports
    WHERE site_id = p_site_id AND report_type = p_report_type AND period_start_date = p_period_start
    FOR UPDATE;
    IF v_id IS NULL THEN
        INSERT INTO analytics.site_reports (organization_id, site_id, report_type, period_start_date, period_end_date,
                                            comparison_start_date, comparison_end_date)
        SELECT p.organization_id, p_site_id, p_report_type, p_period_start, v_end, v_cmp_start, p_period_start - 1
        FROM analytics.site_report_profiles AS p WHERE p.site_id = p_site_id
        RETURNING id INTO v_id;
        IF v_id IS NULL THEN
            RAISE EXCEPTION 'site_report_not_enrolled' USING ERRCODE = 'P0002';
        END IF;
    ELSIF v_state = 'PURGED' THEN
        UPDATE analytics.site_reports
        SET state = 'ACTIVE', deleted_at = NULL, deleted_by = NULL, purged_at = NULL, latest_version_id = NULL
        WHERE id = v_id;
    END IF;
    RETURN v_id;
END;
$function$;

-- Why an attempt's read identity may not read (NULL = it may): automatic
-- attempts use the profile's automation account (A88-A90, A108); manual ones
-- the requesting WiseWatts Admin.
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


-- ----------------------------------------------------------------------------
-- 3. Customer-facing reads (all profiles with site access; read-only; A5).
-- ----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION analytics.list_portal_site_reports(
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

CREATE OR REPLACE FUNCTION analytics.list_portal_site_report_versions(p_portal_user_id BIGINT, p_report_id UUID)
RETURNS TABLE (
    version_id UUID, version_no INTEGER, generated_at TIMESTAMPTZ, trigger TEXT, generated_by_staff BOOLEAN,
    expires_at TIMESTAMPTZ, state TEXT, incomplete_data BOOLEAN, comparison_incomplete BOOLEAN,
    coverage JSONB, settings_snapshot JSONB, file_name TEXT, file_size_bytes BIGINT, page_count INTEGER
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path TO pg_catalog, analytics, admin
AS $function$
    SELECT v.id, v.version_no, v.generated_at, v.trigger, (v.generated_by IS NOT NULL), v.expires_at, v.state,
           v.incomplete_data, v.comparison_incomplete, v.coverage, v.settings_snapshot, v.file_name,
           v.file_size_bytes, v.page_count
    FROM analytics.site_report_versions AS v
    JOIN analytics.site_reports AS r ON r.id = v.report_id
    WHERE v.report_id = p_report_id
      AND r.state = 'ACTIVE'
      AND v.state <> 'PURGED'
      AND admin.portal_user_can_access_site(p_portal_user_id, r.site_id)
    ORDER BY v.version_no DESC;
$function$;

-- The PDF of an AVAILABLE version of an ACTIVE report the user can access;
-- no row otherwise (access re-checked at download time).
CREATE OR REPLACE FUNCTION analytics.get_portal_site_report_file(p_portal_user_id BIGINT, p_version_id UUID)
RETURNS TABLE (file_name TEXT, content BYTEA, sha256 TEXT)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path TO pg_catalog, analytics, admin
AS $function$
    SELECT v.file_name, f.content, v.sha256
    FROM analytics.site_report_versions AS v
    JOIN analytics.site_report_files AS f ON f.version_id = v.id
    JOIN analytics.site_reports AS r ON r.id = v.report_id
    WHERE v.id = p_version_id
      AND v.state = 'AVAILABLE'
      AND v.expires_at > clock_timestamp()
      AND r.state = 'ACTIVE'
      AND admin.portal_user_can_access_site(p_portal_user_id, r.site_id);
$function$;

-- Whether the site is enrolled and its automatic schedules' state (read-only).
CREATE OR REPLACE FUNCTION analytics.get_portal_site_report_schedule(p_portal_user_id BIGINT, p_site_id UUID)
RETURNS TABLE (enrolled BOOLEAN, weekly_enabled BOOLEAN, monthly_enabled BOOLEAN, site_timezone TEXT)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path TO pg_catalog, analytics, admin, metadata
AS $function$
    SELECT (p.site_id IS NOT NULL), COALESCE(p.weekly_enabled, FALSE), COALESCE(p.monthly_enabled, FALSE),
           COALESCE(NULLIF(s.timezone, ''), 'UTC')
    FROM metadata.sites AS s
    LEFT JOIN analytics.site_report_profiles AS p ON p.site_id = s.id
    WHERE s.id = p_site_id AND admin.portal_user_can_access_site(p_portal_user_id, p_site_id);
$function$;


-- ----------------------------------------------------------------------------
-- 4. WiseWatts Admin management (Administration App; A6, A107, A111).
-- ----------------------------------------------------------------------------

-- Manual or historical generation of a period that has no report yet (A63,
-- A71, A73). Refused when the period has not ended in the site timezone.
CREATE OR REPLACE FUNCTION analytics.request_site_report_generation(
    p_portal_user_id BIGINT, p_site_id UUID, p_report_type TEXT, p_period_start DATE
)
RETURNS TABLE (report_id UUID, attempt_id UUID)
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path TO pg_catalog, analytics, admin
AS $function$
DECLARE
    v_org UUID;
    v_tz TEXT;
    v_report analytics.site_reports%ROWTYPE;
    v_report_id UUID;
    v_attempt UUID;
    v_trigger TEXT;
BEGIN
    SELECT r.organization_id, r.site_timezone INTO v_org, v_tz
    FROM analytics.site_report_require_staff(p_portal_user_id, p_site_id) AS r;
    SELECT * INTO v_report FROM analytics.site_reports
    WHERE site_id = p_site_id AND report_type = p_report_type AND period_start_date = p_period_start;
    IF FOUND AND v_report.state = 'ACTIVE' THEN
        RAISE EXCEPTION 'site_report_exists' USING ERRCODE = '23505';
    ELSIF FOUND AND v_report.state = 'DELETED' THEN
        RAISE EXCEPTION 'site_report_in_recycle_bin' USING ERRCODE = '23505';
    END IF;
    v_report_id := analytics.site_report_ensure(p_site_id, p_report_type, p_period_start);
    SELECT * INTO v_report FROM analytics.site_reports WHERE id = v_report_id;
    IF (v_report.period_end_date + 1)::timestamp AT TIME ZONE v_tz > clock_timestamp() THEN
        RAISE EXCEPTION 'site_report_period_not_ended' USING ERRCODE = '22023';
    END IF;
    v_trigger := CASE WHEN (v_report.period_end_date + 1)::timestamp AT TIME ZONE v_tz
                           < clock_timestamp() - INTERVAL '12 hours' THEN 'HISTORICAL' ELSE 'MANUAL' END;
    INSERT INTO analytics.site_report_attempts (report_id, trigger, identity_kind, requested_by)
    VALUES (v_report_id, v_trigger, 'USER', p_portal_user_id)
    RETURNING id INTO v_attempt;
    PERFORM analytics.site_report_audit(p_portal_user_id, v_org, p_site_id, 'SITE_REPORT_GENERATE', 'SITE_REPORT',
                                        v_report_id, '{}'::jsonb,
                                        jsonb_build_object('report_type', p_report_type, 'period_start', p_period_start,
                                                           'trigger', v_trigger, 'attempt_id', v_attempt));
    RETURN QUERY SELECT v_report_id, v_attempt;
END;
$function$;

CREATE OR REPLACE FUNCTION analytics.site_report_manage_target(p_portal_user_id BIGINT, p_report_id UUID,
                                                               OUT report analytics.site_reports)
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path TO pg_catalog, analytics
AS $function$
BEGIN
    SELECT * INTO report FROM analytics.site_reports WHERE id = p_report_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'site_report_not_found' USING ERRCODE = 'P0002';
    END IF;
    PERFORM analytics.site_report_require_staff(p_portal_user_id, report.site_id);
END;
$function$;

CREATE OR REPLACE FUNCTION analytics.request_site_report_regeneration(p_portal_user_id BIGINT, p_report_id UUID)
RETURNS UUID
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path TO pg_catalog, analytics
AS $function$
DECLARE
    v_report analytics.site_reports;
    v_attempt UUID;
BEGIN
    v_report := analytics.site_report_manage_target(p_portal_user_id, p_report_id);
    IF v_report.state <> 'ACTIVE' THEN
        RAISE EXCEPTION 'site_report_not_active' USING ERRCODE = '22023';
    END IF;
    IF EXISTS (SELECT 1 FROM analytics.site_report_attempts WHERE report_id = p_report_id AND status IN ('PENDING', 'PROCESSING')) THEN
        RAISE EXCEPTION 'site_report_attempt_active' USING ERRCODE = '55000';
    END IF;
    INSERT INTO analytics.site_report_attempts (report_id, trigger, identity_kind, requested_by)
    VALUES (p_report_id, 'REGENERATE', 'USER', p_portal_user_id)
    RETURNING id INTO v_attempt;
    PERFORM analytics.site_report_audit(p_portal_user_id, v_report.organization_id, v_report.site_id,
                                        'SITE_REPORT_REGENERATE', 'SITE_REPORT', p_report_id,
                                        jsonb_build_object('latest_version_id', v_report.latest_version_id),
                                        jsonb_build_object('attempt_id', v_attempt));
    RETURN v_attempt;
END;
$function$;

CREATE OR REPLACE FUNCTION analytics.retry_site_report(p_portal_user_id BIGINT, p_report_id UUID)
RETURNS UUID
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path TO pg_catalog, analytics
AS $function$
DECLARE
    v_report analytics.site_reports;
    v_attempt UUID;
BEGIN
    v_report := analytics.site_report_manage_target(p_portal_user_id, p_report_id);
    IF v_report.state <> 'ACTIVE' OR analytics.site_report_display_status(p_report_id) <> 'FAILED' THEN
        RAISE EXCEPTION 'site_report_not_failed' USING ERRCODE = '22023';
    END IF;
    INSERT INTO analytics.site_report_attempts (report_id, trigger, identity_kind, requested_by)
    VALUES (p_report_id, 'RETRY_MANUAL', 'USER', p_portal_user_id)
    RETURNING id INTO v_attempt;
    PERFORM analytics.site_report_audit(p_portal_user_id, v_report.organization_id, v_report.site_id,
                                        'SITE_REPORT_RETRY', 'SITE_REPORT', p_report_id, '{}'::jsonb,
                                        jsonb_build_object('attempt_id', v_attempt));
    RETURN v_attempt;
END;
$function$;

-- Delete: the whole report moves to the recycle bin (A81-A83, A85).
CREATE OR REPLACE FUNCTION analytics.delete_site_report(p_portal_user_id BIGINT, p_report_id UUID)
RETURNS TIMESTAMPTZ
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path TO pg_catalog, analytics
AS $function$
DECLARE
    v_report analytics.site_reports;
    v_now TIMESTAMPTZ := clock_timestamp();
BEGIN
    v_report := analytics.site_report_manage_target(p_portal_user_id, p_report_id);
    IF v_report.state <> 'ACTIVE' THEN
        RAISE EXCEPTION 'site_report_not_active' USING ERRCODE = '22023';
    END IF;
    IF EXISTS (SELECT 1 FROM analytics.site_report_attempts WHERE report_id = p_report_id AND status = 'PROCESSING') THEN
        RAISE EXCEPTION 'site_report_processing' USING ERRCODE = '55000';
    END IF;
    UPDATE analytics.site_report_attempts
    SET status = 'CANCELLED', finished_at = v_now, error_code = 'cancelled_by_delete',
        error_message = 'Cancelled because the report was deleted.'
    WHERE report_id = p_report_id AND status = 'PENDING';
    UPDATE analytics.site_reports SET state = 'DELETED', deleted_at = v_now, deleted_by = p_portal_user_id
    WHERE id = p_report_id;
    UPDATE analytics.site_report_versions
    SET purge_at = LEAST(expires_at, v_now + INTERVAL '7 days')
    WHERE report_id = p_report_id AND state <> 'PURGED';
    PERFORM analytics.site_report_audit(p_portal_user_id, v_report.organization_id, v_report.site_id,
                                        'SITE_REPORT_DELETE', 'SITE_REPORT', p_report_id,
                                        jsonb_build_object('state', 'ACTIVE'),
                                        jsonb_build_object('state', 'DELETED', 'restore_until', v_now + INTERVAL '7 days'));
    RETURN v_now + INTERVAL '7 days';
END;
$function$;

-- Restore within 7 days of deletion; expiry is never extended (A84, A86).
CREATE OR REPLACE FUNCTION analytics.restore_site_report(p_portal_user_id BIGINT, p_report_id UUID)
RETURNS BOOLEAN
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path TO pg_catalog, analytics
AS $function$
DECLARE
    v_report analytics.site_reports;
BEGIN
    v_report := analytics.site_report_manage_target(p_portal_user_id, p_report_id);
    IF v_report.state <> 'DELETED' OR v_report.deleted_at + INTERVAL '7 days' <= clock_timestamp() THEN
        RAISE EXCEPTION 'site_report_not_restorable' USING ERRCODE = '22023';
    END IF;
    UPDATE analytics.site_reports SET state = 'ACTIVE', deleted_at = NULL, deleted_by = NULL WHERE id = p_report_id;
    UPDATE analytics.site_report_versions SET purge_at = NULL WHERE report_id = p_report_id AND state <> 'PURGED';
    PERFORM analytics.site_report_audit(p_portal_user_id, v_report.organization_id, v_report.site_id,
                                        'SITE_REPORT_RESTORE', 'SITE_REPORT', p_report_id,
                                        jsonb_build_object('state', 'DELETED', 'deleted_at', v_report.deleted_at),
                                        jsonb_build_object('state', 'ACTIVE'));
    RETURN TRUE;
END;
$function$;

-- Permanent deletion: ONLY a report already in the recycle bin, with
-- explicit confirmation (A111). Never available for an ACTIVE report.
CREATE OR REPLACE FUNCTION analytics.permanently_delete_site_report(
    p_portal_user_id BIGINT, p_report_id UUID, p_confirmed BOOLEAN
)
RETURNS BOOLEAN
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path TO pg_catalog, analytics
AS $function$
DECLARE
    v_report analytics.site_reports;
    v_versions INTEGER;
BEGIN
    v_report := analytics.site_report_manage_target(p_portal_user_id, p_report_id);
    IF v_report.state <> 'DELETED' THEN
        RAISE EXCEPTION 'site_report_not_in_recycle_bin' USING ERRCODE = '22023';
    END IF;
    IF p_confirmed IS NOT TRUE THEN
        RAISE EXCEPTION 'site_report_confirmation_required' USING ERRCODE = '22023';
    END IF;
    DELETE FROM analytics.site_report_files AS f USING analytics.site_report_versions AS v
    WHERE f.version_id = v.id AND v.report_id = p_report_id;
    UPDATE analytics.site_report_versions SET state = 'PURGED', purge_at = NULL
    WHERE report_id = p_report_id AND state <> 'PURGED';
    GET DIAGNOSTICS v_versions = ROW_COUNT;
    UPDATE analytics.site_reports SET state = 'PURGED', purged_at = clock_timestamp(), latest_version_id = NULL
    WHERE id = p_report_id;
    PERFORM analytics.site_report_audit(p_portal_user_id, v_report.organization_id, v_report.site_id,
                                        'SITE_REPORT_PURGE', 'SITE_REPORT', p_report_id,
                                        jsonb_build_object('state', 'DELETED', 'deleted_at', v_report.deleted_at),
                                        jsonb_build_object('state', 'PURGED', 'mode', 'MANUAL', 'versions_purged', v_versions));
    RETURN TRUE;
END;
$function$;

CREATE OR REPLACE FUNCTION analytics.list_site_reports_admin(p_portal_user_id BIGINT, p_site_id UUID, p_state TEXT)
RETURNS TABLE (
    report_id UUID, report_type TEXT, period_start_date DATE, period_end_date DATE, comparison_start_date DATE,
    comparison_end_date DATE, state TEXT, status TEXT, status_reason TEXT, deleted_at TIMESTAMPTZ,
    deleted_by_username TEXT, restore_until TIMESTAMPTZ, latest_version_id UUID, latest_version_no INTEGER,
    generated_at TIMESTAMPTZ, expires_at TIMESTAMPTZ, download_version_id UUID, incomplete_data BOOLEAN,
    comparison_incomplete BOOLEAN, version_count INTEGER, next_purge_at TIMESTAMPTZ
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO pg_catalog, analytics, admin
AS $function$
BEGIN
    PERFORM analytics.site_report_require_staff(p_portal_user_id, p_site_id);
    RETURN QUERY
    SELECT r.id, r.report_type, r.period_start_date, r.period_end_date, r.comparison_start_date, r.comparison_end_date,
           r.state, analytics.site_report_display_status(r.id),
           (SELECT COALESCE(a.wait_message, a.error_message) FROM analytics.site_report_attempts AS a
            WHERE a.report_id = r.id AND a.status <> 'CANCELLED' ORDER BY a.created_at DESC, a.id DESC LIMIT 1),
           r.deleted_at, du.username, r.deleted_at + INTERVAL '7 days',
           lv.id, lv.version_no, lv.generated_at, lv.expires_at,
           (SELECT v.id FROM analytics.site_report_versions AS v WHERE v.report_id = r.id AND v.state = 'AVAILABLE'
            ORDER BY v.version_no DESC LIMIT 1),
           lv.incomplete_data, lv.comparison_incomplete,
           (SELECT count(*)::int FROM analytics.site_report_versions AS v WHERE v.report_id = r.id AND v.state <> 'PURGED'),
           (SELECT min(v.purge_at) FROM analytics.site_report_versions AS v WHERE v.report_id = r.id AND v.state <> 'PURGED')
    FROM analytics.site_reports AS r
    LEFT JOIN analytics.site_report_versions AS lv ON lv.id = r.latest_version_id
    LEFT JOIN admin.portal_users AS du ON du.portal_user_id = r.deleted_by
    WHERE r.site_id = p_site_id AND r.state = COALESCE(p_state, 'ACTIVE')
    ORDER BY r.period_end_date DESC, r.report_type;
END;
$function$;

CREATE OR REPLACE FUNCTION analytics.list_site_report_attempts_admin(p_portal_user_id BIGINT, p_report_id UUID)
RETURNS TABLE (
    attempt_id UUID, trigger TEXT, identity_kind TEXT, status TEXT, retry_no INTEGER, requested_by_username TEXT,
    read_identity_username TEXT, created_at TIMESTAMPTZ, not_before TIMESTAMPTZ, started_at TIMESTAMPTZ,
    finished_at TIMESTAMPTZ, wait_message TEXT, error_code TEXT, error_message TEXT, version_no INTEGER
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO pg_catalog, analytics, admin
AS $function$
DECLARE
    v_site UUID;
BEGIN
    SELECT site_id INTO v_site FROM analytics.site_reports WHERE id = p_report_id;
    IF v_site IS NULL THEN
        RAISE EXCEPTION 'site_report_not_found' USING ERRCODE = 'P0002';
    END IF;
    PERFORM analytics.site_report_require_staff(p_portal_user_id, v_site);
    RETURN QUERY
    SELECT a.id, a.trigger, a.identity_kind, a.status, a.retry_no, ru.username, iu.username, a.created_at,
           a.not_before, a.started_at, a.finished_at, a.wait_message, a.error_code, a.error_message, v.version_no
    FROM analytics.site_report_attempts AS a
    LEFT JOIN admin.portal_users AS ru ON ru.portal_user_id = a.requested_by
    LEFT JOIN admin.portal_users AS iu ON iu.portal_user_id = a.read_identity_portal_user_id
    LEFT JOIN analytics.site_report_versions AS v ON v.id = a.version_id
    WHERE a.report_id = p_report_id
    ORDER BY a.created_at DESC, a.id DESC;
END;
$function$;

-- Staff version list including the settings snapshot and coverage (also for
-- reports in the recycle bin).
CREATE OR REPLACE FUNCTION analytics.list_site_report_versions_admin(p_portal_user_id BIGINT, p_report_id UUID)
RETURNS TABLE (
    version_id UUID, version_no INTEGER, generated_at TIMESTAMPTZ, trigger TEXT, generated_by_username TEXT,
    automation_username TEXT, expires_at TIMESTAMPTZ, purge_at TIMESTAMPTZ, state TEXT, incomplete_data BOOLEAN,
    comparison_incomplete BOOLEAN, coverage JSONB, settings_snapshot JSONB, file_name TEXT, file_size_bytes BIGINT,
    page_count INTEGER, sha256 TEXT
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO pg_catalog, analytics, admin
AS $function$
DECLARE
    v_site UUID;
BEGIN
    SELECT site_id INTO v_site FROM analytics.site_reports WHERE id = p_report_id;
    IF v_site IS NULL THEN
        RAISE EXCEPTION 'site_report_not_found' USING ERRCODE = 'P0002';
    END IF;
    PERFORM analytics.site_report_require_staff(p_portal_user_id, v_site);
    RETURN QUERY
    SELECT v.id, v.version_no, v.generated_at, v.trigger, gu.username, au.username, v.expires_at, v.purge_at, v.state,
           v.incomplete_data, v.comparison_incomplete, v.coverage, v.settings_snapshot, v.file_name, v.file_size_bytes,
           v.page_count, v.sha256
    FROM analytics.site_report_versions AS v
    LEFT JOIN admin.portal_users AS gu ON gu.portal_user_id = v.generated_by
    LEFT JOIN admin.portal_users AS au ON au.portal_user_id = v.automation_portal_user_id
    WHERE v.report_id = p_report_id
    ORDER BY v.version_no DESC;
END;
$function$;


-- ----------------------------------------------------------------------------
-- 5. Report worker.
-- ----------------------------------------------------------------------------

-- Creates the AUTOMATIC report and attempt of the latest closed week / month
-- of every enrolled site whose schedule is on, when no report exists for the
-- period and the period's first-attempt time (end + 6 h) is after the
-- schedule's latest resume (no back-fill, A61, A64, A70). Idempotent.
CREATE OR REPLACE FUNCTION analytics.schedule_due_site_reports(p_now TIMESTAMPTZ)
RETURNS INTEGER
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path TO pg_catalog, analytics, metadata
AS $function$
DECLARE
    v_profile RECORD;
    v_type TEXT;
    v_today DATE;
    v_start DATE;
    v_end_instant TIMESTAMPTZ;
    v_first TIMESTAMPTZ;
    v_report UUID;
    v_created INTEGER := 0;
BEGIN
    FOR v_profile IN
        SELECT p.*, COALESCE(NULLIF(s.timezone, ''), 'UTC') AS tz
        FROM analytics.site_report_profiles AS p JOIN metadata.sites AS s ON s.id = p.site_id
    LOOP
        v_today := (p_now AT TIME ZONE v_profile.tz)::date;
        FOREACH v_type IN ARRAY ARRAY['WEEKLY', 'MONTHLY'] LOOP
            CONTINUE WHEN (v_type = 'WEEKLY' AND NOT v_profile.weekly_enabled)
                       OR (v_type = 'MONTHLY' AND NOT v_profile.monthly_enabled);
            IF v_type = 'WEEKLY' THEN
                v_start := v_today - extract(dow FROM v_today)::int - 7;
                v_end_instant := (v_start + 7)::timestamp AT TIME ZONE v_profile.tz;
            ELSE
                v_start := (date_trunc('month', v_today) - INTERVAL '1 month')::date;
                v_end_instant := date_trunc('month', v_today)::date::timestamp AT TIME ZONE v_profile.tz;
            END IF;
            v_first := v_end_instant + INTERVAL '6 hours';
            CONTINUE WHEN v_first > p_now;
            CONTINUE WHEN v_first <= (CASE WHEN v_type = 'WEEKLY' THEN v_profile.weekly_resumed_at
                                           ELSE v_profile.monthly_resumed_at END);
            CONTINUE WHEN EXISTS (SELECT 1 FROM analytics.site_reports
                                  WHERE site_id = v_profile.site_id AND report_type = v_type AND period_start_date = v_start);
            v_report := analytics.site_report_ensure(v_profile.site_id, v_type, v_start);
            INSERT INTO analytics.site_report_attempts (report_id, trigger, identity_kind, not_before)
            VALUES (v_report, 'AUTOMATIC', 'AUTOMATION', v_first);
            v_created := v_created + 1;
        END LOOP;
    END LOOP;
    RETURN v_created;
END;
$function$;

-- Claims the oldest due attempt. A PROCESSING attempt whose lease lapsed
-- (worker restart) is FAILED (worker_interrupted) and retried per A68 first.
CREATE OR REPLACE FUNCTION analytics.claim_site_report_attempt(p_worker_id TEXT, p_lease INTERVAL)
RETURNS TABLE (
    attempt_id UUID, report_id UUID, trigger TEXT, identity_kind TEXT, retry_no INTEGER, requested_by BIGINT,
    read_identity_portal_user_id BIGINT, site_id UUID, organization_id UUID, site_name TEXT, site_timezone TEXT,
    report_type TEXT, period_start_date DATE, period_end_date DATE, comparison_start_date DATE,
    comparison_end_date DATE, attempt_created_at TIMESTAMPTZ
)
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path TO pg_catalog, analytics, metadata
AS $function$
DECLARE
    v_lapsed RECORD;
    v_id UUID;
    v_identity BIGINT;
BEGIN
    FOR v_lapsed IN
        SELECT a.id FROM analytics.site_report_attempts AS a
        WHERE a.status = 'PROCESSING' AND a.lease_expires_at < clock_timestamp()
        FOR UPDATE SKIP LOCKED
    LOOP
        PERFORM analytics.site_report_fail_attempt(v_lapsed.id, 'worker_interrupted',
                                                   'Generation was interrupted and will be retried.', TRUE);
    END LOOP;

    SELECT a.id INTO v_id
    FROM analytics.site_report_attempts AS a
    JOIN analytics.site_reports AS r ON r.id = a.report_id
    WHERE a.status = 'PENDING' AND a.not_before <= clock_timestamp() AND r.state = 'ACTIVE'
    ORDER BY a.not_before, a.created_at, a.id
    LIMIT 1
    FOR UPDATE OF a SKIP LOCKED;
    IF v_id IS NULL THEN
        RETURN;
    END IF;
    SELECT CASE WHEN a.identity_kind = 'AUTOMATION' THEN p.automation_portal_user_id ELSE a.requested_by END
    INTO v_identity
    FROM analytics.site_report_attempts AS a
    JOIN analytics.site_reports AS r ON r.id = a.report_id
    JOIN analytics.site_report_profiles AS p ON p.site_id = r.site_id
    WHERE a.id = v_id;
    UPDATE analytics.site_report_attempts AS a
    SET status = 'PROCESSING', worker_id = p_worker_id, lease_expires_at = clock_timestamp() + p_lease,
        started_at = COALESCE(a.started_at, clock_timestamp()), read_identity_portal_user_id = v_identity
    WHERE a.id = v_id;
    RETURN QUERY
    SELECT a.id, a.report_id, a.trigger, a.identity_kind, a.retry_no, a.requested_by, a.read_identity_portal_user_id,
           r.site_id, r.organization_id, s.name, COALESCE(NULLIF(s.timezone, ''), 'UTC'), r.report_type,
           r.period_start_date, r.period_end_date, r.comparison_start_date, r.comparison_end_date, a.created_at
    FROM analytics.site_report_attempts AS a
    JOIN analytics.site_reports AS r ON r.id = a.report_id
    JOIN metadata.sites AS s ON s.id = r.site_id
    WHERE a.id = v_id;
END;
$function$;

CREATE OR REPLACE FUNCTION analytics.extend_site_report_lease(p_attempt_id UUID, p_worker_id TEXT, p_lease INTERVAL)
RETURNS BOOLEAN
LANGUAGE sql
VOLATILE
SECURITY DEFINER
SET search_path TO pg_catalog, analytics
AS $function$
    WITH updated AS (
        UPDATE analytics.site_report_attempts
        SET lease_expires_at = clock_timestamp() + p_lease
        WHERE id = p_attempt_id AND status = 'PROCESSING' AND worker_id = p_worker_id
        RETURNING 1
    )
    SELECT EXISTS (SELECT 1 FROM updated);
$function$;

-- Data still arriving (A65): back to PENDING until p_not_before, with the
-- reason shown in history; the same attempt continues.
CREATE OR REPLACE FUNCTION analytics.defer_site_report_attempt(
    p_attempt_id UUID, p_worker_id TEXT, p_not_before TIMESTAMPTZ, p_message TEXT
)
RETURNS BOOLEAN
LANGUAGE sql
VOLATILE
SECURITY DEFINER
SET search_path TO pg_catalog, analytics
AS $function$
    WITH updated AS (
        UPDATE analytics.site_report_attempts
        SET status = 'PENDING', not_before = p_not_before, wait_message = left(p_message, 500),
            worker_id = NULL, lease_expires_at = NULL
        WHERE id = p_attempt_id AND status = 'PROCESSING' AND worker_id = p_worker_id
        RETURNING 1
    )
    SELECT EXISTS (SELECT 1 FROM updated);
$function$;

-- Publishes a validated PDF: version + file + latest pointer + attempt
-- SUCCEEDED in one transaction, only while this worker holds the lease and the
-- report is ACTIVE (A74-A76, A78-A80). Returns the version id, NULL when not
-- published.
CREATE OR REPLACE FUNCTION analytics.complete_site_report_attempt(
    p_attempt_id UUID, p_worker_id TEXT, p_file_name TEXT, p_content BYTEA, p_sha256 TEXT, p_page_count INTEGER,
    p_incomplete_data BOOLEAN, p_comparison_incomplete BOOLEAN, p_coverage JSONB, p_settings_snapshot JSONB,
    p_engine_version TEXT, p_retention INTERVAL
)
RETURNS UUID
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path TO pg_catalog, analytics
AS $function$
DECLARE
    v_attempt analytics.site_report_attempts%ROWTYPE;
    v_report analytics.site_reports%ROWTYPE;
    v_version UUID;
    v_no INTEGER;
    v_now TIMESTAMPTZ := clock_timestamp();
BEGIN
    SELECT * INTO v_attempt FROM analytics.site_report_attempts
    WHERE id = p_attempt_id AND status = 'PROCESSING' AND worker_id = p_worker_id
    FOR UPDATE;
    IF NOT FOUND THEN
        RETURN NULL;
    END IF;
    SELECT * INTO v_report FROM analytics.site_reports WHERE id = v_attempt.report_id FOR UPDATE;
    IF v_report.state <> 'ACTIVE' THEN
        PERFORM analytics.site_report_fail_attempt(p_attempt_id, 'report_not_active',
                                                   'The report was deleted while it was being generated.', FALSE);
        RETURN NULL;
    END IF;
    IF p_sha256 IS DISTINCT FROM encode(sha256(p_content), 'hex') THEN
        RAISE EXCEPTION 'site_report_checksum_mismatch' USING ERRCODE = '22023';
    END IF;
    SELECT COALESCE(max(version_no), 0) + 1 INTO v_no FROM analytics.site_report_versions WHERE report_id = v_report.id;
    INSERT INTO analytics.site_report_versions
        (report_id, version_no, generated_at, generated_by, automation_portal_user_id, trigger, expires_at,
         incomplete_data, comparison_incomplete, coverage, settings_snapshot, engine_version, file_name,
         file_size_bytes, sha256, page_count)
    VALUES (v_report.id, v_no, v_now,
            CASE WHEN v_attempt.identity_kind = 'USER' THEN v_attempt.requested_by END,
            CASE WHEN v_attempt.identity_kind = 'AUTOMATION' THEN v_attempt.read_identity_portal_user_id END,
            v_attempt.trigger, v_now + p_retention, p_incomplete_data, p_comparison_incomplete, p_coverage,
            p_settings_snapshot, p_engine_version, p_file_name, octet_length(p_content), p_sha256, p_page_count)
    RETURNING id INTO v_version;
    INSERT INTO analytics.site_report_files (version_id, content) VALUES (v_version, p_content);
    UPDATE analytics.site_reports SET latest_version_id = v_version WHERE id = v_report.id;
    UPDATE analytics.site_report_attempts
    SET status = 'SUCCEEDED', finished_at = v_now, version_id = v_version, worker_id = NULL, lease_expires_at = NULL,
        wait_message = NULL, error_code = NULL, error_message = NULL
    WHERE id = p_attempt_id;
    RETURN v_version;
END;
$function$;

CREATE OR REPLACE FUNCTION analytics.fail_site_report_attempt(
    p_attempt_id UUID, p_worker_id TEXT, p_code TEXT, p_message TEXT, p_retryable BOOLEAN
)
RETURNS BOOLEAN
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path TO pg_catalog, analytics
AS $function$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM analytics.site_report_attempts
                   WHERE id = p_attempt_id AND status = 'PROCESSING' AND worker_id = p_worker_id) THEN
        RETURN FALSE;
    END IF;
    PERFORM analytics.site_report_fail_attempt(p_attempt_id, p_code, p_message, p_retryable);
    RETURN TRUE;
END;
$function$;

-- Retention (A78, A85-A87): versions past expires_at -> EXPIRED (file
-- deleted); versions of reports in the recycle bin past purge_at -> PURGED;
-- a deleted report with nothing left (or 7 days after deletion) -> PURGED.
CREATE OR REPLACE FUNCTION analytics.purge_site_reports(p_now TIMESTAMPTZ)
RETURNS TABLE (expired_versions INTEGER, purged_versions INTEGER, purged_reports INTEGER)
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path TO pg_catalog, analytics
AS $function$
DECLARE
    v_expired INTEGER;
    v_purged INTEGER;
    v_reports INTEGER := 0;
    v_report RECORD;
BEGIN
    WITH purged AS (
        UPDATE analytics.site_report_versions AS v
        SET state = 'PURGED'
        FROM analytics.site_reports AS r
        WHERE r.id = v.report_id AND r.state = 'DELETED' AND v.state <> 'PURGED' AND v.purge_at <= p_now
        RETURNING v.id
    )
    DELETE FROM analytics.site_report_files AS f USING purged WHERE f.version_id = purged.id;
    GET DIAGNOSTICS v_purged = ROW_COUNT;

    WITH expired AS (
        UPDATE analytics.site_report_versions
        SET state = 'EXPIRED'
        WHERE state = 'AVAILABLE' AND expires_at <= p_now
        RETURNING id
    )
    DELETE FROM analytics.site_report_files AS f USING expired WHERE f.version_id = expired.id;
    GET DIAGNOSTICS v_expired = ROW_COUNT;

    FOR v_report IN
        SELECT r.* FROM analytics.site_reports AS r
        WHERE r.state = 'DELETED'
          AND (r.deleted_at + INTERVAL '7 days' <= p_now
               OR (EXISTS (SELECT 1 FROM analytics.site_report_versions AS v WHERE v.report_id = r.id)
                   AND NOT EXISTS (SELECT 1 FROM analytics.site_report_versions AS v
                                   WHERE v.report_id = r.id AND v.state <> 'PURGED')))
        FOR UPDATE
    LOOP
        DELETE FROM analytics.site_report_files AS f USING analytics.site_report_versions AS v
        WHERE f.version_id = v.id AND v.report_id = v_report.id;
        UPDATE analytics.site_report_versions SET state = 'PURGED' WHERE report_id = v_report.id AND state <> 'PURGED';
        UPDATE analytics.site_reports SET state = 'PURGED', purged_at = p_now, latest_version_id = NULL
        WHERE id = v_report.id;
        PERFORM analytics.site_report_audit(NULL, v_report.organization_id, v_report.site_id, 'SITE_REPORT_PURGE',
                                            'SITE_REPORT', v_report.id,
                                            jsonb_build_object('state', 'DELETED', 'deleted_at', v_report.deleted_at),
                                            jsonb_build_object('state', 'PURGED', 'mode', 'AUTOMATIC'));
        v_reports := v_reports + 1;
    END LOOP;
    RETURN QUERY SELECT v_expired, v_purged, v_reports;
END;
$function$;


-- ----------------------------------------------------------------------------
-- 6. Ownership and grants.
-- ----------------------------------------------------------------------------

DO $grants$
DECLARE
    v_sig TEXT;
    v_portal TEXT[] := ARRAY[
        'analytics.list_portal_site_reports(bigint, uuid, text, integer)',
        'analytics.list_portal_site_report_versions(bigint, uuid)',
        'analytics.get_portal_site_report_file(bigint, uuid)',
        'analytics.get_portal_site_report_schedule(bigint, uuid)'
    ];
    v_app_only TEXT[] := ARRAY[
        'analytics.request_site_report_generation(bigint, uuid, text, date)',
        'analytics.request_site_report_regeneration(bigint, uuid)',
        'analytics.retry_site_report(bigint, uuid)',
        'analytics.delete_site_report(bigint, uuid)',
        'analytics.restore_site_report(bigint, uuid)',
        'analytics.permanently_delete_site_report(bigint, uuid, boolean)',
        'analytics.list_site_reports_admin(bigint, uuid, text)',
        'analytics.list_site_report_attempts_admin(bigint, uuid)',
        'analytics.list_site_report_versions_admin(bigint, uuid)',
        'analytics.schedule_due_site_reports(timestamptz)',
        'analytics.claim_site_report_attempt(text, interval)',
        'analytics.extend_site_report_lease(uuid, text, interval)',
        'analytics.defer_site_report_attempt(uuid, text, timestamptz, text)',
        'analytics.complete_site_report_attempt(uuid, text, text, bytea, text, integer, boolean, boolean, jsonb, jsonb, text, interval)',
        'analytics.fail_site_report_attempt(uuid, text, text, text, boolean)',
        'analytics.purge_site_reports(timestamptz)',
        'analytics.site_report_read_identity_problem(uuid)'
    ];
    v_internal TEXT[] := ARRAY[
        'analytics.site_report_display_status(uuid)',
        'analytics.site_report_retry_delay(integer)',
        'analytics.site_report_fail_attempt(uuid, text, text, boolean)',
        'analytics.site_report_ensure(uuid, text, date)',
        'analytics.site_report_manage_target(bigint, uuid)'
    ];
BEGIN
    FOREACH v_sig IN ARRAY v_portal || v_app_only || v_internal LOOP
        EXECUTE format('ALTER FUNCTION %s OWNER TO ems_admin', v_sig);
        EXECUTE format('REVOKE ALL ON FUNCTION %s FROM PUBLIC', v_sig);
    END LOOP;
    FOREACH v_sig IN ARRAY v_portal || v_app_only LOOP
        EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO ems_app', v_sig);
    END LOOP;
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'ems_customer_api') THEN
        FOREACH v_sig IN ARRAY v_portal LOOP
            EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO ems_customer_api', v_sig);
        END LOOP;
    END IF;
END;
$grants$;


-- ----------------------------------------------------------------------------
-- 7. Postconditions.
-- ----------------------------------------------------------------------------

DO $post$
DECLARE
    v_sig TEXT;
    v_role TEXT;
    v_table TEXT;
BEGIN
    FOR v_sig IN
        SELECT p.oid::regprocedure::text FROM pg_proc AS p JOIN pg_namespace AS n ON n.oid = p.pronamespace
        WHERE n.nspname = 'analytics' AND p.proname ~ 'site_report' AND p.proname <> 'site_report_retry_delay'
          AND p.proname <> 'site_report_setting_problem'
    LOOP
        IF NOT EXISTS (
            SELECT 1 FROM pg_proc AS p JOIN pg_roles AS r ON r.oid = p.proowner
            WHERE p.oid = v_sig::regprocedure AND p.prosecdef AND r.rolname = 'ems_admin' AND p.proconfig IS NOT NULL
        ) THEN
            RAISE EXCEPTION 'Migration 329 postcondition failed: % is not SECURITY DEFINER / ems_admin / pinned search_path.', v_sig;
        END IF;
        IF has_function_privilege('public', v_sig, 'EXECUTE') THEN
            RAISE EXCEPTION 'Migration 329 postcondition failed: % is executable by PUBLIC.', v_sig;
        END IF;
        FOREACH v_role IN ARRAY ARRAY['grafana_reader', 'ems_readonly', 'ems_investigator'] LOOP
            IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = v_role) AND has_function_privilege(v_role, v_sig, 'EXECUTE') THEN
                RAISE EXCEPTION 'Migration 329 postcondition failed: % is executable by %.', v_sig, v_role;
            END IF;
        END LOOP;
        -- The customer API may execute ONLY the four read-only portal functions (A107).
        IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'ems_customer_api')
           AND has_function_privilege('ems_customer_api', v_sig, 'EXECUTE')
           AND v_sig NOT IN ('analytics.list_portal_site_reports(bigint,uuid,text,integer)',
                             'analytics.list_portal_site_report_versions(bigint,uuid)',
                             'analytics.get_portal_site_report_file(bigint,uuid)',
                             'analytics.get_portal_site_report_schedule(bigint,uuid)') THEN
            RAISE EXCEPTION 'Migration 329 postcondition failed: ems_customer_api can execute %.', v_sig;
        END IF;
    END LOOP;
    FOREACH v_table IN ARRAY ARRAY['analytics.site_reports', 'analytics.site_report_versions',
                                   'analytics.site_report_files', 'analytics.site_report_attempts'] LOOP
        FOREACH v_role IN ARRAY ARRAY['ems_app', 'grafana_reader', 'ems_customer_api'] LOOP
            IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = v_role) AND has_table_privilege(v_role, v_table, 'SELECT') THEN
                RAISE EXCEPTION 'Migration 329 postcondition failed: % is directly readable by %.', v_table, v_role;
            END IF;
        END LOOP;
    END LOOP;
    RAISE NOTICE 'Migration 329: all postconditions passed (site reports, versions, files, attempts; customer API read-only).';
END;
$post$;
