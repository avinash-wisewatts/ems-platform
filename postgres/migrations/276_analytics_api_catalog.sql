-- ============================================================================
-- Migration 276
-- Analytics v1 catalogue read (ADR-022, step B1): the portal-scoped read
-- behind GET /api/v1/sites/{site_id}/analytics/catalog.
--
-- analytics.get_portal_analytics_catalog(p_portal_user_id, p_site_id)
-- returns one row per (ACTIVE asset of the site, semantic parameter,
-- qualifier) that a CURRENTLY EFFECTIVE metadata.asset_points row binds.
--
-- Rules implemented here (ADR-018 decisions 1/2/11, ADR-022):
--   * Availability comes from metadata.asset_points only -- never from
--     device capability, device profile, PRIMARY_METER or
--     analytics.v_grafana_asset_point_selector.
--   * Currently effective only: effective_range @> now().
--   * ACTIVE assets only (ADR-022 decision 6).
--   * Semantic points only: the logical point must map to a
--     config.parameters row (no raw tags -- EMS-REQ-903). The application
--     layer further restricts rows to its curated Analytics data-point
--     registry (ADR-022 decision 2).
--   * Tenant scope: the site must pass admin.portal_user_can_access_site,
--     and asset identity/location fields come from the existing
--     portal-scoped admin.list_accessible_assets (the same read the
--     /api/v1 asset list uses), so every returned row is doubly scoped.
--
-- attribution_basis is internal read-model metadata (ADR-022 decision 4):
-- 'PARITY_BRIDGE' for an assignment with effective_from = '-infinity' (the
-- staging-only parity-bridge rows written before migration 263; the
-- designed assignment/commissioning flow always writes a finite
-- effective_from), otherwise 'CONFIRMED'. The customer API does not expose
-- it. This function never writes metadata.asset_points or anything else.
--
-- Rollback: DROP FUNCTION analytics.get_portal_analytics_catalog(bigint, uuid);
-- ============================================================================

DO $pre$
BEGIN
    IF to_regprocedure('admin.portal_user_can_access_site(bigint, uuid)') IS NULL THEN
        RAISE EXCEPTION 'Migration 276 precondition failed: admin.portal_user_can_access_site(bigint, uuid) is missing.';
    END IF;
    IF to_regprocedure('admin.list_accessible_assets(bigint)') IS NULL THEN
        RAISE EXCEPTION 'Migration 276 precondition failed: admin.list_accessible_assets(bigint) is missing.';
    END IF;
    IF NOT EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema = 'metadata' AND table_name = 'asset_points' AND column_name = 'device_id'
    ) THEN
        RAISE EXCEPTION 'Migration 276 precondition failed: metadata.asset_points.device_id is missing (migration 228).';
    END IF;
    IF NOT EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema = 'metadata' AND table_name = 'logical_points' AND column_name = 'qualifier'
    ) THEN
        RAISE EXCEPTION 'Migration 276 precondition failed: metadata.logical_points.qualifier is missing (migration 223).';
    END IF;
END;
$pre$;

CREATE OR REPLACE FUNCTION analytics.get_portal_analytics_catalog
(
    p_portal_user_id BIGINT,
    p_site_id        UUID
)
RETURNS TABLE
(
    asset_id          UUID,
    asset_name        TEXT,
    asset_type_id     UUID,
    asset_type_name   TEXT,
    building_name     TEXT,
    floor_name        TEXT,
    space_id          UUID,
    space_name        TEXT,
    location_path     TEXT,
    data_point        TEXT,
    data_point_name   TEXT,
    category          TEXT,
    unit              TEXT,
    qualifier         TEXT,
    attribution_basis TEXT
)
LANGUAGE plpgsql
SECURITY DEFINER
STABLE
SET search_path TO pg_catalog, analytics, admin, metadata, config
AS $function$
BEGIN
    IF NOT admin.portal_user_can_access_site(p_portal_user_id, p_site_id) THEN
        RETURN;
    END IF;

    RETURN QUERY
    SELECT DISTINCT ON (la.asset_id, p.code, lp.qualifier)
        la.asset_id,
        la.asset_name,
        la.asset_type_id,
        la.asset_type_name,
        la.building_name,
        la.floor_name,
        la.space_id,
        la.space_name,
        la.location_path,
        p.code::TEXT,
        p.name::TEXT,
        pc.name::TEXT,
        COALESCE(pu.symbol, lu.symbol)::TEXT,
        lp.qualifier::TEXT,
        CASE WHEN ap.effective_from = '-infinity'::timestamptz
             THEN 'PARITY_BRIDGE' ELSE 'CONFIRMED' END
    FROM admin.list_accessible_assets(p_portal_user_id) AS la
    JOIN metadata.assets AS a
      ON a.id = la.asset_id
    JOIN metadata.asset_points AS ap
      ON ap.asset_id = a.id
     AND ap.organization_id = a.organization_id
     AND ap.effective_range @> now()
    JOIN metadata.logical_points AS lp
      ON lp.id = ap.logical_point_id
    JOIN config.parameters AS p
      ON p.id = lp.parameter_id
    LEFT JOIN config.point_categories AS pc
      ON pc.id = p.parameter_category_id
    LEFT JOIN config.engineering_units AS pu
      ON pu.id = p.unit_id
    LEFT JOIN config.engineering_units AS lu
      ON lu.id = lp.unit_id
    WHERE la.site_id = p_site_id
      AND a.site_id = p_site_id
      AND a.lifecycle_status = 'ACTIVE'
    -- A parameter/qualifier bound on two devices at once for one asset is
    -- one catalogue entry; prefer a CONFIRMED binding's classification.
    ORDER BY la.asset_id, p.code, lp.qualifier,
             (ap.effective_from = '-infinity'::timestamptz), ap.effective_from DESC;
