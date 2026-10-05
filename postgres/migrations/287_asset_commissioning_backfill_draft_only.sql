-- ============================================================================
-- Migration 287
-- Asset commissioning backfill: DRAFT-only initial commissioning, a
-- COMMISSIONING-only worker guard, and removal of the defective PENDING
-- records the previous rule created for ACTIVE assets.
--
-- Defect (found on staging 2026-10-05, read-only): admin.save_asset_point_
-- assignments() (migrations 255/256/259) created a PENDING backfill record
-- on the first Save that added a point to ANY asset without one --
-- including ACTIVE assets -- and reported commissioning_triggered = true,
-- although the lifecycle move correctly skipped ACTIVE. Migration 256
-- equated "already commissioned" with "a backfill record exists", which
-- holds only for assets commissioned through this workflow, never for
-- assets made ACTIVE before it existed (every ACTIVE asset on staging and in
-- production). The worker (telemetry.process_asset_commissioning_backfill)
-- claims every PENDING record with no lifecycle check, so enabling it would
-- have moved the newly added points' effective_from up to 90 days back --
-- contrary to ADR-018 decision 6 / Amendment 6 (a point added to an
-- already-commissioned asset starts at its assignment time and is never
-- backfilled).
--
-- Decisions (product owner, 2026-10-05):
--   * Initial commissioning / backfill applies to DRAFT assets only;
--     INACTIVE is not initial commissioning.
--   * Points added to an ACTIVE asset start at assignment time: no backfill
--     record, commissioning_triggered = false, lifecycle unchanged.
--   * The worker processes only records whose asset is COMMISSIONING; any
--     other record -- including a rerun of an already-completed
--     commissioning on a now-ACTIVE asset -- is refused (FAILED with a clear
--     reason, no start date moved, no lifecycle change).
--   * The never-attempted PENDING records the defect created are deleted;
--     admin.onboarding_audit is never touched.
--   * The backfill worker job stays unscheduled.
--
-- Changes:
--   1. admin.save_asset_point_assignments: step 9 only (DRAFT-only trigger)
--      and its COMMENT. Signature, owner, privileges and every other line
--      are byte-identical to migration 259's body.
--   2. telemetry.backfill_asset_commissioning_points: a COMMISSIONING-only
--      guard before any asset_points read or write, and its COMMENT. Every
--      other line is byte-identical to migration 257's body. The claiming
--      procedure is unchanged: it already records any exception as FAILED
--      with SQLSTATE + message, in a block whose changes are rolled back.
--   3. Cleanup: deletes PENDING, never-attempted (attempt_count = 0,
--      started_at IS NULL) backfill records whose asset is not COMMISSIONING
--      -- exactly the records the corrected rule never creates and the guard
--      would refuse. At most 2 may be deleted (the two authorized staging
--      records); finding more aborts the migration for review. Expected:
--      staging 2 (EN-AirCompressor-01, Banquet 2 AHU); production and CI 0.
--
-- Preconditions: both functions match the reviewed definitions (md5,
-- identical on the CI test database and staging); the backfill job is
-- registered and unscheduled; no backfill record is RUNNING.
-- Rollback: re-apply migration 259's save function and migration 257's
-- backfill function. The deleted records are not restored (they were never
-- attempted; the triggering Saves remain in admin.onboarding_audit).
-- ============================================================================

-- ----------------------------------------------------------------------------
-- Preconditions.
-- ----------------------------------------------------------------------------

