-- ============================================================================
-- File:
--   55_grafana_tenant_analytics.sql
--
-- Purpose:
--   Establish the Grafana-to-EMS tenant mapping and expose a restricted
--   analytics schema for Grafana dashboards.
--
-- Tenant contract:
--
--   Grafana ${__org.id}
--       -> metadata.grafana_organization_map.grafana_org_id
--       -> metadata.organizations.id
--       -> analytics views
--
-- Dashboard queries must include:
--
--   WHERE grafana_org_id = ${__org.id}
--
-- Security model:
--
--   1. grafana_reader receives no direct access to metadata or telemetry.
--   2. grafana_reader receives USAGE only on analytics.
--   3. grafana_reader receives SELECT only on approved analytics views.
--   4. Views expose grafana_org_id so tenant filtering is consistent across
--      metadata, raw energy and continuous aggregate queries.
--
-- Mapping lifecycle:
--
--   This canonical file creates the tenant-mapping contract but does not
--   create environment-specific mappings. Grafana organization mappings must
--   be provisioned separately after the corresponding EMS organization exists.
-- ============================================================================


-- ----------------------------------------------------------------------------
-- 1. Create the Grafana organization mapping table.
-- ----------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS metadata.grafana_organization_map
(
    grafana_org_id       BIGINT PRIMARY KEY,

    organization_id      UUID NOT NULL,

    is_active            BOOLEAN NOT NULL DEFAULT TRUE,

    created_at           TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at           TIMESTAMPTZ NOT NULL DEFAULT now(),

    CONSTRAINT fk_grafana_organization_map_organization
        FOREIGN KEY (organization_id)
        REFERENCES metadata.organizations(id)
        ON DELETE RESTRICT,

    CONSTRAINT uq_grafana_organization_map_organization
        UNIQUE (organization_id),

    CONSTRAINT ck_grafana_organization_map_positive_id
        CHECK (grafana_org_id > 0)
);


COMMENT ON TABLE metadata.grafana_organization_map IS
'Maps Grafana organization IDs to EMS tenant organization UUIDs.';

COMMENT ON COLUMN metadata.grafana_organization_map.grafana_org_id IS
'Grafana organization ID exposed through the ${__org.id} dashboard macro.';

COMMENT ON COLUMN metadata.grafana_organization_map.organization_id IS
'EMS metadata.organizations tenant UUID.';


-- ----------------------------------------------------------------------------
-- 2. Grafana organization provisioning lifecycle.
-- ----------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS admin.grafana_organization_provisioning
(
    organization_id UUID PRIMARY KEY,

    status_domain TEXT NOT NULL
        DEFAULT 'GRAFANA_PROVISIONING_STATUS',

    provisioning_status TEXT NOT NULL
        DEFAULT 'NOT_STARTED',

    grafana_org_id BIGINT,

    attempt_count INTEGER NOT NULL DEFAULT 0,

    last_attempt_at TIMESTAMPTZ,

    provisioned_at TIMESTAMPTZ,

    last_error TEXT,

    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),

    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),

    CONSTRAINT grafana_org_provisioning_organization_fk
        FOREIGN KEY (organization_id)
        REFERENCES metadata.organizations(id)
        ON DELETE RESTRICT,

    CONSTRAINT grafana_org_provisioning_mapping_fk
        FOREIGN KEY (grafana_org_id)
        REFERENCES metadata.grafana_organization_map(grafana_org_id)
        ON DELETE RESTRICT,

    CONSTRAINT grafana_org_provisioning_status_fk
        FOREIGN KEY (status_domain, provisioning_status)
        REFERENCES config.status_definitions(status_domain, code)
        ON DELETE RESTRICT,

    CONSTRAINT grafana_org_provisioning_status_domain_chk
        CHECK (
            status_domain = 'GRAFANA_PROVISIONING_STATUS'
        ),

    CONSTRAINT grafana_org_provisioning_attempt_count_chk
        CHECK (attempt_count >= 0),

    CONSTRAINT grafana_org_provisioning_positive_org_id_chk
        CHECK (
            grafana_org_id IS NULL
            OR grafana_org_id > 0
        ),

    CONSTRAINT grafana_org_provisioning_error_state_chk
        CHECK (
            provisioning_status = 'FAILED'
            OR last_error IS NULL
        ),

    CONSTRAINT grafana_org_provisioning_success_state_chk
        CHECK (
            provisioning_status <> 'PROVISIONED'
            OR (
                grafana_org_id IS NOT NULL
                AND provisioned_at IS NOT NULL
            )
        )
);

