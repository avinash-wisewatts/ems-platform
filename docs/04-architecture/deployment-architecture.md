# Deployment Architecture

Status: PARTIAL · Last reviewed: 2026-09-13 · Owner: Architecture
Source of truth: platform manual chapters 03 & 04 (archived), consolidated here. Process detail: [../09-release-and-deployment/](../09-release-and-deployment/).

## Topology

A single Docker Compose stack (`compose.yaml`, project name
`ems-platform-prod`), used unchanged for both staging and production. Five
services: `timescaledb`, `telegraf`, `grafana`, `live-telemetry`,
`admin-portal`. `admin-portal` and `live-telemetry` are two `command:`
variants of the same built application image (`app/Dockerfile`) — see
[../06-platform/README.md](../06-platform/README.md).

**Host topology**: not independently verified — only read-only PostgreSQL
access has been established in any documented session, no SSH or
infrastructure-provider console access. `compose.yaml` comments reference
"the EC2 host," implying AWS EC2, but this is repository evidence, not
independently verified infrastructure inspection.

## Networking / exposure

All five services default to `127.0.0.1`-only binding
(`GRAFANA_BIND_HOST`/`ADMIN_PORTAL_BIND_HOST` overridable via an untracked
root `.env`). **Reverse proxy / public TLS is explicitly planned, not
implemented** — `compose.yaml`'s own comment: "Caddy and public TLS exposure
will be configured only after authentication and tenant isolation have been
validated."

## Independent EMS Web Application deployment

The EMS Web Application is treated as an **independently deployable
application** — releasable and rollbackable without changing the
Administration App, Grafana, the database, or the energy subsystem (see
[ADR-006](../00-governance/decisions/ADR-006-ems-web-app-vs-admin-portal.md)).
Current staging delivery mechanism: an independently versioned
`ghcr.io/<repo>-web:<sha>` artifact carrying only the static bundle,
extracted read-only into the admin-portal container at `/app/src/spa` and
served same-origin under `/app` by the existing FastAPI hook — a delivery
mechanism chosen because no reverse proxy exists yet, expected to evolve
(e.g. a dedicated container behind a proxy) without changing the
architectural boundary. See
[../05-applications/ems-web/README.md](../05-applications/ems-web/README.md).

## What is unknown

Exact hosting provider/instance type/region for staging and production.
Whether a reverse proxy or TLS termination exists beyond what
`compose.yaml` itself configures. Live container status, restart counts,
and resource utilization.