DO $pre$
BEGIN
    IF md5(pg_get_functiondef('admin.save_asset_point_assignments(bigint,uuid,uuid,jsonb)'::regprocedure)) <> 'cfda8f37b247a02fccc88b837c8c622c' THEN
        RAISE EXCEPTION 'Migration 287 precondition failed: admin.save_asset_point_assignments differs from migration 259''s definition.';
    END IF;
    IF md5(pg_get_functiondef('telemetry.backfill_asset_commissioning_points(uuid)'::regprocedure)) <> '888feea6ed589a32ebb3404b96d56e2c' THEN
        RAISE EXCEPTION 'Migration 287 precondition failed: telemetry.backfill_asset_commissioning_points differs from migration 257''s definition.';
    END IF;
    IF NOT EXISTS (
        SELECT 1 FROM timescaledb_information.jobs
        WHERE proc_schema = 'telemetry' AND proc_name = 'run_asset_commissioning_backfill_job'
    ) THEN
        RAISE EXCEPTION 'Migration 287 precondition failed: the backfill job is not registered.';
    END IF;
    IF EXISTS (
        SELECT 1 FROM timescaledb_information.jobs
        WHERE proc_schema = 'telemetry' AND proc_name = 'run_asset_commissioning_backfill_job' AND scheduled
    ) THEN
        RAISE EXCEPTION 'Migration 287 precondition failed: the backfill job is scheduled; it must stay disabled.';
    END IF;
    IF EXISTS (SELECT 1 FROM metadata.asset_commissioning_backfill WHERE status = 'RUNNING') THEN
        RAISE EXCEPTION 'Migration 287 precondition failed: a backfill record is RUNNING.';
    END IF;
END;
$pre$;

CREATE TEMP TABLE m287_privileges AS
SELECT p.oid::regprocedure::text AS sig, p.proacl::text AS acl, p.proowner
FROM pg_proc AS p
WHERE p.oid IN ('admin.save_asset_point_assignments(bigint,uuid,uuid,jsonb)'::regprocedure,
                'telemetry.backfill_asset_commissioning_points(uuid)'::regprocedure);

-- ----------------------------------------------------------------------------
-- 1. admin.save_asset_point_assignments -- DRAFT-only initial commissioning.
-- ----------------------------------------------------------------------------

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
    -- 9. Initial-commissioning trigger (ADR-018 Amendment 6, decision 6;
    --    corrected by migration 287). Initial commissioning applies ONLY
    --    to a DRAFT asset: a Save that adds at least one confirmed point
    --    to a DRAFT asset that has never had a backfill record moves it to
    --    COMMISSIONING and creates the PENDING backfill record. Points added
    --    to any other asset -- ACTIVE (including assets made ACTIVE before
    --    this workflow existed), INACTIVE, COMMISSIONING -- start at their
    --    assignment time: no backfill record, commissioning_triggered =
    --    false, lifecycle unchanged. v_lifecycle_status was read under the
    --    asset row lock taken in step 2 (FOR UPDATE), so it is current for
    --    the whole call; ON CONFLICT (asset_id) DO NOTHING still keeps the
    --    one-record-per-asset guarantee (an earlier record, e.g. from a
    --    full prior removal, never re-triggers).
    -- ------------------------------------------------------------------
    IF v_lifecycle_status = 'DRAFT'
       AND v_added_json IS NOT NULL AND jsonb_array_length(v_added_json) > 0 THEN
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
              AND lifecycle_status = 'DRAFT';

            IF NOT FOUND THEN
                -- Unreachable while the step-2 row lock is held; never leave
                -- a backfill record behind for an asset that did not move.
                RAISE EXCEPTION 'Asset % was not DRAFT when its initial commissioning was triggered.', p_asset_id;
            END IF;

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
'ADR-018 Amendments 5-8 / Amendment 2 correction (migration 255, extended by migrations 256/259/287): the sole write path for metadata.asset_points. Scoped to one (asset, device) pair per call -- confirmed_points (a JSONB array of {"logical_point_id": uuid, "friendly_name": text|null}) is the COMPLETE desired set for that device; diffed into add/remove(close, never delete)/friendly-name-in-place-update. Enforces migration 254''s canonical_measurement_groups one-device-per-governed-group rule, raised with dedicated ERRCODE ''EM001'' (migration 259) so the Admin Portal can safely display that one message; every other validation failure keeps a standard SQLSTATE and the generic database-error path. Initial commissioning applies only to a DRAFT asset (migration 287): its first Save that adds a confirmed point (when no backfill record exists) moves lifecycle_status DRAFT -> COMMISSIONING and creates a PENDING backfill record. Points added to any other asset (ACTIVE, INACTIVE, COMMISSIONING) start at their assignment time: no backfill record, commissioning_triggered=false, lifecycle unchanged. Subsequent additions/removals/friendly-name edits, and any re-assignment after a prior full removal, never re-trigger this. Does not perform the backfill itself, does not transition to ACTIVE, and never moves a point to a different asset. Requires asset.manage + asset access; locks the asset row for the call; audits one admin.onboarding_audit row per call.';


