-- ============================================================================
-- Migration: 99_controlled_lifecycle_statuses.sql
-- Story: 1.1 Controlled Lifecycle and Status Values
-- Purpose:
--   * Add canonical administration status definitions.
--   * Add explicit lifecycle columns to core tenant-owned entities.
--   * Backfill existing records without changing current operational behavior.
--   * Reject invalid lifecycle codes at the database boundary.
--
-- Compatibility:
--   Legacy organizations.is_active, sites.is_active, and assets.status remain in
--   place temporarily. Independent administration write contracts will use the
--   new lifecycle_status columns explicitly.
-- ============================================================================

CREATE TABLE IF NOT EXISTS config.status_definitions
(
    status_domain TEXT NOT NULL,
    code TEXT NOT NULL,
    label TEXT NOT NULL,
    description TEXT NOT NULL,
    sort_order SMALLINT NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),

    CONSTRAINT status_definitions_pk
        PRIMARY KEY (status_domain, code),
    CONSTRAINT status_definitions_domain_format_chk
        CHECK (status_domain ~ '^[A-Z][A-Z0-9_]*$'),
    CONSTRAINT status_definitions_code_format_chk
        CHECK (code ~ '^[A-Z][A-Z0-9_]*$'),
    CONSTRAINT status_definitions_sort_order_chk
        CHECK (sort_order > 0),
    CONSTRAINT status_definitions_domain_sort_uq
        UNIQUE (status_domain, sort_order)
);

