-- ============================================================================
-- Rollback of migration 332 (WhatsApp opt-in wording WA-OPTIN-1, R9 / D21).
--
-- DESTRUCTIVE: every recipient was confirmed under a wording loaded by 332,
-- so EVERY STORED WHATSAPP NUMBER IS DELETED (no copy is kept, as for the
-- migration 331 rollback). Rules that had WhatsApp switched on are switched
-- off (their revision moves on). Counts are reported (NOTICE) first. Audit
-- events in admin.audit_events are kept (they hold recipient ids only).
--
-- Then deletes wording WA-OPTIN-1, drops the consent_business_name column,
-- the {business_name} CHECK, the Legal review columns and the business-name
-- helper, restores the
-- migration 331 definitions of get_portal_alert_rule_whatsapp,
-- save_portal_alert_rule_whatsapp (six arguments) and
-- alert_whatsapp_audit_recipients (copied verbatim from
-- postgres/migrations/331_alert_whatsapp_configuration.sql) with their
-- grants, and removes the ledger row. The result is the migration 331 state:
-- an empty register, so new opt-ins are refused again.
--
-- Run only with explicit authorisation, and run it BEFORE any rollback of
-- migration 331. An application image older than migration 332 works against
-- the result (it calls the six-argument save).
-- ============================================================================

BEGIN;

-- Migration 333 (WhatsApp delivery) builds on 332: roll it back first
-- (postgres/maintenance/333_alert_whatsapp_delivery_rollback.sql).
DO $order$
BEGIN
    IF EXISTS (SELECT 1 FROM admin.schema_migrations WHERE migration_id = '333_alert_whatsapp_delivery') THEN
        RAISE EXCEPTION 'Rollback 332 refused: migration 333 is applied; run its rollback first.';
    END IF;
END;
$order$;

DO $report$
DECLARE
    v_recipients BIGINT;
    v_enabled    BIGINT;
BEGIN
    SELECT count(*) INTO v_recipients FROM analytics.alert_rule_whatsapp_recipients;
    SELECT count(*) INTO v_enabled FROM analytics.alert_rule_whatsapp_settings WHERE enabled;
    RAISE NOTICE 'Rollback 332: deleting % recipient number(s); switching off WhatsApp on % rule(s).',
        v_recipients, v_enabled;
END;
$report$;

-- 1. Remove the consents recorded under 332 (and switch WhatsApp off where it
--    was on: a rule never stays on with no numbers).
DELETE FROM analytics.alert_rule_whatsapp_recipients;
UPDATE analytics.alert_rule_whatsapp_settings
SET enabled = FALSE, revision = revision + 1, updated_at = clock_timestamp()
WHERE enabled;

-- 2. Restore the migration 331 functions.
DROP FUNCTION IF EXISTS analytics.save_portal_alert_rule_whatsapp(bigint, uuid, boolean, jsonb, integer, text, text);

CREATE OR REPLACE FUNCTION analytics.alert_whatsapp_audit_recipients(p_rule_id UUID)
RETURNS JSONB
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path TO pg_catalog, analytics
AS $function$
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
               'recipient_id', r.recipient_id,
               'consent_state', r.consent_state,
               'consent_confirmed_at', r.consent_confirmed_at,
               'consent_confirmed_by', r.consent_confirmed_by,
               'consent_statement_version', r.consent_statement_version
           ) ORDER BY r.recipient_id), '[]'::jsonb)
    FROM analytics.alert_rule_whatsapp_recipients AS r
    WHERE r.rule_id = p_rule_id;
$function$;

CREATE OR REPLACE FUNCTION analytics.get_portal_alert_rule_whatsapp(
    p_portal_user_id BIGINT,
    p_rule_id        UUID
)
RETURNS TABLE (result TEXT, enabled BOOLEAN, revision INTEGER, recipients JSONB, consent_statement JSONB)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO pg_catalog, analytics, admin
AS $function$
#variable_conflict use_column
DECLARE
    v_rule analytics.alert_rules;
    v_set  analytics.alert_rule_whatsapp_settings;
