-- 018_grafana_config_permission_boundary_fix.sql
-- Restore owner-rights execution at the two approved analytics/config resolver
-- boundaries used by the Asset Dashboard.
--
-- Background:
--   * Migration 016 correctly made analytics.resolve_demand_capability()
--     SECURITY DEFINER, but migration 017 recreated that function and therefore
--     reverted it to SECURITY INVOKER.
--   * analytics.v_energy_consumption_{1min,5min,15min} call
--     config.resolve_interval_quality_rule(). That resolver is SECURITY INVOKER
--     and reads config.interval_quality_rules internally.
--
-- grafana_reader must consume published analytics contracts without receiving
-- direct access to private config tables or the config schema. Keep those
-- internals private and execute only these fixed, non-dynamic resolver
-- functions with the ems_admin owner's rights.

-- ---------------------------------------------------------------------------
-- 1. Demand capability boundary.
-- ---------------------------------------------------------------------------

ALTER FUNCTION analytics.resolve_demand_capability(UUID, TEXT, UUID, TIMESTAMPTZ)
    SECURITY DEFINER;

ALTER FUNCTION analytics.resolve_demand_capability(UUID, TEXT, UUID, TIMESTAMPTZ)
    SET search_path TO pg_catalog, analytics, config, metadata;

REVOKE ALL
ON FUNCTION analytics.resolve_demand_capability(UUID, TEXT, UUID, TIMESTAMPTZ)
FROM PUBLIC;

GRANT EXECUTE
ON FUNCTION analytics.resolve_demand_capability(UUID, TEXT, UUID, TIMESTAMPTZ)
TO ems_readonly, grafana_reader;

COMMENT ON FUNCTION analytics.resolve_demand_capability(UUID, TEXT, UUID, TIMESTAMPTZ) IS
'Owner-rights demand capability resolver with a fixed search_path. SITE and automatic ASSET demand semantics remain those established by migration 017; callers do not receive direct config-schema access.';

-- ---------------------------------------------------------------------------
-- 2. Energy interval-quality boundary.
-- ---------------------------------------------------------------------------

ALTER FUNCTION config.resolve_interval_quality_rule(UUID, TIMESTAMPTZ)
    SECURITY DEFINER;

ALTER FUNCTION config.resolve_interval_quality_rule(UUID, TIMESTAMPTZ)
    SET search_path TO pg_catalog, config, metadata;

REVOKE ALL
ON FUNCTION config.resolve_interval_quality_rule(UUID, TIMESTAMPTZ)
FROM PUBLIC;

-- Preserve the published execution contract. The Grafana energy views invoke
-- this resolver internally; this grant does not grant SELECT on config tables.
GRANT EXECUTE
ON FUNCTION config.resolve_interval_quality_rule(UUID, TIMESTAMPTZ)
TO ems_readonly, grafana_reader;

COMMENT ON FUNCTION config.resolve_interval_quality_rule(UUID, TIMESTAMPTZ) IS
'Owner-rights interval-quality resolver with a fixed search_path. Resolves device/profile/site/organization/platform precedence without exposing config.interval_quality_rules to dashboard readers.';
