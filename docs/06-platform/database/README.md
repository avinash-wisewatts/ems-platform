# Database Architecture

Status: CURRENT · Last reviewed: 2026-08-24
Verification basis: Repository (postgres/ddl, postgres/migrations) + Staging (live schema introspection via ems_admin)

The platform runs on PostgreSQL/TimescaleDB. Schema is organized into
purpose-built schemas rather than one flat namespace.

## Schema map

| Schema | Purpose | Owns |
|---|---|---|
| `metadata` | Tenant/asset/device inventory — "what exists" | organizations, sites, buildings, floors, spaces, gateways, devices, assets, device_identifiers, asset_devices, logical_points, grafana_organization_map, sectors |
| `config` | Controlled reference/vocabulary shared across tenants — "what's allowed" | device_categories, device_profiles, profile_field_mapping, device_profile_categories, asset_device_relationship_types + compatibility, energy_register_semantics, engineering_units, protocols, telemetry_capture_policies, site_demand_policies, portal_role/permission tables |
| `telemetry` | Raw and near-raw measured data — "what was received" | raw_messages, normalized_points, energy_measurements, environment_measurements, water_measurements, device_status, device_telemetry_state, capture_bucket_samples, plus continuous aggregates |
| `analytics` | Derived/validated/semantic data and Grafana-facing views — "what it means" | energy_consumption_{1min,5min,15min,hourly,daily} (persisted), demand_intervals/demand_state, ~80 views including `v_grafana_*` |
| `admin` | Admin-portal application logic (portal users, roles, onboarding functions, audit log) | — |
| `public` | Telegraf's insert-only landing schema only | `mqtt_staging` adapter view |

## metadata: entities and relationships

`organizations` (1) → `sites` (N) → `buildings` (N) → `floors` (N) →
`spaces` (N). `gateways`/`devices` optionally reference a
`space_id`/`building_id`/`floor_id`; `devices` additionally has
`location_mode` (`GATEWAY`/`DEVICE`) determining whether location is
inherited or explicit. `assets` sit in a separate hierarchy — see
[../telemetry/data-model.md](../telemetry/data-model.md).

## Verified trigger set (metadata schema)

**12 active triggers** confirmed live via `pg_trigger`/`pg_proc` under the
`ems_admin` role — none exist in a single obvious place in the repo (they
accumulate across many numbered DDL/migration files). See
[../../04-architecture/security-and-tenancy.md](../../04-architecture/security-and-tenancy.md)
for the full table and the `ems_readonly`/`ems_admin` visibility gap this
surfaced.

## Repository vs. live: what to trust

`postgres/ddl/*` is the canonical fresh-deployment schema; `postgres/migrations/*`
is the upgrade path applied to already-running databases (see
[../deployment/README.md](../deployment/README.md)). Both together, applied
in order, should equal the live schema — but this has at least one known
gap (`analytics.energy_consumption_{15min,hourly,daily}` exist only as
migrations, no corresponding `ddl/` file — see
[../telemetry/aggregation.md](../telemetry/aggregation.md)). Treat
`ddl/`+`migrations/` as the source of truth for *intent*; a live
introspection query as the source of truth for *current fact*; document any
gap between them rather than assuming one is wrong.

## Object catalog (operationally-relevant, not exhaustive)

**metadata** (21 base tables, confirmed live): `organizations`, `sites`,
`buildings`, `floors`, `spaces`, `gateways`, `gateway_models`, `devices`,
`device_models`, `device_identifiers`, `assets`, `asset_types`,
`asset_devices`, `asset_device_relationship_history`, `asset_points`,
`logical_points`, `device_field_mapping`, `grafana_organization_map`,
`sectors`, `sub_sectors`, `sub_sector_asset_mapping`.

**config** (24 base tables, confirmed live): `device_categories`,
`device_profiles`, `profile_field_mapping`, `device_profile_categories`,
`device_operational_policies`, `device_point_configuration`,
`asset_device_relationship_types` (+ compatibility), `energy_register_semantics`,
`demand_register_semantics`, `engineering_units`, `protocols`,
`point_categories`, `status_definitions`, `interval_quality_rules`,
`telemetry_capture_policies`, `telemetry_availability_policy`,
`gateway_connectivity_policy`, `site_demand_policies`,
`site_energy_meter_roles`, `site_energy_roles`, `portal_permission_definitions`,
`portal_role_definitions`, `portal_role_permissions`.

**telemetry hypertables**: `raw_messages`, `raw_message_failures`,
`normalized_points`, `energy_measurements`, `environment_measurements`,
`environment_daily`, `water_measurements`, `device_status`, `asset_health`.

**telemetry continuous aggregates** (16 confirmed): `ca_energy_{1min,5min,
15min,hourly,daily}`, `ca_energy_phase_power_{1min,5min,15min,hourly,daily}`,
`ca_energy_electrical_ext_{15min,hourly}`, `ca_environment_{15min,hourly}`,
plus `analytics.generic_telemetry_{15m,1h}`.

**analytics hypertables**: `energy_consumption_{1min,5min,15min,hourly,daily}`,
`demand_intervals`, `demand_state`.

**analytics views** (84 confirmed live) grouped by apparent purpose:
Grafana-facing `v_grafana_*` (17); energy consumption/reporting `v_energy_*`
(20+ — **documented near-duplication finding**, treat any as unverified
for a given purpose until checked against an actual consumer); asset-scoped
`v_asset_*`; operational/commissioning `v_commissioning_readiness`,
`v_device_telemetry_availability`, `v_gateway_connectivity`; environment
sensors `v_environment_*`.

**telemetry views**: `v_energy_measurements_full_resolution`,
`v_energy_measurements_route`, `v_energy_meter`,
`v_environment_measurements_full_resolution`,
`v_environment_measurements_route`, `v_normalized_points`, `v_rtdata`.

**Confirmed absent**: `pg_cron` is **not** installed on staging — background
jobs run via TimescaleDB's own job scheduler
(`timescaledb_information.jobs`, `add_job`/`alter_job`), not `pg_cron`.