BEGIN
    -- R5 first: nothing about the rule is revealed to an automation account.
    IF analytics.alert_whatsapp_actor_is_automation(p_portal_user_id) THEN
        RETURN QUERY SELECT 'forbidden'::TEXT, NULL::BOOLEAN, NULL::INTEGER, NULL::JSONB, NULL::JSONB; RETURN;
    END IF;
    SELECT * INTO v_rule FROM analytics.alert_rules AS r WHERE r.rule_id = p_rule_id AND r.deleted_at IS NULL;
    IF NOT FOUND OR NOT admin.portal_user_can_access_site(p_portal_user_id, v_rule.site_id) THEN
        RETURN QUERY SELECT 'not_found'::TEXT, NULL::BOOLEAN, NULL::INTEGER, NULL::JSONB, NULL::JSONB; RETURN;
    END IF;
    IF NOT admin.portal_user_has_permission(p_portal_user_id, 'alert.configure') THEN
        RETURN QUERY SELECT 'forbidden'::TEXT, NULL::BOOLEAN, NULL::INTEGER, NULL::JSONB, NULL::JSONB; RETURN;
    END IF;

    SELECT * INTO v_set FROM analytics.alert_rule_whatsapp_settings AS s WHERE s.rule_id = v_rule.rule_id;
    RETURN QUERY
    SELECT 'ok'::TEXT,
           COALESCE(v_set.enabled, FALSE),
           COALESCE(v_set.revision, 0),
           COALESCE((
               SELECT jsonb_agg(jsonb_build_object(
                          'recipient_id', r.recipient_id,
                          'phone_e164', r.phone_e164,
                          'consent_state', r.consent_state,
                          'consent_confirmed_at', r.consent_confirmed_at,
                          'consent_confirmed_by_name',
                              CASE WHEN pu.access_scope_mode = 'GLOBAL' THEN 'WiseWatts Support'
                                   ELSE COALESCE(nullif(btrim(pu.display_name), ''), 'Site user') END,
                          'consent_statement_version', r.consent_statement_version
                      ) ORDER BY r.created_at, r.recipient_id)
               FROM analytics.alert_rule_whatsapp_recipients AS r
               LEFT JOIN admin.portal_users AS pu ON pu.portal_user_id = r.consent_confirmed_by
               WHERE r.rule_id = v_rule.rule_id
           ), '[]'::jsonb),
           -- The approved wording the UI must show for a new opt-in (R6, D21),
           -- or NULL while none is approved (new opt-ins are then refused).
           (SELECT jsonb_build_object('version', s.version, 'text', s.statement_text)
            FROM analytics.alert_whatsapp_consent_statements AS s
            WHERE s.version = analytics.alert_whatsapp_current_statement_version());
END;
$function$;

CREATE OR REPLACE FUNCTION analytics.save_portal_alert_rule_whatsapp(
    p_portal_user_id    BIGINT,
    p_rule_id           UUID,
    p_enabled           BOOLEAN,
    p_recipients        JSONB,
    p_expected_revision INTEGER,
    p_consent_statement_version TEXT
)
RETURNS TABLE (result TEXT, revision INTEGER)
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path TO pg_catalog, analytics, admin
AS $function$
#variable_conflict use_column
DECLARE
    c_max_recipients CONSTANT INTEGER := 10;
    v_rule      analytics.alert_rules;
    v_set       analytics.alert_rule_whatsapp_settings;
    v_found     BOOLEAN;
    v_current   INTEGER;
    v_enabled   BOOLEAN := COALESCE(p_enabled, FALSE);
    v_item      JSONB;
    v_phone     TEXT;
    v_rid       UUID;
    v_confirmed BOOLEAN;
    v_existing  analytics.alert_rule_whatsapp_recipients;
    v_keep      UUID[] := ARRAY[]::UUID[];
    v_new       TEXT[] := ARRAY[]::TEXT[];
    v_seen      TEXT[] := ARRAY[]::TEXT[];
    v_removed   UUID[];
    v_added     UUID[] := ARRAY[]::UUID[];
    v_statement TEXT;
    v_previous  JSONB;
    v_now       TIMESTAMPTZ := clock_timestamp();
    v_new_id    UUID;
    v_revision  INTEGER;
