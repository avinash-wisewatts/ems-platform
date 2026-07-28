-- ============================================================================
-- File:
--   83_interval_quality_rules.sql
--
-- Epic:
--   Epic 4 — Core Energy Analytics
--
-- Story:
--   4.2 — Configurable interval quality rules
--
-- Purpose:
--   Replace the hard-coded 30-minute telemetry-gap threshold with declarative,
--   effective-dated rules resolved using this precedence:
--
--       DEVICE
--       PROFILE
--       SITE
--       ORGANIZATION
--       PLATFORM
--
-- Device-to-site resolution:
--
--       metadata.devices.gateway_id
--           -> metadata.gateways.site_id
--
-- Multi-tenancy:
--   Device, gateway, site and organization identities remain database-backed.
--   No tenant identifier is accepted from Grafana or application input.
-- ============================================================================


-- Required for equality + timestamp-range exclusion constraints.
CREATE EXTENSION IF NOT EXISTS btree_gist;


CREATE TABLE IF NOT EXISTS config.interval_quality_rules
(
    id UUID PRIMARY KEY
        DEFAULT gen_random_uuid(),

    -- Exactly zero or one selector is allowed:
    --
    --   all NULL        = PLATFORM
    --   organization_id = ORGANIZATION
    --   site_id         = SITE
    --   profile_id      = PROFILE
    --   device_id       = DEVICE

    organization_id UUID NULL
        REFERENCES metadata.organizations(id)
        ON DELETE CASCADE,

    site_id UUID NULL
        REFERENCES metadata.sites(id)
        ON DELETE CASCADE,

    profile_id UUID NULL
        REFERENCES config.device_profiles(id)
        ON DELETE CASCADE,

    device_id UUID NULL
        REFERENCES metadata.devices(id)
        ON DELETE CASCADE,

    gap_threshold_minutes NUMERIC(12, 3) NOT NULL,

    effective_from TIMESTAMPTZ NOT NULL
        DEFAULT '-infinity'::TIMESTAMPTZ,

    effective_to TIMESTAMPTZ NULL,

    is_active BOOLEAN NOT NULL
        DEFAULT TRUE,

    description TEXT NULL,

    created_at TIMESTAMPTZ NOT NULL
        DEFAULT now(),

    updated_at TIMESTAMPTZ NOT NULL
        DEFAULT now(),

    scope_type TEXT GENERATED ALWAYS AS
    (
        CASE
            WHEN device_id IS NOT NULL
                THEN 'DEVICE'
            WHEN profile_id IS NOT NULL
                THEN 'PROFILE'
            WHEN site_id IS NOT NULL
                THEN 'SITE'
            WHEN organization_id IS NOT NULL
                THEN 'ORGANIZATION'
            ELSE 'PLATFORM'
        END
    ) STORED,

    scope_key TEXT GENERATED ALWAYS AS
    (
        CASE
            WHEN device_id IS NOT NULL
                THEN 'DEVICE:' || device_id::TEXT
            WHEN profile_id IS NOT NULL
                THEN 'PROFILE:' || profile_id::TEXT
            WHEN site_id IS NOT NULL
                THEN 'SITE:' || site_id::TEXT
            WHEN organization_id IS NOT NULL
                THEN 'ORGANIZATION:' || organization_id::TEXT
            ELSE 'PLATFORM'
        END
    ) STORED,

    effective_range TSTZRANGE GENERATED ALWAYS AS
    (
        tstzrange
        (
            effective_from,
            COALESCE
            (
                effective_to,
                'infinity'::TIMESTAMPTZ
            ),
            '[)'
        )
    ) STORED,

    CONSTRAINT ck_interval_quality_one_scope
        CHECK
        (
            num_nonnulls
            (
                organization_id,
                site_id,
                profile_id,
                device_id
            ) <= 1
        ),

    CONSTRAINT ck_interval_quality_gap_positive
        CHECK
        (
            gap_threshold_minutes > 0
        ),

    CONSTRAINT ck_interval_quality_effective_window
        CHECK
        (
            effective_to IS NULL
            OR effective_to > effective_from
        )
);


-- Prevent two active rules for the same scope from covering the same instant.
--
-- This permits future-dated rules and historical rules while guaranteeing
-- deterministic resolution.

DO $$
BEGIN
    IF NOT EXISTS
    (
        SELECT 1
        FROM pg_constraint
        WHERE conname =
            'ex_interval_quality_no_active_overlap'
          AND conrelid =
            'config.interval_quality_rules'::regclass
    )
    THEN
        ALTER TABLE config.interval_quality_rules
        ADD CONSTRAINT ex_interval_quality_no_active_overlap
        EXCLUDE USING gist
        (
            scope_key WITH =,
            effective_range WITH &&
        )
        WHERE
        (
            is_active
        );
    END IF;
END;
$$;


CREATE INDEX IF NOT EXISTS
    ix_interval_quality_rules_device
ON config.interval_quality_rules
(
    device_id,
    effective_from DESC
)
WHERE
    is_active
    AND device_id IS NOT NULL;


CREATE INDEX IF NOT EXISTS
    ix_interval_quality_rules_profile
ON config.interval_quality_rules
(
    profile_id,
    effective_from DESC
)
WHERE
    is_active
    AND profile_id IS NOT NULL;


CREATE INDEX IF NOT EXISTS
    ix_interval_quality_rules_site
