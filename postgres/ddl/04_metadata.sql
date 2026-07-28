-- ============================================================================
-- File: 04_metadata.sql
-- Purpose: Core EMS metadata model.
--
-- Design principles:
--   - Organization-based multi-tenancy.
--   - Asset-centric business model.
--   - Late-binding telemetry architecture.
--   - UUID primary keys.
--   - Metadata defines meaning; telemetry stores measurements.
--
-- Execution order:
--   This script runs after:
--       00_extensions.sql
--       01_schemas.sql
--       02_roles.sql
--       03_admin.sql
-- ============================================================================


CREATE EXTENSION IF NOT EXISTS pgcrypto;


-- ============================================================================
-- TENANT HIERARCHY
-- ============================================================================

CREATE TABLE IF NOT EXISTS metadata.organizations (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),

    name TEXT NOT NULL,
    code TEXT UNIQUE NOT NULL
        CONSTRAINT organizations_code_format_chk
        CHECK (code ~ '^[A-Z0-9_]+$'),

    timezone TEXT NOT NULL DEFAULT 'Asia/Kolkata',

    description TEXT,

    is_active BOOLEAN NOT NULL DEFAULT TRUE,

    lifecycle_status TEXT NOT NULL DEFAULT 'ACTIVE'
        CONSTRAINT organizations_lifecycle_status_chk
        CHECK (lifecycle_status IN ('DRAFT', 'ACTIVE', 'SUSPENDED', 'DECOMMISSIONED')),

    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);


CREATE TABLE IF NOT EXISTS metadata.sites (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),

    organization_id UUID NOT NULL
        REFERENCES metadata.organizations(id),

    name TEXT NOT NULL,
    code TEXT NOT NULL,

    timezone TEXT NOT NULL DEFAULT 'Asia/Kolkata',

    address JSONB,

    is_active BOOLEAN NOT NULL DEFAULT TRUE,

    lifecycle_status TEXT NOT NULL DEFAULT 'ACTIVE'
        CONSTRAINT sites_lifecycle_status_chk
        CHECK (lifecycle_status IN ('DRAFT', 'ACTIVE', 'INACTIVE', 'DECOMMISSIONED')),

    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),

    UNIQUE (organization_id, code)
);


CREATE TABLE IF NOT EXISTS metadata.buildings (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),

    organization_id UUID NOT NULL
        REFERENCES metadata.organizations(id),

    site_id UUID NOT NULL
        REFERENCES metadata.sites(id),

    name TEXT NOT NULL,

    code TEXT NOT NULL
        CONSTRAINT buildings_code_format_chk
        CHECK (code ~ '^[A-Z][A-Z0-9_]*$'),

    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),

    CONSTRAINT buildings_site_code_uq
        UNIQUE (site_id, code)
);


CREATE TABLE IF NOT EXISTS metadata.floors (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),

    organization_id UUID NOT NULL
        REFERENCES metadata.organizations(id),

    building_id UUID NOT NULL
        REFERENCES metadata.buildings(id),

    name TEXT NOT NULL,

    code TEXT NOT NULL
        CONSTRAINT floors_code_format_chk
        CHECK (code ~ '^[A-Z][A-Z0-9_]*$'),

    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),

    CONSTRAINT floors_building_code_uq
        UNIQUE (building_id, code)
);


CREATE TABLE IF NOT EXISTS metadata.spaces (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),

    organization_id UUID NOT NULL
        REFERENCES metadata.organizations(id),

    floor_id UUID NOT NULL
        REFERENCES metadata.floors(id),

    name TEXT NOT NULL,

    code TEXT NOT NULL
        CONSTRAINT spaces_code_format_chk
        CHECK (code ~ '^[A-Z][A-Z0-9_]*$'),

    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),

    CONSTRAINT spaces_floor_code_uq
        UNIQUE (floor_id, code)
);



-- ============================================================================
-- ASSET MODEL
-- ============================================================================

CREATE TABLE IF NOT EXISTS metadata.asset_types (

    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),

    name TEXT NOT NULL,

    description TEXT,

    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);


-- Prevent duplicate controlled-vocabulary entries that differ only by case.
CREATE UNIQUE INDEX IF NOT EXISTS asset_types_name_ci_uq
    ON metadata.asset_types (lower(name));


CREATE TABLE IF NOT EXISTS metadata.assets (

    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),

    organization_id UUID NOT NULL
        REFERENCES metadata.organizations(id),

    site_id UUID NOT NULL
        REFERENCES metadata.sites(id),

    -- Optional physical placement. Floor and building are derived through
    -- metadata.spaces -> metadata.floors -> metadata.buildings.
    space_id UUID
        REFERENCES metadata.spaces(id)
        ON DELETE SET NULL,

    asset_type_id UUID
        REFERENCES metadata.asset_types(id),

    parent_asset_id UUID
        REFERENCES metadata.assets(id),

    name TEXT NOT NULL,

    external_id TEXT NOT NULL,

    manufacturer TEXT,

    model TEXT,

    serial_number TEXT,

    status TEXT DEFAULT 'active',

    lifecycle_status TEXT NOT NULL DEFAULT 'ACTIVE'
        CONSTRAINT assets_lifecycle_status_chk
        CHECK (lifecycle_status IN ('DRAFT', 'COMMISSIONING', 'ACTIVE', 'INACTIVE', 'DECOMMISSIONED')),

    -- Explicit energy-meter coverage policy. No default is provided because
    -- onboarding must make a deliberate production decision for every asset.
    metering_requirement TEXT NOT NULL
        CHECK
        (
            metering_requirement IN
            (
                'DIRECT_METER_REQUIRED',
                'DESCENDANT_COVERAGE_ALLOWED',
                'NOT_REQUIRED'
            )
        ),

    metadata JSONB,

    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);


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