BEGIN
    IF analytics.alert_whatsapp_actor_is_automation(p_portal_user_id) THEN
        RETURN QUERY SELECT 'forbidden'::TEXT, NULL::INTEGER; RETURN;
    END IF;
    -- FOR KEY SHARE: serialises with a concurrent rule edit / delete, never
    -- with the evaluator, and writes nothing to the rule.
    SELECT * INTO v_rule FROM analytics.alert_rules AS r
    WHERE r.rule_id = p_rule_id AND r.deleted_at IS NULL
    FOR KEY SHARE;
    IF NOT FOUND OR NOT admin.portal_user_can_access_site(p_portal_user_id, v_rule.site_id) THEN
        RETURN QUERY SELECT 'not_found'::TEXT, NULL::INTEGER; RETURN;
    END IF;
    IF NOT admin.portal_user_has_permission(p_portal_user_id, 'alert.configure') THEN
        RETURN QUERY SELECT 'forbidden'::TEXT, NULL::INTEGER; RETURN;
    END IF;

    -- Concurrent saves of one rule (including two first saves) serialise here;
    -- the loser sees the new revision and is refused as stale (409, never 500).
    PERFORM pg_advisory_xact_lock(hashtextextended('analytics.alert_rule_whatsapp:' || v_rule.rule_id::TEXT, 0));
    SELECT * INTO v_set FROM analytics.alert_rule_whatsapp_settings AS s WHERE s.rule_id = v_rule.rule_id FOR UPDATE;
    v_found := FOUND;
    v_current := CASE WHEN v_found THEN v_set.revision ELSE 0 END;
    IF p_expected_revision IS DISTINCT FROM v_current THEN
        RETURN QUERY SELECT 'whatsapp_config_stale'::TEXT, v_current; RETURN;
    END IF;

    -- Validation (nothing has been written yet).
    IF p_recipients IS NULL OR jsonb_typeof(p_recipients) <> 'array' THEN
        RETURN QUERY SELECT 'whatsapp_invalid_request'::TEXT, v_current; RETURN;
    END IF;
    IF jsonb_array_length(p_recipients) > c_max_recipients THEN
        RETURN QUERY SELECT 'whatsapp_too_many_recipients'::TEXT, v_current; RETURN;
    END IF;
    FOR v_item IN SELECT value FROM jsonb_array_elements(p_recipients) LOOP
        IF jsonb_typeof(v_item) <> 'object' OR jsonb_typeof(v_item -> 'phone') IS DISTINCT FROM 'string' THEN
            RETURN QUERY SELECT 'whatsapp_invalid_request'::TEXT, v_current; RETURN;
        END IF;
        v_phone := v_item ->> 'phone';
        IF v_phone !~ '^\+[1-9][0-9]{7,14}$' THEN
            RETURN QUERY SELECT 'whatsapp_invalid_phone'::TEXT, v_current; RETURN;
        END IF;
        IF v_phone = ANY(v_seen) THEN
            RETURN QUERY SELECT 'whatsapp_duplicate_phone'::TEXT, v_current; RETURN;
        END IF;
        v_seen := v_seen || v_phone;

        v_rid := NULL;
        IF v_item ? 'recipient_id' AND jsonb_typeof(v_item -> 'recipient_id') <> 'null' THEN
            BEGIN
                v_rid := (v_item ->> 'recipient_id')::UUID;
            EXCEPTION WHEN invalid_text_representation THEN
                RETURN QUERY SELECT 'whatsapp_unknown_recipient'::TEXT, v_current; RETURN;
            END;
            SELECT * INTO v_existing FROM analytics.alert_rule_whatsapp_recipients AS x
            WHERE x.recipient_id = v_rid AND x.rule_id = v_rule.rule_id;
            IF NOT FOUND OR v_rid = ANY(v_keep) THEN
                -- Another rule's (or site's, or organisation's) recipient, an
                -- unknown id, or the same id twice: consent is never carried over.
                RETURN QUERY SELECT 'whatsapp_unknown_recipient'::TEXT, v_current; RETURN;
            END IF;
        END IF;

        IF v_rid IS NOT NULL AND v_existing.phone_e164 = v_phone THEN
            v_keep := v_keep || v_rid;  -- unchanged: keeps its consent
        ELSE
            -- New, or a changed number (A-2): needs a fresh confirmation.
            v_confirmed := CASE WHEN jsonb_typeof(v_item -> 'opt_in_confirmed') = 'boolean'
                                THEN (v_item ->> 'opt_in_confirmed')::BOOLEAN ELSE FALSE END;
            IF NOT v_confirmed THEN
                RETURN QUERY SELECT 'whatsapp_consent_required'::TEXT, v_current; RETURN;
            END IF;
            IF v_rid IS NOT NULL THEN
                v_keep := v_keep || v_rid;  -- reserve the id against reuse in this request
            END IF;
            v_new := v_new || v_phone;
        END IF;
    END LOOP;

    IF cardinality(v_new) > 0 THEN
        v_statement := analytics.alert_whatsapp_current_statement_version();
        IF v_statement IS NULL THEN
            -- No Product-approved wording (D21, R9): new opt-ins are refused.
            RETURN QUERY SELECT 'whatsapp_consent_statement_missing'::TEXT, v_current; RETURN;
        END IF;
        IF p_consent_statement_version IS DISTINCT FROM v_statement THEN
            -- The administrator confirmed a different (or no) wording.
            RETURN QUERY SELECT 'whatsapp_consent_statement_changed'::TEXT, v_current; RETURN;
        END IF;
    END IF;
    IF v_enabled AND cardinality(v_seen) = 0 THEN
        RETURN QUERY SELECT 'whatsapp_recipients_required'::TEXT, v_current; RETURN;
    END IF;

    -- Recipients kept unchanged (a changed number's old id is not kept).
    v_keep := ARRAY(
        SELECT x.recipient_id FROM analytics.alert_rule_whatsapp_recipients AS x
        WHERE x.rule_id = v_rule.rule_id AND x.recipient_id = ANY(v_keep)
          AND x.phone_e164 = ANY(v_seen) AND NOT (x.phone_e164 = ANY(v_new))
    );
    v_removed := ARRAY(
        SELECT x.recipient_id FROM analytics.alert_rule_whatsapp_recipients AS x
        WHERE x.rule_id = v_rule.rule_id AND NOT (x.recipient_id = ANY(v_keep))
        ORDER BY x.recipient_id
    );

    -- No-op: nothing changes, nothing is written or audited.
    IF cardinality(v_new) = 0 AND cardinality(v_removed) = 0
       AND v_enabled = COALESCE(v_set.enabled, FALSE) THEN
        RETURN QUERY SELECT 'ok'::TEXT, v_current; RETURN;
    END IF;

    v_previous := jsonb_build_object(
        'enabled', COALESCE(v_set.enabled, FALSE),
        'revision', v_current,
        'recipients', analytics.alert_whatsapp_audit_recipients(v_rule.rule_id)
    );

    IF v_found THEN
        UPDATE analytics.alert_rule_whatsapp_settings AS s
        SET enabled = v_enabled, revision = s.revision + 1, updated_at = v_now, updated_by = p_portal_user_id
        WHERE s.rule_id = v_rule.rule_id
        RETURNING s.revision INTO v_revision;
    ELSE
        INSERT INTO analytics.alert_rule_whatsapp_settings
            (rule_id, organization_id, site_id, enabled, revision, created_at, created_by, updated_at, updated_by)
        VALUES (v_rule.rule_id, v_rule.organization_id, v_rule.site_id, v_enabled, 1, v_now, p_portal_user_id,
                v_now, p_portal_user_id)
        RETURNING revision INTO v_revision;
    END IF;

    DELETE FROM analytics.alert_rule_whatsapp_recipients AS x
    WHERE x.rule_id = v_rule.rule_id AND x.recipient_id = ANY(v_removed);

    FOREACH v_phone IN ARRAY v_new LOOP
        INSERT INTO analytics.alert_rule_whatsapp_recipients
            (rule_id, phone_e164, consent_state, consent_confirmed_at, consent_confirmed_by,
             consent_statement_version, created_at, created_by)
        -- created_at per row keeps the entered order; consent time is the save instant.
        VALUES (v_rule.rule_id, v_phone, 'CONFIRMED', v_now, p_portal_user_id, v_statement, clock_timestamp(),
                p_portal_user_id)
        RETURNING recipient_id INTO v_new_id;
        v_added := v_added || v_new_id;
    END LOOP;

    PERFORM admin.write_audit_event(
        gen_random_uuid(), p_portal_user_id, 'ALERT_RULE_WHATSAPP_UPDATED', 'ALERT_RULE_WHATSAPP', v_rule.rule_id,
        v_rule.organization_id, v_rule.site_id,
        v_previous,
        jsonb_build_object(
            'enabled', v_enabled,
            'revision', v_revision,
            'recipients', analytics.alert_whatsapp_audit_recipients(v_rule.rule_id),
            'added_recipient_ids', to_jsonb(v_added),
            'removed_recipient_ids', to_jsonb(v_removed),
            'consent_confirmed_recipient_ids', to_jsonb(v_added)
        )
    );

    RETURN QUERY SELECT 'ok'::TEXT, v_revision;
END;
$function$;

DO $grants$
DECLARE
    v_sig TEXT;
    v_customer_api BOOLEAN := EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'ems_customer_api');
