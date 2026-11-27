-- ============================================================================
-- 333 -- WhatsApp alert delivery (ADR-026 Phase 2: A3 outbox, A4 sender
--        functions, A5 receipt functions). STAGING / TEST ONLY.
--
-- When the alert evaluator creates an Active rule-based occurrence, an
-- AFTER INSERT trigger on analytics.alerts queues one delivery per configured
-- recipient IN THE SAME TRANSACTION (transactional outbox, A3). The
-- evaluator itself (migration 327) is not changed, and an enqueue failure
-- never affects the alert: it is caught, counted in
-- analytics.alert_whatsapp_enqueue_errors and raised as a WARNING.
--
-- Safeguards (all enforced here, again when the sender claims a delivery):
--   * Global kill switch analytics.alert_whatsapp_delivery_control,
--     sending_enabled = FALSE after this migration. Nothing is queued or
--     claimed until a separately approved change turns it on.
--   * Only recipients whose consent was recorded under a wording version
--     Legal has APPROVED (WA-OPTIN-1 is still PENDING, so nobody is eligible
--     today), CONFIRMED and not opted out.
--   * Tenant/site isolation: settings, rule and alert must agree on
--     organization and site.
--   * D7 idempotency: UNIQUE (alert_id, recipient_id) -- one message per
--     occurrence and recipient.
--   * D14 quiet period: no new message to the same recipient of the same rule
--     within 60 minutes of a previous one (any occurrence); recorded as
--     SUPPRESSED / QUIET_PERIOD.
--   * Only the opening of an occurrence queues anything: no recovery,
--     reminder or group messages (D7, D2).
--   * A delivery not sent within 60 minutes of being queued is FAILED /
--     EXPIRED; one that no longer matches the alert, rule, settings or
--     recipient is SUPPRESSED at claim time.
--   * The full number is held only while a delivery can still be sent
--     (status PENDING); it is cleared when the delivery is submitted, fails,
--     is suppressed, or the recipient is removed. History shows a masked
--     number. No free-text provider error is stored (codes only), so no
--     number can leak into history (R12 default).
--   * Delivery history is kept 90 days (D10).
--
-- Tables are owned by ems_admin with no direct grants; all access is through
-- the SECURITY DEFINER functions below:
--   ems_app (sender worker):  claim_whatsapp_deliveries, record_whatsapp_send_result,
--                             purge_whatsapp_deliveries, get_whatsapp_delivery_overview,
--                             record_whatsapp_status_update
--   ems_customer_api (receipt endpoint): record_whatsapp_status_update
--   both (portal, alert.configure): get_portal_alert_rule_whatsapp_deliveries
--
-- Rollback: postgres/maintenance/333_alert_whatsapp_delivery_rollback.sql
-- (deletes all delivery records). Run it BEFORE the 332 / 331 rollbacks.
-- ============================================================================

DO $pre$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM admin.schema_migrations WHERE migration_id = '332_alert_whatsapp_consent_wording') THEN
        RAISE EXCEPTION 'Migration 333 precondition failed: migration 332 (WhatsApp consent wording) is not applied.';
    END IF;
    IF to_regclass('analytics.alert_rule_whatsapp_recipients') IS NULL
       OR to_regclass('analytics.alerts') IS NULL
       OR NOT EXISTS (SELECT 1 FROM information_schema.columns
                      WHERE table_schema = 'analytics' AND table_name = 'alert_rule_whatsapp_recipients'
                        AND column_name = 'consent_business_name') THEN
        RAISE EXCEPTION 'Migration 333 precondition failed: the WhatsApp configuration tables of 331/332 are missing.';
    END IF;
END;
$pre$;


-- ----------------------------------------------------------------------------
-- 1. Tables.
-- ----------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS analytics.alert_whatsapp_delivery_control
(
    id              SMALLINT    PRIMARY KEY DEFAULT 1,
    sending_enabled BOOLEAN     NOT NULL DEFAULT FALSE,
    changed_at      TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    changed_by_name TEXT        NOT NULL DEFAULT 'migration 333',

    CONSTRAINT alert_whatsapp_delivery_control_single_chk CHECK (id = 1),
    CONSTRAINT alert_whatsapp_delivery_control_by_chk CHECK (btrim(changed_by_name) <> '')
);
INSERT INTO analytics.alert_whatsapp_delivery_control (id) VALUES (1) ON CONFLICT (id) DO NOTHING;

