-- ============================================================================
-- Migration 321
-- Alerts (ADR-024): customer-configurable alert rules -- schema.
--
-- Rules and occurrences stay within the existing Alert DDS concept (ADR-024
-- DDS change-control note, approved 2026-11-18):
--
--   analytics.alert_rules (new)            one row per rule; soft-deletable
--   analytics.alerts (reused, migration 238) occurrences, now always from a
--                                           rule: rule reference, immutable
--                                           rule snapshot, acknowledgement,
--                                           latest value; guards
--   analytics.alert_evaluation_candidates   qualification / resolution
--     (reused, migration 238)               timers, now per rule
--   analytics.alert_evaluation_runs (new)   evaluator run log (monitoring)
--   config.portal_permission_definitions    alert.configure (ADMIN only;
--                                           OPERATOR keeps alert.acknowledge)
--
-- Precondition: migration 320 has emptied analytics.alerts and
-- analytics.alert_evaluation_candidates, so NOT NULL rule references and the
-- RULE:% guard can be added. Tables are written and read only through the
-- SECURITY DEFINER functions of migrations 323-325; no table grants.
--
-- Rollback: DROP the added constraints/columns and analytics.alert_rules /
-- analytics.alert_evaluation_runs; DELETE alert.configure rows.
-- ============================================================================

DO $pre$
BEGIN
    IF EXISTS (SELECT 1 FROM analytics.alerts) OR EXISTS (SELECT 1 FROM analytics.alert_evaluation_candidates) THEN
        RAISE EXCEPTION 'Migration 321 precondition failed: analytics.alerts / analytics.alert_evaluation_candidates are not empty (migration 320 must run first).';
    END IF;
    IF to_regclass('analytics.alert_rules') IS NOT NULL THEN
        RAISE EXCEPTION 'Migration 321 precondition failed: analytics.alert_rules already exists.';
    END IF;
END;
$pre$;


-- ----------------------------------------------------------------------------
-- 1. analytics.alert_rules
-- ----------------------------------------------------------------------------

CREATE TABLE analytics.alert_rules
(
    rule_id           UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    organization_id   UUID        NOT NULL REFERENCES metadata.organizations (id),
    site_id           UUID        NOT NULL REFERENCES metadata.sites (id),
    asset_id          UUID        NOT NULL REFERENCES metadata.assets (id),
    name              TEXT        NOT NULL,
    parameter_code    TEXT        NOT NULL,
    qualifier         TEXT,
    comparator        TEXT        NOT NULL,
    comparison_mode   TEXT        NOT NULL DEFAULT 'FIXED',
    mean_window       INTERVAL,
    threshold         NUMERIC     NOT NULL,
    tolerance         NUMERIC,
    unit_symbol       TEXT,
    schedule_start    TIME        NOT NULL,
    schedule_end      TIME        NOT NULL,
    weekdays          SMALLINT    NOT NULL,
    reminder_minutes  SMALLINT,
    email_requested   BOOLEAN     NOT NULL DEFAULT FALSE,
    whatsapp_requested BOOLEAN    NOT NULL DEFAULT FALSE,
    enabled           BOOLEAN     NOT NULL DEFAULT TRUE,
    version           INTEGER     NOT NULL DEFAULT 1,
    created_at        TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    created_by        BIGINT      NOT NULL REFERENCES admin.portal_users (portal_user_id),
    updated_at        TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    updated_by        BIGINT      NOT NULL REFERENCES admin.portal_users (portal_user_id),
    deleted_at        TIMESTAMPTZ,
    deleted_by        BIGINT      REFERENCES admin.portal_users (portal_user_id),

    CONSTRAINT alert_rules_name_chk
        CHECK (name = btrim(name) AND char_length(name) BETWEEN 1 AND 120),
    CONSTRAINT alert_rules_parameter_chk CHECK (btrim(parameter_code) <> ''),
    CONSTRAINT alert_rules_comparator_chk CHECK (comparator IN ('GT', 'LT', 'EQ')),
    -- MEAN is reserved for the later mean-over-time increment (ADR-024 §12);
    -- the write functions refuse it today.
    CONSTRAINT alert_rules_mode_chk CHECK (
        (comparison_mode = 'FIXED' AND mean_window IS NULL)
        OR (comparison_mode = 'MEAN' AND mean_window > INTERVAL '0')
    ),
    -- Equal-to needs an explicit tolerance in the parameter's unit; no
    -- default (ADR-024 §5). Other comparators carry none.
    CONSTRAINT alert_rules_tolerance_chk CHECK (
        (comparator = 'EQ' AND tolerance IS NOT NULL AND tolerance >= 0)
        OR (comparator <> 'EQ' AND tolerance IS NULL)
    ),
    -- Site-local daily window; start > end crosses midnight; start = end is
    -- not a window.
    CONSTRAINT alert_rules_schedule_chk CHECK (schedule_start <> schedule_end),
    -- ISO-weekday bitmask: Monday = 1 ... Sunday = 64; 127 = every day.
    CONSTRAINT alert_rules_weekdays_chk CHECK (weekdays BETWEEN 1 AND 127),
    -- Stored preference only; nothing is sent (ADR-024 §10). NULL = none.
    CONSTRAINT alert_rules_reminder_chk CHECK (reminder_minutes IS NULL OR reminder_minutes IN (15, 30)),
    CONSTRAINT alert_rules_version_chk CHECK (version >= 1),
    CONSTRAINT alert_rules_deleted_chk CHECK (
        (deleted_at IS NULL AND deleted_by IS NULL)
        OR (deleted_at IS NOT NULL AND deleted_by IS NOT NULL AND NOT enabled)
    )
);

