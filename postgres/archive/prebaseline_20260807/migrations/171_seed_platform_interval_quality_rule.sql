-- ============================================================================
-- Migration:
--   171_seed_platform_interval_quality_rule.sql
--
-- Purpose:
--   Restore the required platform fallback interval-quality rule in databases
--   that were upgraded before the canonical seed was added.
--
-- Resolution precedence remains:
--   DEVICE -> PROFILE -> SITE -> ORGANIZATION -> PLATFORM
--
-- This migration is idempotent and inserts no row when an effective active
-- platform rule already exists.
-- ============================================================================

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
