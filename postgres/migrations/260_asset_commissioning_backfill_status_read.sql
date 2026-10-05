-- ============================================================================
-- Migration 260
-- Asset Data Point Assignment Admin Portal UI -- read-only backfill status
-- for the Asset Detail page. Additive only; no write path, no schema
-- change.
--
-- Gap found during the UI-architecture investigation: migrations 256-258
-- added the durable metadata.asset_commissioning_backfill table and the
-- worker/activation functions that write it, but no admin-schema read
-- function exists yet -- every other read in this application goes
-- through a dedicated, permission-checked, SECURITY DEFINER admin.*
-- function (admin.list_accessible_asset_device_relationships, admin.
-- list_asset_point_assignment_candidates, admin.list_accessible_
-- commissioning_readiness, ...); reading the table directly from
-- application code would be the first exception to that convention. This
-- migration adds the missing read function instead.
--
-- Shape: mirrors admin.list_asset_point_assignment_candidates (migration
-- 253) exactly -- portal-scoped via admin.portal_user_can_access_asset,
-- STABLE, SECURITY DEFINER, zero rows for an inaccessible/nonexistent
-- asset or an asset with no backfill record yet (never an error, never a
-- partial view). Returns only what the Asset Detail UI needs to display
-- (status/timestamps/error) -- trigger_audit_transaction_id and
-- triggered_by_portal_user_id are audit-trail internals, not UI-facing,
-- and are deliberately omitted.
-- ============================================================================

CREATE OR REPLACE FUNCTION admin.get_asset_commissioning_backfill_status(
    p_actor_portal_user_id BIGINT,
    p_asset_id UUID
)
RETURNS TABLE (
    status TEXT,
    requested_at TIMESTAMPTZ,
    started_at TIMESTAMPTZ,
    completed_at TIMESTAMPTZ,
    failed_at TIMESTAMPTZ,
    attempt_count INTEGER,
    last_error TEXT
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path TO pg_catalog, admin, metadata
AS $function$
    SELECT
        b.status,
        b.requested_at,
        b.started_at,
        b.completed_at,
        b.failed_at,
        b.attempt_count,
        b.last_error
    FROM metadata.asset_commissioning_backfill AS b
    WHERE b.asset_id = p_asset_id
      AND admin.portal_user_can_access_asset(p_actor_portal_user_id, p_asset_id);
$function$;

COMMENT ON FUNCTION admin.get_asset_commissioning_backfill_status(BIGINT, UUID) IS
'Migration 260: portal-scoped, read-only commissioning/backfill status for the Asset Detail UI. At most one row (metadata.asset_commissioning_backfill.asset_id is UNIQUE, migration 256). Zero rows for a caller admin.portal_user_can_access_asset rejects, or an asset with no backfill record yet (never commissioned via the Save flow) -- never an error. Writes nothing; the worker (migration 257) and activation function (migration 258) remain the only writers of this table.';

ALTER FUNCTION admin.get_asset_commissioning_backfill_status(BIGINT, UUID) OWNER TO ems_admin;
REVOKE ALL ON FUNCTION admin.get_asset_commissioning_backfill_status(BIGINT, UUID) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION admin.get_asset_commissioning_backfill_status(BIGINT, UUID) TO ems_app;


-- ----------------------------------------------------------------------------
-- Postconditions.
-- ----------------------------------------------------------------------------

DO $post$
DECLARE
    v_sig TEXT := 'admin.get_asset_commissioning_backfill_status(bigint, uuid)';
BEGIN
    IF has_function_privilege('public', v_sig, 'EXECUTE') THEN
        RAISE EXCEPTION 'Migration 260 postcondition failed: % is executable by PUBLIC.', v_sig;
    END IF;
    IF NOT has_function_privilege('ems_app', v_sig, 'EXECUTE') THEN
        RAISE EXCEPTION 'Migration 260 postcondition failed: % is not executable by ems_app.', v_sig;
    END IF;

    RAISE NOTICE 'Migration 260: all postconditions passed (admin.get_asset_commissioning_backfill_status deployed, portal-scoped, PUBLIC-revoked).';
END;
$post$;