BEGIN
    EXECUTE 'ALTER FUNCTION analytics.alert_whatsapp_audit_recipients(uuid) OWNER TO ems_admin';
    EXECUTE 'REVOKE ALL ON FUNCTION analytics.alert_whatsapp_audit_recipients(uuid) FROM PUBLIC';
    FOREACH v_sig IN ARRAY ARRAY[
        'analytics.get_portal_alert_rule_whatsapp(bigint, uuid)',
        'analytics.save_portal_alert_rule_whatsapp(bigint, uuid, boolean, jsonb, integer, text)'
    ] LOOP
        EXECUTE format('ALTER FUNCTION %s OWNER TO ems_admin', v_sig);
        EXECUTE format('REVOKE ALL ON FUNCTION %s FROM PUBLIC', v_sig);
        EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO ems_app', v_sig);
        IF v_customer_api THEN
            EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO ems_customer_api', v_sig);
        END IF;
    END LOOP;
END;
$grants$;

COMMENT ON FUNCTION analytics.get_portal_alert_rule_whatsapp(BIGINT, UUID) IS
'WhatsApp Phase 1: one rule''s WhatsApp configuration with full numbers, and the current approved opt-in wording {version, text} (NULL while none is approved). Result ok | forbidden (designated report automation account of any site, R5; or missing alert.configure, D16) | not_found (unknown, deleted or inaccessible rule). Revision 0 = never configured.';COMMENT ON FUNCTION analytics.save_portal_alert_rule_whatsapp(BIGINT, UUID, BOOLEAN, JSONB, INTEGER, TEXT) IS
'WhatsApp Phase 1: replace-all save of one rule''s WhatsApp settings and recipients (alert.configure; R5 refused). Revision-checked (whatsapp_config_stale). Refusals: whatsapp_invalid_request | whatsapp_invalid_phone | whatsapp_duplicate_phone | whatsapp_too_many_recipients | whatsapp_unknown_recipient | whatsapp_consent_required | whatsapp_consent_statement_missing | whatsapp_consent_statement_changed | whatsapp_recipients_required | not_found | forbidden. One audit row (ALERT_RULE_WHATSAPP_UPDATED) per effective save, without phone numbers; refusals and no-ops write nothing. Never touches the rule, its occurrences or timers. Sends nothing.';
DROP FUNCTION IF EXISTS analytics.alert_whatsapp_business_name(uuid);

