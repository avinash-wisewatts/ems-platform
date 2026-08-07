BEGIN;

-- ============================================================================
-- Portal authentication identities
--
-- This table stores administrative portal users separately from PostgreSQL
-- database roles. A portal user represents a human identity. The FastAPI
-- service continues to connect to PostgreSQL using the restricted ems_app
-- database role.
--
-- Passwords must never be stored directly. password_hash contains an Argon2id
-- encoded hash generated and verified by the application.
-- ============================================================================

CREATE TABLE IF NOT EXISTS admin.portal_users
(
    portal_user_id bigint
        GENERATED ALWAYS AS IDENTITY
        PRIMARY KEY,

    username text
        NOT NULL,

    display_name text
        NOT NULL,

    email text,

    password_hash text
        NOT NULL,

    role_code text
        NOT NULL
        DEFAULT 'OPERATOR',

    is_active boolean
        NOT NULL
        DEFAULT true,

    failed_login_count integer
        NOT NULL
        DEFAULT 0,

    locked_until timestamptz,

    last_login_at timestamptz,

    password_changed_at timestamptz
        NOT NULL
        DEFAULT clock_timestamp(),

    created_at timestamptz
        NOT NULL
        DEFAULT clock_timestamp(),

    updated_at timestamptz
        NOT NULL
        DEFAULT clock_timestamp(),

    created_by text
        NOT NULL,

    CONSTRAINT portal_users_username_not_blank
        CHECK (btrim(username) <> ''),

    CONSTRAINT portal_users_display_name_not_blank
        CHECK (btrim(display_name) <> ''),

    CONSTRAINT portal_users_username_normalized
        CHECK (username = lower(btrim(username))),

    CONSTRAINT portal_users_role_code_valid
        CHECK (
            role_code IN (
                'SUPER_ADMIN',
                'OPERATOR',
                'VIEWER'
            )
        ),

    CONSTRAINT portal_users_failed_login_count_valid
        CHECK (failed_login_count >= 0),

    CONSTRAINT portal_users_email_not_blank
        CHECK (
            email IS NULL
            OR btrim(email) <> ''
        )
);

-- Username matching is case-insensitive at the boundary because usernames are
-- stored normalized to lowercase.
CREATE UNIQUE INDEX IF NOT EXISTS ux_portal_users_username
    ON admin.portal_users (username);

CREATE UNIQUE INDEX IF NOT EXISTS ux_portal_users_email
    ON admin.portal_users (lower(email))
    WHERE email IS NOT NULL;

COMMENT ON TABLE admin.portal_users IS
    'Human identities authorized to use the EMS administration portal.';

COMMENT ON COLUMN admin.portal_users.password_hash IS
    'Argon2id encoded password hash. Plaintext passwords must never be stored.';

COMMENT ON COLUMN admin.portal_users.role_code IS
    'Portal authorization role: SUPER_ADMIN, OPERATOR, or VIEWER.';

COMMENT ON COLUMN admin.portal_users.locked_until IS
    'Temporary authentication lockout expiration timestamp.';

-- ============================================================================
-- Authentication lookup
--
-- SECURITY DEFINER allows ems_app to request one authentication record without
-- receiving direct SELECT access to the portal_users table.
--
-- The function intentionally returns the password hash because FastAPI must
-- verify the submitted password with Argon2. It returns only one normalized
-- username match and exposes no list operation.
-- ============================================================================

CREATE OR REPLACE FUNCTION admin.get_portal_user_for_authentication
(
    p_username text
)
RETURNS TABLE
(
    portal_user_id bigint,
    username text,
    display_name text,
    password_hash text,
    role_code text,
    is_active boolean,
    failed_login_count integer,
    locked_until timestamptz
)
LANGUAGE sql
SECURITY DEFINER
STABLE
SET search_path TO pg_catalog, admin
AS $function$
    SELECT
        portal_user.portal_user_id,
        portal_user.username,
        portal_user.display_name,
        portal_user.password_hash,
        portal_user.role_code,
        portal_user.is_active,
        portal_user.failed_login_count,
        portal_user.locked_until
    FROM admin.portal_users AS portal_user
    WHERE portal_user.username =
        lower(btrim(p_username))
    LIMIT 1;
$function$;

-- ============================================================================
-- Successful-login recorder
-- ============================================================================

CREATE OR REPLACE FUNCTION admin.record_portal_login_success
(
    p_portal_user_id bigint
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO pg_catalog, admin
AS $function$
BEGIN
    UPDATE admin.portal_users AS portal_user
    SET
        failed_login_count = 0,
        locked_until = NULL,
        last_login_at = clock_timestamp(),
        updated_at = clock_timestamp()
    WHERE portal_user.portal_user_id = p_portal_user_id
      AND portal_user.is_active = true;

    IF NOT FOUND THEN
        RAISE EXCEPTION
            'Active portal user was not found.';
    END IF;
END;
$function$;

-- ============================================================================
-- Failed-login recorder
--
-- Five consecutive failed attempts cause a fifteen-minute lockout.
-- Successful authentication resets the counter through
-- record_portal_login_success().
-- ============================================================================

CREATE OR REPLACE FUNCTION admin.record_portal_login_failure
(
    p_portal_user_id bigint
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO pg_catalog, admin
AS $function$
BEGIN
    UPDATE admin.portal_users AS portal_user
    SET
        failed_login_count =
            portal_user.failed_login_count + 1,

        locked_until =
            CASE
                WHEN portal_user.failed_login_count + 1 >= 5
                THEN clock_timestamp() + interval '15 minutes'
                ELSE portal_user.locked_until
            END,

        updated_at = clock_timestamp()
    WHERE portal_user.portal_user_id = p_portal_user_id
      AND portal_user.is_active = true;

    -- Do not reveal whether a supplied username exists to the HTTP client.
    -- The application will always return the same generic login error.
END;
$function$;

-- ============================================================================
-- Permission boundary
-- ============================================================================

REVOKE ALL
ON TABLE admin.portal_users
FROM PUBLIC;

REVOKE ALL
ON TABLE admin.portal_users
FROM ems_app;

REVOKE ALL
ON SEQUENCE admin.portal_users_portal_user_id_seq
FROM PUBLIC;

REVOKE ALL
ON SEQUENCE admin.portal_users_portal_user_id_seq
FROM ems_app;

REVOKE ALL
ON FUNCTION admin.get_portal_user_for_authentication(text)
FROM PUBLIC;

REVOKE ALL
ON FUNCTION admin.record_portal_login_success(bigint)
FROM PUBLIC;

REVOKE ALL
ON FUNCTION admin.record_portal_login_failure(bigint)
FROM PUBLIC;

GRANT EXECUTE
ON FUNCTION admin.get_portal_user_for_authentication(text)
TO ems_app;

GRANT EXECUTE
ON FUNCTION admin.record_portal_login_success(bigint)
TO ems_app;

GRANT EXECUTE
ON FUNCTION admin.record_portal_login_failure(bigint)
TO ems_app;

COMMIT;
