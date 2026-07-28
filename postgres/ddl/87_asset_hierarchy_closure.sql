-- ============================================================================
-- File:
--   87_asset_hierarchy_closure.sql
--
-- Epic:
--   Epic 4 — Core Energy Analytics
--
-- Story:
--   4.4 — Asset hierarchy rollups
--
-- Purpose:
--   1. Enforce valid same-tenant, same-site acyclic asset hierarchies.
--   2. Expose a recursive ancestor-to-descendant closure view.
--
-- Closure semantics:
--
--   depth = 0
--       The ancestor and descendant are the same asset.
--
--   depth = 1
--       The descendant is a direct child.
--
--   depth > 1
--       The descendant is reachable through multiple hierarchy levels.
--
-- The closure view is the canonical relationship source for downstream
-- direct-versus-descendant energy rollups.
-- ============================================================================


-- ----------------------------------------------------------------------------
-- Hierarchy integrity trigger.
-- ----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION metadata.validate_asset_hierarchy()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $function$
DECLARE
    v_parent_organization_id UUID;
    v_parent_site_id UUID;
    v_cycle_exists BOOLEAN;
BEGIN
    -- Root assets require no parent validation.
    IF NEW.parent_asset_id IS NULL THEN
        RETURN NEW;
    END IF;


    -- Explicit self-parent protection.
    IF NEW.parent_asset_id = NEW.id THEN
        RAISE EXCEPTION
            'Asset % cannot be its own parent',
            NEW.id;
    END IF;


    SELECT
        parent.organization_id,
        parent.site_id
    INTO
        v_parent_organization_id,
        v_parent_site_id
    FROM metadata.assets parent
    WHERE parent.id = NEW.parent_asset_id;


    IF NOT FOUND THEN
        RAISE EXCEPTION
            'Parent asset % does not exist',
            NEW.parent_asset_id;
    END IF;


    IF v_parent_organization_id <> NEW.organization_id THEN
        RAISE EXCEPTION
            'Parent asset % belongs to organization %, not organization %',
            NEW.parent_asset_id,
            v_parent_organization_id,
            NEW.organization_id;
    END IF;


    IF v_parent_site_id <> NEW.site_id THEN
        RAISE EXCEPTION
            'Parent asset % belongs to site %, not site %',
            NEW.parent_asset_id,
            v_parent_site_id,
            NEW.site_id;
    END IF;


    -- Walk upward from the proposed parent. If NEW.id is encountered, the
    -- proposed relationship would create a cycle.
    WITH RECURSIVE ancestor_walk AS
    (
        SELECT
            a.id,
            a.parent_asset_id,
            ARRAY[a.id] AS path
        FROM metadata.assets a
        WHERE a.id = NEW.parent_asset_id

        UNION ALL

        SELECT
            parent.id,
            parent.parent_asset_id,
            aw.path || parent.id
        FROM ancestor_walk aw

        JOIN metadata.assets parent
          ON parent.id = aw.parent_asset_id

        WHERE aw.parent_asset_id IS NOT NULL
          AND NOT parent.id = ANY(aw.path)
    )
    SELECT EXISTS
    (
        SELECT 1
        FROM ancestor_walk
        WHERE id = NEW.id
    )
    INTO v_cycle_exists;


    IF v_cycle_exists THEN
        RAISE EXCEPTION
            'Asset hierarchy cycle detected for asset % with proposed parent %',
            NEW.id,
            NEW.parent_asset_id;
    END IF;


    RETURN NEW;
END;
$function$;


DROP TRIGGER IF EXISTS
    trg_validate_asset_hierarchy
ON metadata.assets;


CREATE TRIGGER trg_validate_asset_hierarchy
BEFORE INSERT OR UPDATE OF
    parent_asset_id,
    organization_id,
    site_id
ON metadata.assets
FOR EACH ROW
EXECUTE FUNCTION metadata.validate_asset_hierarchy();


COMMENT ON FUNCTION metadata.validate_asset_hierarchy() IS
'Prevents self-parenting, cross-tenant parents, cross-site parents and cycles in metadata.assets.';


-- ----------------------------------------------------------------------------
-- Tenant-safe recursive hierarchy closure.
-- ----------------------------------------------------------------------------

CREATE OR REPLACE VIEW analytics.v_asset_hierarchy_closure
WITH
(
    security_barrier = TRUE
)
AS
WITH RECURSIVE hierarchy AS
(
    -- Every asset is its own ancestor at depth zero.
    SELECT
        a.organization_id,
        a.site_id,

        a.id AS ancestor_asset_id,
        a.id AS descendant_asset_id,

        0 AS depth,

        ARRAY[a.id] AS asset_path

    FROM metadata.assets a


    UNION ALL


    -- Walk downward from each ancestor to every reachable child.
    SELECT
        h.organization_id,
        h.site_id,

        h.ancestor_asset_id,
        child.id AS descendant_asset_id,

        h.depth + 1,

        h.asset_path || child.id

    FROM hierarchy h

    JOIN metadata.assets child
      ON child.parent_asset_id = h.descendant_asset_id
     AND child.organization_id = h.organization_id
     AND child.site_id = h.site_id

    -- Defensive protection against legacy cycles.
    WHERE NOT child.id = ANY(h.asset_path)
)

SELECT
    gom.grafana_org_id,

    h.organization_id,
    h.site_id,

    s.code AS site_code,
    s.name AS site_name,

    h.ancestor_asset_id,
    ancestor.name AS ancestor_asset_name,
    ancestor.asset_type_id AS ancestor_asset_type_id,
    ancestor_type.name AS ancestor_asset_type,
    ancestor.parent_asset_id AS ancestor_parent_asset_id,

    h.descendant_asset_id,
    descendant.name AS descendant_asset_name,
    descendant.asset_type_id AS descendant_asset_type_id,
    descendant_type.name AS descendant_asset_type,
    descendant.parent_asset_id AS descendant_parent_asset_id,

    h.depth,
    h.depth = 0 AS is_self,
    h.depth = 1 AS is_direct_child,

    NOT EXISTS
    (
        SELECT 1
        FROM metadata.assets child
        WHERE child.parent_asset_id = h.descendant_asset_id
          AND child.organization_id = h.organization_id
          AND child.site_id = h.site_id
    ) AS descendant_is_leaf,

    h.asset_path

FROM hierarchy h

JOIN metadata.assets ancestor
  ON ancestor.id = h.ancestor_asset_id
 AND ancestor.organization_id = h.organization_id
 AND ancestor.site_id = h.site_id

JOIN metadata.assets descendant
  ON descendant.id = h.descendant_asset_id
 AND descendant.organization_id = h.organization_id
 AND descendant.site_id = h.site_id

JOIN metadata.sites s
  ON s.id = h.site_id
 AND s.organization_id = h.organization_id

LEFT JOIN metadata.asset_types ancestor_type
  ON ancestor_type.id = ancestor.asset_type_id

LEFT JOIN metadata.asset_types descendant_type
  ON descendant_type.id = descendant.asset_type_id

JOIN metadata.grafana_organization_map gom
  ON gom.organization_id = h.organization_id
 AND gom.is_active = TRUE;


COMMENT ON VIEW analytics.v_asset_hierarchy_closure IS
'Tenant-safe recursive asset hierarchy closure containing self and all ancestor-to-descendant relationships.';


REVOKE ALL
ON FUNCTION metadata.validate_asset_hierarchy()
FROM PUBLIC;


REVOKE ALL
ON analytics.v_asset_hierarchy_closure
FROM PUBLIC;


GRANT SELECT
ON analytics.v_asset_hierarchy_closure
TO grafana_reader;
