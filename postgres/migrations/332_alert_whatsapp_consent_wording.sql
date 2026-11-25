-- ============================================================================
-- Migration 332
-- Alerts -> WhatsApp notifications, Phase 1: load the Product-approved opt-in
-- confirmation wording (D21) and name the customer business in it (R9).
--
-- NOTHING IS SENT. Like migration 331 this is configuration only: there is no
-- outbox, worker, provider, template or receipt endpoint.
--
-- DECISIONS (Product Owner, 2026-11-24; docs/07-features/alerts/
-- whatsapp-notifications/README.md §2 and consent-wording-register.md)
--   R9   The customer business is the alert originator; WiseWatts is the
--        technology and delivery platform. The wording names the customer by
--        its legal name (metadata.organizations.legal_name).
--   D21  The administrator confirmation wording below is approved, subject to
--        Legal review (L-1). Explicit individual recipient consent stays
--        mandatory (one confirmation per new or changed number). Operational
--        notifications only; no marketing messages.
--   Opt-ins stay CLOSED until Legal approves the wording (Product Owner,
--        2026-11-24): the wording is loaded with legal_review_status
--        'PENDING', and new opt-ins are refused while it is.
--
-- WHAT IT DOES
--   1. Loads wording version WA-OPTIN-1 into the register
--      analytics.alert_whatsapp_consent_statements, marked Legal review
--      PENDING (new columns legal_review_status / legal_reviewed_by_name /
--      legal_reviewed_at). Its text holds the placeholder {business_name};
--      every wording version must (CHECK). Marking it APPROVED is a separate,
--      separately approved migration recording Legal's sign-off.
--   2. Records with each consent the exact business name that was shown
--      (alert_rule_whatsapp_recipients.consent_business_name), so the
--      evidence is the full text the administrator confirmed: wording
--      version + business name.
--   3. Re-creates get_portal_alert_rule_whatsapp (same signature): the
--      consent_statement it returns is the wording rendered with the rule's
--      business name, {version, text, business_name, unavailable_reason}.
--      With no legal name set, text and business_name are NULL and
--      unavailable_reason is 'business_name_missing'; while Legal review is
--      pending they are NULL and unavailable_reason is 'legal_review_pending'.
--   4. Replaces save_portal_alert_rule_whatsapp with a version that takes the
--      business name the administrator was shown (new last argument,
--      DEFAULT NULL, so a caller still passing six arguments resolves to it).
--      New consent is refused unless a current wording exists
--      (whatsapp_consent_statement_missing), Legal has approved it
--      (whatsapp_consent_legal_review_pending), the organisation has a legal
--      name (whatsapp_business_name_missing), and both the version and the
--      business name equal what was shown (whatsapp_consent_statement_changed).
--      Everything else is unchanged from migration 331.
--
-- Unchanged guarantees (migration 331): refused and no-op saves write no
-- audit row; no phone number is ever audited; the WhatsApp functions never
-- write alert rules, occurrences or timers.
--
-- Staging/test only (postgres/migration_environment_scope.csv), like 331.
-- Re-runnable: every statement is idempotent.
--
-- Rollback: postgres/maintenance/332_alert_whatsapp_consent_wording_rollback.sql
-- (DESTRUCTIVE: deletes every recipient recorded under this wording, then
-- restores the migration 331 functions). Run it before any 331 rollback.
-- ============================================================================

DO $pre$
BEGIN
    IF to_regclass('analytics.alert_whatsapp_consent_statements') IS NULL
       OR to_regclass('analytics.alert_rule_whatsapp_recipients') IS NULL
       OR NOT EXISTS (SELECT 1 FROM admin.schema_migrations WHERE migration_id = '331_alert_whatsapp_configuration') THEN
        RAISE EXCEPTION 'Migration 332 precondition failed: migration 331 (WhatsApp configuration) is not applied.';
    END IF;
    IF NOT EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema = 'metadata' AND table_name = 'organizations' AND column_name = 'legal_name'
    ) THEN
        RAISE EXCEPTION 'Migration 332 precondition failed: metadata.organizations.legal_name is missing.';
    END IF;
    -- A consent recorded before this migration would have no business name.
    -- None can exist (331 shipped an empty register, so every new opt-in was
    -- refused); refuse rather than invent one.
    IF NOT EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema = 'analytics' AND table_name = 'alert_rule_whatsapp_recipients'
          AND column_name = 'consent_business_name'
    ) AND EXISTS (SELECT 1 FROM analytics.alert_rule_whatsapp_recipients) THEN
        RAISE EXCEPTION 'Migration 332 precondition failed: % WhatsApp recipient(s) exist without a recorded business name.',
            (SELECT count(*) FROM analytics.alert_rule_whatsapp_recipients);
    END IF;
    -- Only WA-OPTIN-1 may be (or become) the current version here.
    IF EXISTS (
        SELECT 1 FROM analytics.alert_whatsapp_consent_statements
        WHERE retired_at IS NULL AND version <> 'WA-OPTIN-1'
    ) THEN
        RAISE EXCEPTION 'Migration 332 precondition failed: another current opt-in wording version exists.';
    END IF;
