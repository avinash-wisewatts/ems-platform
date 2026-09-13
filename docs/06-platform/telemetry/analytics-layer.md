# Analytics / Semantic Layer

Status: CURRENT · Last reviewed: 2026-08-24 · Verification basis: Staging, Repository

## What "native semantic data" means here

Five distinct layers exist between a physical device and a Grafana panel —
each a real, separately-populated set of database objects:

| Layer | Objects | What it is |
|---|---|---|
| **Raw telemetry** | `telemetry.energy_measurements`, `environment_measurements`, `raw_messages` | One row per received MQTT payload per device (75 columns on `energy_measurements` alone). |
| **Normalized telemetry** | `telemetry.normalized_points` | One row per (device, logical_point, event_time) — decomposed via `config.profile_field_mapping`. Carries `raw_field_name`, `numeric_value`, `quality_code`, `mapping_source`. |
| **Aggregate telemetry** | `telemetry.ca_energy_*` + `analytics.energy_consumption_*` | Time-bucketed rollups — see [aggregation.md](aggregation.md) for why two parallel systems exist. |
| **Device/gateway state** | `telemetry.device_telemetry_state`, `device_status`, `device_live_point_state`, `pipeline_state` | Latest-value/health tracking — "is this device currently reporting," not a time series. |
| **Business/semantic analytics** | `analytics.v_asset_*`, `v_energy_*`, `v_commissioning_readiness`, `v_gateway_connectivity`, etc. | Answers domain questions by joining metadata + the aggregate layer. Asset/site/org-shaped, not device-shaped. |
| **Grafana presentation** | `analytics.v_grafana_*` (17 views) plus function-form objects (`get_grafana_asset_demand_summary()`, etc.) | The only objects Grafana dashboards query directly. Every one filters by `grafana_org_id`, not `organization_id`. |

Live count (verified): **84 objects in the `analytics` schema**, dominated
by `v_energy_*` (23), `v_asset_*` (10), `v_grafana_*` (17), `v_environment_*`
(6). Not every one has a confirmed Grafana consumer — see
[../grafana/README.md](../grafana/README.md).

## Identity preserved through every layer

`organization_id`, `site_id`, `device_id` are present on
`analytics.energy_consumption_1min` and `telemetry.normalized_points`;
`v_grafana_energy_samples` and `v_energy_latest` additionally carry
`gateway_id` and `asset_id`. Every layer can be filtered or joined back to
the metadata model without a separate lookup.

## Semantic classification, not just storage

`analytics.refresh_energy_consumption_5min()` does register-delta
classification per bucket: `import_quality_code`, `import_is_valid`,
`import_reset_detected`, `import_rollover_detected` (same for export),
driven by `config.energy_register_semantics` (per-profile register
direction/rollover/reset behavior) and
`config.resolve_interval_quality_rule()` (site/device-scoped gap-threshold
policy). This encodes real domain knowledge about how cumulative energy
registers behave — not just arithmetic aggregation.

## Known architectural finding: view sprawl

~20+ `v_energy_*` views are near-duplicates by name — a documented,
unresolved finding. Treat any of these as unverified for a given purpose
until checked against an actual consumer (dashboard JSON or application
code), never assumed canonical by name alone. See
[../../04-architecture/system-architecture.md](../../04-architecture/system-architecture.md).
