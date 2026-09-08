-- ============================================================================
-- Migration 225
-- Phase 2 (Subject Binding and Relationship Foundation), Slice 2B-i + 2B-ii:
-- typed, effective-dated Asset <-> Asset relationship graph.
--
-- Source of record: docs/DDS/analytics-platform-future-state-architecture.md
-- SB.4, docs/DDS/analytics-platform-future-state-architecture-implementation-
-- roadmap.md "Phase 2 -- Subject Binding and Relationship Foundation", and
-- the Slice 2B design-checkpoint / architecture-clarification conversation
-- that preceded this migration.
--
-- Modeled directly on the live, proven metadata.asset_devices +
-- config.asset_device_relationship_types pattern (postgres/ddl/92):
-- a seeded controlled-vocabulary table, the same trigger-enforcement style,
-- and the same "reject on mismatch, do not silently coerce" discipline. The
-- one explicitly-approved deviation is temporal exclusivity: this graph
-- adds effective-dating (unlike asset_devices, which has none), because the
-- architecture calls for it here.
--
-- APPROVED DECISIONS (design-checkpoint conversation; not re-decided here):
--   * Exactly four relationship types: COMPONENT_OF, DRIVEN_BY, SUPPLIED_BY,
--     PART_OF. No others.
--   * All four use directionality = HIERARCHICAL_UP. For DRIVEN_BY/
--     SUPPLIED_BY this is an implementation convention (internal
--     consistency with COMPONENT_OF/PART_OF's cycle-walk direction), not an
--     architecture mandate -- documented, not silently assumed.
--   * from_asset = the dependent/component/driven/supplied asset;
--     to_asset = the whole/driver/supplier. Example: Fan -[DRIVEN_BY]-> Motor.
--   * assets.parent_asset_id and assets.space_id: both explicitly kept
--     unchanged. AssetRelationship is an ADDITIONAL typed graph, not a
--     replacement for the existing simple parent tree.
--   * No LOCATED_IN, no AssetSpaceRelationship, no compatibility-table
--     infrastructure in this slice -- all explicitly deferred.
--   * Temporal exclusivity ONLY for DRIVEN_BY (the architecture's own named
--     example: "a Fan has exactly one DRIVEN_BY motor at a time").
--     COMPONENT_OF, SUPPLIED_BY, PART_OF are NOT assumed exclusive.
--   * Cycle prevention scoped per relationship_type (the existing
--     trg_validate_asset_hierarchy is explicitly single-parent-tree-shaped
--     and cannot be reused for this M:N graph).
--   * No live data backfill -- both new tables start and remain empty.
--
-- Explicitly NOT touched: assets.parent_asset_id, assets.space_id,
-- metadata.asset_devices, any energy table/job/procedure, telemetry
-- ingestion, routing, Grafana, application/API/frontend code,
-- AssetSpaceRelationship, any relationship-type compatibility table.
-- ============================================================================


-- ----------------------------------------------------------------------------
-- 1. Relationship-type registry.
-- ----------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS config.asset_relationship_types (
    code             TEXT PRIMARY KEY,
    name             TEXT NOT NULL,
    description      TEXT NOT NULL,
    directionality   TEXT NOT NULL
        CHECK (directionality IN ('HIERARCHICAL_UP', 'HIERARCHICAL_DOWN', 'SYMMETRIC')),
    exclusivity_policy TEXT NOT NULL
        CHECK (exclusivity_policy IN ('NON_EXCLUSIVE', 'FROM_ASSET_EXCLUSIVE')),
    is_active        BOOLEAN NOT NULL DEFAULT TRUE,
    display_order    INTEGER NOT NULL
);

COMMENT ON TABLE config.asset_relationship_types IS
'Phase 2 Slice 2B: controlled vocabulary for metadata.asset_relationships, modeled on config.asset_device_relationship_types. Migration 225.';

INSERT INTO config.asset_relationship_types (code, name, description, directionality, exclusivity_policy, display_order)
VALUES
    ('COMPONENT_OF', 'Component of', 'from_asset is a physical component of to_asset (e.g. a bearing of a motor).', 'HIERARCHICAL_UP', 'NON_EXCLUSIVE', 10),
    ('DRIVEN_BY',    'Driven by',    'from_asset is mechanically driven by to_asset (e.g. a fan driven by a motor). At most one active driver per driven asset at any time.', 'HIERARCHICAL_UP', 'FROM_ASSET_EXCLUSIVE', 20),
    ('SUPPLIED_BY',  'Supplied by',  'from_asset is electrically/functionally supplied by to_asset (e.g. an AHU supplied by an electrical panel).', 'HIERARCHICAL_UP', 'NON_EXCLUSIVE', 30),
    ('PART_OF',      'Part of',      'from_asset is a constituent part of the larger to_asset.', 'HIERARCHICAL_UP', 'NON_EXCLUSIVE', 40)
ON CONFLICT (code) DO UPDATE
SET name = EXCLUDED.name,
    description = EXCLUDED.description,
    directionality = EXCLUDED.directionality,
    exclusivity_policy = EXCLUDED.exclusivity_policy,
    display_order = EXCLUDED.display_order;


-- ----------------------------------------------------------------------------
-- 2. metadata.asset_relationships -- typed, effective-dated, M:N graph.
--    Modeled on config.site_energy_meter_roles / migration 224's temporal
--    idiom, deliberately without an is_active column (effective_to alone
--    represents "this relationship has ended").
-- ----------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS metadata.asset_relationships (
    id                UUID PRIMARY KEY DEFAULT gen_random_uuid(),

    organization_id   UUID NOT NULL
        REFERENCES metadata.organizations(id),

    from_asset_id     UUID NOT NULL
        REFERENCES metadata.assets(id),

    to_asset_id       UUID NOT NULL
        REFERENCES metadata.assets(id),

    relationship_type TEXT NOT NULL
        REFERENCES config.asset_relationship_types(code),

    effective_from    TIMESTAMPTZ NOT NULL DEFAULT '-infinity',
    effective_to      TIMESTAMPTZ,
    effective_range   TSTZRANGE GENERATED ALWAYS AS
        (tstzrange(effective_from, COALESCE(effective_to, 'infinity'), '[)')) STORED,

    created_at        TIMESTAMPTZ NOT NULL DEFAULT now(),

    CONSTRAINT ck_asset_relationships_no_self
        CHECK (from_asset_id <> to_asset_id),
    CONSTRAINT ck_asset_relationships_effective_window
        CHECK (effective_to IS NULL OR effective_to > effective_from)
);

COMMENT ON TABLE metadata.asset_relationships IS
'Phase 2 Slice 2B: typed, effective-dated Asset<->Asset relationship graph (M:N). Additional to, not a replacement for, assets.parent_asset_id. Migration 225.';
COMMENT ON COLUMN metadata.asset_relationships.from_asset_id IS
'The dependent/component/driven/supplied asset (e.g. the Fan in Fan DRIVEN_BY Motor).';
COMMENT ON COLUMN metadata.asset_relationships.to_asset_id IS
'The whole/driver/supplier asset (e.g. the Motor in Fan DRIVEN_BY Motor).';

-- Temporal exclusivity: DRIVEN_BY only, per the approved design. Scoped to
-- (from_asset_id, effective_range) -- at most one active driver per driven
-- asset at any point in time. Idempotent add, mirroring migration 224's
-- pg_constraint-guarded pattern.
DO
$$
BEGIN
    IF NOT EXISTS (
        SELECT 1
        FROM pg_constraint
        WHERE conname = 'ex_asset_relationships_driven_by_exclusive'
          AND conrelid = 'metadata.asset_relationships'::regclass
    ) THEN
        ALTER TABLE metadata.asset_relationships
        ADD CONSTRAINT ex_asset_relationships_driven_by_exclusive
        EXCLUDE USING gist
        (
            from_asset_id WITH =,
            effective_range WITH &&
        )
        WHERE (relationship_type = 'DRIVEN_BY');
    END IF;
END;
$$;

CREATE INDEX IF NOT EXISTS idx_asset_relationships_from
    ON metadata.asset_relationships (from_asset_id, relationship_type, effective_from DESC);

CREATE INDEX IF NOT EXISTS idx_asset_relationships_to
    ON metadata.asset_relationships (to_asset_id, relationship_type, effective_from DESC);


-- ----------------------------------------------------------------------------
-- 3. Tenant-safety + type-scoped cycle-prevention trigger.
--    Tenant check modeled directly on metadata.validate_asset_device_
--    relationship (postgres/ddl/92) -- reject on organization_id mismatch,
--    never silently coerce. Cycle check is new (the existing trg_validate_
--    asset_hierarchy is single-parent-tree-shaped and explicitly cannot be
--    reused for this M:N graph); it walks forward from the proposed
--    to_asset_id through existing edges of the SAME relationship_type whose
--    effective_range overlaps the new row's, and rejects if that walk
--    reaches the proposed from_asset_id.
-- ----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION metadata.validate_asset_relationship()
RETURNS TRIGGER
LANGUAGE plpgsql
SET search_path TO pg_catalog, metadata, config
AS $function$
DECLARE
    v_from_org UUID;
    v_to_org   UUID;
    v_cycle_exists BOOLEAN;
    v_new_range TSTZRANGE;
BEGIN
    -- NEW.effective_range is a GENERATED ALWAYS ... STORED column and is not
    -- yet computed inside a BEFORE trigger (it reads as NULL here), so it is
    -- recomputed from the raw input columns using the same expression as the
    -- generated column, for use in the cycle-detection overlap check below.
    v_new_range := tstzrange(NEW.effective_from, COALESCE(NEW.effective_to, 'infinity'), '[)');

    SELECT organization_id INTO v_from_org FROM metadata.assets WHERE id = NEW.from_asset_id;
    SELECT organization_id INTO v_to_org   FROM metadata.assets WHERE id = NEW.to_asset_id;

    -- Both columns already carry REFERENCES metadata.assets(id). If either
    -- asset does not exist, defer to that FK constraint (standard
    -- foreign_key_violation / 23503) rather than raising a custom error here
    -- -- this BEFORE trigger would otherwise pre-empt it.
    IF v_from_org IS NULL OR v_to_org IS NULL THEN
        RETURN NEW;
    END IF;

    IF v_from_org IS DISTINCT FROM v_to_org THEN
        RAISE EXCEPTION
            'Assets in a relationship must belong to the same organization (from: %, to: %).',
            v_from_org, v_to_org;
    END IF;

    -- The row's own organization_id is redundant (derivable from either
    -- asset) and must never be allowed to drift from the assets' actual
    -- organization. Modeled on trg_validate_asset_hierarchy's parent_asset_id
    -- vs. NEW.organization_id check (postgres/ddl/87_asset_hierarchy_
    -- closure.sql) -- the existing table facing this exact same shape of
    -- problem, since metadata.asset_devices (this migration's other cited
    -- precedent) has no organization_id column at all and so never had to
    -- solve it.
    IF NEW.organization_id IS DISTINCT FROM v_from_org THEN
        RAISE EXCEPTION
            'Relationship organization_id (%) does not match the owning organization of its assets (%).',
            NEW.organization_id, v_from_org;
    END IF;

    -- Type-scoped cycle prevention (all four approved types are
    -- HIERARCHICAL_UP; the check applies to every relationship_type this
    -- table accepts, since compatibility restriction is deferred and no
    -- non-hierarchical type is seeded in this migration).
    WITH RECURSIVE walk(asset_id) AS (
        SELECT NEW.to_asset_id
        UNION
        SELECT ar.to_asset_id
        FROM metadata.asset_relationships ar
        JOIN walk w ON ar.from_asset_id = w.asset_id
        WHERE ar.relationship_type = NEW.relationship_type
          AND ar.effective_range && v_new_range
    )
    SELECT EXISTS (SELECT 1 FROM walk WHERE asset_id = NEW.from_asset_id)
    INTO v_cycle_exists;

    IF v_cycle_exists THEN
        RAISE EXCEPTION
            'This % relationship (% -> %) would create a cycle.',
            NEW.relationship_type, NEW.from_asset_id, NEW.to_asset_id;
    END IF;

    RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS trg_validate_asset_relationship ON metadata.asset_relationships;
