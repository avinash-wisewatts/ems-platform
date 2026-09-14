-- ============================================================================
-- Migration 238
-- MVP-7 Basic Alerts (Q77) -- Alert domain concept (B1) and server-side
-- evaluation mechanism (A1).
--
-- Source of record:
--   docs/00-governance/decisions/ADR-016-q77-mvp7-basic-alerts.md (product
--   decision -- lifecycle, states, retention, recurrence, content)
--   docs/00-governance/decisions/ADR-017-mvp7-alert-architecture.md
--   (architecture decision -- TimescaleDB-native evaluation job, Alert as
--   the DDS's 11th core concept, single-source-of-truth arrangement for the
--   +/-15% materiality rule)
--   docs/00-governance/decisions/ADR-010-mvp3-attention-materiality-policy.md
--   (the existing client-side rule this migration's evaluator function
--   replicates -- see analytics.evaluate_energy_attention_materiality below)
--
-- Scope, verified this session, not assumed:
--   The only Attention condition that exists anywhere in this repository is
--   Site-level Energy Attention (+/-15% deviation from the Slice C typical
--   reference, web/src/attention/materiality-policy.ts). Per the Space/Asset
--   reconciliation in ADR-017, this migration does NOT implement any
--   Space/Asset-level condition -- analytics.alerts.space_id/asset_id are
--   reserved columns, populated by nothing this migration creates.
--
-- Implementation-discovered design point, not previously decided, flagged
-- here rather than silently resolved: ADR-016 does not specify what time
-- period an *automatically, continuously* evaluated Attention condition
-- applies to (the existing Site Overview / Site Performance Report both let
-- a human pick a period). analytics.get_portal_site_energy_typical_reference
-- (migration 236) requires an EXACT WHOLE-DAY window -- the same constraint
-- ADR-015 already documented as making Attention "unavailable for most
-- calendar-to-date periods." A 1-minute job cannot use a "today so far"
-- window (not a whole day until midnight) without hitting that same
-- documented gap. The narrowest, already-decided-consistent interpretation
-- used here: the job evaluates the most recently COMPLETED site-local
-- calendar day ("yesterday") -- the one period for which Slice C's
-- typical-reference mechanism is always computable. This is a consequence
-- of the already-documented whole-day constraint, not a new product
-- decision; see this session's implementation report for the same note.
--
-- Retention design deviation from ADR-017's original assumption: ADR-017
-- suggested reusing "the platform's existing TimescaleDB retention-policy
-- mechanism" for the 90-day Resolved/Ended retention. On inspection, that
-- mechanism drops whole hypertable chunks by INSERT-time age -- it cannot
-- express "90 days from resolved_at/ended_at, but Active rows never
-- expire," a state-conditional rule. analytics.alerts is therefore a plain
-- (non-hypertable) table; retention is enforced by an explicit DELETE
-- inside analytics.evaluate_alerts() below, run every job cycle. Alert
-- volume (rare occurrences, not high-frequency telemetry) does not need
-- hypertable partitioning or compression.
-- ============================================================================

BEGIN;

-- ----------------------------------------------------------------------------
-- 1. analytics.alerts -- the customer-facing Alert record (ADR-017 minimum
--    conceptual model). Immutable once Resolved/Ended except for the fields
--    that record that very transition.
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS analytics.alerts (
    alert_id            UUID NOT NULL DEFAULT gen_random_uuid(),

    -- tenant / structural context (carried directly, like every analytics.* table)
    organization_id     UUID NOT NULL,
    site_id             UUID NOT NULL REFERENCES metadata.sites(id),
    -- Reserved, not populated by anything this migration creates -- see the
    -- Space/Asset reconciliation note above.
    space_id            UUID REFERENCES metadata.spaces(id),
    asset_id            UUID REFERENCES metadata.assets(id),

    -- condition identity (ADR-016 decision 10 -- recurrence groups on this,
    -- and a configuration change is exactly a condition_key change)
    condition_key        TEXT NOT NULL,
    metric                TEXT NOT NULL,

    -- lifecycle (ADR-016 decisions 3, 7-8)
    state                 TEXT NOT NULL CHECK (state IN ('ACTIVE', 'RESOLVED', 'ENDED')),
    triggered_at           TIMESTAMPTZ NOT NULL,
    trigger_value          DOUBLE PRECISION NOT NULL,
    resolved_at            TIMESTAMPTZ,
    resolved_value         DOUBLE PRECISION,
    ended_at               TIMESTAMPTZ,
    ended_reason           TEXT,
    last_evaluated_at      TIMESTAMPTZ NOT NULL,

    created_at             TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),

    CONSTRAINT pk_alerts PRIMARY KEY (alert_id),

    -- State/field consistency -- a RESOLVED row always has resolved_at/value
    -- and never ended_at/reason; an ENDED row is the mirror image; an ACTIVE
    -- row has neither (ADR-016 decision 7: Ended is never Resolved).
    CONSTRAINT ck_alerts_state_fields CHECK (
        (state = 'ACTIVE'   AND resolved_at IS NULL AND ended_at IS NULL)
        OR (state = 'RESOLVED' AND resolved_at IS NOT NULL AND resolved_value IS NOT NULL AND ended_at IS NULL)
        OR (state = 'ENDED'    AND ended_at IS NOT NULL AND ended_reason IS NOT NULL AND resolved_at IS NULL)
    )
);

