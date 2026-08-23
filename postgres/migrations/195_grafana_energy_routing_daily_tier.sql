-- ============================================================================
-- Migration 195
-- Extend Grafana energy routing to the daily tier
--
-- analytics.resolve_grafana_energy_routing_resolution (migration 044,
-- corrected by migration 045) currently only ever returns 'native', '15m',
-- or '1h' -- ranges beyond 14 days fall through to '1h' unconditionally,
-- with no upper bound. Migration 044's original version did include a '1d'
-- branch (<=24h -> 15m, <=14d -> 1h, >14d -> 1d); it was dropped when
-- migration 045 shifted every bracket one tier finer to fix coarseness,
-- rather than re-added at a new outer boundary.
--
-- Every object needed to serve the daily tier already exists and is
-- already correct: analytics.get_canonical_energy_read's '1d' branch reads
-- analytics.v_energy_reporting_daily, which is derived only from the
-- 15-minute semantic contract (Phase 1B invariant; never from the hourly
-- tier). This migration only adds the missing routing branch so long
-- ranges actually reach it.
--
-- Updated thresholds:
--   <=24h      -> native  (unchanged)
--   <=14 days  -> 15m     (unchanged)
--   <=90 days  -> 1h      (unchanged upper bound added at 90 days)
--   >90 days   -> 1d      (new)
--
-- No other object changes. analytics.get_grafana_asset_energy_intervals and
-- analytics.get_grafana_assets_energy_intervals both call this helper by
-- reference, so their behavior updates automatically with no signature,
-- grant, or dashboard change.
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
    WHEN p_to - p_from <= INTERVAL '90 days'  THEN '1h'
    ELSE '1d'
END;
$function$;


COMMENT ON FUNCTION analytics.resolve_grafana_energy_routing_resolution(
    TIMESTAMPTZ,
    TIMESTAMPTZ
)
IS
'Maps a Grafana panel time range to a canonical reporting resolution tier: <=24h -> native, <=14d -> 15m, <=90d -> 1h, >90d -> 1d. Pure function shared by analytics.get_grafana_asset_energy_intervals and analytics.get_grafana_assets_energy_intervals.';


ALTER FUNCTION analytics.resolve_grafana_energy_routing_resolution(
    TIMESTAMPTZ,
    TIMESTAMPTZ
)
OWNER TO ems_admin;


REVOKE ALL
ON FUNCTION analytics.resolve_grafana_energy_routing_resolution(
    TIMESTAMPTZ,
    TIMESTAMPTZ
)
FROM PUBLIC;

-- Internal helper only, invoked from within the two SECURITY DEFINER
-- functions that call it (both owned by ems_admin). Not exposed to Grafana
-- or app roles directly -- no compensating GRANT is added, matching the
-- function's existing posture since migration 044.
