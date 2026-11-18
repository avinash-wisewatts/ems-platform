-- ============================================================================
-- Migration 325
-- Alerts (ADR-024 §4, §4A, §6, §8, §13): the alert-rule evaluator and its
-- TimescaleDB job.
--
-- analytics.evaluate_alert_rules(p_now) -- one bounded, set-based pass:
--
--   observation  every enabled, non-deleted rule (FOR SHARE ... SKIP LOCKED,
--                so a rule being edited is skipped for this run), its
--                site-local schedule state, its asset's current
--                metadata.asset_points binding, and the latest GOOD value of
--                that point in telemetry.device_live_point_state (the
--                canonical-unit latest-value cache):
--                  UNAVAILABLE  no binding, or no valid sample within the
--                               last 5 minutes
--                  TRUE / FALSE GT: v > threshold, LT: v < threshold,
--                               EQ: |v - threshold| <= tolerance
--   Active       refresh last_value / data_unavailable; a telemetry gap
--                keeps the alert ACTIVE and its acknowledgement (§4A)
--   resolution   FALSE on valid data continuously for 1 minute -> RESOLVED
--                (resolved_at / resolved_value = the first clear
--                observation); TRUE, UNAVAILABLE or a run gap > 3 minutes
--                resets the timer
--   qualification TRUE within the schedule continuously for 5 minutes ->
--                ACTIVE (triggered_at / trigger_value = the first true
--                observation); FALSE, UNAVAILABLE, outside the schedule or a
--                run gap > 3 minutes resets the timer. A schedule closing
--                never ends or resolves an ACTIVE alert (§6).
--   retention    Resolved / Ended occurrences older than 90 days (from
--                resolved_at / ended_at) are deleted; Active never are.
--
-- Configuration changes are not handled here: the migration 323 write
-- functions end the ACTIVE occurrence (CONFIGURATION_CHANGED) and clear its
-- timers in the same audited transaction.
--
-- Schedule semantics (site timezone): start < end is a same-day window
-- [start, end); start > end crosses midnight -- [start, 24:00) on a selected
-- weekday plus [00:00, end) on the day after a selected weekday.
--
-- analytics.run_alert_rule_evaluation_job -- the job procedure: 30-second
-- statement timeout, one analytics.alert_evaluation_runs row per run, run log
-- kept 7 days. A run that cannot take the evaluator's advisory lock (a
-- previous run still going) is logged as skipped.
--
-- The job is registered here (every 1 minute, 5-minute max runtime, 3
-- retries every minute -- the scripts/verify/verify_jobs.sh standard),
-- idempotently and located by procedure name.
--
-- Rollback: SELECT delete_job(job_id) for the job; DROP the procedure,
-- function and type.
-- ============================================================================

DO $pre$
BEGIN
    IF to_regclass('telemetry.device_live_point_state') IS NULL
       OR to_regclass('analytics.alert_evaluation_runs') IS NULL THEN
        RAISE EXCEPTION 'Migration 325 precondition failed: telemetry.device_live_point_state or analytics.alert_evaluation_runs is missing.';
    END IF;
END;
$pre$;

DROP TYPE IF EXISTS analytics.alert_rule_observation;
CREATE TYPE analytics.alert_rule_observation AS
(
    rule_id         UUID,
    organization_id UUID,
    site_id         UUID,
    asset_id        UUID,
    condition_key   TEXT,
    in_schedule     BOOLEAN,
    observation     TEXT,
    value           DOUBLE PRECISION,
    sample_at       TIMESTAMPTZ
);
ALTER TYPE analytics.alert_rule_observation OWNER TO ems_admin;


