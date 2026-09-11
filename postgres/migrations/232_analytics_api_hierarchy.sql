-- ============================================================================
-- Migration 232
-- Slice 0 (Hierarchy Foundation) -- read-only, portal-user-scoped Space and
-- Asset listing for the /api/v1 Analytics API.
--
-- Source of record:
--   docs/product/ems-product-owner-workshop-baseline.md Q51/Q58/Q99/Q100
--     (Site -> Space -> Asset drill-down is core MVP scope).
--   Approved implementation decision pack (Slice 0 review): "basic Asset
--     list/detail... already well-supported by the existing data model and
--     access-control pattern" -- metadata.assets and metadata.spaces are
--     both fully modelled today; only the read-API surface is missing.
--
-- What this migration does (ADDITIVE ONLY, same pattern as migration 231):
--   Two new functions in schema analytics, each:
--     * SECURITY DEFINER, STABLE, explicit parameter + return types,
--     * pinned SET search_path, no dynamic SQL,
--     * REVOKE ALL FROM PUBLIC, GRANT EXECUTE TO ems_app, OWNER ems_admin,
--     * tenant scope re-derived server-side via the established
--       admin.portal_user_can_access_site(bigint, uuid) function -- a caller
--       that cannot see the site gets ZERO ROWS, never an error.
--
--   1. analytics.list_portal_site_spaces(bigint, uuid)
--        RETURNS TABLE(space_id uuid, site_id uuid, space_code text,
--                      space_name text)
--        Resolves site_id via metadata.spaces -> floors -> buildings, the
--        same join path analytics.portal_user_can_access_space (migration
--        231) already uses. No is_active filter exists on metadata.spaces
--        today, so none is applied here.
--
--   2. analytics.list_portal_site_assets(bigint, uuid)
--        RETURNS TABLE(asset_id uuid, site_id uuid, space_id uuid,
--                      parent_asset_id uuid, external_id text,
--                      asset_name text, lifecycle_status text)
--        Reads metadata.assets directly (site_id is a direct NOT NULL FK).
--        space_id and parent_asset_id are passed through as-is (both
--        nullable) -- physical placement and parent grouping only; NO
--        relationship-type join (metadata.asset_relationships) is read here.
--
-- What this migration does NOT do:
--   * No change to any existing v_grafana_* object, migration-231 function,
--     energy table/job, Phase 6 object, or Grafana provisioning.
--   * No new table, hypertable, TimescaleDB job, trigger, or grant to
--     PUBLIC/grafana_reader.
--   * No asset-relationship, asset-component-tree, or "spaces served by an
--     asset" read path -- explicitly deferred per the approved decision
--     pack pending a separate product/architecture confirmation (no such
--     relationship exists in the schema today; metadata.assets.space_id is
--     a single nullable FK, not an M:N relationship).
--   * No write statement anywhere in either function body.
--
-- Transaction: NO BEGIN/COMMIT of its own -- scripts/apply_migrations.sh
--   wraps the file + the ledger INSERT in one transaction (matches 223-231).
--
-- Rollback: postgres/maintenance/232_analytics_api_hierarchy_rollback.sql
--   -- dependency-checked, no CASCADE, safe if never applied.
--
-- NOT APPLIED as part of this implementation increment -- source-code /
-- migration-file change only, per explicit instruction. No remote or local
-- database write occurs from authoring this file.
-- ============================================================================


-- ----------------------------------------------------------------------------
-- Preconditions -- this migration depends on migration 104 (three-role scope
-- model) and the base metadata hierarchy already being present.
-- ----------------------------------------------------------------------------
DO $pre$
BEGIN
    IF to_regprocedure('admin.portal_user_can_access_site(bigint, uuid)') IS NULL THEN
        RAISE EXCEPTION 'Migration 232 precondition failed: admin.portal_user_can_access_site(bigint, uuid) is missing (three-role scope model).';
    END IF;

    IF to_regclass('metadata.spaces')    IS NULL
       OR to_regclass('metadata.floors') IS NULL
       OR to_regclass('metadata.buildings') IS NULL THEN
        RAISE EXCEPTION 'Migration 232 precondition failed: metadata.spaces / floors / buildings not all present.';
    END IF;

    IF to_regclass('metadata.assets') IS NULL THEN
        RAISE EXCEPTION 'Migration 232 precondition failed: metadata.assets is missing.';
    END IF;
END;
$pre$;


-- ----------------------------------------------------------------------------
-- 1. analytics.list_portal_site_spaces(bigint, uuid)
--    Site-scoped Space list. Empty for an inaccessible or unknown site.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION analytics.list_portal_site_spaces
(
    p_portal_user_id BIGINT,
    p_site_id        UUID
)
RETURNS TABLE
(
    space_id   UUID,
    site_id    UUID,
    space_code TEXT,
    space_name TEXT
)
LANGUAGE SQL
SECURITY DEFINER
STABLE
SET search_path TO pg_catalog, analytics, admin, metadata
AS $function$
    SELECT
        space_record.id,
        building_record.site_id,
        space_record.code,
        space_record.name
    FROM metadata.spaces AS space_record
    JOIN metadata.floors AS floor_record
      ON floor_record.id = space_record.floor_id
    JOIN metadata.buildings AS building_record
      ON building_record.id = floor_record.building_id
    WHERE building_record.site_id = p_site_id
      AND admin.portal_user_can_access_site(p_portal_user_id, p_site_id)
    ORDER BY space_record.name, space_record.id;
