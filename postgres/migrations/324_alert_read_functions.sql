-- ============================================================================
-- Migration 324
-- Alerts (ADR-024 §2, §11): portal-scoped reads for the three Alerts views.
--
-- SECURITY DEFINER, STABLE, EXECUTE for ems_app (and, guarded, for
-- ems_customer_api in migration 326). Every read re-derives access from
-- p_portal_user_id through admin.portal_user_can_access_site; an
-- inaccessible or unknown site / alert / rule returns zero rows,
-- indistinguishable from a missing one. Viewing needs only site access
-- (dashboard.view is enforced by the API), so customer ADMIN / OPERATOR /
-- VIEWER and GLOBAL ADMIN / OPERATOR / VIEWER staff all read the same data.
--
--   analytics.get_portal_site_alerts       Active list and Resolved/Ended
--                                          history (replaces the MVP-7
--                                          function dropped by migration 320)
--   analytics.get_portal_alert_detail      one occurrence
--   analytics.list_portal_alert_rules      a site's non-deleted rules
--   analytics.get_portal_alert_rule        one non-deleted rule
--   analytics.list_portal_alert_rule_parameters
--                                          the parameters a rule may use:
--                                          ACTIVE assets' current bindings,
--                                          cumulative counters excluded
--
-- Acknowledgement display (ADR-024, approved decision): an acknowledgement
-- by WiseWatts staff is shown as "WiseWatts Support"; the staff identity is
-- kept internally (analytics.alerts.acknowledged_by, admin.audit_events)
-- and never returned. A customer acknowledger is shown by display name.
--
-- Rollback: DROP the functions below.
-- ============================================================================

-- Shared row shape of the two alert reads.
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
          WHERE prev.organization_id = b.organization_id AND prev.condition_key = b.condition_key
            AND prev.alert_id <> b.alert_id AND prev.triggered_at < b.triggered_at),
        (SELECT max(prev.triggered_at) FROM analytics.alerts AS prev
          WHERE prev.organization_id = b.organization_id AND prev.condition_key = b.condition_key
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
          WHERE prev.organization_id = a.organization_id AND prev.condition_key = a.condition_key
            AND prev.alert_id <> a.alert_id AND prev.triggered_at < a.triggered_at),
        (SELECT max(prev.triggered_at) FROM analytics.alerts AS prev
          WHERE prev.organization_id = a.organization_id AND prev.condition_key = a.condition_key
            AND prev.alert_id <> a.alert_id AND prev.triggered_at < a.triggered_at)
    FROM analytics.alerts AS a
    JOIN analytics.alert_rules AS r ON r.rule_id = a.rule_id
    LEFT JOIN admin.portal_users AS pu ON pu.portal_user_id = a.acknowledged_by
    WHERE a.alert_id = p_alert_id;
END;
$function$;

