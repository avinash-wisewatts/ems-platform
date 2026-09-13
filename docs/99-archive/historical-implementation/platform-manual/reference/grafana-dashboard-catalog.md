# Grafana Dashboard Catalog

```
Status: CURRENT
Last verified: 2026-08-24
Verification basis: Repository (grafana/dashboards/core/*.json, read directly this session)
```

All dashboards: datasource `ems-timescaledb` (uid), org-scoped via `${__org.id}`, no fixed org IDs. Default time range `now-24h`/`now` unless noted.

## `alarms.json` — "EMS | Alarms" (`ems-alarms`)
**Purpose**: live view of currently-active alarm-equivalent conditions, org-wide. **Audience**: operator/facility-manager triage. **Refresh**: 1m. **Variable**: `severity` (multi-select). **Panels**: 4 severity stat tiles (Critical/High/Medium/Low — each hardcoded to one severity, not driven by `$severity`), "Active alarms by site" (table), "Alarm detail" (table, respects `$severity`), static nav + scope-boundary text panels. **Objects**: `analytics.v_grafana_active_alarms`, `analytics.v_grafana_sites`.

## `organization-overview.json` — "EMS | Organization Overview" (`ems-org-overview`)
**Purpose**: portfolio landing page. **Audience**: executive/portfolio scan. **Refresh**: 1m. **No variables** (org scope only). **Panels**: Sites/Assets/Devices counts (stat), Active alarms (stat), "Portfolio demand" (timeseries, `SUM(active_power_kw)` 15m-bucketed), "Sites requiring attention" (table, ranked by alarm count), "Site inventory and status" (table). **Objects**: `v_grafana_sites`, `v_grafana_assets`, `v_grafana_devices`, `v_grafana_active_alarms`, `v_grafana_energy_samples`.

## `site-overview.json` — "EMS | Site Overview" (`ems-site-overview`)
**Purpose**: single-site drill-down. **Variable**: `site_id` (single-select). **Panels**: Assets/Devices counts, "Current demand kW" (latest sample per device, summed), Active alarms, "Site demand profile" (15m-bucketed timeseries), "Device telemetry health" (table, by connectivity state), "Hierarchy entry points" (table), "Current alarms" (table). **Objects**: same `v_grafana_*` family as org-overview, filtered by `site_id`.

## `area-overview.json` — "EMS | Area Overview" (`ems-area-overview`)
**Purpose**: one asset-hierarchy branch ("area") drill-down within a site. **Variables**: `site_id` → `area_id` (cascaded, filtered to nodes with `child_count > 0`; falls back to a sentinel row if the site has no areas). **Panels**: Descendant assets / Assigned devices / Current demand kW / Active alarms (all via `WITH RECURSIVE` walk down the asset tree, stat), "Area demand profile" (15m timeseries), "Direct children" (table), "Descendant inventory" (table). **Objects**: `v_grafana_assets`, `v_grafana_asset_devices`, `v_grafana_energy_samples`, `v_grafana_active_alarms`.

## `asset-overview.json` — "EMS | Asset Overview" (`ems-asset-overview`)
**Purpose**: single-asset deep dive — energy, power, demand, electrical quality. **Panels** (partial list): "Energy & Electrical Summary", "Power & Demand", "Active Power Trend", "Demand Profile", "Energy Consumption & Performance", "Energy Consumption Trend", "Voltage Trend", "Current Trend", "Power Factor & Frequency". **Objects** — the richest object set of any dashboard: `v_grafana_asset_identity_context`, `v_grafana_asset_devices`, `v_grafana_asset_electrical_samples`, `v_grafana_asset_selector`, `v_grafana_normalized_points`, `v_grafana_telemetry_capture_policies`, `v_grafana_asset_demand_intervals`, `v_grafana_active_alarms`, `v_grafana_sites`, plus **functions** `analytics.get_grafana_asset_demand_summary()`, `analytics.get_grafana_asset_connectivity_context()`, `analytics.get_grafana_asset_energy_intervals()`, and `analytics.get_canonical_energy_read()` (this dashboard is its only confirmed call site anywhere in Grafana).

## `device-diagnostics.json` — "EMS | Device Diagnostics" (`ems-device-diagnostics`)
**Purpose**: per-device technical/operational diagnostics. **Panels**: "Telemetry state", "Data age seconds", "Mapped points", Active alarms, "Latest normalized points" (table), "Device identity" (table), "Asset assignments" (table), "Device alarms" (table). **Objects**: `v_grafana_devices`, `v_grafana_normalized_points`, `v_grafana_asset_devices`, `v_grafana_active_alarms`, `v_grafana_sites`. This is the closest existing dashboard to a "commissioning readiness" view, though it does not query `analytics.v_commissioning_readiness` directly (verified: that view is not referenced in any of the 7 dashboards).

## `analytics-explorer.json` — "EMS | Analytics Explorer" (`ems-analytics-explorer`)
**Purpose**: ad-hoc multi-asset/multi-metric exploration ("max 5 assets X 5 metrics" per its own panel title). **No fixed refresh interval.** **Objects**: `v_grafana_asset_selector`, `v_grafana_asset_point_selector`, `v_grafana_sites`, and function `analytics.get_grafana_explorer_intervals()` — the only dashboard built around a function-driven flexible query rather than fixed panel SQL.

## Objects with no confirmed dashboard consumer (as of this session)
`v_energy_demand_15min`, `v_energy_peak_demand_daily`, `v_energy_peak_demand_monthly`, `v_asset_peak_demand_daily`, `v_asset_peak_demand_monthly`, `v_energy_site_demand_kpis`, `v_site_energy_balance_daily`, all `v_environment_*` views, `v_energy_reporting_5min/15min/hourly/daily`. Not confirmed dead — see `12-grafana.md`.