CREATE TABLE IF NOT EXISTS analytics.alert_whatsapp_deliveries
(
    delivery_id               UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    alert_id                  UUID        NOT NULL,
    rule_id                   UUID        NOT NULL,
    recipient_id              UUID        NOT NULL,
    organization_id           UUID        NOT NULL,
    site_id                   UUID        NOT NULL,
    phone_e164                TEXT,
    phone_masked              TEXT        NOT NULL,
    consent_statement_version TEXT        NOT NULL,
    message                   JSONB       NOT NULL,
    status                    TEXT        NOT NULL,
    status_reason             TEXT,
    attempts                  INTEGER     NOT NULL DEFAULT 0,
    next_attempt_at           TIMESTAMPTZ,
    lease_owner               TEXT,
    lease_expires_at          TIMESTAMPTZ,
    -- Set (under the lease) immediately before the provider request: from
    -- then on the provider may have the message, so a lapsed lease is never
    -- re-sent (at most once), it becomes FAILED / SEND_UNCONFIRMED.
    send_started_at           TIMESTAMPTZ,
    provider_message_id       TEXT,
    last_error_code           TEXT,
    created_at                TIMESTAMPTZ NOT NULL,
    submitted_at              TIMESTAMPTZ,
    sent_at                   TIMESTAMPTZ,
    delivered_at              TIMESTAMPTZ,
    read_at                   TIMESTAMPTZ,
    failed_at                 TIMESTAMPTZ,
    updated_at                TIMESTAMPTZ NOT NULL,

    -- D7: one message per occurrence and recipient.
    CONSTRAINT alert_whatsapp_deliveries_once_uq UNIQUE (alert_id, recipient_id),
    CONSTRAINT alert_whatsapp_deliveries_provider_uq UNIQUE (provider_message_id),
    CONSTRAINT alert_whatsapp_deliveries_status_chk
        CHECK (status IN ('PENDING', 'SUBMITTED', 'SENT', 'DELIVERED', 'FAILED', 'SUPPRESSED')),
    CONSTRAINT alert_whatsapp_deliveries_phone_chk
        CHECK (phone_e164 IS NULL OR phone_e164 ~ '^\+[1-9][0-9]{7,14}$'),
    -- The full number exists only while the delivery can still be sent.
    CONSTRAINT alert_whatsapp_deliveries_phone_lifecycle_chk
        CHECK ((status = 'PENDING') = (phone_e164 IS NOT NULL)),
    CONSTRAINT alert_whatsapp_deliveries_pending_chk
        CHECK ((status = 'PENDING') = (next_attempt_at IS NOT NULL)),
    CONSTRAINT alert_whatsapp_deliveries_lease_chk
        CHECK ((lease_owner IS NULL) = (lease_expires_at IS NULL) AND (lease_owner IS NULL OR status = 'PENDING')),
    CONSTRAINT alert_whatsapp_deliveries_in_flight_chk
        CHECK (send_started_at IS NULL OR lease_owner IS NOT NULL),
    CONSTRAINT alert_whatsapp_deliveries_attempts_chk CHECK (attempts >= 0),
    CONSTRAINT alert_whatsapp_deliveries_provider_id_chk
        CHECK (provider_message_id IS NULL OR provider_message_id ~ '^[A-Za-z0-9_.=:+/-]{1,128}$'),
    -- Codes only, never free text (no phone number can be stored here).
    CONSTRAINT alert_whatsapp_deliveries_error_code_chk
        CHECK (last_error_code IS NULL OR last_error_code ~ '^[A-Za-z0-9_.:-]{1,64}$'),
    CONSTRAINT alert_whatsapp_deliveries_submitted_chk
        CHECK (status NOT IN ('SUBMITTED', 'SENT', 'DELIVERED') OR provider_message_id IS NOT NULL)
);

CREATE INDEX IF NOT EXISTS alert_whatsapp_deliveries_due_idx
    ON analytics.alert_whatsapp_deliveries (next_attempt_at) WHERE status = 'PENDING';
CREATE INDEX IF NOT EXISTS alert_whatsapp_deliveries_quiet_idx
    ON analytics.alert_whatsapp_deliveries (rule_id, recipient_id, created_at DESC);
CREATE INDEX IF NOT EXISTS alert_whatsapp_deliveries_created_idx
    ON analytics.alert_whatsapp_deliveries (created_at);
CREATE INDEX IF NOT EXISTS alert_whatsapp_deliveries_recipient_idx
    ON analytics.alert_whatsapp_deliveries (recipient_id) WHERE phone_e164 IS NOT NULL;

-- Receipts that arrive before the sender has recorded the provider message id
-- (the provider can call back within milliseconds). Applied on SUBMITTED;
-- unmatched ones are purged after one day.
CREATE TABLE IF NOT EXISTS analytics.alert_whatsapp_status_events
(
    provider_message_id TEXT        NOT NULL,
    status              TEXT        NOT NULL,
    status_at           TIMESTAMPTZ NOT NULL,
    error_code          TEXT,
    received_at         TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),

    PRIMARY KEY (provider_message_id, status),
    CONSTRAINT alert_whatsapp_status_events_status_chk CHECK (status IN ('sent', 'delivered', 'read', 'failed')),
    CONSTRAINT alert_whatsapp_status_events_id_chk CHECK (provider_message_id ~ '^[A-Za-z0-9_.=:+/-]{1,128}$'),
    CONSTRAINT alert_whatsapp_status_events_code_chk CHECK (error_code IS NULL OR error_code ~ '^[A-Za-z0-9_.:-]{1,64}$')
);

CREATE TABLE IF NOT EXISTS analytics.alert_whatsapp_enqueue_errors
(
    error_id    BIGINT      GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    alert_id    UUID        NOT NULL,
    rule_id     UUID,
    sqlstate    TEXT        NOT NULL,
    occurred_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp()
);

DO $tables$
DECLARE
    v_table TEXT;
    v_role  RECORD;
BEGIN
    FOREACH v_table IN ARRAY ARRAY[
        'analytics.alert_whatsapp_delivery_control',
        'analytics.alert_whatsapp_deliveries',
        'analytics.alert_whatsapp_status_events',
        'analytics.alert_whatsapp_enqueue_errors'
    ] LOOP
        EXECUTE format('ALTER TABLE %s OWNER TO ems_admin', v_table);
        EXECUTE format('REVOKE ALL ON %s FROM PUBLIC', v_table);
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

COMMENT ON TABLE analytics.alert_whatsapp_delivery_control IS
'WhatsApp delivery kill switch (ADR-026 Phase 2). sending_enabled = FALSE: nothing is queued and pending deliveries are suppressed (SENDING_DISABLED) when claimed. Changed only by a separately approved operation.';
COMMENT ON TABLE analytics.alert_whatsapp_deliveries IS
'WhatsApp alert delivery outbox and history (ADR-026 A3-A5): one row per Active occurrence and recipient (D7). phone_e164 only while PENDING; phone_masked for history. Kept 90 days (D10). No direct access: SECURITY DEFINER functions only.';


-- ----------------------------------------------------------------------------
-- 2. Helpers and the enqueue trigger (A3).
-- ----------------------------------------------------------------------------

-- "•••• 0123": the last four digits only.
CREATE OR REPLACE FUNCTION analytics.alert_whatsapp_mask_phone(p_phone TEXT)
RETURNS TEXT
LANGUAGE sql
IMMUTABLE
SECURITY DEFINER
SET search_path TO pg_catalog
AS $function$
    SELECT '•••• ' || right(p_phone, 4);
$function$;

CREATE OR REPLACE FUNCTION analytics.alert_whatsapp_enqueue(p_alert_id UUID)
RETURNS INTEGER
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path TO pg_catalog, analytics, metadata
AS $function$
#variable_conflict use_column
DECLARE
    c_quiet  CONSTANT INTERVAL := INTERVAL '60 minutes';
    v_alert  analytics.alerts;
    v_now    TIMESTAMPTZ;
    v_site   RECORD;
    v_queued INTEGER;