-- 3. Remove the wording and the 332 schema additions.
DELETE FROM analytics.alert_whatsapp_consent_statements WHERE version = 'WA-OPTIN-1';
ALTER TABLE analytics.alert_rule_whatsapp_recipients DROP COLUMN IF EXISTS consent_business_name;
ALTER TABLE analytics.alert_whatsapp_consent_statements
    DROP CONSTRAINT IF EXISTS alert_whatsapp_consent_statements_business_name_chk,
    DROP CONSTRAINT IF EXISTS alert_whatsapp_consent_statements_legal_chk,
    DROP COLUMN IF EXISTS legal_review_status,
    DROP COLUMN IF EXISTS legal_reviewed_by_name,
    DROP COLUMN IF EXISTS legal_reviewed_at;
COMMENT ON TABLE analytics.alert_whatsapp_consent_statements IS
'WhatsApp Phase 1 (R6, D21): versioned register of the Product-approved opt-in confirmation wording. Rows are added only by migration after Product approval; at most one current (retired_at IS NULL) version. Empty until the wording and the named business (R9) are approved: new opt-ins are refused (whatsapp_consent_statement_missing). Product approval is not Legal sign-off (L-1).';
DELETE FROM admin.schema_migrations WHERE migration_id = '332_alert_whatsapp_consent_wording';

COMMIT;
