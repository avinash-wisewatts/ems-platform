-- ============================================================================
-- Migration 323
-- Alerts (ADR-024 §2, §5, §8, §14-§16): rule and acknowledgement writes.
--
-- SECURITY DEFINER functions, EXECUTE for ems_app (and, guarded, for
-- ems_customer_api in migration 326). Each re-derives everything from
-- p_portal_user_id (the session user); nothing the browser sends is trusted
-- for authorisation:
--
--   analytics.create_portal_alert_rule        alert.configure
--   analytics.update_portal_alert_rule        alert.configure (expected version)
--   analytics.set_portal_alert_rule_enabled   alert.configure
--   analytics.delete_portal_alert_rule        alert.configure (soft delete)
--   analytics.acknowledge_portal_alert        alert.acknowledge
--
-- Result contract: one row (result, rule_id | alert_id, version).
--   result = 'ok'          change committed (or already in the requested
--                           state: enable/disable; no change: update)
--          = 'not_found'   site / asset / rule / alert not accessible --
--                           indistinguishable from missing; NOT audited
--          = 'forbidden'   accessible, but the permission is missing;
--                           audited as REJECTED (the row commits)
--          = <code>        validation failure (see analytics.alert_rule_validate);
--                           not audited, nothing written
--
-- Every successful change writes exactly one admin.audit_events row via
-- admin.write_audit_event in the same transaction (actor = the session user;
-- actor_type derived by migration 322). An edit, disable or delete ends the
-- rule's ACTIVE occurrence as ENDED / CONFIGURATION_CHANGED and clears its
-- evaluator timers in that same transaction; the ended alert ids are listed
-- in the audit row's new_values.
--
-- Permissions: GLOBAL ADMIN (WiseWatts staff) reaches every site through
-- admin.portal_user_can_access_site and holds alert.configure; GLOBAL
-- OPERATOR holds alert.acknowledge only; VIEWER holds neither.
--
-- Rollback: DROP the functions below.
-- ============================================================================

DO $pre$
BEGIN
    IF to_regclass('analytics.alert_rules') IS NULL THEN
        RAISE EXCEPTION 'Migration 323 precondition failed: analytics.alert_rules (migration 321) is missing.';
    END IF;
    IF to_regprocedure('admin.portal_user_has_permission(bigint, text)') IS NULL
       OR to_regprocedure('admin.portal_user_can_access_site(bigint, uuid)') IS NULL
       OR to_regprocedure('admin.write_audit_event(uuid, bigint, text, text, uuid, uuid, uuid, jsonb, jsonb, text, text)') IS NULL THEN
        RAISE EXCEPTION 'Migration 323 precondition failed: an admin access / audit function is missing.';
    END IF;
END;
$pre$;


-- ----------------------------------------------------------------------------
-- 1. Internal helpers (no EXECUTE for application roles).
-- ----------------------------------------------------------------------------

