-- ============================================================================
-- Rollback of migration 333 (WhatsApp alert delivery, ADR-026 Phase 2).
--
-- DESTRUCTIVE: deletes every WhatsApp delivery record (history, pending
-- outbox rows, buffered receipts, enqueue errors). Counts are reported
-- (NOTICE) first. Recipients and their consent (331/332) are not touched.
-- Stop the whatsapp-sender service first. Run only with explicit
-- authorisation, and BEFORE any rollback of 332 or 331.
-- ============================================================================

BEGIN;

DO $report$
BEGIN
    RAISE NOTICE 'Rollback 333: deleting % WhatsApp delivery record(s) (% pending).',
        (SELECT count(*) FROM analytics.alert_whatsapp_deliveries),
        (SELECT count(*) FROM analytics.alert_whatsapp_deliveries WHERE status = 'PENDING');
END;
$report$;

DROP TRIGGER IF EXISTS alert_whatsapp_enqueue ON analytics.alerts;
DROP TRIGGER IF EXISTS alert_whatsapp_recipient_removed ON analytics.alert_rule_whatsapp_recipients;

DROP FUNCTION IF EXISTS analytics.get_portal_alert_rule_whatsapp_deliveries(BIGINT, UUID, INTEGER);
DROP FUNCTION IF EXISTS analytics.get_whatsapp_delivery_overview(TIMESTAMPTZ);
DROP FUNCTION IF EXISTS analytics.purge_whatsapp_deliveries(TIMESTAMPTZ);
DROP FUNCTION IF EXISTS analytics.record_whatsapp_status_update(TEXT, TEXT, TIMESTAMPTZ, TEXT);
DROP FUNCTION IF EXISTS analytics.record_whatsapp_send_result(UUID, TEXT, TEXT, TEXT, TEXT, TIMESTAMPTZ, TIMESTAMPTZ);
DROP FUNCTION IF EXISTS analytics.begin_whatsapp_send(UUID, TEXT, INTERVAL, TIMESTAMPTZ);
DROP FUNCTION IF EXISTS analytics.alert_whatsapp_apply_status(UUID, TEXT, TIMESTAMPTZ, TEXT);
DROP FUNCTION IF EXISTS analytics.claim_whatsapp_deliveries(TEXT, INTEGER, INTERVAL, TIMESTAMPTZ);
DROP FUNCTION IF EXISTS analytics.alert_whatsapp_recipient_removed();
DROP FUNCTION IF EXISTS analytics.alert_whatsapp_enqueue_trigger();
DROP FUNCTION IF EXISTS analytics.alert_whatsapp_enqueue(UUID);
DROP FUNCTION IF EXISTS analytics.alert_whatsapp_mask_phone(TEXT);

DROP TABLE IF EXISTS analytics.alert_whatsapp_enqueue_errors;
DROP TABLE IF EXISTS analytics.alert_whatsapp_status_events;
DROP TABLE IF EXISTS analytics.alert_whatsapp_deliveries;
DROP TABLE IF EXISTS analytics.alert_whatsapp_delivery_control;

DELETE FROM admin.schema_migrations WHERE migration_id = '333_alert_whatsapp_delivery';

COMMIT;