END;
$pre$;


-- ----------------------------------------------------------------------------
-- 1. Schema: every wording names the business; every consent records it.
-- ----------------------------------------------------------------------------

DO $schema$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema = 'analytics' AND table_name = 'alert_whatsapp_consent_statements'
          AND column_name = 'legal_review_status'
    ) THEN
        ALTER TABLE analytics.alert_whatsapp_consent_statements
            ADD COLUMN legal_review_status    TEXT        NOT NULL DEFAULT 'PENDING',
            ADD COLUMN legal_reviewed_by_name TEXT,
            ADD COLUMN legal_reviewed_at      TIMESTAMPTZ;
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conrelid = 'analytics.alert_whatsapp_consent_statements'::regclass
          AND conname = 'alert_whatsapp_consent_statements_legal_chk'
    ) THEN
        ALTER TABLE analytics.alert_whatsapp_consent_statements
            ADD CONSTRAINT alert_whatsapp_consent_statements_legal_chk CHECK (
                (legal_review_status = 'PENDING' AND legal_reviewed_by_name IS NULL AND legal_reviewed_at IS NULL)
                OR (legal_review_status = 'APPROVED' AND legal_reviewed_by_name IS NOT NULL
                    AND btrim(legal_reviewed_by_name) <> '' AND legal_reviewed_at IS NOT NULL)
            );
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conrelid = 'analytics.alert_whatsapp_consent_statements'::regclass
          AND conname = 'alert_whatsapp_consent_statements_business_name_chk'
    ) THEN
        ALTER TABLE analytics.alert_whatsapp_consent_statements
            ADD CONSTRAINT alert_whatsapp_consent_statements_business_name_chk
            CHECK (strpos(statement_text, '{business_name}') > 0);
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema = 'analytics' AND table_name = 'alert_rule_whatsapp_recipients'
          AND column_name = 'consent_business_name'
    ) THEN
        -- The table is empty (precondition), so NOT NULL needs no default.
        ALTER TABLE analytics.alert_rule_whatsapp_recipients
            ADD COLUMN consent_business_name TEXT NOT NULL;
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conrelid = 'analytics.alert_rule_whatsapp_recipients'::regclass
          AND conname = 'alert_rule_whatsapp_recipients_business_name_chk'
    ) THEN
        ALTER TABLE analytics.alert_rule_whatsapp_recipients
            ADD CONSTRAINT alert_rule_whatsapp_recipients_business_name_chk
            CHECK (consent_business_name = btrim(consent_business_name) AND consent_business_name <> '');
    END IF;
END;
$schema$;

COMMENT ON TABLE analytics.alert_whatsapp_consent_statements IS
'WhatsApp Phase 1 (R6, D21): versioned register of the Product-approved opt-in confirmation wording. Rows are added only by migration after Product approval; at most one current (retired_at IS NULL) version; approved text is never edited (a change is a new version). Every version names the business through the placeholder {business_name} (R9: the customer business, organizations.legal_name). WA-OPTIN-1 loaded by migration 332 (Product Owner, 2026-11-24). Product approval is not Legal sign-off (L-1): new opt-ins are refused while legal_review_status is PENDING.';
COMMENT ON COLUMN analytics.alert_whatsapp_consent_statements.legal_review_status IS
'WhatsApp Phase 1 (L-1, migration 332): PENDING until Legal approves this wording version; new opt-ins are refused (whatsapp_consent_legal_review_pending) while PENDING. Set to APPROVED, with reviewer and date, only by a separately approved migration.';
COMMENT ON COLUMN analytics.alert_rule_whatsapp_recipients.consent_business_name IS
'WhatsApp Phase 1 (R9, migration 332): the business name shown in the confirmed wording at consent time (the customer organisation''s legal name). Together with consent_statement_version it is the exact text the administrator confirmed.';