-- The current telemetry binding of an asset's parameter: the
-- metadata.asset_points row whose effective range contains p_at, for the
-- logical point whose config.parameters code and qualifier match. Also
-- whether it is a cumulative counter (an active energy-register semantics
-- row for the bound device's profile, or PULSE_COUNT) -- cumulative counters
-- are excluded from alert rules in the first release (ADR-024 §5).
CREATE OR REPLACE FUNCTION analytics.alert_rule_parameter_binding(
    p_asset_id       UUID,
    p_parameter_code TEXT,
    p_qualifier      TEXT,
    p_at             TIMESTAMPTZ
)
RETURNS TABLE
(
    device_id        UUID,
    logical_point_id UUID,
    parameter_name   TEXT,
    unit_symbol      TEXT,
    is_cumulative    BOOLEAN
)
LANGUAGE SQL
STABLE
SET search_path TO pg_catalog, analytics, metadata, config
AS $function$
    SELECT
        ap.device_id,
        lp.id,
        p.name::TEXT,
        COALESCE(pu.symbol, lu.symbol)::TEXT,
        (
            lp.name = 'PULSE_COUNT'
            OR EXISTS (
                SELECT 1
                FROM metadata.devices AS d
                JOIN config.energy_register_semantics AS ers
                  ON ers.profile_id = d.profile_id
                 AND ers.logical_point_id = lp.id
                 AND ers.is_active
                WHERE d.id = ap.device_id
            )
        )
    FROM metadata.asset_points AS ap
    JOIN metadata.logical_points AS lp ON lp.id = ap.logical_point_id
    JOIN config.parameters AS p ON p.id = lp.parameter_id
    LEFT JOIN config.engineering_units AS pu ON pu.id = p.unit_id
    LEFT JOIN config.engineering_units AS lu ON lu.id = lp.unit_id
    WHERE ap.asset_id = p_asset_id
      AND p.code = p_parameter_code
      AND lp.qualifier IS NOT DISTINCT FROM p_qualifier
      AND ap.effective_range @> p_at
    ORDER BY ap.effective_from DESC
    LIMIT 1;
$function$;

-- Validates a full rule definition for a site. NULL error = valid; then
-- parameter_name / unit_symbol describe the parameter.
CREATE OR REPLACE FUNCTION analytics.alert_rule_validate(
    p_site_id        UUID,
    p_name           TEXT,
    p_asset_id       UUID,
    p_parameter_code TEXT,
    p_qualifier      TEXT,
    p_comparator     TEXT,
    p_threshold      NUMERIC,
    p_tolerance      NUMERIC,
    p_schedule_start TIME,
    p_schedule_end   TIME,
    p_weekdays       SMALLINT,
    p_reminder_minutes SMALLINT,
    p_comparison_mode TEXT
)
RETURNS TABLE (error TEXT, parameter_name TEXT, unit_symbol TEXT)
LANGUAGE plpgsql
STABLE
SET search_path TO pg_catalog, analytics, metadata, config
AS $function$
#variable_conflict use_column
DECLARE
    v_binding RECORD;
BEGIN
    IF p_name IS NULL OR btrim(p_name) = '' OR char_length(btrim(p_name)) > 120 THEN
        RETURN QUERY SELECT 'invalid_name'::TEXT, NULL::TEXT, NULL::TEXT; RETURN;
    END IF;
    IF COALESCE(p_comparison_mode, 'FIXED') = 'MEAN' THEN
        RETURN QUERY SELECT 'mean_not_available'::TEXT, NULL::TEXT, NULL::TEXT; RETURN;
    END IF;
    IF COALESCE(p_comparison_mode, 'FIXED') <> 'FIXED' THEN
        RETURN QUERY SELECT 'invalid_comparison_mode'::TEXT, NULL::TEXT, NULL::TEXT; RETURN;
    END IF;
    IF p_comparator IS NULL OR p_comparator NOT IN ('GT', 'LT', 'EQ') THEN
        RETURN QUERY SELECT 'invalid_comparator'::TEXT, NULL::TEXT, NULL::TEXT; RETURN;
    END IF;
    IF p_threshold IS NULL OR p_threshold::TEXT IN ('NaN', 'Infinity', '-Infinity') THEN
        RETURN QUERY SELECT 'invalid_threshold'::TEXT, NULL::TEXT, NULL::TEXT; RETURN;
    END IF;
    IF p_comparator = 'EQ' AND p_tolerance IS NULL THEN
        RETURN QUERY SELECT 'tolerance_required'::TEXT, NULL::TEXT, NULL::TEXT; RETURN;
    END IF;
    IF p_comparator = 'EQ' AND (p_tolerance < 0 OR p_tolerance::TEXT IN ('NaN', 'Infinity')) THEN
        RETURN QUERY SELECT 'invalid_tolerance'::TEXT, NULL::TEXT, NULL::TEXT; RETURN;
    END IF;
    IF p_comparator <> 'EQ' AND p_tolerance IS NOT NULL THEN
        RETURN QUERY SELECT 'tolerance_not_allowed'::TEXT, NULL::TEXT, NULL::TEXT; RETURN;
    END IF;
    IF p_schedule_start IS NULL OR p_schedule_end IS NULL OR p_schedule_start = p_schedule_end THEN
        RETURN QUERY SELECT 'invalid_schedule'::TEXT, NULL::TEXT, NULL::TEXT; RETURN;
    END IF;
    IF p_weekdays IS NULL OR p_weekdays < 1 OR p_weekdays > 127 THEN
        RETURN QUERY SELECT 'invalid_weekdays'::TEXT, NULL::TEXT, NULL::TEXT; RETURN;
    END IF;
    IF p_reminder_minutes IS NOT NULL AND p_reminder_minutes NOT IN (15, 30) THEN
        RETURN QUERY SELECT 'invalid_reminder'::TEXT, NULL::TEXT, NULL::TEXT; RETURN;
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM metadata.assets AS a
        WHERE a.id = p_asset_id AND a.site_id = p_site_id AND a.lifecycle_status = 'ACTIVE'
    ) THEN
        RETURN QUERY SELECT 'asset_not_found'::TEXT, NULL::TEXT, NULL::TEXT; RETURN;
    END IF;

    SELECT * INTO v_binding
    FROM analytics.alert_rule_parameter_binding(p_asset_id, p_parameter_code, p_qualifier, clock_timestamp());
    IF NOT FOUND THEN
        RETURN QUERY SELECT 'parameter_not_available'::TEXT, NULL::TEXT, NULL::TEXT; RETURN;
    END IF;
    IF v_binding.is_cumulative THEN
        RETURN QUERY SELECT 'counter_not_allowed'::TEXT, NULL::TEXT, NULL::TEXT; RETURN;
    END IF;

    RETURN QUERY SELECT NULL::TEXT, v_binding.parameter_name, v_binding.unit_symbol;
END;
$function$;

