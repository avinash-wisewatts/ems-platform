-- ============================================================================
-- Migration 314
-- Server-side customer sessions: revocable sign-in (ADR-023)
--
-- Until now the customer session was only a signed cookie: POST /auth/logout
-- cleared it in the browser, but a copy of the cookie taken before sign-out
-- stayed valid until it expired (EMS_APP_SESSION_MAX_AGE_SECONDS, sliding),
-- on the customer API and on live-telemetry's customer WebSockets alike.
--
-- This migration adds the server-side half. At sign-in the customer API
-- stores the SHA-256 of a random session token (the token itself travels
-- only inside the signed, HttpOnly cookie; the database never holds it);
-- every authenticated request and every open customer live stream checks
-- that the session still exists, is not revoked and has not expired, and
-- that its account is still active.
--
--   admin.portal_sessions             one row per sign-in (token hash, user,
--                                     idle and absolute expiry, revocation)
--   admin.create_portal_session       sign-in; only for an active account;
--                                     also purges that user's dead rows
--   admin.touch_portal_session        per-request check + sliding idle
--                                     expiry (written at most once a minute)
--   admin.get_portal_session_user     read-only check (live-telemetry)
--   admin.revoke_portal_session       sign-out
--   trigger portal_users_revoke_sessions
--                                     deactivating an account or changing
--                                     its password revokes every open
--                                     session of it, so re-activation never
--                                     revives an old cookie
--
-- Grants: create / touch / revoke to ems_customer_api (migration 313);
-- get_portal_session_user to ems_app (live-telemetry's login). Nothing to
-- PUBLIC. The table itself is granted to no role: the SELECT that
-- ems_investigator's default privileges (staging) give a new admin table is
-- revoked. No existing function, grant, table, job or row changes.
--
-- Scope: staging and test only (postgres/migration_environment_scope.csv),
-- like migration 313: production has no customer API.
--
-- Rollback (previous application image first, or every customer is signed
-- out until it is running):
--   DROP TRIGGER portal_users_revoke_sessions ON admin.portal_users;
--   DROP FUNCTION admin.revoke_portal_sessions_on_account_change(),
--       admin.create_portal_session(BIGINT, BYTEA, TEXT, INTEGER, INTEGER),
--       admin.touch_portal_session(BYTEA, TEXT, INTEGER),
--       admin.get_portal_session_user(BYTEA, TEXT),
--       admin.revoke_portal_session(BYTEA, TEXT);
--   DROP TABLE admin.portal_sessions;
-- ============================================================================

DO $pre$
BEGIN
    IF to_regclass('admin.portal_users') IS NULL THEN
        RAISE EXCEPTION 'Migration 314 precondition failed: admin.portal_users is missing';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'ems_customer_api') THEN
        RAISE EXCEPTION 'Migration 314 precondition failed: role ems_customer_api (migration 313) is missing';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'ems_app') THEN
        RAISE EXCEPTION 'Migration 314 precondition failed: role ems_app is missing';
    END IF;
END
$pre$;


CREATE TABLE IF NOT EXISTS admin.portal_sessions
(
    session_token_hash bytea
        PRIMARY KEY
        CHECK (octet_length(session_token_hash) = 32),

    portal_user_id bigint
        NOT NULL
        REFERENCES admin.portal_users (portal_user_id)
        ON DELETE CASCADE,

    audience text
        NOT NULL
        CHECK (audience IN ('CUSTOMER')),

    created_at timestamptz
        NOT NULL
        DEFAULT now(),

    last_seen_at timestamptz
        NOT NULL
        DEFAULT now(),

    idle_expires_at timestamptz
        NOT NULL,

    absolute_expires_at timestamptz
        NOT NULL,

    revoked_at timestamptz,

    revoked_reason text
        CHECK (revoked_reason IN ('LOGOUT', 'ACCOUNT_DEACTIVATED', 'PASSWORD_CHANGED')),

    CHECK ((revoked_at IS NULL) = (revoked_reason IS NULL)),
    CHECK (idle_expires_at <= absolute_expires_at)
);

CREATE INDEX IF NOT EXISTS idx_portal_sessions_user_open
    ON admin.portal_sessions (portal_user_id)
    WHERE revoked_at IS NULL;

ALTER TABLE admin.portal_sessions OWNER TO ems_admin;
REVOKE ALL ON TABLE admin.portal_sessions FROM PUBLIC;

-- Staging's read-only investigation role (ems_investigator) holds
-- ALTER DEFAULT PRIVILEGES ... IN SCHEMA admin GRANT SELECT ON TABLES, so
-- CREATE TABLE above granted it SELECT. Session rows are reached only
-- through the functions below; the postcondition requires no direct grant.
DO $investigator$
BEGIN
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'ems_investigator') THEN
        REVOKE ALL ON TABLE admin.portal_sessions FROM ems_investigator;
    END IF;
END
$investigator$;