-- ----------------------------------------------------------------------------
-- 2. telemetry.backfill_asset_commissioning_points -- COMMISSIONING-only guard.
-- ----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION telemetry.backfill_asset_commissioning_points(
    p_backfill_id UUID
)
RETURNS JSONB
LANGUAGE plpgsql
AS $function$
DECLARE
    v_job             RECORD;
    v_point_id        UUID;
    v_row             metadata.asset_points%ROWTYPE;
    v_window_lower    TIMESTAMPTZ;
    v_prior_boundary  TIMESTAMPTZ;
    v_earliest        TIMESTAMPTZ;
    v_results         JSONB := '[]'::jsonb;
    v_points_processed INTEGER := 0;
    v_points_extended  INTEGER := 0;
    v_asset_lifecycle  TEXT;
BEGIN
    SELECT id, asset_id, trigger_audit_transaction_id, requested_at
    INTO v_job
    FROM metadata.asset_commissioning_backfill
    WHERE id = p_backfill_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Backfill record % was not found.', p_backfill_id;
    END IF;

    IF v_job.trigger_audit_transaction_id IS NULL THEN
        RAISE EXCEPTION 'Backfill record % has no trigger_audit_transaction_id -- cannot determine which points to backfill.', p_backfill_id;
    END IF;

    -- Migration 287 guard: only an asset in COMMISSIONING may be backfilled.
    -- Any other lifecycle (ACTIVE -- including a rerun of an already-
    -- completed commissioning -- DRAFT, INACTIVE, DECOMMISSIONED) is refused
    -- BEFORE any metadata.asset_points row is read or changed; the claiming
    -- procedure records the record FAILED with this message, and no
    -- assignment start date moves.
    SELECT a.lifecycle_status INTO v_asset_lifecycle
    FROM metadata.assets AS a
    WHERE a.id = v_job.asset_id;

    IF v_asset_lifecycle IS DISTINCT FROM 'COMMISSIONING' THEN
        RAISE EXCEPTION 'Backfill record % refused: asset % is %, not COMMISSIONING -- only initial commissioning is backfilled; assignment start dates were not changed.',
            p_backfill_id, v_job.asset_id, COALESCE(v_asset_lifecycle, 'missing');
    END IF;

    FOR v_point_id IN
        SELECT (elem->>'asset_point_id')::uuid
        FROM admin.onboarding_audit aa
        CROSS JOIN LATERAL jsonb_array_elements(COALESCE(aa.result_payload->'added', '[]'::jsonb)) AS elem
        WHERE aa.id = v_job.trigger_audit_transaction_id
    LOOP
        v_points_processed := v_points_processed + 1;

        SELECT * INTO v_row FROM metadata.asset_points WHERE id = v_point_id;
        IF NOT FOUND THEN
            -- Defensive: the row is somehow gone (should not happen --
            -- asset_points rows are never deleted, only closed). Skip
            -- rather than fail the whole job over one missing point.
            CONTINUE;
        END IF;

        v_window_lower := v_job.requested_at - INTERVAL '90 days';

        -- Never reach into a period a DIFFERENT prior binding for the
        -- same (device_id, logical_point_id) already owns -- decision 8
        -- immutability, and the exact boundary the GiST exclusion
        -- constraint would otherwise reject an UPDATE for anyway.
        SELECT max(effective_to) INTO v_prior_boundary
        FROM metadata.asset_points
        WHERE device_id = v_row.device_id
          AND logical_point_id = v_row.logical_point_id
          AND id <> v_row.id
          AND effective_to IS NOT NULL
          AND effective_to <= v_row.effective_from;

        v_window_lower := GREATEST(v_window_lower, COALESCE(v_prior_boundary, '-infinity'::timestamptz));

        SELECT min(event_time) INTO v_earliest
        FROM telemetry.normalized_points
        WHERE device_id = v_row.device_id
          AND logical_point_id = v_row.logical_point_id
          AND event_time >= v_window_lower
          AND event_time < v_row.effective_from;

        IF v_earliest IS NOT NULL AND v_earliest < v_row.effective_from THEN
            UPDATE metadata.asset_points
            SET effective_from = v_earliest
            WHERE id = v_row.id;
            v_points_extended := v_points_extended + 1;
        END IF;

        v_results := v_results || jsonb_build_array(jsonb_build_object(
            'asset_point_id', v_row.id,
            'device_id', v_row.device_id,
            'logical_point_id', v_row.logical_point_id,
            'window_lower_bound', v_window_lower,
            'earliest_telemetry_found', v_earliest,
            'effective_from_extended', (v_earliest IS NOT NULL AND v_earliest < v_row.effective_from)
        ));
    END LOOP;

    RETURN jsonb_build_object(
        'backfill_id', p_backfill_id,
        'asset_id', v_job.asset_id,
        'points_processed', v_points_processed,
        'points_extended', v_points_extended,
        'points', v_results
    );