-- Ends a rule's ACTIVE occurrence (configuration change) and clears its
-- evaluator timers. Returns the ended alert ids.
CREATE OR REPLACE FUNCTION analytics.alert_rule_end_active(p_rule_id UUID, p_at TIMESTAMPTZ)
RETURNS UUID[]
LANGUAGE plpgsql
VOLATILE
SET search_path TO pg_catalog, analytics
AS $function$
#variable_conflict use_column
DECLARE
    v_ended UUID[];
BEGIN
    DELETE FROM analytics.alert_evaluation_candidates WHERE rule_id = p_rule_id;

    WITH ended AS (
        UPDATE analytics.alerts
        SET state             = 'ENDED',
            ended_at          = p_at,
            ended_reason      = 'Alert rule configuration changed',
            ended_reason_code = 'CONFIGURATION_CHANGED',
            data_unavailable  = FALSE,
            last_evaluated_at = p_at
        WHERE rule_id = p_rule_id AND state = 'ACTIVE'
        RETURNING alert_id
    )
    SELECT COALESCE(array_agg(alert_id), ARRAY[]::UUID[]) INTO v_ended FROM ended;
    RETURN v_ended;
END;
$function$;

-- Active-rule limit per site (ADR-024 §13): 25.
CREATE OR REPLACE FUNCTION analytics.alert_rule_site_limit()
RETURNS INTEGER
LANGUAGE SQL
IMMUTABLE
SET search_path TO pg_catalog
AS $function$ SELECT 25 $function$;

CREATE OR REPLACE FUNCTION analytics.alert_rule_json(p_rule analytics.alert_rules)
RETURNS JSONB
LANGUAGE SQL
IMMUTABLE
SET search_path TO pg_catalog, analytics
AS $function$
    SELECT jsonb_build_object(
        'name', p_rule.name,
        'asset_id', p_rule.asset_id,
        'parameter_code', p_rule.parameter_code,
        'qualifier', p_rule.qualifier,
        'comparator', p_rule.comparator,
        'comparison_mode', p_rule.comparison_mode,
        'threshold', p_rule.threshold,
        'tolerance', p_rule.tolerance,
        'schedule_start', p_rule.schedule_start,
        'schedule_end', p_rule.schedule_end,
        'weekdays', p_rule.weekdays,
        'reminder_minutes', p_rule.reminder_minutes,
        'email_requested', p_rule.email_requested,
        'whatsapp_requested', p_rule.whatsapp_requested,
        'enabled', p_rule.enabled,
        'version', p_rule.version
    );
$function$;


-- ----------------------------------------------------------------------------
-- 2. Create.
-- ----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION analytics.create_portal_alert_rule(
    p_portal_user_id   BIGINT,
    p_site_id          UUID,
    p_name             TEXT,
    p_asset_id         UUID,
    p_parameter_code   TEXT,
    p_qualifier        TEXT,
    p_comparator       TEXT,
    p_threshold        NUMERIC,
    p_tolerance        NUMERIC,
    p_schedule_start   TIME,
    p_schedule_end     TIME,
    p_weekdays         SMALLINT,
    p_reminder_minutes SMALLINT,
    p_email_requested  BOOLEAN,
    p_whatsapp_requested BOOLEAN,
    p_enabled          BOOLEAN
)
RETURNS TABLE (result TEXT, rule_id UUID, version INTEGER)
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path TO pg_catalog, analytics, admin, metadata
AS $function$
#variable_conflict use_column
DECLARE
    v_org     UUID;
    v_valid   RECORD;
    v_count   INTEGER;
    v_rule    analytics.alert_rules;
    v_enabled BOOLEAN := COALESCE(p_enabled, TRUE);