BEGIN
    SELECT * INTO v_alert FROM analytics.alerts AS a WHERE a.alert_id = p_alert_id;
    IF NOT FOUND OR v_alert.state <> 'ACTIVE' OR v_alert.rule_id IS NULL THEN
        RETURN 0;
    END IF;
    IF NOT COALESCE((SELECT c.sending_enabled FROM analytics.alert_whatsapp_delivery_control AS c WHERE c.id = 1), FALSE) THEN
        RETURN 0;
    END IF;
    -- WhatsApp on for this rule, and settings, rule and alert agree on the tenant.
    IF NOT EXISTS (
        SELECT 1
        FROM analytics.alert_rule_whatsapp_settings AS s
        JOIN analytics.alert_rules AS r ON r.rule_id = s.rule_id
        WHERE s.rule_id = v_alert.rule_id AND s.enabled
          AND s.site_id = v_alert.site_id AND s.organization_id = v_alert.organization_id
          AND r.site_id = v_alert.site_id AND r.organization_id = v_alert.organization_id
          AND r.deleted_at IS NULL AND r.enabled
    ) THEN
        RETURN 0;
    END IF;

    v_now := COALESCE(v_alert.last_evaluated_at, clock_timestamp());
    SELECT s.name, s.timezone INTO v_site FROM metadata.sites AS s WHERE s.id = v_alert.site_id;

    WITH candidates AS (
        SELECT r.recipient_id, r.phone_e164, r.consent_statement_version, r.consent_business_name,
               CASE
                   WHEN r.consent_state <> 'CONFIRMED' OR r.opted_out_at IS NOT NULL THEN 'OPTED_OUT'
                   WHEN st.legal_review_status IS DISTINCT FROM 'APPROVED' THEN 'CONSENT_NOT_APPROVED'
                   WHEN EXISTS (
                       SELECT 1 FROM analytics.alert_whatsapp_deliveries AS d
                       WHERE d.rule_id = v_alert.rule_id AND d.recipient_id = r.recipient_id
                         AND d.status IN ('PENDING', 'SUBMITTED', 'SENT', 'DELIVERED')
                         AND d.created_at > v_now - c_quiet
                   ) THEN 'QUIET_PERIOD'
               END AS suppress_reason
        FROM analytics.alert_rule_whatsapp_recipients AS r
        LEFT JOIN analytics.alert_whatsapp_consent_statements AS st ON st.version = r.consent_statement_version
        WHERE r.rule_id = v_alert.rule_id
    ), inserted AS (
        INSERT INTO analytics.alert_whatsapp_deliveries (
            alert_id, rule_id, recipient_id, organization_id, site_id, phone_e164, phone_masked,
            consent_statement_version, message, status, status_reason, next_attempt_at, created_at, updated_at
        )
        SELECT v_alert.alert_id, v_alert.rule_id, c.recipient_id, v_alert.organization_id, v_alert.site_id,
               CASE WHEN c.suppress_reason IS NULL THEN c.phone_e164 END,
               analytics.alert_whatsapp_mask_phone(c.phone_e164),
               c.consent_statement_version,
               jsonb_build_object(
                   'business_name', c.consent_business_name,
                   'site_name', v_site.name,
                   'site_timezone', v_site.timezone,
                   'rule_name', v_alert.rule_name,
                   'asset_name', v_alert.asset_name,
                   'parameter_name', v_alert.parameter_name,
                   'qualifier', v_alert.qualifier,
                   'unit_symbol', v_alert.unit_symbol,
                   'comparator', v_alert.comparator,
                   'threshold', v_alert.threshold,
                   'tolerance', v_alert.tolerance,
                   'trigger_value', v_alert.trigger_value,
                   'triggered_at', v_alert.triggered_at
               ),
               CASE WHEN c.suppress_reason IS NULL THEN 'PENDING' ELSE 'SUPPRESSED' END,
               c.suppress_reason,
               CASE WHEN c.suppress_reason IS NULL THEN v_now END,
               v_now, v_now
        FROM candidates AS c
        ON CONFLICT (alert_id, recipient_id) DO NOTHING
        RETURNING status
    )
    SELECT count(*) FILTER (WHERE status = 'PENDING') INTO v_queued FROM inserted;
    RETURN v_queued;
END;
$function$;

-- Never lets a WhatsApp problem affect alert evaluation.
CREATE OR REPLACE FUNCTION analytics.alert_whatsapp_enqueue_trigger()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO pg_catalog, analytics
AS $function$
BEGIN
    BEGIN
        PERFORM analytics.alert_whatsapp_enqueue(NEW.alert_id);
    EXCEPTION WHEN OTHERS THEN
        INSERT INTO analytics.alert_whatsapp_enqueue_errors (alert_id, rule_id, sqlstate)
        VALUES (NEW.alert_id, NEW.rule_id, SQLSTATE);
        RAISE WARNING 'WhatsApp enqueue failed for alert % (SQLSTATE %); the alert itself is unaffected.',
            NEW.alert_id, SQLSTATE;
    END;
    RETURN NULL;
END;
$function$;

DROP TRIGGER IF EXISTS alert_whatsapp_enqueue ON analytics.alerts;
CREATE TRIGGER alert_whatsapp_enqueue
    AFTER INSERT ON analytics.alerts
    FOR EACH ROW
    WHEN (NEW.state = 'ACTIVE' AND NEW.rule_id IS NOT NULL)
    EXECUTE FUNCTION analytics.alert_whatsapp_enqueue_trigger();

-- Removing a recipient removes its number from every delivery record and
-- suppresses anything not yet sent.
CREATE OR REPLACE FUNCTION analytics.alert_whatsapp_recipient_removed()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO pg_catalog, analytics
AS $function$
BEGIN
    UPDATE analytics.alert_whatsapp_deliveries AS d
    SET status = 'SUPPRESSED', status_reason = 'RECIPIENT_REMOVED', phone_e164 = NULL, next_attempt_at = NULL,
        lease_owner = NULL, lease_expires_at = NULL, send_started_at = NULL, updated_at = clock_timestamp()
    WHERE d.recipient_id = OLD.recipient_id AND d.status = 'PENDING';
    RETURN OLD;
