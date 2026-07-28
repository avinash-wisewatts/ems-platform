-- ============================================================================
-- File: 82_admin_hierarchy_lookup_views.sql
-- Purpose:
--   Provide controlled, read-only hierarchy catalogs for the progressive
--   EMS onboarding wizard.
--
-- Hierarchy:
--   Organization
--       -> Site
--           -> Gateway
--               -> Device
--
-- Security:
--   * Views are created with PostgreSQL security barriers.
--   * PUBLIC receives no privileges.
--   * ems_app receives SELECT only.
--   * Direct writes continue through the controlled onboarding function.
-- ============================================================================

BEGIN;


-- ============================================================================
-- 1. ORGANIZATIONS
-- ============================================================================

CREATE OR REPLACE VIEW admin.v_organizations
WITH
(
    security_barrier = TRUE
)
AS
SELECT
    o.id,
    o.code AS organization_code,
    o.name AS organization_name,
    o.description,
    o.is_active,
    o.created_at,
    o.updated_at
FROM metadata.organizations o
WHERE o.is_active = TRUE;


COMMENT ON VIEW admin.v_organizations IS
'Active organizations available for explicit selection in the EMS onboarding wizard.';


-- ============================================================================
-- 2. SITES
-- ============================================================================

CREATE OR REPLACE VIEW admin.v_sites
WITH
(
    security_barrier = TRUE
)
AS
SELECT
    s.id,
    s.organization_id,
    o.code AS organization_code,
    o.name AS organization_name,
    s.code AS site_code,
    s.name AS site_name,
    s.timezone,
    s.address,
    s.is_active,
    s.created_at,
    s.updated_at
FROM metadata.sites s
JOIN metadata.organizations o
  ON o.id = s.organization_id
WHERE s.is_active = TRUE
  AND o.is_active = TRUE;


COMMENT ON VIEW admin.v_sites IS
'Active sites with organization ownership for dependent onboarding selection.';


-- ============================================================================
-- 3. GATEWAYS
-- ============================================================================

CREATE OR REPLACE VIEW admin.v_gateways
WITH
(
    security_barrier = TRUE
)
AS
SELECT
    g.id,
    g.organization_id,
    o.code AS organization_code,
    o.name AS organization_name,

    g.site_id,
    s.code AS site_code,
    s.name AS site_name,

    g.space_id,
    sp.code AS space_code,
    sp.name AS space_name,

    g.gateway_model_id,
    gm.vendor AS gateway_vendor,
    gm.model AS gateway_model,
    gm.protocol AS gateway_protocol,

    g.external_id,
    g.name AS gateway_name,
    g.created_at

FROM metadata.gateways g

JOIN metadata.organizations o
  ON o.id = g.organization_id

JOIN metadata.sites s
  ON s.id = g.site_id
 AND s.organization_id = g.organization_id

LEFT JOIN metadata.spaces sp
  ON sp.id = g.space_id
 AND sp.organization_id = g.organization_id

LEFT JOIN metadata.gateway_models gm
  ON gm.id = g.gateway_model_id

WHERE o.is_active = TRUE
  AND s.is_active = TRUE;


COMMENT ON VIEW admin.v_gateways IS
'Gateways with organization, site, optional space, and gateway-model ownership for dependent onboarding selection.';


-- ============================================================================
-- 4. DEVICES
-- ============================================================================

CREATE OR REPLACE VIEW admin.v_devices
WITH
(
    security_barrier = TRUE
)
AS
SELECT
    d.id,
    d.organization_id,
    o.code AS organization_code,
    o.name AS organization_name,

    d.gateway_id,
    g.site_id,
    s.code AS site_code,
    s.name AS site_name,
    g.external_id AS gateway_external_id,
    g.name AS gateway_name,

    d.device_model_id,
    dm.vendor AS device_vendor,
    dm.model AS device_model,
    dm.device_category_id,
    dc.name AS device_category_name,

    d.profile_id,
    dp.profile_code,
    dp.profile_name,

    d.external_id,
    d.name AS device_name,
    d.serial_number,
    d.firmware_version,
    d.protocol,
    d.created_at,
    d.updated_at

FROM metadata.devices d

JOIN metadata.organizations o
  ON o.id = d.organization_id

LEFT JOIN metadata.gateways g
  ON g.id = d.gateway_id
 AND g.organization_id = d.organization_id

LEFT JOIN metadata.sites s
  ON s.id = g.site_id
 AND s.organization_id = d.organization_id

LEFT JOIN metadata.device_models dm
  ON dm.id = d.device_model_id

LEFT JOIN config.device_categories dc
  ON dc.id = dm.device_category_id

LEFT JOIN config.device_profiles dp
  ON dp.id = d.profile_id

WHERE o.is_active = TRUE;


COMMENT ON VIEW admin.v_devices IS
'Devices with organization, gateway, site, model, category, and profile ownership for dependent onboarding selection.';


-- ============================================================================
-- 5. LEAST-PRIVILEGE ACCESS
-- ============================================================================

REVOKE ALL ON admin.v_organizations FROM PUBLIC;
REVOKE ALL ON admin.v_sites FROM PUBLIC;
REVOKE ALL ON admin.v_gateways FROM PUBLIC;
REVOKE ALL ON admin.v_devices FROM PUBLIC;

GRANT USAGE ON SCHEMA admin TO ems_app;

GRANT SELECT ON admin.v_organizations TO ems_app;
GRANT SELECT ON admin.v_sites TO ems_app;
GRANT SELECT ON admin.v_gateways TO ems_app;
GRANT SELECT ON admin.v_devices TO ems_app;


COMMIT;