COMMENT ON TABLE admin.grafana_organization_provisioning IS
'Tracks Grafana provisioning attempts and outcomes for each EMS organization.';

COMMENT ON COLUMN
    admin.grafana_organization_provisioning.organization_id IS
'EMS organization being provisioned in Grafana.';

COMMENT ON COLUMN
    admin.grafana_organization_provisioning.provisioning_status IS
'Controlled GRAFANA_PROVISIONING_STATUS code.';

COMMENT ON COLUMN
    admin.grafana_organization_provisioning.grafana_org_id IS
'Mapped Grafana organization ID after successful provisioning.';

COMMENT ON COLUMN
    admin.grafana_organization_provisioning.attempt_count IS
'Number of provisioning attempts started for this organization.';

COMMENT ON COLUMN
    admin.grafana_organization_provisioning.last_error IS
'Most recent provisioning failure message, retained only for FAILED status.';


-- Backfill successful state for existing one-to-one mappings.
INSERT INTO admin.grafana_organization_provisioning
(
    organization_id,
    provisioning_status,
    grafana_org_id,
    attempt_count,
    last_attempt_at,
    provisioned_at,
    last_error
)
SELECT
    mapping.organization_id,
    'PROVISIONED',
    mapping.grafana_org_id,
    1,
    mapping.updated_at,
    mapping.updated_at,
    NULL
FROM metadata.grafana_organization_map mapping
ON CONFLICT (organization_id)
DO UPDATE SET
    provisioning_status = 'PROVISIONED',
    grafana_org_id = EXCLUDED.grafana_org_id,
    attempt_count = GREATEST(
        admin.grafana_organization_provisioning.attempt_count,
        EXCLUDED.attempt_count
    ),
    last_attempt_at = COALESCE(
        admin.grafana_organization_provisioning.last_attempt_at,
        EXCLUDED.last_attempt_at
    ),
    provisioned_at = COALESCE(
        admin.grafana_organization_provisioning.provisioned_at,
        EXCLUDED.provisioned_at
    ),
    last_error = NULL,
    updated_at = now();


