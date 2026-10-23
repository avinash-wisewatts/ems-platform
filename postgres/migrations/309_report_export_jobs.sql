-- ============================================================================
-- Migration 309
-- Reports: site measurement export jobs (EMS Web App "Reports" tab).
--
-- The Reports tab exports every asset of a site for a time range as one ZIP
-- of per-asset CSV files. Small exports are generated in the request and
-- never touch these tables. Large exports are background jobs: the admin
-- portal process queues a job here, its in-process worker claims it, builds
-- the ZIP from the same portal-scoped Analytics reads the Analytics page
-- uses (keyed on the job owner's portal_user_id), and stores the ZIP here
-- until it expires.
--
-- Objects (all owned by ems_admin, no PUBLIC access):
--   analytics.report_export_jobs    one row per background export job
--   analytics.report_export_files   the generated ZIP of a COMPLETED job
--                                   (separate table so listing jobs never
--                                   reads file content)
--   SECURITY DEFINER functions, EXECUTE granted to ems_app only:
--     portal-scoped (keyed on the authenticated portal_user_id; a job is
--     visible only to its owner, and only while the owner can still access
--     the job's site -- admin.portal_user_can_access_site):
--       analytics.create_portal_report_export_job
--       analytics.list_portal_report_export_jobs
--       analytics.get_portal_report_export_job
--       analytics.retry_portal_report_export_job
--       analytics.get_portal_report_export_file
--     worker (the admin portal's own background worker):
--       analytics.claim_report_export_job
--       analytics.extend_report_export_lease
--       analytics.complete_report_export_job
--       analytics.fail_report_export_job
--       analytics.purge_report_exports
--
-- Status: QUEUED -> PROCESSING -> COMPLETED | FAILED; COMPLETED -> EXPIRED
-- when its file is purged after expires_at; FAILED -> QUEUED on retry. A
-- PROCESSING job whose lease lapsed (worker restarted mid-job) is claimed
-- again, at most 3 attempts in all, then FAILED (worker_interrupted).
--
-- No telemetry, metadata, configuration, job or Analytics read changes. No
-- TimescaleDB job is added: the admin portal worker purges expired files.
--
-- Rollback: DROP the ten functions, then DROP TABLE
-- analytics.report_export_files, analytics.report_export_jobs (nothing else
-- depends on them).
-- ============================================================================

DO $pre$
BEGIN
    IF to_regprocedure('admin.portal_user_can_access_site(bigint, uuid)') IS NULL THEN
        RAISE EXCEPTION 'Migration 309 precondition failed: admin.portal_user_can_access_site(bigint, uuid) is missing.';
    END IF;
    IF to_regclass('analytics.report_export_jobs') IS NOT NULL
       OR to_regclass('analytics.report_export_files') IS NOT NULL THEN
        RAISE EXCEPTION 'Migration 309 precondition failed: a migration 309 table already exists.';
    END IF;
END;
$pre$;


-- ----------------------------------------------------------------------------
-- 1. Tables.
-- ----------------------------------------------------------------------------

CREATE TABLE analytics.report_export_jobs
(
    id                   UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    portal_user_id       BIGINT      NOT NULL REFERENCES admin.portal_users (portal_user_id) ON DELETE CASCADE,
    site_id              UUID        NOT NULL REFERENCES metadata.sites (id) ON DELETE CASCADE,
    range_from           TIMESTAMPTZ NOT NULL,
    range_to             TIMESTAMPTZ NOT NULL,
    requested_resolution TEXT        NOT NULL,
    resolution           TEXT        NOT NULL,
    status               TEXT        NOT NULL DEFAULT 'QUEUED',
    attempts             INTEGER     NOT NULL DEFAULT 0,
    error_code           TEXT,
    error_message        TEXT,
    worker_id            TEXT,
    lease_expires_at     TIMESTAMPTZ,
    created_at           TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    started_at           TIMESTAMPTZ,
    completed_at         TIMESTAMPTZ,
    expires_at           TIMESTAMPTZ,
    file_name            TEXT,
    file_size_bytes      BIGINT,
    asset_count          INTEGER,
    row_count            BIGINT,
    CONSTRAINT report_export_jobs_range_chk CHECK (range_to > range_from),
    CONSTRAINT report_export_jobs_status_chk
        CHECK (status IN ('QUEUED', 'PROCESSING', 'COMPLETED', 'FAILED', 'EXPIRED')),
    CONSTRAINT report_export_jobs_resolution_chk
        CHECK (resolution IN ('1m', '15m', '30m', '1h', '1d')
               AND requested_resolution IN ('auto', '1m', '15m', '30m', '1h', '1d')),
    CONSTRAINT report_export_jobs_attempts_chk CHECK (attempts >= 0),
    CONSTRAINT report_export_jobs_error_length_chk CHECK (char_length(error_message) <= 500)
);
CREATE INDEX report_export_jobs_owner_created_idx
    ON analytics.report_export_jobs (portal_user_id, created_at DESC);
CREATE INDEX report_export_jobs_pending_idx
    ON analytics.report_export_jobs (created_at) WHERE status IN ('QUEUED', 'PROCESSING');
ALTER TABLE analytics.report_export_jobs OWNER TO ems_admin;
REVOKE ALL ON analytics.report_export_jobs FROM PUBLIC, ems_app, grafana_reader;
COMMENT ON TABLE analytics.report_export_jobs IS
'Migration 309 (Reports tab): background site measurement export jobs. Written and read only through the migration 309 SECURITY DEFINER functions (portal-scoped for the API, worker functions for the admin portal export worker). range_from inclusive, range_to exclusive (UTC); resolution is the resolved Analytics resolution. expires_at: when the COMPLETED file is purged (status EXPIRED).';

CREATE TABLE analytics.report_export_files
(
    job_id     UUID        PRIMARY KEY REFERENCES analytics.report_export_jobs (id) ON DELETE CASCADE,
    content    BYTEA       NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp()
);
ALTER TABLE analytics.report_export_files OWNER TO ems_admin;
REVOKE ALL ON analytics.report_export_files FROM PUBLIC, ems_app, grafana_reader;
COMMENT ON TABLE analytics.report_export_files IS
'Migration 309 (Reports tab): the generated ZIP of a COMPLETED analytics.report_export_jobs row. Deleted by analytics.purge_report_exports once the job expires.';


-- ----------------------------------------------------------------------------
-- 2. Portal-scoped functions (the /api/v1 report-export routes).
-- ----------------------------------------------------------------------------

-- Queues a job. No row when the site is not accessible (indistinguishable
-- from a missing site). SQLSTATE 54000 when the owner already has
-- p_max_active QUEUED / PROCESSING jobs.
CREATE OR REPLACE FUNCTION analytics.create_portal_report_export_job(
    p_portal_user_id       BIGINT,
    p_site_id              UUID,
    p_range_from           TIMESTAMPTZ,
    p_range_to             TIMESTAMPTZ,
    p_requested_resolution TEXT,
    p_resolution           TEXT,
    p_max_active           INTEGER
)
RETURNS SETOF analytics.report_export_jobs
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path TO pg_catalog, analytics, admin
AS $function$
DECLARE
    v_active INTEGER;
BEGIN
    IF NOT admin.portal_user_can_access_site(p_portal_user_id, p_site_id) THEN
        RETURN;
    END IF;

    -- One owner's concurrent creates serialise on this lock, so the active
    -- job limit cannot be raced past.
    PERFORM pg_advisory_xact_lock(hashtextextended('analytics.report_export_jobs:' || p_portal_user_id::TEXT, 0));
    SELECT count(*) INTO v_active
    FROM analytics.report_export_jobs
    WHERE portal_user_id = p_portal_user_id AND status IN ('QUEUED', 'PROCESSING');
    IF v_active >= p_max_active THEN
        RAISE EXCEPTION 'report_export_active_limit' USING ERRCODE = '54000';
    END IF;

    RETURN QUERY
    INSERT INTO analytics.report_export_jobs (
        portal_user_id, site_id, range_from, range_to, requested_resolution, resolution
    )
    VALUES (p_portal_user_id, p_site_id, p_range_from, p_range_to, p_requested_resolution, p_resolution)
    RETURNING *;
END;
$function$;

CREATE OR REPLACE FUNCTION analytics.list_portal_report_export_jobs(
    p_portal_user_id BIGINT,
    p_limit          INTEGER
)
RETURNS SETOF analytics.report_export_jobs
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path TO pg_catalog, analytics, admin
AS $function$
    SELECT j.*
    FROM analytics.report_export_jobs AS j
    WHERE j.portal_user_id = p_portal_user_id
      AND admin.portal_user_can_access_site(p_portal_user_id, j.site_id)
    ORDER BY j.created_at DESC, j.id
    LIMIT LEAST(GREATEST(COALESCE(p_limit, 50), 1), 200);
$function$;

CREATE OR REPLACE FUNCTION analytics.get_portal_report_export_job(
    p_portal_user_id BIGINT,
    p_job_id         UUID
)
RETURNS SETOF analytics.report_export_jobs
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path TO pg_catalog, analytics, admin
AS $function$
    SELECT j.*
    FROM analytics.report_export_jobs AS j
    WHERE j.id = p_job_id
      AND j.portal_user_id = p_portal_user_id
      AND admin.portal_user_can_access_site(p_portal_user_id, j.site_id);
$function$;

-- FAILED -> QUEUED (attempts and error reset). No row when the job is not
-- the caller's, its site is no longer accessible, or it is not FAILED.
CREATE OR REPLACE FUNCTION analytics.retry_portal_report_export_job(
    p_portal_user_id BIGINT,
    p_job_id         UUID
)
RETURNS SETOF analytics.report_export_jobs
LANGUAGE sql
VOLATILE
SECURITY DEFINER
SET search_path TO pg_catalog, analytics, admin
AS $function$
    UPDATE analytics.report_export_jobs AS j
    SET status = 'QUEUED', attempts = 0, error_code = NULL, error_message = NULL,
        worker_id = NULL, lease_expires_at = NULL, started_at = NULL, completed_at = NULL
    WHERE j.id = p_job_id
      AND j.portal_user_id = p_portal_user_id
      AND j.status = 'FAILED'
      AND admin.portal_user_can_access_site(p_portal_user_id, j.site_id)
    RETURNING j.*;
$function$;

-- The ZIP of a COMPLETED, unexpired job of the caller's. No row otherwise.
CREATE OR REPLACE FUNCTION analytics.get_portal_report_export_file(
    p_portal_user_id BIGINT,
    p_job_id         UUID
)
RETURNS TABLE (file_name TEXT, content BYTEA)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path TO pg_catalog, analytics, admin
AS $function$
    SELECT j.file_name, f.content
    FROM analytics.report_export_jobs AS j
    JOIN analytics.report_export_files AS f ON f.job_id = j.id
    WHERE j.id = p_job_id
      AND j.portal_user_id = p_portal_user_id
      AND j.status = 'COMPLETED'
      AND j.expires_at > clock_timestamp()
      AND admin.portal_user_can_access_site(p_portal_user_id, j.site_id);
$function$;


-- ----------------------------------------------------------------------------
-- 3. Worker functions (the admin portal's export worker).
-- ----------------------------------------------------------------------------

-- Claims the oldest QUEUED job, or a PROCESSING job whose lease lapsed.
-- A lapsed job that already used p_max_attempts is FAILED instead.
CREATE OR REPLACE FUNCTION analytics.claim_report_export_job(
    p_worker_id    TEXT,
    p_lease        INTERVAL,
    p_max_attempts INTEGER
)
RETURNS SETOF analytics.report_export_jobs
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path TO pg_catalog, analytics
AS $function$
DECLARE
    v_id UUID;
BEGIN
    UPDATE analytics.report_export_jobs
    SET status = 'FAILED', error_code = 'worker_interrupted',
        error_message = 'The export was interrupted. Retry it to run it again.',
        worker_id = NULL, lease_expires_at = NULL, completed_at = clock_timestamp()
    WHERE status = 'PROCESSING' AND lease_expires_at < clock_timestamp() AND attempts >= p_max_attempts;

    SELECT id INTO v_id
    FROM analytics.report_export_jobs
    WHERE status = 'QUEUED'
       OR (status = 'PROCESSING' AND lease_expires_at < clock_timestamp())
    ORDER BY created_at, id
    LIMIT 1
    FOR UPDATE SKIP LOCKED;

    IF v_id IS NULL THEN
        RETURN;
    END IF;

    RETURN QUERY
    UPDATE analytics.report_export_jobs
    SET status = 'PROCESSING', attempts = attempts + 1, worker_id = p_worker_id,
        lease_expires_at = clock_timestamp() + p_lease, started_at = clock_timestamp(),
        error_code = NULL, error_message = NULL
    WHERE id = v_id
    RETURNING *;
END;
$function$;

CREATE OR REPLACE FUNCTION analytics.extend_report_export_lease(
    p_job_id    UUID,
    p_worker_id TEXT,
    p_lease     INTERVAL
)
RETURNS BOOLEAN
LANGUAGE sql
VOLATILE
SECURITY DEFINER
SET search_path TO pg_catalog, analytics
AS $function$
    WITH updated AS (
        UPDATE analytics.report_export_jobs
        SET lease_expires_at = clock_timestamp() + p_lease
        WHERE id = p_job_id AND status = 'PROCESSING' AND worker_id = p_worker_id
        RETURNING 1
    )
    SELECT EXISTS (SELECT 1 FROM updated);
$function$;

-- Stores the ZIP and completes the job, only while this worker holds it.
CREATE OR REPLACE FUNCTION analytics.complete_report_export_job(
    p_job_id      UUID,
    p_worker_id   TEXT,
    p_file_name   TEXT,
    p_content     BYTEA,
    p_asset_count INTEGER,
    p_row_count   BIGINT,
    p_retention   INTERVAL
)
RETURNS BOOLEAN
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path TO pg_catalog, analytics
AS $function$
BEGIN
    UPDATE analytics.report_export_jobs
    SET status = 'COMPLETED', completed_at = clock_timestamp(),
        expires_at = clock_timestamp() + p_retention,
        file_name = p_file_name, file_size_bytes = octet_length(p_content),
        asset_count = p_asset_count, row_count = p_row_count,
        worker_id = NULL, lease_expires_at = NULL
    WHERE id = p_job_id AND status = 'PROCESSING' AND worker_id = p_worker_id;
    IF NOT FOUND THEN
        RETURN FALSE;
    END IF;
    INSERT INTO analytics.report_export_files (job_id, content)
    VALUES (p_job_id, p_content)
    ON CONFLICT (job_id) DO UPDATE SET content = EXCLUDED.content, created_at = clock_timestamp();
    RETURN TRUE;
END;
$function$;

CREATE OR REPLACE FUNCTION analytics.fail_report_export_job(
    p_job_id        UUID,
    p_worker_id     TEXT,
    p_error_code    TEXT,
    p_error_message TEXT
)
RETURNS BOOLEAN
LANGUAGE sql
VOLATILE
SECURITY DEFINER
SET search_path TO pg_catalog, analytics
AS $function$
    WITH updated AS (
        UPDATE analytics.report_export_jobs
        SET status = 'FAILED', completed_at = clock_timestamp(),
            error_code = left(p_error_code, 100), error_message = left(p_error_message, 500),
            worker_id = NULL, lease_expires_at = NULL
        WHERE id = p_job_id AND status = 'PROCESSING' AND worker_id = p_worker_id
        RETURNING 1
    )
    SELECT EXISTS (SELECT 1 FROM updated);
$function$;

-- Deletes the files of COMPLETED jobs past expires_at (status EXPIRED), and
-- every job row older than p_history.
CREATE OR REPLACE FUNCTION analytics.purge_report_exports(p_history INTERVAL)
RETURNS TABLE (expired_files INTEGER, deleted_jobs INTEGER)
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path TO pg_catalog, analytics
AS $function$
DECLARE
    v_expired INTEGER;
    v_deleted INTEGER;
BEGIN
    WITH expired AS (
        UPDATE analytics.report_export_jobs
        SET status = 'EXPIRED'
        WHERE status = 'COMPLETED' AND expires_at <= clock_timestamp()
        RETURNING id
    )
    DELETE FROM analytics.report_export_files AS f
    USING expired
    WHERE f.job_id = expired.id;
    GET DIAGNOSTICS v_expired = ROW_COUNT;

    DELETE FROM analytics.report_export_jobs
    WHERE created_at < clock_timestamp() - p_history
      AND status IN ('COMPLETED', 'FAILED', 'EXPIRED');
    GET DIAGNOSTICS v_deleted = ROW_COUNT;

    RETURN QUERY SELECT v_expired, v_deleted;
END;
$function$;


-- ----------------------------------------------------------------------------
-- 4. Ownership and grants: ems_app EXECUTE only.
-- ----------------------------------------------------------------------------

DO $grants$
DECLARE
    v_sig TEXT;
BEGIN
    FOREACH v_sig IN ARRAY ARRAY[
        'analytics.create_portal_report_export_job(bigint, uuid, timestamptz, timestamptz, text, text, integer)',
        'analytics.list_portal_report_export_jobs(bigint, integer)',
        'analytics.get_portal_report_export_job(bigint, uuid)',
        'analytics.retry_portal_report_export_job(bigint, uuid)',
        'analytics.get_portal_report_export_file(bigint, uuid)',
        'analytics.claim_report_export_job(text, interval, integer)',
        'analytics.extend_report_export_lease(uuid, text, interval)',
        'analytics.complete_report_export_job(uuid, text, text, bytea, integer, bigint, interval)',
        'analytics.fail_report_export_job(uuid, text, text, text)',
        'analytics.purge_report_exports(interval)'
    ] LOOP
        EXECUTE format('ALTER FUNCTION %s OWNER TO ems_admin', v_sig);
        EXECUTE format('REVOKE ALL ON FUNCTION %s FROM PUBLIC', v_sig);
        EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO ems_app', v_sig);
    END LOOP;
END;
$grants$;

COMMENT ON FUNCTION analytics.create_portal_report_export_job(BIGINT, UUID, TIMESTAMPTZ, TIMESTAMPTZ, TEXT, TEXT, INTEGER) IS
'Migration 309 (Reports tab): queues a background site export job for the portal user. No row when the site is not accessible to the user; SQLSTATE 54000 (report_export_active_limit) when the user already has p_max_active QUEUED/PROCESSING jobs.';
COMMENT ON FUNCTION analytics.get_portal_report_export_file(BIGINT, UUID) IS
'Migration 309 (Reports tab): the ZIP of a COMPLETED, unexpired export job owned by the portal user whose site the user can still access. No row otherwise.';
COMMENT ON FUNCTION analytics.claim_report_export_job(TEXT, INTERVAL, INTEGER) IS
'Migration 309 (Reports tab): admin portal export worker -- claims the oldest QUEUED job or a PROCESSING job whose lease lapsed (FOR UPDATE SKIP LOCKED); a lapsed job with p_max_attempts attempts is FAILED (worker_interrupted) instead.';
COMMENT ON FUNCTION analytics.purge_report_exports(INTERVAL) IS
'Migration 309 (Reports tab): deletes the files of COMPLETED jobs past expires_at (status EXPIRED) and job rows older than p_history.';


-- ----------------------------------------------------------------------------
-- 5. Postconditions.
-- ----------------------------------------------------------------------------

DO $post$
DECLARE
    v_sig TEXT;
BEGIN
    FOREACH v_sig IN ARRAY ARRAY[
        'analytics.create_portal_report_export_job(bigint, uuid, timestamptz, timestamptz, text, text, integer)',
        'analytics.list_portal_report_export_jobs(bigint, integer)',
        'analytics.get_portal_report_export_job(bigint, uuid)',
        'analytics.retry_portal_report_export_job(bigint, uuid)',
        'analytics.get_portal_report_export_file(bigint, uuid)',
        'analytics.claim_report_export_job(text, interval, integer)',
        'analytics.extend_report_export_lease(uuid, text, interval)',
        'analytics.complete_report_export_job(uuid, text, text, bytea, integer, bigint, interval)',
        'analytics.fail_report_export_job(uuid, text, text, text)',
        'analytics.purge_report_exports(interval)'
    ] LOOP
        IF NOT EXISTS (
            SELECT 1 FROM pg_proc AS p JOIN pg_roles AS r ON r.oid = p.proowner
            WHERE p.oid = v_sig::regprocedure
              AND p.prosecdef AND r.rolname = 'ems_admin' AND p.proconfig IS NOT NULL
        ) THEN
            RAISE EXCEPTION 'Migration 309 postcondition failed: % is not SECURITY DEFINER / ems_admin / pinned search_path.', v_sig;
        END IF;
        IF has_function_privilege('public', v_sig, 'EXECUTE')
           OR NOT has_function_privilege('ems_app', v_sig, 'EXECUTE') THEN
            RAISE EXCEPTION 'Migration 309 postcondition failed: % grants are not ems_app-only.', v_sig;
        END IF;
    END LOOP;

    IF has_table_privilege('ems_app', 'analytics.report_export_jobs', 'SELECT')
       OR has_table_privilege('ems_app', 'analytics.report_export_files', 'SELECT')
       OR has_table_privilege('grafana_reader', 'analytics.report_export_jobs', 'SELECT')
       OR has_table_privilege('grafana_reader', 'analytics.report_export_files', 'SELECT') THEN
        RAISE EXCEPTION 'Migration 309 postcondition failed: a report export table is directly readable.';
    END IF;

    RAISE NOTICE 'Migration 309: all postconditions passed (report export jobs and files; SECURITY DEFINER, ems_app-only).';
END;
$post$;
