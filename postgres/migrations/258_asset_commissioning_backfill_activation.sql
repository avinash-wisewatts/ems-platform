-- ============================================================================
-- Migration 258
-- Backfill completion -> ACTIVE lifecycle transition (ADR-018 Amendments
-- 6, 8, 12), built on migrations 253-257.
--
-- ----------------------------------------------------------------------------
-- Investigation performed before writing any code.
-- ----------------------------------------------------------------------------
--   * admin.validate_lifecycle_transition(entity_type, entity_id,
--     current_status, new_status, allow_reactivation) (migration 001,
--     STABLE, read-only): the shared, single source of truth for every
--     lifecycle state machine in the platform. Its ASSET transition table
--     already includes ('COMMISSIONING','ACTIVE') as an explicitly
--     allowed transition -- no new lifecycle value or transition needs to
--     be added; this slice only needs to CALL this existing function, not
--     extend it. Its only conditional gate (ACTIVE_DEPENDENCIES) applies
--     solely when new_status='DECOMMISSIONED', so COMMISSIONING->ACTIVE
--     is unconditionally allowed once current_status is genuinely
--     COMMISSIONING. It also already encodes the DECOMMISSIONED guard
--     generically (current='DECOMMISSIONED' requires an explicit
--     p_allow_reactivation override) -- this slice never needs to pass
--     that override, because it never attempts DECOMMISSIONED->ACTIVE at
--     all (see the gate below).
--   * admin.update_asset() / admin.transition_entity_lifecycle(): the
--     generic, PORTAL-USER-facing transition path -- requires a live
--     actor with permission, a mandatory p_change_reason, and writes to
--     admin.audit_events via admin.write_audit_event(). Not used here:
--     this transition is triggered by the backfill WORKER's own success,
--     not a portal user submitting a reasoned change request, so the
--     "reason" and re-permission-check machinery does not fit. This
--     mirrors exactly why admin.commission_asset() (below) also bypasses
--     this generic path.
--   * admin.commission_asset() (postgres/ddl/95): the existing precedent
--     for a narrowly-scoped function flipping an asset to ACTIVE without
--     going through the generic transition path -- a direct
--     UPDATE metadata.assets SET lifecycle_status='ACTIVE', status='active'
--     WHERE id=..., gated by its own precondition check, audited via
--     admin.onboarding_audit (not admin.audit_events). This slice follows
--     that exact shape and audit table, for the same reason and for
--     consistency with migrations 255/256/257's own onboarding_audit use
--     throughout this workstream. admin.commission_asset() itself is left
--     completely untouched -- per Amendment 6/12, its user-facing trigger
--     is already gone from the new Asset Point Assignment flow; nothing
--     in this migration calls, disables, or interacts with it.
--   * metadata.asset_commissioning_backfill (migration 256): status
--     PENDING/RUNNING/COMPLETED/FAILED, UNIQUE(asset_id) -- confirmed
--     still the single source for "has this asset's initial commissioning
--     cycle already happened," never re-derived from a live asset_points
--     count (unchanged from migration 256's own resolved ambiguity).
--   * Migration 256's trigger: unchanged and untouched. It only ever
--     creates the record and flips DRAFT/INACTIVE -> COMMISSIONING; it
--     never sets ACTIVE. This migration is the missing other half.
--   * Migration 257's worker (telemetry.process_asset_commissioning_
--     backfill / telemetry.backfill_asset_commissioning_points): the
--     attribution function is NOT modified (no correctness issue was
--     found in it during this investigation -- see the header of
--     migration 257 for its own trace). The CLAIMING procedure is
--     extended with exactly one additional call, in the success branch,
--     before it marks the backfill COMPLETED -- see below.
--
-- ----------------------------------------------------------------------------
-- Transition mechanism.
-- ----------------------------------------------------------------------------
-- New admin.activate_asset_after_commissioning_backfill(p_backfill_id):
--   1. Locks the asset row (FOR UPDATE) and reads its CURRENT
--      lifecycle_status.
--   2. If it is not exactly 'COMMISSIONING', does nothing and returns
--      activated=false -- this is the entire mechanism for "do not
--      reactivate an Asset an administrator has since moved to INACTIVE/
--      DECOMMISSIONED" (a no-op, not an error, since a backfill
--      completing successfully after an administrator's independent
--      decision is not itself a failure) and for idempotent reruns (an
--      already-ACTIVE asset is simply left alone).
--   3. Otherwise calls admin.validate_lifecycle_transition('ASSET',
--      asset_id, 'COMMISSIONING', 'ACTIVE') -- reusing the existing,
--      shared decision, not re-implementing it -- and, since it is
--      allowed, performs the same direct UPDATE admin.commission_asset()
--      performs (lifecycle_status='ACTIVE', status='active'), then writes
--      one admin.onboarding_audit row (requested_by =
--      'system:telemetry.process_asset_commissioning_backfill';
--      triggered_by_portal_user_id from the backfill record is carried in
--      the payload for lineage, not used as the audit actor, since the
--      activation event itself is system-performed, asynchronously, not
--      an action that portal user is currently taking).
--
-- Atomicity: telemetry.process_asset_commissioning_backfill (migration
-- 257) already performs the entire per-job success path -- the
-- attribution computation, and now this activation call -- inside the
-- SAME transaction as the backfill row's own UPDATE ... SET
-- status='COMPLETED', before that job's single COMMIT (unchanged from
-- migration 257's structure). The two writes are therefore genuinely
-- atomic, not merely "safely recoverable": if activation raised an
-- unexpected exception, the per-job EXCEPTION handler (unchanged, still
-- migration 257's) would catch it and record FAILED instead, exactly as
-- it already does for an attribution failure -- there is no
-- reachable state where a job reads COMPLETED without activation having
-- already been attempted in the same transaction.
--
-- One-time commissioning semantics (migration 256) are unaffected: this
-- migration never creates or touches metadata.asset_commissioning_
-- backfill's uniqueness or the Save-side trigger; it only reacts to an
-- already-existing record reaching COMPLETED.
--
-- Explicitly NOT in this migration:
--   * No change to migration 257's attribution function (no correctness
--     issue found).
--   * No new lifecycle value, no change to admin.validate_lifecycle_
--     transition()'s transition table (COMMISSIONING->ACTIVE already
--     existed).
--   * The scheduled job registration is untouched -- still
--     scheduled=>FALSE, exactly as migration 257 deliberately left it;
--     nothing in ADR-018 requires enabling it as part of this slice.
--   * No UI. No staging deployment.
-- ============================================================================


