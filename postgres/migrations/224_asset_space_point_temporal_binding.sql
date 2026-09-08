-- ============================================================================
-- Migration 224
-- Phase 2 (Subject Binding and Relationship Foundation), Slice 2A only:
-- retrofit metadata.asset_points with effective-dating + a single-owner
-- temporal exclusion, and create metadata.space_points with the same shape
-- for space-mounted sensors (CO2, occupancy) that describe a room rather
-- than a piece of equipment.
--
-- Source of record: docs/DDS/analytics-platform-future-state-architecture.md
-- §B.3, docs/DDS/analytics-platform-future-state-architecture-implementation-
-- roadmap.md "Phase 2 -- Subject Binding and Relationship Foundation", and
-- the Slice 2A design-checkpoint/final-design-review conversation that
-- preceded this migration.
--
-- Effective-dating model (both tables): modeled directly on the live,
-- proven config.site_energy_meter_roles idiom (postgres/ddl/85) --
-- effective_from/effective_to + a GENERATED STORED tstzrange + a GiST
-- EXCLUDE constraint. Unlike that precedent, no is_active column is added
-- here (deliberately -- effective_to alone represents "this binding has
-- ended"; see the design review) and the exclusion key does NOT include
-- asset_id/space_id.
--
-- EXCLUSION KEY DECISION (explicit, not incidental): the GiST exclusion on
-- both tables is scoped to (logical_point_id, effective_range) only --
-- asset_id/space_id is deliberately NOT part of the key. A logical point
-- must not be simultaneously owned by two different Subjects during
-- overlapping periods; scoping the key per-owner (as the architecture
-- doc's own prose literally says, "the same (subject, logical_point_id)")
-- would only catch the SAME owner double-claiming the point and would
-- silently allow two DIFFERENT assets to claim the same point over an
-- overlapping window. This was raised as an open question at the design
-- checkpoint and resolved explicitly: exclude asset_id/space_id from the
-- key so that any temporal overlap for a given point is rejected
-- regardless of which owner(s) are involved.
--
-- Explicitly OUT OF SCOPE (Slice 2B or later, not touched by this
-- migration): metadata.asset_relationships, metadata.asset_space_
-- relationships, any relationship-type registry, metadata.assets.
-- asset_nature, metadata.assets.space_id, metadata.asset_devices,
-- assets.parent_asset_id, any energy table/job/procedure, telemetry
-- ingestion, routing, Grafana, application/API/frontend code. No
-- cross-table (asset_points vs space_points) exclusivity is enforced --
-- whether a point may simultaneously belong to both an Asset and a Space
-- is a separate, deliberately unresolved semantic question. No live data
-- backfill: metadata.asset_points has zero existing rows (verified --
-- no seed or migration has ever inserted into it) and metadata.space_points
-- is new, so both start/remain empty until a separately-authorized
-- commissioning step populates them.
-- ============================================================================


-- ----------------------------------------------------------------------------
-- 1. Retrofit metadata.asset_points.
--    All existing columns, keys, foreign keys, and indexes are preserved
--    unchanged. The table has zero existing rows, so no backfill is
--    required and the new NOT NULL column's default cannot conflict with
--    any pre-existing data.
-- ----------------------------------------------------------------------------

ALTER TABLE metadata.asset_points
    ADD COLUMN IF NOT EXISTS effective_from TIMESTAMPTZ NOT NULL DEFAULT '-infinity',
    ADD COLUMN IF NOT EXISTS effective_to   TIMESTAMPTZ,
    ADD COLUMN IF NOT EXISTS effective_range TSTZRANGE GENERATED ALWAYS AS
        (tstzrange(effective_from, COALESCE(effective_to, 'infinity'), '[)')) STORED;

ALTER TABLE metadata.asset_points
    DROP CONSTRAINT IF EXISTS ck_asset_points_effective_window;

ALTER TABLE metadata.asset_points
    ADD CONSTRAINT ck_asset_points_effective_window
    CHECK (effective_to IS NULL OR effective_to > effective_from);

DO
$$
BEGIN
    IF NOT EXISTS (
        SELECT 1
        FROM pg_constraint
        WHERE conname = 'ex_asset_points_no_overlap'
          AND conrelid = 'metadata.asset_points'::regclass
    ) THEN
        ALTER TABLE metadata.asset_points
        ADD CONSTRAINT ex_asset_points_no_overlap
        EXCLUDE USING gist
        (
            logical_point_id WITH =,
            effective_range WITH &&
        );
    END IF;
END;
$$;

CREATE INDEX IF NOT EXISTS idx_asset_points_point_effective
    ON metadata.asset_points (logical_point_id, effective_from DESC);

COMMENT ON COLUMN metadata.asset_points.effective_from IS
'Start of the period this point was bound to this asset. Migration 224.';
COMMENT ON COLUMN metadata.asset_points.effective_to IS
'End of the binding period, exclusive; NULL = still current. Migration 224.';
COMMENT ON COLUMN metadata.asset_points.effective_range IS
'Generated [effective_from, effective_to) range; the exclusion-constraint target. Never set directly. Migration 224.';


-- ----------------------------------------------------------------------------
-- 2. Create metadata.space_points.
--    Same shape as the retrofitted asset_points, space_id in place of
--    asset_id, for sensors that describe a room rather than equipment.
-- ----------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS metadata.space_points
(
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),

    space_id UUID NOT NULL
        REFERENCES metadata.spaces(id),

    logical_point_id UUID NOT NULL
        REFERENCES metadata.logical_points(id),

    point_role TEXT,

    effective_from TIMESTAMPTZ NOT NULL DEFAULT '-infinity',
    effective_to   TIMESTAMPTZ,
    effective_range TSTZRANGE GENERATED ALWAYS AS
        (tstzrange(effective_from, COALESCE(effective_to, 'infinity'), '[)')) STORED,

    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),

    CONSTRAINT ck_space_points_effective_window
        CHECK (effective_to IS NULL OR effective_to > effective_from)
);