$function$;

ALTER FUNCTION analytics.list_portal_site_spaces(BIGINT, UUID) OWNER TO ems_admin;
REVOKE ALL ON FUNCTION analytics.list_portal_site_spaces(BIGINT, UUID) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION analytics.list_portal_site_spaces(BIGINT, UUID) TO ems_app;


-- ----------------------------------------------------------------------------
-- 2. analytics.list_portal_site_assets(bigint, uuid)
--    Site-scoped Asset list. Empty for an inaccessible or unknown site.
--    Placement (space_id) and parent grouping (parent_asset_id) only --
--    NO relationship-type traversal.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION analytics.list_portal_site_assets
(
    p_portal_user_id BIGINT,
    p_site_id        UUID
)
RETURNS TABLE
(
    asset_id         UUID,
    site_id          UUID,
    space_id         UUID,
    parent_asset_id  UUID,
    external_id      TEXT,
    asset_name       TEXT,
    lifecycle_status TEXT
)
LANGUAGE SQL
SECURITY DEFINER
STABLE
SET search_path TO pg_catalog, analytics, admin, metadata
AS $function$
    SELECT
        asset_record.id,
        asset_record.site_id,
        asset_record.space_id,
        asset_record.parent_asset_id,
        asset_record.external_id,
        asset_record.name,
        asset_record.lifecycle_status
    FROM metadata.assets AS asset_record
    WHERE asset_record.site_id = p_site_id
      AND admin.portal_user_can_access_site(p_portal_user_id, p_site_id)
    ORDER BY asset_record.name, asset_record.id;
$function$;

ALTER FUNCTION analytics.list_portal_site_assets(BIGINT, UUID) OWNER TO ems_admin;
REVOKE ALL ON FUNCTION analytics.list_portal_site_assets(BIGINT, UUID) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION analytics.list_portal_site_assets(BIGINT, UUID) TO ems_app;


-- ----------------------------------------------------------------------------
-- Postconditions -- ownership/grant hygiene and read-only-body proof, same
-- discipline as migration 231 (scoped to what this migration touches).
-- ----------------------------------------------------------------------------
DO $post$
DECLARE
    v_sig  TEXT;
    v_body TEXT := '';
BEGIN
    FOR v_sig IN
        SELECT unnest(ARRAY[
            'analytics.list_portal_site_spaces(bigint, uuid)',
            'analytics.list_portal_site_assets(bigint, uuid)'
        ])
    LOOP
        IF NOT EXISTS (
            SELECT 1 FROM pg_proc p
            JOIN pg_roles r ON r.oid = p.proowner
            WHERE p.oid = v_sig::regprocedure
              AND p.prosecdef
              AND p.provolatile = 's'
              AND r.rolname = 'ems_admin'
              AND EXISTS (
                  SELECT 1 FROM unnest(coalesce(p.proconfig, ARRAY[]::text[])) AS c
                  WHERE c LIKE 'search_path=%'
              )
        ) THEN
            RAISE EXCEPTION 'Migration 232 postcondition failed: % is not SECURITY DEFINER / STABLE / owned by ems_admin / search_path-pinned.', v_sig;
        END IF;

        IF has_function_privilege('public', v_sig, 'EXECUTE') THEN
            RAISE EXCEPTION 'Migration 232 postcondition failed: % is executable by PUBLIC.', v_sig;
        END IF;
        IF NOT has_function_privilege('ems_app', v_sig, 'EXECUTE') THEN
            RAISE EXCEPTION 'Migration 232 postcondition failed: % is not executable by ems_app.', v_sig;
        END IF;
        IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'grafana_reader')
           AND has_function_privilege('grafana_reader', v_sig, 'EXECUTE') THEN
            RAISE EXCEPTION 'Migration 232 postcondition failed: % is executable by grafana_reader.', v_sig;
        END IF;

        v_body := v_body || lower(pg_get_functiondef(v_sig::regprocedure)) || E'\n';
    END LOOP;

    IF position('insert into' IN v_body) > 0
       OR position('update ' IN v_body) > 0
       OR position('delete from' IN v_body) > 0
       OR position(' merge ' IN v_body) > 0 THEN
        RAISE EXCEPTION 'Migration 232 postcondition failed: a hierarchy-listing function contains a write statement.';
    END IF;

    IF position('asset_relationships' IN v_body) > 0 THEN
        RAISE EXCEPTION 'Migration 232 postcondition failed: relationship traversal is out of scope for this increment.';
    END IF;

    RAISE NOTICE 'Migration 232: all postconditions passed (Space/Asset hierarchy listing created; read-only; no relationship traversal).';
END;
$post$;
