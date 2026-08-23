\set ON_ERROR_STOP on

-- =============================================================================
-- WiseWatts EMS — Phase 1A connectivity semantic contract
--
-- Canonical source under test:
--   analytics.get_grafana_asset_connectivity_context(grafana_org_id, asset_id, p_at)
--
-- This asserts the deterministic state machine defined by the Phase 1A
-- Connectivity Semantic Consolidation plan:
--
--   NEVER_SEEN > SILENT > STALE > DELAYED > RECEIVING   (precedence order)
--   NO_ASSIGNED_DEVICE when the asset has no assigned device at all
--
-- against telemetry.device_raw_receipt_state, using a fixed reference
-- instant (p_at) so results never depend on wall-clock timing.
--
-- All test records are created inside one transaction and rolled back.
-- =============================================================================

BEGIN;

-- ---------------------------------------------------------------------------
-- Deterministic thresholds for this test, regardless of what is seeded
-- elsewhere: receiving=300s, stale(source-delay)=900s, silent=3600s.
-- ---------------------------------------------------------------------------

INSERT INTO config.telemetry_availability_policy (
    policy_key, receiving_threshold_seconds, stale_threshold_seconds, silent_threshold_seconds
)
VALUES ('DEFAULT', 300, 900, 3600)
ON CONFLICT (policy_key) DO UPDATE SET
    receiving_threshold_seconds = 300,
    stale_threshold_seconds = 900,
    silent_threshold_seconds = 3600;

-- ---------------------------------------------------------------------------
-- Fixed reference instant: 2026-01-01 12:00:00+00. Every fixture timestamp
-- below is expressed relative to this value (hardcoded per assertion block)
-- so the test is fully deterministic and never depends on wall-clock timing.
-- ---------------------------------------------------------------------------

-- ---------------------------------------------------------------------------
-- Organization / site / gateway
-- ---------------------------------------------------------------------------

INSERT INTO metadata.organizations (id, name, code, description, is_active)
VALUES
    ('94000000-0000-0000-0000-000000000001', 'Connectivity Tenant Alpha', 'CONNECTIVITY_ALPHA', 'Disposable connectivity contract tenant', TRUE),
    ('94000000-0000-0000-0000-000000000002', 'Connectivity Tenant Beta', 'CONNECTIVITY_BETA', 'Disposable connectivity contract tenant', TRUE);

INSERT INTO metadata.sites (id, organization_id, name, code, timezone, address, is_active)
VALUES
    ('94100000-0000-0000-0000-000000000001', '94000000-0000-0000-0000-000000000001', 'Connectivity Alpha Site', 'CONNECTIVITY_ALPHA_SITE', 'Asia/Kolkata', '{}'::jsonb, TRUE),
    ('94100000-0000-0000-0000-000000000002', '94000000-0000-0000-0000-000000000002', 'Connectivity Beta Site', 'CONNECTIVITY_BETA_SITE', 'Asia/Kolkata', '{}'::jsonb, TRUE);

INSERT INTO metadata.grafana_organization_map (grafana_org_id, organization_id, is_active)
VALUES
    (94001, '94000000-0000-0000-0000-000000000001', TRUE),
    (94002, '94000000-0000-0000-0000-000000000002', TRUE);

INSERT INTO metadata.gateways (id, organization_id, site_id, name, external_id)
VALUES
    ('94200000-0000-0000-0000-000000000001', '94000000-0000-0000-0000-000000000001', '94100000-0000-0000-0000-000000000001', 'Connectivity Alpha Gateway', 'CONNECTIVITY_ALPHA_GW'),
    ('94200000-0000-0000-0000-000000000002', '94000000-0000-0000-0000-000000000002', '94100000-0000-0000-0000-000000000002', 'Connectivity Beta Gateway', 'CONNECTIVITY_BETA_GW');

-- ---------------------------------------------------------------------------
-- A qualifying Energy Meter device model, required by
-- metadata.assert_asset_device_relationship() for PRIMARY_METER/
-- SECONDARY_METER asset_devices relationships (device-category
-- compatibility check). References the existing 'Energy Meter'
-- config.device_categories row by name, not a hardcoded id.
-- ---------------------------------------------------------------------------