CREATE OR REPLACE FUNCTION analytics.alert_rule_in_schedule(
    p_local_ts       TIMESTAMP,
    p_schedule_start TIME,
    p_schedule_end   TIME,
    p_weekdays       SMALLINT
)
RETURNS BOOLEAN
LANGUAGE SQL
IMMUTABLE
SET search_path TO pg_catalog
AS $function$
    SELECT CASE
        WHEN p_schedule_start < p_schedule_end THEN
            p_local_ts::TIME >= p_schedule_start
            AND p_local_ts::TIME < p_schedule_end
            AND (p_weekdays::INTEGER & (1 << (extract(isodow FROM p_local_ts)::INTEGER - 1))) <> 0
        ELSE
            (p_local_ts::TIME >= p_schedule_start
             AND (p_weekdays::INTEGER & (1 << (extract(isodow FROM p_local_ts)::INTEGER - 1))) <> 0)
            OR
            (p_local_ts::TIME < p_schedule_end
             AND (p_weekdays::INTEGER & (1 << (extract(isodow FROM p_local_ts - INTERVAL '1 day')::INTEGER - 1))) <> 0)
    END;
$function$;


CREATE OR REPLACE FUNCTION analytics.evaluate_alert_rules(p_now TIMESTAMPTZ DEFAULT clock_timestamp())
RETURNS TABLE
(
    rules_evaluated   INTEGER,
    rules_unavailable INTEGER,
    alerts_created    INTEGER,
    alerts_resolved   INTEGER,
    alerts_purged     INTEGER,
    skipped           BOOLEAN
)
LANGUAGE plpgsql
VOLATILE
SET search_path TO pg_catalog, analytics, metadata, config, telemetry
AS $function$
#variable_conflict use_column
DECLARE
    c_unavailable_after CONSTANT INTERVAL := INTERVAL '5 minutes';
    c_qualification     CONSTANT INTERVAL := INTERVAL '5 minutes';
    c_resolution        CONSTANT INTERVAL := INTERVAL '1 minute';
    c_gap               CONSTANT INTERVAL := INTERVAL '3 minutes';
    c_retention         CONSTANT INTERVAL := INTERVAL '90 days';
    v_obs      analytics.alert_rule_observation[];
    v_created  INTEGER := 0;
    v_resolved INTEGER := 0;
    v_purged   INTEGER := 0;