END;
$function$;

COMMENT ON FUNCTION telemetry.backfill_asset_commissioning_points(UUID) IS
'ADR-018 Amendments 6-8 (migration 257, guarded by migration 287): refuses -- raising, changing nothing -- unless the record''s asset is COMMISSIONING. for the given metadata.asset_commissioning_backfill record, widens effective_from (never any other column) on exactly the metadata.asset_points rows created by the triggering Save (resolved via admin.onboarding_audit.result_payload->''added'' for trigger_audit_transaction_id) back to the earliest telemetry.normalized_points event within [requested_at - 90 days, current effective_from), bounded below by any prior binding''s effective_to for the same (device_id, logical_point_id). No telemetry is read, copied, or written anywhere else. Idempotent: reruns converge (a rerun can only find an earlier-or-equal minimum within an already-narrower window) and are safe to repeat any number of times. Does not touch metadata.assets.lifecycle_status or the backfill record''s own status -- purely the point-level attribution computation, called by telemetry.process_asset_commissioning_backfill.';


-- ----------------------------------------------------------------------------
-- 3. Cleanup of the defective records (authorized by the product owner,
--    2026-10-05). The block between the markers is also executed verbatim
--    by scripts/test/assert_asset_commissioning_backfill_draft_only.sh.
-- ----------------------------------------------------------------------------

-- BEGIN M287 DEFECTIVE BACKFILL CLEANUP
DO $cleanup$
DECLARE
    v_candidates INTEGER;
    v_deleted    INTEGER;
    v_detail     TEXT;
BEGIN
    SELECT count(*) INTO v_candidates
    FROM metadata.asset_commissioning_backfill AS b
    JOIN metadata.assets AS a ON a.id = b.asset_id
    WHERE b.status = 'PENDING'
      AND b.attempt_count = 0
      AND b.started_at IS NULL
      AND a.lifecycle_status <> 'COMMISSIONING';

    IF v_candidates > 2 THEN
        RAISE EXCEPTION 'Migration 287 cleanup refused: % defective PENDING backfill records found; at most 2 were authorized for deletion. Review before re-running.', v_candidates;
    END IF;

    WITH deleted AS (
        DELETE FROM metadata.asset_commissioning_backfill AS b
        USING metadata.assets AS a
        WHERE a.id = b.asset_id
          AND b.status = 'PENDING'
          AND b.attempt_count = 0
          AND b.started_at IS NULL
          AND a.lifecycle_status <> 'COMMISSIONING'
        RETURNING b.id, b.asset_id, a.name, a.lifecycle_status
    )
    SELECT count(*), string_agg(format('%s (asset %s "%s", %s)', id, asset_id, name, lifecycle_status), '; ' ORDER BY name)
    INTO v_deleted, v_detail
    FROM deleted;

    RAISE NOTICE 'Migration 287 cleanup: deleted % defective never-attempted PENDING backfill record(s)%', v_deleted,
        CASE WHEN v_deleted > 0 THEN ': ' || v_detail ELSE '' END;