INSERT INTO metadata.device_models (id, vendor, model, device_category_id)
SELECT '94250000-0000-0000-0000-000000000001'::uuid, 'Connectivity Test Vendor', 'Connectivity Test Meter', dc.id
FROM config.device_categories dc WHERE lower(dc.name) = 'energy meter';

-- ---------------------------------------------------------------------------
-- Devices — one per test case, all under the Alpha org unless noted.
-- ---------------------------------------------------------------------------

-- lifecycle_status is intentionally omitted here (defaults to 'REGISTERED')
-- for every device except the one deliberately marked DECOMMISSIONED below.
-- A trigger (metadata.reject_uncommissioned_active_device) rejects direct
-- INSERT/UPDATE of lifecycle_status='ACTIVE' outside the controlled
-- commissioning action; the connectivity function is lifecycle-blind
-- regardless, so no test case requires 'ACTIVE' specifically.
INSERT INTO metadata.devices (id, organization_id, gateway_id, name, external_id, protocol, device_model_id)
VALUES
    ('94300000-0000-0000-0000-000000000001', '94000000-0000-0000-0000-000000000001', '94200000-0000-0000-0000-000000000001', 'Receiving Device', 'CONN_DEV_RECEIVING', 'MQTT', '94250000-0000-0000-0000-000000000001'),
    ('94300000-0000-0000-0000-000000000002', '94000000-0000-0000-0000-000000000001', '94200000-0000-0000-0000-000000000001', 'Stale Device', 'CONN_DEV_STALE', 'MQTT', '94250000-0000-0000-0000-000000000001'),
    ('94300000-0000-0000-0000-000000000003', '94000000-0000-0000-0000-000000000001', '94200000-0000-0000-0000-000000000001', 'Silent Device', 'CONN_DEV_SILENT', 'MQTT', '94250000-0000-0000-0000-000000000001'),
    ('94300000-0000-0000-0000-000000000004', '94000000-0000-0000-0000-000000000001', '94200000-0000-0000-0000-000000000001', 'Delayed Device', 'CONN_DEV_DELAYED', 'MQTT', '94250000-0000-0000-0000-000000000001'),
    ('94300000-0000-0000-0000-000000000005', '94000000-0000-0000-0000-000000000001', '94200000-0000-0000-0000-000000000001', 'Never Seen Device', 'CONN_DEV_NEVER_SEEN', 'MQTT', '94250000-0000-0000-0000-000000000001'),
    ('94300000-0000-0000-0000-000000000006', '94000000-0000-0000-0000-000000000001', '94200000-0000-0000-0000-000000000001', 'Null Source Device', 'CONN_DEV_NULL_SOURCE', 'MQTT', '94250000-0000-0000-0000-000000000001'),
    ('94300000-0000-0000-0000-000000000008', '94000000-0000-0000-0000-000000000001', '94200000-0000-0000-0000-000000000001', 'Precedence Device', 'CONN_DEV_PRECEDENCE', 'MQTT', '94250000-0000-0000-0000-000000000001'),
    ('94300000-0000-0000-0000-000000000009', '94000000-0000-0000-0000-000000000001', '94200000-0000-0000-0000-000000000001', 'Secondary Meter Device', 'CONN_DEV_SECONDARY', 'MQTT', '94250000-0000-0000-0000-000000000001'),
    ('94300000-0000-0000-0000-000000000010', '94000000-0000-0000-0000-000000000002', '94200000-0000-0000-0000-000000000002', 'Beta Receiving Device', 'CONN_DEV_BETA_RECEIVING', 'MQTT', '94250000-0000-0000-0000-000000000001'),
    -- Dedicated PRIMARY_METER device for the multi-device asset test case.
    -- (uq_asset_devices_primary_meter allows at most one PRIMARY_METER
    -- relationship per device, so this must not reuse device ...0001.)
    ('94300000-0000-0000-0000-000000000011', '94000000-0000-0000-0000-000000000001', '94200000-0000-0000-0000-000000000001', 'Multi-Asset Primary Meter Device', 'CONN_DEV_MULTI_PRIMARY', 'MQTT', '94250000-0000-0000-0000-000000000001');

