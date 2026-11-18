-- ============================================================================
-- Migration 327
-- Alerts (ADR-024) staging refinements D-1 and D-2. Redefines three
-- functions with UNCHANGED signatures, result columns, permissions and
-- lifecycle semantics; no table, data or job change.
--
-- D-1  analytics.evaluate_alert_rules: qualification (5 minutes) and
--      resolution (1 minute) tests gain a 2-second jitter grace:
--          c.since <= p_now - <interval> + INTERVAL '2 seconds'
--      `since` and `p_now` are both run start times. The once-a-minute job
--      starts each run a few milliseconds either side of exactly 60 s after
--      the previous one (staging 2026-11-18: 59.997-60.003 s), so the exact
--      test missed the intended run about half the time and waited one more
--      (qualification 5-6 min, resolution 1-2 min). Bound: the grace is 2 s
--      against a 60 s run interval, so a run can qualify / resolve only when
--      at least 4 min 58 s (qualification) / 58 s (resolution) have elapsed
--      since the first observation -- the run that is nominally 5 min / 1 min
--      later. No earlier run can qualify or resolve. Recorded triggered_at /
--      resolved_at are unchanged (the first observation). Gap reset (3 min)
--      and unavailability (5 min) are not affected by millisecond jitter and
--      are unchanged.
--
-- D-2  analytics.get_portal_site_alerts, analytics.get_portal_alert_detail:
--      previous_occurrence_count / most_recent_previous_triggered_at count
--      earlier occurrences of the same RULE (stable rule_id, all versions)
--      instead of the same condition_key (rule_id + version). Editing,
--      disabling, re-enabling or soft-deleting a rule no longer resets them.
--      Organisation filter kept; index ix_alerts_rule_time (rule_id,
--      triggered_at DESC) serves the lookup. Each alert keeps its own
--      rule_version, condition_key and configuration snapshot.
--
-- Ownership, PUBLIC revocation and ems_app grants are re-asserted;
-- CREATE OR REPLACE keeps the existing ems_customer_api grants (326), which
-- the post-check verifies where that role exists.
--
-- Rollback: re-apply the 324/325 definitions of these three functions in a
-- forward migration (behaviour reverts to the jitter-sensitive timing and
-- per-version counting). No data to restore.
-- ============================================================================

SET LOCAL lock_timeout = '30s';

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
    -- D-1: runs start a few ms either side of exactly one interval apart, so
    -- `since <= p_now - c_x` alone can miss the intended run and wait one
    -- more. The grace absorbs that jitter only: it is far below the 1-minute
    -- run interval, so no earlier run can ever qualify or resolve.
    c_jitter_grace      CONSTANT INTERVAL := INTERVAL '2 seconds';
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
          AND c.since <= p_now - c_resolution + c_jitter_grace
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
          AND c.since <= p_now - c_qualification + c_jitter_grace
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

