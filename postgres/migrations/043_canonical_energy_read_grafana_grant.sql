-- Migration 043
-- Grant the Grafana-facing role EXECUTE on the canonical energy reader.
--
-- analytics.get_canonical_energy_read (migration 042) is SECURITY DEFINER,
-- owned by ems_admin, with a fixed search_path -- the same boundary pattern
-- already used for grafana_reader-facing resolvers (e.g. migration 018's
-- analytics.resolve_demand_capability). grafana_reader does not receive any
-- new table/view access; it can only invoke this one fixed, non-dynamic
-- function with the owner's rights, identical to how
-- analytics.get_grafana_asset_energy_intervals is already exposed.
--
-- No other function's grants are touched. No other role is granted.

GRANT EXECUTE
ON FUNCTION analytics.get_canonical_energy_read(
    BIGINT,
    UUID,
    TIMESTAMPTZ,
    TIMESTAMPTZ,
    TEXT,
    TEXT
)
TO grafana_reader;
