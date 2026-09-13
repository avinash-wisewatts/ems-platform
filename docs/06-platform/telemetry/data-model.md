# Data Model: Organization → Site → Location → Gateway → Device → Asset

Status: CURRENT · Last reviewed: 2026-08-24
Verification basis: Repository + Staging (Meenaxy Pharma commissioning worked example)

## The hierarchy

```text
Organization  (tenant boundary)
  └─ Site
       └─ Building
            └─ Floor
                 └─ Space
       └─ Gateway  (physical concentrator, optionally placed in a building/floor/space)
            └─ Device  (physical meter/sensor behind the gateway)
                 └─ [asset_devices] ──── Asset  (a piece of production equipment)
```

This is the current, live implementation model. The customer-facing
simplification of this hierarchy (`Organisation/Portfolio → Site → Space →
Asset`) and its noted tension with the frozen future-state model are
discussed in
[../../00-governance/decisions/ADR-002-hierarchy-model.md](../../00-governance/decisions/ADR-002-hierarchy-model.md).

Worked example (Meenaxy Pharma staging commissioning, business keys not
internal UUIDs): Organization `MEENAXY_PHARMA` → Site `UNIT_2` → Building
`PRODUCTION` → Floors `GROUND`/`MEZZANINE` → Spaces `PRODUCTIONLINE_1`/
`PRODUCTIONLINE_2`/`DISTRIBUTIONPANEL`; 3 gateways; 22 devices; 22 assets,
each linked to exactly one device via `asset_devices`
(`relationship_type='PRIMARY_METER'`).

## The identity chain that isn't a straight line

A device's telemetry identifies it by a **physical identifier** first:

```text
MQTT_UID (physical hardware address, e.g. 80:34:28:16:22:fe:00:01)
   │  metadata.device_identifiers, identifier_type='MQTT_UID'
   │  UNIQUE across the entire platform (not per-org)
   ▼
metadata.devices.id (internal UUID)
```

Several *separate* classification concepts, easy to conflate, do not
collapse into each other:

| Concept | Table | Example | Question it answers |
|---|---|---|---|
| Device model | `metadata.device_models` | vendor=`Best Energy`, model=`Eniscope Energy Meter` | What physical product is this? |
| Device category | `config.device_categories` | `Energy Meter` | What class of thing is it, for compatibility rules? |
| Device profile | `config.device_profiles` | `ENERGY_METER_ENISCOPE_V1` | How do I interpret its raw telemetry payload? |
| Asset type | `metadata.asset_types` | `Electric Motors (Standalone)` | What kind of production equipment is the *asset*, independent of the meter? |
| Asset | `metadata.assets` | `MICRO_PULVERIZER_P1_MPL_01` | The actual piece of equipment a business user cares about. |
| Telemetry point | `metadata.logical_points` | `ENERGY_IMPORT_TOTAL` | One named measurable field within a device's telemetry payload. |

**Common confusion**: "device model" and "device profile" sound
interchangeable but are not — a device model is a hardware/vendor fact; a
device profile is a payload-interpretation fact. `admin.create_device()`
validates the chosen profile is compatible with the chosen model's category
via `config.device_profile_categories` — model and profile are
cross-checked, not implicitly linked.

## "Device exists" ≠ "commissioned" ≠ "producing telemetry"

Three separate, independently-observable states:

1. **Device exists**: a row in `metadata.devices`. `lifecycle_status`
   defaults to `REGISTERED`.
2. **Device is commissioned**: `lifecycle_status='ACTIVE'`, permitted only
   via `admin.commission_device()`.
3. **Device is producing telemetry**: `telemetry.device_telemetry_state.latest_received_timestamp`
   is recent. A device can be `ACTIVE` and simultaneously producing
   telemetry — but the two facts come from different tables and must be
   checked separately. A device can be `REGISTERED` (not commissioned)
   while still receiving telemetry into raw tables, since ingestion doesn't
   gate on lifecycle_status.

See [onboarding-and-commissioning.md](onboarding-and-commissioning.md) for
the full workflow.

## Asset model

An asset represents a piece of production equipment — the thing a business
user cares about metering, distinct from the physical meter device attached
to it.

- `asset_type_id` → `metadata.asset_types` — a global, shared controlled
  vocabulary, not organization-scoped.
- `parent_asset_id` → self-reference for asset composition. Verified: all
  22 Meenaxy Pharma assets have `parent_asset_id IS NULL` (flat in this
  instance) — the hierarchy capability exists (`trg_validate_asset_hierarchy`
  prevents cycles/self-parenting) but no evidence confirms it's used
  anywhere in production beyond that.
- `metering_requirement` — `DIRECT_METER_REQUIRED` /
  `DESCENDANT_COVERAGE_ALLOWED` / `NOT_REQUIRED`. No schema-level default —
  "onboarding must make a deliberate production decision for every asset."
- `status` (free text) vs. `lifecycle_status` (controlled) — two separate
  columns; don't assume they move together.

### `metadata.asset_devices` — the relationship table

Many-to-many between assets and devices, typed by `relationship_type` (9
seeded types): `PRIMARY_METER` (exclusive both directions — a device is
PRIMARY_METER for at most one asset and vice versa), `SECONDARY_METER`,
`TEMPERATURE_SENSOR`, `PRESSURE_SENSOR`, `FLOW_SENSOR`, `VIBRATION_SENSOR`,
`RUN_STATUS`, `FAULT_STATUS`, `STATUS_INPUT`. `PRIMARY_METER` additionally
requires the device's category to be exactly `'energy meter'`
(case-insensitive), enforced live by `trg_validate_asset_device_relationship`.

Verified in Meenaxy Pharma: all 22 relationships are `PRIMARY_METER`, 1:1
device↔asset, zero duplicates or orphans.

**What `asset_devices` does NOT tell you**: its existence does not mean the
device is commissioned, and does not mean telemetry is flowing — it only
means the metadata graph is wired correctly for the analytics/Grafana layer
to resolve an asset's meter.
