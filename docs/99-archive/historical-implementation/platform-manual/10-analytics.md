# Analytics / Semantic Layer

```
Status: CURRENT
Last verified: 2026-08-24
Verification basis: Staging, Repository
```

## What "native semantic data" means here

Five distinct layers exist between a physical device and a Grafana panel. Each is a real, separately-populated set of database objects — not just a conceptual distinction:

| Layer | Objects | What it is |
|---|---|---|
| **Raw telemetry** | `telemetry.energy_measurements`, `telemetry.environment_measurements`, `telemetry.raw_messages` | One row per received MQTT payload per device, full field set (75 columns on `energy_measurements` alone: voltages, currents, power, THD, per-phase energy registers, etc.), org/site/gateway/device/asset-scoped. |
| **Normalized telemetry** | `telemetry.normalized_points` | One row per (device, logical_point, event_time) — the raw payload decomposed into the vendor-neutral logical-point vocabulary via `config.profile_field_mapping`/`metadata.device_field_mapping`. Carries `raw_field_name`, `numeric_value`, `quality_code`, `mapping_source`. |
| **Aggregate telemetry** | `telemetry.ca_energy_{1min,5min,15min,hourly,daily}` (TimescaleDB continuous aggregates) and `analytics.energy_consumption_{1min,5min,15min,hourly,daily}` (persisted, validated tables) | Time-bucketed rollups. Two parallel systems — see `11-aggregation.md` for why, and why `_5min` is legitimately empty for 60-second-capture sites. |
| **Device/gateway state** | `telemetry.device_telemetry_state`, `telemetry.device_status`, `telemetry.device_live_point_state`, `telemetry.device_raw_receipt_state`, `telemetry.pipeline_state` | Latest-value/health tracking — "is this device currently reporting," not a time series. |
| **Business/semantic analytics** | `analytics.v_asset_*`, `analytics.v_energy_*`, `analytics.v_commissioning_readiness`, `analytics.v_asset_meter_coverage_configuration`, `analytics.v_gateway_connectivity`, `analytics.v_site_energy_*`, etc. | Views/functions that answer domain questions ("is this asset's metering coverage configured," "what's this asset's current demand") by joining metadata + the aggregate layer. Not device-shaped — asset/site/org-shaped. |
| **Grafana presentation** | `analytics.v_grafana_*` (sites, assets, devices, asset_devices, energy_samples, active_alarms, asset_selector, point_selector, normalized_points, telemetry_capture_policies, plus function-form objects like `analytics.get_grafana_asset_demand_summary()`) | The only objects Grafana dashboards query directly. Every one filters by `grafana_org_id` (resolved from `metadata.grafana_organization_map`), not `organization_id` — a deliberate indirection so dashboards never need to know the internal UUID. |

Live count, verified this session: **84 objects in the `analytics` schema** (`information_schema.tables`), dominated by the `v_energy_*` (23), `v_asset_*` (10), `v_grafana_*` (17), and `v_environment_*` (6) families. Not every one of these 84 has a confirmed Grafana consumer — see `12-grafana.md` for which are actually wired to a dashboard versus defined-but-unused.

## Identity preserved through every layer

Verified live via `information_schema.columns` this session: `organization_id`, `site_id`, `device_id` are present on `analytics.energy_consumption_1min` (29 columns total) and `telemetry.normalized_points` (16 columns, plus `gateway_id`); `analytics.v_grafana_energy_samples` (20 columns) and `analytics.v_energy_latest` (77 columns) additionally carry `gateway_id` and `asset_id`. This means every layer can be filtered or joined back to the metadata model without a separate lookup — a Grafana query never has to guess which organization a raw energy sample belongs to.

## Semantic classification, not just storage

The 1min/5min layer is not a plain average — `analytics.refresh_energy_consumption_5min()` (read in full this session) does register-delta classification per bucket: `import_quality_code`, `import_is_valid`, `import_reset_detected`, `import_rollover_detected` (same for export), driven by `config.energy_register_semantics` (per-profile register direction/rollover/reset behavior) and `config.resolve_interval_quality_rule()` (site/device-scoped gap-threshold policy). This is genuinely a "semantic" layer in the sense the platform's own naming implies — it encodes domain knowledge about how cumulative energy registers behave (rollover, reset, gaps), not just arithmetic aggregation. `analytics.energy_consumption_1min` follows the equivalent pattern for the 1-minute native resolution.

See `07-telemetry-pipeline.md` for the full stage-by-stage lifecycle and `11-aggregation.md` for resolution-by-resolution detail.
