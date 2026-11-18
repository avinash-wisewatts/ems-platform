-- ============================================================================
-- Shared setup for assert_alert_legacy_retirement.sh (migration 320).
--
-- Runs inside the caller's open transaction (always rolled back). Recreates
-- the pre-migration-321 shape of analytics.alerts /
-- analytics.alert_evaluation_candidates (drops the 321 additions -- only
-- inside this transaction), a stub legacy job procedure with a registered
-- TimescaleDB job, and legacy Energy Attention rows in every state, so the
-- REAL migration 320 file can be executed against it.
-- ============================================================================

\set ON_ERROR_STOP on

ALTER TABLE analytics.alerts
    DROP CONSTRAINT ck_alerts_rule_condition_key,
    DROP CONSTRAINT ck_alerts_rule_comparator,
    DROP CONSTRAINT ck_alerts_rule_ended_reason,
    DROP CONSTRAINT ck_alerts_acknowledgement,
    DROP COLUMN rule_id CASCADE,
    DROP COLUMN rule_version,
    DROP COLUMN rule_name,
    DROP COLUMN asset_name,
    DROP COLUMN parameter_code,
    DROP COLUMN qualifier,
    DROP COLUMN parameter_name,
    DROP COLUMN unit_symbol,
    DROP COLUMN comparator,
    DROP COLUMN threshold,
    DROP COLUMN tolerance,
    DROP COLUMN acknowledged_at,
    DROP COLUMN acknowledged_by,
    DROP COLUMN acknowledged_actor_type,
    DROP COLUMN last_value,
    DROP COLUMN last_value_at;

ALTER TABLE analytics.alert_evaluation_candidates
    DROP CONSTRAINT ck_alert_evaluation_candidates_rule_key,
    DROP COLUMN rule_id CASCADE;

CREATE PROCEDURE analytics.run_alert_evaluation_job(job_id INTEGER, config JSONB)
LANGUAGE plpgsql
AS $$ BEGIN NULL; END $$;

SELECT add_job('analytics.run_alert_evaluation_job', INTERVAL '1 hour', scheduled => FALSE) AS legacy_job_id \gset

INSERT INTO metadata.organizations (id, name, code)
VALUES ('00000000-0000-0000-0000-00000000a320', 'M320 Org', 'M320_ORG')
ON CONFLICT (id) DO NOTHING;
INSERT INTO metadata.sites (id, organization_id, name, code)
VALUES ('00000000-0000-0000-0000-00000000b320', '00000000-0000-0000-0000-00000000a320', 'M320 Site', 'M320_SITE')
ON CONFLICT (id) DO NOTHING;

INSERT INTO analytics.alerts
    (alert_id, organization_id, site_id, condition_key, metric, state, triggered_at, trigger_value,
     resolved_at, resolved_value, ended_at, ended_reason, ended_reason_code, last_evaluated_at)
VALUES
    ('00000000-0000-0000-0000-0000000c3201', '00000000-0000-0000-0000-00000000a320', '00000000-0000-0000-0000-00000000b320',
     'ENERGY_ATTENTION:PERCENT_DEVIATION_FROM_TYPICAL_REFERENCE:15:SITE:00000000-0000-0000-0000-00000000b320',
     'ENERGY_CONSUMPTION', 'ACTIVE', now() - INTERVAL '1 hour', 120, NULL, NULL, NULL, NULL, NULL, now()),
    ('00000000-0000-0000-0000-0000000c3202', '00000000-0000-0000-0000-00000000a320', '00000000-0000-0000-0000-00000000b320',
     'ENERGY_ATTENTION:PERCENT_DEVIATION_FROM_TYPICAL_REFERENCE:15:SITE:00000000-0000-0000-0000-00000000b320',
     'ENERGY_CONSUMPTION', 'RESOLVED', now() - INTERVAL '3 days', 130, now() - INTERVAL '2 days', 90, NULL, NULL, NULL, now()),
    ('00000000-0000-0000-0000-0000000c3203', '00000000-0000-0000-0000-00000000a320', '00000000-0000-0000-0000-00000000b320',
     'ENERGY_ATTENTION:PERCENT_DEVIATION_FROM_TYPICAL_REFERENCE:15:SITE:00000000-0000-0000-0000-00000000b320',
     'ENERGY_CONSUMPTION', 'ENDED', now() - INTERVAL '5 days', 140, NULL, NULL, now() - INTERVAL '4 days',
     'Data was unavailable while this alert was active', 'DATA_UNAVAILABLE', now()),
    ('00000000-0000-0000-0000-0000000c3204', '00000000-0000-0000-0000-00000000a320', '00000000-0000-0000-0000-00000000b320',
     'ENERGY_ATTENTION:PERCENT_DEVIATION_FROM_TYPICAL_REFERENCE:15:SITE:00000000-0000-0000-0000-00000000b320',
     'ENERGY_CONSUMPTION', 'ENDED', now() - INTERVAL '6 days', 150, NULL, NULL, now() - INTERVAL '5 days',
     'Data was unavailable while this alert was active', 'DATA_UNAVAILABLE', now());

INSERT INTO analytics.alert_evaluation_candidates
    (site_id, condition_key, watch_state, since, candidate_value, last_evaluated_at, alert_id)
VALUES
    ('00000000-0000-0000-0000-00000000b320',
     'ENERGY_ATTENTION:PERCENT_DEVIATION_FROM_TYPICAL_REFERENCE:15:SITE:00000000-0000-0000-0000-00000000b320',
     'WATCHING_CLEAR', now() - INTERVAL '30 seconds', 80, now(), '00000000-0000-0000-0000-0000000c3201');
