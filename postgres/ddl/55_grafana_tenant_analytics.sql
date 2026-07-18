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
-- 2. Environment-specific tenant mappings
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

GRANT CONNECT ON DATABASE ems TO grafana_reader;

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