-- The decommissioned-device fixture is inserted REGISTERED (like every
-- other device above) and assigned to its asset normally; it is only
-- transitioned to DECOMMISSIONED afterward (below, once assigned), since a
-- trigger (reject_decommissioned_asset_device_assignment) rejects a *new*
-- asset_devices assignment to an already-decommissioned device.
INSERT INTO metadata.devices (id, organization_id, gateway_id, name, external_id, protocol, device_model_id)
VALUES
    ('94300000-0000-0000-0000-000000000007', '94000000-0000-0000-0000-000000000001', '94200000-0000-0000-0000-000000000001', 'Decommissioned Silent Device', 'CONN_DEV_DECOMMISSIONED', 'MQTT', '94250000-0000-0000-0000-000000000001');

-- ---------------------------------------------------------------------------
-- Assets and PRIMARY_METER relationships
-- ---------------------------------------------------------------------------

INSERT INTO metadata.assets (id, organization_id, site_id, asset_type_id, name, status, metering_requirement, metadata)
SELECT '94500000-0000-0000-0000-000000000001'::uuid, '94000000-0000-0000-0000-000000000001'::uuid, '94100000-0000-0000-0000-000000000001'::uuid, at.id, 'Receiving Asset', 'active', 'DIRECT_METER_REQUIRED', '{}'::jsonb FROM metadata.asset_types at ORDER BY at.name LIMIT 1;
INSERT INTO metadata.assets (id, organization_id, site_id, asset_type_id, name, status, metering_requirement, metadata)
SELECT '94500000-0000-0000-0000-000000000002'::uuid, '94000000-0000-0000-0000-000000000001'::uuid, '94100000-0000-0000-0000-000000000001'::uuid, at.id, 'Stale Asset', 'active', 'DIRECT_METER_REQUIRED', '{}'::jsonb FROM metadata.asset_types at ORDER BY at.name LIMIT 1;
INSERT INTO metadata.assets (id, organization_id, site_id, asset_type_id, name, status, metering_requirement, metadata)
SELECT '94500000-0000-0000-0000-000000000003'::uuid, '94000000-0000-0000-0000-000000000001'::uuid, '94100000-0000-0000-0000-000000000001'::uuid, at.id, 'Silent Asset', 'active', 'DIRECT_METER_REQUIRED', '{}'::jsonb FROM metadata.asset_types at ORDER BY at.name LIMIT 1;
INSERT INTO metadata.assets (id, organization_id, site_id, asset_type_id, name, status, metering_requirement, metadata)
SELECT '94500000-0000-0000-0000-000000000004'::uuid, '94000000-0000-0000-0000-000000000001'::uuid, '94100000-0000-0000-0000-000000000001'::uuid, at.id, 'Delayed Asset', 'active', 'DIRECT_METER_REQUIRED', '{}'::jsonb FROM metadata.asset_types at ORDER BY at.name LIMIT 1;
INSERT INTO metadata.assets (id, organization_id, site_id, asset_type_id, name, status, metering_requirement, metadata)
SELECT '94500000-0000-0000-0000-000000000005'::uuid, '94000000-0000-0000-0000-000000000001'::uuid, '94100000-0000-0000-0000-000000000001'::uuid, at.id, 'Never Seen Asset', 'active', 'DIRECT_METER_REQUIRED', '{}'::jsonb FROM metadata.asset_types at ORDER BY at.name LIMIT 1;
INSERT INTO metadata.assets (id, organization_id, site_id, asset_type_id, name, status, metering_requirement, metadata)
SELECT '94500000-0000-0000-0000-000000000006'::uuid, '94000000-0000-0000-0000-000000000001'::uuid, '94100000-0000-0000-0000-000000000001'::uuid, at.id, 'Null Source Asset', 'active', 'DIRECT_METER_REQUIRED', '{}'::jsonb FROM metadata.asset_types at ORDER BY at.name LIMIT 1;
INSERT INTO metadata.assets (id, organization_id, site_id, asset_type_id, name, status, metering_requirement, metadata)
SELECT '94500000-0000-0000-0000-000000000007'::uuid, '94000000-0000-0000-0000-000000000001'::uuid, '94100000-0000-0000-0000-000000000001'::uuid, at.id, 'Decommissioned Asset', 'active', 'DIRECT_METER_REQUIRED', '{}'::jsonb FROM metadata.asset_types at ORDER BY at.name LIMIT 1;
INSERT INTO metadata.assets (id, organization_id, site_id, asset_type_id, name, status, metering_requirement, metadata)
SELECT '94500000-0000-0000-0000-000000000008'::uuid, '94000000-0000-0000-0000-000000000001'::uuid, '94100000-0000-0000-0000-000000000001'::uuid, at.id, 'Precedence Asset', 'active', 'DIRECT_METER_REQUIRED', '{}'::jsonb FROM metadata.asset_types at ORDER BY at.name LIMIT 1;
INSERT INTO metadata.assets (id, organization_id, site_id, asset_type_id, name, status, metering_requirement, metadata)
SELECT '94500000-0000-0000-0000-000000000009'::uuid, '94000000-0000-0000-0000-000000000001'::uuid, '94100000-0000-0000-0000-000000000001'::uuid, at.id, 'No Assigned Device Asset', 'active', 'DIRECT_METER_REQUIRED', '{}'::jsonb FROM metadata.asset_types at ORDER BY at.name LIMIT 1;
INSERT INTO metadata.assets (id, organization_id, site_id, asset_type_id, name, status, metering_requirement, metadata)
SELECT '94500000-0000-0000-0000-000000000010'::uuid, '94000000-0000-0000-0000-000000000001'::uuid, '94100000-0000-0000-0000-000000000001'::uuid, at.id, 'Multi Device Asset', 'active', 'DIRECT_METER_REQUIRED', '{}'::jsonb FROM metadata.asset_types at ORDER BY at.name LIMIT 1;
INSERT INTO metadata.assets (id, organization_id, site_id, asset_type_id, name, status, metering_requirement, metadata)
SELECT '94500000-0000-0000-0000-000000000011'::uuid, '94000000-0000-0000-0000-000000000002'::uuid, '94100000-0000-0000-0000-000000000002'::uuid, at.id, 'Beta Receiving Asset', 'active', 'DIRECT_METER_REQUIRED', '{}'::jsonb FROM metadata.asset_types at ORDER BY at.name LIMIT 1;

