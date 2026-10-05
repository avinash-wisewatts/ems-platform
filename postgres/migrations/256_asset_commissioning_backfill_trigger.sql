-- ============================================================================
-- Migration 256
-- Asset Data Point Assignment / Commissioning (ADR-018 Amendment 6/8,
-- corrected by Amendment 12) -- first-assignment commissioning trigger and
-- durable backfill state, built on migrations 253-255 exactly as
-- implemented.
--
-- Scope, explicit (per the approved slice; nothing beyond this list):
--   * metadata.asset_commissioning_backfill -- new, durable backfill
--     state for an Asset's initial commissioning: PENDING/RUNNING/
--     COMPLETED/FAILED, timestamps and an error field sufficient for a
--     future retry/audit, and (see "One record per Asset" below)
--     UNIQUE(asset_id) so at most one record can ever exist per asset.
--   * admin.save_asset_point_assignments() (migration 255) extended,
--     preserving every migration-255 behavior/return shape unchanged: on
--     an asset's FIRST successful confirmed-point addition -- and only
--     then -- moves metadata.assets.lifecycle_status to COMMISSIONING and
--     creates the PENDING backfill record.
--
-- Explicitly NOT in this migration (deferred, per the approved scope):
--   * The actual backfill job / worker that reads this state and performs
--     the historical backfill (Amendment 6's "asynchronous background
--     job") -- not built. This migration only records that a backfill is
--     owed; nothing consumes PENDING rows yet.
--   * The COMMISSIONING -> ACTIVE transition (still gated, per Amendment
--     6, on that not-yet-built job completing successfully) -- this
--     migration never sets lifecycle_status to ACTIVE.
--   * Re-pointing admin.commission_asset()'s existing ACTIVE gate --
--     untouched, unaffected by this migration.
--   * Any UI.
--   * Any staging deployment.
--
-- ----------------------------------------------------------------------------
-- Resolved ambiguity: re-assignment after ALL points were previously
-- closed.
-- ----------------------------------------------------------------------------
-- Investigated before implementation, as required. The literal reading of
-- "the Asset had no currently-effective asset_points before this
-- successful Save" would, taken alone, re-detect "first assignment" every
-- time an asset's confirmed points are fully removed and then reconfirmed
-- -- e.g. an ACTIVE asset whose only confirmed point is removed and later
-- re-added would be misread as needing INITIAL commissioning again.
--
-- ADR-018 Amendment 6's own trigger language is not framed as a row-count
-- check: "the system detects that initial commissioning has **not yet
-- occurred**" -- a one-time STATUS about the asset's history, not a live
-- count of currently-effective rows. The original decision 6 uses the
-- same framing: a point "assigned to an **already-commissioned**
-- asset...after the fact" never backfills -- "already-commissioned" is
-- also a permanent, one-time status, not something that resets when
-- points are later removed. Initial commissioning backfill (decision 5)
-- is described throughout the ADR as a single, one-time historical event
-- in an asset's life, not a state that re-arms whenever the current
-- confirmed-point count happens to pass through zero.
--
-- Resolution implemented here: "first successful assignment" is detected
-- by whether a metadata.asset_commissioning_backfill row already exists
-- for the asset (i.e., whether initial commissioning was ever triggered
-- before) -- NOT by the current confirmed-point count. Because
-- metadata.asset_points has no write path anywhere outside admin.
-- save_asset_point_assignments() (confirmed repeatedly across ADR-018's
-- amendments, unchanged by migration 255), "no backfill record exists
-- yet" and "this is genuinely the asset's first-ever confirmed point"
-- coincide exactly for a brand-new asset, and diverge exactly, correctly,
-- for the re-assignment-after-full-removal case: the backfill record from
-- the ORIGINAL commissioning already exists, so the new addition does not
-- re-trigger COMMISSIONING or create a second backfill record -- the
-- asset simply gains a newly confirmed point, exactly as decision 6
-- already describes for any point "assigned...after the fact." This also
-- means the trigger check needs no separate "count effective rows before
-- this Save" query at all -- the existence check against
-- asset_commissioning_backfill is the single, sufficient, race-safe
-- signal (see "One record per Asset" below).
--
-- ----------------------------------------------------------------------------
-- One record per Asset / concurrency.
-- ----------------------------------------------------------------------------
-- metadata.asset_commissioning_backfill.asset_id is UNIQUE, so the table
-- can structurally never hold more than one row for a given asset,
-- regardless of that row's status or how many times points are later
-- added/removed/re-added. The trigger step performs INSERT ... ON
-- CONFLICT (asset_id) DO NOTHING and only proceeds to flip
-- lifecycle_status when that INSERT actually returned a new row. Two
-- concurrent first-successful Saves for the same asset (different
-- devices, or a genuine client retry) therefore race safely at the
-- database level: exactly one inserts and flips lifecycle_status; the
-- other sees no returned row and continues as an ordinary, successful
-- point-assignment Save with no commissioning side effect -- no
-- duplicate record, no error, no partial state.
--
-- A failed/invalid Save (any RAISE EXCEPTION earlier in the function --
-- authorization, validation, the measurement-group conflict, or the
-- exclusion_violation race handler) never reaches the commissioning-
-- trigger step at all, and the whole function body executes as one
-- transaction scope, so no lifecycle or backfill-state mutation is ever
-- left behind by a failed call.
--
-- Rollback: DROP FUNCTION admin.save_asset_point_assignments(BIGINT,
-- UUID, UUID, JSONB) then re-CREATE the migration-255 body; DROP TABLE
-- metadata.asset_commissioning_backfill. Not run as part of this
-- migration.
-- ============================================================================


-- ----------------------------------------------------------------------------
-- 1. metadata.asset_commissioning_backfill.
-- ----------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS metadata.asset_commissioning_backfill (
    id                            UUID PRIMARY KEY DEFAULT gen_random_uuid(),

    asset_id                      UUID NOT NULL
        REFERENCES metadata.assets(id),

    status                        TEXT NOT NULL DEFAULT 'PENDING',

    triggered_by_portal_user_id   BIGINT
        REFERENCES admin.portal_users(portal_user_id),
    -- DEFERRABLE INITIALLY DEFERRED: admin.save_asset_point_assignments()
    -- inserts this row BEFORE it inserts the admin.onboarding_audit row
    -- carrying the same id (the audit row's result_payload needs the
    -- final commissioning_triggered/backfill_record_id, which are only
    -- known after this insert). Both inserts land in the same
    -- transaction, so deferring the check to COMMIT (rather than
    -- statement time) is correct and sufficient -- the audit row always
    -- exists by the time the transaction actually commits.
    trigger_audit_transaction_id  UUID
        REFERENCES admin.onboarding_audit(id)
        DEFERRABLE INITIALLY DEFERRED,

    requested_at                  TIMESTAMPTZ NOT NULL DEFAULT now(),
    started_at                    TIMESTAMPTZ,
    completed_at                  TIMESTAMPTZ,
    failed_at                     TIMESTAMPTZ,

    attempt_count                 INTEGER NOT NULL DEFAULT 0,
    last_error                    TEXT,

    created_at                    TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at                    TIMESTAMPTZ NOT NULL DEFAULT now(),

    CONSTRAINT uq_asset_commissioning_backfill_asset
        UNIQUE (asset_id),

    CONSTRAINT ck_asset_commissioning_backfill_status
        CHECK (status IN ('PENDING', 'RUNNING', 'COMPLETED', 'FAILED')),

    CONSTRAINT ck_asset_commissioning_backfill_timestamps
        CHECK (
            (status = 'PENDING'   AND started_at IS NULL AND completed_at IS NULL AND failed_at IS NULL)
            OR (status = 'RUNNING'   AND started_at IS NOT NULL AND completed_at IS NULL AND failed_at IS NULL)
            OR (status = 'COMPLETED' AND started_at IS NOT NULL AND completed_at IS NOT NULL AND failed_at IS NULL)
            OR (status = 'FAILED'    AND started_at IS NOT NULL AND failed_at IS NOT NULL)
        )
);

CREATE INDEX IF NOT EXISTS idx_asset_commissioning_backfill_status
    ON metadata.asset_commissioning_backfill (status)
    WHERE status IN ('PENDING', 'FAILED');

COMMENT ON TABLE metadata.asset_commissioning_backfill IS
'ADR-018 Amendment 6/8 (corrected by Amendment 12), migration 256: durable state for an Asset''s ONE-TIME initial-commissioning historical backfill. UNIQUE(asset_id) -- at most one record ever exists per asset, created exactly once by admin.save_asset_point_assignments() on the asset''s first successful confirmed-point addition. Not yet consumed by any job (the backfill worker itself is a later slice) -- rows may sit PENDING indefinitely today. status transitions (PENDING->RUNNING->COMPLETED|FAILED, and a future FAILED->RUNNING retry) are not yet written by any code path other than the initial PENDING insert.';

COMMENT ON COLUMN metadata.asset_commissioning_backfill.trigger_audit_transaction_id IS
'The admin.onboarding_audit row for the Save call that triggered this record -- links the commissioning trigger back to the exact assignment request that caused it.';

COMMENT ON COLUMN metadata.asset_commissioning_backfill.attempt_count IS
'Incremented by the (not-yet-built) backfill worker on each RUNNING attempt; 0 while still PENDING. Present now so the worker''s future retry logic needs no further schema change.';

COMMENT ON COLUMN metadata.asset_commissioning_backfill.last_error IS
'Error detail from the most recent FAILED attempt, for retry/audit. NULL until a failure is recorded by the (not-yet-built) worker.';


-- ----------------------------------------------------------------------------
-- 2. admin.save_asset_point_assignments -- migration 255's body, extended
--    with the first-assignment commissioning trigger. Every migration-255
--    validation/mutation/audit step is preserved verbatim; only the new
--    step 10 (commissioning trigger, after the mutation block succeeds)
--    and the two new result_payload/return fields (commissioning_
--    triggered, backfill_record_id) are added.
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
    -- 9. First-assignment commissioning trigger (ADR-018 Amendment 6,
    --    corrected by Amendment 12). Only when this Save actually added
    --    at least one confirmed point, AND no backfill record has ever
    --    been created for this asset (see the migration header for why
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
'ADR-018 Amendments 5-8 / Amendment 2 correction (migration 255, extended by migration 256): the sole write path for metadata.asset_points. Scoped to one (asset, device) pair per call -- confirmed_points (a JSONB array of {"logical_point_id": uuid, "friendly_name": text|null}) is the COMPLETE desired set for that device; diffed into add/remove(close, never delete)/friendly-name-in-place-update. Enforces migration 254''s canonical_measurement_groups one-device-per-governed-group rule. On the asset''s first successful confirmed-point addition (detected by the ABSENCE of any metadata.asset_commissioning_backfill row for the asset, not a live row-count check -- see migration 256 header for why), moves lifecycle_status to COMMISSIONING and creates a PENDING backfill record; subsequent additions/removals/friendly-name edits, and any re-assignment after a prior full removal, never re-trigger this (the backfill record already exists). Does not perform the backfill itself, does not transition to ACTIVE, and never moves a point to a different asset -- all deferred to later slices. Requires asset.manage + asset access; locks the asset row for the call; audits one admin.onboarding_audit row per call.';


-- ----------------------------------------------------------------------------
-- 3. Postconditions.
-- ----------------------------------------------------------------------------

DO $post$
DECLARE
    v_sig TEXT := 'admin.save_asset_point_assignments(bigint, uuid, uuid, jsonb)';
BEGIN
    IF to_regclass('metadata.asset_commissioning_backfill') IS NULL THEN
        RAISE EXCEPTION 'Migration 256 postcondition failed: metadata.asset_commissioning_backfill was not created.';
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conname = 'uq_asset_commissioning_backfill_asset'
          AND conrelid = 'metadata.asset_commissioning_backfill'::regclass
    ) THEN
        RAISE EXCEPTION 'Migration 256 postcondition failed: uq_asset_commissioning_backfill_asset (one record per Asset) was not created.';
    END IF;

    IF to_regprocedure(v_sig) IS NULL THEN
        RAISE EXCEPTION 'Migration 256 postcondition failed: % does not exist.', v_sig;
    END IF;
    IF has_function_privilege('public', v_sig, 'EXECUTE') THEN
        RAISE EXCEPTION 'Migration 256 postcondition failed: % is executable by PUBLIC.', v_sig;
    END IF;
    IF NOT has_function_privilege('ems_app', v_sig, 'EXECUTE') THEN
        RAISE EXCEPTION 'Migration 256 postcondition failed: % is not executable by ems_app.', v_sig;
    END IF;

    RAISE NOTICE 'Migration 256: all postconditions passed (metadata.asset_commissioning_backfill deployed with a one-record-per-Asset guarantee; admin.save_asset_point_assignments extended with the first-assignment commissioning trigger).';
END;
$post$;
