-- ============================================================================
-- Migration 240
-- MVP-7 Basic Alerts -- correct analytics.get_portal_site_alerts' date-range
-- filter to be state-keyed, per ADR-016 decision 48.
--
-- Source of record:
--   docs/00-governance/decisions/ADR-016-q77-mvp7-basic-alerts.md decision
--   48: "date range filtering keyed to triggered time (Active), resolved
--   time (Resolved), or ended time (Ended)".
--
-- Defect corrected (found during the 2026-09-14 staging-validation
-- corrective pass, not fixed there -- flagged for this separate migration
-- instead, since it touches an already-applied migration's function):
--   migration 239's analytics.get_portal_site_alerts filtered p_from/p_to
--   against a.triggered_at UNCONDITIONALLY, regardless of the requested
--   p_state. Correct for the Active tab; wrong for Resolved (should key on
--   resolved_at) and Ended (should key on ended_at).
--
-- Fix, minimum necessary: CREATE OR REPLACE the function with the SAME
-- signature, return shape, STABLE/SECURITY DEFINER/search_path/tenant-
-- boundary check, ORDER BY, and p_before (infinite-scroll) cursor
-- semantics -- all unchanged, all still triggered_at-based (the cursor is a
-- pagination-ordering concern, not the "date-range filter" ADR-016 decision
-- 48 addresses; ORDER BY a.triggered_at DESC is unaffected). Only the
-- p_from/p_to WHERE conditions change, from a single triggered_at
-- comparison to a per-row comparison keyed on that row's own a.state --
-- resolved_at and ended_at are NOT NULL exactly when state is RESOLVED /
-- ENDED respectively (ck_alerts_state_fields, migration 238), so this is
-- safe with no NULL-comparison risk. When p_state pins one value (every
-- real caller -- the frontend always sends state=ACTIVE|RESOLVED|ENDED per
-- tab), this degenerates exactly to ADR-016 decision 48's per-tab rule; the
-- function's own pre-existing p_state=NULL "any state" capability (not used
-- by any current caller) is handled by keying each row on its own state,
-- the only non-arbitrary reading given ADR-016 does not separately address
-- a mixed-state query.
--
-- analytics.get_portal_alert_detail (migration 239) takes NO p_from/p_to --
-- it is a single-row lookup by alert_id, not a list -- so it has no
-- date-range filter to correct and is untouched by this migration.
--
-- Analytics API boundary / authorization: unchanged. The Python route
-- (app/src/routers/analytics_api.py::get_site_alerts) and service layer
-- pass p_from/p_to through exactly as before; only this function's
-- server-side interpretation of them changes. _require_portal_user and
-- admin.portal_user_can_access_site tenant scoping are untouched.
--
-- Rollback: CREATE OR REPLACE FUNCTION analytics.get_portal_site_alerts
-- with migration 239's original WHERE clause (a single
-- `a.triggered_at >= p_from` / `a.triggered_at < p_to` pair, no state
-- keying) restores prior behavior -- safe, since the signature and return
-- shape are unchanged and staging's analytics.alerts table is currently
-- empty (confirmed 2026-09-14; no data-shape risk either way).
--
-- New tests: app/tests/test_alert_date_filter_state_keying_contract.py
-- (static SQL contract, same convention as test_alert_evaluation_contract.py
-- -- no live database available in this environment).
-- ============================================================================

BEGIN;

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
'MVP-7 alert list (Analytics API). Recurrence (previous_occurrence_count / most_recent_previous_triggered_at) is derived at read time, per ADR-017 -- never a stored counter, and correctly excludes occurrences of a different, superseding condition_key (ADR-016 decision 21). Ordering (materiality, then recency, ADR-016 decision 48) is applied by the caller -- MVP-7''s only condition has no materiality gradation. Date-range filter (p_from/p_to) is state-keyed (migration 240): triggered_at for ACTIVE, resolved_at for RESOLVED, ended_at for ENDED (ADR-016 decision 48).';

-- CREATE OR REPLACE preserves ownership/ACLs on an existing function, so
-- this is not strictly required -- restated explicitly anyway to match
-- every other function definition in this schema (migration 239's own
-- convention) and to keep this migration self-contained/verifiable by
-- static inspection alone.
ALTER FUNCTION analytics.get_portal_site_alerts(BIGINT, UUID, TEXT, TEXT, TIMESTAMPTZ, TIMESTAMPTZ, INT, TIMESTAMPTZ) OWNER TO ems_admin;
REVOKE ALL ON FUNCTION analytics.get_portal_site_alerts(BIGINT, UUID, TEXT, TEXT, TIMESTAMPTZ, TIMESTAMPTZ, INT, TIMESTAMPTZ) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION analytics.get_portal_site_alerts(BIGINT, UUID, TEXT, TEXT, TIMESTAMPTZ, TIMESTAMPTZ, INT, TIMESTAMPTZ) TO ems_app;

COMMIT;
