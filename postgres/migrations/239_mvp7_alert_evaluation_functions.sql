-- ============================================================================
-- Migration 239
-- MVP-7 Basic Alerts -- evaluation function, lifecycle procedure, job
-- wrapper, and portal-scoped read functions. Companion to migration 238
-- (schema). See that migration's header for the source-of-record ADRs and
-- the two implementation-discovered design notes (evaluation period =
-- most recent completed site-local day; retention via explicit DELETE, not
-- a hypertable retention policy) -- both apply identically here.
-- ============================================================================

BEGIN;

-- ----------------------------------------------------------------------------
-- 1. analytics.evaluate_energy_attention_materiality
--
-- The canonical, single-source-of-truth implementation of the Energy
-- Attention rule for the alerting concern (ADR-017 "Single-source-of-truth
-- arrangement"). Replicates web/src/attention/materiality-policy.ts +
-- web/src/attention/energyAttention.ts EXACTLY:
--   - threshold = 15 (MVP3_MATERIALITY_POLICY.thresholdPercent)
--   - epsilon   = 1e-9 (THRESHOLD_EPSILON, commit e64c1e3)
--   - deviation% = (current - typical) / typical * 100
--   - HIGH when deviation% >= threshold - epsilon
--   - LOW  when deviation% <= -threshold + epsilon
--   - no Attention when insufficient data, no current data, or a null/zero
--     typical reference (division guarded below)
--
-- NOT a wrapper around analytics.get_portal_site_energy_typical_reference
-- (migration 236) -- that function requires a p_portal_user_id and enforces
-- portal-session tenant scope via admin.portal_user_can_access_site, which
-- has no meaning for an unattended background job evaluating every site.
-- This function therefore reads analytics.energy_consumption_daily
-- directly, replicating migration 236's window/eligibility/median query
-- (Slice C, ADR-009) verbatim for the internal-evaluation privilege
-- context. This is a deliberate, flagged duplication of the WINDOWING
-- query (not of the materiality THRESHOLD rule, which stays single-
-- sourced here) -- see this session's implementation report.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION analytics.evaluate_energy_attention_materiality
(
    p_site_id UUID,
    p_as_of   TIMESTAMPTZ DEFAULT clock_timestamp()
)
RETURNS TABLE
(
    condition_key           TEXT,
    has_sufficient_data     BOOLEAN,
    is_material              BOOLEAN,
    direction                 TEXT,
    current_value              DOUBLE PRECISION,
    typical_reference_value    DOUBLE PRECISION,
    deviation_percent           DOUBLE PRECISION,
    window_from                  TIMESTAMPTZ,
    window_to                     TIMESTAMPTZ
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO pg_catalog, analytics, admin
AS $function$
DECLARE
    v_threshold        CONSTANT NUMERIC := 15;
    v_epsilon          CONSTANT NUMERIC := 1e-9;
    v_min_eligible     CONSTANT INT := 5;
    v_step_days        CONSTANT INT := 7;

    v_site_timezone    TEXT;
    v_eval_date        DATE;
    v_window_from      TIMESTAMPTZ;
    v_window_to        TIMESTAMPTZ;
    v_condition_key    TEXT;

    v_current_kwh      NUMERIC;
    v_current_has_data BOOLEAN;

    v_eligible_count   INT;
    v_typical_kwh      NUMERIC;

    v_deviation        NUMERIC;
    v_direction        TEXT;
    v_is_material      BOOLEAN;
BEGIN
    v_condition_key := format('ENERGY_ATTENTION:PERCENT_DEVIATION_FROM_TYPICAL_REFERENCE:15:SITE:%s', p_site_id);

    SELECT s.timezone INTO v_site_timezone FROM metadata.sites AS s WHERE s.id = p_site_id;
    IF v_site_timezone IS NULL THEN
        RETURN QUERY SELECT v_condition_key, FALSE, FALSE, NULL::TEXT,
                            NULL::DOUBLE PRECISION, NULL::DOUBLE PRECISION, NULL::DOUBLE PRECISION,
                            NULL::TIMESTAMPTZ, NULL::TIMESTAMPTZ;
        RETURN;
    END IF;

    -- Most recent COMPLETED site-local calendar day -- see migration 238's
    -- header note on why "today so far" cannot be used here.
    v_eval_date   := ((p_as_of AT TIME ZONE v_site_timezone)::DATE) - 1;
    v_window_from := (v_eval_date::TIMESTAMP AT TIME ZONE v_site_timezone);
    v_window_to   := ((v_eval_date + 1)::TIMESTAMP AT TIME ZONE v_site_timezone);

    SELECT
        SUM(d.import_consumption_kwh),
        COUNT(d.consumption_date) > 0
    INTO v_current_kwh, v_current_has_data
    FROM analytics.energy_consumption_daily AS d
    WHERE d.site_id = p_site_id
      AND d.consumption_date = v_eval_date;

    -- Slice C: median of up to 8 comparable, 70%-coverage-eligible prior
    -- occurrences of this same 1-day period, stepping back 7 days at a
    -- time -- identical rule to migration 236 (ADR-009), replicated here
    -- (not called) for the reason in this function's header comment.
    WITH indices AS (
        SELECT generate_series(1, 8) AS k
    ),
    windows AS (
        SELECT
            k,
            (v_eval_date - (k * v_step_days)) AS window_date
        FROM indices
    ),
    aggregated AS (
        SELECT
            w.k,
            d.consumption_date,
            d.import_consumption_kwh,
            d.source_interval_count,
            d.valid_import_intervals
        FROM windows AS w
        LEFT JOIN analytics.energy_consumption_daily AS d
          ON d.site_id = p_site_id
         AND d.consumption_date = w.window_date
    ),
    eligibility AS (
        SELECT
            a.k,
            a.import_consumption_kwh,
            COALESCE(
                a.consumption_date IS NOT NULL
                AND COALESCE(a.source_interval_count, 0) > 0
                AND COALESCE(a.valid_import_intervals, 0)::NUMERIC / NULLIF(a.source_interval_count, 0) >= 0.70,
                FALSE
            ) AS eligible
        FROM aggregated AS a
    )
    SELECT
        COUNT(*) FILTER (WHERE eligible),
        percentile_cont(0.5) WITHIN GROUP (ORDER BY import_consumption_kwh)
            FILTER (WHERE eligible AND import_consumption_kwh IS NOT NULL)
    INTO v_eligible_count, v_typical_kwh
    FROM eligibility;

    IF NOT v_current_has_data
       OR v_eligible_count < v_min_eligible
       OR v_typical_kwh IS NULL
       OR v_typical_kwh = 0
    THEN
        RETURN QUERY SELECT v_condition_key, FALSE, FALSE, NULL::TEXT,
                            v_current_kwh::DOUBLE PRECISION, v_typical_kwh::DOUBLE PRECISION, NULL::DOUBLE PRECISION,
                            v_window_from, v_window_to;
        RETURN;
    END IF;

    v_deviation := (v_current_kwh - v_typical_kwh) / v_typical_kwh * 100;

    IF v_deviation >= v_threshold - v_epsilon THEN
        v_direction := 'HIGH';
        v_is_material := TRUE;
    ELSIF v_deviation <= -v_threshold + v_epsilon THEN
        v_direction := 'LOW';
        v_is_material := TRUE;
    ELSE
        v_direction := NULL;
        v_is_material := FALSE;
    END IF;

    RETURN QUERY SELECT v_condition_key, TRUE, v_is_material, v_direction,
                        v_current_kwh::DOUBLE PRECISION, v_typical_kwh::DOUBLE PRECISION, v_deviation::DOUBLE PRECISION,
                        v_window_from, v_window_to;
END;
$function$;

COMMENT ON FUNCTION analytics.evaluate_energy_attention_materiality(UUID, TIMESTAMPTZ) IS
'Canonical (single-source-of-truth) server-side implementation of the +/-15% Energy Attention rule, for MVP-7 alert evaluation only (ADR-017). Must be kept in exact parity with web/src/attention/materiality-policy.ts + energyAttention.ts -- see app/tests/test_alert_evaluation_contract.py::test_materiality_parity_fixtures for the mandatory parity check ADR-017 requires before this function may be relied on.';

ALTER FUNCTION analytics.evaluate_energy_attention_materiality(UUID, TIMESTAMPTZ) OWNER TO ems_admin;
REVOKE ALL ON FUNCTION analytics.evaluate_energy_attention_materiality(UUID, TIMESTAMPTZ) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION analytics.evaluate_energy_attention_materiality(UUID, TIMESTAMPTZ) TO ems_app;

-- ----------------------------------------------------------------------------
-- 2. analytics.evaluate_alerts -- the lifecycle procedure (ADR-016
--    decisions 2-8; ADR-017 evaluation/persistence boundary). A PROCEDURE,
--    not a function, so it can COMMIT per-site: qualification/resolution
--    state must be durable and idempotent across runs, per this session's
--    explicit instruction, even if a later site (or a later run) fails.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE analytics.evaluate_alerts()
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO pg_catalog, analytics, admin
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
                COMMIT;
                CONTINUE;
            END IF;

            SELECT * INTO v_active_alert
            FROM analytics.alerts
            WHERE site_id = v_site.id AND state = 'ACTIVE'
            LIMIT 1;

            -- Configuration-transition detection (ADR-016 decisions 8,
            -- 12-14): an Active alert whose condition_key no longer matches
            -- what is currently being evaluated. Unreachable today (the
            -- policy is a static constant, ADR-010) but implemented so it
            -- is correct the moment a condition's definition ever changes.
            -- v_active_alert.alert_id IS NOT NULL (not FOUND -- FOUND is
            -- reassigned by every subsequent statement, including the
            -- UPDATE/DELETE just below, so it cannot be trusted past them).
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
                    -- Already Active under the same condition -- decision 3:
                    -- no repeated alerts. Abandon any resolution attempt the
                    -- condition briefly interrupted by becoming true again.
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
                                -- Persistence failure: candidate row (already
                                -- durably committed on a prior run -- see the
                                -- COMMIT below) is left in place so
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
                    -- No Active alert, condition false -- nothing to watch.
                    -- An explicit false observation also breaks any
                    -- in-progress qualification streak (not only a gap).
                    DELETE FROM analytics.alert_evaluation_candidates
                    WHERE site_id = v_site.id AND condition_key = v_eval.condition_key AND watch_state = 'WATCHING_TRIGGER';
                END IF;
            END IF;

            COMMIT;
        EXCEPTION WHEN OTHERS THEN
            -- One site's failure must never abort evaluation for the rest
            -- of the site portfolio (do not create duplicate occurrences
            -- via a partial retry either -- the unique index on
            -- analytics.alerts is the final backstop regardless).
            RAISE WARNING 'MVP-7 alert evaluation failed for site %: %', v_site.id, SQLERRM;
            ROLLBACK;
        END;
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
'MVP-7 alert lifecycle: qualification (5 min), resolution (1 min), configuration-transition, persistence-retry (30 min from qualification), and 90-day retention. Commits per-site so already-durable qualification/resolution state survives a later site''s or run''s failure. See ADR-016/ADR-017.';

ALTER PROCEDURE analytics.evaluate_alerts() OWNER TO ems_admin;
REVOKE ALL ON PROCEDURE analytics.evaluate_alerts() FROM PUBLIC;

-- ----------------------------------------------------------------------------
-- 3. Job wrapper -- required (job_id INTEGER, config JSONB) signature, same
--    idiom as telemetry.run_environment_routing_job (postgres/ddl/68).
-- ----------------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE analytics.run_alert_evaluation_job
(
    job_id INTEGER,
    config JSONB
)
LANGUAGE plpgsql
AS
$$
BEGIN
    CALL analytics.evaluate_alerts();
END;
$$;

COMMENT ON PROCEDURE analytics.run_alert_evaluation_job(INTEGER, JSONB) IS
'TimescaleDB background job entrypoint for MVP-7 alert evaluation (ADR-017, A1). Delegates to analytics.evaluate_alerts().';

ALTER PROCEDURE analytics.run_alert_evaluation_job(INTEGER, JSONB) OWNER TO ems_admin;
REVOKE ALL ON PROCEDURE analytics.run_alert_evaluation_job(INTEGER, JSONB) FROM PUBLIC;

-- ----------------------------------------------------------------------------
-- 4. Portal-scoped read functions (Analytics API boundary, ADR-007).
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION analytics.get_portal_site_alerts
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
    previous_occurrence_count        BIGINT,
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
      AND (p_from IS NULL OR a.triggered_at >= p_from)
      AND (p_to IS NULL OR a.triggered_at < p_to)
      AND (p_before IS NULL OR a.triggered_at < p_before)
    ORDER BY a.triggered_at DESC
    LIMIT p_limit;
END;
$function$;

COMMENT ON FUNCTION analytics.get_portal_site_alerts(BIGINT, UUID, TEXT, TEXT, TIMESTAMPTZ, TIMESTAMPTZ, INT, TIMESTAMPTZ) IS
'MVP-7 alert list (Analytics API). Recurrence (previous_occurrence_count / most_recent_previous_triggered_at) is derived at read time, per ADR-017 -- never a stored counter, and correctly excludes occurrences of a different, superseding condition_key (ADR-016 decision 21). Ordering (materiality, then recency, ADR-016 decision 48) is applied by the caller -- MVP-7''s only condition has no materiality gradation.';

ALTER FUNCTION analytics.get_portal_site_alerts(BIGINT, UUID, TEXT, TEXT, TIMESTAMPTZ, TIMESTAMPTZ, INT, TIMESTAMPTZ) OWNER TO ems_admin;
REVOKE ALL ON FUNCTION analytics.get_portal_site_alerts(BIGINT, UUID, TEXT, TEXT, TIMESTAMPTZ, TIMESTAMPTZ, INT, TIMESTAMPTZ) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION analytics.get_portal_site_alerts(BIGINT, UUID, TEXT, TEXT, TIMESTAMPTZ, TIMESTAMPTZ, INT, TIMESTAMPTZ) TO ems_app;

CREATE OR REPLACE FUNCTION analytics.get_portal_alert_detail
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
    previous_occurrence_count        BIGINT,
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
'MVP-7 alert detail (Analytics API). An inaccessible or unknown alert_id returns zero rows, identical to every other portal-scoped read function in this schema (migration 231 pattern) -- never a distinguishable error.';

ALTER FUNCTION analytics.get_portal_alert_detail(BIGINT, UUID) OWNER TO ems_admin;
REVOKE ALL ON FUNCTION analytics.get_portal_alert_detail(BIGINT, UUID) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION analytics.get_portal_alert_detail(BIGINT, UUID) TO ems_app;

COMMIT;
