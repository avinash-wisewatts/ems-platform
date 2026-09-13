# Asset Model

```
Status: CURRENT
Last verified: 2026-08-24
Verification basis: Repository (postgres/ddl/04_metadata.sql, postgres/ddl/89_asset_metering_requirements.sql, postgres/ddl/92_asset_device_relationship_management.sql) + Staging (live, 22-asset Meenaxy Pharma example)
```

## `metadata.assets`

An asset represents a piece of production equipment (a compressor, a coating pan, an HVAC unit) — the thing a business user actually cares about metering, distinct from the physical meter device attached to it (see `06-data-model.md` for that distinction).

Key columns:
- `asset_type_id` → `metadata.asset_types` — a global, shared controlled vocabulary (e.g. "Air Compressors", "Coating Pans (Tablet/Sugar)"), not organization-scoped. New asset types are added by name, case-insensitively unique (`asset_types_name_ci_uq`).
- `parent_asset_id` → self-reference, enabling asset composition into a hierarchy. **Verified**: all 22 Meenaxy Pharma assets have `parent_asset_id IS NULL` — a flat structure in this instance. The hierarchy capability exists (`trg_validate_asset_hierarchy` prevents cycles/self-parenting) but nothing in this session's evidence confirms it's used anywhere in production; not verified either way beyond Meenaxy.
- `space_id`, `building_id`, `floor_id` — physical placement, independent of any device's placement.
- `metering_requirement` — one of `DIRECT_METER_REQUIRED`, `DESCENDANT_COVERAGE_ALLOWED`, `NOT_REQUIRED`. No default is provided at the schema level (`postgres/ddl/89_asset_metering_requirements.sql`'s comment: "onboarding must make a deliberate production decision for every asset"). All 22 Meenaxy assets are `DIRECT_METER_REQUIRED`.
- `status` (free text, default `'active'`) vs. `lifecycle_status` (controlled: `DRAFT`/`COMMISSIONING`/`ACTIVE`/`INACTIVE`/`DECOMMISSIONED`) — two separate columns; don't assume they always move together.

## `metadata.asset_devices` — the relationship table

Many-to-many between assets and devices, typed by `relationship_type`, which must reference an active row in `config.asset_device_relationship_types`. Nine seeded types, in `display_order`:

| Code | Exclusivity policy | Meaning |
|---|---|---|
| `PRIMARY_METER` | `ASSET_AND_DEVICE_UNIQUE` | Authoritative energy meter for one asset — enforced by two partial unique indexes (`asset_devices_primary_meter_asset_uq` on `asset_id`, `asset_devices_primary_meter_device_uq` on `device_id`, both `WHERE relationship_type='PRIMARY_METER'`), so a device can be PRIMARY_METER for at most one asset and vice versa |
| `SECONDARY_METER` | `NON_EXCLUSIVE` | Additional energy meter on the same asset |
| `TEMPERATURE_SENSOR`, `PRESSURE_SENSOR`, `FLOW_SENSOR`, `VIBRATION_SENSOR` | `NON_EXCLUSIVE` | Environmental/condition sensors |
| `RUN_STATUS`, `FAULT_STATUS`, `STATUS_INPUT` | `NON_EXCLUSIVE` | Binary state inputs |

`config.asset_device_relationship_category_compatibility` constrains which `config.device_categories` value is valid for which relationship type — e.g. `PRIMARY_METER` requires `Energy Meter` category, `RUN_STATUS`/`FAULT_STATUS`/`STATUS_INPUT` require `Digital Input Module`/`PLC`/`BMS Controller`. This is enforced live by `trg_validate_asset_device_relationship` (see `05-database.md`), plus a hard rule specific to `PRIMARY_METER`: the device's category name must be exactly `'energy meter'` (case-insensitive), not merely "compatible."

Verified in Meenaxy Pharma: all 22 relationships are `PRIMARY_METER`, 1:1 device↔asset, zero duplicates or orphans (re-verified live this session, `metadata.asset_devices` join integrity — 0 orphaned rows).

## What this table does NOT tell you

`asset_devices` existing does not mean the device is commissioned, and does not mean telemetry is flowing — see `06-data-model.md`'s three-state distinction. It only means the metadata graph is wired correctly for the analytics/Grafana layer to resolve an asset's meter.
