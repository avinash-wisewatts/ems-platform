-- ============================================================================
-- Migration 241
-- MVP-7 Basic Alerts -- fix analytics.evaluate_alerts()'s transaction-control
-- defect that made every staging execution of the alert-evaluation job fail.
--
-- Defect (discovered and root-caused during the 2026-09-14 corrective
-- passes; job 1127 was explicitly authorized, registered on staging, and
-- then explicitly disabled after 3/3 executions failed identically):
--   analytics.evaluate_alerts() (migration 239) is declared SECURITY DEFINER
--   and SET search_path TO pg_catalog, analytics, admin, and contains
--   explicit COMMIT statements (a per-site COMMIT after each loop
--   iteration, line 404 of that migration, and a final retention COMMIT,
--   line 412). PostgreSQL forbids COMMIT/ROLLBACK inside a procedure that
--   has EITHER the SECURITY DEFINER property OR a SET-configuration clause,
--   in ANY calling context -- top level or nested. Live staging error:
--   sqlerrcode 2D000, "invalid transaction termination".
--
--   Confirmed empirically (disposable local TimescaleDB containers, not
--   staging/production) by isolating each variable independently:
--     - a plain procedure with a per-loop-iteration COMMIT succeeds, both
--       called at the top level and nested inside another procedure;
--     - the SAME procedure made SECURITY DEFINER fails identically in both
--       contexts;
--     - the SAME procedure with only a SET clause added (no SECURITY
--       DEFINER) ALSO fails identically;
--     - the real analytics.evaluate_alerts() body, with BOTH properties
--       removed and everything else byte-identical, succeeds via the real,
--       unmodified analytics.run_alert_evaluation_job() nested-CALL path.
--   Nesting itself is NOT the cause (an earlier investigation pass had
--   attributed it to nesting alone -- that was incomplete; corrected here).
--
-- Fix, minimum necessary: CREATE OR REPLACE the procedure with the SAME
-- body (byte-identical control flow, comments, and SQL statements),
-- removing only the two lines that make transaction control illegal here.
-- Neither is load-bearing:
--   - SECURITY DEFINER exists to let a lower-privileged caller (e.g.
--     ems_app, which owns none of analytics.alerts/alert_evaluation_
--     candidates) act with the procedure owner's (ems_admin) privileges.
--     But this procedure is ONLY ever invoked by the TimescaleDB job
--     scheduler, and job 1127's owner (confirmed live, read-only query,
--     2026-09-14) is ems_admin -- the same role that already owns this
--     procedure and the tables it touches. SECURITY DEFINER never actually
--     elevates privilege on this call path.
--   - SET search_path exists as a standard SECURITY DEFINER hardening
--     measure (prevents search-path hijacking of an elevated-privilege
--     call). Every table/function reference inside this procedure is
--     already fully schema-qualified (analytics.alerts, metadata.sites,
--     analytics.evaluate_energy_attention_materiality, ...) -- confirmed by
--     inspection, zero unqualified references -- so the clause is not
--     load-bearing for correctness, and its security rationale is moot
--     once SECURITY DEFINER is gone (no privilege elevation left to
--     protect).
--
-- Explicitly NOT changed by this migration (per the corrective-pass scope):
--   - analytics.run_alert_evaluation_job(job_id, config) -- unchanged,
--     still nests a CALL to analytics.evaluate_alerts() exactly as before.
--     This is consistent with the existing repository convention: every
--     other TimescaleDB job wrapper in this codebase (e.g.
--     telemetry.run_environment_routing_job -> CALL
--     telemetry.load_environment_measurements_incremental, postgres/ddl/
--     68_incremental_environment_loader.sql) also nests a CALL to a
--     separate business-logic procedure; that pattern is not itself the
--     defect and did not need restructuring.
--   - postgres/jobs/238_alert_evaluation_job.sql (job registration SQL).
--   - job 1127's registration/configuration on staging -- untouched by
--     this migration; it remains explicitly disabled.
--   - the alert schema (migration 238), any API contract (migration
--     239/240's read functions), or any alert lifecycle semantics
--     (qualification/resolution/recurrence/retention rules).
--
-- Idempotency: a single CREATE OR REPLACE PROCEDURE statement -- inherently
-- idempotent (re-applying it is a no-op past the first application, same
-- convention as migration 240). CREATE OR REPLACE preserves the existing
-- object identity/OID, so ownership and grants survive automatically; the
-- ALTER/REVOKE statements below restate them explicitly anyway, matching
-- migration 240's own justification: not required for correctness, kept
-- for self-contained static verifiability.
--
-- Rollback: CREATE OR REPLACE FUNCTION analytics.evaluate_alerts() with
-- migration 239's original SECURITY DEFINER / SET search_path clauses
-- restored -- safe (same signature, same body otherwise), though it would
-- restore the transaction-termination defect this migration fixes.
--
-- New tests: scripts/test/assert_mvp7_alert_evaluation_job_executes.sh
-- (live-execution integration test against the disposable TimescaleDB test
-- database -- the exact coverage gap that let this defect ship
-- undetected: static contract tests can verify COMMIT *placement* but not
-- whether that COMMIT is *legal* at the actual security/call context).
-- ============================================================================

BEGIN;

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
                -- an already-Active alert is left untouched (decision 5).
                DELETE FROM analytics.alert_evaluation_candidates
                WHERE site_id = v_site.id
                  AND watch_state = 'WATCHING_TRIGGER';
                -- WATCHING_CLEAR candidates are intentionally left in place
                -- here: they belong to a specific Active alert whose data
                -- is now unavailable, which is the SAME "data unavailable
                -- while Active" case (decision 5), not a clear-timer gap.
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
                        last_evaluated_at = v_now
                    WHERE alert_id = v_active_alert.alert_id;

                    DELETE FROM analytics.alert_evaluation_candidates
                    WHERE site_id = v_site.id AND condition_key = v_active_alert.condition_key;

                    -- Fresh evaluation starts below with no prior Active alert.
                    v_active_alert := NULL;
                END IF;

                IF v_eval.is_material THEN
                    IF v_active_alert.alert_id IS NOT NULL AND v_active_alert.condition_key = v_eval.condition_key THEN
                        -- Already Active under the same condition -- decision
                        -- 3: no repeated alerts. Abandon any resolution
                        -- attempt the condition briefly interrupted by
                        -- becoming true again.
                        UPDATE analytics.alerts SET last_evaluated_at = v_now WHERE alert_id = v_active_alert.alert_id;
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
'MVP-7 alert lifecycle: qualification (5 min), resolution (1 min), configuration-transition, persistence-retry (30 min from qualification), and 90-day retention. Commits per-site so already-durable qualification/resolution state survives a later site''s or run''s failure. See ADR-016/ADR-017. Migration 241: no longer SECURITY DEFINER / no SET search_path -- PostgreSQL forbids transaction control (the per-site and retention COMMITs above) inside a procedure with either property, in any calling context; neither was load-bearing here (job 1127 runs as ems_admin, the procedure owner; every reference in this body is already schema-qualified).';

ALTER PROCEDURE analytics.evaluate_alerts() OWNER TO ems_admin;
REVOKE ALL ON PROCEDURE analytics.evaluate_alerts() FROM PUBLIC;

COMMIT;
