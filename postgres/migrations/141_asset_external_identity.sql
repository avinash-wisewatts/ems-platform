-- Migration 141
-- Add a stable, site-scoped external identity for assets.
--
-- Display names remain non-unique. external_id is the machine identifier.
-- When omitted, PostgreSQL generates a unique value from the asset name.

BEGIN;

ALTER TABLE metadata.assets
    ADD COLUMN IF NOT EXISTS external_id TEXT;

CREATE OR REPLACE FUNCTION metadata.generate_asset_external_id()
RETURNS trigger
LANGUAGE plpgsql
SET search_path TO pg_catalog, metadata
AS $function$
DECLARE
    v_base      TEXT;
    v_candidate TEXT;
    v_suffix    INTEGER := 1;
BEGIN
    IF NULLIF(btrim(NEW.external_id), '') IS NOT NULL THEN
        NEW.external_id := upper(btrim(NEW.external_id));
        RETURN NEW;
    END IF;

    v_base := upper(
        trim(
            both '_' FROM
            regexp_replace(
                COALESCE(NULLIF(btrim(NEW.name), ''), 'ASSET'),
                '[^A-Za-z0-9]+',
                '_',
                'g'
            )
        )
    );

    IF v_base = '' THEN
        v_base := 'ASSET';
    END IF;

    v_base := left(v_base, 100);

    -- Serialize generation for the same organization/site/base combination.
    PERFORM pg_advisory_xact_lock(
        hashtextextended(
            NEW.organization_id::text
            || ':'
            || NEW.site_id::text
            || ':'
            || v_base,
            0
        )
    );

    v_candidate := v_base;

    WHILE EXISTS
    (
        SELECT 1
        FROM metadata.assets AS existing_asset
        WHERE existing_asset.organization_id = NEW.organization_id
          AND existing_asset.site_id = NEW.site_id
          AND upper(btrim(existing_asset.external_id))
              = upper(btrim(v_candidate))
          AND existing_asset.id IS DISTINCT FROM NEW.id
    )
    LOOP
        v_suffix := v_suffix + 1;

        v_candidate :=
            left(
                v_base,
                100 - length(v_suffix::text) - 1
            )
            || '_'
            || v_suffix::text;
    END LOOP;

    NEW.external_id := v_candidate;

    RETURN NEW;
END;
$function$;

ALTER FUNCTION metadata.generate_asset_external_id()
    OWNER TO ems_admin;

DROP TRIGGER IF EXISTS trg_generate_asset_external_id
    ON metadata.assets;

CREATE TRIGGER trg_generate_asset_external_id
BEFORE INSERT OR UPDATE OF name, external_id, organization_id, site_id
ON metadata.assets
FOR EACH ROW
EXECUTE FUNCTION metadata.generate_asset_external_id();

-- Backfill existing rows through the same trigger logic.
UPDATE metadata.assets
SET external_id = NULL
WHERE NULLIF(btrim(external_id), '') IS NULL;

ALTER TABLE metadata.assets
    ALTER COLUMN external_id SET NOT NULL;

ALTER TABLE metadata.assets
    DROP CONSTRAINT IF EXISTS assets_external_id_format_chk;

ALTER TABLE metadata.assets
    ADD CONSTRAINT assets_external_id_format_chk
    CHECK
    (
        external_id ~ '^[A-Z0-9][A-Z0-9_]*$'
        AND length(external_id) <= 100
    );

CREATE UNIQUE INDEX IF NOT EXISTS assets_org_site_external_id_ci_uq
    ON metadata.assets
    (
        organization_id,
        site_id,
        upper(btrim(external_id))
    );

COMMENT ON COLUMN metadata.assets.external_id IS
    'Stable system identity unique within organization and site; generated from name when omitted.';

COMMENT ON FUNCTION metadata.generate_asset_external_id() IS
    'Generates a site-scoped asset external ID while allowing duplicate asset names.';

COMMIT;