BEGIN
    IF NOT pg_try_advisory_xact_lock(hashtextextended('analytics.evaluate_alert_rules', 0)) THEN
        RETURN QUERY SELECT 0, 0, 0, 0, 0, TRUE;
        RETURN;
    END IF;

    -- 1. Observations (one row per rule).
    SELECT COALESCE(array_agg(ROW(
               x.rule_id, x.organization_id, x.site_id, x.asset_id, x.condition_key,
               x.in_schedule, x.observation, x.value, x.sample_at
           )::analytics.alert_rule_observation), ARRAY[]::analytics.alert_rule_observation[])
    INTO v_obs
    FROM (
        SELECT
            r.rule_id,
            r.organization_id,
            r.site_id,
            r.asset_id,
            'RULE:' || r.rule_id::TEXT || ':v' || r.version::TEXT AS condition_key,
            analytics.alert_rule_in_schedule(
                p_now AT TIME ZONE COALESCE(s.timezone, 'UTC'),
                r.schedule_start, r.schedule_end, r.weekdays
            ) AS in_schedule,
            CASE
                WHEN l.numeric_value IS NULL THEN 'UNAVAILABLE'
                WHEN r.comparator = 'GT' AND l.numeric_value > r.threshold THEN 'TRUE'
                WHEN r.comparator = 'LT' AND l.numeric_value < r.threshold THEN 'TRUE'
                WHEN r.comparator = 'EQ' AND abs(l.numeric_value - r.threshold) <= r.tolerance THEN 'TRUE'
                ELSE 'FALSE'
            END AS observation,
            l.numeric_value::DOUBLE PRECISION AS value,
            l.event_time AS sample_at
        FROM analytics.alert_rules AS r
        JOIN metadata.sites AS s ON s.id = r.site_id
        LEFT JOIN LATERAL (
            SELECT ap.device_id, ap.logical_point_id
            FROM metadata.asset_points AS ap
            JOIN metadata.logical_points AS lp ON lp.id = ap.logical_point_id
            JOIN config.parameters AS p ON p.id = lp.parameter_id
            WHERE ap.asset_id = r.asset_id
              AND p.code = r.parameter_code
              AND lp.qualifier IS NOT DISTINCT FROM r.qualifier
              AND ap.effective_range @> p_now
            ORDER BY ap.effective_from DESC
            LIMIT 1
        ) AS b ON TRUE
        LEFT JOIN telemetry.device_live_point_state AS l
          ON l.device_id = b.device_id
         AND l.logical_point_id = b.logical_point_id
         AND l.quality_code = 'GOOD'
         AND l.numeric_value IS NOT NULL
         AND l.event_time > p_now - c_unavailable_after
         AND l.event_time <= p_now + INTERVAL '1 minute'
        WHERE r.enabled AND r.deleted_at IS NULL
        FOR SHARE OF r SKIP LOCKED
    ) AS x;

    -- 2. Active occurrences: latest value and the data-unavailable flag. A
    --    gap never resolves or ends an alert and keeps its acknowledgement.
    UPDATE analytics.alerts AS a
    SET last_evaluated_at = p_now,
        data_unavailable  = (o.observation = 'UNAVAILABLE'),
        last_value        = CASE WHEN o.observation = 'UNAVAILABLE' THEN a.last_value ELSE o.value END,
        last_value_at     = CASE WHEN o.observation = 'UNAVAILABLE' THEN a.last_value_at ELSE o.sample_at END
    FROM unnest(v_obs) AS o
    WHERE a.rule_id = o.rule_id AND a.state = 'ACTIVE';

    -- 3. Resolution timers.
    DELETE FROM analytics.alert_evaluation_candidates AS c
    USING unnest(v_obs) AS o
    WHERE c.rule_id = o.rule_id
      AND c.watch_state = 'WATCHING_CLEAR'
      AND (o.observation <> 'FALSE' OR c.last_evaluated_at < p_now - c_gap);

    INSERT INTO analytics.alert_evaluation_candidates
        (site_id, condition_key, rule_id, watch_state, since, candidate_value, last_evaluated_at, alert_id)
    SELECT o.site_id, a.condition_key, o.rule_id, 'WATCHING_CLEAR', p_now, o.value, p_now, a.alert_id
    FROM unnest(v_obs) AS o
    JOIN analytics.alerts AS a ON a.rule_id = o.rule_id AND a.state = 'ACTIVE'
    WHERE o.observation = 'FALSE'
    ON CONFLICT (site_id, condition_key) DO UPDATE
        SET last_evaluated_at = EXCLUDED.last_evaluated_at
        WHERE analytics.alert_evaluation_candidates.watch_state = 'WATCHING_CLEAR';

    WITH resolved AS (
        UPDATE analytics.alerts AS a
        SET state = 'RESOLVED',
            resolved_at = c.since,
            resolved_value = c.candidate_value,
            data_unavailable = FALSE,
            last_evaluated_at = p_now
        FROM analytics.alert_evaluation_candidates AS c
        WHERE c.alert_id = a.alert_id
          AND c.watch_state = 'WATCHING_CLEAR'
          AND a.state = 'ACTIVE'
          AND c.since <= p_now - c_resolution
        RETURNING a.alert_id
    ), cleared AS (
        DELETE FROM analytics.alert_evaluation_candidates AS c
        USING resolved
        WHERE c.alert_id = resolved.alert_id
        RETURNING 1
    )
    SELECT count(*) INTO v_resolved FROM resolved;

    -- 4. Qualification timers (rules without an ACTIVE occurrence).
    DELETE FROM analytics.alert_evaluation_candidates AS c
    USING unnest(v_obs) AS o
    WHERE c.rule_id = o.rule_id
      AND c.watch_state = 'WATCHING_TRIGGER'
      AND (o.observation <> 'TRUE' OR NOT o.in_schedule OR c.last_evaluated_at < p_now - c_gap
           OR c.condition_key <> o.condition_key);

    INSERT INTO analytics.alert_evaluation_candidates
        (site_id, condition_key, rule_id, watch_state, since, candidate_value, last_evaluated_at, alert_id)
    SELECT o.site_id, o.condition_key, o.rule_id, 'WATCHING_TRIGGER', p_now, o.value, p_now, NULL
    FROM unnest(v_obs) AS o
    WHERE o.observation = 'TRUE' AND o.in_schedule
      AND NOT EXISTS (SELECT 1 FROM analytics.alerts AS a WHERE a.rule_id = o.rule_id AND a.state = 'ACTIVE')
    ON CONFLICT (site_id, condition_key) DO UPDATE
        SET last_evaluated_at = EXCLUDED.last_evaluated_at
        WHERE analytics.alert_evaluation_candidates.watch_state = 'WATCHING_TRIGGER';

    WITH qualified AS (
        SELECT c.site_id, c.condition_key, c.rule_id, c.since, c.candidate_value, o.value, o.sample_at
        FROM analytics.alert_evaluation_candidates AS c
        JOIN unnest(v_obs) AS o ON o.rule_id = c.rule_id AND o.condition_key = c.condition_key
        WHERE c.watch_state = 'WATCHING_TRIGGER'
          AND c.since <= p_now - c_qualification
    ), inserted AS (
        INSERT INTO analytics.alerts (
            organization_id, site_id, asset_id, condition_key, metric, state, triggered_at, trigger_value,
            last_evaluated_at, rule_id, rule_version, rule_name, asset_name, parameter_code, qualifier,
            parameter_name, unit_symbol, comparator, threshold, tolerance, last_value, last_value_at
        )
        SELECT
            r.organization_id, r.site_id, r.asset_id, q.condition_key, r.parameter_code, 'ACTIVE', q.since,
            q.candidate_value, p_now, r.rule_id, r.version, r.name, a.name, r.parameter_code, r.qualifier,
            COALESCE((SELECT p.name::TEXT FROM config.parameters AS p WHERE p.code = r.parameter_code), r.parameter_code),
            r.unit_symbol, r.comparator, r.threshold, r.tolerance, q.value, q.sample_at
        FROM qualified AS q
        JOIN analytics.alert_rules AS r ON r.rule_id = q.rule_id
        JOIN metadata.assets AS a ON a.id = r.asset_id
        ON CONFLICT DO NOTHING
        RETURNING rule_id, condition_key
    ), consumed AS (
        DELETE FROM analytics.alert_evaluation_candidates AS c
        USING inserted
        WHERE c.rule_id = inserted.rule_id AND c.condition_key = inserted.condition_key
        RETURNING 1
    )
    SELECT count(*) INTO v_created FROM inserted;

    -- 5. Timers of rules that are no longer evaluated under that identity.
    DELETE FROM analytics.alert_evaluation_candidates AS c
    USING analytics.alert_rules AS r
    WHERE c.rule_id = r.rule_id
      AND (NOT r.enabled OR r.deleted_at IS NOT NULL
           OR c.condition_key <> 'RULE:' || r.rule_id::TEXT || ':v' || r.version::TEXT);

    -- 6. 90-day history retention.
    WITH purged AS (
        DELETE FROM analytics.alerts AS a
        WHERE (a.state = 'RESOLVED' AND a.resolved_at < p_now - c_retention)
           OR (a.state = 'ENDED' AND a.ended_at < p_now - c_retention)
        RETURNING 1
    )
    SELECT count(*) INTO v_purged FROM purged;

    RETURN QUERY SELECT
        COALESCE(cardinality(v_obs), 0),
        (SELECT count(*)::INTEGER FROM unnest(v_obs) AS o WHERE o.observation = 'UNAVAILABLE'),
        v_created, v_resolved, v_purged, FALSE;
