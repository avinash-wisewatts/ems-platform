-- Story 3.3: organization-scoped portal identities and user audit history.

ALTER TABLE admin.portal_users
    ADD COLUMN IF NOT EXISTS organization_id UUID;


ALTER TABLE admin.portal_users
    DROP CONSTRAINT IF EXISTS portal_users_organization_fk;

ALTER TABLE admin.portal_users
    ADD CONSTRAINT portal_users_organization_fk
    FOREIGN KEY (organization_id)
    REFERENCES metadata.organizations (id)
    ON UPDATE CASCADE
    ON DELETE RESTRICT;


ALTER TABLE admin.portal_users
    DROP CONSTRAINT IF EXISTS portal_users_role_organization_scope_valid;

ALTER TABLE admin.portal_users
    ADD CONSTRAINT portal_users_role_organization_scope_valid
    CHECK
    (
        (
            role_code = 'PLATFORM_ADMIN'
            AND organization_id IS NULL
        )
        OR
        (
            role_code = 'ORG_ADMIN'
            AND organization_id IS NOT NULL
        )
        OR role_code IN ('OPERATOR', 'VIEWER')
    );


CREATE INDEX IF NOT EXISTS idx_portal_users_organization
    ON admin.portal_users
    (
        organization_id,
        portal_user_id
    )
    WHERE organization_id IS NOT NULL;


COMMENT ON COLUMN admin.portal_users.organization_id IS
'Organization scope for tenant-owned portal identities. PLATFORM_ADMIN is global and must remain unscoped.';


CREATE TABLE IF NOT EXISTS admin.portal_user_audit
(
    audit_id UUID
        PRIMARY KEY
        DEFAULT gen_random_uuid(),

    actor_portal_user_id BIGINT
        NOT NULL,

    target_portal_user_id BIGINT,

    organization_id UUID,

    event_type TEXT
        NOT NULL,

    previous_role_code TEXT,

    new_role_code TEXT,

    event_payload JSONB
        NOT NULL
        DEFAULT '{}'::jsonb,

    created_at TIMESTAMPTZ
        NOT NULL
        DEFAULT clock_timestamp(),

    CONSTRAINT portal_user_audit_actor_fk
        FOREIGN KEY (actor_portal_user_id)
        REFERENCES admin.portal_users (portal_user_id)
        ON UPDATE CASCADE
        ON DELETE RESTRICT,

    CONSTRAINT portal_user_audit_target_fk
        FOREIGN KEY (target_portal_user_id)
        REFERENCES admin.portal_users (portal_user_id)
        ON UPDATE CASCADE
        ON DELETE SET NULL,

    CONSTRAINT portal_user_audit_organization_fk
        FOREIGN KEY (organization_id)
        REFERENCES metadata.organizations (id)
        ON UPDATE CASCADE
        ON DELETE RESTRICT,

    CONSTRAINT portal_user_audit_event_type_not_blank
        CHECK (btrim(event_type) <> ''),

    CONSTRAINT portal_user_audit_payload_object
        CHECK (jsonb_typeof(event_payload) = 'object')
);


CREATE INDEX IF NOT EXISTS idx_portal_user_audit_target_created
    ON admin.portal_user_audit
    (
        target_portal_user_id,
        created_at DESC
    );

CREATE INDEX IF NOT EXISTS idx_portal_user_audit_organization_created
    ON admin.portal_user_audit
    (
        organization_id,
        created_at DESC
    )
    WHERE organization_id IS NOT NULL;


COMMENT ON TABLE admin.portal_user_audit IS
'Immutable audit history for portal-user creation, status changes, and role changes.';


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
        portal_user.is_active,
        portal_user.failed_login_count,
        portal_user.locked_until
    FROM admin.portal_users AS portal_user
    WHERE portal_user.username = lower(btrim(p_username))
    LIMIT 1;
$function$;


ALTER FUNCTION admin.get_portal_user_for_authentication(TEXT)
    OWNER TO ems_admin;


REVOKE ALL
    ON TABLE admin.portal_user_audit
    FROM PUBLIC;

REVOKE ALL
    ON TABLE admin.portal_user_audit
    FROM ems_app;

REVOKE ALL
    ON FUNCTION admin.get_portal_user_for_authentication(TEXT)
    FROM PUBLIC;

GRANT EXECUTE
    ON FUNCTION admin.get_portal_user_for_authentication(TEXT)
    TO ems_app;
