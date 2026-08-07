-- Story 3.4: independent organization-wide and selected-site access scopes.

ALTER TABLE admin.portal_users
    ADD COLUMN IF NOT EXISTS access_scope_mode TEXT;


UPDATE admin.portal_users
SET access_scope_mode = CASE
    WHEN role_code = 'PLATFORM_ADMIN' THEN NULL
    ELSE 'ORGANIZATION'
END
WHERE access_scope_mode IS NULL;


ALTER TABLE admin.portal_users
    DROP CONSTRAINT IF EXISTS portal_users_access_scope_mode_valid;

ALTER TABLE admin.portal_users
    ADD CONSTRAINT portal_users_access_scope_mode_valid
    CHECK (
        (
            role_code = 'PLATFORM_ADMIN'
            AND organization_id IS NULL
            AND access_scope_mode IS NULL
        )
        OR
        (
            role_code <> 'PLATFORM_ADMIN'
            AND organization_id IS NOT NULL
            AND access_scope_mode IN (
                'ORGANIZATION',
                'SELECTED_SITES'
            )
        )
    );


COMMENT ON COLUMN admin.portal_users.access_scope_mode IS
'Independent tenant access scope: ORGANIZATION or SELECTED_SITES. PLATFORM_ADMIN remains global with NULL scope.';


CREATE TABLE IF NOT EXISTS admin.portal_user_site_access
(
    portal_user_id BIGINT NOT NULL,
    site_id UUID NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    created_by_portal_user_id BIGINT NOT NULL,

    CONSTRAINT portal_user_site_access_pkey
        PRIMARY KEY (portal_user_id, site_id),

    CONSTRAINT portal_user_site_access_user_fk
        FOREIGN KEY (portal_user_id)
        REFERENCES admin.portal_users (portal_user_id)
        ON UPDATE CASCADE
        ON DELETE CASCADE,

    CONSTRAINT portal_user_site_access_site_fk
        FOREIGN KEY (site_id)
        REFERENCES metadata.sites (id)
        ON UPDATE CASCADE
        ON DELETE CASCADE,

    CONSTRAINT portal_user_site_access_creator_fk
        FOREIGN KEY (created_by_portal_user_id)
        REFERENCES admin.portal_users (portal_user_id)
        ON UPDATE CASCADE
        ON DELETE RESTRICT
);


CREATE INDEX IF NOT EXISTS idx_portal_user_site_access_site
    ON admin.portal_user_site_access
    (
        site_id,
        portal_user_id
    );


COMMENT ON TABLE admin.portal_user_site_access IS
'Explicit site assignments for portal users whose access_scope_mode is SELECTED_SITES.';


CREATE OR REPLACE FUNCTION admin.portal_user_can_access_site
(
    p_portal_user_id BIGINT,
    p_site_id UUID
)
RETURNS BOOLEAN
LANGUAGE SQL
SECURITY DEFINER
STABLE
SET search_path TO pg_catalog, admin, metadata
AS $function$
    SELECT COALESCE(
        (
            SELECT
                CASE
                    WHEN portal_user.role_code = 'PLATFORM_ADMIN'
                        THEN TRUE

                    WHEN portal_user.organization_id
                         IS DISTINCT FROM site_record.organization_id
                        THEN FALSE

                    WHEN portal_user.access_scope_mode = 'ORGANIZATION'
                        THEN TRUE

                    WHEN portal_user.access_scope_mode = 'SELECTED_SITES'
                        THEN EXISTS (
                            SELECT 1
                            FROM admin.portal_user_site_access AS assignment
                            WHERE assignment.portal_user_id =
                                portal_user.portal_user_id
                              AND assignment.site_id = site_record.id
                        )

                    ELSE FALSE
                END
            FROM admin.portal_users AS portal_user
            JOIN metadata.sites AS site_record
              ON site_record.id = p_site_id
            WHERE portal_user.portal_user_id = p_portal_user_id
              AND portal_user.is_active = TRUE
        ),
        FALSE
    );
$function$;