BEGIN
    IF NOT admin.portal_user_can_access_site(p_portal_user_id, p_site_id) THEN
        RETURN QUERY SELECT 'not_found'::TEXT, NULL::UUID, NULL::INTEGER; RETURN;
    END IF;
    SELECT s.organization_id INTO v_org FROM metadata.sites AS s WHERE s.id = p_site_id;

    IF NOT admin.portal_user_has_permission(p_portal_user_id, 'alert.configure') THEN
        PERFORM admin.write_audit_event(
            gen_random_uuid(), p_portal_user_id, 'ALERT_RULE_CREATED', 'ALERT_RULE', NULL, v_org, p_site_id,
            '{}'::jsonb, jsonb_build_object('name', p_name), 'REJECTED', 'Missing permission alert.configure.'
        );
        RETURN QUERY SELECT 'forbidden'::TEXT, NULL::UUID, NULL::INTEGER; RETURN;
    END IF;

    SELECT * INTO v_valid FROM analytics.alert_rule_validate(
        p_site_id, p_name, p_asset_id, p_parameter_code, p_qualifier, p_comparator, p_threshold, p_tolerance,
        p_schedule_start, p_schedule_end, p_weekdays, p_reminder_minutes, 'FIXED'
    );
    IF v_valid.error IS NOT NULL THEN
        RETURN QUERY SELECT v_valid.error, NULL::UUID, NULL::INTEGER; RETURN;
    END IF;

    -- Concurrent creates / enables for one site serialise here, so the
    -- active-rule limit cannot be raced past.
    PERFORM pg_advisory_xact_lock(hashtextextended('analytics.alert_rules:' || p_site_id::TEXT, 0));
    IF v_enabled THEN
        SELECT count(*) INTO v_count FROM analytics.alert_rules AS r
        WHERE r.site_id = p_site_id AND r.enabled AND r.deleted_at IS NULL;
        IF v_count >= analytics.alert_rule_site_limit() THEN
            RETURN QUERY SELECT 'rule_limit_reached'::TEXT, NULL::UUID, NULL::INTEGER; RETURN;
        END IF;
    END IF;
    IF EXISTS (
        SELECT 1 FROM analytics.alert_rules AS r
        WHERE r.site_id = p_site_id AND r.deleted_at IS NULL AND lower(r.name) = lower(btrim(p_name))
    ) THEN
        RETURN QUERY SELECT 'name_taken'::TEXT, NULL::UUID, NULL::INTEGER; RETURN;
    END IF;

    INSERT INTO analytics.alert_rules (
        organization_id, site_id, asset_id, name, parameter_code, qualifier, comparator, threshold, tolerance,
        unit_symbol, schedule_start, schedule_end, weekdays, reminder_minutes, email_requested,
        whatsapp_requested, enabled, created_by, updated_by
    )
    VALUES (
        v_org, p_site_id, p_asset_id, btrim(p_name), p_parameter_code, p_qualifier, p_comparator, p_threshold,
        p_tolerance, v_valid.unit_symbol, p_schedule_start, p_schedule_end, p_weekdays, p_reminder_minutes,
        COALESCE(p_email_requested, FALSE), COALESCE(p_whatsapp_requested, FALSE), v_enabled,
        p_portal_user_id, p_portal_user_id
    )
    RETURNING * INTO v_rule;

    PERFORM admin.write_audit_event(
        gen_random_uuid(), p_portal_user_id, 'ALERT_RULE_CREATED', 'ALERT_RULE', v_rule.rule_id, v_org, p_site_id,
        '{}'::jsonb, analytics.alert_rule_json(v_rule)
    );

    RETURN QUERY SELECT 'ok'::TEXT, v_rule.rule_id, v_rule.version;
END;
$function$;


-- ----------------------------------------------------------------------------
-- 3. Update (full definition; optimistic version check).
-- ----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION analytics.update_portal_alert_rule(
    p_portal_user_id   BIGINT,
    p_rule_id          UUID,
    p_expected_version INTEGER,
    p_name             TEXT,
    p_asset_id         UUID,
    p_parameter_code   TEXT,
    p_qualifier        TEXT,
    p_comparator       TEXT,
    p_threshold        NUMERIC,
    p_tolerance        NUMERIC,
    p_schedule_start   TIME,
    p_schedule_end     TIME,
    p_weekdays         SMALLINT,
    p_reminder_minutes SMALLINT,
    p_email_requested  BOOLEAN,
    p_whatsapp_requested BOOLEAN
)
RETURNS TABLE (result TEXT, rule_id UUID, version INTEGER)
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path TO pg_catalog, analytics, admin, metadata
AS $function$
#variable_conflict use_column
DECLARE
    v_old   analytics.alert_rules;
    v_new   analytics.alert_rules;
    v_valid RECORD;
    v_ended UUID[];
    v_now   TIMESTAMPTZ := clock_timestamp();
