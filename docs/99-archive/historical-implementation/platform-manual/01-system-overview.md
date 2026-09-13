# System Overview

Status: CURRENT
Last verified: 2026-08-24
Verification basis: Repository, Staging, Production read-only

## What the platform is

The WiseWatts EMS (Energy Management System) platform ingests electrical
telemetry from physical energy meters (currently Eniscope-brand devices,
publishing over MQTT) at customer sites, persists it in TimescaleDB,
computes validated energy-consumption aggregates at multiple time
resolutions, and exposes the result to operators through Grafana dashboards
and a dedicated admin portal used for tenant/site/device onboarding and
commissioning.

## Who it's for

- **Tenant/site operators** — view energy consumption, demand, and device
  health for their organization's sites via Grafana dashboards.
- **WiseWatts administrators** — onboard new organizations, sites,
  gateways, devices, and assets, and commission them for live telemetry via
  the admin portal.
- **Platform engineers** — operate and diagnose the ingestion, database,
  and analytics pipeline.

## Top-level components

| Component | Role |
|---|---|
| **timescaledb** | PostgreSQL 16 + TimescaleDB extension. Sole system of record: metadata (tenants/sites/devices/assets), raw and normalized telemetry (hypertables), validated energy-consumption aggregates, and the semantic/analytics views Grafana queries. |
| **telegraf** | Subscribes to the configured MQTT input and writes raw telemetry into TimescaleDB via the `postgres` output plugin. Stateless relay; holds no application logic. |
| **live-telemetry** | A dedicated FastAPI service (`app/src/live_main.py`, `uvicorn`) that maintains a server-side MQTT subscription for real-time (WebSocket) delivery to Grafana's live-datasource plugin, so MQTT broker credentials never reach the browser. Runs from the same application image as admin-portal, different `command:`. |
| **admin-portal** | The application's HTTP interface for tenant/site/gateway/device/asset onboarding and commissioning, backed by `admin.*` schema functions in TimescaleDB. Same application image as live-telemetry. |
| **grafana** | Visualization layer. Datasource is provisioned per-tenant at runtime (not statically) via `metadata.grafana_organization_map`; dashboards are declarative JSON checked into `grafana/dashboards/`. |

## What this manual assumes you already know

Basic familiarity with PostgreSQL, TimescaleDB (hypertables, continuous
aggregates), MQTT, Docker Compose, and Grafana provisioning. Where the
platform uses a non-obvious pattern (e.g. business-key resolution instead
of hardcoded UUIDs, or the split between "device exists" and "device is
producing telemetry"), the relevant document explains it explicitly.

## Where to go next

Start with [02-architecture.md](02-architecture.md) for the full component
diagram and source-of-truth map, then [07-telemetry-pipeline.md](07-telemetry-pipeline.md)
for the end-to-end data path.