COMMENT ON TABLE admin.portal_sessions IS
'ADR-023 / migration 314: server-side customer sessions. session_token_hash is the SHA-256 of the random token held in the signed session cookie (the token itself is never stored). A session is valid while not revoked, before idle_expires_at and absolute_expires_at, and while its account is active. Read and written only through the admin.*_portal_session SECURITY DEFINER functions.';


CREATE OR REPLACE FUNCTION admin.create_portal_session
(
    p_portal_user_id BIGINT,
    p_session_token_hash BYTEA,
    p_audience TEXT,
    p_idle_seconds INTEGER,
    p_absolute_seconds INTEGER
)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
VOLATILE
SET search_path TO pg_catalog, admin
AS $function$
BEGIN
    IF p_idle_seconds IS NULL OR p_idle_seconds NOT BETWEEN 300 AND 86400 THEN
        RAISE EXCEPTION 'idle session lifetime must be between 300 and 86400 seconds';
    END IF;
    IF p_absolute_seconds IS NULL OR p_absolute_seconds NOT BETWEEN p_idle_seconds AND 2592000 THEN
        RAISE EXCEPTION 'absolute session lifetime must be between the idle lifetime and 2592000 seconds';
    END IF;

    -- Keep the table small without a scheduled job: a user's revoked or
    -- expired sessions are removed when that user next signs in.
    DELETE FROM admin.portal_sessions AS s
    WHERE s.portal_user_id = p_portal_user_id
      AND (s.revoked_at IS NOT NULL
           OR s.idle_expires_at < now()
           OR s.absolute_expires_at < now());

    INSERT INTO admin.portal_sessions
        (session_token_hash, portal_user_id, audience, created_at, last_seen_at, idle_expires_at, absolute_expires_at)
    SELECT
        p_session_token_hash,
        u.portal_user_id,
        p_audience,
        now(),
        now(),
        now() + make_interval(secs => p_idle_seconds),
        now() + make_interval(secs => p_absolute_seconds)
    FROM admin.portal_users AS u
    WHERE u.portal_user_id = p_portal_user_id
      AND u.is_active = TRUE;

    RETURN FOUND;
END
$function$;


CREATE OR REPLACE FUNCTION admin.touch_portal_session
(
    p_session_token_hash BYTEA,
    p_audience TEXT,
    p_idle_seconds INTEGER
)
RETURNS BIGINT
LANGUAGE plpgsql
SECURITY DEFINER
VOLATILE
SET search_path TO pg_catalog, admin
AS $function$
DECLARE
    v_portal_user_id BIGINT;
    v_last_seen_at TIMESTAMPTZ;
BEGIN
    SELECT s.portal_user_id, s.last_seen_at
    INTO v_portal_user_id, v_last_seen_at
    FROM admin.portal_sessions AS s
    JOIN admin.portal_users AS u ON u.portal_user_id = s.portal_user_id
    WHERE s.session_token_hash = p_session_token_hash
      AND s.audience = p_audience
      AND s.revoked_at IS NULL
      AND s.idle_expires_at > now()
      AND s.absolute_expires_at > now()
      AND u.is_active = TRUE;

    IF v_portal_user_id IS NULL THEN
        RETURN NULL;
    END IF;

    -- Sliding idle expiry, as the signed cookie already slides; written at
    -- most once a minute per session, never past the absolute expiry.
    IF v_last_seen_at < now() - interval '60 seconds' THEN
        UPDATE admin.portal_sessions AS s
        SET last_seen_at = now(),
            idle_expires_at = LEAST(now() + make_interval(secs => GREATEST(p_idle_seconds, 300)), s.absolute_expires_at)
        WHERE s.session_token_hash = p_session_token_hash
          AND s.revoked_at IS NULL;
    END IF;

    RETURN v_portal_user_id;
END
$function$;


CREATE OR REPLACE FUNCTION admin.get_portal_session_user
(
    p_session_token_hash BYTEA,
    p_audience TEXT
)
RETURNS BIGINT
LANGUAGE SQL
SECURITY DEFINER
STABLE
SET search_path TO pg_catalog, admin
AS $function$
    SELECT s.portal_user_id
    FROM admin.portal_sessions AS s
    JOIN admin.portal_users AS u ON u.portal_user_id = s.portal_user_id
    WHERE s.session_token_hash = p_session_token_hash
      AND s.audience = p_audience
      AND s.revoked_at IS NULL
      AND s.idle_expires_at > now()
      AND s.absolute_expires_at > now()
      AND u.is_active = TRUE;
$function$;


CREATE OR REPLACE FUNCTION admin.revoke_portal_session
(
    p_session_token_hash BYTEA,
    p_reason TEXT
)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
VOLATILE
SET search_path TO pg_catalog, admin
AS $function$
BEGIN
    UPDATE admin.portal_sessions AS s
    SET revoked_at = now(),
        revoked_reason = p_reason
    WHERE s.session_token_hash = p_session_token_hash
      AND s.revoked_at IS NULL;

    RETURN FOUND;
END
$function$;


