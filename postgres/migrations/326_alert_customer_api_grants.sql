-- ============================================================================
-- Migration 326
-- Alerts (ADR-024 §15): EXECUTE for the customer API's least-privilege role
-- on the customer-facing alert functions of migrations 323 and 324.
--
-- ems_customer_api (migration 313) exists on staging and test only; on
-- production the customer-facing /api/v1 is still served by the
-- Administration App as ems_app (ADR-023 stage 5 not done there), which
-- migrations 323 / 324 already grant. This migration therefore runs in every
-- environment and grants only where the role exists -- a no-op (reported by a
-- NOTICE) where it does not. Internal helpers and the evaluator are never
-- granted.
--
-- Rollback: REVOKE EXECUTE on the functions below FROM ems_customer_api.
-- ============================================================================

DO $grants$
DECLARE
    v_sig TEXT;
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'ems_customer_api') THEN
        RAISE NOTICE 'Migration 326: role ems_customer_api does not exist here; no grant needed (ems_app serves /api/v1).';
        RETURN;
    END IF;

    FOREACH v_sig IN ARRAY ARRAY[
        'analytics.create_portal_alert_rule(bigint, uuid, text, uuid, text, text, text, numeric, numeric, time, time, smallint, smallint, boolean, boolean, boolean)',
        'analytics.update_portal_alert_rule(bigint, uuid, integer, text, uuid, text, text, text, numeric, numeric, time, time, smallint, smallint, boolean, boolean)',
        'analytics.set_portal_alert_rule_enabled(bigint, uuid, boolean)',
        'analytics.delete_portal_alert_rule(bigint, uuid)',
        'analytics.acknowledge_portal_alert(bigint, uuid)',
        'analytics.get_portal_site_alerts(bigint, uuid, text[], timestamptz, timestamptz, integer, timestamptz)',
        'analytics.get_portal_alert_detail(bigint, uuid)',
        'analytics.list_portal_alert_rules(bigint, uuid)',
        'analytics.get_portal_alert_rule(bigint, uuid)',
        'analytics.list_portal_alert_rule_parameters(bigint, uuid, uuid)'
    ] LOOP
        EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO ems_customer_api', v_sig);
    END LOOP;

    FOREACH v_sig IN ARRAY ARRAY[
        'analytics.alert_rule_parameter_binding(uuid, text, text, timestamptz)',
        'analytics.alert_rule_validate(uuid, text, uuid, text, text, text, numeric, numeric, time, time, smallint, smallint, text)',
        'analytics.alert_rule_end_active(uuid, timestamptz)',
        'analytics.evaluate_alert_rules(timestamptz)'
    ] LOOP
        IF has_function_privilege('ems_customer_api', v_sig, 'EXECUTE') THEN
            RAISE EXCEPTION 'Migration 326 postcondition failed: ems_customer_api can execute internal function %.', v_sig;
        END IF;
    END LOOP;
END;
$grants$;