END;
$function$;


CREATE OR REPLACE PROCEDURE analytics.run_alert_rule_evaluation_job(job_id INTEGER, config JSONB)
LANGUAGE plpgsql
SET search_path TO pg_catalog, analytics
AS $procedure$
DECLARE
    v_started TIMESTAMPTZ := clock_timestamp();
    v_result  RECORD;
BEGIN
    PERFORM set_config('statement_timeout', '30s', TRUE);

    SELECT * INTO v_result FROM analytics.evaluate_alert_rules(v_started);

    INSERT INTO analytics.alert_evaluation_runs (
        started_at, finished_at, evaluated_at, rules_evaluated, rules_unavailable,
        alerts_created, alerts_resolved, alerts_purged, skipped
    )
    VALUES (
        v_started, clock_timestamp(), v_started, v_result.rules_evaluated, v_result.rules_unavailable,
        v_result.alerts_created, v_result.alerts_resolved, v_result.alerts_purged, v_result.skipped
    );

    DELETE FROM analytics.alert_evaluation_runs WHERE started_at < v_started - INTERVAL '7 days';
END;
$procedure$;


DO $grants$
BEGIN
    ALTER FUNCTION analytics.alert_rule_in_schedule(TIMESTAMP, TIME, TIME, SMALLINT) OWNER TO ems_admin;
    REVOKE ALL ON FUNCTION analytics.alert_rule_in_schedule(TIMESTAMP, TIME, TIME, SMALLINT) FROM PUBLIC;
    ALTER FUNCTION analytics.evaluate_alert_rules(TIMESTAMPTZ) OWNER TO ems_admin;
    REVOKE ALL ON FUNCTION analytics.evaluate_alert_rules(TIMESTAMPTZ) FROM PUBLIC;
    ALTER PROCEDURE analytics.run_alert_rule_evaluation_job(INTEGER, JSONB) OWNER TO ems_admin;
    REVOKE ALL ON PROCEDURE analytics.run_alert_rule_evaluation_job(INTEGER, JSONB) FROM PUBLIC;
