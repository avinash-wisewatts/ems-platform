-- ============================================================================
-- Migration 244
-- Asset View (WiseWatts dashboard redesign) -- portal-user-scoped asset
-- energy interval read for the /api/v1 Analytics API's new
-- GET /sites/{site_id}/assets/{asset_id}/energy/consumption endpoint.
--
-- Source of record: this session's Asset View "Energy" tile -- total
-- energy for the selected time range, compared against the immediately
-- preceding window of the same length (e.g. "1 Hour" compares against the
-- previous 1-hour window). No new energy-calculation logic is introduced:
-- this migration ADDS a thin, portal-user-scoped wrapper around the
-- existing, unmodified analytics.get_grafana_asset_energy_intervals
-- (itself unmodified since it was created), which in turn reads the
-- existing analytics.get_canonical_energy_read (619 lines, unmodified,
-- unread-into by this migration beyond confirming it exists).
--
-- Why a wrapper, not a new implementation: analytics.get_grafana_asset_-
-- energy_intervals takes p_grafana_org_id as its tenant key (verified this
-- session: get_canonical_energy_read joins metadata.grafana_organization_map
-- and filters several CTEs on grafana_org_id throughout its body). The
-- customer-facing /api/v1 API has no Grafana org id -- it authenticates by
-- portal_user_id. This function resolves the asset's real organization_id,
-- looks up that organization's grafana_org_id via the existing 1:1
-- metadata.grafana_organization_map (UNIQUE on organization_id -- verified
-- this session, cannot fan out), and only proceeds if
-- admin.portal_user_can_access_site (the same tenant check every other
-- portal-scoped function in this API already uses) allows it. A caller who
-- cannot access the asset's site gets ZERO ROWS, matching every other
-- function in this family -- never an error, never another caller's data.
--
-- What this migration does (ADDITIVE ONLY):
--   One new function in schema analytics:
--
--   analytics.get_portal_asset_energy_intervals(bigint, uuid, timestamptz,
--     timestamptz) RETURNS TABLE(interval_start, device_id, device_name,
--     elapsed_minutes, import_consumption_kwh, export_consumption_kwh,
--     import_quality_code, export_quality_code, reset_detected,
--     gap_detected) -- the exact same row shape
--     analytics.get_grafana_asset_energy_intervals already returns,
--     unchanged.
--
--     * SECURITY DEFINER, STABLE, pinned SET search_path,
--     * REVOKE ALL FROM PUBLIC, GRANT EXECUTE TO ems_app, OWNER ems_admin,
--     * tenant scope via admin.portal_user_can_access_site(bigint, uuid),
--       re-derived server-side, never trusting a client-supplied
--       organization/grafana id.
--
-- What this migration does NOT do:
--   * Does NOT modify analytics.get_grafana_asset_energy_intervals,
--     analytics.get_canonical_energy_read, or any object either reads.
--   * Does NOT add a resolution parameter -- the wrapped function already
--     auto-selects resolution via
--     analytics.resolve_grafana_energy_routing_resolution(from, to)
--     internally; duplicating that choice here would risk disagreeing with
--     it.
--   * Does NOT touch Demand, Power Quality, or any other reader of
--     get_canonical_energy_read.
--
-- Rollback: DROP FUNCTION analytics.get_portal_asset_energy_intervals
-- (bigint, uuid, timestamptz, timestamptz); safe, no existing object is
-- altered by this migration.
--
-- New app tests: app/tests/test_analytics_api_v1_asset_energy_routes.py.
-- ============================================================================