DO
$$
BEGIN
    IF NOT EXISTS (
        SELECT 1
        FROM pg_constraint
        WHERE conname = 'ex_space_points_no_overlap'
          AND conrelid = 'metadata.space_points'::regclass
    ) THEN
        ALTER TABLE metadata.space_points
        ADD CONSTRAINT ex_space_points_no_overlap
        EXCLUDE USING gist
        (
            logical_point_id WITH =,
            effective_range WITH &&
        );
    END IF;
END;
$$;

CREATE INDEX IF NOT EXISTS idx_space_points_space
    ON metadata.space_points (space_id);

CREATE INDEX IF NOT EXISTS idx_space_points_point_effective
    ON metadata.space_points (logical_point_id, effective_from DESC);

COMMENT ON TABLE metadata.space_points IS
'Phase 2 Slice 2A: effective-dated binding of a logical point to a Space (room-level sensors -- CO2, occupancy) rather than an Asset. Migration 224.';


-- ----------------------------------------------------------------------------
-- 3. Postconditions -- fail the transaction loudly if the intended end
--    state was not reached, per the migration 198/199/219/223 "fail loudly
--    on partial reference data" discipline.
-- ----------------------------------------------------------------------------

DO
$$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema = 'metadata' AND table_name = 'asset_points'
          AND column_name = 'effective_range'
    ) THEN
        RAISE EXCEPTION
            'Migration 224 postcondition failed: metadata.asset_points.effective_range was not created.';
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conname = 'ck_asset_points_effective_window'
          AND conrelid = 'metadata.asset_points'::regclass
    ) THEN
        RAISE EXCEPTION
            'Migration 224 postcondition failed: ck_asset_points_effective_window was not created.';
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conname = 'ex_asset_points_no_overlap'
          AND conrelid = 'metadata.asset_points'::regclass
    ) THEN
        RAISE EXCEPTION
            'Migration 224 postcondition failed: ex_asset_points_no_overlap was not created.';
    END IF;

    IF to_regclass('metadata.space_points') IS NULL THEN
        RAISE EXCEPTION
            'Migration 224 postcondition failed: metadata.space_points was not created.';
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conname = 'ck_space_points_effective_window'
          AND conrelid = 'metadata.space_points'::regclass
    ) THEN
        RAISE EXCEPTION
            'Migration 224 postcondition failed: ck_space_points_effective_window was not created.';
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conname = 'ex_space_points_no_overlap'
          AND conrelid = 'metadata.space_points'::regclass
    ) THEN
        RAISE EXCEPTION
            'Migration 224 postcondition failed: ex_space_points_no_overlap was not created.';
    END IF;
END;
$$;