END;
$function$;

ALTER FUNCTION analytics.get_portal_analytics_catalog(BIGINT, UUID) OWNER TO ems_admin;
REVOKE ALL ON FUNCTION analytics.get_portal_analytics_catalog(BIGINT, UUID) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION analytics.get_portal_analytics_catalog(BIGINT, UUID) TO ems_app;

COMMENT ON FUNCTION analytics.get_portal_analytics_catalog(BIGINT, UUID) IS
'Analytics v1 catalogue (migration 276, ADR-022): one row per ACTIVE asset of the site x semantic parameter x qualifier bound by a currently effective metadata.asset_points row. Portal-scoped (portal_user_can_access_site + list_accessible_assets). attribution_basis (CONFIRMED | PARITY_BRIDGE) is internal read-model metadata and is not exposed by the customer API. Read-only.';

DO $post$
DECLARE
    v_sig  TEXT := 'analytics.get_portal_analytics_catalog(bigint, uuid)';
    v_body TEXT;
BEGIN
    IF to_regprocedure(v_sig) IS NULL THEN
        RAISE EXCEPTION 'Migration 276 postcondition failed: % was not created.', v_sig;
    END IF;
    IF NOT EXISTS (
        SELECT 1 FROM pg_proc p
        JOIN pg_roles r ON r.oid = p.proowner
        WHERE p.oid = v_sig::regprocedure
          AND p.prosecdef
          AND p.provolatile = 's'
          AND r.rolname = 'ems_admin'
          AND p.proconfig IS NOT NULL
    ) THEN
        RAISE EXCEPTION 'Migration 276 postcondition failed: % is not SECURITY DEFINER / STABLE / owned by ems_admin / search_path-pinned.', v_sig;
    END IF;
    IF has_function_privilege('public', v_sig, 'EXECUTE') THEN
        RAISE EXCEPTION 'Migration 276 postcondition failed: % is executable by PUBLIC.', v_sig;
    END IF;
    IF NOT has_function_privilege('ems_app', v_sig, 'EXECUTE') THEN
        RAISE EXCEPTION 'Migration 276 postcondition failed: % is not executable by ems_app.', v_sig;
    END IF;
    v_body := lower(pg_get_functiondef(v_sig::regprocedure));
    IF position('insert into' IN v_body) > 0
       OR position('update ' IN v_body) > 0
       OR position('delete from' IN v_body) > 0
       OR position(' merge ' IN v_body) > 0
       OR position('execute ' IN v_body) > 0
       OR position('format(' IN v_body) > 0 THEN
        RAISE EXCEPTION 'Migration 276 postcondition failed: the catalogue function contains a write statement or dynamic SQL.';
    END IF;
    IF position('primary_meter' IN v_body) > 0
       OR position('asset_devices' IN v_body) > 0
       OR position('device_point_configuration' IN v_body) > 0
       OR position('v_grafana_asset_point_selector' IN v_body) > 0 THEN
        RAISE EXCEPTION 'Migration 276 postcondition failed: the catalogue must derive availability from metadata.asset_points only (ADR-018 decision 1).';
    END IF;
    IF position('portal_user_can_access_site' IN v_body) = 0
       OR position('list_accessible_assets' IN v_body) = 0
       OR position('lifecycle_status = ''active''' IN v_body) = 0 THEN
        RAISE EXCEPTION 'Migration 276 postcondition failed: the catalogue must be portal-scoped and ACTIVE-only.';
    END IF;
    RAISE NOTICE 'Migration 276: all postconditions passed (portal-scoped Analytics catalogue read function created; read-only).';
END;
$post$;