-- ----------------------------------------------------------------------------
-- 1. admin.activate_asset_after_commissioning_backfill.
-- ----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION admin.activate_asset_after_commissioning_backfill(
    p_backfill_id UUID
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO pg_catalog, admin, metadata
AS $function$
DECLARE
    v_asset_id                  UUID;
    v_triggered_by_portal_user  BIGINT;
    v_current_lifecycle         TEXT;
    v_validation                JSONB;
    v_audit_id                  UUID := gen_random_uuid();
    v_result                    JSONB;
BEGIN
    SELECT b.asset_id, b.triggered_by_portal_user_id
    INTO v_asset_id, v_triggered_by_portal_user
    FROM metadata.asset_commissioning_backfill b
    WHERE b.id = p_backfill_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Backfill record % was not found.', p_backfill_id;
    END IF;

    SELECT lifecycle_status INTO v_current_lifecycle
    FROM metadata.assets
    WHERE id = v_asset_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Asset % was not found.', v_asset_id;
    END IF;

    -- Not currently COMMISSIONING: either an administrator already moved
    -- it to INACTIVE/DECOMMISSIONED (never silently reactivate), or it is
    -- already ACTIVE (an idempotent rerun -- leave it alone), or some
    -- other state. In every case, a completed backfill is not itself
    -- grounds to change lifecycle_status here -- do nothing.
    IF v_current_lifecycle IS DISTINCT FROM 'COMMISSIONING' THEN
        RETURN jsonb_build_object(
            'activated', FALSE,
            'asset_id', v_asset_id,
            'backfill_id', p_backfill_id,
            'reason', 'NOT_IN_COMMISSIONING',
            'current_lifecycle_status', v_current_lifecycle
        );
    END IF;

    v_validation := admin.validate_lifecycle_transition('ASSET', v_asset_id, 'COMMISSIONING', 'ACTIVE');
    IF NOT (v_validation->>'allowed')::boolean THEN
        RETURN jsonb_build_object(
            'activated', FALSE,
            'asset_id', v_asset_id,
            'backfill_id', p_backfill_id,
            'reason', v_validation->>'reason',
            'current_lifecycle_status', v_current_lifecycle
        );
    END IF;

    UPDATE metadata.assets
    SET lifecycle_status = 'ACTIVE', status = 'active', updated_at = now()
    WHERE id = v_asset_id;

    v_result := jsonb_build_object(
        'activated', TRUE,
        'asset_id', v_asset_id,
        'backfill_id', p_backfill_id,
        'previous_lifecycle_status', 'COMMISSIONING',
        'lifecycle_status', 'ACTIVE',
        'audit_transaction_id', v_audit_id
    );

    INSERT INTO admin.onboarding_audit(id, requested_by, request_payload, result_payload)
    VALUES (
        v_audit_id,
        'system:telemetry.process_asset_commissioning_backfill',
        jsonb_build_object(
            'operation', 'ACTIVATE_ASSET_AFTER_COMMISSIONING_BACKFILL',
            'asset_id', v_asset_id,
            'backfill_id', p_backfill_id,
            'triggered_by_portal_user_id', v_triggered_by_portal_user,
            'previous_lifecycle_status', 'COMMISSIONING',
            'readiness_source', 'admin.validate_lifecycle_transition'
        ),
        v_result
    );

    RETURN v_result;
END;
$function$;

COMMENT ON FUNCTION admin.activate_asset_after_commissioning_backfill(UUID) IS
'ADR-018 Amendments 6/8/12 (migration 258): called by telemetry.process_asset_commissioning_backfill immediately after a successful backfill, in the SAME transaction as that job''s own COMPLETED status write (atomic). Transitions the asset COMMISSIONING -> ACTIVE via admin.validate_lifecycle_transition''s existing, unmodified ASSET rule, mirroring admin.commission_asset()''s direct-UPDATE/onboarding_audit shape. A no-op (activated=false, reason=NOT_IN_COMMISSIONING) whenever the asset is not currently COMMISSIONING -- this is the entire mechanism preventing reactivation of an asset an administrator has since moved to INACTIVE/DECOMMISSIONED, and what makes repeated completion/retry idempotent for an already-ACTIVE asset. Never called for a FAILED backfill. Does not create a new backfill record, does not touch metadata.asset_commissioning_backfill at all, and does not alter admin.commission_asset(), which remains untouched and unused by this flow.';

REVOKE ALL ON FUNCTION admin.activate_asset_after_commissioning_backfill(UUID) FROM PUBLIC;


-- ----------------------------------------------------------------------------
-- 2. telemetry.process_asset_commissioning_backfill -- migration 257's
--    body, with exactly one addition: on a successful attribution run,
--    call the activation function above, in the same transaction, before
--    marking the backfill COMPLETED. telemetry.backfill_asset_
--    commissioning_points (the attribution function) is untouched.
-- ----------------------------------------------------------------------------

CREATE OR REPLACE PROCEDURE telemetry.process_asset_commissioning_backfill(
    IN p_limit INTEGER DEFAULT 10
)
LANGUAGE plpgsql
AS $procedure$
DECLARE
    v_job        RECORD;
    v_summary    JSONB;
    v_activation JSONB;
    v_error      TEXT;
    v_sqlstate   TEXT;
BEGIN
    IF p_limit IS NULL OR p_limit < 1 OR p_limit > 1000 THEN
        RAISE EXCEPTION 'p_limit must be between 1 and 1000';
    END IF;

    FOR v_job IN
        SELECT id
        FROM metadata.asset_commissioning_backfill
        WHERE status = 'PENDING'
        ORDER BY requested_at
        LIMIT p_limit
        FOR UPDATE SKIP LOCKED
    LOOP
        -- Claim: durably mark RUNNING and commit immediately, so the
        -- status change alone (independent of any lock) excludes this
        -- row from every other concurrent/subsequent claiming query from
        -- this point on.
        UPDATE metadata.asset_commissioning_backfill
        SET status = 'RUNNING',
            started_at = now(),
            attempt_count = attempt_count + 1,
            updated_at = now()
        WHERE id = v_job.id;
        COMMIT;

        BEGIN
            v_summary := telemetry.backfill_asset_commissioning_points(v_job.id);

            -- Migration 258: activate in the SAME transaction as the
            -- COMPLETED write below -- atomic, and if this raises, the
            -- EXCEPTION handler records FAILED instead, exactly as an
            -- attribution failure already would.
            v_activation := admin.activate_asset_after_commissioning_backfill(v_job.id);

            UPDATE metadata.asset_commissioning_backfill
            SET status = 'COMPLETED',
                completed_at = now(),
                updated_at = now(),
                last_error = NULL
            WHERE id = v_job.id;
        EXCEPTION WHEN OTHERS THEN
            GET STACKED DIAGNOSTICS v_error = MESSAGE_TEXT, v_sqlstate = RETURNED_SQLSTATE;
            UPDATE metadata.asset_commissioning_backfill
            SET status = 'FAILED',
                failed_at = now(),
                updated_at = now(),
                last_error = v_sqlstate || ': ' || v_error
            WHERE id = v_job.id;
        END;

        COMMIT;
    END LOOP;
END;
$procedure$;

COMMENT ON PROCEDURE telemetry.process_asset_commissioning_backfill(INTEGER) IS
'ADR-018 Amendments 6-8/12 (migration 255''s claiming shape, extended by migration 258): claims up to p_limit PENDING metadata.asset_commissioning_backfill rows (FOR UPDATE SKIP LOCKED, oldest requested_at first), marks each RUNNING and commits immediately, runs telemetry.backfill_asset_commissioning_points, then admin.activate_asset_after_commissioning_backfill (migration 258 -- a no-op unless the asset is still COMMISSIONING), then commits COMPLETED (or, on any exception from either step, FAILED with SQLSTATE + message in last_error) -- the attribution write and the activation attempt are therefore atomic with the COMPLETED status write. Matches the telemetry.recover_failed_raw_messages precedent (postgres/ddl/126, migration 203).';


-- ----------------------------------------------------------------------------
-- 3. Postconditions.
-- ----------------------------------------------------------------------------

DO $post$
BEGIN
    IF to_regprocedure('admin.activate_asset_after_commissioning_backfill(uuid)') IS NULL THEN
        RAISE EXCEPTION 'Migration 258 postcondition failed: admin.activate_asset_after_commissioning_backfill(uuid) does not exist.';
    END IF;
    IF has_function_privilege('public', 'admin.activate_asset_after_commissioning_backfill(uuid)', 'EXECUTE') THEN
        RAISE EXCEPTION 'Migration 258 postcondition failed: admin.activate_asset_after_commissioning_backfill is executable by PUBLIC.';
    END IF;

    IF to_regprocedure('telemetry.process_asset_commissioning_backfill(integer)') IS NULL THEN
        RAISE EXCEPTION 'Migration 258 postcondition failed: telemetry.process_asset_commissioning_backfill(integer) does not exist.';
    END IF;

    -- The scheduled job registration must remain untouched (scheduled=FALSE).
    IF EXISTS (
        SELECT 1 FROM timescaledb_information.jobs
        WHERE proc_schema = 'telemetry' AND proc_name = 'run_asset_commissioning_backfill_job'
          AND scheduled = TRUE
    ) THEN
        RAISE EXCEPTION 'Migration 258 postcondition failed: the backfill job must remain scheduled=FALSE (unchanged from migration 257 -- not required by this slice).';
    END IF;

    -- admin.validate_lifecycle_transition's ASSET table already allows
    -- COMMISSIONING -> ACTIVE -- confirm this migration did not need to
    -- (and did not) change it.
    IF NOT ((admin.validate_lifecycle_transition('ASSET', gen_random_uuid(), 'COMMISSIONING', 'ACTIVE'))->>'allowed')::boolean THEN
        RAISE EXCEPTION 'Migration 258 postcondition failed: admin.validate_lifecycle_transition no longer allows ASSET COMMISSIONING -> ACTIVE.';
    END IF;

    RAISE NOTICE 'Migration 258: all postconditions passed (admin.activate_asset_after_commissioning_backfill deployed; telemetry.process_asset_commissioning_backfill extended atomically; scheduled job left disabled).';
END;
$post$;