CREATE OR REPLACE FUNCTION analytics.get_portal_site_alerts(
    p_portal_user_id BIGINT,
    p_site_id        UUID,
    p_states         TEXT[] DEFAULT NULL,   -- NULL = all states
    p_from           TIMESTAMPTZ DEFAULT NULL,
    p_to             TIMESTAMPTZ DEFAULT NULL,
    p_limit          INTEGER DEFAULT 50,
    p_before         TIMESTAMPTZ DEFAULT NULL  -- cursor: event_at of the last row already seen
)
RETURNS TABLE
(
    alert_id                 UUID,
    site_id                  UUID,
    rule_id                  UUID,
    rule_name                TEXT,
    rule_deleted             BOOLEAN,
    asset_id                 UUID,
    asset_name               TEXT,
    parameter_code           TEXT,
    qualifier                TEXT,
    parameter_name           TEXT,
    unit_symbol              TEXT,
    comparator               TEXT,
    threshold                NUMERIC,
    tolerance                NUMERIC,
    state                    TEXT,
    event_at                 TIMESTAMPTZ,
    triggered_at             TIMESTAMPTZ,
    trigger_value            DOUBLE PRECISION,
    last_value               DOUBLE PRECISION,
    last_value_at            TIMESTAMPTZ,
    data_unavailable         BOOLEAN,
    resolved_at              TIMESTAMPTZ,
    resolved_value           DOUBLE PRECISION,
    ended_at                 TIMESTAMPTZ,
    ended_reason_code        TEXT,
    acknowledged_at          TIMESTAMPTZ,
    acknowledged_by_name     TEXT,
    acknowledged_by_type     TEXT,
    previous_occurrence_count BIGINT,
    most_recent_previous_triggered_at TIMESTAMPTZ
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO pg_catalog, analytics, admin
AS $function$
#variable_conflict use_column
BEGIN
    IF NOT admin.portal_user_can_access_site(p_portal_user_id, p_site_id) THEN
        RETURN;
    END IF;

    RETURN QUERY
    WITH base AS (
        SELECT a.*,
               CASE a.state WHEN 'ACTIVE' THEN a.triggered_at
                            WHEN 'RESOLVED' THEN a.resolved_at
                            ELSE a.ended_at END AS ev_at
        FROM analytics.alerts AS a
        WHERE a.site_id = p_site_id
          AND (p_states IS NULL OR a.state = ANY (p_states))
    )
    SELECT
        b.alert_id, b.site_id, b.rule_id, b.rule_name, (r.deleted_at IS NOT NULL),
        b.asset_id, b.asset_name, b.parameter_code, b.qualifier, b.parameter_name, b.unit_symbol,
        b.comparator, b.threshold, b.tolerance, b.state, b.ev_at,
        b.triggered_at, b.trigger_value, b.last_value, b.last_value_at, b.data_unavailable,
        b.resolved_at, b.resolved_value, b.ended_at, b.ended_reason_code,
        b.acknowledged_at,
        CASE
            WHEN b.acknowledged_at IS NULL THEN NULL
            WHEN b.acknowledged_actor_type = 'WISEWATTS_STAFF' THEN 'WiseWatts Support'
            ELSE COALESCE(nullif(btrim(pu.display_name), ''), 'Site user')
        END,
        b.acknowledged_actor_type,
        (SELECT count(*) FROM analytics.alerts AS prev
          WHERE prev.organization_id = b.organization_id AND prev.rule_id = b.rule_id
            AND prev.alert_id <> b.alert_id AND prev.triggered_at < b.triggered_at),
        (SELECT max(prev.triggered_at) FROM analytics.alerts AS prev
          WHERE prev.organization_id = b.organization_id AND prev.rule_id = b.rule_id
            AND prev.alert_id <> b.alert_id AND prev.triggered_at < b.triggered_at)
    FROM base AS b
    JOIN analytics.alert_rules AS r ON r.rule_id = b.rule_id
    LEFT JOIN admin.portal_users AS pu ON pu.portal_user_id = b.acknowledged_by
    WHERE (p_from IS NULL OR b.ev_at >= p_from)
      AND (p_to IS NULL OR b.ev_at < p_to)
      AND (p_before IS NULL OR b.ev_at < p_before)
    ORDER BY b.ev_at DESC, b.alert_id DESC
    LIMIT LEAST(GREATEST(COALESCE(p_limit, 50), 1), 200);
END;
$function$;

CREATE OR REPLACE FUNCTION analytics.get_portal_alert_detail(
    p_portal_user_id BIGINT,
    p_alert_id       UUID
)
RETURNS TABLE
(
    alert_id                 UUID,
    site_id                  UUID,
    rule_id                  UUID,
    rule_name                TEXT,
    rule_deleted             BOOLEAN,
    asset_id                 UUID,
    asset_name               TEXT,
    parameter_code           TEXT,
    qualifier                TEXT,
    parameter_name           TEXT,
    unit_symbol              TEXT,
    comparator               TEXT,
    threshold                NUMERIC,
    tolerance                NUMERIC,
    state                    TEXT,
    event_at                 TIMESTAMPTZ,
    triggered_at             TIMESTAMPTZ,
    trigger_value            DOUBLE PRECISION,
    last_value               DOUBLE PRECISION,
    last_value_at            TIMESTAMPTZ,
    data_unavailable         BOOLEAN,
    resolved_at              TIMESTAMPTZ,
    resolved_value           DOUBLE PRECISION,
    ended_at                 TIMESTAMPTZ,
    ended_reason_code        TEXT,
    acknowledged_at          TIMESTAMPTZ,
    acknowledged_by_name     TEXT,
    acknowledged_by_type     TEXT,
    previous_occurrence_count BIGINT,
    most_recent_previous_triggered_at TIMESTAMPTZ
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO pg_catalog, analytics, admin
AS $function$
#variable_conflict use_column
DECLARE
    v_site UUID;
BEGIN
    SELECT a.site_id INTO v_site FROM analytics.alerts AS a WHERE a.alert_id = p_alert_id;
    IF v_site IS NULL OR NOT admin.portal_user_can_access_site(p_portal_user_id, v_site) THEN
        RETURN;
    END IF;

    RETURN QUERY
    SELECT
        a.alert_id, a.site_id, a.rule_id, a.rule_name, (r.deleted_at IS NOT NULL),
        a.asset_id, a.asset_name, a.parameter_code, a.qualifier, a.parameter_name, a.unit_symbol,
        a.comparator, a.threshold, a.tolerance, a.state,
        CASE a.state WHEN 'ACTIVE' THEN a.triggered_at WHEN 'RESOLVED' THEN a.resolved_at ELSE a.ended_at END,
        a.triggered_at, a.trigger_value, a.last_value, a.last_value_at, a.data_unavailable,
        a.resolved_at, a.resolved_value, a.ended_at, a.ended_reason_code,
        a.acknowledged_at,
        CASE
            WHEN a.acknowledged_at IS NULL THEN NULL
            WHEN a.acknowledged_actor_type = 'WISEWATTS_STAFF' THEN 'WiseWatts Support'
            ELSE COALESCE(nullif(btrim(pu.display_name), ''), 'Site user')
        END,
        a.acknowledged_actor_type,
        (SELECT count(*) FROM analytics.alerts AS prev
          WHERE prev.organization_id = a.organization_id AND prev.rule_id = a.rule_id
            AND prev.alert_id <> a.alert_id AND prev.triggered_at < a.triggered_at),
        (SELECT max(prev.triggered_at) FROM analytics.alerts AS prev
          WHERE prev.organization_id = a.organization_id AND prev.rule_id = a.rule_id
            AND prev.alert_id <> a.alert_id AND prev.triggered_at < a.triggered_at)
    FROM analytics.alerts AS a
    JOIN analytics.alert_rules AS r ON r.rule_id = a.rule_id
    LEFT JOIN admin.portal_users AS pu ON pu.portal_user_id = a.acknowledged_by
    WHERE a.alert_id = p_alert_id;
END;
$function$;

DO $grants$
DECLARE
    v_sig TEXT;
BEGIN
    ALTER FUNCTION analytics.evaluate_alert_rules(TIMESTAMPTZ) OWNER TO ems_admin;
    REVOKE ALL ON FUNCTION analytics.evaluate_alert_rules(TIMESTAMPTZ) FROM PUBLIC;
    FOREACH v_sig IN ARRAY ARRAY[
        'analytics.get_portal_site_alerts(bigint, uuid, text[], timestamptz, timestamptz, integer, timestamptz)',
        'analytics.get_portal_alert_detail(bigint, uuid)'
    ] LOOP
        EXECUTE format('ALTER FUNCTION %s OWNER TO ems_admin', v_sig);
        EXECUTE format('REVOKE ALL ON FUNCTION %s FROM PUBLIC', v_sig);
        EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO ems_app', v_sig);
    END LOOP;
END;
$grants$;

COMMENT ON FUNCTION analytics.evaluate_alert_rules(TIMESTAMPTZ) IS
'ADR-024 §4/§4A/§6/§13: one set-based alert-rule evaluation at p_now -- live-cache observations (UNAVAILABLE after 5 minutes without a valid sample), 5-minute qualification, 1-minute resolution on valid data (both with a 2-second run-jitter grace, migration 327), gap reset (3 minutes), schedule in the site timezone, 90-day history retention. Skips (skipped = TRUE) when another evaluation holds the advisory lock. Called by analytics.run_alert_rule_evaluation_job.';

DO $post$
DECLARE
    v_def TEXT;
    v_fn  TEXT;
BEGIN
    v_def := pg_get_functiondef('analytics.evaluate_alert_rules(timestamptz)'::regprocedure);
    IF position('c_jitter_grace' IN v_def) = 0
       OR position('p_now - c_qualification + c_jitter_grace' IN v_def) = 0
       OR position('p_now - c_resolution + c_jitter_grace' IN v_def) = 0 THEN
        RAISE EXCEPTION 'Migration 327: evaluator jitter grace not in place';
    END IF;
    FOREACH v_fn IN ARRAY ARRAY[
        'analytics.get_portal_site_alerts(bigint, uuid, text[], timestamptz, timestamptz, integer, timestamptz)',
        'analytics.get_portal_alert_detail(bigint, uuid)'
    ] LOOP
        v_def := pg_get_functiondef(v_fn::regprocedure);
        IF position('prev.condition_key' IN v_def) > 0 OR position('prev.rule_id' IN v_def) = 0 THEN
            RAISE EXCEPTION 'Migration 327: % still counts previous occurrences per condition_key', v_fn;
        END IF;
        IF has_function_privilege('public', v_fn, 'EXECUTE')
           OR NOT has_function_privilege('ems_app', v_fn, 'EXECUTE') THEN
            RAISE EXCEPTION 'Migration 327: unexpected grants on %', v_fn;
        END IF;
        IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'ems_customer_api')
           AND NOT has_function_privilege('ems_customer_api', v_fn, 'EXECUTE') THEN
            RAISE EXCEPTION 'Migration 327: ems_customer_api lost EXECUTE on %', v_fn;
        END IF;
    END LOOP;
    IF has_function_privilege('ems_app', 'analytics.evaluate_alert_rules(timestamptz)', 'EXECUTE')
       OR has_function_privilege('public', 'analytics.evaluate_alert_rules(timestamptz)', 'EXECUTE') THEN
        RAISE EXCEPTION 'Migration 327: evaluator must not be executable by application roles';
    END IF;
END;
$post$;
