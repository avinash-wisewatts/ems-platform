-- ============================================================================
-- Migration 252
-- Corrective migration for migration 250: extends the CHECK constraints on
-- analytics.demand_intervals and analytics.demand_state to accept the
-- SOURCE_BOUNDARY quality_status (and its NONE source_method) that
-- migration 250 introduced for analytics.calculate_demand_window's ASSET-
-- scope "no single confirmed source spans the interval" result.
--
-- Background: migration 250's own commentary states "quality_status has no
-- CHECK constraint (verified this session)" -- that is incorrect. Both
-- demand_intervals_quality_chk and demand_state_quality_chk (created by
-- migration 011, never altered since) enumerate a fixed, closed list of
-- values that does NOT include 'SOURCE_BOUNDARY'; demand_intervals_
-- source_method_chk (also migration 011) likewise does not include 'NONE',
-- the source_method migration 250's SOURCE_BOUNDARY row uses
-- (calculate_demand_window's ASSET branch, "no source" return:
-- source_method='NONE'::TEXT, quality_status='SOURCE_BOUNDARY'::TEXT,
-- demand_kw/demand_kva/source_device_id all NULL -- identical shape on the
-- analytics.demand_state live-state write via refresh_demand_analytics).
--
-- Found during this session's read-only staging verification of the Demand
-- deployment (migrations 250/251): confirmed live via pg_constraint that
-- both CHECK constraints are still exactly as migration 011 created them.
-- Not yet observed as a live failure on staging -- migration 250 also
-- switched analytics.refresh_demand_analytics' ASSET-scope enumeration to
-- metadata.asset_points (also migration 250), and staging currently has
-- zero metadata.asset_points rows, so no asset is currently enumerated for
-- calculation at all; the SOURCE_BOUNDARY finalize INSERT this migration
-- fixes has therefore never actually been attempted yet. It is a certainty
-- the moment any asset gets, then loses or changes, a confirmed metadata.
-- asset_points binding: analytics.refresh_demand_analytics has no
-- exception handling and SITE/ASSET scope share one transaction per job
-- run, so the unhandled CHECK violation would abort the entire job run
-- (all sites, both scopes) and stall the watermark (migration 210).
--
-- Verified this session, read-only, that adding these two values is
-- sufficient and that nothing else rejects them:
--   * No triggers exist on analytics.demand_intervals or analytics.
--     demand_state (pg_trigger, tgisinternal=false: zero rows).
--   * quality_status/source_method are plain TEXT columns (no native ENUM
--     type to extend).
--   * No other CHECK constraint, view, or function references a closed
--     quality_status/source_method list that would exclude these two
--     values -- migration 250's own CASE expressions (the demand_state
--     write, and the PROVISIONAL->INCOMPLETE finalize mapping) already
--     pass 'SOURCE_BOUNDARY' through unchanged; the only rejection point
--     is the three CHECK constraints fixed here.
--   * app/src/analytics_api_service.py types quality_status as a plain
--     Pydantic `str` (no Literal/enum restriction).
--   * web/src/api/types.ts types quality_status as a plain `string`, and
--     web/src/routes/demand/DemandOverview.tsx's demandStatusLabel/
--     demandStatusExplanation already fall back to "Data unavailable" for
--     any value absent from their label map (SOURCE_BOUNDARY is absent
--     today) -- no frontend change required for this to render safely.
--
-- Scope: exactly the three constraint definitions below. Does NOT touch
-- migration 250/251's function bodies, does NOT populate/commission
-- metadata.asset_points (a separate, tracked gap -- see this session's
-- staging verification report), and makes no other change.
--
-- Rollback: DROP the three constraints added here and re-add the original
-- migration-011 bodies (five-value quality_status lists, three-value
-- source_method list) -- safe only once no persisted row uses
-- SOURCE_BOUNDARY/NONE.
-- ============================================================================

BEGIN;

-- ----------------------------------------------------------------------------
-- 1. analytics.demand_intervals -- add SOURCE_BOUNDARY to quality_status,
--    NONE to source_method. CHECK constraints cannot be altered in place in
--    PostgreSQL (same drop/recreate pattern as migration 242's
--    ck_alerts_state_fields): drop and recreate.
-- ----------------------------------------------------------------------------

ALTER TABLE analytics.demand_intervals
    DROP CONSTRAINT demand_intervals_quality_chk;

