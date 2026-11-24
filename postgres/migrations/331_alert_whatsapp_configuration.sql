-- ============================================================================
-- Migration 331
-- Alerts -> WhatsApp notifications, Phase 1: per-rule WhatsApp CONFIGURATION
-- only (ADR-024 Amendment 2, decided 2026-11-23; ADR-026 Proposed; plan
-- docs/07-features/alerts/whatsapp-notifications/phase-1-plan.md).
--
-- NOTHING IS SENT. There is no outbox, delivery record, worker, provider,
-- template or receipt endpoint, and nothing here is read by the evaluator.
--
-- WHAT IT DOES
--   1. Retires the legacy "Coming Soon" flag alert_rules.whatsapp_requested
--      (ADR-024 Amendment 2 §2A, D5, D20): refuses to run if any rule has it
--      set, then adds CHECK (NOT whatsapp_requested). The column is kept for
--      rollback compatibility and older clients.
--   2. A separate configuration store keyed by the stable rule_id (§2B, D6):
--        analytics.alert_rule_whatsapp_settings     on/off + revision
--        analytics.alert_rule_whatsapp_recipients   1-10 E.164 numbers, each
--                                                   with its opt-in consent
--        analytics.alert_whatsapp_consent_statements versioned register of the
--                                                   Product-approved opt-in
--                                                   wording (R6). Shipped
--                                                   EMPTY: no wording is
--                                                   approved (D21, R9), so
--                                                   every NEW opt-in is
--                                                   refused until a version
--                                                   is loaded by a later,
--                                                   separately approved
--                                                   migration.
--   3. SECURITY DEFINER functions (get / save / summaries). Each refuses a
--      designated report automation account of ANY site first (R5), then
--      re-checks site access and alert.configure (§2D, D16). Saves are
--      revision-checked and write ONE admin.audit_events row per effective
--      change, holding recipient ids and consent metadata but NO phone number,
--      full or masked (R12 default, pending Legal L-2). Refused and no-op
--      saves write nothing (P1-AC-6).
--   4. Re-creates the migration 323 create / update / delete rule functions
--      with identical signatures: create and update store whatsapp_requested
--      = FALSE whatever is passed and update no longer compares it, so a
--      client that sends or omits the old flag cannot end an Active
--      occurrence (§2C, D6). delete also removes the rule's WhatsApp
--      configuration in the same audited transaction (A-5).
--
-- LIFECYCLE GUARANTEE
--   The WhatsApp functions never INSERT, UPDATE or DELETE analytics.alert_rules,
--   analytics.alerts or analytics.alert_evaluation_candidates. They read the
--   rule FOR KEY SHARE only, which never blocks the evaluator (FOR SHARE ...
--   SKIP LOCKED) and only serialises with a concurrent rule edit / delete.
--
-- Staging/test only (postgres/migration_environment_scope.csv): production
-- waits for ADR-024 in production (D11) and ADR-026 Decided (D13). The R5
-- check also needs analytics.site_report_profiles (migration 328, staging/test).
--
-- Re-runnable: every statement is idempotent.
--
-- Rollback: postgres/maintenance/331_alert_whatsapp_configuration_rollback.sql
-- (DESTRUCTIVE: deletes every stored number; restores the 323 functions).
-- ============================================================================

DO $pre$
BEGIN
    IF to_regclass('analytics.alert_rules') IS NULL
       OR to_regclass('analytics.site_report_profiles') IS NULL
       OR to_regclass('admin.audit_events') IS NULL THEN
        RAISE EXCEPTION 'Migration 331 precondition failed: analytics.alert_rules, analytics.site_report_profiles or admin.audit_events is missing.';
    END IF;
    IF to_regprocedure('analytics.update_portal_alert_rule(bigint, uuid, integer, text, uuid, text, text, text, numeric, numeric, time, time, smallint, smallint, boolean, boolean)') IS NULL
       OR to_regprocedure('admin.portal_user_can_access_site(bigint, uuid)') IS NULL
       OR to_regprocedure('admin.portal_user_has_permission(bigint, text)') IS NULL THEN
        RAISE EXCEPTION 'Migration 331 precondition failed: a migration 323 rule function or an admin permission helper is missing.';
    END IF;
    -- The safeguard (ADR-024 Amendment 2 §2A): retiring the flag must never
    -- silently drop a stored preference.
    IF EXISTS (SELECT 1 FROM analytics.alert_rules WHERE whatsapp_requested) THEN
        RAISE EXCEPTION 'Migration 331 precondition failed: % alert rule(s) have whatsapp_requested = true; the legacy flag cannot be retired.',
            (SELECT count(*) FROM analytics.alert_rules WHERE whatsapp_requested);
    END IF;
