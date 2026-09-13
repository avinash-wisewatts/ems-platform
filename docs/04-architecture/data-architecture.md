# Data Architecture

Status: CURRENT · Last reviewed: 2026-09-13 · Owner: Architecture
Full detail: [../06-platform/](../06-platform/); full frozen model: `docs/DDS/analytics-platform-future-state-architecture.md` §C

## Current data flow (as implemented and verified)

```text
Physical Eniscope meter ──MQTT──► MQTT broker (HiveMQ Cloud)
                                       │
                    ┌──────────────────┴───────────────────┐
                    ▼ (Telegraf, historical path)          ▼ (live-telemetry, live path)
              telemetry.raw_messages              telemetry.ingest_live_rtdata()
                    │  normalization                       │
                    ▼                                       ▼
          telemetry.normalized_points              WebSocket → Grafana live datasource
                    │  routed by hardcoded SQL per device profile
                    ▼
   energy_measurements / environment_measurements / (water_measurements, asset_health — schema-only)
                    │
                    ▼
     Continuous aggregates (telemetry.ca_energy_*, ca_environment_*)
                    │
                    ▼
 Persisted, quality-classified analytics.energy_consumption_{1min,5min,15min,hourly,daily}
                    │
                    ▼
        analytics.v_grafana_* semantic/presentation views (tenant-scoped)
                    │
                    ▼
                 Grafana dashboards  /  Analytics API (Phase 7) → EMS Web Application
```

See [../06-platform/telemetry/README.md](../06-platform/telemetry/README.md)
for the full stage-by-stage trace (live-verified against real devices) and
[../06-platform/database/README.md](../06-platform/database/README.md) for
the schema map.

## Future-state data flow (frozen architecture, not yet built)

The DDS's proposed flow inserts a **semantic interpretation** step between
normalization and domain routing (resolving `logical_point → parameter_id`
and `subject → asset|space`), and makes routing **declarative**
(`config.parameter_routing`, codegen'd) instead of hardcoded SQL:

```text
telemetry.normalized_points
        │  NEW: resolve parameter_id (+qualifier), resolve subject (asset_points/space_points)
        ▼
config.parameter_routing (declarative) decides destination:
        ├─→ domain measurement tables (existing pattern, extended to asset_health/water_measurements)
        └─→ telemetry.generic_point_measurements (NEW — narrow landing zone, promotion-governed)
        ▼
Aggregation (unchanged mechanism, extended coverage; watermark + bounded-catchup + reconciliation)
        ▼
Derived/calculated parameters (NEW): analytics.derived_parameter_values
        ▼
analytics.v_grafana_* (existing pattern, extended with asset/space-shaped views)
```

This is DDS §C's data-flow architecture, implemented via the 17-phase
roadmap. See [system-architecture.md](system-architecture.md) for what's
frozen and [../01-product/roadmap.md](../01-product/roadmap.md) for
implementation status.

## Why two "aggregation" systems exist, and must not be confused

`telemetry.ca_energy_*` (TimescaleDB continuous aggregates — simple
statistical rollups, no quality classification) and
`analytics.energy_consumption_*` (separately persisted, quality-classified
consumption deltas) look similar but serve different purposes. Grafana and
the Analytics API consume **only** the second. See
[../06-platform/database/README.md](../06-platform/database/README.md) and
[../06-platform/telemetry/README.md](../06-platform/telemetry/README.md)
"Watermarks and bounded catch-up."

## Self-healing pipeline pattern (proven, being generalized)

Every analytical tier (energy consumption ×5 resolutions, demand,
`environment_daily`) follows the same proven pattern: a durable watermark
checkpoint, bounded catch-up (`p_max_window`), and a bounded trailing
reconciliation pass that detects and repairs deficits without ever
re-advancing the forward checkpoint. The frozen architecture generalizes
this pattern to every future analytical tier (derived parameters, new
domains) rather than re-implementing it per domain. Operator visibility:
`analytics.v_pipeline_health` — see
[../10-operations/monitoring.md](../10-operations/monitoring.md).