CREATE TRIGGER trg_validate_asset_relationship
BEFORE INSERT OR UPDATE OF organization_id, from_asset_id, to_asset_id, relationship_type, effective_from, effective_to
ON metadata.asset_relationships
FOR EACH ROW
EXECUTE FUNCTION metadata.validate_asset_relationship();

ALTER FUNCTION metadata.validate_asset_relationship() OWNER TO ems_admin;


-- ----------------------------------------------------------------------------
-- 4. Postconditions -- fail the transaction loudly if the intended end
--    state was not reached, per the migration 198/199/223/224 "fail loudly
--    on partial reference data" discipline.
-- ----------------------------------------------------------------------------

DO
$$
DECLARE
    v_type_count INTEGER;
BEGIN
    SELECT count(*) INTO v_type_count
    FROM config.asset_relationship_types
    WHERE code IN ('COMPONENT_OF', 'DRIVEN_BY', 'SUPPLIED_BY', 'PART_OF');

    IF v_type_count <> 4 THEN
        RAISE EXCEPTION
            'Migration 225 postcondition failed: expected exactly 4 config.asset_relationship_types rows, found %.',
            v_type_count;
    END IF;

    IF to_regclass('metadata.asset_relationships') IS NULL THEN
        RAISE EXCEPTION
            'Migration 225 postcondition failed: metadata.asset_relationships was not created.';
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conname = 'ex_asset_relationships_driven_by_exclusive'
          AND conrelid = 'metadata.asset_relationships'::regclass
    ) THEN
        RAISE EXCEPTION
            'Migration 225 postcondition failed: ex_asset_relationships_driven_by_exclusive was not created.';
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM pg_trigger
        WHERE tgname = 'trg_validate_asset_relationship'
          AND tgrelid = 'metadata.asset_relationships'::regclass
    ) THEN
        RAISE EXCEPTION
            'Migration 225 postcondition failed: trg_validate_asset_relationship was not created.';
    END IF;

    IF (SELECT count(*) FROM metadata.asset_relationships) <> 0 THEN
        RAISE EXCEPTION
            'Migration 225 postcondition failed: metadata.asset_relationships must start empty (no backfill authorized).';
    END IF;
END;
$$;
