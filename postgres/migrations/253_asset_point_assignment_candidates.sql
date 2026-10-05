-- ============================================================================
-- Migration 253
-- Asset Data Point Assignment / Commissioning (ADR-018 Amendment 5) --
-- first read-focused slice: a persisted Asset-specific Friendly Name field
-- on metadata.asset_points, and the portal-scoped candidate-point read
-- function the Admin Portal's Assign Data Points UI will consume.
--
-- Scope, explicit (per this session's product decision):
--   * Add metadata.asset_points.friendly_name -- a genuinely new, empty
--     field. Not a repurposing of point_role: point_role is untouched
--     (confirmed this session, read-only, that no code anywhere -- app/,
--     web/src, scripts/test -- reads or writes point_role today; it is
--     safe to leave exactly as-is).
--   * Add admin.list_asset_point_assignment_candidates(actor, asset_id) --
--     a read-only, portal-tenant-scoped candidate/confirmation-state
--     query. Returns candidates from EVERY metadata.asset_devices
--     relationship type for the asset, never inferring point ownership
--     from PRIMARY_METER (ADR-018 Amendment 4).
--
-- Explicitly NOT in this slice: the assignment Save/write path (no
-- function writes metadata.asset_points), commissioning/backfill
-- triggering, and duplicate-semantic-source enforcement. All deferred to
-- later slices per ADR-018 Amendments 5/6/7 and this session's own
-- sequencing.
--
-- friendly_name length/validation convention: verified this session that
-- the closest existing analog -- metadata.asset_devices' own optional,
-- per-relationship descriptive text fields (panel_name, feeder_name,
-- breaker_identifier, channel_identifier, mounting_point,
-- engineering_notes) -- carry no DB-level CHECK constraint on length;
-- only the REQUIRED top-level assets.name/devices.name fields have a
-- 200-character ceiling, and that is enforced in their SECURITY DEFINER
-- write functions (admin.update_asset, etc.), not a table CHECK. friendly_
-- name is optional and per-assignment, the same shape as those asset_
-- devices fields, so it follows their convention here: plain nullable
-- TEXT, no CHECK constraint. Any length/format validation belongs to the
-- future write function (admin.assign_asset_points or similar, not built
-- in this slice), matching where devices.name's validation actually lives
-- today.
--
-- Candidate read function: mirrors the existing admin.list_accessible_*
-- SECURITY DEFINER read-function shape (admin.list_accessible_devices,
-- admin.list_accessible_asset_device_relationships, both migration 001)
-- and reuses analytics.v_grafana_asset_point_selector's (migration 172)
-- join pattern -- asset -> metadata.asset_devices (every relationship
-- type, unfiltered) -> config.device_point_configuration (enabled only)
-- -> metadata.logical_points -- but with portal-tenant authorization
-- (admin.portal_user_can_access_asset, migration 022) instead of that
-- view's Grafana-org scoping, and a LEFT JOIN to metadata.asset_points
-- (matched on device_id + logical_point_id + effective_range @> now())
-- to expose current confirmation state and friendly_name. Parameterized
-- by asset_id (unlike list_accessible_devices/relationships' "list
-- everything accessible, filter in application code" convention) --
-- deliberate: this read is invoked from exactly one asset's edit page,
-- and a single device profile was observed carrying 58 enabled points on
-- staging, so joining across every accessible asset would be wasteful for
-- no benefit here.
--
-- Rollback: DROP FUNCTION admin.list_asset_point_assignment_candidates
-- (BIGINT, UUID); ALTER TABLE metadata.asset_points DROP COLUMN
-- friendly_name -- safe, no other object references either.
-- ============================================================================

BEGIN;

-- ----------------------------------------------------------------------------
-- 1. metadata.asset_points.friendly_name.
-- ----------------------------------------------------------------------------

ALTER TABLE metadata.asset_points
    ADD COLUMN IF NOT EXISTS friendly_name TEXT;

COMMENT ON COLUMN metadata.asset_points.friendly_name IS
'Optional, Admin-set, Asset-specific display label for this confirmed point assignment (ADR-018 Amendment 5). NULL when never set. Distinct from and unrelated to point_role, which this migration does not touch. Preserved by future assignment edits unless explicitly changed by the actor -- not enforced by this migration (no write path exists yet); the future write function must carry it forward on an unrelated edit rather than clearing it.';

-- ----------------------------------------------------------------------------
-- 2. admin.list_asset_point_assignment_candidates(actor, asset_id).
-- ----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION admin.list_asset_point_assignment_candidates(
    p_actor_portal_user_id BIGINT,
    p_asset_id UUID
)
RETURNS TABLE (
    device_id UUID,
    device_name TEXT,
    relationship_type TEXT,
    relationship_type_name TEXT,
    logical_point_id UUID,
    logical_point_name TEXT,
    point_category_id UUID,
    point_category_name TEXT,
    unit_symbol TEXT,
    is_confirmed BOOLEAN,
    asset_point_id UUID,
    friendly_name TEXT,
    effective_from TIMESTAMPTZ,
    effective_to TIMESTAMPTZ
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path TO pg_catalog, admin, metadata, config
AS $function$
    SELECT
        d.id,
        d.name,
        ad.relationship_type,
        rt.name,
        lp.id,
        lp.name,
        pc.id,
        pc.name,
        eu.symbol,
        (ap.id IS NOT NULL),
        ap.id,
        ap.friendly_name,
        ap.effective_from,
        ap.effective_to
    FROM metadata.assets AS a
    JOIN metadata.asset_devices AS ad
      ON ad.asset_id = a.id
    JOIN metadata.devices AS d
      ON d.id = ad.device_id
    JOIN config.asset_device_relationship_types AS rt
      ON rt.code = ad.relationship_type
    JOIN config.device_point_configuration AS dpc
      ON dpc.device_id = d.id
     AND dpc.is_enabled
    JOIN metadata.logical_points AS lp
      ON lp.id = dpc.logical_point_id
    LEFT JOIN config.parameters AS pr
      ON pr.id = lp.parameter_id
    LEFT JOIN config.point_categories AS pc
      ON pc.id = pr.parameter_category_id
    LEFT JOIN config.engineering_units AS eu
      ON eu.id = lp.unit_id
    LEFT JOIN metadata.asset_points AS ap
      ON ap.asset_id = a.id
     AND ap.device_id = d.id
     AND ap.logical_point_id = lp.id
     AND ap.effective_range @> now()
    WHERE a.id = p_asset_id
      AND admin.portal_user_can_access_asset(p_actor_portal_user_id, p_asset_id)
    ORDER BY d.name, pc.name NULLS LAST, lp.name;
$function$;

COMMENT ON FUNCTION admin.list_asset_point_assignment_candidates(BIGINT, UUID) IS
'Portal-scoped, read-only candidate/confirmation-state query for the Assign Data Points flow (ADR-018 Amendment 5). Candidates come from EVERY metadata.asset_devices relationship type for the asset (never inferring point ownership from PRIMARY_METER, ADR-018 Amendment 4) with an enabled config.device_point_configuration row. is_confirmed/asset_point_id/friendly_name/effective_from/effective_to reflect the currently-effective metadata.asset_points row only (effective_range @> now()), never a historical/removed one. Zero rows for a caller admin.portal_user_can_access_asset rejects, or for an asset with no related devices -- never an error. Writes nothing; no assignment Save path exists yet.';

ALTER FUNCTION admin.list_asset_point_assignment_candidates(BIGINT, UUID) OWNER TO ems_admin;
REVOKE ALL ON FUNCTION admin.list_asset_point_assignment_candidates(BIGINT, UUID) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION admin.list_asset_point_assignment_candidates(BIGINT, UUID) TO ems_app;

-- ----------------------------------------------------------------------------
-- 3. Postconditions.
-- ----------------------------------------------------------------------------

DO $post$
DECLARE
    v_sig TEXT := 'admin.list_asset_point_assignment_candidates(bigint, uuid)';
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema = 'metadata'
          AND table_name = 'asset_points'
          AND column_name = 'friendly_name'
          AND is_nullable = 'YES'
    ) THEN
        RAISE EXCEPTION 'Migration 253 postcondition failed: metadata.asset_points.friendly_name does not exist as a nullable column.';
    END IF;

    IF has_function_privilege('public', v_sig, 'EXECUTE') THEN
        RAISE EXCEPTION 'Migration 253 postcondition failed: % is executable by PUBLIC.', v_sig;
    END IF;
    IF NOT has_function_privilege('ems_app', v_sig, 'EXECUTE') THEN
        RAISE EXCEPTION 'Migration 253 postcondition failed: % is not executable by ems_app.', v_sig;
    END IF;

    RAISE NOTICE 'Migration 253: all postconditions passed (metadata.asset_points.friendly_name added; admin.list_asset_point_assignment_candidates deployed, portal-scoped, PUBLIC-revoked).';
END;
$post$;

COMMIT;