COMMENT ON COLUMN metadata.assets.external_id IS
    'Stable system identity unique within organization and site; generated from name when omitted.';

COMMENT ON FUNCTION metadata.generate_asset_external_id() IS
    'Generates a site-scoped asset external ID while allowing duplicate asset names.';




-- ============================================================================
-- DEVICE MODEL
-- ============================================================================

CREATE TABLE IF NOT EXISTS metadata.gateway_models (

    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),

    vendor TEXT,
    model TEXT NOT NULL,

    protocol TEXT,

    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);


CREATE TABLE IF NOT EXISTS metadata.gateways (

    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),

    organization_id UUID NOT NULL
        REFERENCES metadata.organizations(id),

    site_id UUID NOT NULL
        REFERENCES metadata.sites(id),

    -- Optional physical installation location for the gateway.
    building_id UUID
        REFERENCES metadata.buildings(id)
        ON DELETE SET NULL,

    floor_id UUID
        REFERENCES metadata.floors(id)
        ON DELETE SET NULL,

    space_id UUID
        REFERENCES metadata.spaces(id)
        ON DELETE SET NULL,

    gateway_model_id UUID
        REFERENCES metadata.gateway_models(id),

    name TEXT NOT NULL,

    external_id TEXT NOT NULL,

    lifecycle_status TEXT NOT NULL DEFAULT 'REGISTERED'
        CONSTRAINT gateways_lifecycle_status_chk
        CHECK (lifecycle_status IN ('REGISTERED', 'COMMISSIONING', 'INACTIVE', 'DECOMMISSIONED')),

    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);


-- One stable gateway external identifier per organization.
CREATE UNIQUE INDEX IF NOT EXISTS gateways_org_external_id_ci_uq
    ON metadata.gateways
    (
        organization_id,
        upper(btrim(external_id))
    );


CREATE TABLE IF NOT EXISTS metadata.device_models (

    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),

    vendor TEXT,

    model TEXT NOT NULL,

    -- Temporary compatibility column. New application logic must use
    -- device_category_id as the authoritative classification.
    device_type TEXT,

    device_category_id UUID NOT NULL
        REFERENCES config.device_categories(id),

    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);


-- One canonical device-model definition per vendor and model.
CREATE UNIQUE INDEX IF NOT EXISTS device_models_vendor_model_ci_uq
    ON metadata.device_models
    (
        lower(COALESCE(vendor, '')),
        lower(model)
    );


CREATE TABLE IF NOT EXISTS metadata.devices (

    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),

    organization_id UUID NOT NULL
        REFERENCES metadata.organizations(id),

    gateway_id UUID
        REFERENCES metadata.gateways(id),

    device_model_id UUID
        REFERENCES metadata.device_models(id),

    name TEXT NOT NULL,

    external_id TEXT NOT NULL,

    serial_number TEXT,

    firmware_version TEXT,

    protocol TEXT,

    -- Optional physical location independent from gateway and asset.
    building_id UUID REFERENCES metadata.buildings(id) ON DELETE SET NULL,
    floor_id UUID REFERENCES metadata.floors(id) ON DELETE SET NULL,
    space_id UUID REFERENCES metadata.spaces(id) ON DELETE SET NULL,

    lifecycle_status TEXT NOT NULL DEFAULT 'REGISTERED'
        CONSTRAINT devices_lifecycle_status_chk
        CHECK (lifecycle_status IN ('DISCOVERED', 'REGISTERED', 'UNASSIGNED', 'COMMISSIONING', 'ACTIVE', 'INACTIVE', 'DECOMMISSIONED')),

    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),

    updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);




-- ============================================================================
-- ASSET DEVICE RELATIONSHIP
-- ============================================================================

-- One stable device external identifier per organization.
CREATE UNIQUE INDEX IF NOT EXISTS devices_org_external_id_ci_uq
    ON metadata.devices
    (
        organization_id,
        upper(btrim(external_id))
    );


CREATE TABLE IF NOT EXISTS metadata.asset_devices (

    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),

    asset_id UUID NOT NULL
        REFERENCES metadata.assets(id),

    device_id UUID NOT NULL
        REFERENCES metadata.devices(id),

    relationship_type TEXT NOT NULL,

    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),

    UNIQUE(asset_id, device_id, relationship_type)
);


-- ============================================================================
-- SEMANTIC MEASUREMENT MODEL
-- ============================================================================

CREATE TABLE IF NOT EXISTS metadata.logical_points (

    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),

    name TEXT NOT NULL,

    description TEXT,

    unit_id UUID
        REFERENCES config.engineering_units(id),

    data_type TEXT NOT NULL DEFAULT 'numeric',

    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);



CREATE TABLE IF NOT EXISTS metadata.asset_points (

    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),

    asset_id UUID NOT NULL
        REFERENCES metadata.assets(id),

    logical_point_id UUID NOT NULL
        REFERENCES metadata.logical_points(id),

    point_role TEXT,

    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),

    UNIQUE(asset_id, logical_point_id)
);



CREATE TABLE IF NOT EXISTS metadata.device_field_mapping (

    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),

    device_id UUID NOT NULL
        REFERENCES metadata.devices(id),

    raw_field_name TEXT NOT NULL,

    logical_point_id UUID NOT NULL
        REFERENCES metadata.logical_points(id),

    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),

    UNIQUE(device_id, raw_field_name)
);