CREATE OR REPLACE FUNCTION admin.list_accessible_sites
(
    p_portal_user_id BIGINT
)
RETURNS TABLE
(
    id UUID,
    organization_id UUID,
    organization_code TEXT,
    organization_name TEXT,
    site_code TEXT,
    site_name TEXT,
    timezone TEXT,
    address JSONB,
    is_active BOOLEAN
)
LANGUAGE SQL
SECURITY DEFINER
STABLE
SET search_path TO pg_catalog, admin, metadata
AS $function$
    SELECT
        site_record.id,
        site_record.organization_id,
        organization_record.code AS organization_code,
        organization_record.name AS organization_name,
        site_record.code AS site_code,
        site_record.name AS site_name,
        site_record.timezone,
        site_record.address,
        site_record.is_active
    FROM metadata.sites AS site_record
    JOIN metadata.organizations AS organization_record
      ON organization_record.id = site_record.organization_id
    JOIN admin.portal_users AS portal_user
      ON portal_user.portal_user_id = p_portal_user_id
    WHERE portal_user.is_active = TRUE
      AND site_record.is_active = TRUE
      AND (
          portal_user.role_code = 'PLATFORM_ADMIN'
          OR (
              portal_user.organization_id = site_record.organization_id
              AND (
                  portal_user.access_scope_mode = 'ORGANIZATION'
                  OR (
                      portal_user.access_scope_mode = 'SELECTED_SITES'
                      AND EXISTS (
                          SELECT 1
                          FROM admin.portal_user_site_access AS assignment
                          WHERE assignment.portal_user_id =
                              portal_user.portal_user_id
                            AND assignment.site_id = site_record.id
                      )
                  )
              )
          )
      )
    ORDER BY
        organization_record.name,
        site_record.name,
        site_record.code,
        site_record.id;
$function$;


DROP FUNCTION IF EXISTS
    admin.get_portal_user_for_authentication(TEXT);


CREATE FUNCTION admin.get_portal_user_for_authentication
(
    p_username TEXT
)
RETURNS TABLE
(
    portal_user_id BIGINT,
    username TEXT,
    display_name TEXT,
    password_hash TEXT,
    role_code TEXT,
    organization_id UUID,
    access_scope_mode TEXT,
    site_ids UUID[],
    is_active BOOLEAN,
    failed_login_count INTEGER,
    locked_until TIMESTAMPTZ
)
LANGUAGE SQL
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
        portal_user.organization_id,
        portal_user.access_scope_mode,
        COALESCE(
            array_agg(
                assignment.site_id
                ORDER BY assignment.site_id
            ) FILTER (
                WHERE assignment.site_id IS NOT NULL
            ),
            ARRAY[]::UUID[]
        ) AS site_ids,
        portal_user.is_active,
        portal_user.failed_login_count,
        portal_user.locked_until
    FROM admin.portal_users AS portal_user
    LEFT JOIN admin.portal_user_site_access AS assignment
      ON assignment.portal_user_id = portal_user.portal_user_id
    WHERE portal_user.username = lower(btrim(p_username))
    GROUP BY
        portal_user.portal_user_id,
        portal_user.username,
        portal_user.display_name,
        portal_user.password_hash,
        portal_user.role_code,
        portal_user.organization_id,
        portal_user.access_scope_mode,
        portal_user.is_active,
        portal_user.failed_login_count,
        portal_user.locked_until
    LIMIT 1;
$function$;


ALTER TABLE admin.portal_user_site_access
    OWNER TO ems_admin;

ALTER FUNCTION admin.portal_user_can_access_site(BIGINT, UUID)
    OWNER TO ems_admin;

ALTER FUNCTION admin.list_accessible_sites(BIGINT)
    OWNER TO ems_admin;

ALTER FUNCTION admin.get_portal_user_for_authentication(TEXT)
    OWNER TO ems_admin;


REVOKE ALL
    ON TABLE admin.portal_user_site_access
    FROM PUBLIC;

REVOKE ALL
    ON TABLE admin.portal_user_site_access
    FROM ems_app;

REVOKE ALL
    ON FUNCTION admin.portal_user_can_access_site(BIGINT, UUID)
    FROM PUBLIC;

REVOKE ALL
    ON FUNCTION admin.list_accessible_sites(BIGINT)
    FROM PUBLIC;

REVOKE ALL
    ON FUNCTION admin.get_portal_user_for_authentication(TEXT)
    FROM PUBLIC;


GRANT EXECUTE
    ON FUNCTION admin.portal_user_can_access_site(BIGINT, UUID)
    TO ems_app;

GRANT EXECUTE
    ON FUNCTION admin.list_accessible_sites(BIGINT)
    TO ems_app;

GRANT EXECUTE
    ON FUNCTION admin.get_portal_user_for_authentication(TEXT)
    TO ems_app;