BEGIN
    SELECT * INTO v_old FROM analytics.alert_rules AS r
    WHERE r.rule_id = p_rule_id AND r.deleted_at IS NULL;
    IF NOT FOUND OR NOT admin.portal_user_can_access_site(p_portal_user_id, v_old.site_id) THEN
        RETURN QUERY SELECT 'not_found'::TEXT, NULL::UUID, NULL::INTEGER; RETURN;
    END IF;

    IF NOT admin.portal_user_has_permission(p_portal_user_id, 'alert.configure') THEN
        PERFORM admin.write_audit_event(
            gen_random_uuid(), p_portal_user_id, 'ALERT_RULE_UPDATED', 'ALERT_RULE', v_old.rule_id,
            v_old.organization_id, v_old.site_id, '{}'::jsonb, '{}'::jsonb, 'REJECTED', 'Missing permission alert.configure.'
        );
        RETURN QUERY SELECT 'forbidden'::TEXT, v_old.rule_id, v_old.version; RETURN;
    END IF;

    -- Serialises with the evaluator (FOR SHARE ... SKIP LOCKED) and other edits.
    SELECT * INTO v_old FROM analytics.alert_rules AS r WHERE r.rule_id = p_rule_id FOR UPDATE;
    IF v_old.deleted_at IS NOT NULL THEN
        RETURN QUERY SELECT 'not_found'::TEXT, NULL::UUID, NULL::INTEGER; RETURN;
    END IF;
    IF p_expected_version IS DISTINCT FROM v_old.version THEN
        RETURN QUERY SELECT 'version_conflict'::TEXT, v_old.rule_id, v_old.version; RETURN;
    END IF;

    SELECT * INTO v_valid FROM analytics.alert_rule_validate(
        v_old.site_id, p_name, p_asset_id, p_parameter_code, p_qualifier, p_comparator, p_threshold, p_tolerance,
        p_schedule_start, p_schedule_end, p_weekdays, p_reminder_minutes, 'FIXED'
    );
    IF v_valid.error IS NOT NULL THEN
        RETURN QUERY SELECT v_valid.error, v_old.rule_id, v_old.version; RETURN;
    END IF;
    IF EXISTS (
        SELECT 1 FROM analytics.alert_rules AS r
        WHERE r.site_id = v_old.site_id AND r.deleted_at IS NULL AND r.rule_id <> v_old.rule_id
          AND lower(r.name) = lower(btrim(p_name))
    ) THEN
        RETURN QUERY SELECT 'name_taken'::TEXT, v_old.rule_id, v_old.version; RETURN;
    END IF;

    IF (btrim(p_name), p_asset_id, p_parameter_code, p_qualifier, p_comparator, p_threshold, p_tolerance,
        p_schedule_start, p_schedule_end, p_weekdays, p_reminder_minutes,
        COALESCE(p_email_requested, FALSE), COALESCE(p_whatsapp_requested, FALSE))
       IS NOT DISTINCT FROM
       (v_old.name, v_old.asset_id, v_old.parameter_code, v_old.qualifier, v_old.comparator, v_old.threshold,
        v_old.tolerance, v_old.schedule_start, v_old.schedule_end, v_old.weekdays, v_old.reminder_minutes,
        v_old.email_requested, v_old.whatsapp_requested) THEN
        RETURN QUERY SELECT 'ok'::TEXT, v_old.rule_id, v_old.version; RETURN;
    END IF;

    -- Any change is a configuration change (ADR-024 §8): the ACTIVE
    -- occurrence ends and the rule gets a new condition identity.
    v_ended := analytics.alert_rule_end_active(v_old.rule_id, v_now);

    UPDATE analytics.alert_rules AS r
    SET name = btrim(p_name), asset_id = p_asset_id, parameter_code = p_parameter_code, qualifier = p_qualifier,
        comparator = p_comparator, threshold = p_threshold, tolerance = p_tolerance,
        unit_symbol = v_valid.unit_symbol, schedule_start = p_schedule_start, schedule_end = p_schedule_end,
        weekdays = p_weekdays, reminder_minutes = p_reminder_minutes,
        email_requested = COALESCE(p_email_requested, FALSE),
        whatsapp_requested = COALESCE(p_whatsapp_requested, FALSE),
        version = r.version + 1, updated_at = v_now, updated_by = p_portal_user_id
    WHERE r.rule_id = v_old.rule_id
    RETURNING * INTO v_new;

    PERFORM admin.write_audit_event(
        gen_random_uuid(), p_portal_user_id, 'ALERT_RULE_UPDATED', 'ALERT_RULE', v_new.rule_id,
        v_new.organization_id, v_new.site_id, analytics.alert_rule_json(v_old),
        analytics.alert_rule_json(v_new) || jsonb_build_object('ended_alert_ids', to_jsonb(v_ended))
    );

    RETURN QUERY SELECT 'ok'::TEXT, v_new.rule_id, v_new.version;
END;
$function$;


-- ----------------------------------------------------------------------------
-- 4. Enable / disable.
-- ----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION analytics.set_portal_alert_rule_enabled(
    p_portal_user_id BIGINT,
    p_rule_id        UUID,
    p_enabled        BOOLEAN
)
RETURNS TABLE (result TEXT, rule_id UUID, version INTEGER)
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path TO pg_catalog, analytics, admin, metadata
AS $function$
#variable_conflict use_column
DECLARE
    v_old   analytics.alert_rules;
    v_new   analytics.alert_rules;
    v_ended UUID[] := ARRAY[]::UUID[];
    v_count INTEGER;
    v_now   TIMESTAMPTZ := clock_timestamp();
    v_action TEXT := CASE WHEN p_enabled THEN 'ALERT_RULE_ENABLED' ELSE 'ALERT_RULE_DISABLED' END;