END;
$cleanup$;
-- END M287 DEFECTIVE BACKFILL CLEANUP

-- ----------------------------------------------------------------------------
-- Postconditions.
-- ----------------------------------------------------------------------------

DO $post$
DECLARE
    v_save_def TEXT := pg_get_functiondef('admin.save_asset_point_assignments(bigint,uuid,uuid,jsonb)'::regprocedure);
    v_bf_def   TEXT := pg_get_functiondef('telemetry.backfill_asset_commissioning_points(uuid)'::regprocedure);
BEGIN
    IF position('IF v_lifecycle_status = ''DRAFT''' IN v_save_def) = 0
       OR position('AND lifecycle_status = ''DRAFT''' IN v_save_def) = 0 THEN
        RAISE EXCEPTION 'Migration 287 postcondition failed: the DRAFT-only commissioning trigger is not in admin.save_asset_point_assignments.';
    END IF;
    IF position('NOT IN (''ACTIVE'', ''COMMISSIONING'', ''DECOMMISSIONED'')' IN v_save_def) > 0 THEN
        RAISE EXCEPTION 'Migration 287 postcondition failed: the old lifecycle predicate is still present.';
    END IF;
    IF position('USING ERRCODE = ''EM001''' IN v_save_def) = 0 THEN
        RAISE EXCEPTION 'Migration 287 postcondition failed: migration 259''s EM001 ERRCODE was lost.';
    END IF;
    IF position('IS DISTINCT FROM ''COMMISSIONING''' IN v_bf_def) = 0 THEN
        RAISE EXCEPTION 'Migration 287 postcondition failed: the COMMISSIONING-only guard is not in telemetry.backfill_asset_commissioning_points.';
    END IF;
    IF EXISTS (
        SELECT 1
        FROM pg_proc AS p JOIN m287_privileges AS m ON m.sig = p.oid::regprocedure::text
        WHERE p.proacl::text IS DISTINCT FROM m.acl OR p.proowner <> m.proowner
    ) OR (SELECT count(*) FROM m287_privileges) <> 2 THEN
        RAISE EXCEPTION 'Migration 287 postcondition failed: a replaced function''s owner or privileges changed.';
    END IF;
    IF has_function_privilege('public', 'admin.save_asset_point_assignments(bigint,uuid,uuid,jsonb)', 'EXECUTE')
       OR NOT has_function_privilege('ems_app', 'admin.save_asset_point_assignments(bigint,uuid,uuid,jsonb)', 'EXECUTE') THEN
        RAISE EXCEPTION 'Migration 287 postcondition failed: admin.save_asset_point_assignments must be executable by ems_app and not PUBLIC.';
    END IF;
    IF EXISTS (
        SELECT 1 FROM timescaledb_information.jobs
        WHERE proc_schema = 'telemetry' AND proc_name = 'run_asset_commissioning_backfill_job' AND scheduled
    ) THEN
        RAISE EXCEPTION 'Migration 287 postcondition failed: the backfill job must remain unscheduled.';
    END IF;
    IF EXISTS (
        SELECT 1 FROM metadata.asset_commissioning_backfill AS b
        JOIN metadata.assets AS a ON a.id = b.asset_id
        WHERE b.status = 'PENDING' AND b.attempt_count = 0 AND b.started_at IS NULL
          AND a.lifecycle_status <> 'COMMISSIONING'
    ) THEN
        RAISE EXCEPTION 'Migration 287 postcondition failed: a defective PENDING backfill record remains.';
    END IF;

    RAISE NOTICE 'Migration 287: all postconditions passed (DRAFT-only initial commissioning; COMMISSIONING-only backfill guard; defective PENDING records removed; owners/privileges unchanged; backfill job unscheduled).';
END;
$post$;

DROP TABLE m287_privileges;
