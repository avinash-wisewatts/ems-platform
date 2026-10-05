-- ============================================================================
-- Migration 255
-- Asset Data Point Assignment / Commissioning (ADR-018 Amendments 5-7,
-- Amendment 2 correction) -- the authoritative Save/write path for
-- metadata.asset_points, approved this session on top of migration 254's
-- canonical_measurement_groups semantic foundation.
--
-- Scope, explicit (per the approved design; nothing beyond this list):
--   * admin.save_asset_point_assignments(actor, asset_id, device_id,
--     confirmed_points) -- the first and only write path anywhere in the
--     repository for metadata.asset_points. Scoped to one (asset, device)
--     pair per call: confirmed_points is the COMPLETE desired set of
--     confirmed points for that device on that asset (a full-replace
--     diff), matching ADR-018 Amendment 5's UX ("user selects a device...
--     that device's points are shown... explicit save").
--   * Add/remove/friendly-name-only-edit behavior, historical immutability,
--     and the measurement-group duplicate-source rule, per the v3 design
--     report approved this session.
--
-- Explicitly NOT in this migration (deferred, per the approved scope):
--   * Commissioning trigger (Amendment 6: first successful Save entering
--     COMMISSIONING) -- not wired. This function never touches
--     metadata.assets.lifecycle_status.
--   * Backfill / durable backfill state machine (Amendment 6/12).
--   * The ACTIVE transition / admin.commission_asset() re-pointing.
--   * Cross-Asset point moves ("Move Sensor / Data Point", ADR-018
--     decision 7) -- explicitly out of scope; this function only ever
--     writes rows for p_asset_id/p_device_id, never touches another
--     asset's rows. A point cannot move between assets through this
--     function.
--   * Any UI.
--   * Any staging deployment.
--
-- Save semantics (per point, diffed against the currently-effective
-- metadata.asset_points rows for (p_asset_id, p_device_id) only -- other
-- devices' currently-effective rows on the same asset are never touched):
--   * ADD: a submitted logical_point_id with no currently-effective row
--     -> INSERT, effective_from = now(), effective_to = NULL. Never
--     backfills (decision 6) -- backfill is a separate, not-yet-built job.
--   * REMOVE: a currently-effective row whose logical_point_id is absent
--     from the payload -> UPDATE ... SET effective_to = now(). Never
--     DELETE (decision 8 immutability) -- the row remains as history.
--   * FRIENDLY-NAME-ONLY EDIT: a submitted logical_point_id that already
--     has a currently-effective row -> UPDATE the EXISTING row's
--     friendly_name in place. Deliberately does NOT close+reopen: doing
--     so would manufacture a spurious effective_range discontinuity that
--     migration 250's analytics.resolve_demand_source_for_interval()
--     would read as a false SOURCE_BOUNDARY for an edit that changed
--     nothing about point ownership. metadata.validate_point_binding()
--     (migration 228) is not even re-triggered by this UPDATE, since it
--     only fires on device_id/logical_point_id/asset_id/organization_id/
--     effective_from/effective_to columns, none of which this statement
--     touches.
--   * EMPTY PAYLOAD: valid -- closes every currently-effective point for
--     this device on this asset (Amendment 5: "user may uncheck existing
--     points," including all of them). Other devices on the same asset
--     are unaffected.
--
-- Measurement-group enforcement (data-driven, per migration 254 --
-- NOTHING in this function hardcodes a logical_point or parameter name):
-- after applying this Save's proposed diff, for every governed group
-- (config.parameters.measurement_group_id IS NOT NULL, resolved via
-- metadata.logical_points.parameter_id), at most one DISTINCT device may
-- contribute a currently-effective point to that group for this asset.
-- Points whose parameter has measurement_group_id NULL (or no parameter
-- at all) are never subject to this check. Because migration 254 modeled
-- Energy as three independent groups (ENERGY_IMPORT/ENERGY_EXPORT/
-- ENERGY_APPARENT) rather than one, and Power/Power-Quality/Voltage/
-- Current as one shared group each, this ONE uniform query already
-- produces every approved rule as a consequence of the group DATA, with
-- no per-family branching in this function's logic.
--
-- Authorization: admin.portal_user_has_permission(actor, 'asset.manage')
-- (PortalPermission.ASSET_MANAGE) + admin.portal_user_can_access_asset,
-- matching every existing asset-write function (admin.commission_asset,
-- admin.replace_asset_primary_meter, admin.remove_asset_device_
-- relationship). Concurrency: SELECT ... FOR UPDATE locks the asset row
-- for the duration of the call (serializes concurrent Saves against the
-- SAME asset, same pattern as admin.commission_asset/admin.replace_
-- asset_primary_meter); cross-asset contention for the same physical
-- point is backstopped by the pre-existing ex_asset_points_no_overlap
-- GiST exclusion (migration 228) and translated into a friendly error on
-- exclusion_violation rather than a raw constraint message.
--
-- Audit: one admin.onboarding_audit row per call (operation
-- SAVE_ASSET_POINT_ASSIGNMENTS), matching the one-call/one-row precedent
-- of every existing write function here. request_payload carries the raw
-- requested points AND a "before" snapshot of the device's prior
-- confirmed state; result_payload carries the full added/removed/
-- unchanged diff.
--
-- Rollback: DROP FUNCTION admin.save_asset_point_assignments(BIGINT,
-- UUID, UUID, JSONB) -- safe, no other object depends on it.
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
    v_actor_username     TEXT;
    v_org_id             UUID;
    v_site_id            UUID;
    v_lifecycle_status   TEXT;
    v_payload_count      INTEGER;
    v_distinct_count     INTEGER;
    v_invalid_points     TEXT;
    v_conflicting_groups TEXT;
    v_before_json        JSONB;
    v_removed_json       JSONB;
    v_added_json         JSONB;
    v_unchanged_json     JSONB;
    v_audit_id           UUID := gen_random_uuid();
    v_result             JSONB;
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
        RAISE EXCEPTION 'This Save would confirm % from more than one device for this Asset; each measurement group must come from a single device.', v_conflicting_groups USING ERRCODE = '23514';
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
    -- 9. Result + audit.
    -- ------------------------------------------------------------------
    v_result := jsonb_build_object(
        'success', TRUE,
        'asset_id', p_asset_id,
        'device_id', p_device_id,
        'added', COALESCE(v_added_json, '[]'::jsonb),
        'removed', COALESCE(v_removed_json, '[]'::jsonb),
        'unchanged', COALESCE(v_unchanged_json, '[]'::jsonb),
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
'ADR-018 Amendments 5-7 / Amendment 2 correction (migration 255): the sole write path for metadata.asset_points. Scoped to one (asset, device) pair per call -- confirmed_points (a JSONB array of {"logical_point_id": uuid, "friendly_name": text|null}) is the COMPLETE desired set for that device; diffed against the device''s currently-effective rows into add (INSERT, effective_from=now()) / remove (UPDATE effective_to=now(), never DELETE) / friendly-name-only-in-place-update (never closes+reopens). Enforces, per migration 254''s canonical_measurement_groups: after the Save, any governed measurement group may have at most one contributing device for this asset -- Energy''s three groups (Import/Export/Apparent) are independent, Power/Power-Quality/Voltage/Current are each one shared group; ungoverned (measurement_group_id NULL) points are exempt. Requires asset.manage + asset access; locks the asset row for the call; audits one admin.onboarding_audit row per call. Does not trigger commissioning, backfill, or the ACTIVE transition, and never moves a point to a different asset -- all deferred to later slices.';

ALTER FUNCTION admin.save_asset_point_assignments(BIGINT, UUID, UUID, JSONB) OWNER TO ems_admin;
REVOKE ALL ON FUNCTION admin.save_asset_point_assignments(BIGINT, UUID, UUID, JSONB) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION admin.save_asset_point_assignments(BIGINT, UUID, UUID, JSONB) TO ems_app;


-- ----------------------------------------------------------------------------
-- Postconditions.
-- ----------------------------------------------------------------------------

DO $post$
DECLARE
    v_sig TEXT := 'admin.save_asset_point_assignments(bigint, uuid, uuid, jsonb)';
BEGIN
    IF to_regprocedure(v_sig) IS NULL THEN
        RAISE EXCEPTION 'Migration 255 postcondition failed: % does not exist.', v_sig;
    END IF;

    IF has_function_privilege('public', v_sig, 'EXECUTE') THEN
        RAISE EXCEPTION 'Migration 255 postcondition failed: % is executable by PUBLIC.', v_sig;
    END IF;
    IF NOT has_function_privilege('ems_app', v_sig, 'EXECUTE') THEN
        RAISE EXCEPTION 'Migration 255 postcondition failed: % is not executable by ems_app.', v_sig;
    END IF;

    RAISE NOTICE 'Migration 255: all postconditions passed (admin.save_asset_point_assignments deployed, PUBLIC-revoked, ems_app-granted).';
END;
$post$;