-- Rule names are unique among a site's non-deleted rules (case-insensitive);
-- a soft-deleted rule's name can be reused.
CREATE UNIQUE INDEX alert_rules_site_name_uq
    ON analytics.alert_rules (site_id, lower(name)) WHERE deleted_at IS NULL;
CREATE INDEX alert_rules_site_idx
    ON analytics.alert_rules (site_id) WHERE deleted_at IS NULL;
CREATE INDEX alert_rules_enabled_idx
    ON analytics.alert_rules (site_id) WHERE enabled AND deleted_at IS NULL;

ALTER TABLE analytics.alert_rules OWNER TO ems_admin;
REVOKE ALL ON analytics.alert_rules FROM PUBLIC, ems_app, grafana_reader;
COMMENT ON TABLE analytics.alert_rules IS
'ADR-024: customer-configurable alert rules, one per (site, asset, parameter, condition, schedule). Soft-deleted (deleted_at) rules are never evaluated and leave the rule list; their occurrences stay in analytics.alerts. version increments on every edit and on re-enable (a new condition identity, ADR-016 decision 8). At most 25 enabled, non-deleted rules per site (enforced by the migration 323 write functions). email_requested / whatsapp_requested and reminder_minutes are stored preferences only -- nothing is ever sent. Written only through migration 323 functions.';
COMMENT ON COLUMN analytics.alert_rules.weekdays IS
'ISO-weekday bitmask in the site''s timezone: Monday = 1, Tuesday = 2, ... Sunday = 64; 127 = every day.';
COMMENT ON COLUMN analytics.alert_rules.parameter_code IS
'config.parameters.code -- the Analytics catalogue data_point; with qualifier it identifies the asset''s parameter, resolved to telemetry through the current metadata.asset_points binding.';


-- ----------------------------------------------------------------------------
-- 2. analytics.alerts -- rule-based occurrences only.
-- ----------------------------------------------------------------------------

ALTER TABLE analytics.alerts
    ADD COLUMN rule_id                 UUID    NOT NULL REFERENCES analytics.alert_rules (rule_id),
    ADD COLUMN rule_version            INTEGER NOT NULL,
    ADD COLUMN rule_name               TEXT    NOT NULL,
    ADD COLUMN asset_name              TEXT    NOT NULL,
    ADD COLUMN parameter_code          TEXT    NOT NULL,
    ADD COLUMN qualifier               TEXT,
    ADD COLUMN parameter_name          TEXT    NOT NULL,
    ADD COLUMN unit_symbol             TEXT,
    ADD COLUMN comparator              TEXT    NOT NULL,
    ADD COLUMN threshold               NUMERIC NOT NULL,
    ADD COLUMN tolerance               NUMERIC,
    ADD COLUMN acknowledged_at         TIMESTAMPTZ,
    ADD COLUMN acknowledged_by         BIGINT  REFERENCES admin.portal_users (portal_user_id),
    ADD COLUMN acknowledged_actor_type TEXT,
    ADD COLUMN last_value              DOUBLE PRECISION,
    ADD COLUMN last_value_at           TIMESTAMPTZ;

ALTER TABLE analytics.alerts
    -- Guard: legacy-shaped (Energy Attention) rows can never reappear.
    ADD CONSTRAINT ck_alerts_rule_condition_key
        CHECK (condition_key = 'RULE:' || rule_id::TEXT || ':v' || rule_version::TEXT),
    ADD CONSTRAINT ck_alerts_rule_comparator CHECK (comparator IN ('GT', 'LT', 'EQ')),
    -- Rule-based alerts end only through a configuration change (ADR-024
    -- §4A, §8): never DATA_UNAVAILABLE.
    ADD CONSTRAINT ck_alerts_rule_ended_reason
        CHECK (state <> 'ENDED' OR ended_reason_code = 'CONFIGURATION_CHANGED'),
    -- Acknowledgement is an attribute, all-or-nothing; set only while
    -- ACTIVE (migration 323) and retained after resolution.
    ADD CONSTRAINT ck_alerts_acknowledgement CHECK (
        (acknowledged_at IS NULL AND acknowledged_by IS NULL AND acknowledged_actor_type IS NULL)
        OR (acknowledged_at IS NOT NULL AND acknowledged_by IS NOT NULL
            AND acknowledged_actor_type IN ('CUSTOMER', 'WISEWATTS_STAFF'))
    );

CREATE UNIQUE INDEX ux_alerts_one_active_per_rule
    ON analytics.alerts (rule_id) WHERE state = 'ACTIVE';