-- ----------------------------------------------------------------------------
-- 2. The approved wording (D21, R9).
-- ----------------------------------------------------------------------------

-- Legal review PENDING (column default): opt-ins stay closed until Legal approves.
INSERT INTO analytics.alert_whatsapp_consent_statements (version, statement_text, approved_by_name, approved_at)
SELECT 'WA-OPTIN-1',
       'I confirm that this person has explicitly agreed to receive operational alert notifications from '
       || '{business_name} on WhatsApp at this number. These messages are delivered by WiseWatts as '
       || '{business_name}''s technology platform. No marketing messages will be sent.',
       'WiseWatts Product Owner',
       TIMESTAMPTZ '2026-11-24 00:00:00+05:30'
WHERE NOT EXISTS (SELECT 1 FROM analytics.alert_whatsapp_consent_statements WHERE version = 'WA-OPTIN-1');


-- ----------------------------------------------------------------------------
-- 3. Internal helpers (no EXECUTE for application roles).
-- ----------------------------------------------------------------------------

-- R9: the name of the business an organisation's alerts come from, or NULL
-- when no legal name is recorded (new opt-ins are then refused).
CREATE OR REPLACE FUNCTION analytics.alert_whatsapp_business_name(p_organization_id UUID)
RETURNS TEXT
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path TO pg_catalog, metadata
AS $function$
    SELECT nullif(btrim(o.legal_name), '') FROM metadata.organizations AS o WHERE o.id = p_organization_id;
$function$;

-- The recipients of a rule as audit JSON: ids and consent metadata, never a
-- phone number (R12). Since 332 it includes the business name shown.
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
               'consent_statement_version', r.consent_statement_version,
               'consent_business_name', r.consent_business_name
           ) ORDER BY r.recipient_id), '[]'::jsonb)
    FROM analytics.alert_rule_whatsapp_recipients AS r
    WHERE r.rule_id = p_rule_id;
$function$;


-- ----------------------------------------------------------------------------
-- 4. Read: the wording is returned rendered with the rule's business name.
-- ----------------------------------------------------------------------------

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
    v_rule     analytics.alert_rules;
    v_set      analytics.alert_rule_whatsapp_settings;
    v_business TEXT;
    v_reason   TEXT;
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

    v_business := analytics.alert_whatsapp_business_name(v_rule.organization_id);
    -- Why the wording cannot be confirmed (NULL when it can).
    SELECT CASE WHEN s.legal_review_status <> 'APPROVED' THEN 'legal_review_pending'
                WHEN v_business IS NULL THEN 'business_name_missing' END
    INTO v_reason
    FROM analytics.alert_whatsapp_consent_statements AS s
    WHERE s.version = analytics.alert_whatsapp_current_statement_version();
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
                          'consent_statement_version', r.consent_statement_version,
                          'consent_business_name', r.consent_business_name
                      ) ORDER BY r.created_at, r.recipient_id)
               FROM analytics.alert_rule_whatsapp_recipients AS r
               LEFT JOIN admin.portal_users AS pu ON pu.portal_user_id = r.consent_confirmed_by
               WHERE r.rule_id = v_rule.rule_id
           ), '[]'::jsonb),
           -- The approved wording the UI must show for a new opt-in (R6, D21),
           -- rendered with this rule's business (R9); NULL while none is
           -- approved. While Legal review is pending, or without a legal name,
           -- it cannot be confirmed: text is NULL and the reason is returned.
           (SELECT jsonb_build_object(
                       'version', s.version,
                       'text', CASE WHEN v_reason IS NOT NULL THEN NULL
                                    ELSE replace(s.statement_text, '{business_name}', v_business) END,
                       'business_name', CASE WHEN v_reason IS NULL THEN v_business END,
                       'unavailable_reason', v_reason)
            FROM analytics.alert_whatsapp_consent_statements AS s
            WHERE s.version = analytics.alert_whatsapp_current_statement_version());
END;
$function$;


-- ----------------------------------------------------------------------------
-- 5. Save: as migration 331, plus the business name binding (R9).
--
-- p_consent_business_name: the business name in the wording the
-- administrator was shown (consent_statement.business_name from the read).
-- New consent is recorded only when it equals the organisation's legal name
-- now, so the recorded name is always the one that was confirmed.
-- ----------------------------------------------------------------------------

