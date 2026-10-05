-- ============================================================================
-- Migration 257
-- Asset Commissioning 90-day historical backfill worker (ADR-018
-- Amendments 6-8), built on migrations 253-256.
--
-- ----------------------------------------------------------------------------
-- Architectural trace performed before writing any code (per instructions).
-- ----------------------------------------------------------------------------
-- Candidate point-level telemetry/aggregate objects, and why each is or
-- isn't the right source for this backfill:
--
--   * telemetry.normalized_points (postgres/ddl/38) -- the canonical
--     point-level store: (device_id, logical_point_id, event_time,
--     numeric_value, ...), a TimescaleDB hypertable, retained exactly 90
--     days (SELECT add_retention_policy('telemetry.normalized_points',
--     INTERVAL '90 days'), migration 001 -- verified directly, matching
--     ADR-018 Amendment 8's own evidence). Indexed
--     (device_id, event_time DESC) and (logical_point_id, event_time
--     DESC) -- exactly the access pattern this backfill needs
--     (device+point+time-range lookups). This is the ONLY source used.
--   * analytics.generic_telemetry_15m / generic_telemetry_1h -- live,
--     populated continuous aggregates over the same (device_id,
--     logical_point_id) grain (ADR-018 Amendment 7's own evidence).
--     Considered and NOT used: this backfill needs to find the single
--     earliest raw event_time within a bounded window per (device,
--     point), which is a MIN() over normalized_points directly, not an
--     aggregation; using a 15-minute/hourly aggregate would only lose
--     precision here for no benefit, and neither aggregate carries
--     anything normalized_points itself lacks for this purpose.
--   * telemetry.energy_measurements / ca_energy_* (the wide, pivoted
--     domain tables) -- NOT usable, confirmed already by ADR-018
--     Amendment 7: these tables have named columns per electrical
--     quantity (active_power_total_w, ...), not logical_point_id rows,
--     so they cannot be joined against metadata.asset_points at all
--     without an unpivot this ADR explicitly defers as a separate,
--     unresolved design question. Out of scope here by the ADR's own
--     prior decision, not a new finding.
--
-- ----------------------------------------------------------------------------
-- The resolved mechanism: no data is copied, duplicated, or stamped.
-- ----------------------------------------------------------------------------
-- ADR-018 Amendment 7 ("Option A") is explicit and unambiguous that this
-- decision was already made, not open for reinterpretation here:
-- "attribution is expressed by resolving through asset_points against
-- the existing point-level record, not by duplicating data and stamping
-- it with asset_id... this decision does not create a second copy of
-- telemetry merely to establish asset ownership."
--
-- Given that, "backfilling into Asset history" (decision 5's phrase) does
-- not mean writing any new telemetry, aggregate, or domain-table row at
-- all. Every future read path that resolves an asset's history through
-- metadata.asset_points (Demand already does this today, migration 250;
-- Energy/Power read paths are intended to per Amendment 7) determines
-- "is this telemetry the asset's history" purely from whether the
-- reading's event_time falls inside a confirmed asset_points row's
-- effective_range. Historical backfill is therefore fully and correctly
-- achieved by widening that SAME row's effective_from backward -- to the
-- earliest actually-retained telemetry for that exact (device_id,
-- logical_point_id), bounded to at most 90 days before the point was
-- confirmed, and bounded so it never reaches into a period a DIFFERENT
-- prior binding for that same device+point already owns. No new row, no
-- new table, no duplicated telemetry; the existing point-level foundation
-- (telemetry.normalized_points) is read-only input, and the only write is
-- to the effective_from column already built for exactly this purpose by
-- migration 224/228.
--
-- No architectural gap was found. The schema already fully supports this
-- backfill without copying or rebuilding any data -- by design, per
-- Amendment 7. This migration implements exactly that mechanism.
--
-- ----------------------------------------------------------------------------
-- What gets backfilled, precisely.
-- ----------------------------------------------------------------------------
-- Only the SPECIFIC metadata.asset_points rows created by the Save call
-- that triggered this backfill record (migration 256's
-- trigger_audit_transaction_id, resolved via admin.onboarding_audit.
-- result_payload->'added'.asset_point_id) -- never any point added by a
-- LATER, separate Save (those already correctly get "no backfill, starts
-- at assignment time" per decision 6, simply by never being read here).
-- This is what makes "later assignment to another source does not
-- rewrite earlier Asset history" and "do not backfill points assigned
-- after the historical period" hold by construction, not by an extra
-- check: a later Save's added points are never in scope for any
-- pre-existing backfill record's work.
--
-- For each targeted asset_points row:
--   window_lower  = GREATEST(
--                        asset_commissioning_backfill.requested_at
--                            - INTERVAL '90 days',              -- Amendment 8
--                        prior_binding_effective_to              -- decision 8:
--                    )                                            -- never reach
--                                                                  -- into a
--                                                                  -- different
--                                                                  -- prior
--                                                                  -- binding's
--                                                                  -- period for
--                                                                  -- the same
--                                                                  -- (device,
--                                                                  -- point)
--   earliest      = MIN(event_time) FROM telemetry.normalized_points
--                    WHERE device_id/logical_point_id match
--                      AND event_time >= window_lower
--                      AND event_time <  asset_points.effective_from (current)
--   IF earliest IS NOT NULL: UPDATE asset_points SET effective_from = earliest
--   (no row found in the window -> no mutation; "do not invent data")
--
-- requested_at (not the row's own effective_from) anchors the 90-day
-- bound because it is immutable across retries -- the row's own
-- effective_from is exactly what this job mutates, so anchoring the
-- window to it would let repeated retries creep the window backward
-- indefinitely. Anchoring to requested_at (set once, at commissioning-
-- trigger time, migration 256) keeps every rerun bounded to the SAME
-- 90-day ceiling and makes the computation idempotent: a rerun searches
-- [window_lower, current_effective_from) and can only ever find an
-- earlier-or-equal minimum than a prior run already found, converging to
-- a fixed point rather than drifting.
--
-- ----------------------------------------------------------------------------
-- Job scheduling mechanism -- mirrors the existing recovery-job pattern
-- exactly (telemetry.recover_failed_raw_messages / run_failed_message_
-- recovery_job, postgres/ddl/126): a claiming loop procedure using
-- FOR UPDATE SKIP LOCKED with a COMMIT per job (so a concurrent worker's
-- claiming query can never see, lock, or reprocess a row another worker
-- already claimed -- requirement 11), a thin (job_id, config) wrapper
-- procedure for the TimescaleDB job scheduler to CALL, and an idempotent
-- add_job registration.
--
-- Deliberately registered with scheduled=>FALSE. This is a new mechanism
-- that mutates metadata.asset_points.effective_from -- a first run in
-- production should be an explicit, operator-triggered CALL (or a
-- follow-up migration once this slice is proven), not an automatically
-- firing job the moment this migration is applied. Consistent with the
-- task's own phasing: prove the worker before any ACTIVE transition.
--
-- ----------------------------------------------------------------------------
-- Explicitly NOT in this migration (deferred, per the approved scope):
--   * The COMMISSIONING -> ACTIVE transition -- a separate slice, once
--     this worker is proven. This migration never sets lifecycle_status.
--   * Any UI.
--   * Any staging deployment or job enablement (scheduled=>FALSE).
-- ============================================================================


-- ----------------------------------------------------------------------------
-- 1. telemetry.backfill_asset_commissioning_points -- the per-job
--    attribution-window computation. Idempotent, read-only against
--    telemetry.normalized_points; its only write is metadata.
--    asset_points.effective_from, and only ever backward (earlier).
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
'ADR-018 Amendments 6-8 (migration 257): for the given metadata.asset_commissioning_backfill record, widens effective_from (never any other column) on exactly the metadata.asset_points rows created by the triggering Save (resolved via admin.onboarding_audit.result_payload->''added'' for trigger_audit_transaction_id) back to the earliest telemetry.normalized_points event within [requested_at - 90 days, current effective_from), bounded below by any prior binding''s effective_to for the same (device_id, logical_point_id). No telemetry is read, copied, or written anywhere else. Idempotent: reruns converge (a rerun can only find an earlier-or-equal minimum within an already-narrower window) and are safe to repeat any number of times. Does not touch metadata.assets.lifecycle_status or the backfill record''s own status -- purely the point-level attribution computation, called by telemetry.process_asset_commissioning_backfill.';


-- ----------------------------------------------------------------------------
-- 2. telemetry.process_asset_commissioning_backfill -- the claiming loop.
--    Mirrors telemetry.recover_failed_raw_messages (postgres/ddl/126)
--    exactly: FOR UPDATE SKIP LOCKED, one COMMIT per claimed job so a
--    concurrent invocation can never see or reprocess an already-claimed
--    row, per-job EXCEPTION handling so one failure never blocks the
--    batch.
-- ----------------------------------------------------------------------------

CREATE OR REPLACE PROCEDURE telemetry.process_asset_commissioning_backfill(
    IN p_limit INTEGER DEFAULT 10
)
LANGUAGE plpgsql
AS $procedure$
DECLARE
    v_job        RECORD;
    v_summary    JSONB;
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
        -- this point on -- requirement 11.
        UPDATE metadata.asset_commissioning_backfill
        SET status = 'RUNNING',
            started_at = now(),
            attempt_count = attempt_count + 1,
            updated_at = now()
        WHERE id = v_job.id;
        COMMIT;

        BEGIN
            v_summary := telemetry.backfill_asset_commissioning_points(v_job.id);

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
'ADR-018 Amendments 6-8 (migration 257): claims up to p_limit PENDING metadata.asset_commissioning_backfill rows (oldest requested_at first, FOR UPDATE SKIP LOCKED so concurrent invocations never process the same Asset), marks each RUNNING and commits immediately, runs telemetry.backfill_asset_commissioning_points for it, then commits COMPLETED or (on any exception) FAILED with SQLSTATE + message in last_error. Each job is its own durable unit of work -- a crash or cancellation mid-batch leaves already-finished jobs committed and only the in-flight one at risk, matching the telemetry.recover_failed_raw_messages precedent (postgres/ddl/126, migration 203).';


-- ----------------------------------------------------------------------------
-- 3. telemetry.retry_failed_asset_commissioning_backfill -- explicit
--    requeue for a FAILED record. Resets exactly the columns the PENDING
--    branch of ck_asset_commissioning_backfill_status_timestamps
--    requires; last_error is preserved until the next attempt overwrites
--    or clears it, for diagnosis continuity.
-- ----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION telemetry.retry_failed_asset_commissioning_backfill(
    p_backfill_id UUID
)
RETURNS BOOLEAN
LANGUAGE plpgsql
AS $function$
DECLARE
    v_row_count INTEGER;
BEGIN
    UPDATE metadata.asset_commissioning_backfill
    SET status = 'PENDING',
        started_at = NULL,
        completed_at = NULL,
        failed_at = NULL,
        updated_at = now()
    WHERE id = p_backfill_id
      AND status = 'FAILED';

    GET DIAGNOSTICS v_row_count = ROW_COUNT;
    RETURN v_row_count > 0;
END;
$function$;

COMMENT ON FUNCTION telemetry.retry_failed_asset_commissioning_backfill(UUID) IS
'Requeues a FAILED metadata.asset_commissioning_backfill record back to PENDING (only from FAILED -- a no-op returning FALSE for any other status) so the next telemetry.process_asset_commissioning_backfill run picks it up. last_error is preserved until the retry attempt itself succeeds or fails again. The underlying attribution computation (telemetry.backfill_asset_commissioning_points) is idempotent, so retrying is always safe.';


-- ----------------------------------------------------------------------------
-- 4. Scheduler wrapper + idempotent job registration (scheduled=>FALSE --
--    see migration header). Mirrors run_failed_message_recovery_job
--    exactly.
-- ----------------------------------------------------------------------------

CREATE OR REPLACE PROCEDURE telemetry.run_asset_commissioning_backfill_job(job_id INTEGER, config JSONB)
LANGUAGE plpgsql
AS $$
DECLARE
    v_limit INTEGER := 10;
BEGIN
    IF config IS NOT NULL AND config ? 'limit'
       AND NULLIF(btrim(config->>'limit'), '') IS NOT NULL THEN
        v_limit := (config->>'limit')::INTEGER;
    END IF;
    CALL telemetry.process_asset_commissioning_backfill(v_limit);
END;
$$;

DO $$
DECLARE
    v_job_id INTEGER;
BEGIN
    SELECT job_id INTO v_job_id
    FROM timescaledb_information.jobs
    WHERE proc_schema = 'telemetry' AND proc_name = 'run_asset_commissioning_backfill_job'
    ORDER BY job_id LIMIT 1;

    IF v_job_id IS NULL THEN
        SELECT add_job('telemetry.run_asset_commissioning_backfill_job', INTERVAL '5 minutes',
                       config => jsonb_build_object('limit', 10),
                       scheduled => FALSE) INTO v_job_id;
    END IF;

    PERFORM alter_job(v_job_id,
        schedule_interval => INTERVAL '5 minutes',
        max_runtime => INTERVAL '10 minutes',
        max_retries => 1,
        retry_period => INTERVAL '5 minutes',
        scheduled => FALSE,
        config => jsonb_build_object('limit', 10));
END;
$$;


-- ----------------------------------------------------------------------------
-- 5. Postconditions.
-- ----------------------------------------------------------------------------

DO $post$
BEGIN
    IF to_regprocedure('telemetry.backfill_asset_commissioning_points(uuid)') IS NULL THEN
        RAISE EXCEPTION 'Migration 257 postcondition failed: telemetry.backfill_asset_commissioning_points(uuid) does not exist.';
    END IF;
    IF to_regprocedure('telemetry.process_asset_commissioning_backfill(integer)') IS NULL THEN
        RAISE EXCEPTION 'Migration 257 postcondition failed: telemetry.process_asset_commissioning_backfill(integer) does not exist.';
    END IF;
    IF to_regprocedure('telemetry.retry_failed_asset_commissioning_backfill(uuid)') IS NULL THEN
        RAISE EXCEPTION 'Migration 257 postcondition failed: telemetry.retry_failed_asset_commissioning_backfill(uuid) does not exist.';
    END IF;
    IF to_regprocedure('telemetry.run_asset_commissioning_backfill_job(integer,jsonb)') IS NULL THEN
        RAISE EXCEPTION 'Migration 257 postcondition failed: telemetry.run_asset_commissioning_backfill_job(integer,jsonb) does not exist.';
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM timescaledb_information.jobs
        WHERE proc_schema = 'telemetry' AND proc_name = 'run_asset_commissioning_backfill_job'
    ) THEN
        RAISE EXCEPTION 'Migration 257 postcondition failed: the scheduled job was not registered.';
    END IF;

    IF EXISTS (
        SELECT 1 FROM timescaledb_information.jobs
        WHERE proc_schema = 'telemetry' AND proc_name = 'run_asset_commissioning_backfill_job'
          AND scheduled = TRUE
    ) THEN
        RAISE EXCEPTION 'Migration 257 postcondition failed: the job must be registered with scheduled=FALSE (deliberate -- see migration header).';
    END IF;

    RAISE NOTICE 'Migration 257: all postconditions passed (backfill worker deployed: attribution function, claiming procedure, retry helper, scheduler wrapper registered with scheduled=FALSE).';
END;
$post$;