CREATE INDEX ix_alerts_site_resolved_time
    ON analytics.alerts (site_id, resolved_at DESC) WHERE state = 'RESOLVED';
CREATE INDEX ix_alerts_site_ended_time
    ON analytics.alerts (site_id, ended_at DESC) WHERE state = 'ENDED';
CREATE INDEX ix_alerts_rule_time
    ON analytics.alerts (rule_id, triggered_at DESC);

COMMENT ON TABLE analytics.alerts IS
'Alert occurrences (ADR-024; table from MVP-7 migration 238). Every row comes from an analytics.alert_rules rule (condition_key = RULE:<rule_id>:v<rule_version>); the legacy Energy Attention rows were deleted by migration 320. The rule snapshot columns (rule_name, asset_name, parameter_*, unit_symbol, comparator, threshold, tolerance) keep history intact after edits, soft deletion or renames. Acknowledgement (acknowledged_*) records who saw an ACTIVE alert -- it is never resolution. Resolved/Ended rows are kept 90 days from resolved_at / ended_at (migration 325).';
COMMENT ON COLUMN analytics.alerts.acknowledged_by IS
'Internal: the portal user who acknowledged. Never exposed for staff (acknowledged_actor_type = WISEWATTS_STAFF): customer-facing reads show "WiseWatts Support".';


-- ----------------------------------------------------------------------------
-- 3. analytics.alert_evaluation_candidates -- per rule.
-- ----------------------------------------------------------------------------

ALTER TABLE analytics.alert_evaluation_candidates
    ADD COLUMN rule_id UUID NOT NULL REFERENCES analytics.alert_rules (rule_id),
    ADD CONSTRAINT ck_alert_evaluation_candidates_rule_key CHECK (condition_key LIKE 'RULE:%');

COMMENT ON TABLE analytics.alert_evaluation_candidates IS
'Internal evaluator timer state (ADR-024 §4/§4A; table from migration 238): WATCHING_TRIGGER = condition true, counting toward the 5-minute qualification; WATCHING_CLEAR = condition false on valid data for an ACTIVE alert, counting toward the 1-minute resolution. A gap, an out-of-schedule run (trigger only) or unavailable telemetry resets the timer. Not customer-facing.';


-- ----------------------------------------------------------------------------
-- 4. analytics.alert_evaluation_runs -- monitoring.
-- ----------------------------------------------------------------------------

CREATE TABLE analytics.alert_evaluation_runs
(
    run_id           BIGINT      GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    started_at       TIMESTAMPTZ NOT NULL,
    finished_at      TIMESTAMPTZ NOT NULL,
    evaluated_at     TIMESTAMPTZ NOT NULL,
    rules_evaluated  INTEGER     NOT NULL,
    rules_unavailable INTEGER    NOT NULL,
    alerts_created   INTEGER     NOT NULL,
    alerts_resolved  INTEGER     NOT NULL,
    alerts_purged    INTEGER     NOT NULL,
    skipped          BOOLEAN     NOT NULL DEFAULT FALSE
);
CREATE INDEX alert_evaluation_runs_started_idx ON analytics.alert_evaluation_runs (started_at DESC);
ALTER TABLE analytics.alert_evaluation_runs OWNER TO ems_admin;
REVOKE ALL ON analytics.alert_evaluation_runs FROM PUBLIC, ems_app, grafana_reader;
COMMENT ON TABLE analytics.alert_evaluation_runs IS
'ADR-024 §13: one row per alert-rule evaluator run (duration, rules evaluated / unavailable, alerts created / resolved / purged; skipped = a previous run still held the lock). Kept 7 days. Checked by scripts/verify/verify_jobs.sh.';


-- ----------------------------------------------------------------------------
-- 5. alert.configure -- ADMIN only (ADMIN's catalogue rows were seeded once,
--    so the grant is explicit). OPERATOR keeps alert.acknowledge only.
-- ----------------------------------------------------------------------------

INSERT INTO config.portal_permission_definitions (permission_code, display_name, description, sort_order)
VALUES ('alert.configure', 'Configure alerts',
        'Create, edit, enable, disable and delete alert rules for permitted sites.', 115)
ON CONFLICT (permission_code) DO NOTHING;

INSERT INTO config.portal_role_permissions (role_code, permission_code)
VALUES ('ADMIN', 'alert.configure')
ON CONFLICT DO NOTHING;


DO $post$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM config.portal_role_permissions WHERE role_code = 'ADMIN' AND permission_code = 'alert.configure'
    ) OR EXISTS (
        SELECT 1 FROM config.portal_role_permissions WHERE role_code <> 'ADMIN' AND permission_code = 'alert.configure'
    ) THEN
        RAISE EXCEPTION 'Migration 321 postcondition failed: alert.configure must be granted to ADMIN only.';
    END IF;
    IF NOT EXISTS (
        SELECT 1 FROM config.portal_role_permissions WHERE role_code = 'OPERATOR' AND permission_code = 'alert.acknowledge'
    ) THEN
        RAISE EXCEPTION 'Migration 321 postcondition failed: OPERATOR must hold alert.acknowledge.';
    END IF;
END;
$post$;
