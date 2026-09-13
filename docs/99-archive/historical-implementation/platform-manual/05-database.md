# Database Architecture

```
Status: CURRENT
Last verified: 2026-08-24
Verification basis: Repository (postgres/ddl, postgres/migrations) + Staging (live schema introspection via ems_admin)
```

The platform runs on PostgreSQL/TimescaleDB. Schema is organized into purpose-built schemas rather than one flat namespace. This document maps the schemas that matter for understanding or operating the system; it does not enumerate every object (see `reference/database-object-catalog.md` for the operationally-relevant object list).

## Schema map

| Schema | Purpose | Owns |
|---|---|---|
| `metadata` | Tenant/asset/device inventory — the "what exists" layer | organizations, sites, buildings, floors, spaces, gateways, devices, assets, device_identifiers, asset_devices, logical_points, device_field_mapping, grafana_organization_map, sectors/sub_sectors |
| `config` | Controlled reference/vocabulary data shared across tenants — the "what's allowed" layer | device_categories, device_profiles, profile_field_mapping, device_profile_categories, asset_device_relationship_types, asset_device_relationship_category_compatibility, device_operational_policies, engineering_units, protocols, point_categories, interval_quality_rules, telemetry_capture_policies, site_demand_policies, portal_role/permission tables |
| `telemetry` | Raw and near-raw measured data — the "what was received" layer | raw_messages, normalized_points, energy_measurements, environment_measurements, water_measurements, device_status, device_telemetry_state, device_point_state, capture_bucket_samples, plus TimescaleDB continuous aggregates (`ca_energy_*`, `ca_environment_*`) |
| `analytics` | Derived/validated/semantic data and Grafana-facing views — the "what it means" layer | energy_consumption_{1min,5min,15min,hourly,daily} (persisted, validated), demand_intervals/demand_state, ~80 views including the `v_grafana_*` family consumed directly by dashboards |
| `admin` | Admin-portal application logic (portal users, roles, onboarding functions, audit log) | not deeply inventoried this pass — see `13-admin-portal.md` |
| `public` | Telegraf's insert-only landing schema only | `mqtt_staging` adapter view → `telemetry.raw_messages` |

## metadata: entities and relationships

`organizations` (1) → `sites` (N) → `buildings` (N) → `floors` (N) → `spaces` (N). `gateways` and `devices` optionally reference a `space_id`/`building_id`/`floor_id` for physical placement; `devices` additionally has a `location_mode` column (`'GATEWAY'` or `'DEVICE'`) that determines whether its effective location is inherited from its gateway or set explicitly. `assets` sit in a separate hierarchy from the physical building tree — an asset has an optional `space_id` and a `parent_asset_id` (self-referencing, enabling asset-to-asset composition; verified flat/unused for the current Meenaxy Pharma data — all 22 assets have `parent_asset_id IS NULL`). Devices and assets are linked many-to-many through `asset_devices`, typed by `relationship_type` (see `09-asset-model.md`).

## config: how the vocabulary constrains metadata

`device_categories` (e.g. "Energy Meter") is the controlled classification a `metadata.device_models` row must reference. `device_profiles` (e.g. `ENERGY_METER_ENISCOPE_V1`) defines a reusable telemetry-field mapping; `device_profile_categories` is the many-to-many table stating which categories a profile is valid for. `asset_device_relationship_types` (9 seeded values: `PRIMARY_METER`, `SECONDARY_METER`, `TEMPERATURE_SENSOR`, `PRESSURE_SENSOR`, `FLOW_SENSOR`, `VIBRATION_SENSOR`, `RUN_STATUS`, `FAULT_STATUS`, `STATUS_INPUT`) and `asset_device_relationship_category_compatibility` together constrain which device category can fill which relationship role on an asset.

## Verified trigger set (metadata schema)

Confirmed live this session via `pg_trigger`/`pg_proc`/`pg_get_functiondef` under the `ems_admin` role — **12 active triggers**, none of which exist in a single obvious place in the repo (they accumulate across many numbered DDL/migration files):