BEGIN
    IF p_enabled IS NULL THEN
        RETURN QUERY SELECT 'invalid_enabled'::TEXT, NULL::UUID, NULL::INTEGER; RETURN;
    END IF;
    SELECT * INTO v_old FROM analytics.alert_rules AS r
    WHERE r.rule_id = p_rule_id AND r.deleted_at IS NULL;
    IF NOT FOUND OR NOT admin.portal_user_can_access_site(p_portal_user_id, v_old.site_id) THEN
        RETURN QUERY SELECT 'not_found'::TEXT, NULL::UUID, NULL::INTEGER; RETURN;
    END IF;

    IF NOT admin.portal_user_has_permission(p_portal_user_id, 'alert.configure') THEN
        PERFORM admin.write_audit_event(
            gen_random_uuid(), p_portal_user_id, v_action, 'ALERT_RULE', v_old.rule_id,
            v_old.organization_id, v_old.site_id, '{}'::jsonb, '{}'::jsonb, 'REJECTED', 'Missing permission alert.configure.'
        );
        RETURN QUERY SELECT 'forbidden'::TEXT, v_old.rule_id, v_old.version; RETURN;
    END IF;

    IF p_enabled THEN
        PERFORM pg_advisory_xact_lock(hashtextextended('analytics.alert_rules:' || v_old.site_id::TEXT, 0));
    END IF;
    SELECT * INTO v_old FROM analytics.alert_rules AS r WHERE r.rule_id = p_rule_id FOR UPDATE;
    IF v_old.deleted_at IS NOT NULL THEN
        RETURN QUERY SELECT 'not_found'::TEXT, NULL::UUID, NULL::INTEGER; RETURN;
    END IF;
    IF v_old.enabled = p_enabled THEN
        RETURN QUERY SELECT 'ok'::TEXT, v_old.rule_id, v_old.version; RETURN;
    END IF;

    IF p_enabled THEN
        SELECT count(*) INTO v_count FROM analytics.alert_rules AS r
        WHERE r.site_id = v_old.site_id AND r.enabled AND r.deleted_at IS NULL;
        IF v_count >= analytics.alert_rule_site_limit() THEN
            RETURN QUERY SELECT 'rule_limit_reached'::TEXT, v_old.rule_id, v_old.version; RETURN;
        END IF;
        -- Re-enabling starts a new condition identity (fresh qualification).
        UPDATE analytics.alert_rules AS r
        SET enabled = TRUE, version = r.version + 1, updated_at = v_now, updated_by = p_portal_user_id
        WHERE r.rule_id = v_old.rule_id
        RETURNING * INTO v_new;
    ELSE
        v_ended := analytics.alert_rule_end_active(v_old.rule_id, v_now);
        UPDATE analytics.alert_rules AS r
        SET enabled = FALSE, updated_at = v_now, updated_by = p_portal_user_id
        WHERE r.rule_id = v_old.rule_id
        RETURNING * INTO v_new;
    END IF;

    PERFORM admin.write_audit_event(
        gen_random_uuid(), p_portal_user_id, v_action, 'ALERT_RULE', v_new.rule_id,
        v_new.organization_id, v_new.site_id, jsonb_build_object('enabled', v_old.enabled, 'version', v_old.version),
        jsonb_build_object('enabled', v_new.enabled, 'version', v_new.version, 'ended_alert_ids', to_jsonb(v_ended))
    );

    RETURN QUERY SELECT 'ok'::TEXT, v_new.rule_id, v_new.version;
END;
$function$;


-- ----------------------------------------------------------------------------
-- 5. Soft delete.
-- ----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION analytics.delete_portal_alert_rule(
    p_portal_user_id BIGINT,
    p_rule_id        UUID
)
RETURNS TABLE (result TEXT, rule_id UUID, version INTEGER)
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path TO pg_catalog, analytics, admin, metadata
AS $function$
#variable_conflict use_column
DECLARE
    v_old   analytics.alert_rules;
    v_ended UUID[];
    v_now   TIMESTAMPTZ := clock_timestamp();
BEGIN
    SELECT * INTO v_old FROM analytics.alert_rules AS r
    WHERE r.rule_id = p_rule_id AND r.deleted_at IS NULL;
    IF NOT FOUND OR NOT admin.portal_user_can_access_site(p_portal_user_id, v_old.site_id) THEN
        RETURN QUERY SELECT 'not_found'::TEXT, NULL::UUID, NULL::INTEGER; RETURN;
    END IF;

    IF NOT admin.portal_user_has_permission(p_portal_user_id, 'alert.configure') THEN
        PERFORM admin.write_audit_event(
            gen_random_uuid(), p_portal_user_id, 'ALERT_RULE_DELETED', 'ALERT_RULE', v_old.rule_id,
            v_old.organization_id, v_old.site_id, '{}'::jsonb, '{}'::jsonb, 'REJECTED', 'Missing permission alert.configure.'
        );
        RETURN QUERY SELECT 'forbidden'::TEXT, v_old.rule_id, v_old.version; RETURN;
    END IF;

    SELECT * INTO v_old FROM analytics.alert_rules AS r WHERE r.rule_id = p_rule_id FOR UPDATE;
    IF v_old.deleted_at IS NOT NULL THEN
        RETURN QUERY SELECT 'not_found'::TEXT, NULL::UUID, NULL::INTEGER; RETURN;
    END IF;

    v_ended := analytics.alert_rule_end_active(v_old.rule_id, v_now);
    UPDATE analytics.alert_rules AS r
    SET enabled = FALSE, deleted_at = v_now, deleted_by = p_portal_user_id,
        updated_at = v_now, updated_by = p_portal_user_id
    WHERE r.rule_id = v_old.rule_id;

    PERFORM admin.write_audit_event(
        gen_random_uuid(), p_portal_user_id, 'ALERT_RULE_DELETED', 'ALERT_RULE', v_old.rule_id,
        v_old.organization_id, v_old.site_id, analytics.alert_rule_json(v_old),
        jsonb_build_object('deleted_at', v_now, 'ended_alert_ids', to_jsonb(v_ended))
    );

    RETURN QUERY SELECT 'ok'::TEXT, v_old.rule_id, v_old.version;