END;
$function$;

DROP TRIGGER IF EXISTS alert_whatsapp_recipient_removed ON analytics.alert_rule_whatsapp_recipients;
CREATE TRIGGER alert_whatsapp_recipient_removed
    BEFORE DELETE ON analytics.alert_rule_whatsapp_recipients
    FOR EACH ROW
    EXECUTE FUNCTION analytics.alert_whatsapp_recipient_removed();


-- ----------------------------------------------------------------------------
-- 3. Sender functions (A4, ems_app).
-- ----------------------------------------------------------------------------

-- Claims due deliveries, re-checking eligibility first. A delivery that no
-- longer qualifies is SUPPRESSED (or FAILED / EXPIRED after 60 minutes) and
-- not returned. Leased rows are skipped by concurrent workers. A lapsed lease
-- is taken over only if its holder never started the provider request
-- (send_started_at NULL); otherwise the message may already be with the
-- provider, so it is FAILED / SEND_UNCONFIRMED instead of sent twice.
CREATE OR REPLACE FUNCTION analytics.claim_whatsapp_deliveries(
    p_worker_id TEXT,
    p_limit     INTEGER,
    p_lease     INTERVAL,
    p_now       TIMESTAMPTZ DEFAULT clock_timestamp()
)
RETURNS TABLE (delivery_id UUID, phone_e164 TEXT, message JSONB, attempts INTEGER, created_at TIMESTAMPTZ)
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path TO pg_catalog, analytics, metadata
AS $function$
#variable_conflict use_column
DECLARE
    c_window  CONSTANT INTERVAL := INTERVAL '60 minutes';
    v         analytics.alert_whatsapp_deliveries;
    v_enabled BOOLEAN;
    v_reason  TEXT;
BEGIN
    IF p_worker_id IS NULL OR btrim(p_worker_id) = '' OR length(p_worker_id) > 128
       OR p_limit IS NULL OR p_limit < 1 OR p_limit > 100
       OR p_lease IS NULL OR p_lease <= INTERVAL '0' OR p_lease > INTERVAL '10 minutes' OR p_now IS NULL THEN
        RAISE EXCEPTION 'claim_whatsapp_deliveries: invalid arguments' USING ERRCODE = '22023';
    END IF;
    v_enabled := COALESCE((SELECT c.sending_enabled FROM analytics.alert_whatsapp_delivery_control AS c WHERE c.id = 1), FALSE);

    FOR v IN
        SELECT d.*
        FROM analytics.alert_whatsapp_deliveries AS d
        WHERE d.status = 'PENDING' AND d.next_attempt_at <= p_now
          AND (d.lease_expires_at IS NULL OR d.lease_expires_at < p_now)
        ORDER BY d.next_attempt_at, d.created_at, d.delivery_id
        LIMIT p_limit
        FOR UPDATE SKIP LOCKED
    LOOP
        IF v.send_started_at IS NOT NULL THEN
            UPDATE analytics.alert_whatsapp_deliveries AS d
            SET status = 'FAILED', status_reason = 'SEND_UNCONFIRMED', last_error_code = 'LEASE_EXPIRED',
                failed_at = p_now, phone_e164 = NULL, next_attempt_at = NULL,
                lease_owner = NULL, lease_expires_at = NULL, send_started_at = NULL, updated_at = p_now
            WHERE d.delivery_id = v.delivery_id;
            CONTINUE;
        END IF;

        v_reason := CASE
            WHEN NOT v_enabled THEN 'SENDING_DISABLED'
            WHEN v.created_at < p_now - c_window THEN 'EXPIRED'
            WHEN NOT EXISTS (
                SELECT 1 FROM analytics.alerts AS a
                WHERE a.alert_id = v.alert_id AND a.state = 'ACTIVE'
                  AND a.site_id = v.site_id AND a.organization_id = v.organization_id
            ) THEN 'ALERT_NOT_ACTIVE'
            WHEN NOT EXISTS (
                SELECT 1
                FROM analytics.alert_rule_whatsapp_settings AS s
                JOIN analytics.alert_rules AS r ON r.rule_id = s.rule_id
                WHERE s.rule_id = v.rule_id AND s.enabled AND s.site_id = v.site_id
                  AND s.organization_id = v.organization_id AND r.deleted_at IS NULL AND r.enabled
            ) THEN 'WHATSAPP_OFF'
            WHEN NOT EXISTS (
                SELECT 1
                FROM analytics.alert_rule_whatsapp_recipients AS rc
                JOIN analytics.alert_whatsapp_consent_statements AS st ON st.version = rc.consent_statement_version
                WHERE rc.recipient_id = v.recipient_id AND rc.rule_id = v.rule_id AND rc.phone_e164 = v.phone_e164
                  AND rc.consent_state = 'CONFIRMED' AND rc.opted_out_at IS NULL
                  AND st.legal_review_status = 'APPROVED'
            ) THEN 'RECIPIENT_NOT_ELIGIBLE'
        END;

        IF v_reason IS NOT NULL THEN
            UPDATE analytics.alert_whatsapp_deliveries AS d
            SET status = CASE WHEN v_reason = 'EXPIRED' THEN 'FAILED' ELSE 'SUPPRESSED' END,
                status_reason = v_reason,
                failed_at = CASE WHEN v_reason = 'EXPIRED' THEN p_now END,
                phone_e164 = NULL, next_attempt_at = NULL, lease_owner = NULL, lease_expires_at = NULL,
                updated_at = p_now
            WHERE d.delivery_id = v.delivery_id;
            CONTINUE;
        END IF;

        UPDATE analytics.alert_whatsapp_deliveries AS d
        SET lease_owner = p_worker_id, lease_expires_at = p_now + p_lease, attempts = d.attempts + 1, updated_at = p_now
        WHERE d.delivery_id = v.delivery_id;

        delivery_id := v.delivery_id;
        phone_e164 := v.phone_e164;
        message := v.message;
        attempts := v.attempts + 1;
        created_at := v.created_at;
        RETURN NEXT;
    END LOOP;
