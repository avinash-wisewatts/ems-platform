-- ============================================================================
-- Rollback of migration 331 (WhatsApp Phase 1 configuration).
--
-- DESTRUCTIVE: drops the WhatsApp settings, recipients and consent-wording
-- tables, so EVERY STORED PHONE NUMBER IS DELETED (no copy is kept; review
-- B3). The deleted row counts are reported (NOTICE) before the drop. Their
-- audit events in admin.audit_events are kept (they hold recipient ids only).
--
-- Then drops the CHECK (NOT whatsapp_requested), removes the retired-column
-- comment, restores the migration 323 definitions of
-- create_portal_alert_rule, update_portal_alert_rule and
-- delete_portal_alert_rule (copied verbatim from
-- postgres/migrations/323_alert_rule_write_functions.sql; signatures, owner
-- and grants are unchanged by CREATE OR REPLACE) and removes the ledger row.
--
-- Run only with explicit authorisation, like any staging rollback, and only
-- after deploying an application image without the WhatsApp routes (the API
-- would otherwise call functions that no longer exist). No CASCADE is used.
-- ============================================================================

BEGIN;

DO $report$
DECLARE
    v_settings   BIGINT := 0;
    v_recipients BIGINT := 0;
    v_statements BIGINT := 0;
BEGIN
    IF to_regclass('analytics.alert_rule_whatsapp_settings') IS NOT NULL THEN
        SELECT count(*) INTO v_settings FROM analytics.alert_rule_whatsapp_settings;
    END IF;
    IF to_regclass('analytics.alert_rule_whatsapp_recipients') IS NOT NULL THEN
        SELECT count(*) INTO v_recipients FROM analytics.alert_rule_whatsapp_recipients;
    END IF;
    IF to_regclass('analytics.alert_whatsapp_consent_statements') IS NOT NULL THEN
        SELECT count(*) INTO v_statements FROM analytics.alert_whatsapp_consent_statements;
    END IF;
    RAISE NOTICE 'Rollback 331: deleting % WhatsApp settings row(s), % recipient number(s), % consent-wording version(s).',
        v_settings, v_recipients, v_statements;
END;
$report$;

-- 1. Restore the migration 323 rule functions first, so that from here on
--    nothing references the WhatsApp tables.
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

COMMENT ON FUNCTION analytics.create_portal_alert_rule(BIGINT, UUID, TEXT, UUID, TEXT, TEXT, TEXT, NUMERIC, NUMERIC, TIME, TIME, SMALLINT, SMALLINT, BOOLEAN, BOOLEAN, BOOLEAN) IS
'ADR-024: creates an alert rule (alert.configure). Result ok | not_found (site not accessible; not audited) | forbidden (audited REJECTED) | validation code | rule_limit_reached (25 enabled rules per site) | name_taken. Audited ALERT_RULE_CREATED in the same transaction.';
COMMENT ON FUNCTION analytics.update_portal_alert_rule(BIGINT, UUID, INTEGER, TEXT, UUID, TEXT, TEXT, TEXT, NUMERIC, NUMERIC, TIME, TIME, SMALLINT, SMALLINT, BOOLEAN, BOOLEAN) IS
'ADR-024: replaces a rule''s definition (alert.configure) when p_expected_version matches (else version_conflict). Any change ends the ACTIVE occurrence (ENDED / CONFIGURATION_CHANGED) and increments version. Audited ALERT_RULE_UPDATED.';
COMMENT ON FUNCTION analytics.delete_portal_alert_rule(BIGINT, UUID) IS
'ADR-024: soft-deletes a rule (alert.configure): ends its ACTIVE occurrence, keeps every historical occurrence. Audited ALERT_RULE_DELETED.';

-- 2. Drop the WhatsApp functions and tables (recipients -> settings -> register).
DROP FUNCTION IF EXISTS analytics.save_portal_alert_rule_whatsapp(bigint, uuid, boolean, jsonb, integer, text);
DROP FUNCTION IF EXISTS analytics.get_portal_alert_rule_whatsapp(bigint, uuid);
DROP FUNCTION IF EXISTS analytics.get_portal_alert_rule_whatsapp_summaries(bigint, uuid);
DROP FUNCTION IF EXISTS analytics.alert_whatsapp_audit_recipients(uuid);
DROP FUNCTION IF EXISTS analytics.alert_whatsapp_current_statement_version();
DROP FUNCTION IF EXISTS analytics.alert_whatsapp_actor_is_automation(bigint);

DROP TABLE IF EXISTS analytics.alert_rule_whatsapp_recipients;
DROP TABLE IF EXISTS analytics.alert_rule_whatsapp_settings;
DROP FUNCTION IF EXISTS analytics.alert_rule_whatsapp_settings_scope_guard();
DROP TABLE IF EXISTS analytics.alert_whatsapp_consent_statements;

-- 3. Un-retire the legacy flag.
ALTER TABLE analytics.alert_rules DROP CONSTRAINT IF EXISTS alert_rules_whatsapp_retired_chk;
COMMENT ON COLUMN analytics.alert_rules.whatsapp_requested IS NULL;

DELETE FROM admin.schema_migrations WHERE migration_id = '331_alert_whatsapp_configuration';

COMMIT;