INSERT INTO metadata.asset_devices (id, asset_id, device_id, relationship_type)
VALUES
    ('94600000-0000-0000-0000-000000000001', '94500000-0000-0000-0000-000000000001', '94300000-0000-0000-0000-000000000001', 'PRIMARY_METER'),
    ('94600000-0000-0000-0000-000000000002', '94500000-0000-0000-0000-000000000002', '94300000-0000-0000-0000-000000000002', 'PRIMARY_METER'),
    ('94600000-0000-0000-0000-000000000003', '94500000-0000-0000-0000-000000000003', '94300000-0000-0000-0000-000000000003', 'PRIMARY_METER'),
    ('94600000-0000-0000-0000-000000000004', '94500000-0000-0000-0000-000000000004', '94300000-0000-0000-0000-000000000004', 'PRIMARY_METER'),
    ('94600000-0000-0000-0000-000000000005', '94500000-0000-0000-0000-000000000005', '94300000-0000-0000-0000-000000000005', 'PRIMARY_METER'),
    ('94600000-0000-0000-0000-000000000006', '94500000-0000-0000-0000-000000000006', '94300000-0000-0000-0000-000000000006', 'PRIMARY_METER'),
    ('94600000-0000-0000-0000-000000000007', '94500000-0000-0000-0000-000000000007', '94300000-0000-0000-0000-000000000007', 'PRIMARY_METER'),
    ('94600000-0000-0000-0000-000000000008', '94500000-0000-0000-0000-000000000008', '94300000-0000-0000-0000-000000000008', 'PRIMARY_METER'),
    -- Multi-device asset: a non-primary device is assigned first, then the
    -- PRIMARY_METER device, to prove selection is by relationship_type, not
    -- insertion/id order.
    ('94600000-0000-0000-0000-000000000010', '94500000-0000-0000-0000-000000000010', '94300000-0000-0000-0000-000000000009', 'SECONDARY_METER'),
    ('94600000-0000-0000-0000-000000000011', '94500000-0000-0000-0000-000000000010', '94300000-0000-0000-0000-000000000011', 'PRIMARY_METER'),
    ('94600000-0000-0000-0000-000000000012', '94500000-0000-0000-0000-000000000011', '94300000-0000-0000-0000-000000000010', 'PRIMARY_METER');
    -- '94500000-...09' (No Assigned Device Asset) intentionally has no
    -- asset_devices row at all.

