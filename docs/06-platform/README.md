# 06 — Platform

Status: CURRENT · Last reviewed: 2026-09-13 · Owner: Engineering

Canonical source for **how the platform is built and how telemetry flows**
— the implementation layer beneath [04-architecture/](../04-architecture/)'s
architectural summary. Consolidated from `docs/platform-manual/` (archived
at [../99-archive/historical-implementation/platform-manual/](../99-archive/historical-implementation/platform-manual/)).

## What the platform is

The WiseWatts EMS platform ingests electrical telemetry from physical
energy meters (currently Eniscope-brand devices, publishing over MQTT) at
customer sites, persists it in TimescaleDB, computes validated
energy-consumption aggregates at multiple time resolutions, and exposes the
result to operators through Grafana dashboards and (as of Phase 7/8) to
customers through the Analytics API and EMS Web Application.

## Top-level components

| Component | Role |
|---|---|
| **timescaledb** | PostgreSQL 16 + TimescaleDB extension. Sole system of record: metadata, raw/normalized telemetry, validated energy-consumption aggregates, and the semantic/analytics views. |
| **telegraf** | Subscribes to MQTT and writes raw telemetry into TimescaleDB. Stateless relay; holds no application logic. |
| **live-telemetry** | A dedicated FastAPI service maintaining a server-side MQTT subscription for real-time delivery to Grafana's live-datasource plugin, so MQTT broker credentials never reach the browser. Same application image as admin-portal, different `command:`. |
| **admin-portal** | Tenant/site/gateway/device/asset onboarding and commissioning interface. See [../05-applications/admin-portal/README.md](../05-applications/admin-portal/README.md). |
| **grafana** | Visualization layer; per-tenant datasource provisioned at runtime. See [grafana/README.md](grafana/README.md). |

## Directory map

| Directory | Covers |
|---|---|
| [telemetry/](telemetry/README.md) | The end-to-end telemetry pipeline, data model, aggregation, semantic/analytics layer, device onboarding & commissioning. |
| [telegraf/](telegraf/README.md) | MQTT ingestion and Telegraf configuration. |
| [database/](database/README.md) | Schema map, object catalog, drift/repository-vs-live discipline. |
| [grafana/](grafana/README.md) | Grafana architecture, provisioning, dashboard catalog. |
| [deployment/](deployment/README.md) | Docker Compose service topology, ports, environment-file boundaries. |

## What this manual assumes

Basic familiarity with PostgreSQL, TimescaleDB (hypertables, continuous
aggregates), MQTT, Docker Compose, and Grafana provisioning. Where the
platform uses a non-obvious pattern, the relevant document below explains
it explicitly.

## Source-of-truth discipline (carried forward from the archived platform manual)

This documentation explains *how things fit together*; the repository
(`postgres/`, `compose.yaml`, `grafana/`, `.github/workflows/`) is
authoritative for *exact configuration*; the live staging/production
databases are authoritative for *current runtime state*, noted here as of
specific verification dates, not continuously. See
[../00-governance/source-of-truth.md](../00-governance/source-of-truth.md).
