# Database Object Catalog

```
Status: CURRENT
Last verified: 2026-08-24
Verification basis: Staging (live, information_schema + pg_trigger/pg_proc + timescaledb_information, via ems_admin)
```

Operationally-relevant objects only — not an exhaustive catalog of every table/view in the database. See `05-database.md` for schema-level purpose and `06-data-model.md`/`09-asset-model.md` for how the `metadata`/`config` tables relate.

## metadata schema — base tables (21 confirmed live)

`organizations`, `sites`, `buildings`, `floors`, `spaces`, `gateways`, `gateway_models`, `devices`, `device_models`, `device_identifiers`, `assets`, `asset_types`, `asset_devices`, `asset_device_relationship_history`, `asset_points`, `logical_points`, `device_field_mapping`, `grafana_organization_map`, `sectors`, `sub_sectors`, `sub_sector_asset_mapping`.

## config schema — base tables (24 confirmed live)

`device_categories`, `device_profiles`, `profile_field_mapping`, `device_profile_categories`, `device_operational_policies`, `device_point_configuration`, `asset_device_relationship_types`, `asset_device_relationship_category_compatibility`, `energy_register_semantics`, `demand_register_semantics`, `engineering_units`, `protocols`, `point_categories`, `status_definitions`, `interval_quality_rules`, `telemetry_capture_policies`, `telemetry_availability_policy`, `gateway_connectivity_policy`, `site_demand_policies`, `site_energy_meter_roles`, `site_energy_roles`, `portal_permission_definitions`, `portal_role_definitions`, `portal_role_permissions`.

## telemetry schema — hypertables (confirmed via `timescaledb_information.hypertables`)

`raw_messages`, `raw_message_failures`, `normalized_points`, `energy_measurements`, `environment_measurements`, `environment_daily`, `water_measurements`, `device_status`, `asset_health`.

## telemetry schema — continuous aggregates (16 confirmed via `timescaledb_information.continuous_aggregates`)

`ca_energy_1min`, `ca_energy_5min`, `ca_energy_15min`, `ca_energy_hourly`, `ca_energy_daily`, `ca_energy_phase_power_1min`, `ca_energy_phase_power_5min`, `ca_energy_phase_power_15min`, `ca_energy_phase_power_hourly`, `ca_energy_phase_power_daily`, `ca_energy_electrical_ext_15min`, `ca_energy_electrical_ext_hourly`, `ca_environment_15min`, `ca_environment_hourly`, plus `analytics.generic_telemetry_15m` and `analytics.generic_telemetry_1h`. See `11-aggregation.md` — these are a separate layer from the persisted `analytics.energy_consumption_*` tables.

## analytics schema — hypertables

`energy_consumption_1min`, `energy_consumption_5min`, `energy_consumption_15min`, `energy_consumption_hourly`, `energy_consumption_daily`, `demand_intervals`, `demand_state`.

## analytics schema — views (84 confirmed live; grouped by apparent purpose, not individually documented — many near-duplicate names exist, a known architectural finding, see below)

- **Grafana-facing** (`v_grafana_*`, 15 views): `v_grafana_sites`, `v_grafana_assets`, `v_grafana_devices`, `v_grafana_asset_devices`, `v_grafana_asset_selector`, `v_grafana_asset_point_selector`, `v_grafana_normalized_points`, `v_grafana_active_alarms`, `v_grafana_asset_demand_intervals`, `v_grafana_asset_demand_state`, `v_grafana_asset_electrical_samples`, `v_grafana_asset_energy_intervals`, `v_grafana_asset_health_history`, `v_grafana_asset_identity_context`, `v_grafana_energy_samples`, `v_grafana_point_catalog`, `v_grafana_telemetry_capture_policies` — 17 total. Live-verified this session returning correct row counts for Meenaxy Pharma: `v_grafana_devices` (22), `v_grafana_assets` (22), `v_grafana_energy_samples` (968 rows, current timestamps).
- **Energy consumption/reporting** (`v_energy_*`, 20+ views): `v_energy_consumption_{1min,5min,15min,daily,monthly,mtd,native,site_kpis,today,yesterday}`, `v_energy_reporting_{15min,5min,daily,hourly}`, `v_energy_semantic_rollup_{15min,5min}`, `v_energy_latest`, `v_energy_raw`, `v_energy_daily`, `v_energy_hourly`, `v_energy_demand_15min`, `v_energy_load_profile_*`, `v_energy_peak_demand_*`. **This volume of near-synonymous names is itself a documented architectural finding** (Audit: "Phase 1 Canonical Semantic Model — Final Reconciliation" calls this "the energy-consumption 5-way duplication") — treat any of these as unverified for a given purpose until checked against an actual consumer (dashboard JSON or application code), not assumed canonical by name alone.
- **Asset-scoped**: `v_asset_consumption_*`, `v_asset_demand_15min`, `v_asset_devices`, `v_asset_energy_*`, `v_asset_hierarchy_*`, `v_asset_load_profile_*`, `v_asset_meter_coverage_configuration`, `v_asset_peak_demand_*`, `v_asset_selector`, `v_assets`.
- **Operational/commissioning**: `v_commissioning_readiness`, `v_device_telemetry_availability`, `v_gateway_connectivity`, `v_devices`, `v_organizations`, `v_sites`.
- **Environment sensors**: `v_environment_15min`, `v_environment_hourly`, `v_environment_latest`, `v_environment_sensor_kpis`, `v_environment_sensor_selector`.

## telemetry schema — views

`v_energy_measurements_full_resolution`, `v_energy_measurements_route`, `v_energy_meter`, `v_environment_measurements_full_resolution`, `v_environment_measurements_route`, `v_normalized_points`, `v_rtdata`.

## Key functions/procedures encountered this session

- `metadata.validate_asset_physical_location`, `validate_device_physical_location`, `validate_asset_hierarchy`, `validate_tenant_site_ownership`, `reject_obsolete_device_lifecycle_status`, `reject_uncommissioned_active_device`, `reject_decommissioned_asset_device_assignment`, `validate_asset_device_relationship`, `generate_asset_external_id` — trigger functions, see `05-database.md`.
- `config.sync_device_point_configuration(device_id, reset)`, `config.sync_device_points_after_profile_change()` (trigger wrapper) — populates `device_point_configuration` from `profile_field_mapping`.
- `analytics.refresh_energy_consumption_1min/5min(from, to)` + `analytics.run_energy_consumption_5min_job(job_id, config)` — TimescaleDB background job procedures, see `11-aggregation.md`.
- `telemetry.resolve_site_capture_bucket(site_id, timestamp)` — resolves a site's effective capture-interval policy; live-verified returning `capture_interval_seconds=60` for Meenaxy Pharma's `UNIT_2`.
- `telemetry.ingest_live_rtdata(topic, payload, received_at)` — the live-telemetry path's ingestion entrypoint, called from `app/src/live_telemetry/broker.py`.
- `admin.create_device`, `admin.commission_device`, `admin.set_device_operational_policy`, `admin.assign_device_to_asset` — application-layer onboarding/commissioning functions, see `08-device-onboarding.md` and `16-commissioning.md`.

## Confirmed absent

`pg_cron` extension is **not** installed on staging (`cron.job` relation does not exist) — background jobs run via TimescaleDB's own job scheduler (`timescaledb_information.jobs`, `add_job`/`alter_job`), not `pg_cron`.