END;
$pre$;


-- ----------------------------------------------------------------------------
-- 1. Retire the legacy flag.
-- ----------------------------------------------------------------------------

DO $chk$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conrelid = 'analytics.alert_rules'::regclass AND conname = 'alert_rules_whatsapp_retired_chk'
    ) THEN
        ALTER TABLE analytics.alert_rules
            ADD CONSTRAINT alert_rules_whatsapp_retired_chk CHECK (NOT whatsapp_requested);
    END IF;
END;
$chk$;

COMMENT ON COLUMN analytics.alert_rules.whatsapp_requested IS
'RETIRED (migration 331, ADR-024 Amendment 2 §2A): always FALSE (CHECK alert_rules_whatsapp_retired_chk); kept for rollback compatibility. WhatsApp configuration lives in analytics.alert_rule_whatsapp_settings / _recipients.';


-- ----------------------------------------------------------------------------
-- 2. Tables.
-- ----------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS analytics.alert_whatsapp_consent_statements
(
    version          TEXT        PRIMARY KEY,
    statement_text   TEXT        NOT NULL,
    approved_by_name TEXT        NOT NULL,
    approved_at      TIMESTAMPTZ NOT NULL,
    retired_at       TIMESTAMPTZ,
    created_at       TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),

    CONSTRAINT alert_whatsapp_consent_statements_version_chk
        CHECK (version = btrim(version) AND char_length(version) BETWEEN 1 AND 40),
    CONSTRAINT alert_whatsapp_consent_statements_text_chk CHECK (btrim(statement_text) <> ''),
    CONSTRAINT alert_whatsapp_consent_statements_approver_chk CHECK (btrim(approved_by_name) <> ''),
    CONSTRAINT alert_whatsapp_consent_statements_retired_chk CHECK (retired_at IS NULL OR retired_at >= approved_at)
);
-- At most one current (not retired) version.
CREATE UNIQUE INDEX IF NOT EXISTS alert_whatsapp_consent_statements_current_uq
    ON analytics.alert_whatsapp_consent_statements ((TRUE)) WHERE retired_at IS NULL;

CREATE TABLE IF NOT EXISTS analytics.alert_rule_whatsapp_settings
(
    rule_id         UUID        PRIMARY KEY REFERENCES analytics.alert_rules (rule_id),
    organization_id UUID        NOT NULL,
    site_id         UUID        NOT NULL,
    enabled         BOOLEAN     NOT NULL DEFAULT FALSE,
    revision        INTEGER     NOT NULL DEFAULT 1,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    created_by      BIGINT      NOT NULL REFERENCES admin.portal_users (portal_user_id),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    updated_by      BIGINT      NOT NULL REFERENCES admin.portal_users (portal_user_id),

    CONSTRAINT alert_rule_whatsapp_settings_revision_chk CHECK (revision >= 1)
);
CREATE INDEX IF NOT EXISTS alert_rule_whatsapp_settings_site_idx
    ON analytics.alert_rule_whatsapp_settings (site_id);

CREATE TABLE IF NOT EXISTS analytics.alert_rule_whatsapp_recipients
(
    recipient_id              UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    rule_id                   UUID        NOT NULL
                                          REFERENCES analytics.alert_rule_whatsapp_settings (rule_id) ON DELETE CASCADE,
    phone_e164                TEXT        NOT NULL,
    consent_state             TEXT        NOT NULL DEFAULT 'CONFIRMED',
    consent_confirmed_at      TIMESTAMPTZ NOT NULL,
    consent_confirmed_by      BIGINT      NOT NULL REFERENCES admin.portal_users (portal_user_id),
    consent_statement_version TEXT        NOT NULL
                                          REFERENCES analytics.alert_whatsapp_consent_statements (version),
    opted_out_at              TIMESTAMPTZ,
    opted_out_source          TEXT,
    created_at                TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    created_by                BIGINT      NOT NULL REFERENCES admin.portal_users (portal_user_id),

    CONSTRAINT alert_rule_whatsapp_recipients_phone_chk CHECK (phone_e164 ~ '^\+[1-9][0-9]{7,14}$'),
    CONSTRAINT alert_rule_whatsapp_recipients_consent_chk CHECK (consent_state IN ('CONFIRMED', 'OPTED_OUT')),
    -- Phase 1 never records an opt-out (STOP handling is Phase 2, D4).
    CONSTRAINT alert_rule_whatsapp_recipients_opt_out_chk CHECK (
        (consent_state = 'CONFIRMED' AND opted_out_at IS NULL AND opted_out_source IS NULL)
        OR (consent_state = 'OPTED_OUT' AND opted_out_at IS NOT NULL AND opted_out_source IS NOT NULL)
    ),
    CONSTRAINT alert_rule_whatsapp_recipients_phone_uq UNIQUE (rule_id, phone_e164)
);

