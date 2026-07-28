-- ============================================================================
-- File:
--   85_site_energy_meter_roles.sql
--
-- Epic:
--   Epic 4 — Core Energy Analytics
--
-- Story:
--   4.3 — Site energy balance
--
-- Purpose:
--   Classify physical energy meters by their role in a site's energy balance.
--
-- Important distinction:
--
--   metadata.asset_devices.relationship_type = PRIMARY_METER
--
--       identifies the primary meter for an operational asset.
--
--   config.site_energy_meter_roles.meter_role
--
--       identifies how the meter participates in the site energy equation.
--
-- These concepts must remain separate to prevent utility meters and asset
-- submeters from being aggregated together incorrectly.
--
-- Supported balance equation:
--
--   Derived Site Consumption
--       = Grid Import
--       + On-site Generation
--       - Grid Export
--       - Battery Charging
--       + Battery Discharging
--
-- A direct SITE_CONSUMPTION meter may later be used as the authoritative
-- measured total instead of the derived equation.
-- ============================================================================


CREATE TABLE IF NOT EXISTS config.site_energy_meter_roles
(
    id UUID PRIMARY KEY
        DEFAULT gen_random_uuid(),

    site_id UUID NOT NULL
        REFERENCES metadata.sites(id)
        ON DELETE CASCADE,

    device_id UUID NOT NULL
        REFERENCES metadata.devices(id)
        ON DELETE CASCADE,

    meter_role TEXT NOT NULL,

    -- Allows multiple meters to contribute to one component while preserving
    -- explicit allocation behavior. Default 1 means the full measured value.
    allocation_factor NUMERIC(12, 9) NOT NULL
        DEFAULT 1,

    is_authoritative BOOLEAN NOT NULL
        DEFAULT TRUE,

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

    CONSTRAINT ck_site_energy_meter_role
        CHECK
        (
            meter_role IN
            (
                'GRID_IMPORT',
                'GRID_EXPORT',
                'ONSITE_GENERATION',
                'SITE_CONSUMPTION',
                'BATTERY_CHARGE',
                'BATTERY_DISCHARGE',
                'LOAD_SUBMETER'
            )
        ),

    CONSTRAINT ck_site_energy_meter_allocation
        CHECK
        (
            allocation_factor > 0
            AND allocation_factor <= 1
        ),

    CONSTRAINT ck_site_energy_meter_effective_window
        CHECK
        (
            effective_to IS NULL
            OR effective_to > effective_from
        )
);


-- A device may legitimately hold multiple roles, such as a bidirectional
-- utility meter with both GRID_IMPORT and GRID_EXPORT. However, the same
-- device/role/site combination cannot have overlapping active periods.

DO $$
BEGIN
    IF NOT EXISTS
    (
        SELECT 1
        FROM pg_constraint
        WHERE conname = 'ex_site_energy_meter_role_no_overlap'
          AND conrelid =
              'config.site_energy_meter_roles'::regclass
    )
    THEN
        ALTER TABLE config.site_energy_meter_roles
        ADD CONSTRAINT ex_site_energy_meter_role_no_overlap
        EXCLUDE USING gist
        (
            site_id WITH =,
            device_id WITH =,
            meter_role WITH =,
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
    ix_site_energy_meter_roles_site
ON config.site_energy_meter_roles
(
    site_id,
    meter_role,
    effective_from DESC
)
WHERE is_active;


CREATE INDEX IF NOT EXISTS
    ix_site_energy_meter_roles_device
ON config.site_energy_meter_roles
(
    device_id,
    effective_from DESC
)
WHERE is_active;


-- ----------------------------------------------------------------------------
-- Validate that the assigned device belongs to the assigned site.
--
-- Device site resolution:
--
--   metadata.devices.gateway_id
--       -> metadata.gateways.site_id
--
-- This trigger prevents cross-site and cross-tenant meter-role assignments.
-- ----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION config.validate_site_energy_meter_role()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $function$
DECLARE
    v_device_site_id UUID;
BEGIN
    SELECT g.site_id
    INTO v_device_site_id
    FROM metadata.devices d

    JOIN metadata.gateways g
      ON g.id = d.gateway_id

    WHERE d.id = NEW.device_id;


    IF v_device_site_id IS NULL THEN
        RAISE EXCEPTION
            'Device % does not resolve to a site through its gateway',
            NEW.device_id;
    END IF;


    IF v_device_site_id <> NEW.site_id THEN
        RAISE EXCEPTION
            'Device % belongs to site %, not assigned site %',
            NEW.device_id,
            v_device_site_id,
            NEW.site_id;
    END IF;


    RETURN NEW;
END;
$function$;


DROP TRIGGER IF EXISTS
    trg_validate_site_energy_meter_role
ON config.site_energy_meter_roles;


CREATE TRIGGER trg_validate_site_energy_meter_role
BEFORE INSERT OR UPDATE OF site_id, device_id
ON config.site_energy_meter_roles
FOR EACH ROW
EXECUTE FUNCTION config.validate_site_energy_meter_role();


COMMENT ON TABLE config.site_energy_meter_roles IS
'Effective-dated device roles used to calculate site-level energy balance without double-counting asset submeters.';


COMMENT ON COLUMN config.site_energy_meter_roles.is_authoritative IS
'Indicates whether this meter is approved for inclusion in production site-balance calculations.';


COMMENT ON COLUMN config.site_energy_meter_roles.allocation_factor IS
'Fraction of the meter measurement allocated to the configured site balance component.';


-- ----------------------------------------------------------------------------
-- Tenant-safe role catalog for analytics and Grafana.
-- ----------------------------------------------------------------------------

CREATE OR REPLACE VIEW analytics.v_site_energy_meter_roles
WITH
(
    security_barrier = TRUE
)
AS
SELECT
    gom.grafana_org_id,

    s.organization_id,
    r.site_id,

    s.code AS site_code,
    s.name AS site_name,

    r.device_id,
    d.external_id,
    d.name AS device_name,

    dp.profile_code,

    r.meter_role,
    r.allocation_factor,
    r.is_authoritative,

    r.effective_from,
    r.effective_to,
    r.effective_range,

    r.is_active,
    r.description

FROM config.site_energy_meter_roles r

JOIN metadata.sites s
  ON s.id = r.site_id

JOIN metadata.devices d
  ON d.id = r.device_id

LEFT JOIN config.device_profiles dp
  ON dp.id = d.profile_id

JOIN metadata.grafana_organization_map gom
  ON gom.organization_id = s.organization_id
 AND gom.is_active = TRUE;


COMMENT ON VIEW analytics.v_site_energy_meter_roles IS
'Tenant-safe effective-dated site energy meter-role catalog.';


REVOKE ALL
ON config.site_energy_meter_roles
FROM PUBLIC;


REVOKE ALL
ON analytics.v_site_energy_meter_roles
FROM PUBLIC;


GRANT SELECT
ON analytics.v_site_energy_meter_roles
TO grafana_reader;