INSERT INTO config.status_definitions
(status_domain, code, label, description, sort_order)
VALUES
('ORGANIZATION_LIFECYCLE', 'DRAFT', 'Draft', 'Organization record exists but is not ready for normal customer operation.', 10),
('ORGANIZATION_LIFECYCLE', 'ACTIVE', 'Active', 'Organization is an operational EMS tenant.', 20),
('ORGANIZATION_LIFECYCLE', 'SUSPENDED', 'Suspended', 'Organization is temporarily disabled while history is retained.', 30),
('ORGANIZATION_LIFECYCLE', 'DECOMMISSIONED', 'Decommissioned', 'Organization has been permanently retired from active operation.', 40),
('SITE_LIFECYCLE', 'DRAFT', 'Draft', 'Site record exists but onboarding is incomplete.', 10),
('SITE_LIFECYCLE', 'ACTIVE', 'Active', 'Site is operational and may participate in onboarding and reporting.', 20),
('SITE_LIFECYCLE', 'INACTIVE', 'Inactive', 'Site is temporarily not operational while history is retained.', 30),
('SITE_LIFECYCLE', 'DECOMMISSIONED', 'Decommissioned', 'Site has been retired from active operation.', 40),
('ASSET_LIFECYCLE', 'DRAFT', 'Draft', 'Asset master record exists but commissioning has not started.', 10),
('ASSET_LIFECYCLE', 'COMMISSIONING', 'Commissioning', 'Asset is being prepared and validated for operational use.', 20),
('ASSET_LIFECYCLE', 'ACTIVE', 'Active', 'Asset has passed required commissioning rules.', 30),
('ASSET_LIFECYCLE', 'INACTIVE', 'Inactive', 'Asset is temporarily not operating while history is retained.', 40),
('ASSET_LIFECYCLE', 'DECOMMISSIONED', 'Decommissioned', 'Asset has been retired from active operation.', 50),
('GATEWAY_LIFECYCLE', 'REGISTERED', 'Registered', 'Gateway identity exists and configuration may begin.', 10),
('GATEWAY_LIFECYCLE', 'COMMISSIONING', 'Commissioning', 'Gateway installation or connectivity validation is in progress.', 20),
('GATEWAY_LIFECYCLE', 'INACTIVE', 'Inactive', 'Gateway is intentionally disabled or temporarily out of use.', 30),
('GATEWAY_LIFECYCLE', 'DECOMMISSIONED', 'Decommissioned', 'Gateway has been retired while history is retained.', 40),
('DEVICE_LIFECYCLE', 'DISCOVERED', 'Discovered', 'Device was detected but has not been formally registered.', 10),
('DEVICE_LIFECYCLE', 'REGISTERED', 'Registered', 'Device identity and core metadata have been saved.', 20),
('DEVICE_LIFECYCLE', 'UNASSIGNED', 'Unassigned', 'Device is tenant-owned and valid but has no functional assignment.', 30),
('DEVICE_LIFECYCLE', 'COMMISSIONING', 'Commissioning', 'Device profile, channels, relationships, or telemetry are being validated.', 40),
('DEVICE_LIFECYCLE', 'ACTIVE', 'Active', 'Device is approved for operational use.', 50),
('DEVICE_LIFECYCLE', 'INACTIVE', 'Inactive', 'Device is intentionally disabled or temporarily removed from service.', 60),
('DEVICE_LIFECYCLE', 'DECOMMISSIONED', 'Decommissioned', 'Device has been permanently retired while history is retained.', 70),
('COMMISSIONING_STATUS', 'NOT_STARTED', 'Not started', 'No commissioning attempt has been made.', 10),
('COMMISSIONING_STATUS', 'IN_PROGRESS', 'In progress', 'Commissioning work is underway.', 20),
('COMMISSIONING_STATUS', 'BLOCKED', 'Blocked', 'Mandatory requirements are missing or invalid.', 30),
('COMMISSIONING_STATUS', 'READY', 'Ready', 'All mandatory checks passed and activation is permitted.', 40),
('COMMISSIONING_STATUS', 'COMMISSIONED', 'Commissioned', 'Commissioning completed successfully.', 50),
('COMMISSIONING_STATUS', 'FAILED', 'Failed', 'A commissioning attempt failed and the reason is retained.', 60),
('GRAFANA_PROVISIONING_STATUS', 'NOT_STARTED', 'Not started', 'Grafana provisioning has not yet been attempted.', 10),
('GRAFANA_PROVISIONING_STATUS', 'PENDING', 'Pending', 'Grafana provisioning is running or awaiting completion.', 20),
('GRAFANA_PROVISIONING_STATUS', 'PROVISIONED', 'Provisioned', 'Grafana tenant resources were created successfully.', 30),
('GRAFANA_PROVISIONING_STATUS', 'FAILED', 'Failed', 'Grafana provisioning did not complete successfully.', 40),
('TELEMETRY_AVAILABILITY', 'NEVER_SEEN', 'Never seen', 'No telemetry has ever been received for the device.', 10),
('TELEMETRY_AVAILABILITY', 'RECEIVING', 'Receiving', 'Valid telemetry is arriving within the expected interval.', 20),
('TELEMETRY_AVAILABILITY', 'STALE', 'Stale', 'Telemetry was received previously but is older than the warning threshold.', 30),
('TELEMETRY_AVAILABILITY', 'SILENT', 'Silent', 'No telemetry has arrived beyond the critical threshold.', 40),
('TELEMETRY_AVAILABILITY', 'INVALID_PROFILE', 'Invalid profile', 'Telemetry is arriving but cannot be normalized with the assigned profile.', 50),
('TELEMETRY_AVAILABILITY', 'UNMAPPED', 'Unmapped', 'Telemetry is arriving for a known device without a required functional mapping.', 60),
('TELEMETRY_AVAILABILITY', 'VALIDATED', 'Validated', 'Telemetry passed profile, timestamp, value, and expected-point checks.', 70),
('METERING_REQUIREMENT', 'DIRECT_METER_REQUIRED', 'Direct meter required', 'Asset requires a qualifying primary energy meter for commissioning.', 10),
('METERING_REQUIREMENT', 'DESCENDANT_COVERAGE_ALLOWED', 'Descendant coverage allowed', 'Asset coverage may be satisfied by required directly metered descendants.', 20),
('METERING_REQUIREMENT', 'NOT_REQUIRED', 'Not required', 'Asset is intentionally excluded from energy-meter coverage.', 30),
('METER_COVERAGE_STATUS', 'CONFIGURED', 'Configured', 'All required qualifying meter relationships are present.', 10),
('METER_COVERAGE_STATUS', 'MISSING_DIRECT_METER', 'Missing direct meter', 'A required qualifying primary meter relationship is missing.', 20),
('METER_COVERAGE_STATUS', 'PARTIALLY_CONFIGURED', 'Partially configured', 'Some but not all required descendants are correctly metered.', 30),
('METER_COVERAGE_STATUS', 'MISSING_DESCENDANT_COVERAGE', 'Missing descendant coverage', 'Required descendant assets are not adequately metered.', 40),
('METER_COVERAGE_STATUS', 'NO_REQUIRED_DESCENDANTS', 'No required descendants', 'No active descendant currently requires a direct meter.', 50),
('METER_COVERAGE_STATUS', 'EXCLUDED', 'Excluded', 'Asset is excluded from energy-meter coverage evaluation.', 60),
('METER_COVERAGE_STATUS', 'OUT_OF_SCOPE_INACTIVE', 'Out of scope inactive', 'Inactive or decommissioned asset is outside active coverage evaluation.', 70)
ON CONFLICT (status_domain, code) DO UPDATE
SET
    label = EXCLUDED.label,
    description = EXCLUDED.description,
    sort_order = EXCLUDED.sort_order;