ALTER TABLE analytics.demand_intervals
    ADD CONSTRAINT demand_intervals_quality_chk
    CHECK (
        quality_status IN (
            'VALID',
            'INCOMPLETE',
            'NO_DATA',
            'INVALID_SOURCE',
            'INSUFFICIENT_SOURCE_RESOLUTION',
            'SOURCE_BOUNDARY'
        )
    );

ALTER TABLE analytics.demand_intervals
    DROP CONSTRAINT demand_intervals_source_method_chk;

ALTER TABLE analytics.demand_intervals
    ADD CONSTRAINT demand_intervals_source_method_chk
    CHECK (
        source_method IN (
            'METER_NATIVE',
            'ENERGY_COUNTER_DELTA',
            'TIME_WEIGHTED_POWER',
            'NONE'
        )
    );

-- ----------------------------------------------------------------------------
-- 2. analytics.demand_state -- same addition to quality_status. This table
--    has no source_method column (current/open-interval state only carries
--    current_demand_kw/current_demand_kva), so there is no corresponding
--    source_method constraint to extend here.
-- ----------------------------------------------------------------------------

ALTER TABLE analytics.demand_state
    DROP CONSTRAINT demand_state_quality_chk;

ALTER TABLE analytics.demand_state
    ADD CONSTRAINT demand_state_quality_chk
    CHECK (
        quality_status IN (
            'PROVISIONAL',
            'INCOMPLETE',
            'NO_DATA',
            'INVALID_SOURCE',
            'INSUFFICIENT_SOURCE_RESOLUTION',
            'SOURCE_BOUNDARY'
        )
    );

-- ----------------------------------------------------------------------------
-- 3. Postconditions.
-- ----------------------------------------------------------------------------

DO $post$
DECLARE
    v_def TEXT;
BEGIN
    SELECT pg_get_constraintdef(oid) INTO v_def
    FROM pg_constraint
    WHERE conrelid = 'analytics.demand_intervals'::regclass
      AND conname = 'demand_intervals_quality_chk';
    IF v_def IS NULL OR position('''SOURCE_BOUNDARY''' IN v_def) = 0 THEN
        RAISE EXCEPTION 'Migration 252 postcondition failed: demand_intervals_quality_chk does not permit SOURCE_BOUNDARY.';
    END IF;
    IF position('''VALID''' IN v_def) = 0
       OR position('''INSUFFICIENT_SOURCE_RESOLUTION''' IN v_def) = 0 THEN
        RAISE EXCEPTION 'Migration 252 postcondition failed: demand_intervals_quality_chk lost a pre-existing value.';
    END IF;

    SELECT pg_get_constraintdef(oid) INTO v_def
    FROM pg_constraint
    WHERE conrelid = 'analytics.demand_intervals'::regclass
      AND conname = 'demand_intervals_source_method_chk';
    IF v_def IS NULL OR position('''NONE''' IN v_def) = 0 THEN
        RAISE EXCEPTION 'Migration 252 postcondition failed: demand_intervals_source_method_chk does not permit NONE.';
    END IF;
    IF position('''METER_NATIVE''' IN v_def) = 0
       OR position('''ENERGY_COUNTER_DELTA''' IN v_def) = 0
       OR position('''TIME_WEIGHTED_POWER''' IN v_def) = 0 THEN
        RAISE EXCEPTION 'Migration 252 postcondition failed: demand_intervals_source_method_chk lost a pre-existing value.';
    END IF;

    SELECT pg_get_constraintdef(oid) INTO v_def
    FROM pg_constraint
    WHERE conrelid = 'analytics.demand_state'::regclass
      AND conname = 'demand_state_quality_chk';
    IF v_def IS NULL OR position('''SOURCE_BOUNDARY''' IN v_def) = 0 THEN
        RAISE EXCEPTION 'Migration 252 postcondition failed: demand_state_quality_chk does not permit SOURCE_BOUNDARY.';
    END IF;
    IF position('''PROVISIONAL''' IN v_def) = 0
       OR position('''INSUFFICIENT_SOURCE_RESOLUTION''' IN v_def) = 0 THEN
        RAISE EXCEPTION 'Migration 252 postcondition failed: demand_state_quality_chk lost a pre-existing value.';
    END IF;

    RAISE NOTICE 'Migration 252: all postconditions passed (demand_intervals/demand_state now accept the SOURCE_BOUNDARY quality_status, and demand_intervals its NONE source_method).';
END;
$post$;

COMMIT;