-- The settings row's organization / site always equal its rule's.
CREATE OR REPLACE FUNCTION analytics.alert_rule_whatsapp_settings_scope_guard()
RETURNS trigger
LANGUAGE plpgsql
SET search_path TO pg_catalog, analytics
AS $function$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM analytics.alert_rules AS r
        WHERE r.rule_id = NEW.rule_id AND r.organization_id = NEW.organization_id AND r.site_id = NEW.site_id
    ) THEN
        RAISE EXCEPTION 'alert_rule_whatsapp_settings: organization_id / site_id must equal the rule''s'
            USING ERRCODE = '23514';
    END IF;
    RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS alert_rule_whatsapp_settings_scope_guard ON analytics.alert_rule_whatsapp_settings;
CREATE TRIGGER alert_rule_whatsapp_settings_scope_guard
    BEFORE INSERT OR UPDATE OF rule_id, organization_id, site_id ON analytics.alert_rule_whatsapp_settings
    FOR EACH ROW EXECUTE FUNCTION analytics.alert_rule_whatsapp_settings_scope_guard();

-- Ownership and table privileges: no role reads these tables directly. Phone
-- numbers are personal data; only the functions below reach them.
DO $tables$
DECLARE
    v_table TEXT;
    v_role  RECORD;
BEGIN
    FOREACH v_table IN ARRAY ARRAY[
        'analytics.alert_whatsapp_consent_statements',
        'analytics.alert_rule_whatsapp_settings',
        'analytics.alert_rule_whatsapp_recipients'
    ] LOOP
        EXECUTE format('ALTER TABLE %s OWNER TO ems_admin', v_table);
        EXECUTE format('REVOKE ALL ON %s FROM PUBLIC', v_table);
        -- Including any role that received access through default privileges
        -- on the analytics schema (diagnostic read-only roles).
        FOR v_role IN
            SELECT DISTINCT r.rolname
            FROM pg_class AS c
            CROSS JOIN LATERAL aclexplode(c.relacl) AS a
            JOIN pg_roles AS r ON r.oid = a.grantee
            WHERE c.oid = v_table::regclass AND c.relacl IS NOT NULL AND r.rolname <> 'ems_admin'
        LOOP
            EXECUTE format('REVOKE ALL ON %s FROM %I', v_table, v_role.rolname);
        END LOOP;
    END LOOP;
END;
$tables$;

ALTER FUNCTION analytics.alert_rule_whatsapp_settings_scope_guard() OWNER TO ems_admin;
REVOKE ALL ON FUNCTION analytics.alert_rule_whatsapp_settings_scope_guard() FROM PUBLIC;

COMMENT ON TABLE analytics.alert_whatsapp_consent_statements IS
'WhatsApp Phase 1 (R6, D21): versioned register of the Product-approved opt-in confirmation wording. Rows are added only by migration after Product approval; at most one current (retired_at IS NULL) version. Empty until the wording and the named business (R9) are approved: new opt-ins are refused (whatsapp_consent_statement_missing). Product approval is not Legal sign-off (L-1).';
COMMENT ON TABLE analytics.alert_rule_whatsapp_settings IS
'WhatsApp Phase 1 (ADR-024 Amendment 2 §2B): per-rule WhatsApp on/off, keyed by the stable rule_id; revision for optimistic concurrency. No row = off, revision 0. Never read by the evaluator; nothing is sent. Written only by analytics.save_portal_alert_rule_whatsapp and delete_portal_alert_rule.';
COMMENT ON TABLE analytics.alert_rule_whatsapp_recipients IS
'WhatsApp Phase 1: 1-10 E.164 recipient numbers per rule (D15), each with the administrator''s opt-in confirmation (who, when, wording version; D4). Personal data: no direct table access for any role; never written to the audit log (R12). Removing a recipient deletes its row (A-3).';