| Table | Trigger | Function | Effect |
|---|---|---|---|
| `assets` | `assets_validate_physical_location` | `validate_asset_physical_location` | If `space_id` is set, `floor_id` and `building_id` must **also** be set explicitly on the row (not merely derivable by joining through the hierarchy) — undocumented in `postgres/ddl/04_metadata.sql`'s original table definition, discovered only by hitting it live |
| `assets` | `trg_generate_asset_external_id` | `generate_asset_external_id` | Auto-generates `external_id` from `name` when omitted; uppercases and normalizes when supplied |
| `assets` | `trg_validate_asset_hierarchy` | `validate_asset_hierarchy` | Prevents self-parenting and cycles in `parent_asset_id`; no-op when `parent_asset_id IS NULL` |
| `assets` | `trg_validate_asset_ownership` | `validate_tenant_site_ownership` | Cross-checks org/site consistency against referenced building/floor/space/parent |
| `devices` | `trg_validate_device_physical_location` | `validate_device_physical_location` | Device's organization must match its gateway's; building/floor/space (if set) must belong to the gateway's site |
| `devices` | `trg_validate_device_ownership` | `validate_tenant_site_ownership` | Same shared function as above, devices variant |
| `devices` | `trg_reject_obsolete_device_lifecycle_status` | `reject_obsolete_device_lifecycle_status` | Only `REGISTERED`/`ACTIVE`/`INACTIVE`/`DECOMMISSIONED` are valid values |
| `devices` | `trg_reject_uncommissioned_active_device` | `reject_uncommissioned_active_device` | Blocks setting `lifecycle_status='ACTIVE'` directly unless the session is inside a controlled commissioning transaction (checked via a session-local `ems.controlled_device_commissioning_id` setting matched to `current_user='ems_admin'`) |
| `devices` | `trg_sync_device_points_after_profile_change` | `sync_device_points_after_profile_change` (schema `config`) | On insert, or when `profile_id` changes, calls `config.sync_device_point_configuration()` to populate `config.device_point_configuration` from `config.profile_field_mapping` |
| `asset_devices` | `trg_validate_asset_device_relationship` | `validate_asset_device_relationship` | Enforces `asset_device_relationship_category_compatibility` and the `PRIMARY_METER`-must-be-`Energy Meter` rule |
| `asset_devices` | `trg_validate_asset_device_ownership` | `validate_tenant_site_ownership` | Shared ownership function, asset_devices variant |
| `asset_devices` | `trg_reject_decommissioned_asset_device_assignment` | `reject_decommissioned_asset_device_assignment` | Blocks new relationships to a `DECOMMISSIONED` asset or device |

**Drift note — role-based trigger visibility (unresolved, low severity):** the `ems_readonly` role, despite having `SELECT` on `metadata`/`config` tables, could **not** see any of these triggers via `information_schema.triggers` (returned 0 rows) earlier in this same investigation. The `ems_admin` role saw all 12 immediately via the same query. This was not root-caused — `information_schema.triggers` is documented to require some privilege on the underlying table, and `SELECT` should qualify, so this is an open, unexplained gap between two roles' catalog visibility. **Practical consequence:** any future investigation using a read-only role must not conclude "no triggers exist" from an empty `information_schema.triggers` result — cross-check with `pg_trigger` directly under a role known to have full catalog visibility.

## Repository vs. live: what to trust

`postgres/ddl/*` is the canonical fresh-deployment schema; `postgres/migrations/*` is the upgrade path applied to already-running databases (see `18-environment-management.md`). Both together, applied in order, should equal the live schema — but this session found at least one case where they don't fully agree with what's live (see `11-aggregation.md`'s note that `analytics.energy_consumption_{15min,hourly,daily}` exist only as migrations, with no corresponding `ddl/` canonical file found). Treat `ddl/` + `migrations/` as the source of truth for *intent*; treat a live introspection query as the source of truth for *current fact*, and document any gap between them rather than assuming one is wrong.
