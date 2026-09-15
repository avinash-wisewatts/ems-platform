-- ============================================================================
-- Migration 242
-- MVP-7 Basic Alerts -- ADR-016 section 4/7 amendment (2026-09-15): data-
-- unavailable-while-Active messaging, and the recovery-while-still-material
-- transition (Option B -- ENDED, a second distinct Ended cause alongside
-- migration 239's configuration-transition cause).
--
-- Background (see ADR-016's 2026-09-15 amendment and ADR-017's conceptual-
-- data-model addition for the full record): a read-only investigation this
-- session found two real gaps in the deployed analytics.evaluate_alerts()
-- (migration 239, fixed by 241) against ADR-016 section 4:
--   1. The "remains Active during a gap" half was correctly implemented,
--      but the required customer messaging ("Unable to evaluate -- data
--      unavailable" / "Latest value: Data unavailable") did not exist at
--      any layer -- no persisted flag, no API field, no UI text.
--   2. Recovery while the condition is still material did not end the old
--      alert as section 4 requires -- it silently continued the same
--      Active row with no fresh qualification. Section 4's own original
--      wording ("resolved/ended per the applicable rule (section 3 or 6
--      as appropriate)") was itself found ambiguous -- neither section 3
--      nor 6 actually covers "still material on recovery". A three-option
--      product decision (Resolved / Ended / a new fourth state) was
--      presented without a recommendation; Ended was selected, with a
--      controlled (not free-text) two-value reason representation.
--
-- This migration:
--   - Adds analytics.alerts.data_unavailable (persisted Active-alert flag)
--     and analytics.alerts.ended_reason_code (controlled, enumerated:
--     CONFIGURATION_CHANGED | DATA_UNAVAILABLE -- the product decision;
--     the existing free-text ended_reason column's exact wording per code
--     remains an implementation/content detail, deliberately not the same
--     thing, per the product decision's own instruction).
--   - Extends analytics.evaluate_alerts() (CREATE OR REPLACE, same overall
--     shape/transaction structure as migration 241 -- no COMMIT placement
--     change, no SECURITY DEFINER/SET clause reintroduced) with:
--       * setting data_unavailable=TRUE on an Active alert when a run
--         observes NOT has_sufficient_data for its site+condition;
--       * a new check, structurally identical to the existing
--         configuration-transition check, that ends an Active alert whose
--         data_unavailable flag is set once the condition is observed
--         material again -- gated additionally on is_material so recovery
--         while NOT material is unaffected and still follows the existing,
--         unmodified normal resolution path;
--       * clearing data_unavailable back to FALSE on every path that
--         evaluates an Active alert with sufficient data (the "still
--         active, no gap" refresh) or transitions it to a terminal state
--         (RESOLVED, or either ENDED cause) -- required by the new
--         ck_alerts_data_unavailable_active_only constraint below.
--   - Extends analytics.get_portal_site_alerts (migration 240's version)
--     and analytics.get_portal_alert_detail (migration 239's version) to
--     return the two new columns. Both are extended identically because
--     they already share one row shape consumed by one Pydantic model
--     (AlertSummary, app/src/analytics_api_service.py) -- an
--     implementation-economy choice, not itself required by ADR-016
--     section 11's list-summary field set.
--
-- Also fixes a real, previously-latent defect discovered by this
-- migration's own live-execution test (scripts/test/assert_mvp7_alert_
-- data_unavailable_lifecycle_executes.sql): migration 239/241's
-- `v_active_alert := NULL;` (in the configuration-transition branch)
-- assigns NULL directly to a bare PL/pgSQL RECORD variable, which reverts
-- it to the "not yet assigned" state (distinct from a properly-typed
-- record whose fields are null) -- any subsequent field access then
-- raises "record ... is not assigned yet". Never triggered before because
-- that branch was itself unreachable; this migration's own structurally
-- identical new branch IS reachable, and hit it immediately under live
-- testing. Fixed in both places (the pre-existing configuration-
-- transition case and the new data-unavailable-recovery case) by
-- `SELECT * INTO v_active_alert FROM analytics.alerts WHERE FALSE;`
-- instead -- confirmed directly against a live instance to safely yield a
-- properly-typed empty record rather than an unassigned one.
--
-- Not touched, deliberately: qualification (5-minute), resolution
-- (1-minute), persistence-retry (30-minute), restart-resilience, retention
-- (90-day), recurrence-counting (already state-agnostic, confirmed
-- unaffected), and the existing configuration-transition cause's own
-- trigger condition -- all unchanged, per "do not change unrelated MVP-7
-- behavior".
--
-- Existing-data safety: confirmed live this session, analytics.alerts
-- currently has 0 RESOLVED/ENDED rows anywhere this migration will run
-- against in this repository's own environments -- no backfill is
-- required for correctness there. The defensive backfill UPDATE below
-- (populating ended_reason_code for any pre-existing ENDED row before the
-- NOT-NULL constraint is added) is included anyway so this migration is
-- correct in any environment, not merely the one verified live.
-- ============================================================================

BEGIN;

-- ----------------------------------------------------------------------------
-- 1. Schema: persisted data-unavailable flag and controlled Ended-reason
--    code.
-- ----------------------------------------------------------------------------

ALTER TABLE analytics.alerts
    ADD COLUMN IF NOT EXISTS data_unavailable BOOLEAN NOT NULL DEFAULT FALSE;

ALTER TABLE analytics.alerts
    ADD COLUMN IF NOT EXISTS ended_reason_code TEXT;

COMMENT ON COLUMN analytics.alerts.data_unavailable IS
'TRUE while this Active alert''s most recent evaluation could not complete (analytics.evaluate_energy_attention_materiality returned has_sufficient_data=FALSE) -- ADR-016 section 4. Always FALSE once the alert is no longer ACTIVE (see ck_alerts_data_unavailable_active_only). Drives the "Unable to evaluate -- data unavailable" / "Latest value: Data unavailable" customer messaging.';

COMMENT ON COLUMN analytics.alerts.ended_reason_code IS
'Controlled, enumerated Ended cause (ADR-016 section 7, amended 2026-09-15) -- CONFIGURATION_CHANGED or DATA_UNAVAILABLE. This code is the product-level decision (exactly these two causes exist today); the free-text ended_reason column''s exact customer-facing wording per code is a separate, unfixed implementation/content detail. NULL until Ended.';

-- Defensive backfill before the NOT-NULL-when-Ended constraint below --
-- every ENDED row that could exist before this migration was, by
-- definition of the pre-migration-242 code, only ever caused by a
-- configuration-transition.
UPDATE analytics.alerts
SET ended_reason_code = 'CONFIGURATION_CHANGED'
WHERE state = 'ENDED' AND ended_reason_code IS NULL;

-- CHECK constraints cannot be altered in place in PostgreSQL -- drop and
-- recreate the existing state/field-consistency constraint, extended to
-- also require ended_reason_code when Ended.
ALTER TABLE analytics.alerts DROP CONSTRAINT ck_alerts_state_fields;

ALTER TABLE analytics.alerts ADD CONSTRAINT ck_alerts_state_fields CHECK (
    (state = 'ACTIVE'   AND resolved_at IS NULL AND ended_at IS NULL)
    OR (state = 'RESOLVED' AND resolved_at IS NOT NULL AND resolved_value IS NOT NULL AND ended_at IS NULL)
    OR (state = 'ENDED'    AND ended_at IS NOT NULL AND ended_reason IS NOT NULL AND ended_reason_code IS NOT NULL AND resolved_at IS NULL)
);

ALTER TABLE analytics.alerts ADD CONSTRAINT ck_alerts_ended_reason_code_values CHECK (
    ended_reason_code IS NULL OR ended_reason_code IN ('CONFIGURATION_CHANGED', 'DATA_UNAVAILABLE')
);

-- data_unavailable is an "is this Active alert currently observable"
-- concept -- meaningless (and must not be silently stale) once the alert
-- has a terminal state.
ALTER TABLE analytics.alerts ADD CONSTRAINT ck_alerts_data_unavailable_active_only CHECK (
    NOT data_unavailable OR state = 'ACTIVE'
);

-- ----------------------------------------------------------------------------
-- 2. analytics.evaluate_alerts() -- extended lifecycle procedure.
--
-- Same overall structure as migration 241 (no SECURITY DEFINER, no SET
-- clause, same per-site exception-guarded block, same COMMIT placement).
-- Changes from migration 241 are marked "-- migration 242" inline.
-- ----------------------------------------------------------------------------

CREATE OR REPLACE PROCEDURE analytics.evaluate_alerts()
LANGUAGE plpgsql
AS $procedure$
DECLARE
    v_site               RECORD;
    v_eval                RECORD;
    v_active_alert        RECORD;
    v_candidate            RECORD;
    v_now                   TIMESTAMPTZ := clock_timestamp();
    -- Generous relative to the 1-minute job cadence -- absorbs one missed/
    -- overlapping run without falsely declaring a gap; a real gap (job
    -- paused, DB unavailable) is far longer than this in practice.
    v_gap_tolerance          CONSTANT INTERVAL := INTERVAL '3 minutes';
    v_qualification_window   CONSTANT INTERVAL := INTERVAL '5 minutes';
    v_resolution_window       CONSTANT INTERVAL := INTERVAL '1 minute';
    -- ADR-016 decision 6: retry persistence for up to 30 minutes from
    -- qualification (i.e. from since + 5 minutes), then discard.
    v_persistence_retry_limit  CONSTANT INTERVAL := INTERVAL '35 minutes';
BEGIN
    FOR v_site IN
        SELECT id, organization_id
        FROM metadata.sites
        WHERE is_active = TRUE
          AND lifecycle_status = 'ACTIVE'
    LOOP
        -- IMPORTANT: PL/pgSQL forbids COMMIT/ROLLBACK inside a block that
        -- has an EXCEPTION clause -- the block itself is implemented as a
        -- subtransaction, and transaction control cannot run inside one.
        -- Every code path below therefore falls through to the single
        -- COMMIT placed AFTER this block's END (never CONTINUE, which
        -- would skip that COMMIT and leave work uncommitted across
        -- iterations). The EXCEPTION handler itself needs no ROLLBACK --
        -- entering it automatically rolls back to the block's own
        -- savepoint, and the COMMIT after END then simply closes out that
        -- already-clean state.
        BEGIN
            SELECT * INTO v_eval
            FROM analytics.evaluate_energy_attention_materiality(v_site.id, v_now);

            IF NOT v_eval.has_sufficient_data THEN
                -- No usable observation this run. A gap during qualification
                -- or resolution resets that timer (ADR-016 decisions 2, 4);
                -- an already-Active alert is left Active (decision 4/5), but
                -- migration 242: flag it as currently unevaluable so the
                -- required customer messaging can be shown. No-op UPDATE
                -- when no Active alert exists for this site+condition.
                UPDATE analytics.alerts
                SET data_unavailable = TRUE, last_evaluated_at = v_now
                WHERE site_id = v_site.id
                  AND condition_key = v_eval.condition_key
                  AND state = 'ACTIVE';

                DELETE FROM analytics.alert_evaluation_candidates
                WHERE site_id = v_site.id
                  AND watch_state = 'WATCHING_TRIGGER';
                -- WATCHING_CLEAR candidates are intentionally left in place
                -- here: they belong to a specific Active alert whose data
                -- is now unavailable, which is the SAME "data unavailable
                -- while Active" case (decision 4), not a clear-timer gap.
            ELSE
                SELECT * INTO v_active_alert
                FROM analytics.alerts
                WHERE site_id = v_site.id AND state = 'ACTIVE'
                LIMIT 1;

                -- Configuration-transition detection (ADR-016 decisions 8,
                -- 12-14): an Active alert whose condition_key no longer
                -- matches what is currently being evaluated. Unreachable
                -- today (the policy is a static constant, ADR-010) but
                -- implemented so it is correct the moment a condition's
                -- definition ever changes. v_active_alert.alert_id IS NOT
                -- NULL (not FOUND -- FOUND is reassigned by every
                -- subsequent statement, including the UPDATE/DELETE just
                -- below, so it cannot be trusted past them).
                IF v_active_alert.alert_id IS NOT NULL AND v_active_alert.condition_key <> v_eval.condition_key THEN
                    UPDATE analytics.alerts
                    SET state = 'ENDED',
                        ended_at = v_now,
                        ended_reason = 'Attention condition configuration changed',
                        ended_reason_code = 'CONFIGURATION_CHANGED', -- migration 242
                        data_unavailable = FALSE, -- migration 242: terminal, no longer meaningful
                        last_evaluated_at = v_now
                    WHERE alert_id = v_active_alert.alert_id;

                    DELETE FROM analytics.alert_evaluation_candidates
                    WHERE site_id = v_site.id AND condition_key = v_active_alert.condition_key;

                    -- Fresh evaluation starts below with no prior Active
                    -- alert. migration 242: a bare `v_active_alert := NULL`
                    -- assignment here (the original migration-239/241 form)
                    -- is a real,
                    -- reproduced-live latent defect -- assigning NULL
                    -- directly to a bare RECORD variable reverts it to
                    -- PL/pgSQL's "not yet assigned" state (distinct from a
                    -- properly-typed record whose fields are null), and any
                    -- subsequent field access (e.g. the is_material check
                    -- below) then raises "record ... is not assigned yet".
                    -- Never triggered before because this branch was itself
                    -- unreachable; discovered by this migration's own live-
                    -- execution lifecycle test, which exercises the
                    -- structurally identical branch below. A zero-row
                    -- SELECT INTO, unlike a bare NULL assignment, safely
                    -- yields a properly-typed empty record (confirmed
                    -- directly against a live instance) -- used here instead.
                    SELECT * INTO v_active_alert FROM analytics.alerts WHERE FALSE;
                END IF;

                -- migration 242: data-unavailable-recovery-while-still-
                -- material detection (ADR-016 section 4, amended
                -- 2026-09-15) -- a second, independent Ended cause,
                -- structurally identical to the configuration-transition
                -- check above. Only relevant when the condition is
                -- CURRENTLY material: recovery while NOT material is
                -- unaffected and continues to the normal resolution path
                -- further below, per section 4's "no longer material ->
                -- normal resolution" rule.
                IF v_active_alert.alert_id IS NOT NULL
                   AND v_active_alert.condition_key = v_eval.condition_key
                   AND v_active_alert.data_unavailable
                   AND v_eval.is_material THEN
                    UPDATE analytics.alerts
                    SET state = 'ENDED',
                        ended_at = v_now,
                        ended_reason = 'Data was unavailable while this alert was active',
                        ended_reason_code = 'DATA_UNAVAILABLE',
                        data_unavailable = FALSE, -- terminal, no longer meaningful
                        last_evaluated_at = v_now
                    WHERE alert_id = v_active_alert.alert_id;

                    DELETE FROM analytics.alert_evaluation_candidates
                    WHERE site_id = v_site.id AND condition_key = v_active_alert.condition_key;

                    -- Fresh evaluation starts below with no prior Active
                    -- alert -- the 5-minute qualification window starts
                    -- from THIS observation (mirrors the configuration-
                    -- transition case above). See that case's comment for
                    -- why a zero-row SELECT INTO is used here instead of a
                    -- bare NULL assignment.
                    SELECT * INTO v_active_alert FROM analytics.alerts WHERE FALSE;
                END IF;

                IF v_eval.is_material THEN
                    IF v_active_alert.alert_id IS NOT NULL AND v_active_alert.condition_key = v_eval.condition_key THEN
                        -- Already Active under the same condition -- decision
                        -- 3: no repeated alerts. Abandon any resolution
                        -- attempt the condition briefly interrupted by
                        -- becoming true again. migration 242: also clears
                        -- data_unavailable -- this is a normal, sufficient-
                        -- data evaluation, so any prior gap has ended.
                        UPDATE analytics.alerts
                        SET last_evaluated_at = v_now, data_unavailable = FALSE
                        WHERE alert_id = v_active_alert.alert_id;
                        DELETE FROM analytics.alert_evaluation_candidates
                        WHERE site_id = v_site.id AND condition_key = v_eval.condition_key AND watch_state = 'WATCHING_CLEAR';
                    ELSE
                        -- No Active alert for this condition -- qualification path.
                        SELECT * INTO v_candidate
                        FROM analytics.alert_evaluation_candidates
                        WHERE site_id = v_site.id AND condition_key = v_eval.condition_key AND watch_state = 'WATCHING_TRIGGER';

                        IF NOT FOUND THEN
                            INSERT INTO analytics.alert_evaluation_candidates
                                (site_id, condition_key, watch_state, since, candidate_value, last_evaluated_at)
                            VALUES
                                (v_site.id, v_eval.condition_key, 'WATCHING_TRIGGER', v_now, v_eval.current_value, v_now);
                        ELSIF v_now - v_candidate.last_evaluated_at > v_gap_tolerance THEN
                            -- Gap -- reset (decision 2).
                            UPDATE analytics.alert_evaluation_candidates
                            SET since = v_now, candidate_value = v_eval.current_value, last_evaluated_at = v_now
                            WHERE site_id = v_site.id AND condition_key = v_eval.condition_key;
                        ELSE
                            UPDATE analytics.alert_evaluation_candidates
                            SET last_evaluated_at = v_now
                            WHERE site_id = v_site.id AND condition_key = v_eval.condition_key;

                            IF v_now - v_candidate.since >= v_qualification_window THEN
                                BEGIN
                                    INSERT INTO analytics.alerts
                                        (organization_id, site_id, condition_key, metric, state,
                                         triggered_at, trigger_value, last_evaluated_at)
                                    VALUES
                                        (v_site.organization_id, v_site.id, v_eval.condition_key, 'ENERGY_CONSUMPTION', 'ACTIVE',
                                         v_candidate.since, v_candidate.candidate_value, v_now);

                                    DELETE FROM analytics.alert_evaluation_candidates
                                    WHERE site_id = v_site.id AND condition_key = v_eval.condition_key;
                                EXCEPTION WHEN OTHERS THEN
                                    -- Persistence failure: candidate row
                                    -- (already durably committed on a prior
                                    -- run -- see the COMMIT after this outer
                                    -- block's END) is left in place so
                                    -- since/candidate_value survive; the next
                                    -- run retries this INSERT. Capped below.
                                    RAISE WARNING 'MVP-7 alert persistence failed for site %, condition %: %', v_site.id, v_eval.condition_key, SQLERRM;
                                END;
                            END IF;
                        END IF;

                        -- 30-minute-from-qualification discard (decision 6).
                        -- Re-select: the qualification branch above may have
                        -- just deleted the row (success) or left it in place
                        -- (not yet qualified, or qualified-but-failed).
                        SELECT * INTO v_candidate
                        FROM analytics.alert_evaluation_candidates
                        WHERE site_id = v_site.id AND condition_key = v_eval.condition_key AND watch_state = 'WATCHING_TRIGGER';

                        IF FOUND AND v_now - v_candidate.since >= v_persistence_retry_limit THEN
                            RAISE WARNING 'MVP-7 alert occurrence discarded after 30 minutes of persistence failure: site %, condition %, original trigger % / value %',
                                v_site.id, v_eval.condition_key, v_candidate.since, v_candidate.candidate_value;
                            DELETE FROM analytics.alert_evaluation_candidates
                            WHERE site_id = v_site.id AND condition_key = v_eval.condition_key;
                        END IF;
                    END IF;
                ELSE
                    -- Condition currently false (and sufficiently evaluated).
                    IF v_active_alert.alert_id IS NOT NULL AND v_active_alert.condition_key = v_eval.condition_key THEN
                        -- Resolution path.
                        SELECT * INTO v_candidate
                        FROM analytics.alert_evaluation_candidates
                        WHERE site_id = v_site.id AND condition_key = v_eval.condition_key AND watch_state = 'WATCHING_CLEAR';

                        IF NOT FOUND THEN
                            INSERT INTO analytics.alert_evaluation_candidates
                                (site_id, condition_key, watch_state, since, candidate_value, last_evaluated_at, alert_id)
                            VALUES
                                (v_site.id, v_eval.condition_key, 'WATCHING_CLEAR', v_now, v_eval.current_value, v_now, v_active_alert.alert_id);
                        ELSIF v_now - v_candidate.last_evaluated_at > v_gap_tolerance THEN
                            UPDATE analytics.alert_evaluation_candidates
                            SET since = v_now, candidate_value = v_eval.current_value, last_evaluated_at = v_now
                            WHERE site_id = v_site.id AND condition_key = v_eval.condition_key AND watch_state = 'WATCHING_CLEAR';
                        ELSE
                            UPDATE analytics.alert_evaluation_candidates
                            SET last_evaluated_at = v_now
                            WHERE site_id = v_site.id AND condition_key = v_eval.condition_key AND watch_state = 'WATCHING_CLEAR';

                            IF v_now - v_candidate.since >= v_resolution_window THEN
                                UPDATE analytics.alerts
                                SET state = 'RESOLVED',
                                    resolved_at = v_candidate.since,
                                    resolved_value = v_candidate.candidate_value,
                                    data_unavailable = FALSE, -- migration 242: terminal, no longer meaningful
                                    last_evaluated_at = v_now
                                WHERE alert_id = v_active_alert.alert_id;

                                DELETE FROM analytics.alert_evaluation_candidates
                                WHERE site_id = v_site.id AND condition_key = v_eval.condition_key AND watch_state = 'WATCHING_CLEAR';
                            END IF;
                        END IF;
                    ELSE
                        -- No Active alert, condition false -- nothing to
                        -- watch. An explicit false observation also breaks
                        -- any in-progress qualification streak (not only a
                        -- gap).
                        DELETE FROM analytics.alert_evaluation_candidates
                        WHERE site_id = v_site.id AND condition_key = v_eval.condition_key AND watch_state = 'WATCHING_TRIGGER';
                    END IF;
                END IF;
            END IF;
        EXCEPTION WHEN OTHERS THEN
            -- One site's failure must never abort evaluation for the rest
            -- of the site portfolio (do not create duplicate occurrences
            -- via a partial retry either -- the unique index on
            -- analytics.alerts is the final backstop regardless). Entering
            -- this handler implicitly rolls back to this block's own
            -- savepoint -- no explicit ROLLBACK (illegal here; see the
            -- note above this BEGIN).
            RAISE WARNING 'MVP-7 alert evaluation failed for site %: %', v_site.id, SQLERRM;
        END;

        -- Outside the exception-guarded block -- legal, and reached on
        -- every path (success or caught exception) since none of the
        -- branches above uses CONTINUE. Durable per-site commit: a later
        -- site's or run's failure can never undo this one.
        COMMIT;
    END LOOP;

    -- Retention (ADR-016 decision 9): 90 days from resolution/ending, Active
    -- retained indefinitely. Explicit DELETE, not a hypertable retention
    -- policy -- see migration 238's header note.
    DELETE FROM analytics.alerts WHERE state = 'RESOLVED' AND resolved_at < v_now - INTERVAL '90 days';
    DELETE FROM analytics.alerts WHERE state = 'ENDED' AND ended_at < v_now - INTERVAL '90 days';
    COMMIT;
END;
$procedure$;

COMMENT ON PROCEDURE analytics.evaluate_alerts() IS
'MVP-7 alert lifecycle: qualification (5 min), resolution (1 min), configuration-transition, data-unavailable-while-Active flagging and recovery-while-still-material transition (migration 242, ADR-016 section 4/7), persistence-retry (30 min from qualification), and 90-day retention. Commits per-site so already-durable qualification/resolution state survives a later site''s or run''s failure. See ADR-016/ADR-017. No SECURITY DEFINER / no SET search_path (migration 241 -- PostgreSQL forbids transaction control, i.e. the COMMITs above, inside a procedure with either property, in any calling context).';

ALTER PROCEDURE analytics.evaluate_alerts() OWNER TO ems_admin;
REVOKE ALL ON PROCEDURE analytics.evaluate_alerts() FROM PUBLIC;

-- ----------------------------------------------------------------------------
-- 3. Portal-scoped read functions -- extended to return the two new
--    columns. Both functions already return one identical row shape
--    consumed by one shared Pydantic model (AlertSummary); extended
--    identically for implementation economy, not because ADR-016 section
--    11's list-summary field set itself requires these columns at list
--    level.
-- ----------------------------------------------------------------------------

-- PostgreSQL forbids CREATE OR REPLACE from changing an existing
-- function's OUT-parameter (RETURNS TABLE) row shape -- the two new
-- columns require dropping and recreating both read functions (same
-- signature, so nothing else about how they're called changes).
DROP FUNCTION IF EXISTS analytics.get_portal_site_alerts(BIGINT, UUID, TEXT, TEXT, TIMESTAMPTZ, TIMESTAMPTZ, INT, TIMESTAMPTZ);

CREATE FUNCTION analytics.get_portal_site_alerts
(
    p_portal_user_id BIGINT,
    p_site_id        UUID,
    p_state          TEXT DEFAULT NULL,     -- ACTIVE | RESOLVED | ENDED | NULL (any)
    p_condition_key  TEXT DEFAULT NULL,
    p_from           TIMESTAMPTZ DEFAULT NULL,
    p_to             TIMESTAMPTZ DEFAULT NULL,
    p_limit          INT DEFAULT 50,
    p_before         TIMESTAMPTZ DEFAULT NULL  -- infinite-scroll cursor: triggered_at of the last row already seen
)
RETURNS TABLE
(
    alert_id          UUID,
    site_id            UUID,
    space_id            UUID,
    asset_id             UUID,
    condition_key         TEXT,
    metric                 TEXT,
    state                   TEXT,
    triggered_at             TIMESTAMPTZ,
    trigger_value             DOUBLE PRECISION,
    resolved_at                TIMESTAMPTZ,
    resolved_value               DOUBLE PRECISION,
    ended_at                       TIMESTAMPTZ,
    ended_reason                    TEXT,
    ended_reason_code                TEXT,
    data_unavailable                  BOOLEAN,
    previous_occurrence_count          BIGINT,
    most_recent_previous_triggered_at TIMESTAMPTZ
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO pg_catalog, analytics, admin
AS $function$
BEGIN
    IF NOT admin.portal_user_can_access_site(p_portal_user_id, p_site_id) THEN
        RETURN;
    END IF;

    RETURN QUERY
    SELECT
        a.alert_id, a.site_id, a.space_id, a.asset_id, a.condition_key, a.metric, a.state,
        a.triggered_at, a.trigger_value, a.resolved_at, a.resolved_value, a.ended_at, a.ended_reason,
        a.ended_reason_code, a.data_unavailable,
        (
            SELECT COUNT(*) FROM analytics.alerts AS prev
            WHERE prev.condition_key = a.condition_key AND prev.alert_id <> a.alert_id
              AND prev.triggered_at < a.triggered_at
        ) AS previous_occurrence_count,
        (
            SELECT MAX(prev.triggered_at) FROM analytics.alerts AS prev
            WHERE prev.condition_key = a.condition_key AND prev.alert_id <> a.alert_id
              AND prev.triggered_at < a.triggered_at
        ) AS most_recent_previous_triggered_at
    FROM analytics.alerts AS a
    WHERE a.site_id = p_site_id
      AND (p_state IS NULL OR a.state = p_state)
      AND (p_condition_key IS NULL OR a.condition_key = p_condition_key)
      -- ADR-016 decision 48: date range keyed to the field appropriate to
      -- EACH ROW's own state (Active -> triggered_at, Resolved ->
      -- resolved_at, Ended -> ended_at), not always triggered_at.
      AND (
          p_from IS NULL
          OR (a.state = 'ACTIVE'   AND a.triggered_at >= p_from)
          OR (a.state = 'RESOLVED' AND a.resolved_at  >= p_from)
          OR (a.state = 'ENDED'    AND a.ended_at      >= p_from)
      )
      AND (
          p_to IS NULL
          OR (a.state = 'ACTIVE'   AND a.triggered_at < p_to)
          OR (a.state = 'RESOLVED' AND a.resolved_at  < p_to)
          OR (a.state = 'ENDED'    AND a.ended_at      < p_to)
      )
      -- Infinite-scroll cursor and ordering are a pagination concern, not
      -- the date-range filter -- unchanged, still triggered_at-based.
      AND (p_before IS NULL OR a.triggered_at < p_before)
    ORDER BY a.triggered_at DESC
    LIMIT p_limit;
END;
$function$;

COMMENT ON FUNCTION analytics.get_portal_site_alerts(BIGINT, UUID, TEXT, TEXT, TIMESTAMPTZ, TIMESTAMPTZ, INT, TIMESTAMPTZ) IS
'MVP-7 alert list (Analytics API). Recurrence (previous_occurrence_count / most_recent_previous_triggered_at) is derived at read time, per ADR-017 -- never a stored counter, and correctly excludes occurrences of a different, superseding condition_key (ADR-016 decision 21). Ordering (materiality, then recency, ADR-016 decision 48) is applied by the caller -- MVP-7''s only condition has no materiality gradation. Date-range filter (p_from/p_to) is state-keyed (migration 240): triggered_at for ACTIVE, resolved_at for RESOLVED, ended_at for ENDED (ADR-016 decision 48). Migration 242: adds ended_reason_code (controlled Ended-cause code) and data_unavailable (current-gap flag, ADR-016 section 4).';

ALTER FUNCTION analytics.get_portal_site_alerts(BIGINT, UUID, TEXT, TEXT, TIMESTAMPTZ, TIMESTAMPTZ, INT, TIMESTAMPTZ) OWNER TO ems_admin;
REVOKE ALL ON FUNCTION analytics.get_portal_site_alerts(BIGINT, UUID, TEXT, TEXT, TIMESTAMPTZ, TIMESTAMPTZ, INT, TIMESTAMPTZ) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION analytics.get_portal_site_alerts(BIGINT, UUID, TEXT, TEXT, TIMESTAMPTZ, TIMESTAMPTZ, INT, TIMESTAMPTZ) TO ems_app;

DROP FUNCTION IF EXISTS analytics.get_portal_alert_detail(BIGINT, UUID);

CREATE FUNCTION analytics.get_portal_alert_detail
(
    p_portal_user_id BIGINT,
    p_alert_id       UUID
)
RETURNS TABLE
(
    alert_id          UUID,
    site_id            UUID,
    space_id            UUID,
    asset_id             UUID,
    condition_key         TEXT,
    metric                 TEXT,
    state                   TEXT,
    triggered_at             TIMESTAMPTZ,
    trigger_value             DOUBLE PRECISION,
    resolved_at                TIMESTAMPTZ,
    resolved_value               DOUBLE PRECISION,
    ended_at                       TIMESTAMPTZ,
    ended_reason                    TEXT,
    ended_reason_code                TEXT,
    data_unavailable                  BOOLEAN,
    previous_occurrence_count          BIGINT,
    most_recent_previous_triggered_at TIMESTAMPTZ
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO pg_catalog, analytics, admin
AS $function$
DECLARE
    v_site_id UUID;
BEGIN
    SELECT a.site_id INTO v_site_id FROM analytics.alerts AS a WHERE a.alert_id = p_alert_id;

    IF v_site_id IS NULL OR NOT admin.portal_user_can_access_site(p_portal_user_id, v_site_id) THEN
        RETURN;
    END IF;

    RETURN QUERY
    SELECT
        a.alert_id, a.site_id, a.space_id, a.asset_id, a.condition_key, a.metric, a.state,
        a.triggered_at, a.trigger_value, a.resolved_at, a.resolved_value, a.ended_at, a.ended_reason,
        a.ended_reason_code, a.data_unavailable,
        (
            SELECT COUNT(*) FROM analytics.alerts AS prev
            WHERE prev.condition_key = a.condition_key AND prev.alert_id <> a.alert_id
              AND prev.triggered_at < a.triggered_at
        ) AS previous_occurrence_count,
        (
            SELECT MAX(prev.triggered_at) FROM analytics.alerts AS prev
            WHERE prev.condition_key = a.condition_key AND prev.alert_id <> a.alert_id
              AND prev.triggered_at < a.triggered_at
        ) AS most_recent_previous_triggered_at
    FROM analytics.alerts AS a
    WHERE a.alert_id = p_alert_id;
END;
$function$;

COMMENT ON FUNCTION analytics.get_portal_alert_detail(BIGINT, UUID) IS
'MVP-7 alert detail (Analytics API). An inaccessible or unknown alert_id returns zero rows, identical to every other portal-scoped read function in this schema (migration 231 pattern) -- never a distinguishable error. Migration 242: adds ended_reason_code (controlled Ended-cause code) and data_unavailable (current-gap flag, ADR-016 section 4).';

ALTER FUNCTION analytics.get_portal_alert_detail(BIGINT, UUID) OWNER TO ems_admin;
REVOKE ALL ON FUNCTION analytics.get_portal_alert_detail(BIGINT, UUID) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION analytics.get_portal_alert_detail(BIGINT, UUID) TO ems_app;

COMMIT;