-- ----------------------------------------------------------------------------
-- 3. Internal helpers (no EXECUTE for application roles).
-- ----------------------------------------------------------------------------

-- R5: a designated report automation account of ANY site (migration 328/330).
CREATE OR REPLACE FUNCTION analytics.alert_whatsapp_actor_is_automation(p_portal_user_id BIGINT)
RETURNS BOOLEAN
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path TO pg_catalog, analytics
AS $function$
    SELECT EXISTS (
        SELECT 1 FROM analytics.site_report_profiles AS p
        WHERE p.automation_portal_user_id = p_portal_user_id
    );
$function$;

-- The current approved wording version, or NULL when none is approved.
CREATE OR REPLACE FUNCTION analytics.alert_whatsapp_current_statement_version()
RETURNS TEXT
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path TO pg_catalog, analytics
AS $function$
    SELECT s.version FROM analytics.alert_whatsapp_consent_statements AS s
    WHERE s.retired_at IS NULL AND s.approved_at <= clock_timestamp()
    ORDER BY s.approved_at DESC
    LIMIT 1;
$function$;

-- The recipients of a rule as audit JSON: ids and consent metadata, never a
-- phone number (R12).
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


-- ----------------------------------------------------------------------------
-- 4. Read: one rule's configuration, with full numbers, for configurers only.
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


-- ----------------------------------------------------------------------------
-- 5. Read: per-rule summary for a site (no numbers), for configurers only.
-- ----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION analytics.get_portal_alert_rule_whatsapp_summaries(
    p_portal_user_id BIGINT,
    p_site_id        UUID
)
RETURNS TABLE (result TEXT, rule_id UUID, enabled BOOLEAN, recipient_count INTEGER)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO pg_catalog, analytics, admin
AS $function$
#variable_conflict use_column
BEGIN
    IF analytics.alert_whatsapp_actor_is_automation(p_portal_user_id) THEN
        RETURN QUERY SELECT 'forbidden'::TEXT, NULL::UUID, NULL::BOOLEAN, NULL::INTEGER; RETURN;
    END IF;
    IF NOT admin.portal_user_can_access_site(p_portal_user_id, p_site_id) THEN
        RETURN QUERY SELECT 'not_found'::TEXT, NULL::UUID, NULL::BOOLEAN, NULL::INTEGER; RETURN;
    END IF;
    IF NOT admin.portal_user_has_permission(p_portal_user_id, 'alert.configure') THEN
        RETURN QUERY SELECT 'forbidden'::TEXT, NULL::UUID, NULL::BOOLEAN, NULL::INTEGER; RETURN;
    END IF;
    -- One 'ok' row per live rule of the site (zero rows when it has none).
    RETURN QUERY
    SELECT 'ok'::TEXT, r.rule_id, COALESCE(s.enabled, FALSE),
           (SELECT count(*)::INTEGER FROM analytics.alert_rule_whatsapp_recipients AS x WHERE x.rule_id = r.rule_id)
    FROM analytics.alert_rules AS r
    LEFT JOIN analytics.alert_rule_whatsapp_settings AS s ON s.rule_id = r.rule_id
    WHERE r.site_id = p_site_id AND r.deleted_at IS NULL
    ORDER BY r.rule_id;
END;
$function$;


-- ----------------------------------------------------------------------------
-- 6. Save: replace-all, revision-checked, audited; never touches the rule.
--
-- p_recipients: JSON array of {"recipient_id": uuid|null, "phone": "+E164",
-- "opt_in_confirmed": bool}. A recipient that repeats its recipient_id AND its
-- number keeps its consent; a new or changed number is a new recipient and
-- needs opt_in_confirmed = true and a current approved wording version
-- (A-2, D4, D21). A recipient_id must belong to THIS rule (review B2).
-- p_consent_statement_version: the wording version the administrator was
-- shown. New consent is recorded only under that version, and only while it
-- is still the current one (otherwise whatsapp_consent_statement_changed), so
-- the recorded version is always the text that was actually confirmed.
-- ----------------------------------------------------------------------------

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