ALTER TABLE metadata.organizations
    ADD COLUMN IF NOT EXISTS lifecycle_status TEXT;

UPDATE metadata.organizations
SET lifecycle_status = CASE
    WHEN is_active THEN 'ACTIVE'
    ELSE 'SUSPENDED'
END
WHERE lifecycle_status IS NULL;

ALTER TABLE metadata.organizations
    ALTER COLUMN lifecycle_status SET DEFAULT 'ACTIVE',
    ALTER COLUMN lifecycle_status SET NOT NULL;

ALTER TABLE metadata.organizations
    DROP CONSTRAINT IF EXISTS organizations_lifecycle_status_chk;

ALTER TABLE metadata.organizations
    ADD CONSTRAINT organizations_lifecycle_status_chk
    CHECK (lifecycle_status IN ('DRAFT', 'ACTIVE', 'SUSPENDED', 'DECOMMISSIONED'));

ALTER TABLE metadata.sites
    ADD COLUMN IF NOT EXISTS lifecycle_status TEXT;

UPDATE metadata.sites
SET lifecycle_status = CASE
    WHEN is_active THEN 'ACTIVE'
    ELSE 'INACTIVE'
END
WHERE lifecycle_status IS NULL;

ALTER TABLE metadata.sites
    ALTER COLUMN lifecycle_status SET DEFAULT 'ACTIVE',
    ALTER COLUMN lifecycle_status SET NOT NULL;

ALTER TABLE metadata.sites
    DROP CONSTRAINT IF EXISTS sites_lifecycle_status_chk;

ALTER TABLE metadata.sites
    ADD CONSTRAINT sites_lifecycle_status_chk
    CHECK (lifecycle_status IN ('DRAFT', 'ACTIVE', 'INACTIVE', 'DECOMMISSIONED'));

ALTER TABLE metadata.assets
    ADD COLUMN IF NOT EXISTS lifecycle_status TEXT;

UPDATE metadata.assets
SET lifecycle_status = CASE lower(COALESCE(status, 'active'))
    WHEN 'draft' THEN 'DRAFT'
    WHEN 'commissioning' THEN 'COMMISSIONING'
    WHEN 'inactive' THEN 'INACTIVE'
    WHEN 'decommissioned' THEN 'DECOMMISSIONED'
    ELSE 'ACTIVE'
END
WHERE lifecycle_status IS NULL;

ALTER TABLE metadata.assets
    ALTER COLUMN lifecycle_status SET DEFAULT 'ACTIVE',
    ALTER COLUMN lifecycle_status SET NOT NULL;

ALTER TABLE metadata.assets
    DROP CONSTRAINT IF EXISTS assets_lifecycle_status_chk;

ALTER TABLE metadata.assets
    ADD CONSTRAINT assets_lifecycle_status_chk
    CHECK (lifecycle_status IN ('DRAFT', 'COMMISSIONING', 'ACTIVE', 'INACTIVE', 'DECOMMISSIONED'));

ALTER TABLE metadata.gateways
    ADD COLUMN IF NOT EXISTS lifecycle_status TEXT;

UPDATE metadata.gateways
SET lifecycle_status = 'REGISTERED'
WHERE lifecycle_status IS NULL;

ALTER TABLE metadata.gateways
    ALTER COLUMN lifecycle_status SET DEFAULT 'REGISTERED',
    ALTER COLUMN lifecycle_status SET NOT NULL;

ALTER TABLE metadata.gateways
    DROP CONSTRAINT IF EXISTS gateways_lifecycle_status_chk;

ALTER TABLE metadata.gateways
    ADD CONSTRAINT gateways_lifecycle_status_chk
    CHECK (lifecycle_status IN ('REGISTERED', 'COMMISSIONING', 'INACTIVE', 'DECOMMISSIONED'));

ALTER TABLE metadata.devices
    ADD COLUMN IF NOT EXISTS lifecycle_status TEXT;

UPDATE metadata.devices
SET lifecycle_status = 'REGISTERED'
WHERE lifecycle_status IS NULL;

ALTER TABLE metadata.devices
    ALTER COLUMN lifecycle_status SET DEFAULT 'REGISTERED',
    ALTER COLUMN lifecycle_status SET NOT NULL;

ALTER TABLE metadata.devices
    DROP CONSTRAINT IF EXISTS devices_lifecycle_status_chk;

ALTER TABLE metadata.devices
    ADD CONSTRAINT devices_lifecycle_status_chk
    CHECK (lifecycle_status IN ('DISCOVERED', 'REGISTERED', 'UNASSIGNED', 'COMMISSIONING', 'ACTIVE', 'INACTIVE', 'DECOMMISSIONED'));