-- Now that it is assigned (relationship 94600000-...0007 above), transition
-- the decommissioned-device fixture out of REGISTERED. This is a lifecycle
-- change on an already-assigned device, not a new assignment, so it is not
-- subject to reject_decommissioned_asset_device_assignment().
UPDATE metadata.devices
SET lifecycle_status = 'DECOMMISSIONED'
WHERE id = '94300000-0000-0000-0000-000000000007';

-- ---------------------------------------------------------------------------
-- telemetry.device_raw_receipt_state fixtures, relative to the fixed
-- reference instant 2026-01-01 12:00:00+00.
-- ---------------------------------------------------------------------------

INSERT INTO telemetry.device_raw_receipt_state (device_id, latest_raw_received_at, latest_raw_source_timestamp, updated_at)
VALUES
    -- Recently reporting: receipt 5s old, source 5s old -> RECEIVING
    ('94300000-0000-0000-0000-000000000001', TIMESTAMPTZ '2026-01-01 11:59:55+00', TIMESTAMPTZ '2026-01-01 11:59:55+00', TIMESTAMPTZ '2026-01-01 11:59:55+00'),
    -- Stale: receipt 400s old (>300s receiving, <3600s silent) -> STALE
    ('94300000-0000-0000-0000-000000000002', TIMESTAMPTZ '2026-01-01 11:53:20+00', TIMESTAMPTZ '2026-01-01 11:53:20+00', TIMESTAMPTZ '2026-01-01 11:53:20+00'),
    -- Silent: receipt 4000s old (>3600s silent) -> SILENT
    ('94300000-0000-0000-0000-000000000003', TIMESTAMPTZ '2026-01-01 10:53:20+00', TIMESTAMPTZ '2026-01-01 10:53:20+00', TIMESTAMPTZ '2026-01-01 10:53:20+00'),
    -- Delayed: receipt fresh (5s), source 1000s old (>900s delay) -> DELAYED
    ('94300000-0000-0000-0000-000000000004', TIMESTAMPTZ '2026-01-01 11:59:55+00', TIMESTAMPTZ '2026-01-01 11:43:20+00', TIMESTAMPTZ '2026-01-01 11:59:55+00'),
    -- Null source device: receipt fresh (5s), source NULL -> RECEIVING
    ('94300000-0000-0000-0000-000000000006', TIMESTAMPTZ '2026-01-01 11:59:55+00', NULL, TIMESTAMPTZ '2026-01-01 11:59:55+00'),
    -- Decommissioned device: receipt 4000s old (>3600s silent) -> SILENT
    -- (documents the confirmed gap: lifecycle_status is not incorporated)
    ('94300000-0000-0000-0000-000000000007', TIMESTAMPTZ '2026-01-01 10:53:20+00', TIMESTAMPTZ '2026-01-01 10:53:20+00', TIMESTAMPTZ '2026-01-01 10:53:20+00'),
    -- Precedence device: receipt 7200s old (SILENT) AND source 7200s old
    -- (would also satisfy DELAYED) -> SILENT must win
    ('94300000-0000-0000-0000-000000000008', TIMESTAMPTZ '2026-01-01 10:00:00+00', TIMESTAMPTZ '2026-01-01 10:00:00+00', TIMESTAMPTZ '2026-01-01 10:00:00+00'),
    -- Secondary meter device (multi-device asset, non-primary): also fresh,
    -- so a wrong selection would still show RECEIVING and hide the bug;
    -- verified explicitly by asserting source_device_id below.
    ('94300000-0000-0000-0000-000000000009', TIMESTAMPTZ '2026-01-01 11:59:55+00', TIMESTAMPTZ '2026-01-01 11:59:55+00', TIMESTAMPTZ '2026-01-01 11:59:55+00'),
    -- Beta org receiving device
    ('94300000-0000-0000-0000-000000000010', TIMESTAMPTZ '2026-01-01 11:59:55+00', TIMESTAMPTZ '2026-01-01 11:59:55+00', TIMESTAMPTZ '2026-01-01 11:59:55+00'),
    -- Multi-asset PRIMARY_METER device: also fresh.
    ('94300000-0000-0000-0000-000000000011', TIMESTAMPTZ '2026-01-01 11:59:55+00', TIMESTAMPTZ '2026-01-01 11:59:55+00', TIMESTAMPTZ '2026-01-01 11:59:55+00');
    -- '94300000-...05' (Never Seen Device) intentionally has no
    -- device_raw_receipt_state row at all.