-- ----------------------------------------------------------------------------
-- 7. Re-created migration 323 rule functions (same signatures).
--    create / update: whatsapp_requested is always stored FALSE and is no
--    longer part of the change comparison. delete: also removes the rule's
--    WhatsApp configuration (audited with recipient ids only).
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

    -- Migration 331: the retired WhatsApp flag is always stored FALSE
    -- (p_whatsapp_requested is accepted for older clients and ignored).
    INSERT INTO analytics.alert_rules (
        organization_id, site_id, asset_id, name, parameter_code, qualifier, comparator, threshold, tolerance,
        unit_symbol, schedule_start, schedule_end, weekdays, reminder_minutes, email_requested,
        whatsapp_requested, enabled, created_by, updated_by
    )
    VALUES (
        v_org, p_site_id, p_asset_id, btrim(p_name), p_parameter_code, p_qualifier, p_comparator, p_threshold,
        p_tolerance, v_valid.unit_symbol, p_schedule_start, p_schedule_end, p_weekdays, p_reminder_minutes,
        COALESCE(p_email_requested, FALSE), FALSE, v_enabled,
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

    -- Migration 331: the retired WhatsApp flag is no longer compared (ADR-024
    -- Amendment 2 §2C), so sending or omitting it never ends an occurrence.
    IF (btrim(p_name), p_asset_id, p_parameter_code, p_qualifier, p_comparator, p_threshold, p_tolerance,
        p_schedule_start, p_schedule_end, p_weekdays, p_reminder_minutes,
        COALESCE(p_email_requested, FALSE))
       IS NOT DISTINCT FROM
       (v_old.name, v_old.asset_id, v_old.parameter_code, v_old.qualifier, v_old.comparator, v_old.threshold,
        v_old.tolerance, v_old.schedule_start, v_old.schedule_end, v_old.weekdays, v_old.reminder_minutes,
        v_old.email_requested) THEN
        RETURN QUERY SELECT 'ok'::TEXT, v_old.rule_id, v_old.version; RETURN;
    END IF;

    -- Any operational change is a configuration change (ADR-024 §8): the
    -- ACTIVE occurrence ends and the rule gets a new condition identity.
    v_ended := analytics.alert_rule_end_active(v_old.rule_id, v_now);

    UPDATE analytics.alert_rules AS r
    SET name = btrim(p_name), asset_id = p_asset_id, parameter_code = p_parameter_code, qualifier = p_qualifier,
        comparator = p_comparator, threshold = p_threshold, tolerance = p_tolerance,
        unit_symbol = v_valid.unit_symbol, schedule_start = p_schedule_start, schedule_end = p_schedule_end,
        weekdays = p_weekdays, reminder_minutes = p_reminder_minutes,
        email_requested = COALESCE(p_email_requested, FALSE),
        whatsapp_requested = FALSE,
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
    v_old     analytics.alert_rules;
    v_ended   UUID[];
    v_removed UUID[];
    v_now     TIMESTAMPTZ := clock_timestamp();
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

    -- Migration 331 (A-5): the rule's WhatsApp configuration goes with it, in
    -- this transaction; the audit row lists recipient ids, never numbers.
    v_removed := ARRAY(
        SELECT x.recipient_id FROM analytics.alert_rule_whatsapp_recipients AS x
        WHERE x.rule_id = v_old.rule_id ORDER BY x.recipient_id
    );
    DELETE FROM analytics.alert_rule_whatsapp_settings AS s WHERE s.rule_id = v_old.rule_id;

    PERFORM admin.write_audit_event(
        gen_random_uuid(), p_portal_user_id, 'ALERT_RULE_DELETED', 'ALERT_RULE', v_old.rule_id,
        v_old.organization_id, v_old.site_id, analytics.alert_rule_json(v_old),
        jsonb_build_object('deleted_at', v_now, 'ended_alert_ids', to_jsonb(v_ended),
                           'whatsapp_removed_recipient_ids', to_jsonb(v_removed))
    );

    RETURN QUERY SELECT 'ok'::TEXT, v_old.rule_id, v_old.version;
END;
$function$;


-- ----------------------------------------------------------------------------
-- 8. Ownership and grants.
-- ----------------------------------------------------------------------------

DO $grants$
DECLARE
    v_sig TEXT;
    v_customer_api BOOLEAN := EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'ems_customer_api');