CREATE OR REPLACE FUNCTION analytics.list_portal_alert_rules(
    p_portal_user_id BIGINT,
    p_site_id        UUID
)
RETURNS TABLE
(
    rule_id            UUID,
    site_id            UUID,
    name               TEXT,
    asset_id           UUID,
    asset_name         TEXT,
    parameter_code     TEXT,
    qualifier          TEXT,
    parameter_name     TEXT,
    unit_symbol        TEXT,
    comparator         TEXT,
    comparison_mode    TEXT,
    threshold          NUMERIC,
    tolerance          NUMERIC,
    schedule_start     TIME,
    schedule_end       TIME,
    weekdays           SMALLINT,
    reminder_minutes   SMALLINT,
    email_requested    BOOLEAN,
    whatsapp_requested BOOLEAN,
    enabled            BOOLEAN,
    version            INTEGER,
    created_at         TIMESTAMPTZ,
    updated_at         TIMESTAMPTZ,
    active_alert_id    UUID
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO pg_catalog, analytics, admin, metadata, config
AS $function$
#variable_conflict use_column
BEGIN
    IF NOT admin.portal_user_can_access_site(p_portal_user_id, p_site_id) THEN
        RETURN;
    END IF;

    RETURN QUERY
    SELECT
        r.rule_id, r.site_id, r.name, r.asset_id, a.name::TEXT, r.parameter_code, r.qualifier,
        COALESCE((SELECT p.name::TEXT FROM config.parameters AS p WHERE p.code = r.parameter_code), r.parameter_code),
        r.unit_symbol, r.comparator, r.comparison_mode, r.threshold, r.tolerance,
        r.schedule_start, r.schedule_end, r.weekdays, r.reminder_minutes,
        r.email_requested, r.whatsapp_requested, r.enabled, r.version, r.created_at, r.updated_at,
        (SELECT al.alert_id FROM analytics.alerts AS al WHERE al.rule_id = r.rule_id AND al.state = 'ACTIVE')
    FROM analytics.alert_rules AS r
    JOIN metadata.assets AS a ON a.id = r.asset_id
    WHERE r.site_id = p_site_id AND r.deleted_at IS NULL
    ORDER BY lower(r.name), r.rule_id;
END;
$function$;

CREATE OR REPLACE FUNCTION analytics.get_portal_alert_rule(
    p_portal_user_id BIGINT,
    p_rule_id        UUID
)
RETURNS TABLE
(
    rule_id            UUID,
    site_id            UUID,
    name               TEXT,
    asset_id           UUID,
    asset_name         TEXT,
    parameter_code     TEXT,
    qualifier          TEXT,
    parameter_name     TEXT,
    unit_symbol        TEXT,
    comparator         TEXT,
    comparison_mode    TEXT,
    threshold          NUMERIC,
    tolerance          NUMERIC,
    schedule_start     TIME,
    schedule_end       TIME,
    weekdays           SMALLINT,
    reminder_minutes   SMALLINT,
    email_requested    BOOLEAN,
    whatsapp_requested BOOLEAN,
    enabled            BOOLEAN,
    version            INTEGER,
    created_at         TIMESTAMPTZ,
    updated_at         TIMESTAMPTZ,
    active_alert_id    UUID
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
    SELECT r.site_id INTO v_site FROM analytics.alert_rules AS r
    WHERE r.rule_id = p_rule_id AND r.deleted_at IS NULL;
    IF v_site IS NULL THEN
        RETURN;
    END IF;
    RETURN QUERY
    SELECT l.* FROM analytics.list_portal_alert_rules(p_portal_user_id, v_site) AS l
    WHERE l.rule_id = p_rule_id;
END;
$function$;

CREATE OR REPLACE FUNCTION analytics.list_portal_alert_rule_parameters(
    p_portal_user_id BIGINT,
    p_site_id        UUID,
    p_asset_id       UUID DEFAULT NULL
)
RETURNS TABLE
(
    asset_id       UUID,
    asset_name     TEXT,
    parameter_code TEXT,
    parameter_name TEXT,
    qualifier      TEXT,
    unit_symbol    TEXT
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO pg_catalog, analytics, admin, metadata, config
AS $function$
#variable_conflict use_column
DECLARE
    v_now TIMESTAMPTZ := clock_timestamp();
BEGIN
    IF NOT admin.portal_user_can_access_site(p_portal_user_id, p_site_id) THEN
        RETURN;
    END IF;

    RETURN QUERY
    SELECT DISTINCT ON (a.id, p.code, lp.qualifier)
        a.id, a.name::TEXT, p.code::TEXT, p.name::TEXT, lp.qualifier::TEXT,
        COALESCE(pu.symbol, lu.symbol)::TEXT
    FROM metadata.assets AS a
    JOIN metadata.asset_points AS ap ON ap.asset_id = a.id AND ap.effective_range @> v_now
    JOIN metadata.logical_points AS lp ON lp.id = ap.logical_point_id
    JOIN config.parameters AS p ON p.id = lp.parameter_id
    LEFT JOIN config.engineering_units AS pu ON pu.id = p.unit_id
    LEFT JOIN config.engineering_units AS lu ON lu.id = lp.unit_id
    WHERE a.site_id = p_site_id
      AND a.lifecycle_status = 'ACTIVE'
      AND (p_asset_id IS NULL OR a.id = p_asset_id)
      AND NOT COALESCE(
          (SELECT b.is_cumulative
           FROM analytics.alert_rule_parameter_binding(a.id, p.code, lp.qualifier, v_now) AS b),
          TRUE)
    ORDER BY a.id, p.code, lp.qualifier, ap.effective_from DESC;
END;
$function$;


DO $grants$
DECLARE
    v_sig TEXT;
BEGIN
    FOREACH v_sig IN ARRAY ARRAY[
        'analytics.get_portal_site_alerts(bigint, uuid, text[], timestamptz, timestamptz, integer, timestamptz)',
        'analytics.get_portal_alert_detail(bigint, uuid)',
        'analytics.list_portal_alert_rules(bigint, uuid)',
        'analytics.get_portal_alert_rule(bigint, uuid)',
        'analytics.list_portal_alert_rule_parameters(bigint, uuid, uuid)'
    ] LOOP
        EXECUTE format('ALTER FUNCTION %s OWNER TO ems_admin', v_sig);
        EXECUTE format('REVOKE ALL ON FUNCTION %s FROM PUBLIC', v_sig);
        EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO ems_app', v_sig);
    END LOOP;
END;
$grants$;

COMMENT ON FUNCTION analytics.get_portal_site_alerts(BIGINT, UUID, TEXT[], TIMESTAMPTZ, TIMESTAMPTZ, INTEGER, TIMESTAMPTZ) IS
'ADR-024 §11: a site''s rule-based alert occurrences -- Active Alerts (p_states {ACTIVE}) and Resolved/Ended history ({RESOLVED,ENDED}). event_at = triggered_at (ACTIVE) / resolved_at / ended_at; filtered by p_from/p_to, paged by p_before, newest first, at most 200. Staff acknowledgements are shown as "WiseWatts Support". Zero rows for an inaccessible site.';
COMMENT ON FUNCTION analytics.list_portal_alert_rule_parameters(BIGINT, UUID, UUID) IS
'ADR-024 §3, §5: the (asset, parameter, qualifier) choices for an alert rule -- ACTIVE assets of the site with a current metadata.asset_points binding; cumulative counters (energy registers, PULSE_COUNT) excluded.';