-- ---------------------------------------------------------------------------
-- Assertions
-- ---------------------------------------------------------------------------

DO $$
DECLARE
    v_at CONSTANT TIMESTAMPTZ := TIMESTAMPTZ '2026-01-01 12:00:00+00';
    r RECORD;
BEGIN
    -- 1. Recently reporting device -> RECEIVING
    SELECT * INTO r FROM analytics.get_grafana_asset_connectivity_context(94001, '94500000-0000-0000-0000-000000000001', v_at);
    IF r.connectivity_state IS DISTINCT FROM 'RECEIVING' THEN
        RAISE EXCEPTION 'Recently-reporting device: expected RECEIVING, got %', r.connectivity_state;
    END IF;

    -- 2. Stale device -> STALE
    SELECT * INTO r FROM analytics.get_grafana_asset_connectivity_context(94001, '94500000-0000-0000-0000-000000000002', v_at);
    IF r.connectivity_state IS DISTINCT FROM 'STALE' THEN
        RAISE EXCEPTION 'Stale device: expected STALE, got %', r.connectivity_state;
    END IF;

    -- 3. Silent device -> SILENT
    SELECT * INTO r FROM analytics.get_grafana_asset_connectivity_context(94001, '94500000-0000-0000-0000-000000000003', v_at);
    IF r.connectivity_state IS DISTINCT FROM 'SILENT' THEN
        RAISE EXCEPTION 'Silent device: expected SILENT, got %', r.connectivity_state;
    END IF;

    -- 4. Delayed device -> DELAYED
    SELECT * INTO r FROM analytics.get_grafana_asset_connectivity_context(94001, '94500000-0000-0000-0000-000000000004', v_at);
    IF r.connectivity_state IS DISTINCT FROM 'DELAYED' THEN
        RAISE EXCEPTION 'Delayed device: expected DELAYED, got %', r.connectivity_state;
    END IF;

    -- 5. Never-seen device (no raw-receipt row at all) -> NEVER_SEEN
    SELECT * INTO r FROM analytics.get_grafana_asset_connectivity_context(94001, '94500000-0000-0000-0000-000000000005', v_at);
    IF r.connectivity_state IS DISTINCT FROM 'NEVER_SEEN' THEN
        RAISE EXCEPTION 'Never-seen device: expected NEVER_SEEN, got %', r.connectivity_state;
    END IF;

    -- 6. NULL source timestamp with fresh receipt -> RECEIVING, not DELAYED
    SELECT * INTO r FROM analytics.get_grafana_asset_connectivity_context(94001, '94500000-0000-0000-0000-000000000006', v_at);
    IF r.connectivity_state IS DISTINCT FROM 'RECEIVING' THEN
        RAISE EXCEPTION 'NULL-source fresh-receipt device: expected RECEIVING, got %', r.connectivity_state;
    END IF;
    IF r.latest_raw_source_timestamp IS NOT NULL THEN
        RAISE EXCEPTION 'NULL-source device: expected latest_raw_source_timestamp NULL, got %', r.latest_raw_source_timestamp;
    END IF;

    -- 7. No assigned device -> NO_ASSIGNED_DEVICE
    SELECT * INTO r FROM analytics.get_grafana_asset_connectivity_context(94001, '94500000-0000-0000-0000-000000000009', v_at);
    IF r.connectivity_state IS DISTINCT FROM 'NO_ASSIGNED_DEVICE' THEN
        RAISE EXCEPTION 'No-assigned-device asset: expected NO_ASSIGNED_DEVICE, got %', r.connectivity_state;
    END IF;
    IF r.source_device_id IS NOT NULL THEN
        RAISE EXCEPTION 'No-assigned-device asset: expected source_device_id NULL, got %', r.source_device_id;
    END IF;

    -- 8. Decommissioned device with old telemetry -> SILENT
    -- (documents the confirmed gap: lifecycle_status is not a state input)
    SELECT * INTO r FROM analytics.get_grafana_asset_connectivity_context(94001, '94500000-0000-0000-0000-000000000007', v_at);
    IF r.connectivity_state IS DISTINCT FROM 'SILENT' THEN
        RAISE EXCEPTION 'Decommissioned device: expected SILENT (lifecycle-blind, by design today), got %', r.connectivity_state;
    END IF;

    -- 9. Deterministic precedence: a device satisfying both SILENT and
    --    DELAYED conditions must resolve to SILENT (higher precedence).
    SELECT * INTO r FROM analytics.get_grafana_asset_connectivity_context(94001, '94500000-0000-0000-0000-000000000008', v_at);
    IF r.connectivity_state IS DISTINCT FROM 'SILENT' THEN
        RAISE EXCEPTION 'Precedence device: expected SILENT to win over DELAYED, got %', r.connectivity_state;
    END IF;

    -- 10. Multi-device asset: PRIMARY_METER must be selected regardless of
    --     assignment order (SECONDARY_METER row was inserted first).
    SELECT * INTO r FROM analytics.get_grafana_asset_connectivity_context(94001, '94500000-0000-0000-0000-000000000010', v_at);
    IF r.source_device_id IS DISTINCT FROM '94300000-0000-0000-0000-000000000011'::uuid THEN
        RAISE EXCEPTION 'Multi-device asset: expected PRIMARY_METER device %, got %',
            '94300000-0000-0000-0000-000000000011'::uuid, r.source_device_id;
    END IF;
    IF r.relationship_type IS DISTINCT FROM 'PRIMARY_METER' THEN
        RAISE EXCEPTION 'Multi-device asset: expected relationship_type PRIMARY_METER, got %', r.relationship_type;
    END IF;

    -- 11. Correct site association is returned alongside the state.
    SELECT * INTO r FROM analytics.get_grafana_asset_connectivity_context(94001, '94500000-0000-0000-0000-000000000001', v_at);
    IF r.site_id IS DISTINCT FROM '94100000-0000-0000-0000-000000000001'::uuid THEN
        RAISE EXCEPTION 'Site association: expected Alpha site, got %', r.site_id;
    END IF;