END;
$function$;


-- ----------------------------------------------------------------------------
-- 6. Acknowledge (never resolution; ADR-024 §7).
-- ----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION analytics.acknowledge_portal_alert(
    p_portal_user_id BIGINT,
    p_alert_id       UUID
)
RETURNS TABLE (result TEXT, alert_id UUID, version INTEGER)
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path TO pg_catalog, analytics, admin, metadata
AS $function$
#variable_conflict use_column
DECLARE
    v_alert analytics.alerts;
    v_actor_type TEXT;
    v_now   TIMESTAMPTZ := clock_timestamp();
BEGIN
    SELECT * INTO v_alert FROM analytics.alerts AS a WHERE a.alert_id = p_alert_id;
    IF NOT FOUND OR NOT admin.portal_user_can_access_site(p_portal_user_id, v_alert.site_id) THEN
        RETURN QUERY SELECT 'not_found'::TEXT, NULL::UUID, NULL::INTEGER; RETURN;
    END IF;

    IF NOT admin.portal_user_has_permission(p_portal_user_id, 'alert.acknowledge') THEN
        PERFORM admin.write_audit_event(
            gen_random_uuid(), p_portal_user_id, 'ALERT_ACKNOWLEDGED', 'ALERT', v_alert.alert_id,
            v_alert.organization_id, v_alert.site_id, '{}'::jsonb, '{}'::jsonb, 'REJECTED', 'Missing permission alert.acknowledge.'
        );
        RETURN QUERY SELECT 'forbidden'::TEXT, v_alert.alert_id, NULL::INTEGER; RETURN;
    END IF;

    SELECT * INTO v_alert FROM analytics.alerts AS a WHERE a.alert_id = p_alert_id FOR UPDATE;
    IF v_alert.state <> 'ACTIVE' THEN
        RETURN QUERY SELECT 'alert_not_active'::TEXT, v_alert.alert_id, NULL::INTEGER; RETURN;
    END IF;
    IF v_alert.acknowledged_at IS NOT NULL THEN
        RETURN QUERY SELECT 'already_acknowledged'::TEXT, v_alert.alert_id, NULL::INTEGER; RETURN;
    END IF;

    SELECT CASE WHEN pu.access_scope_mode = 'GLOBAL' THEN 'WISEWATTS_STAFF' ELSE 'CUSTOMER' END
    INTO v_actor_type
    FROM admin.portal_users AS pu WHERE pu.portal_user_id = p_portal_user_id;

    UPDATE analytics.alerts AS a
    SET acknowledged_at = v_now, acknowledged_by = p_portal_user_id, acknowledged_actor_type = v_actor_type
    WHERE a.alert_id = v_alert.alert_id;

    PERFORM admin.write_audit_event(
        gen_random_uuid(), p_portal_user_id, 'ALERT_ACKNOWLEDGED', 'ALERT', v_alert.alert_id,
        v_alert.organization_id, v_alert.site_id, jsonb_build_object('acknowledged', FALSE),
        jsonb_build_object('acknowledged', TRUE, 'acknowledged_at', v_now, 'rule_id', v_alert.rule_id)
    );

    RETURN QUERY SELECT 'ok'::TEXT, v_alert.alert_id, NULL::INTEGER;
END;
$function$;


-- ----------------------------------------------------------------------------
-- 7. Ownership and grants.
-- ----------------------------------------------------------------------------

DO $grants$
DECLARE
    v_sig TEXT;