END;
$function$;

-- The sender's last check before the provider request. TRUE (and the row is
-- marked in flight) only while the caller still holds an unexpired lease with
-- at least p_min_remaining left -- enough for the whole request -- and the
-- kill switch is still on. FALSE means: do not send (the row is retried or
-- suppressed by a later claim; nothing was sent).
CREATE OR REPLACE FUNCTION analytics.begin_whatsapp_send(
    p_delivery_id   UUID,
    p_worker_id     TEXT,
    p_min_remaining INTERVAL,
    p_now           TIMESTAMPTZ DEFAULT clock_timestamp()
)
RETURNS BOOLEAN
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path TO pg_catalog, analytics
AS $function$
BEGIN
    IF p_delivery_id IS NULL OR p_worker_id IS NULL OR p_now IS NULL
       OR p_min_remaining IS NULL OR p_min_remaining < INTERVAL '0' THEN
        RAISE EXCEPTION 'begin_whatsapp_send: invalid arguments' USING ERRCODE = '22023';
    END IF;
    IF NOT COALESCE((SELECT c.sending_enabled FROM analytics.alert_whatsapp_delivery_control AS c WHERE c.id = 1), FALSE) THEN
        RETURN FALSE;
    END IF;
    UPDATE analytics.alert_whatsapp_deliveries AS d
    SET send_started_at = p_now, updated_at = p_now
    WHERE d.delivery_id = p_delivery_id AND d.status = 'PENDING' AND d.lease_owner = p_worker_id
      AND d.send_started_at IS NULL AND d.lease_expires_at >= p_now + p_min_remaining;
    RETURN FOUND;
END;
$function$;

-- Applies one provider status to a delivery: forward only
-- (SUBMITTED -> SENT -> DELIVERED); 'failed' ends anything not yet DELIVERED.
CREATE OR REPLACE FUNCTION analytics.alert_whatsapp_apply_status(
    p_delivery_id UUID,
    p_status      TEXT,
    p_status_at   TIMESTAMPTZ,
    p_error_code  TEXT
)
RETURNS BOOLEAN
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path TO pg_catalog, analytics
AS $function$
DECLARE
    v_current TEXT;
BEGIN
    SELECT d.status INTO v_current FROM analytics.alert_whatsapp_deliveries AS d
    WHERE d.delivery_id = p_delivery_id FOR UPDATE;
    IF v_current IS NULL OR v_current NOT IN ('SUBMITTED', 'SENT', 'DELIVERED') THEN
        RETURN FALSE;
    END IF;
    IF p_status = 'sent' AND v_current = 'SUBMITTED' THEN
        UPDATE analytics.alert_whatsapp_deliveries
        SET status = 'SENT', sent_at = p_status_at, updated_at = clock_timestamp() WHERE delivery_id = p_delivery_id;
    ELSIF p_status IN ('delivered', 'read') THEN
        UPDATE analytics.alert_whatsapp_deliveries
        SET status = 'DELIVERED',
            sent_at = COALESCE(sent_at, p_status_at),
            delivered_at = COALESCE(delivered_at, p_status_at),
            read_at = CASE WHEN p_status = 'read' THEN COALESCE(read_at, p_status_at) ELSE read_at END,
            updated_at = clock_timestamp()
        WHERE delivery_id = p_delivery_id;
    ELSIF p_status = 'failed' AND v_current <> 'DELIVERED' THEN
        UPDATE analytics.alert_whatsapp_deliveries
        SET status = 'FAILED', status_reason = 'PROVIDER_FAILED', failed_at = p_status_at,
            last_error_code = p_error_code, updated_at = clock_timestamp()
        WHERE delivery_id = p_delivery_id;
    ELSE
        RETURN FALSE;
    END IF;
    RETURN TRUE;
END;
$function$;

-- The sender's outcome for a claimed delivery. Returns the resulting status,
-- or NULL when the caller no longer holds the lease (nothing changed).
--   SUBMITTED  provider accepted it (p_provider_message_id required)
--   RETRY      transient failure: PENDING again at p_retry_at, unless that is
--              past the 60-minute window or the attempts are used up (FAILED)
--   FAILED     permanent provider refusal
CREATE OR REPLACE FUNCTION analytics.record_whatsapp_send_result(
    p_delivery_id         UUID,
    p_worker_id           TEXT,
    p_outcome             TEXT,
    p_provider_message_id TEXT,
    p_error_code          TEXT,
    p_retry_at            TIMESTAMPTZ,
    p_now                 TIMESTAMPTZ DEFAULT clock_timestamp()
)
RETURNS TEXT
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path TO pg_catalog, analytics
AS $function$
#variable_conflict use_column
DECLARE
    c_window       CONSTANT INTERVAL := INTERVAL '60 minutes';
    c_max_attempts CONSTANT INTEGER := 6;
    v              analytics.alert_whatsapp_deliveries;
    v_event        RECORD;