END
$$;

-- ---------------------------------------------------------------------------
-- 12. Tenant isolation: Alpha's grafana_org_id against Beta's asset_id must
--     return zero rows (silent tenant mismatch, not an error).
-- ---------------------------------------------------------------------------

DO $$
DECLARE
    cross_rows BIGINT;
BEGIN
    SELECT count(*) INTO cross_rows
    FROM analytics.get_grafana_asset_connectivity_context(94001, '94500000-0000-0000-0000-000000000011', TIMESTAMPTZ '2026-01-01 12:00:00+00');

    IF cross_rows <> 0 THEN
        RAISE EXCEPTION 'Tenant isolation violated: Alpha org_id resolved % rows for a Beta asset', cross_rows;
    END IF;

    -- Beta's own org_id against its own asset must succeed normally.
    SELECT count(*) INTO cross_rows
    FROM analytics.get_grafana_asset_connectivity_context(94002, '94500000-0000-0000-0000-000000000011', TIMESTAMPTZ '2026-01-01 12:00:00+00')
    WHERE connectivity_state = 'RECEIVING';

    IF cross_rows <> 1 THEN
        RAISE EXCEPTION 'Beta asset under its own org_id: expected exactly 1 RECEIVING row, got %', cross_rows;
    END IF;
END
$$;

ROLLBACK;

SELECT 'Connectivity semantic contract assertions passed.' AS result;