DROP FUNCTION IF EXISTS analytics.save_portal_alert_rule_whatsapp(bigint, uuid, boolean, jsonb, integer, text);

CREATE OR REPLACE FUNCTION analytics.save_portal_alert_rule_whatsapp(
    p_portal_user_id    BIGINT,
    p_rule_id           UUID,
    p_enabled           BOOLEAN,
    p_recipients        JSONB,
    p_expected_revision INTEGER,
    p_consent_statement_version TEXT,
    p_consent_business_name     TEXT DEFAULT NULL
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
    v_business  TEXT;
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
            -- No Product-approved wording (D21): new opt-ins are refused.
            RETURN QUERY SELECT 'whatsapp_consent_statement_missing'::TEXT, v_current; RETURN;
        END IF;
        IF NOT EXISTS (
            SELECT 1 FROM analytics.alert_whatsapp_consent_statements AS s
            WHERE s.version = v_statement AND s.legal_review_status = 'APPROVED'
        ) THEN
            -- L-1: Product-approved but not yet Legal-approved: opt-ins stay closed.
            RETURN QUERY SELECT 'whatsapp_consent_legal_review_pending'::TEXT, v_current; RETURN;
        END IF;
        v_business := analytics.alert_whatsapp_business_name(v_rule.organization_id);
        IF v_business IS NULL THEN
            -- R9: the wording must name the customer business; without a legal
            -- name it cannot be shown, so it cannot be confirmed.
            RETURN QUERY SELECT 'whatsapp_business_name_missing'::TEXT, v_current; RETURN;
        END IF;
        IF p_consent_statement_version IS DISTINCT FROM v_statement
           OR p_consent_business_name IS DISTINCT FROM v_business THEN
            -- The administrator confirmed a different (or no) text.
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
             consent_statement_version, consent_business_name, created_at, created_by)
        -- created_at per row keeps the entered order; consent time is the save instant.
        VALUES (v_rule.rule_id, v_phone, 'CONFIRMED', v_now, p_portal_user_id, v_statement, v_business,
                clock_timestamp(), p_portal_user_id)
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


-- ----------------------------------------------------------------------------
-- 6. Ownership and grants.
-- ----------------------------------------------------------------------------

DO $grants$
DECLARE
    v_sig TEXT;
    v_customer_api BOOLEAN := EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'ems_customer_api');