BEGIN
    IF p_outcome IS NULL OR p_outcome NOT IN ('SUBMITTED', 'RETRY', 'FAILED')
       OR (p_outcome = 'SUBMITTED' AND (p_provider_message_id IS NULL OR p_provider_message_id !~ '^[A-Za-z0-9_.=:+/-]{1,128}$'))
       OR (p_outcome = 'RETRY' AND p_retry_at IS NULL)
       OR (p_error_code IS NOT NULL AND p_error_code !~ '^[A-Za-z0-9_.:-]{1,64}$') THEN
        RAISE EXCEPTION 'record_whatsapp_send_result: invalid arguments' USING ERRCODE = '22023';
    END IF;
    SELECT * INTO v FROM analytics.alert_whatsapp_deliveries AS d
    WHERE d.delivery_id = p_delivery_id
      AND ((d.status = 'PENDING' AND d.lease_owner = p_worker_id)
           -- A late acceptance of a send whose lease lapsed: only the worker
           -- that started it can hold a provider id for it, so record it.
           OR (p_outcome = 'SUBMITTED' AND d.status = 'FAILED' AND d.status_reason = 'SEND_UNCONFIRMED'
               AND d.provider_message_id IS NULL))
    FOR UPDATE;
    IF NOT FOUND THEN
        RETURN NULL;
    END IF;

    IF p_outcome = 'SUBMITTED' THEN
        UPDATE analytics.alert_whatsapp_deliveries AS d
        SET status = 'SUBMITTED', status_reason = NULL, failed_at = NULL,
            provider_message_id = p_provider_message_id, submitted_at = p_now,
            phone_e164 = NULL, next_attempt_at = NULL, lease_owner = NULL, lease_expires_at = NULL,
            send_started_at = NULL, last_error_code = NULL, updated_at = p_now
        WHERE d.delivery_id = p_delivery_id;
        -- Receipts that overtook this result.
        FOR v_event IN
            SELECT e.status, e.status_at, e.error_code
            FROM analytics.alert_whatsapp_status_events AS e
            WHERE e.provider_message_id = p_provider_message_id
            ORDER BY CASE e.status WHEN 'sent' THEN 1 WHEN 'delivered' THEN 2 WHEN 'read' THEN 3 ELSE 4 END
        LOOP
            PERFORM analytics.alert_whatsapp_apply_status(p_delivery_id, v_event.status, v_event.status_at, v_event.error_code);
        END LOOP;
        DELETE FROM analytics.alert_whatsapp_status_events AS e WHERE e.provider_message_id = p_provider_message_id;
    ELSIF p_outcome = 'RETRY' AND v.attempts < c_max_attempts AND p_retry_at <= v.created_at + c_window THEN
        UPDATE analytics.alert_whatsapp_deliveries AS d
        SET next_attempt_at = p_retry_at, lease_owner = NULL, lease_expires_at = NULL, send_started_at = NULL,
            last_error_code = p_error_code, updated_at = p_now
        WHERE d.delivery_id = p_delivery_id;
    ELSE
        UPDATE analytics.alert_whatsapp_deliveries AS d
        SET status = 'FAILED',
            status_reason = CASE WHEN p_outcome = 'RETRY' THEN 'RETRIES_EXHAUSTED'
                                 WHEN p_error_code = 'NOT_ALLOWLISTED' THEN 'NOT_ALLOWLISTED'
                                 ELSE 'PROVIDER_REJECTED' END,
            failed_at = p_now, last_error_code = p_error_code,
            phone_e164 = NULL, next_attempt_at = NULL, lease_owner = NULL, lease_expires_at = NULL,
            send_started_at = NULL, updated_at = p_now
        WHERE d.delivery_id = p_delivery_id;
    END IF;
    RETURN (SELECT d.status FROM analytics.alert_whatsapp_deliveries AS d WHERE d.delivery_id = p_delivery_id);
END;
$function$;


-- ----------------------------------------------------------------------------
-- 4. Receipt function (A5): one provider status from the verified webhook.
--    Returns applied | buffered | ignored.
-- ----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION analytics.record_whatsapp_status_update(
    p_provider_message_id TEXT,
    p_status              TEXT,
    p_status_at           TIMESTAMPTZ,
    p_error_code          TEXT
)
RETURNS TEXT
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path TO pg_catalog, analytics
AS $function$
DECLARE
    v_id UUID;
BEGIN
    IF p_provider_message_id IS NULL OR p_provider_message_id !~ '^[A-Za-z0-9_.=:+/-]{1,128}$'
       OR p_status IS NULL OR p_status NOT IN ('sent', 'delivered', 'read', 'failed') OR p_status_at IS NULL
       OR (p_error_code IS NOT NULL AND p_error_code !~ '^[A-Za-z0-9_.:-]{1,64}$') THEN
        RAISE EXCEPTION 'record_whatsapp_status_update: invalid arguments' USING ERRCODE = '22023';
    END IF;
    SELECT d.delivery_id INTO v_id FROM analytics.alert_whatsapp_deliveries AS d
    WHERE d.provider_message_id = p_provider_message_id;
    IF v_id IS NULL THEN
        INSERT INTO analytics.alert_whatsapp_status_events (provider_message_id, status, status_at, error_code)
        VALUES (p_provider_message_id, p_status, p_status_at, p_error_code)
        ON CONFLICT (provider_message_id, status) DO NOTHING;
        RETURN 'buffered';
    END IF;
    RETURN CASE WHEN analytics.alert_whatsapp_apply_status(v_id, p_status, p_status_at, p_error_code)
                THEN 'applied' ELSE 'ignored' END;
END;
$function$;


-- ----------------------------------------------------------------------------
-- 5. Retention and visibility.
-- ----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION analytics.purge_whatsapp_deliveries(p_now TIMESTAMPTZ DEFAULT clock_timestamp())
RETURNS TABLE (deliveries INTEGER, status_events INTEGER, enqueue_errors INTEGER)
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path TO pg_catalog, analytics
AS $function$
DECLARE
    v_d INTEGER; v_e INTEGER; v_x INTEGER;
BEGIN
    DELETE FROM analytics.alert_whatsapp_deliveries AS d
    WHERE d.created_at < p_now - INTERVAL '90 days' AND d.status <> 'PENDING';
    GET DIAGNOSTICS v_d = ROW_COUNT;
    DELETE FROM analytics.alert_whatsapp_status_events AS e WHERE e.received_at < p_now - INTERVAL '1 day';
    GET DIAGNOSTICS v_e = ROW_COUNT;
    DELETE FROM analytics.alert_whatsapp_enqueue_errors AS x WHERE x.occurred_at < p_now - INTERVAL '90 days';
    GET DIAGNOSTICS v_x = ROW_COUNT;
    RETURN QUERY SELECT v_d, v_e, v_x;
END;
$function$;