CREATE OR REPLACE FUNCTION admin.get_grafana_provisioning
(
    p_organization_id UUID
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, admin, metadata, config
AS $$
DECLARE
    v_result JSONB;
BEGIN
    SELECT jsonb_build_object
    (
        'organization_id', provisioning.organization_id,
        'provisioning_status', provisioning.provisioning_status,
        'grafana_org_id', provisioning.grafana_org_id,
        'attempt_count', provisioning.attempt_count,
        'last_attempt_at', provisioning.last_attempt_at,
        'provisioned_at', provisioning.provisioned_at,
        'last_error', provisioning.last_error
    )
    INTO v_result
    FROM admin.grafana_organization_provisioning provisioning
    WHERE provisioning.organization_id = p_organization_id;

    RETURN v_result;
END;
$$;


CREATE OR REPLACE FUNCTION admin.mark_grafana_provisioning_pending
(
    p_organization_id UUID
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, admin, metadata, config
AS $$
DECLARE
    v_result JSONB;
BEGIN
    IF NOT EXISTS
    (
        SELECT 1
        FROM metadata.organizations organization_record
        WHERE organization_record.id = p_organization_id
    ) THEN
        RAISE EXCEPTION
            'EMS organization % does not exist.',
            p_organization_id
            USING ERRCODE = '23503';
    END IF;

    INSERT INTO admin.grafana_organization_provisioning
    (
        organization_id,
        provisioning_status,
        grafana_org_id,
        attempt_count,
        last_attempt_at,
        provisioned_at,
        last_error
    )
    VALUES
    (
        p_organization_id,
        'PENDING',
        NULL,
        1,
        clock_timestamp(),
        NULL,
        NULL
    )
    ON CONFLICT (organization_id)
    DO UPDATE SET
        provisioning_status = 'PENDING',
        attempt_count =
            admin.grafana_organization_provisioning.attempt_count + 1,
        last_attempt_at = clock_timestamp(),
        last_error = NULL,
        updated_at = clock_timestamp();

    SELECT admin.get_grafana_provisioning(
        p_organization_id
    )
    INTO v_result;

    RETURN v_result;
END;
$$;


CREATE OR REPLACE FUNCTION admin.mark_grafana_provisioning_failed
(
    p_organization_id UUID,
    p_error TEXT
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, admin, metadata, config
AS $$
DECLARE
    v_error TEXT := NULLIF(btrim(p_error), '');
    v_result JSONB;
BEGIN
    IF v_error IS NULL THEN
        v_error := 'Grafana provisioning failed.';
    END IF;

    IF length(v_error) > 4000 THEN
        v_error := left(v_error, 4000);
    END IF;

    INSERT INTO admin.grafana_organization_provisioning
    (
        organization_id,
        provisioning_status,
        grafana_org_id,
        attempt_count,
        last_attempt_at,
        provisioned_at,
        last_error
    )
    VALUES
    (
        p_organization_id,
        'FAILED',
        NULL,
        1,
        clock_timestamp(),
        NULL,
        v_error
    )
    ON CONFLICT (organization_id)
    DO UPDATE SET
        provisioning_status = 'FAILED',
        last_error = v_error,
        updated_at = clock_timestamp();

    SELECT admin.get_grafana_provisioning(
        p_organization_id
    )
    INTO v_result;

    RETURN v_result;
END;
$$;


CREATE OR REPLACE FUNCTION admin.mark_grafana_provisioning_complete
(
    p_organization_id UUID,
    p_grafana_org_id BIGINT
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, admin, metadata, config
AS $$
DECLARE
    v_existing_grafana_org_id BIGINT;
    v_existing_organization_id UUID;
    v_result JSONB;
BEGIN
    IF p_grafana_org_id IS NULL OR p_grafana_org_id <= 0 THEN
        RAISE EXCEPTION
            'Grafana organization ID must be a positive integer.'
            USING ERRCODE = '22023';
    END IF;

    IF NOT EXISTS
    (
        SELECT 1
        FROM metadata.organizations organization_record
        WHERE organization_record.id = p_organization_id
    ) THEN
        RAISE EXCEPTION
            'EMS organization % does not exist.',
            p_organization_id
            USING ERRCODE = '23503';
    END IF;

    SELECT mapping.grafana_org_id
    INTO v_existing_grafana_org_id
    FROM metadata.grafana_organization_map mapping
    WHERE mapping.organization_id = p_organization_id;

    IF v_existing_grafana_org_id IS NOT NULL
       AND v_existing_grafana_org_id <> p_grafana_org_id
    THEN
        RAISE EXCEPTION
            'EMS organization % is already mapped to Grafana org %.',
            p_organization_id,
            v_existing_grafana_org_id
            USING ERRCODE = '23505';
    END IF;

    SELECT mapping.organization_id
    INTO v_existing_organization_id
    FROM metadata.grafana_organization_map mapping
    WHERE mapping.grafana_org_id = p_grafana_org_id;

    IF v_existing_organization_id IS NOT NULL
       AND v_existing_organization_id <> p_organization_id
    THEN
        RAISE EXCEPTION
            'Grafana org % is already mapped to EMS organization %.',
            p_grafana_org_id,
            v_existing_organization_id
            USING ERRCODE = '23505';
    END IF;

    INSERT INTO metadata.grafana_organization_map
    (
        grafana_org_id,
        organization_id,
        is_active
    )
    VALUES
    (
        p_grafana_org_id,
        p_organization_id,
        TRUE
    )
    ON CONFLICT (grafana_org_id)
    DO UPDATE SET
        organization_id = EXCLUDED.organization_id,
        is_active = TRUE,
        updated_at = clock_timestamp();

    INSERT INTO admin.grafana_organization_provisioning
    (
        organization_id,
        provisioning_status,
        grafana_org_id,
        attempt_count,
        last_attempt_at,
        provisioned_at,
        last_error
    )
    VALUES
    (
        p_organization_id,
        'PROVISIONED',
        p_grafana_org_id,
        1,
        clock_timestamp(),
        clock_timestamp(),
        NULL
    )
    ON CONFLICT (organization_id)
    DO UPDATE SET
        provisioning_status = 'PROVISIONED',
        grafana_org_id = EXCLUDED.grafana_org_id,
        provisioned_at = clock_timestamp(),
        last_error = NULL,
        updated_at = clock_timestamp();

    SELECT admin.get_grafana_provisioning(
        p_organization_id
    )
    INTO v_result;

    RETURN v_result;
END;
$$;


ALTER TABLE admin.grafana_organization_provisioning
    OWNER TO ems_admin;

ALTER FUNCTION admin.get_grafana_provisioning(UUID)
    OWNER TO ems_admin;

ALTER FUNCTION admin.mark_grafana_provisioning_pending(UUID)
    OWNER TO ems_admin;

ALTER FUNCTION admin.mark_grafana_provisioning_failed(UUID, TEXT)
    OWNER TO ems_admin;

ALTER FUNCTION admin.mark_grafana_provisioning_complete(UUID, BIGINT)
    OWNER TO ems_admin;


REVOKE ALL
    ON TABLE admin.grafana_organization_provisioning
    FROM PUBLIC;

REVOKE ALL
    ON FUNCTION admin.get_grafana_provisioning(UUID)
    FROM PUBLIC;

REVOKE ALL
    ON FUNCTION admin.mark_grafana_provisioning_pending(UUID)
    FROM PUBLIC;

REVOKE ALL
    ON FUNCTION admin.mark_grafana_provisioning_failed(UUID, TEXT)
    FROM PUBLIC;

REVOKE ALL
    ON FUNCTION admin.mark_grafana_provisioning_complete(UUID, BIGINT)
    FROM PUBLIC;


GRANT EXECUTE
    ON FUNCTION admin.get_grafana_provisioning(UUID)
    TO ems_app;

GRANT EXECUTE
    ON FUNCTION admin.mark_grafana_provisioning_pending(UUID)
    TO ems_app;

GRANT EXECUTE
    ON FUNCTION admin.mark_grafana_provisioning_failed(UUID, TEXT)
    TO ems_app;

GRANT EXECUTE
    ON FUNCTION admin.mark_grafana_provisioning_complete(UUID, BIGINT)
    TO ems_app;


-- ----------------------------------------------------------------------------
-- 3. Organization Grafana provisioning status listing.
-- ----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION admin.list_grafana_provisioning_status()
RETURNS TABLE
(
    organization_id UUID,
    organization_code TEXT,
    organization_name TEXT,
    timezone TEXT,
    lifecycle_status TEXT,
    provisioning_status TEXT,
    grafana_org_id BIGINT,
    attempt_count INTEGER,
    last_attempt_at TIMESTAMPTZ,
    provisioned_at TIMESTAMPTZ,
    last_error TEXT
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, admin, metadata, config
AS $$
    SELECT
        organization.id AS organization_id,
        organization.code AS organization_code,
        organization.name AS organization_name,
        organization.timezone,
        organization.lifecycle_status,
        COALESCE(
            provisioning.provisioning_status,
            'NOT_STARTED'
        ) AS provisioning_status,
        provisioning.grafana_org_id,
        COALESCE(
            provisioning.attempt_count,
            0
        ) AS attempt_count,
        provisioning.last_attempt_at,
        provisioning.provisioned_at,
        provisioning.last_error
    FROM metadata.organizations organization
    LEFT JOIN admin.grafana_organization_provisioning provisioning
        ON provisioning.organization_id = organization.id
    ORDER BY
        organization.name,
        organization.code,
        organization.id;
$$;

ALTER FUNCTION admin.list_grafana_provisioning_status()
    OWNER TO ems_admin;

REVOKE ALL
    ON FUNCTION admin.list_grafana_provisioning_status()
    FROM PUBLIC;

GRANT EXECUTE
    ON FUNCTION admin.list_grafana_provisioning_status()
    TO ems_app;


-- ----------------------------------------------------------------------------
-- 4. Environment-specific tenant mappings
-- ----------------------------------------------------------------------------
--
-- Intentionally empty in canonical production DDL.
--
-- A Grafana organization must be mapped only after the corresponding EMS
-- organization exists. Demo mappings belong in demo seeds; production mappings
-- belong in controlled tenant-provisioning operations.
--


-- ----------------------------------------------------------------------------
-- 3. Create the dedicated Grafana analytics schema.
-- ----------------------------------------------------------------------------

CREATE SCHEMA IF NOT EXISTS analytics;


COMMENT ON SCHEMA analytics IS
'Approved read-only views used by Grafana dashboards and tenant analytics.';


-- ----------------------------------------------------------------------------
-- 4. Tenant and organization view.
-- ----------------------------------------------------------------------------

CREATE OR REPLACE VIEW analytics.v_organizations
WITH
(
    security_barrier = TRUE
)
AS
SELECT
    gom.grafana_org_id,

    o.id AS organization_id,
    o.code AS organization_code,
    o.name AS organization_name,
    o.description,
    o.is_active

FROM metadata.grafana_organization_map gom

JOIN metadata.organizations o
  ON o.id = gom.organization_id

WHERE gom.is_active = TRUE
  AND o.is_active = TRUE;


COMMENT ON VIEW analytics.v_organizations IS
'Active EMS organizations mapped to Grafana organizations.';


-- ----------------------------------------------------------------------------
-- 5. Tenant-safe site metadata.
-- ----------------------------------------------------------------------------

CREATE OR REPLACE VIEW analytics.v_sites
WITH
(
    security_barrier = TRUE
)
AS
SELECT
    gom.grafana_org_id,

    o.id AS organization_id,
    o.code AS organization_code,
    o.name AS organization_name,

    s.id AS site_id,
    s.code AS site_code,
    s.name AS site_name

FROM metadata.grafana_organization_map gom

JOIN metadata.organizations o
  ON o.id = gom.organization_id

JOIN metadata.sites s
  ON s.organization_id = o.id

WHERE gom.is_active = TRUE
  AND o.is_active = TRUE;


COMMENT ON VIEW analytics.v_sites IS
'Tenant-aware site list for Grafana variables and dashboard filtering.';


-- ----------------------------------------------------------------------------
-- 6. Tenant-safe device metadata.
-- ----------------------------------------------------------------------------

CREATE OR REPLACE VIEW analytics.v_devices
WITH
(
    security_barrier = TRUE
)
AS
SELECT
    gom.grafana_org_id,

    d.organization_id,

    g.site_id,
    s.code AS site_code,
    s.name AS site_name,

    d.gateway_id,
    g.name AS gateway_name,

    d.id AS device_id,
    d.external_id,
    d.name AS device_name,
    d.serial_number,
    d.protocol,
    d.firmware_version,

    d.profile_id,
    dp.profile_code,
    dp.profile_name

FROM metadata.grafana_organization_map gom

JOIN metadata.devices d
  ON d.organization_id = gom.organization_id

LEFT JOIN metadata.gateways g
  ON g.id = d.gateway_id

LEFT JOIN metadata.sites s
  ON s.id = g.site_id

LEFT JOIN config.device_profiles dp
  ON dp.id = d.profile_id

WHERE gom.is_active = TRUE;


COMMENT ON VIEW analytics.v_devices IS
'Tenant-aware device metadata for Grafana dashboard variables.';


-- ----------------------------------------------------------------------------
-- 7. Raw energy measurements.
--
-- Use this view only for short time ranges or detailed diagnostics.
-- Longer Grafana ranges should use the aggregate views below.
-- ----------------------------------------------------------------------------

CREATE OR REPLACE VIEW analytics.v_energy_raw
WITH
(
    security_barrier = TRUE
)
AS
SELECT
    gom.grafana_org_id,

    em.*

FROM metadata.grafana_organization_map gom

JOIN telemetry.energy_measurements em
  ON em.organization_id = gom.organization_id

WHERE gom.is_active = TRUE;


COMMENT ON VIEW analytics.v_energy_raw IS
'Tenant-aware raw energy telemetry retained for detailed short-range analysis.';


-- ----------------------------------------------------------------------------
-- 8. Fifteen-minute energy aggregate.
-- ----------------------------------------------------------------------------

CREATE OR REPLACE VIEW analytics.v_energy_15min
WITH
(
    security_barrier = TRUE
)
AS
SELECT
    gom.grafana_org_id,

    ca.*

FROM metadata.grafana_organization_map gom

JOIN telemetry.ca_energy_15min ca
  ON ca.organization_id = gom.organization_id

WHERE gom.is_active = TRUE;


COMMENT ON VIEW analytics.v_energy_15min IS
'Tenant-aware fifteen-minute energy aggregate for Grafana operational trends.';


-- ----------------------------------------------------------------------------
-- 9. Hourly energy aggregate.
-- ----------------------------------------------------------------------------

CREATE OR REPLACE VIEW analytics.v_energy_hourly
WITH
(
    security_barrier = TRUE
)
AS
SELECT
    gom.grafana_org_id,

    ca.*

FROM metadata.grafana_organization_map gom

JOIN telemetry.ca_energy_hourly ca
  ON ca.organization_id = gom.organization_id

WHERE gom.is_active = TRUE;


COMMENT ON VIEW analytics.v_energy_hourly IS
'Tenant-aware hourly energy aggregate for medium- and long-range dashboards.';


-- ----------------------------------------------------------------------------
-- 10. Daily energy aggregate.
-- ----------------------------------------------------------------------------

CREATE OR REPLACE VIEW analytics.v_energy_daily
WITH
(
    security_barrier = TRUE
)
AS
SELECT
    gom.grafana_org_id,

    ca.*

FROM metadata.grafana_organization_map gom

JOIN telemetry.ca_energy_daily ca
  ON ca.organization_id = gom.organization_id

WHERE gom.is_active = TRUE;


COMMENT ON VIEW analytics.v_energy_daily IS
'Tenant-aware daily energy aggregate for reporting and executive dashboards.';


-- ----------------------------------------------------------------------------
-- 11. Grafana-friendly latest-value view.
--
-- Returns the newest available wide energy measurement for each device.
-- ----------------------------------------------------------------------------

CREATE OR REPLACE VIEW analytics.v_energy_latest
WITH
(
    security_barrier = TRUE
)
AS
SELECT DISTINCT ON
(
    gom.grafana_org_id,
    em.device_id
)
    gom.grafana_org_id,

    em.*,

    d.external_id,
    d.name AS device_name

FROM metadata.grafana_organization_map gom

JOIN telemetry.energy_measurements em
  ON em.organization_id = gom.organization_id

JOIN metadata.devices d
  ON d.id = em.device_id

WHERE gom.is_active = TRUE

ORDER BY
    gom.grafana_org_id,
    em.device_id,
    em.received_at DESC;


COMMENT ON VIEW analytics.v_energy_latest IS
'Newest energy measurement per device and Grafana organization.';


-- ----------------------------------------------------------------------------
-- 12. Lock down direct database access.
-- ----------------------------------------------------------------------------

REVOKE ALL ON SCHEMA analytics FROM PUBLIC;

REVOKE ALL ON ALL TABLES IN SCHEMA analytics FROM PUBLIC;

REVOKE ALL ON SCHEMA metadata FROM grafana_reader;
REVOKE ALL ON SCHEMA config FROM grafana_reader;
REVOKE ALL ON SCHEMA telemetry FROM grafana_reader;

REVOKE ALL ON ALL TABLES IN SCHEMA metadata FROM grafana_reader;
REVOKE ALL ON ALL TABLES IN SCHEMA config FROM grafana_reader;
REVOKE ALL ON ALL TABLES IN SCHEMA telemetry FROM grafana_reader;


-- ----------------------------------------------------------------------------
-- 13. Grant Grafana access only to the approved analytics schema.
-- ----------------------------------------------------------------------------

GRANT CONNECT ON DATABASE :"db_name" TO grafana_reader;

GRANT USAGE ON SCHEMA analytics TO grafana_reader;

GRANT SELECT ON
    analytics.v_organizations,
    analytics.v_sites,
    analytics.v_devices,
    analytics.v_energy_raw,
    analytics.v_energy_15min,
    analytics.v_energy_hourly,
    analytics.v_energy_daily,
    analytics.v_energy_latest
TO grafana_reader;


-- ----------------------------------------------------------------------------
-- 14. Default privilege policy.
--
-- Future analytics views must still be explicitly granted. This avoids
-- accidentally exposing new objects to Grafana.
-- ----------------------------------------------------------------------------

ALTER DEFAULT PRIVILEGES
FOR ROLE ems_admin
IN SCHEMA analytics
REVOKE ALL ON TABLES FROM PUBLIC;