ON config.interval_quality_rules
(
    site_id,
    effective_from DESC
)
WHERE
    is_active
    AND site_id IS NOT NULL;


CREATE INDEX IF NOT EXISTS
    ix_interval_quality_rules_organization
ON config.interval_quality_rules
(
    organization_id,
    effective_from DESC
)
WHERE
    is_active
    AND organization_id IS NOT NULL;


COMMENT ON TABLE config.interval_quality_rules IS
'Effective-dated hierarchical interval-quality rules resolved from device through platform scope.';


COMMENT ON COLUMN config.interval_quality_rules.gap_threshold_minutes IS
'Elapsed minutes above which a valid cumulative-register interval is classified as GAP.';


COMMENT ON COLUMN config.interval_quality_rules.scope_key IS
'Generated unique resolution key used to prevent overlapping active rules within the same scope.';


-- ----------------------------------------------------------------------------
-- Seed the platform default.
-- ----------------------------------------------------------------------------

INSERT INTO config.interval_quality_rules
(
    gap_threshold_minutes,
    effective_from,
    effective_to,
    is_active,
    description
)
SELECT
    30,
    '-infinity'::TIMESTAMPTZ,
    NULL,
    TRUE,
    'Platform default: classify elapsed intervals greater than 30 minutes as GAP.'
WHERE NOT EXISTS
(
    SELECT 1
    FROM config.interval_quality_rules
    WHERE scope_type = 'PLATFORM'
      AND is_active = TRUE
      AND effective_range @> now()
);


-- ----------------------------------------------------------------------------
-- Deterministic rule resolver.
--
-- Resolution order:
--   1. DEVICE
--   2. PROFILE
--   3. SITE
--   4. ORGANIZATION
--   5. PLATFORM
--
-- The function returns exactly one row when the platform default exists.
-- ----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION config.resolve_interval_quality_rule
(
    p_device_id UUID,
    p_effective_at TIMESTAMPTZ DEFAULT now()
)
RETURNS TABLE
(
    rule_id UUID,
    gap_threshold_minutes NUMERIC,
    resolved_scope TEXT,
    scope_key TEXT,
    effective_from TIMESTAMPTZ,
    effective_to TIMESTAMPTZ
)
LANGUAGE sql
STABLE
PARALLEL SAFE
AS $function$
    WITH device_context AS
    (
        SELECT
            d.id AS device_id,
            d.profile_id,
            d.organization_id,
            g.site_id
        FROM metadata.devices d

        LEFT JOIN metadata.gateways g
          ON g.id = d.gateway_id

        WHERE d.id = p_device_id
    ),

    candidates AS
    (
        SELECT
            r.id,
            r.gap_threshold_minutes,
            r.scope_type,
            r.scope_key,
            r.effective_from,
            r.effective_to,
            1 AS precedence

        FROM config.interval_quality_rules r
        JOIN device_context dc
          ON r.device_id = dc.device_id

        WHERE r.is_active = TRUE
          AND r.effective_range @> p_effective_at

        UNION ALL

        SELECT
            r.id,
            r.gap_threshold_minutes,
            r.scope_type,
            r.scope_key,
            r.effective_from,
            r.effective_to,
            2

        FROM config.interval_quality_rules r
        JOIN device_context dc
          ON r.profile_id = dc.profile_id

        WHERE r.is_active = TRUE
          AND r.effective_range @> p_effective_at

        UNION ALL

        SELECT
            r.id,
            r.gap_threshold_minutes,
            r.scope_type,
            r.scope_key,
            r.effective_from,
            r.effective_to,
            3

        FROM config.interval_quality_rules r
        JOIN device_context dc
          ON r.site_id = dc.site_id

        WHERE r.is_active = TRUE
          AND r.effective_range @> p_effective_at

        UNION ALL

        SELECT
            r.id,
            r.gap_threshold_minutes,
            r.scope_type,
            r.scope_key,
            r.effective_from,
            r.effective_to,
            4

        FROM config.interval_quality_rules r
        JOIN device_context dc
          ON r.organization_id = dc.organization_id

        WHERE r.is_active = TRUE
          AND r.effective_range @> p_effective_at

        UNION ALL

        SELECT
            r.id,
            r.gap_threshold_minutes,
            r.scope_type,
            r.scope_key,
            r.effective_from,
            r.effective_to,
            5

        FROM config.interval_quality_rules r

        WHERE r.scope_type = 'PLATFORM'
          AND r.is_active = TRUE
          AND r.effective_range @> p_effective_at
    )

    SELECT
        c.id,
        c.gap_threshold_minutes,
        c.scope_type,
        c.scope_key,
        c.effective_from,
        c.effective_to
    FROM candidates c
    ORDER BY
        c.precedence,
        c.effective_from DESC,
        c.id
    LIMIT 1;
$function$;


COMMENT ON FUNCTION config.resolve_interval_quality_rule
(
    UUID,
    TIMESTAMPTZ
)
IS
'Resolves the effective interval-quality rule using device, profile, site, organization and platform precedence.';


REVOKE ALL
ON config.interval_quality_rules
FROM PUBLIC;


REVOKE ALL
ON FUNCTION config.resolve_interval_quality_rule
(
    UUID,
    TIMESTAMPTZ
)
FROM PUBLIC;


GRANT EXECUTE
ON FUNCTION config.resolve_interval_quality_rule
(
    UUID,
    TIMESTAMPTZ
)
TO grafana_reader;