BEGIN
    FOREACH v_sig IN ARRAY ARRAY[
        'analytics.alert_whatsapp_actor_is_automation(bigint)',
        'analytics.alert_whatsapp_current_statement_version()',
        'analytics.alert_whatsapp_audit_recipients(uuid)'
    ] LOOP
        EXECUTE format('ALTER FUNCTION %s OWNER TO ems_admin', v_sig);
        EXECUTE format('REVOKE ALL ON FUNCTION %s FROM PUBLIC', v_sig);
    END LOOP;

    FOREACH v_sig IN ARRAY ARRAY[
        'analytics.get_portal_alert_rule_whatsapp(bigint, uuid)',
        'analytics.get_portal_alert_rule_whatsapp_summaries(bigint, uuid)',
        'analytics.save_portal_alert_rule_whatsapp(bigint, uuid, boolean, jsonb, integer, text)'
    ] LOOP
        EXECUTE format('ALTER FUNCTION %s OWNER TO ems_admin', v_sig);
        EXECUTE format('REVOKE ALL ON FUNCTION %s FROM PUBLIC', v_sig);
        EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO ems_app', v_sig);
        IF v_customer_api THEN
            EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO ems_customer_api', v_sig);
        END IF;
    END LOOP;
    IF NOT v_customer_api THEN
        RAISE NOTICE 'Migration 331: role ems_customer_api does not exist here; WhatsApp functions granted to ems_app only.';
    END IF;
END;
$grants$;

COMMENT ON FUNCTION analytics.get_portal_alert_rule_whatsapp(BIGINT, UUID) IS
'WhatsApp Phase 1: one rule''s WhatsApp configuration with full numbers, and the current approved opt-in wording {version, text} (NULL while none is approved). Result ok | forbidden (designated report automation account of any site, R5; or missing alert.configure, D16) | not_found (unknown, deleted or inaccessible rule). Revision 0 = never configured.';
COMMENT ON FUNCTION analytics.get_portal_alert_rule_whatsapp_summaries(BIGINT, UUID) IS
'WhatsApp Phase 1: per live rule of a site, enabled + recipient_count, no numbers. alert.configure holders only (D16); automation accounts refused (R5). Refusal = one row with result forbidden / not_found.';
COMMENT ON FUNCTION analytics.save_portal_alert_rule_whatsapp(BIGINT, UUID, BOOLEAN, JSONB, INTEGER, TEXT) IS
'WhatsApp Phase 1: replace-all save of one rule''s WhatsApp settings and recipients (alert.configure; R5 refused). Revision-checked (whatsapp_config_stale). Refusals: whatsapp_invalid_request | whatsapp_invalid_phone | whatsapp_duplicate_phone | whatsapp_too_many_recipients | whatsapp_unknown_recipient | whatsapp_consent_required | whatsapp_consent_statement_missing | whatsapp_consent_statement_changed | whatsapp_recipients_required | not_found | forbidden. One audit row (ALERT_RULE_WHATSAPP_UPDATED) per effective save, without phone numbers; refusals and no-ops write nothing. Never touches the rule, its occurrences or timers. Sends nothing.';
COMMENT ON FUNCTION analytics.create_portal_alert_rule(BIGINT, UUID, TEXT, UUID, TEXT, TEXT, TEXT, NUMERIC, NUMERIC, TIME, TIME, SMALLINT, SMALLINT, BOOLEAN, BOOLEAN, BOOLEAN) IS
'ADR-024: creates an alert rule (alert.configure). Result ok | not_found (site not accessible; not audited) | forbidden (audited REJECTED) | validation code | rule_limit_reached (25 enabled rules per site) | name_taken. Audited ALERT_RULE_CREATED in the same transaction. Migration 331: p_whatsapp_requested is ignored (stored FALSE).';
COMMENT ON FUNCTION analytics.update_portal_alert_rule(BIGINT, UUID, INTEGER, TEXT, UUID, TEXT, TEXT, TEXT, NUMERIC, NUMERIC, TIME, TIME, SMALLINT, SMALLINT, BOOLEAN, BOOLEAN) IS
'ADR-024: replaces a rule''s definition (alert.configure) when p_expected_version matches (else version_conflict). Any operational change ends the ACTIVE occurrence (ENDED / CONFIGURATION_CHANGED) and increments version. Audited ALERT_RULE_UPDATED. Migration 331: p_whatsapp_requested is ignored and not compared.';
COMMENT ON FUNCTION analytics.delete_portal_alert_rule(BIGINT, UUID) IS
'ADR-024: soft-deletes a rule (alert.configure): ends its ACTIVE occurrence, keeps every historical occurrence. Audited ALERT_RULE_DELETED. Migration 331: also deletes the rule''s WhatsApp settings and recipients (audit lists recipient ids only).';


