-- Story 3.2: canonical permission catalog and declarative role mappings.

CREATE TABLE config.portal_permission_definitions
(
    permission_code TEXT PRIMARY KEY,

    display_name TEXT NOT NULL,

    description TEXT NOT NULL,

    sort_order INTEGER NOT NULL,

    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),

    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),

    CONSTRAINT portal_permission_definitions_code_not_blank
        CHECK (btrim(permission_code) <> ''),

    CONSTRAINT portal_permission_definitions_display_name_not_blank
        CHECK (btrim(display_name) <> ''),

    CONSTRAINT portal_permission_definitions_description_not_blank
        CHECK (btrim(description) <> ''),

    CONSTRAINT portal_permission_definitions_sort_order_positive
        CHECK (sort_order > 0)
);


CREATE TABLE config.portal_role_permissions
(
    role_code TEXT NOT NULL,

    permission_code TEXT NOT NULL,

    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),

    PRIMARY KEY
    (
        role_code,
        permission_code
    ),

    CONSTRAINT portal_role_permissions_role_fk
        FOREIGN KEY (role_code)
        REFERENCES config.portal_role_definitions (role_code)
        ON UPDATE CASCADE
        ON DELETE CASCADE,

    CONSTRAINT portal_role_permissions_permission_fk
        FOREIGN KEY (permission_code)
        REFERENCES config.portal_permission_definitions (permission_code)
        ON UPDATE CASCADE
        ON DELETE CASCADE
);


INSERT INTO config.portal_permission_definitions
(
    permission_code,
    display_name,
    description,
    sort_order
)
VALUES
(
    'organization.manage',
    'Manage organizations',
    'Create and manage EMS organizations and platform-owned organization services.',
    10
),
(
    'user.manage',
    'Manage users',
    'Create, update, activate, deactivate, and assign permitted portal users.',
    20
),
(
    'site.manage',
    'Manage sites',
    'Create and manage sites within the authorized tenant scope.',
    30
),
(
    'location.manage',
    'Manage locations',
    'Create and manage locations within authorized sites.',
    40
),
(
    'asset.manage',
    'Manage assets',
    'Create and manage assets within the authorized tenant and site scope.',
    50
),
(
    'gateway.manage',
    'Manage gateways',
    'Create, configure, and manage gateways within the authorized scope.',
    60
),
(
    'device.manage',
    'Manage devices',
    'Create, configure, and manage devices within the authorized scope.',
    70
),
(
    'relationship.manage',
    'Manage relationships',
    'Create and manage authorized hierarchy, attachment, and entity relationships.',
    80
),
(
    'metering_policy.manage',
    'Manage metering policies',
    'Configure metering roles, coverage requirements, and related policies.',
    90
),
(
    'commissioning.execute',
    'Execute commissioning',
    'Perform onboarding, commissioning, validation, and submission operations.',
    100
),
(
    'alert.acknowledge',
    'Acknowledge alerts',
    'Acknowledge and update permitted operational alerts.',
    110
),
(
    'dashboard.view',
    'View dashboards',
    'View permitted EMS dashboards and operational portal information.',
    120
),
(
    'report.export',
    'Export reports',
    'Export permitted reports and analytical data.',
    130
),
(
    'audit.view',
    'View audit records',
    'View permitted audit events and administrative history.',
    140
);


INSERT INTO config.portal_role_permissions
(
    role_code,
    permission_code
)
SELECT
    'PLATFORM_ADMIN',
    permission.permission_code
FROM config.portal_permission_definitions AS permission;


INSERT INTO config.portal_role_permissions
(
    role_code,
    permission_code
)
SELECT
    'ORG_ADMIN',
    permission.permission_code
FROM config.portal_permission_definitions AS permission
WHERE permission.permission_code <> 'organization.manage';


INSERT INTO config.portal_role_permissions
(
    role_code,
    permission_code
)
VALUES
    ('OPERATOR', 'site.manage'),
    ('OPERATOR', 'location.manage'),
    ('OPERATOR', 'asset.manage'),
    ('OPERATOR', 'gateway.manage'),
    ('OPERATOR', 'device.manage'),
    ('OPERATOR', 'relationship.manage'),
    ('OPERATOR', 'metering_policy.manage'),
    ('OPERATOR', 'commissioning.execute'),
    ('OPERATOR', 'alert.acknowledge'),
    ('OPERATOR', 'dashboard.view'),
    ('OPERATOR', 'report.export'),
    ('VIEWER', 'dashboard.view'),
    ('VIEWER', 'report.export');


COMMENT ON TABLE config.portal_permission_definitions IS
'Canonical Story 3.2 permission catalog.';

COMMENT ON TABLE config.portal_role_permissions IS
'Declarative canonical role-to-permission mappings.';


ALTER TABLE config.portal_permission_definitions
    OWNER TO ems_admin;

ALTER TABLE config.portal_role_permissions
    OWNER TO ems_admin;


REVOKE ALL
    ON TABLE config.portal_permission_definitions
    FROM PUBLIC;

REVOKE ALL
    ON TABLE config.portal_role_permissions
    FROM PUBLIC;

REVOKE ALL
    ON TABLE config.portal_permission_definitions
    FROM ems_app;

REVOKE ALL
    ON TABLE config.portal_role_permissions
    FROM ems_app;