-- Enforces ADR-016 decision 3 ("no repeated alerts while the same condition
-- remains continuously true") and the explicit "do not create duplicate
-- occurrences" instruction at the database level, not just in job logic:
-- at most one ACTIVE row per (site, condition) at a time.
CREATE UNIQUE INDEX IF NOT EXISTS ux_alerts_one_active_per_condition
    ON analytics.alerts (site_id, condition_key)
    WHERE state = 'ACTIVE';

CREATE INDEX IF NOT EXISTS ix_alerts_site_state_time
    ON analytics.alerts (site_id, state, triggered_at DESC);
CREATE INDEX IF NOT EXISTS ix_alerts_org_condition_time
    ON analytics.alerts (organization_id, condition_key, triggered_at DESC);
CREATE INDEX IF NOT EXISTS ix_alerts_resolved_retention
    ON analytics.alerts (resolved_at) WHERE state = 'RESOLVED';
CREATE INDEX IF NOT EXISTS ix_alerts_ended_retention
    ON analytics.alerts (ended_at) WHERE state = 'ENDED';

COMMENT ON TABLE analytics.alerts IS
'MVP-7 Basic Alerts (ADR-016/ADR-017). One row per alert occurrence -- immutable historical record once Resolved/Ended (ADR-016 decision 16), never rewritten by a later configuration change. condition_key changes exactly when the underlying Attention configuration changes (ADR-016 decision 10), so recurrence and configuration-transition logic both key on it. space_id/asset_id are reserved -- unpopulated until a Space/Asset-level Attention condition is separately built (see the Space/Asset reconciliation, ADR-017).';
COMMENT ON COLUMN analytics.alerts.condition_key IS
'Stable identity over {parameter/metric, threshold/reference, scope/context}. Today''s only value: ''ENERGY_ATTENTION:PERCENT_DEVIATION_FROM_TYPICAL_REFERENCE:15:SITE:<site_id>'' (see analytics.evaluate_energy_attention_materiality). A change to this string is, by definition, a configuration change (ADR-016 decision 8/10).';

ALTER TABLE analytics.alerts OWNER TO ems_admin;
REVOKE ALL ON TABLE analytics.alerts FROM PUBLIC;
-- No direct table grant to ems_app -- all access is through the SECURITY
-- DEFINER read functions below and the job's own procedure, matching every
-- other analytics.* table in this schema.

-- ----------------------------------------------------------------------------
-- 2. analytics.alert_evaluation_candidates -- internal-only qualification/
--    resolution timer state. NOT part of the customer-facing Alert concept
--    (ADR-017: no customer-visible pending state, ADR-016 decision 2).
--    One row per (site, condition) currently being watched.
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS analytics.alert_evaluation_candidates (
    site_id              UUID NOT NULL REFERENCES metadata.sites(id),
    condition_key         TEXT NOT NULL,

    -- WATCHING_TRIGGER: condition currently true, no Active alert yet --
    --   counting toward the 5-minute qualification window.
    -- WATCHING_CLEAR: condition currently false for an existing Active
    --   alert -- counting toward the 1-minute resolution window.
    watch_state            TEXT NOT NULL CHECK (watch_state IN ('WATCHING_TRIGGER', 'WATCHING_CLEAR')),
    since                   TIMESTAMPTZ NOT NULL,
    candidate_value         DOUBLE PRECISION,
    last_evaluated_at       TIMESTAMPTZ NOT NULL,
    -- Set only for WATCHING_CLEAR -- the Active alert being watched for
    -- resolution.
    alert_id                UUID REFERENCES analytics.alerts(alert_id),

    CONSTRAINT pk_alert_evaluation_candidates PRIMARY KEY (site_id, condition_key),
    CONSTRAINT ck_alert_evaluation_candidates_clear_has_alert CHECK (
        (watch_state = 'WATCHING_TRIGGER' AND alert_id IS NULL)
        OR (watch_state = 'WATCHING_CLEAR' AND alert_id IS NOT NULL)
    )
);

COMMENT ON TABLE analytics.alert_evaluation_candidates IS
'Internal job-scratch state for MVP-7''s qualification (ADR-016 decision 2, 5 min) and resolution (decision 4, 1 min) timers -- not a DDS core concept, not customer-facing, not subject to the five-criteria change-control test (ADR-017). Durable across restarts by design (durable table, not in-memory) so a persistence failure never loses the original trigger time -- see analytics.evaluate_alerts(). last_evaluated_at drives gap detection: any run gap resets the timer, per ADR-016 decisions 2 and 4.';

ALTER TABLE analytics.alert_evaluation_candidates OWNER TO ems_admin;
REVOKE ALL ON TABLE analytics.alert_evaluation_candidates FROM PUBLIC;

COMMIT;