-- ----------------------------------------------------------------------------
-- Preconditions.
-- ----------------------------------------------------------------------------
DO $pre$
BEGIN
    IF to_regprocedure('admin.portal_user_can_access_site(bigint, uuid)') IS NULL THEN
        RAISE EXCEPTION 'Migration 244 precondition failed: admin.portal_user_can_access_site(bigint, uuid) is missing.';
    END IF;

    IF to_regprocedure(
        'analytics.get_grafana_asset_energy_intervals(bigint, uuid, timestamptz, timestamptz)'
    ) IS NULL THEN
        RAISE EXCEPTION 'Migration 244 precondition failed: analytics.get_grafana_asset_energy_intervals is missing.';
    END IF;

    IF to_regclass('metadata.grafana_organization_map') IS NULL THEN
        RAISE EXCEPTION 'Migration 244 precondition failed: metadata.grafana_organization_map is missing.';
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM pg_constraint
        WHERE conrelid = 'metadata.grafana_organization_map'::regclass
          AND contype = 'u'
          AND conkey = ARRAY[(
              SELECT attnum FROM pg_attribute
              WHERE attrelid = 'metadata.grafana_organization_map'::regclass
                AND attname = 'organization_id'
          )]
    ) THEN
        RAISE EXCEPTION 'Migration 244 precondition failed: metadata.grafana_organization_map has no UNIQUE constraint on organization_id -- the 1:1 assumption this migration relies on is not guaranteed.';
    END IF;
END;
$pre$;


-- ----------------------------------------------------------------------------
-- 1. analytics.get_portal_asset_energy_intervals(bigint, uuid, timestamptz, timestamptz)
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION analytics.get_portal_asset_energy_intervals
(
    p_portal_user_id BIGINT,
    p_asset_id       UUID,
    p_from           TIMESTAMPTZ,
    p_to             TIMESTAMPTZ
)
RETURNS TABLE
(
    interval_start          TIMESTAMPTZ,
    device_id               UUID,
    device_name             TEXT,
    elapsed_minutes         NUMERIC,
    import_consumption_kwh  NUMERIC,
    export_consumption_kwh  NUMERIC,
    import_quality_code     TEXT,
    export_quality_code     TEXT,
    reset_detected           BOOLEAN,
    gap_detected             BOOLEAN
)
LANGUAGE sql
SECURITY DEFINER
STABLE
SET search_path TO pg_catalog, analytics, admin, metadata
AS $function$
    WITH authorized_asset AS (
        SELECT a.organization_id
        FROM metadata.assets AS a
        WHERE a.id = p_asset_id
          AND admin.portal_user_can_access_site(p_portal_user_id, a.site_id)
    ),
    resolved_grafana_org AS (
        SELECT gom.grafana_org_id
        FROM authorized_asset AS aa
        JOIN metadata.grafana_organization_map AS gom
          ON gom.organization_id = aa.organization_id
         AND gom.is_active
    )
    SELECT r.*
    FROM resolved_grafana_org AS rgo
    CROSS JOIN LATERAL analytics.get_grafana_asset_energy_intervals(
        rgo.grafana_org_id, p_asset_id, p_from, p_to
    ) AS r;
$function$;

ALTER FUNCTION analytics.get_portal_asset_energy_intervals(BIGINT, UUID, TIMESTAMPTZ, TIMESTAMPTZ) OWNER TO ems_admin;
REVOKE ALL ON FUNCTION analytics.get_portal_asset_energy_intervals(BIGINT, UUID, TIMESTAMPTZ, TIMESTAMPTZ) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION analytics.get_portal_asset_energy_intervals(BIGINT, UUID, TIMESTAMPTZ, TIMESTAMPTZ) TO ems_app;


-- ----------------------------------------------------------------------------
-- Postconditions.
-- ----------------------------------------------------------------------------
DO $post$
BEGIN
    IF to_regprocedure(
        'analytics.get_portal_asset_energy_intervals(bigint, uuid, timestamptz, timestamptz)'
    ) IS NULL THEN
        RAISE EXCEPTION 'Migration 244 postcondition failed: analytics.get_portal_asset_energy_intervals was not created.';
    END IF;

    RAISE NOTICE 'Migration 244: all postconditions passed (portal-scoped asset energy interval read function created).';
END;
$post$;