CREATE OR REPLACE FUNCTION admin.revoke_portal_sessions_on_account_change()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO pg_catalog, admin
AS $function$
BEGIN
    UPDATE admin.portal_sessions AS s
    SET revoked_at = now(),
        revoked_reason = CASE
            WHEN NOT NEW.is_active THEN 'ACCOUNT_DEACTIVATED'
            ELSE 'PASSWORD_CHANGED'
        END
    WHERE s.portal_user_id = NEW.portal_user_id
      AND s.revoked_at IS NULL;

    RETURN NULL;
END
$function$;

DROP TRIGGER IF EXISTS portal_users_revoke_sessions ON admin.portal_users;

CREATE TRIGGER portal_users_revoke_sessions
AFTER UPDATE OF is_active, password_hash
ON admin.portal_users
FOR EACH ROW
WHEN (
    (OLD.is_active AND NOT NEW.is_active)
    OR OLD.password_hash IS DISTINCT FROM NEW.password_hash
)
EXECUTE FUNCTION admin.revoke_portal_sessions_on_account_change();


ALTER FUNCTION admin.create_portal_session(BIGINT, BYTEA, TEXT, INTEGER, INTEGER) OWNER TO ems_admin;
ALTER FUNCTION admin.touch_portal_session(BYTEA, TEXT, INTEGER) OWNER TO ems_admin;
ALTER FUNCTION admin.get_portal_session_user(BYTEA, TEXT) OWNER TO ems_admin;
ALTER FUNCTION admin.revoke_portal_session(BYTEA, TEXT) OWNER TO ems_admin;
ALTER FUNCTION admin.revoke_portal_sessions_on_account_change() OWNER TO ems_admin;

REVOKE ALL ON FUNCTION admin.create_portal_session(BIGINT, BYTEA, TEXT, INTEGER, INTEGER) FROM PUBLIC;
REVOKE ALL ON FUNCTION admin.touch_portal_session(BYTEA, TEXT, INTEGER) FROM PUBLIC;
REVOKE ALL ON FUNCTION admin.get_portal_session_user(BYTEA, TEXT) FROM PUBLIC;
REVOKE ALL ON FUNCTION admin.revoke_portal_session(BYTEA, TEXT) FROM PUBLIC;
REVOKE ALL ON FUNCTION admin.revoke_portal_sessions_on_account_change() FROM PUBLIC;

GRANT EXECUTE ON FUNCTION admin.create_portal_session(BIGINT, BYTEA, TEXT, INTEGER, INTEGER) TO ems_customer_api;
GRANT EXECUTE ON FUNCTION admin.touch_portal_session(BYTEA, TEXT, INTEGER) TO ems_customer_api;
GRANT EXECUTE ON FUNCTION admin.revoke_portal_session(BYTEA, TEXT) TO ems_customer_api;
GRANT EXECUTE ON FUNCTION admin.get_portal_session_user(BYTEA, TEXT) TO ems_app;


DO $post$
DECLARE
    v_customer oid := (SELECT oid FROM pg_roles WHERE rolname = 'ems_customer_api');
BEGIN
    IF NOT has_function_privilege('ems_customer_api', 'admin.create_portal_session(bigint, bytea, text, integer, integer)', 'EXECUTE')
       OR NOT has_function_privilege('ems_customer_api', 'admin.touch_portal_session(bytea, text, integer)', 'EXECUTE')
       OR NOT has_function_privilege('ems_customer_api', 'admin.revoke_portal_session(bytea, text)', 'EXECUTE')
       OR NOT has_function_privilege('ems_app', 'admin.get_portal_session_user(bytea, text)', 'EXECUTE') THEN
        RAISE EXCEPTION 'Migration 314 postcondition failed: a session function grant is missing';
    END IF;

    IF has_function_privilege('ems_app', 'admin.create_portal_session(bigint, bytea, text, integer, integer)', 'EXECUTE')
       OR has_function_privilege('ems_app', 'admin.revoke_portal_session(bytea, text)', 'EXECUTE')
       OR has_function_privilege('ems_app', 'admin.touch_portal_session(bytea, text, integer)', 'EXECUTE') THEN
        RAISE EXCEPTION 'Migration 314 postcondition failed: ems_app can write customer sessions';
    END IF;

    IF EXISTS (
        SELECT 1
        FROM pg_class AS c
        CROSS JOIN LATERAL aclexplode(c.relacl) AS a
        WHERE c.oid = 'admin.portal_sessions'::regclass
          AND c.relacl IS NOT NULL
          AND a.grantee <> c.relowner
    ) THEN
        RAISE EXCEPTION 'Migration 314 postcondition failed: admin.portal_sessions is granted to a role';
    END IF;

    -- Migration 313's invariant still holds: the customer API reads no table.
    IF EXISTS (
        SELECT 1
        FROM pg_class AS c
        CROSS JOIN LATERAL aclexplode(c.relacl) AS a
        WHERE c.relacl IS NOT NULL
          AND a.grantee = v_customer
    ) THEN
        RAISE EXCEPTION 'Migration 314 postcondition failed: ems_customer_api has relation privileges';
    END IF;
END
$post$;
