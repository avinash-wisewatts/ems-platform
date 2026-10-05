-- ============================================================================
-- Migration 259
-- Asset Data Point Assignment Admin Portal UI -- dedicated SQLSTATE for the
-- measurement-group conflict, so the Admin Portal can safely display this
-- one deliberately-authored validation message without loosening the
-- generic user_facing_database_error() allowlist for every other DatabaseError.
--
-- Investigation (see the session's UI-architecture report): admin.
-- save_asset_point_assignments() (migration 255, extended by migration 256)
-- raises 6 distinct conditions but only 5 SQLSTATEs -- the measurement-group
-- conflict reuses '23514' (check_violation), the SAME code as three other,
-- unrelated conditions in the same function (decommissioned asset,
-- device-not-associated, disabled/non-existent point). SQLSTATE alone
-- cannot distinguish the measurement-group conflict from those today. A
-- repo-wide scan of postgres/ found exactly 8 distinct SQLSTATEs in use
-- anywhere in this codebase, all standard PostgreSQL codes -- no existing
-- custom-SQLSTATE convention to reuse.
--
-- This migration changes exactly ONE line of the function (the measurement-
-- group conflict's ERRCODE, from '23514' to 'EM001') -- every other line is
-- byte-identical to migration 256's body. 'EM001' is this repository's
-- first custom (non-standard) SQLSTATE: class 'EM' does not collide with
-- any PostgreSQL-assigned error class (00-58, F0, HV, XX) or the
-- PL/pgSQL-reserved 'P0' class. Chosen to be unambiguous and trivially
-- greppable; a second custom code, if ever needed, would be 'EM002'.
--
-- Scope discipline: this is intentionally narrow. Only the measurement-
-- group conflict gets a dedicated code -- it is the one validation failure
-- genuinely reachable through normal Admin Portal usage (an admin checking
-- points that happen to collide across devices); the other 23514 uses
-- (decommissioned asset, device-not-associated, disabled point) are
-- defensive guards against a malformed/tampered request that the UI itself
-- already prevents by construction (it only ever offers enabled candidate
-- points on associated devices), so they are left exactly as migration 255
-- authored them and continue to fall through to the generic database-error
-- path, per this session's explicit instruction not to broaden the mapping
-- beyond the one known condition.
--
-- No other behavior changes: authorization, locking, payload validation,
-- the diff/mutation logic, the commissioning trigger, and the audit/result
-- shape are all unchanged from migration 256.
-- ============================================================================


CREATE OR REPLACE FUNCTION admin.save_asset_point_assignments(
    p_actor_portal_user_id BIGINT,
    p_asset_id             UUID,
    p_device_id            UUID,
    p_confirmed_points     JSONB DEFAULT '[]'::jsonb
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO pg_catalog, admin, metadata, config
AS $function$
DECLARE
    v_actor_username        TEXT;
    v_org_id                UUID;
    v_site_id               UUID;
    v_lifecycle_status      TEXT;
    v_payload_count         INTEGER;
    v_distinct_count        INTEGER;
    v_invalid_points        TEXT;
    v_conflicting_groups    TEXT;
    v_before_json           JSONB;
    v_removed_json          JSONB;
    v_added_json             JSONB;
    v_unchanged_json        JSONB;
    v_audit_id              UUID := gen_random_uuid();
    v_result                JSONB;
    v_backfill_id            UUID;
    v_commissioning_triggered BOOLEAN := FALSE;
BEGIN
    -- ------------------------------------------------------------------
    -- 1. Actor authorization.
    -- ------------------------------------------------------------------
    SELECT username
    INTO v_actor_username
    FROM admin.portal_users
    WHERE portal_user_id = p_actor_portal_user_id
      AND is_active = TRUE;

    IF NOT FOUND OR NOT admin.portal_user_has_permission(p_actor_portal_user_id, 'asset.manage') THEN
        RAISE EXCEPTION 'Portal actor is not authorized to manage asset point assignments.' USING ERRCODE = '42501';
    END IF;

    -- ------------------------------------------------------------------
    -- 2. Lock the asset row (concurrency safeguard -- serializes
    --    concurrent Saves against the same asset) and fetch its context.
    -- ------------------------------------------------------------------
    SELECT organization_id, site_id, lifecycle_status
    INTO v_org_id, v_site_id, v_lifecycle_status
    FROM metadata.assets
    WHERE id = p_asset_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Asset was not found.' USING ERRCODE = '22023';
    END IF;

    IF NOT admin.portal_user_can_access_asset(p_actor_portal_user_id, p_asset_id) THEN
        RAISE EXCEPTION 'Portal actor cannot access the selected asset.' USING ERRCODE = '42501';
    END IF;

    IF v_lifecycle_status = 'DECOMMISSIONED' THEN
        RAISE EXCEPTION 'Point assignments cannot be edited on a decommissioned asset.' USING ERRCODE = '23514';
    END IF;

    -- ------------------------------------------------------------------
    -- 3. Device must be associated with the asset (any relationship
    --    type -- never PRIMARY_METER-only, per ADR-018 Amendment 4).
    --    A device already associated via metadata.asset_devices is
    --    guaranteed same-organization with the asset (enforced at
    --    relationship-creation time by metadata.assert_asset_device_
    --    relationship), so no separate organization check is needed here.
    -- ------------------------------------------------------------------
    IF NOT EXISTS (
        SELECT 1 FROM metadata.asset_devices
        WHERE asset_id = p_asset_id AND device_id = p_device_id
    ) THEN
        RAISE EXCEPTION 'Device is not associated with this asset.' USING ERRCODE = '23514';
    END IF;

    -- ------------------------------------------------------------------
    -- 4. Payload sanity: every entry has a logical_point_id, and no
    --    logical_point_id is repeated within the payload.
    -- ------------------------------------------------------------------
    IF EXISTS (
        SELECT 1
        FROM jsonb_to_recordset(COALESCE(p_confirmed_points, '[]'::jsonb)) AS x(logical_point_id UUID, friendly_name TEXT)
        WHERE x.logical_point_id IS NULL
    ) THEN
        RAISE EXCEPTION 'Each submitted point must include a logical_point_id.' USING ERRCODE = '22023';
    END IF;

    SELECT count(*), count(DISTINCT x.logical_point_id)
    INTO v_payload_count, v_distinct_count
    FROM jsonb_to_recordset(COALESCE(p_confirmed_points, '[]'::jsonb)) AS x(logical_point_id UUID, friendly_name TEXT);

    IF v_payload_count <> v_distinct_count THEN
        RAISE EXCEPTION 'Duplicate logical_point_id in the submitted point assignments.' USING ERRCODE = '23505';
    END IF;

    -- ------------------------------------------------------------------
    -- 5. Every submitted point must be enabled/configured for this
    --    device (same candidate set migration 253's read path exposes).
    -- ------------------------------------------------------------------
    SELECT string_agg(x.logical_point_id::text, ', ')
    INTO v_invalid_points
    FROM jsonb_to_recordset(COALESCE(p_confirmed_points, '[]'::jsonb)) AS x(logical_point_id UUID, friendly_name TEXT)
    WHERE NOT EXISTS (
        SELECT 1 FROM config.device_point_configuration dpc
        WHERE dpc.device_id = p_device_id
          AND dpc.logical_point_id = x.logical_point_id
          AND dpc.is_enabled
    );

    IF v_invalid_points IS NOT NULL THEN
        RAISE EXCEPTION 'The following points are not enabled/configured for this device: %', v_invalid_points USING ERRCODE = '23514';
    END IF;

    -- ------------------------------------------------------------------
    -- 6. "Before" snapshot of this device's currently-effective confirmed
    --    points on this asset, for the audit row.
    -- ------------------------------------------------------------------
    SELECT jsonb_agg(jsonb_build_object(
               'asset_point_id', ap.id,
               'logical_point_id', ap.logical_point_id,
               'logical_point_name', lp.name,
               'friendly_name', ap.friendly_name
           ))
    INTO v_before_json
    FROM metadata.asset_points ap
    JOIN metadata.logical_points lp ON lp.id = ap.logical_point_id
    WHERE ap.asset_id = p_asset_id
      AND ap.device_id = p_device_id
      AND ap.effective_range @> now();

    -- ------------------------------------------------------------------
    -- 7. Measurement-group enforcement (data-driven, no hardcoded point/
    --    parameter names). "After-save" state = every OTHER device's
    --    currently-effective points on this asset, unioned with this
    --    Save's proposed full-replace set for p_device_id. Any governed
    --    group (measurement_group_id IS NOT NULL) contributed by more
    --    than one distinct device is rejected. NULL measurement_group_id
    --    is never subject to this check -- it is simply excluded by the
    --    join to config.parameters/canonical_measurement_groups below.
    --
    --    Migration 259: dedicated ERRCODE 'EM001' (was '23514') -- the
    --    one condition here that is genuinely reachable through normal
    --    Admin Portal usage, so the Admin Portal maps it to a safe,
    --    displayable message instead of the generic database-error
    --    fallback. See this migration's header.
    -- ------------------------------------------------------------------
    SELECT string_agg(DISTINCT conflict.group_name, ', ')
    INTO v_conflicting_groups
    FROM (
        SELECT g.name AS group_name, count(DISTINCT after_save.device_id) AS device_count
        FROM (
            SELECT lp.parameter_id, ap.device_id
            FROM metadata.asset_points ap
            JOIN metadata.logical_points lp ON lp.id = ap.logical_point_id
            WHERE ap.asset_id = p_asset_id
              AND ap.device_id <> p_device_id
              AND ap.effective_range @> now()

            UNION ALL

            SELECT lp.parameter_id, p_device_id AS device_id
            FROM jsonb_to_recordset(COALESCE(p_confirmed_points, '[]'::jsonb)) AS x(logical_point_id UUID, friendly_name TEXT)
            JOIN metadata.logical_points lp ON lp.id = x.logical_point_id
        ) after_save
        JOIN config.parameters cp ON cp.id = after_save.parameter_id
        JOIN config.canonical_measurement_groups g ON g.id = cp.measurement_group_id
        GROUP BY g.name
        HAVING count(DISTINCT after_save.device_id) > 1
    ) conflict;

    IF v_conflicting_groups IS NOT NULL THEN
        RAISE EXCEPTION 'This Save would confirm % from more than one device for this Asset; each measurement group must come from a single device.', v_conflicting_groups USING ERRCODE = 'EM001';
    END IF;

    -- ------------------------------------------------------------------
    -- 8. Apply the diff: REMOVE (close), SYNC (friendly-name in place,
    --    never re-dates effective_from), ADD (open new). Wrapped so a
    --    genuine concurrent-write race on the exclusion constraint
    --    (another Save just confirmed the same device/point elsewhere)
    --    surfaces a clear error instead of a raw constraint message.
    -- ------------------------------------------------------------------
    BEGIN
        WITH removed AS (
            UPDATE metadata.asset_points ap
            SET effective_to = now()
            WHERE ap.asset_id = p_asset_id
              AND ap.device_id = p_device_id
              AND ap.effective_range @> now()
              AND NOT EXISTS (
                  SELECT 1
                  FROM jsonb_to_recordset(COALESCE(p_confirmed_points, '[]'::jsonb)) AS x(logical_point_id UUID, friendly_name TEXT)
                  WHERE x.logical_point_id = ap.logical_point_id
              )
            RETURNING ap.id, ap.logical_point_id, ap.effective_to
        )
        SELECT jsonb_agg(jsonb_build_object(
                   'asset_point_id', removed.id,
                   'logical_point_id', removed.logical_point_id,
                   'logical_point_name', lp.name,
                   'closed_effective_to', removed.effective_to
               ))
        INTO v_removed_json
        FROM removed
        JOIN metadata.logical_points lp ON lp.id = removed.logical_point_id;

        WITH synced AS (
            UPDATE metadata.asset_points ap
            SET friendly_name = x.friendly_name_clean
            FROM (
                SELECT x.logical_point_id, nullif(btrim(x.friendly_name), '') AS friendly_name_clean
                FROM jsonb_to_recordset(COALESCE(p_confirmed_points, '[]'::jsonb)) AS x(logical_point_id UUID, friendly_name TEXT)
            ) x
            WHERE ap.asset_id = p_asset_id
              AND ap.device_id = p_device_id
              AND ap.logical_point_id = x.logical_point_id
              AND ap.effective_range @> now()
            RETURNING ap.id, ap.logical_point_id, ap.friendly_name
        )
        SELECT jsonb_agg(jsonb_build_object(
                   'asset_point_id', synced.id,
                   'logical_point_id', synced.logical_point_id,
                   'logical_point_name', lp.name,
                   'friendly_name', synced.friendly_name
               ))
        INTO v_unchanged_json
        FROM synced
        JOIN metadata.logical_points lp ON lp.id = synced.logical_point_id;

        WITH added AS (
            INSERT INTO metadata.asset_points (
                asset_id, device_id, logical_point_id, organization_id,
                friendly_name, effective_from, effective_to
            )
            SELECT p_asset_id, p_device_id, x.logical_point_id, v_org_id,
                   nullif(btrim(x.friendly_name), ''), now(), NULL
            FROM jsonb_to_recordset(COALESCE(p_confirmed_points, '[]'::jsonb)) AS x(logical_point_id UUID, friendly_name TEXT)
            WHERE NOT EXISTS (
                SELECT 1 FROM metadata.asset_points ap2
                WHERE ap2.asset_id = p_asset_id
                  AND ap2.device_id = p_device_id
                  AND ap2.logical_point_id = x.logical_point_id
                  AND ap2.effective_range @> now()
            )
            RETURNING id, logical_point_id, friendly_name
        )
        SELECT jsonb_agg(jsonb_build_object(
                   'asset_point_id', added.id,
                   'logical_point_id', added.logical_point_id,
                   'logical_point_name', lp.name,
                   'friendly_name', added.friendly_name
               ))
        INTO v_added_json
        FROM added
        JOIN metadata.logical_points lp ON lp.id = added.logical_point_id;

    EXCEPTION
        WHEN exclusion_violation THEN
            RAISE EXCEPTION 'One or more selected points were just confirmed by another assignment. Refresh and try again.' USING ERRCODE = '23P01';
    END;

    -- ------------------------------------------------------------------
    -- 9. First-assignment commissioning trigger (ADR-018 Amendment 6,
    --    corrected by Amendment 12). Only when this Save actually added
    --    at least one confirmed point, AND no backfill record has ever
    --    been created for this asset (see migration 256's header for why
    --    this -- not a live currently-effective-row count -- is the
    --    correct, ADR-faithful "first successful assignment" signal,
    --    including for a re-assignment after a full prior removal).
    --    INSERT ... ON CONFLICT (asset_id) DO NOTHING makes this
    --    race-safe under concurrent Saves: only the call that actually
    --    inserts a new row flips lifecycle_status.
    -- ------------------------------------------------------------------
    IF v_added_json IS NOT NULL AND jsonb_array_length(v_added_json) > 0 THEN
        INSERT INTO metadata.asset_commissioning_backfill (
            asset_id, status, triggered_by_portal_user_id, trigger_audit_transaction_id
        )
        VALUES (p_asset_id, 'PENDING', p_actor_portal_user_id, v_audit_id)
        ON CONFLICT (asset_id) DO NOTHING
        RETURNING id INTO v_backfill_id;

        IF v_backfill_id IS NOT NULL THEN
            UPDATE metadata.assets
            SET lifecycle_status = 'COMMISSIONING', updated_at = now()
            WHERE id = p_asset_id
              AND lifecycle_status NOT IN ('ACTIVE', 'COMMISSIONING', 'DECOMMISSIONED');

            v_commissioning_triggered := TRUE;
        END IF;
    END IF;

    -- ------------------------------------------------------------------
    -- 10. Result + audit.
    -- ------------------------------------------------------------------
    v_result := jsonb_build_object(
        'success', TRUE,
        'asset_id', p_asset_id,
        'device_id', p_device_id,
        'added', COALESCE(v_added_json, '[]'::jsonb),
        'removed', COALESCE(v_removed_json, '[]'::jsonb),
        'unchanged', COALESCE(v_unchanged_json, '[]'::jsonb),
        'commissioning_triggered', v_commissioning_triggered,
        'backfill_record_id', v_backfill_id,
        'audit_transaction_id', v_audit_id
    );

    INSERT INTO admin.onboarding_audit(id, requested_by, request_payload, result_payload)
    VALUES (
        v_audit_id,
        v_actor_username,
        jsonb_build_object(
            'operation', 'SAVE_ASSET_POINT_ASSIGNMENTS',
            'asset_id', p_asset_id,
            'device_id', p_device_id,
            'requested_points', COALESCE(p_confirmed_points, '[]'::jsonb),
            'before', COALESCE(v_before_json, '[]'::jsonb)
        ),
        v_result
    );

    RETURN v_result;
END;
$function$;

COMMENT ON FUNCTION admin.save_asset_point_assignments(BIGINT, UUID, UUID, JSONB) IS
'ADR-018 Amendments 5-8 / Amendment 2 correction (migration 255, extended by migrations 256/259): the sole write path for metadata.asset_points. Scoped to one (asset, device) pair per call -- confirmed_points (a JSONB array of {"logical_point_id": uuid, "friendly_name": text|null}) is the COMPLETE desired set for that device; diffed into add/remove(close, never delete)/friendly-name-in-place-update. Enforces migration 254''s canonical_measurement_groups one-device-per-governed-group rule, raised with dedicated ERRCODE ''EM001'' (migration 259) so the Admin Portal can safely display that one message; every other validation failure keeps a standard SQLSTATE and the generic database-error path. On the asset''s first successful confirmed-point addition (detected by the ABSENCE of any metadata.asset_commissioning_backfill row for the asset, not a live row-count check), moves lifecycle_status to COMMISSIONING and creates a PENDING backfill record; subsequent additions/removals/friendly-name edits, and any re-assignment after a prior full removal, never re-trigger this. Does not perform the backfill itself, does not transition to ACTIVE, and never moves a point to a different asset. Requires asset.manage + asset access; locks the asset row for the call; audits one admin.onboarding_audit row per call.';


-- ----------------------------------------------------------------------------
-- Postconditions.
-- ----------------------------------------------------------------------------

DO $post$
DECLARE
    v_sig TEXT := 'admin.save_asset_point_assignments(bigint, uuid, uuid, jsonb)';
BEGIN
    IF to_regprocedure(v_sig) IS NULL THEN
        RAISE EXCEPTION 'Migration 259 postcondition failed: % does not exist.', v_sig;
    END IF;

    IF has_function_privilege('public', v_sig, 'EXECUTE') THEN
        RAISE EXCEPTION 'Migration 259 postcondition failed: % is executable by PUBLIC.', v_sig;
    END IF;
    IF NOT has_function_privilege('ems_app', v_sig, 'EXECUTE') THEN
        RAISE EXCEPTION 'Migration 259 postcondition failed: % is not executable by ems_app.', v_sig;
    END IF;

    IF position('EM001' IN pg_get_functiondef('admin.save_asset_point_assignments(bigint,uuid,uuid,jsonb)'::regprocedure)) = 0 THEN
        RAISE EXCEPTION 'Migration 259 postcondition failed: the dedicated EM001 ERRCODE was not applied.';
    END IF;
    IF position(
        'from more than one device for this Asset; each measurement group must come from a single device.'', v_conflicting_groups USING ERRCODE = ''EM001'''
        IN pg_get_functiondef('admin.save_asset_point_assignments(bigint,uuid,uuid,jsonb)'::regprocedure)
    ) = 0 THEN
        RAISE EXCEPTION 'Migration 259 postcondition failed: the measurement-group conflict message is not paired with ERRCODE EM001.';
    END IF;

    RAISE NOTICE 'Migration 259: all postconditions passed (admin.save_asset_point_assignments now raises the measurement-group conflict with dedicated ERRCODE EM001; every other line unchanged from migration 256).';
END;
$post$;