-- ----------------------------------------------------------------------------
-- 9. Postconditions.
-- ----------------------------------------------------------------------------

DO $post$
DECLARE
    v_sig  TEXT;
    v_role TEXT;
    v_tab  TEXT;
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conrelid = 'analytics.alert_rules'::regclass AND conname = 'alert_rules_whatsapp_retired_chk'
    ) THEN
        RAISE EXCEPTION 'Migration 331 postcondition failed: alert_rules_whatsapp_retired_chk is missing.';
    END IF;

    FOREACH v_sig IN ARRAY ARRAY[
        'analytics.get_portal_alert_rule_whatsapp(bigint, uuid)',
        'analytics.get_portal_alert_rule_whatsapp_summaries(bigint, uuid)',
        'analytics.save_portal_alert_rule_whatsapp(bigint, uuid, boolean, jsonb, integer, text)',
        'analytics.alert_whatsapp_actor_is_automation(bigint)',
        'analytics.alert_whatsapp_current_statement_version()',
        'analytics.alert_whatsapp_audit_recipients(uuid)',
        'analytics.create_portal_alert_rule(bigint, uuid, text, uuid, text, text, text, numeric, numeric, time, time, smallint, smallint, boolean, boolean, boolean)',
        'analytics.update_portal_alert_rule(bigint, uuid, integer, text, uuid, text, text, text, numeric, numeric, time, time, smallint, smallint, boolean, boolean)',
        'analytics.delete_portal_alert_rule(bigint, uuid)'
    ] LOOP
        IF NOT EXISTS (
            SELECT 1 FROM pg_proc AS p JOIN pg_roles AS r ON r.oid = p.proowner
            WHERE p.oid = v_sig::regprocedure AND p.prosecdef AND r.rolname = 'ems_admin' AND p.proconfig IS NOT NULL
        ) THEN
            RAISE EXCEPTION 'Migration 331 postcondition failed: % is not SECURITY DEFINER / ems_admin / pinned search_path.', v_sig;
        END IF;
        IF has_function_privilege('public', v_sig, 'EXECUTE') THEN
            RAISE EXCEPTION 'Migration 331 postcondition failed: PUBLIC can execute %.', v_sig;
        END IF;
    END LOOP;

    FOREACH v_sig IN ARRAY ARRAY[
        'analytics.alert_whatsapp_actor_is_automation(bigint)',
        'analytics.alert_whatsapp_current_statement_version()',
        'analytics.alert_whatsapp_audit_recipients(uuid)'
    ] LOOP
        FOREACH v_role IN ARRAY ARRAY['ems_app', 'ems_customer_api', 'grafana_reader'] LOOP
            IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = v_role) AND has_function_privilege(v_role, v_sig, 'EXECUTE') THEN
                RAISE EXCEPTION 'Migration 331 postcondition failed: % can execute internal function %.', v_role, v_sig;
            END IF;
        END LOOP;
    END LOOP;

    FOREACH v_tab IN ARRAY ARRAY[
        'analytics.alert_whatsapp_consent_statements',
        'analytics.alert_rule_whatsapp_settings',
        'analytics.alert_rule_whatsapp_recipients'
    ] LOOP
        FOREACH v_role IN ARRAY ARRAY['ems_app', 'ems_customer_api', 'grafana_reader'] LOOP
            IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = v_role)
               AND (has_table_privilege(v_role, v_tab, 'SELECT') OR has_table_privilege(v_role, v_tab, 'INSERT')
                    OR has_table_privilege(v_role, v_tab, 'UPDATE') OR has_table_privilege(v_role, v_tab, 'DELETE')) THEN
                RAISE EXCEPTION 'Migration 331 postcondition failed: % has direct access to %.', v_role, v_tab;
            END IF;
        END LOOP;
    END LOOP;
END;
$post$;