-- Operational summary for WiseWatts (worker logs / diagnostics). No numbers.
CREATE OR REPLACE FUNCTION analytics.get_whatsapp_delivery_overview(p_now TIMESTAMPTZ DEFAULT clock_timestamp())
RETURNS TABLE (
    sending_enabled        BOOLEAN,
    pending                BIGINT,
    oldest_pending_seconds INTEGER,
    submitted_24h          BIGINT,
    sent_24h               BIGINT,
    delivered_24h          BIGINT,
    failed_24h             BIGINT,
    suppressed_24h         BIGINT,
    enqueue_errors_24h     BIGINT
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path TO pg_catalog, analytics
AS $function$
    SELECT
        COALESCE((SELECT c.sending_enabled FROM analytics.alert_whatsapp_delivery_control AS c WHERE c.id = 1), FALSE),
        (SELECT count(*) FROM analytics.alert_whatsapp_deliveries AS d WHERE d.status = 'PENDING'),
        (SELECT EXTRACT(EPOCH FROM p_now - min(d.created_at))::INTEGER
         FROM analytics.alert_whatsapp_deliveries AS d WHERE d.status = 'PENDING'),
        count(*) FILTER (WHERE d.status = 'SUBMITTED'),
        count(*) FILTER (WHERE d.status = 'SENT'),
        count(*) FILTER (WHERE d.status = 'DELIVERED'),
        count(*) FILTER (WHERE d.status = 'FAILED'),
        count(*) FILTER (WHERE d.status = 'SUPPRESSED'),
        (SELECT count(*) FROM analytics.alert_whatsapp_enqueue_errors AS x WHERE x.occurred_at > p_now - INTERVAL '24 hours')
    FROM analytics.alert_whatsapp_deliveries AS d
    WHERE d.created_at > p_now - INTERVAL '24 hours';
$function$;

-- Masked delivery history of one rule, newest first, for alert.configure
-- holders with access to its site (D9, D16). Never a full number.
CREATE OR REPLACE FUNCTION analytics.get_portal_alert_rule_whatsapp_deliveries(
    p_portal_user_id BIGINT,
    p_rule_id        UUID,
    p_limit          INTEGER DEFAULT 50
)
RETURNS TABLE (
    result          TEXT,
    delivery_id     UUID,
    alert_id        UUID,
    recipient_id    UUID,
    phone_masked    TEXT,
    status          TEXT,
    status_reason   TEXT,
    attempts        INTEGER,
    last_error_code TEXT,
    created_at      TIMESTAMPTZ,
    submitted_at    TIMESTAMPTZ,
    sent_at         TIMESTAMPTZ,
    delivered_at    TIMESTAMPTZ,
    read_at         TIMESTAMPTZ,
    failed_at       TIMESTAMPTZ
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO pg_catalog, analytics, admin
AS $function$
#variable_conflict use_column
DECLARE
    v_rule analytics.alert_rules;
BEGIN
    IF analytics.alert_whatsapp_actor_is_automation(p_portal_user_id) THEN
        RETURN QUERY SELECT 'forbidden'::TEXT, NULL::UUID, NULL::UUID, NULL::UUID, NULL::TEXT, NULL::TEXT, NULL::TEXT,
            NULL::INTEGER, NULL::TEXT, NULL::TIMESTAMPTZ, NULL::TIMESTAMPTZ, NULL::TIMESTAMPTZ, NULL::TIMESTAMPTZ,
            NULL::TIMESTAMPTZ, NULL::TIMESTAMPTZ;
        RETURN;
    END IF;
    SELECT * INTO v_rule FROM analytics.alert_rules AS r WHERE r.rule_id = p_rule_id AND r.deleted_at IS NULL;
    IF NOT FOUND OR NOT admin.portal_user_can_access_site(p_portal_user_id, v_rule.site_id) THEN
        RETURN QUERY SELECT 'not_found'::TEXT, NULL::UUID, NULL::UUID, NULL::UUID, NULL::TEXT, NULL::TEXT, NULL::TEXT,
            NULL::INTEGER, NULL::TEXT, NULL::TIMESTAMPTZ, NULL::TIMESTAMPTZ, NULL::TIMESTAMPTZ, NULL::TIMESTAMPTZ,
            NULL::TIMESTAMPTZ, NULL::TIMESTAMPTZ;
        RETURN;
    END IF;
    IF NOT admin.portal_user_has_permission(p_portal_user_id, 'alert.configure') THEN
        RETURN QUERY SELECT 'forbidden'::TEXT, NULL::UUID, NULL::UUID, NULL::UUID, NULL::TEXT, NULL::TEXT, NULL::TEXT,
            NULL::INTEGER, NULL::TEXT, NULL::TIMESTAMPTZ, NULL::TIMESTAMPTZ, NULL::TIMESTAMPTZ, NULL::TIMESTAMPTZ,
            NULL::TIMESTAMPTZ, NULL::TIMESTAMPTZ;
        RETURN;
    END IF;
    RETURN QUERY
    SELECT 'ok'::TEXT, d.delivery_id, d.alert_id, d.recipient_id, d.phone_masked, d.status, d.status_reason,
           d.attempts, d.last_error_code, d.created_at, d.submitted_at, d.sent_at, d.delivered_at, d.read_at, d.failed_at
    FROM analytics.alert_whatsapp_deliveries AS d
    WHERE d.rule_id = v_rule.rule_id AND d.site_id = v_rule.site_id AND d.organization_id = v_rule.organization_id
    ORDER BY d.created_at DESC, d.delivery_id
    LIMIT LEAST(GREATEST(COALESCE(p_limit, 50), 1), 200);
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
        'analytics.alert_whatsapp_mask_phone(text)',
        'analytics.alert_whatsapp_enqueue(uuid)',
        'analytics.alert_whatsapp_enqueue_trigger()',
        'analytics.alert_whatsapp_recipient_removed()',
        'analytics.alert_whatsapp_apply_status(uuid, text, timestamptz, text)',
        'analytics.claim_whatsapp_deliveries(text, integer, interval, timestamptz)',
        'analytics.begin_whatsapp_send(uuid, text, interval, timestamptz)',
        'analytics.record_whatsapp_send_result(uuid, text, text, text, text, timestamptz, timestamptz)',
        'analytics.record_whatsapp_status_update(text, text, timestamptz, text)',
        'analytics.purge_whatsapp_deliveries(timestamptz)',
        'analytics.get_whatsapp_delivery_overview(timestamptz)',
        'analytics.get_portal_alert_rule_whatsapp_deliveries(bigint, uuid, integer)'
    ] LOOP
        EXECUTE format('ALTER FUNCTION %s OWNER TO ems_admin', v_sig);
        EXECUTE format('REVOKE ALL ON FUNCTION %s FROM PUBLIC', v_sig);
    END LOOP;

    FOREACH v_sig IN ARRAY ARRAY[
        'analytics.claim_whatsapp_deliveries(text, integer, interval, timestamptz)',
        'analytics.begin_whatsapp_send(uuid, text, interval, timestamptz)',
        'analytics.record_whatsapp_send_result(uuid, text, text, text, text, timestamptz, timestamptz)',
        'analytics.record_whatsapp_status_update(text, text, timestamptz, text)',
        'analytics.purge_whatsapp_deliveries(timestamptz)',
        'analytics.get_whatsapp_delivery_overview(timestamptz)',
        'analytics.get_portal_alert_rule_whatsapp_deliveries(bigint, uuid, integer)'
    ] LOOP
        EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO ems_app', v_sig);
    END LOOP;

    IF v_customer_api THEN
        FOREACH v_sig IN ARRAY ARRAY[
            'analytics.record_whatsapp_status_update(text, text, timestamptz, text)',
            'analytics.get_portal_alert_rule_whatsapp_deliveries(bigint, uuid, integer)'
        ] LOOP
            EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO ems_customer_api', v_sig);
        END LOOP;
    END IF;
END;
$grants$;

COMMENT ON FUNCTION analytics.claim_whatsapp_deliveries(TEXT, INTEGER, INTERVAL, TIMESTAMPTZ) IS
'WhatsApp sender (ems_app): lease up to p_limit due PENDING deliveries, re-checking the kill switch, 60-minute window, Active alert, WhatsApp settings and recipient eligibility (Legal-APPROVED consent) first; non-qualifying rows become SUPPRESSED (or FAILED/EXPIRED) and are not returned.';
COMMENT ON FUNCTION analytics.begin_whatsapp_send(UUID, TEXT, INTERVAL, TIMESTAMPTZ) IS
'WhatsApp sender (ems_app): mark a leased delivery in flight just before the provider request; FALSE (do not send) unless the lease has p_min_remaining left and the kill switch is on. A lapsed in-flight lease is never re-sent: the next claim records FAILED / SEND_UNCONFIRMED.';
COMMENT ON FUNCTION analytics.record_whatsapp_send_result(UUID, TEXT, TEXT, TEXT, TEXT, TIMESTAMPTZ, TIMESTAMPTZ) IS
'WhatsApp sender (ems_app): outcome SUBMITTED | RETRY | FAILED of a leased delivery. Returns the new status, or NULL if the lease was lost. Clears the full number once nothing more will be sent.';
COMMENT ON FUNCTION analytics.record_whatsapp_status_update(TEXT, TEXT, TIMESTAMPTZ, TEXT) IS
'WhatsApp receipt endpoint (signature-verified webhook): sent | delivered | read | failed for a provider message id. applied | buffered (id not recorded yet) | ignored (no forward change).';


-- ----------------------------------------------------------------------------
-- 7. Postconditions.
-- ----------------------------------------------------------------------------

DO $post$
DECLARE
    v_sig  TEXT;
    v_role TEXT;
BEGIN
    IF (SELECT sending_enabled FROM analytics.alert_whatsapp_delivery_control WHERE id = 1) IS DISTINCT FROM FALSE THEN
        RAISE EXCEPTION 'Migration 333 postcondition failed: WhatsApp sending must be off after the migration.';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'alert_whatsapp_enqueue'
                   AND tgrelid = 'analytics.alerts'::regclass AND NOT tgisinternal) THEN
        RAISE EXCEPTION 'Migration 333 postcondition failed: the enqueue trigger is missing.';
    END IF;
    FOREACH v_sig IN ARRAY ARRAY[
        'analytics.alert_whatsapp_enqueue(uuid)',
        'analytics.claim_whatsapp_deliveries(text, integer, interval, timestamptz)',
        'analytics.begin_whatsapp_send(uuid, text, interval, timestamptz)',
        'analytics.record_whatsapp_send_result(uuid, text, text, text, text, timestamptz, timestamptz)',
        'analytics.record_whatsapp_status_update(text, text, timestamptz, text)',
        'analytics.get_portal_alert_rule_whatsapp_deliveries(bigint, uuid, integer)'
    ] LOOP
        IF NOT EXISTS (
            SELECT 1 FROM pg_proc AS p JOIN pg_roles AS r ON r.oid = p.proowner
            WHERE p.oid = v_sig::regprocedure AND p.prosecdef AND r.rolname = 'ems_admin' AND p.proconfig IS NOT NULL
        ) THEN
            RAISE EXCEPTION 'Migration 333 postcondition failed: % is not SECURITY DEFINER / ems_admin / pinned search_path.', v_sig;
        END IF;
        IF has_function_privilege('public', v_sig, 'EXECUTE') THEN
            RAISE EXCEPTION 'Migration 333 postcondition failed: PUBLIC can execute %.', v_sig;
        END IF;
    END LOOP;
    FOREACH v_role IN ARRAY ARRAY['ems_app', 'ems_customer_api', 'grafana_reader'] LOOP
        IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = v_role) THEN
            IF has_function_privilege(v_role, 'analytics.alert_whatsapp_enqueue(uuid)', 'EXECUTE') THEN
                RAISE EXCEPTION 'Migration 333 postcondition failed: % can execute the internal enqueue function.', v_role;
            END IF;
            IF has_table_privilege(v_role, 'analytics.alert_whatsapp_deliveries', 'SELECT') THEN
                RAISE EXCEPTION 'Migration 333 postcondition failed: % can read the delivery table directly.', v_role;
            END IF;
        END IF;
    END LOOP;
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'ems_customer_api')
       AND has_function_privilege('ems_customer_api', 'analytics.claim_whatsapp_deliveries(text, integer, interval, timestamptz)', 'EXECUTE') THEN
        RAISE EXCEPTION 'Migration 333 postcondition failed: the customer API can claim deliveries (and read numbers).';
    END IF;
END;
$post$;
