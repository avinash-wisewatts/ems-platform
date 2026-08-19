-- ============================================================================
-- Migration 045
-- Fix Grafana energy resolution routing thresholds
--
-- Migration 044 shipped analytics.resolve_grafana_energy_routing_resolution
-- with thresholds that were too coarse for the requested ranges:
--   <=24h -> 15m, <=14d -> 1h, >14d -> 1d
--
-- Corrected thresholds:
--   <=24h -> native (finest available resolution; equivalent to the
--            "1-minute" tier -- actual native capture interval varies by
--            site, so 'native' is the correct canonical-reader identifier
--            rather than a hardcoded '1m')
--   <=14d -> 15m
--   >14d  -> 1h
--
-- No other object changes: analytics.get_grafana_asset_energy_intervals and
-- analytics.get_grafana_assets_energy_intervals (migration 044) both call
-- this helper by reference, so their behavior updates automatically.
-- ============================================================================


CREATE OR REPLACE FUNCTION analytics.resolve_grafana_energy_routing_resolution(
    p_from TIMESTAMPTZ,
    p_to TIMESTAMPTZ
)
RETURNS TEXT
LANGUAGE SQL
IMMUTABLE
AS $function$
SELECT CASE
    WHEN p_to - p_from <= INTERVAL '24 hours' THEN 'native'
    WHEN p_to - p_from <= INTERVAL '14 days'  THEN '15m'
    ELSE '1h'
END;
$function$;


COMMENT ON FUNCTION analytics.resolve_grafana_energy_routing_resolution(
    TIMESTAMPTZ,
    TIMESTAMPTZ
)
IS
'Maps a Grafana panel time range to a canonical reporting resolution tier: <=24h -> native, <=14d -> 15m, >14d -> 1h. Pure function shared by analytics.get_grafana_asset_energy_intervals and analytics.get_grafana_assets_energy_intervals.';