BEGIN
    FOREACH v_sig IN ARRAY ARRAY[
        'analytics.alert_whatsapp_business_name(uuid)',
        'analytics.alert_whatsapp_audit_recipients(uuid)'
    ] LOOP
        EXECUTE format('ALTER FUNCTION %s OWNER TO ems_admin', v_sig);
        EXECUTE format('REVOKE ALL ON FUNCTION %s FROM PUBLIC', v_sig);
    END LOOP;

    FOREACH v_sig IN ARRAY ARRAY[
        'analytics.get_portal_alert_rule_whatsapp(bigint, uuid)',
        'analytics.save_portal_alert_rule_whatsapp(bigint, uuid, boolean, jsonb, integer, text, text)'
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
'WhatsApp Phase 1: one rule''s WhatsApp configuration with full numbers, and the current approved opt-in wording rendered with the rule''s business (R9): {version, text, business_name, unavailable_reason} (NULL while no wording is approved; text and business_name NULL with unavailable_reason legal_review_pending while Legal review is pending, or business_name_missing without a legal name). Result ok | forbidden (designated report automation account of any site, R5; or missing alert.configure, D16) | not_found (unknown, deleted or inaccessible rule). Revision 0 = never configured.';
COMMENT ON FUNCTION analytics.save_portal_alert_rule_whatsapp(BIGINT, UUID, BOOLEAN, JSONB, INTEGER, TEXT, TEXT) IS
'WhatsApp Phase 1: replace-all save of one rule''s WhatsApp settings and recipients (alert.configure; R5 refused). Revision-checked (whatsapp_config_stale). New consent needs the current wording version AND the business name the administrator was shown (migration 332, R9). Refusals: whatsapp_invalid_request | whatsapp_invalid_phone | whatsapp_duplicate_phone | whatsapp_too_many_recipients | whatsapp_unknown_recipient | whatsapp_consent_required | whatsapp_consent_statement_missing | whatsapp_consent_legal_review_pending | whatsapp_business_name_missing | whatsapp_consent_statement_changed | whatsapp_recipients_required | not_found | forbidden. One audit row (ALERT_RULE_WHATSAPP_UPDATED) per effective save, without phone numbers; refusals and no-ops write nothing. Never touches the rule, its occurrences or timers. Sends nothing.';


-- ----------------------------------------------------------------------------
-- 7. Postconditions.
-- ----------------------------------------------------------------------------

DO $post$
DECLARE
    v_sig  TEXT;
    v_role TEXT;
BEGIN
    IF to_regprocedure('analytics.save_portal_alert_rule_whatsapp(bigint, uuid, boolean, jsonb, integer, text)') IS NOT NULL THEN
        RAISE EXCEPTION 'Migration 332 postcondition failed: the six-argument save function still exists.';
    END IF;
    IF analytics.alert_whatsapp_current_statement_version() IS DISTINCT FROM 'WA-OPTIN-1' THEN
        RAISE EXCEPTION 'Migration 332 postcondition failed: WA-OPTIN-1 is not the current opt-in wording.';
    END IF;
    IF NOT EXISTS (
        SELECT 1 FROM analytics.alert_whatsapp_consent_statements
        WHERE version = 'WA-OPTIN-1' AND legal_review_status IN ('PENDING', 'APPROVED')
    ) THEN
        RAISE EXCEPTION 'Migration 332 postcondition failed: WA-OPTIN-1 has no Legal review status.';
    END IF;
    IF EXISTS (
        SELECT 1 FROM analytics.alert_whatsapp_consent_statements
        WHERE version = 'WA-OPTIN-1' AND strpos(statement_text, '{business_name}') = 0
    ) THEN
        RAISE EXCEPTION 'Migration 332 postcondition failed: WA-OPTIN-1 does not name the business.';
    END IF;
    IF NOT EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema = 'analytics' AND table_name = 'alert_rule_whatsapp_recipients'
          AND column_name = 'consent_business_name' AND is_nullable = 'NO'
    ) THEN
        RAISE EXCEPTION 'Migration 332 postcondition failed: consent_business_name is missing or nullable.';
    END IF;

    FOREACH v_sig IN ARRAY ARRAY[
        'analytics.get_portal_alert_rule_whatsapp(bigint, uuid)',
        'analytics.save_portal_alert_rule_whatsapp(bigint, uuid, boolean, jsonb, integer, text, text)',
        'analytics.alert_whatsapp_business_name(uuid)',
        'analytics.alert_whatsapp_audit_recipients(uuid)'
    ] LOOP
        IF NOT EXISTS (
            SELECT 1 FROM pg_proc AS p JOIN pg_roles AS r ON r.oid = p.proowner
            WHERE p.oid = v_sig::regprocedure AND p.prosecdef AND r.rolname = 'ems_admin' AND p.proconfig IS NOT NULL
        ) THEN
            RAISE EXCEPTION 'Migration 332 postcondition failed: % is not SECURITY DEFINER / ems_admin / pinned search_path.', v_sig;
        END IF;
        IF has_function_privilege('public', v_sig, 'EXECUTE') THEN
            RAISE EXCEPTION 'Migration 332 postcondition failed: PUBLIC can execute %.', v_sig;
        END IF;
    END LOOP;

    FOREACH v_sig IN ARRAY ARRAY[
        'analytics.alert_whatsapp_business_name(uuid)',
        'analytics.alert_whatsapp_audit_recipients(uuid)'
    ] LOOP
        FOREACH v_role IN ARRAY ARRAY['ems_app', 'ems_customer_api', 'grafana_reader'] LOOP
            IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = v_role) AND has_function_privilege(v_role, v_sig, 'EXECUTE') THEN
                RAISE EXCEPTION 'Migration 332 postcondition failed: % can execute internal function %.', v_role, v_sig;
            END IF;
        END LOOP;
    END LOOP;

    FOREACH v_role IN ARRAY ARRAY['ems_app', 'ems_customer_api'] LOOP
        IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = v_role)
           AND NOT has_function_privilege(v_role, 'analytics.save_portal_alert_rule_whatsapp(bigint, uuid, boolean, jsonb, integer, text, text)', 'EXECUTE') THEN
            RAISE EXCEPTION 'Migration 332 postcondition failed: % cannot execute the save function.', v_role;
        END IF;
    END LOOP;
END;
$post$;