BEGIN
    FOREACH v_sig IN ARRAY ARRAY[
        'analytics.alert_rule_parameter_binding(uuid, text, text, timestamptz)',
        'analytics.alert_rule_validate(uuid, text, uuid, text, text, text, numeric, numeric, time, time, smallint, smallint, text)',
        'analytics.alert_rule_end_active(uuid, timestamptz)',
        'analytics.alert_rule_site_limit()',
        'analytics.alert_rule_json(analytics.alert_rules)'
    ] LOOP
        EXECUTE format('ALTER FUNCTION %s OWNER TO ems_admin', v_sig);
        EXECUTE format('REVOKE ALL ON FUNCTION %s FROM PUBLIC', v_sig);
    END LOOP;

    FOREACH v_sig IN ARRAY ARRAY[
        'analytics.create_portal_alert_rule(bigint, uuid, text, uuid, text, text, text, numeric, numeric, time, time, smallint, smallint, boolean, boolean, boolean)',
        'analytics.update_portal_alert_rule(bigint, uuid, integer, text, uuid, text, text, text, numeric, numeric, time, time, smallint, smallint, boolean, boolean)',
        'analytics.set_portal_alert_rule_enabled(bigint, uuid, boolean)',
        'analytics.delete_portal_alert_rule(bigint, uuid)',
        'analytics.acknowledge_portal_alert(bigint, uuid)'
    ] LOOP
        EXECUTE format('ALTER FUNCTION %s OWNER TO ems_admin', v_sig);
        EXECUTE format('REVOKE ALL ON FUNCTION %s FROM PUBLIC', v_sig);
        EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO ems_app', v_sig);
    END LOOP;
END;
$grants$;

COMMENT ON FUNCTION analytics.create_portal_alert_rule(BIGINT, UUID, TEXT, UUID, TEXT, TEXT, TEXT, NUMERIC, NUMERIC, TIME, TIME, SMALLINT, SMALLINT, BOOLEAN, BOOLEAN, BOOLEAN) IS
'ADR-024: creates an alert rule (alert.configure). Result ok | not_found (site not accessible; not audited) | forbidden (audited REJECTED) | validation code | rule_limit_reached (25 enabled rules per site) | name_taken. Audited ALERT_RULE_CREATED in the same transaction.';
COMMENT ON FUNCTION analytics.update_portal_alert_rule(BIGINT, UUID, INTEGER, TEXT, UUID, TEXT, TEXT, TEXT, NUMERIC, NUMERIC, TIME, TIME, SMALLINT, SMALLINT, BOOLEAN, BOOLEAN) IS
'ADR-024: replaces a rule''s definition (alert.configure) when p_expected_version matches (else version_conflict). Any change ends the ACTIVE occurrence (ENDED / CONFIGURATION_CHANGED) and increments version. Audited ALERT_RULE_UPDATED.';
COMMENT ON FUNCTION analytics.set_portal_alert_rule_enabled(BIGINT, UUID, BOOLEAN) IS
'ADR-024: enables (version + 1, 25-rule limit) or disables (ends the ACTIVE occurrence) a rule (alert.configure). Idempotent. Audited ALERT_RULE_ENABLED / ALERT_RULE_DISABLED.';
COMMENT ON FUNCTION analytics.delete_portal_alert_rule(BIGINT, UUID) IS
'ADR-024: soft-deletes a rule (alert.configure): ends its ACTIVE occurrence, keeps every historical occurrence. Audited ALERT_RULE_DELETED.';
COMMENT ON FUNCTION analytics.acknowledge_portal_alert(BIGINT, UUID) IS
'ADR-024 §7: acknowledges an ACTIVE alert (alert.acknowledge): records who and when; the alert stays ACTIVE (acknowledgement is never resolution). alert_not_active / already_acknowledged otherwise. Audited ALERT_ACKNOWLEDGED.';


DO $post$
DECLARE
    v_sig TEXT;
BEGIN
    FOREACH v_sig IN ARRAY ARRAY[
        'analytics.create_portal_alert_rule(bigint, uuid, text, uuid, text, text, text, numeric, numeric, time, time, smallint, smallint, boolean, boolean, boolean)',
        'analytics.update_portal_alert_rule(bigint, uuid, integer, text, uuid, text, text, text, numeric, numeric, time, time, smallint, smallint, boolean, boolean)',
        'analytics.set_portal_alert_rule_enabled(bigint, uuid, boolean)',
        'analytics.delete_portal_alert_rule(bigint, uuid)',
        'analytics.acknowledge_portal_alert(bigint, uuid)'
    ] LOOP
        IF NOT EXISTS (
            SELECT 1 FROM pg_proc AS p JOIN pg_roles AS r ON r.oid = p.proowner
            WHERE p.oid = v_sig::regprocedure AND p.prosecdef AND r.rolname = 'ems_admin' AND p.proconfig IS NOT NULL
        ) THEN
            RAISE EXCEPTION 'Migration 323 postcondition failed: % is not SECURITY DEFINER / ems_admin / pinned search_path.', v_sig;
        END IF;
        IF has_function_privilege('public', v_sig, 'EXECUTE') OR NOT has_function_privilege('ems_app', v_sig, 'EXECUTE') THEN
            RAISE EXCEPTION 'Migration 323 postcondition failed: % grants are not as expected.', v_sig;
        END IF;
    END LOOP;
END;
$post$;