END;
$grants$;

COMMENT ON FUNCTION analytics.evaluate_alert_rules(TIMESTAMPTZ) IS
'ADR-024 §4/§4A/§6/§13: one set-based alert-rule evaluation at p_now -- live-cache observations (UNAVAILABLE after 5 minutes without a valid sample), 5-minute qualification, 1-minute resolution on valid data, gap reset (3 minutes), schedule in the site timezone, 90-day history retention. Skips (skipped = TRUE) when another evaluation holds the advisory lock. Called by analytics.run_alert_rule_evaluation_job.';
COMMENT ON PROCEDURE analytics.run_alert_rule_evaluation_job(INTEGER, JSONB) IS
'ADR-024 §13: TimescaleDB job (every minute) -- runs analytics.evaluate_alert_rules with a 30-second statement timeout and logs the run in analytics.alert_evaluation_runs (kept 7 days).';


-- ----------------------------------------------------------------------------
-- Job registration (idempotent; located by procedure name).
-- ----------------------------------------------------------------------------

DO $jobs$
DECLARE
    v_job_id INTEGER;
BEGIN
    SELECT j.job_id INTO v_job_id
    FROM timescaledb_information.jobs AS j
    WHERE j.proc_schema = 'analytics' AND j.proc_name = 'run_alert_rule_evaluation_job'
    ORDER BY j.job_id
    LIMIT 1;

    IF v_job_id IS NULL THEN
        v_job_id := add_job(
            'analytics.run_alert_rule_evaluation_job'::regproc,
            schedule_interval => INTERVAL '1 minute',
            initial_start     => now() + INTERVAL '1 minute',
            scheduled         => TRUE
        );
    END IF;

    PERFORM alter_job(
        v_job_id,
        schedule_interval => INTERVAL '1 minute',
        max_runtime       => INTERVAL '5 minutes',
        max_retries       => 3,
        retry_period      => INTERVAL '1 minute',
        scheduled         => TRUE
    );
END;
$jobs$;

DO $post$
BEGIN
    IF (SELECT count(*) FROM timescaledb_information.jobs
        WHERE proc_schema = 'analytics' AND proc_name = 'run_alert_rule_evaluation_job') <> 1 THEN
        RAISE EXCEPTION 'Migration 325 postcondition failed: the alert-rule evaluation job is not registered exactly once.';
    END IF;
    IF EXISTS (SELECT 1 FROM timescaledb_information.jobs
               WHERE proc_schema = 'analytics' AND proc_name = 'run_alert_evaluation_job') THEN
        RAISE EXCEPTION 'Migration 325 postcondition failed: the legacy alert evaluation job still exists.';
    END IF;
END;
$post$;
